#!/bin/bash
# Build the NVK Vulkan driver for the Nintendo Switch on macOS (arm64 or x86_64) or Linux, in Docker, and lay it out
# as the SDK folder that tools/build_nro.sh expects:
#
#     <OUT>/opt/devkitpro/portlibs/switch/lib/libvulkan.a
#
# Steps: clone danfromtico/mesa-switch at the pinned commit, apply mesa-switch-masseffect.patch, run the upstream
# build-switch.sh (it builds the devkitpro-mesa-rust image from Docker.rust, then Mesa's host tools, then the Switch
# archives), and merge libnak_rs.a (the Rust runtime of the shader compiler) into libvulkan.a.
# Uses Dockerfile.local with pinned devkitPro base and Rust nightly; JOBS defaults to 1; MESA_OPT defaults to 2.
#
#   ./build_mesa_docker.sh                       # full build, source and SDK under ../out/
#   OUT=/path/to/mesa-sdk ./build_mesa_docker.sh
#   SRC=/path/to/mesa-switch-src ./build_mesa_docker.sh
#   ./build_mesa_docker.sh --incremental         # after editing SRC: only ninja + merge (needs a previous full build)
#   APPLY_ONLY=1 ./build_mesa_docker.sh          # only clone + apply the patch (no Docker needed)
#
# Needs: git, docker, python3. First full build: about an hour or more and ~15 GB of disk.
# MESA_IMAGE selects an existing compatible image; its identity is saved in OUT/docker-image.json.
set -euo pipefail

PIN=d4a00ea0ab3f59afb967cc5d779e4263d237bd77
UPSTREAM=${UPSTREAM:-https://github.com/danfromtico/mesa-switch.git}
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=$HERE/mesa-switch-masseffect.patch
SRC=${SRC:-$HERE/../out/mesa-switch-src}
OUT=${OUT:-$HERE/../out/mesa-sdk}
IMAGE=${MESA_IMAGE:-devkitpro-mesa-rust-local}
CONTAINER=mesa-switch-masseffect-build
JOBS=${JOBS:-1}
MESA_OPT=${MESA_OPT:-2}
MESA_OPT=${MESA_OPT#[Oo]}
case "$MESA_OPT" in 1|2|3) ;; *) echo "error: MESA_OPT must be 1, 2 or 3 (got '$MESA_OPT')" >&2; exit 1 ;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer' >&2; exit 2; }
INCREMENTAL=0
[ "${1:-}" = "--incremental" ] && INCREMENTAL=1

mkdir -p "$(dirname "$SRC")" "$OUT"
SRC=$(cd "$SRC" 2>/dev/null && pwd || echo "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")")
OUT=$(cd "$OUT" && pwd)
VOLUME_KEY=$(printf '%s' "$SRC" | cksum | awk '{print $1}')
NATIVE_VOLUME="masseffect-mesa-$VOLUME_KEY-native"
SWITCH_VOLUME="masseffect-mesa-$VOLUME_KEY-switch-o$MESA_OPT"
prepare_volumes() {
  for volume in "$NATIVE_VOLUME" "$SWITCH_VOLUME"; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      [ "$(docker volume inspect --format '{{index .Labels "masseffect.source"}}' "$volume")" = "$SRC" ] || {
        echo "Volume belongs to another source tree: $volume" >&2; exit 1;
      }
    else
      docker volume create --label "masseffect.source=$SRC" "$volume" >/dev/null
    fi
  done
}

if [ "$INCREMENTAL" = 0 ]; then
  if [ ! -d "$SRC/.git" ]; then
    echo "== clone $UPSTREAM at $PIN"
    git clone --no-checkout "$UPSTREAM" "$SRC"
  fi
  cd "$SRC"
  if git apply --reverse --check "$PATCH" 2>/dev/null && [ "$(git rev-parse HEAD)" != "$PIN" ]; then
    echo "Patched checkout does not match pinned Mesa commit $PIN" >&2
    exit 1
  fi
  if git apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "== patch already applied"
  else
    git checkout -q "$PIN"
    echo "== apply $(basename "$PATCH")"
    git apply "$PATCH"
  fi
  [ "${APPLY_ONLY:-0}" = 1 ] && { echo "patched source: $SRC"; exit 0; }
  prepare_volumes
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    # This Dockerfile needs no source context; avoid sending the Mesa checkout.
    mkdir -p "$OUT/image-context"
    docker build -f "$HERE/Dockerfile.local" -t "$IMAGE" "$OUT/image-context"
  fi
  # Keep upstream source scripts intact and retain the exact bounded build script.
  python3 - "$SRC/build-switch.sh" "$OUT/build-switch-local.sh" "$IMAGE" "$JOBS" "$NATIVE_VOLUME" "$SWITCH_VOLUME" "$MESA_OPT" <<'PY'
import pathlib, sys
source, target, image, jobs, native_volume, switch_volume, optimization = sys.argv[1:]
script = pathlib.Path(source).read_text()
if '-Doptimization=1' not in script:
    raise SystemExit('upstream build-switch.sh no longer has the expected optimization setting')
script = script.replace('-Doptimization=1', '-Doptimization=' + optimization)

script = script.replace('IMAGE_NAME="devkitpro-mesa-rust"', 'IMAGE_NAME=' + repr(image))
script = script.replace('CONTAINER_NAME="mesa-switch-build"', 'CONTAINER_NAME="mesa-switch-masseffect-full"')
script = script.replace('docker rm -f "$CONTAINER_NAME" 2>/dev/null || true',
    'if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then echo "Build container already exists: $CONTAINER_NAME" >&2; exit 1; fi')
