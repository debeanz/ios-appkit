#!/usr/bin/env bash
# Build the desktop OpenGL stack the Mac games Steam starts use, for iOS arm64, natively:
# Mesa's OpenGL (OSMesa front end) with the Zink driver turns GL into Vulkan, and MoltenVK
# turns Vulkan into Metal. No emulation and no JIT: everything is ahead-of-time compiled
# arm64 code; shaders go GLSL -> SPIR-V (Zink) -> Metal Shading Language (MoltenVK) -> the
# Metal compiler, as any iOS game's do.
#
#   tools/gl/build.sh <out-dir>
#
# Writes <out-dir>/libMoltenVK.dylib, <out-dir>/libOSMesa.dylib (both @rpath/<name>) and their
# licences. macOS only (Xcode, the iOS SDK); takes a while the first time, so CI caches the
# result (.github/workflows/ipa.yml).
set -euo pipefail
OUT="$(mkdir -p "${1:?usage: build.sh <out-dir>}" && cd "$1" && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${GL_WORK:-$here/../../build/gl-work}"
mkdir -p "$WORK" "$OUT/licenses"
WORK="$(cd "$WORK" && pwd)"

MVK_TAG=v1.4.2
MESA_VERSION=25.0.7   # OSMesa was removed in 25.1
MESA_SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "=== MoltenVK $MVK_TAG (Vulkan on Metal) ==="
MVK="$WORK/MoltenVK"
[ -d "$MVK/.git" ] || git clone --depth 1 -b "$MVK_TAG" https://github.com/KhronosGroup/MoltenVK "$MVK"
( cd "$MVK"
  [ -d External/build ] || ./fetchDependencies --ios
  make ios )
cp "$MVK/Package/Release/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK" "$OUT/libMoltenVK.dylib"
install_name_tool -id @rpath/libMoltenVK.dylib "$OUT/libMoltenVK.dylib"
cp "$MVK/LICENSE" "$OUT/licenses/MoltenVK-Apache-2.0.txt"

echo "=== Mesa $MESA_VERSION (OSMesa + Zink) ==="
VENV="$WORK/venv"
[ -x "$VENV/bin/meson" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q meson mako pyyaml packaging ninja; }
export PATH="$VENV/bin:$PATH"
SRC="$WORK/mesa-$MESA_VERSION"
if [ ! -f "$SRC/meson.build" ]; then
  curl -sfL -o "$WORK/mesa.tar.xz" "https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"
  echo "$MESA_SHA256  $WORK/mesa.tar.xz" | shasum -a 256 -c -
  tar -xJf "$WORK/mesa.tar.xz" -C "$WORK"
  for p in "$here"/mesa-patches/0*.patch; do
    echo "  patch $(basename "$p")"
    patch -d "$SRC" -p1 --forward < "$p"
  done
fi

# iOS arm64, with the Vulkan platform defines MoltenVK's headers set, so every file agrees.
ARGS="'-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=15.0'"
DEFS="'-DVK_USE_PLATFORM_METAL_EXT=1', '-DVK_USE_PLATFORM_IOS_MVK=1'"
cat > "$WORK/ios-arm64.cross" <<EOF
[binaries]
c = ['xcrun', '-sdk', 'iphoneos', 'clang']
cpp = ['xcrun', '-sdk', 'iphoneos', 'clang++']
objc = ['xcrun', '-sdk', 'iphoneos', 'clang']
ar = ['xcrun', '-sdk', 'iphoneos', 'ar']
strip = ['xcrun', '-sdk', 'iphoneos', 'strip']
pkg-config = 'false'

[built-in options]
c_args = [$ARGS, $DEFS]
cpp_args = [$ARGS, $DEFS]
objc_args = [$ARGS, $DEFS]
c_link_args = [$ARGS]
cpp_link_args = [$ARGS]
objc_link_args = [$ARGS]

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

B="$WORK/mesa-build"
if [ ! -f "$B/build.ninja" ]; then
  # softpipe only because OSMesa insists on a software driver; GALLIUM_DRIVER=zink picks Zink.
  meson setup "$B" "$SRC" --cross-file "$WORK/ios-arm64.cross" \
    --buildtype=release -Db_ndebug=true --default-library=shared \
    -Dplatforms= -Dgallium-drivers=softpipe,zink -Dvulkan-drivers= \
    -Dosmesa=true -Dopengl=true -Dgles1=disabled -Dgles2=disabled \
    -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dllvm=disabled -Dxmlconfig=disabled -Dzstd=disabled -Dlibunwind=disabled \
    -Dvalgrind=disabled -Dlmsensors=disabled -Dexpat=disabled -Dbuild-tests=false -Dvideo-codecs= \
    -Dshader-cache=enabled -Dshader-cache-default=true -Dshader-cache-max-size=256M -Dzlib=enabled \
    -Dmoltenvk-dir="$MVK"
fi
ninja -C "$B"
cp "$B/src/gallium/targets/osmesa/libOSMesa.8.dylib" "$OUT/libOSMesa.dylib"
install_name_tool -id @rpath/libOSMesa.dylib "$OUT/libOSMesa.dylib"
xcrun -sdk iphoneos strip -x "$OUT/libOSMesa.dylib"
cp "$SRC/docs/license.rst" "$OUT/licenses/Mesa-license.rst"

echo "$MVK_TAG mesa-$MESA_VERSION" > "$OUT/VERSION"
ls -la "$OUT"
echo "libOSMesa exports $(nm -gU "$OUT/libOSMesa.dylib" | grep -c ' _gl') gl functions"
