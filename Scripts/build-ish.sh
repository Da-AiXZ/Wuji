#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
  exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ish="$repo_root/ThirdParty/ish"
libarchive="$ish/deps/libarchive"
output="$(mkdir -p "$1" && cd "$1" && pwd)"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
clang="$(xcrun --sdk iphonesimulator --find clang)"
ar="$(xcrun --sdk iphonesimulator --find ar)"

"$repo_root/Scripts/verify-source-lock.sh"

libarchive_build="$output/libarchive-build"
cmake -S "$libarchive" -B "$libarchive_build" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_TEST=OFF \
  -DENABLE_TAR=OFF \
  -DENABLE_CPIO=OFF \
  -DENABLE_CAT=OFF \
  -DENABLE_OPENSSL=OFF \
  -DENABLE_MBEDTLS=OFF \
  -DENABLE_NETTLE=OFF \
  -DENABLE_LZ4=OFF \
  -DENABLE_LZO=OFF \
  -DENABLE_LZMA=OFF \
  -DENABLE_ZSTD=OFF \
  -DENABLE_BZip2=OFF \
  -DENABLE_LIBXML2=OFF \
  -DENABLE_EXPAT=OFF \
  -DENABLE_PCREPOSIX=OFF \
  -DENABLE_LIBB2=OFF \
  -DENABLE_LibGCC=OFF \
  -DENABLE_XATTR=OFF \
  -DENABLE_ACL=OFF \
  -DENABLE_ICONV=OFF
cmake --build "$libarchive_build" --target archive_static
cp "$libarchive_build/libarchive/libarchive.a" "$output/libarchive.a"

ish_build="$output/ish-build"
mkdir -p "$ish_build"
cross_file="$ish_build/cross.txt"
cat > "$cross_file" <<EOF
[binaries]
c = '$clang'
ar = '$ar'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-mios-simulator-version-min=16.0', '-fblocks']
c_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-mios-simulator-version-min=16.0']

[properties]
needs_exe_wrapper = true
EOF

export CC_FOR_BUILD="$(xcrun --find clang)"
meson setup "$ish_build" "$ish" \
  --cross-file "$cross_file" \
  -Dguest_arch=arm64 \
  -Dkernel=ish \
  -Dengine=asbestos \
  -Dlog_handler=nslog \
  -Dbuildtype=debug
ninja -C "$ish_build" libish.a libish_emu.a libfakefs.a
cp "$ish_build/libish.a" "$output/libish.a"
cp "$ish_build/libish_emu.a" "$output/libish_emu.a"
cp "$ish_build/libfakefs.a" "$output/libfakefs.a"

common_flags=(
  -arch arm64
  -isysroot "$sdk"
  -mios-simulator-version-min=16.0
  -std=gnu11
  -fblocks
  -DGUEST_ARM64=1
  -I"$repo_root/Executor"
  -I"$ish"
  -I"$libarchive/libarchive"
)
"$clang" "${common_flags[@]}" -c "$repo_root/Executor/WujiISHAdapter.c" -o "$output/WujiISHAdapter.o"
"$clang" "${common_flags[@]}" -c "$ish/tools/fakefs.c" -o "$output/fakefs-import.o"
xcrun libtool -static -o "$output/libwuji_ish_adapter.a" \
  "$output/WujiISHAdapter.o" "$output/fakefs-import.o"

for library in libarchive.a libish.a libish_emu.a libfakefs.a libwuji_ish_adapter.a; do
  test -s "$output/$library"
done
printf 'Built fixed ARM64 iSH simulator closure in %s\n' "$output"