script = script.replace('run() { docker exec', 'trap \'docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true\' EXIT\nrun() { docker exec')
script = script.replace('"$IMAGE_NAME" sleep infinity', '-e CARGO_BUILD_JOBS=' + jobs + ' "$IMAGE_NAME" sleep infinity')
script = script.replace('-v "$(pwd):/project"', '-v "$(pwd):/project" -v ' + native_volume + ':/project/builddir-native -v ' + switch_volume + ':/project/builddir-switch')
script = script.replace('ninja -C /project/', 'ninja -j' + jobs + ' -C /project/')
script = script.replace('meson setup builddir-native --wipe', 'meson setup builddir-native --wipe -Ddisplay-info=disabled')
script = script.replace('meson setup builddir-switch --wipe', 'meson setup builddir-switch --wipe -Ddisplay-info=disabled')
pathlib.Path(target).write_text(script)
PY
  echo "== full build (build-switch.sh)"
  bash "$OUT/build-switch-local.sh"
fi

cd "$SRC"
if [ "$INCREMENTAL" = 1 ]; then
  prepare_volumes
  echo "== incremental ninja"
  docker run --rm --name "$CONTAINER" -e JOBS="$JOBS" -e CARGO_BUILD_JOBS="$JOBS" -v "$SRC:/project" -v "$NATIVE_VOLUME:/project/builddir-native" -v "$SWITCH_VOLUME:/project/builddir-switch" -w /project "$IMAGE" bash -c '
    set -euo pipefail
    mkdir -p /usr/local/libexec
    cp bindgen-switch-wrapper.sh /usr/local/libexec/bindgen
    cp rustc-switch-wrapper.sh /usr/local/libexec/rustc
    cp bindgen-atomic-shim.h /usr/local/libexec/
    chmod +x /usr/local/libexec/bindgen /usr/local/libexec/rustc
    cp src/gallium/winsys/nouveau/drm/nouveau.h src/nouveau/headers/nv_device_info.h /opt/devkitpro/portlibs/switch/include/
    if [ ! -d /usr/lib/llvm-15/lib/clang/15/include ]; then
      ln -sf /usr/lib/llvm-15/lib/clang/15.0.6/include /usr/lib/llvm-15/lib/clang/15/include
    fi
    if [ ! -f /opt/devkitpro/portlibs/switch/lib/libdl.a ]; then
      printf "void __mesa_switch_stub_lib(void) {}\n" > /tmp/stub_posix.c
      /opt/devkitpro/devkitA64/bin/aarch64-none-elf-gcc -c /tmp/stub_posix.c -o /tmp/stub_posix.o
      for library in dl rt util; do
        /opt/devkitpro/devkitA64/bin/aarch64-none-elf-ar rcs /opt/devkitpro/portlibs/switch/lib/lib${library}.a /tmp/stub_posix.o
      done
    fi
    export PATH="/usr/local/libexec:/project/builddir-native/src/compiler/clc:/project/builddir-native/src/compiler/spirv:$PATH"
    ninja -j "$JOBS" -C /project/builddir-switch \
      src/nouveau/vulkan/libnvk.a src/nouveau/vulkan/libvulkan.a src/nouveau/compiler/libnak_rs.a \
      src/nouveau/compiler/libnak.a'
fi

echo "== merge libnak_rs.a into libvulkan.a"
LIBDIR=$OUT/opt/devkitpro/portlibs/switch/lib
mkdir -p "$LIBDIR"
docker run --rm -v "$SRC:/project" -v "$SWITCH_VOLUME:/project/builddir-switch" -v "$LIBDIR:/export" -w /project/builddir-switch "$IMAGE" bash -euo pipefail -c '
  AR=/opt/devkitpro/devkitA64/bin/aarch64-none-elf-ar
  printf "CREATE libvulkan_merged.a\nADDLIB src/nouveau/vulkan/libvulkan.a\nADDLIB src/nouveau/compiler/libnak_rs.a\nSAVE\nEND\n" | $AR -M
  /opt/devkitpro/devkitA64/bin/aarch64-none-elf-nm --defined-only libvulkan_merged.a > merged-symbols.txt
  for symbol in nvk_switch_draw nvk_switch_set4 vk_switch_preload_pipeline; do
    grep -Eq " [BDT] $symbol$" merged-symbols.txt || { echo "Missing NVK contract: $symbol" >&2; exit 1; }
  done
  cp libvulkan_merged.a /export/libvulkan.a
  cmp libvulkan_merged.a /export/libvulkan.a
  sha256sum libvulkan_merged.a /export/libvulkan.a'
cat > "$OUT/SOURCE.txt" <<EOT
mesa-switch $PIN + masseffect-nx mesa/mesa-switch-masseffect.patch
built with build-switch.sh (Docker), libvulkan.a = builddir-switch libvulkan.a + libnak_rs.a merged with ar -M
image: $IMAGE; jobs: $JOBS; -Doptimization=$MESA_OPT
build volumes: $NATIVE_VOLUME $SWITCH_VOLUME
EOT
docker image inspect "$IMAGE" > "$OUT/docker-image.json"
ls -la "$LIBDIR/libvulkan.a"
echo "Use it with:  MESA_SDK=$OUT tools/build_nro.sh"
echo "(-DREXGLUE_SWITCH_NVK_SDK=$OUT/opt/devkitpro/portlibs/switch). The app tracks the archive for relinking."
