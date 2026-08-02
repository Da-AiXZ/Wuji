#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
  exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo_root/ThirdParty/minizip-ng"
output="$(mkdir -p "$1" && cd "$1" && pwd)"
build_dir="$output/minizip-build"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
clang="$(xcrun --sdk iphonesimulator --find clang)"

"$repo_root/Scripts/verify-minizip-lock.sh"

cmake -S "$source_dir" -B "$build_dir" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DMZ_COMPAT=OFF \
  -DMZ_ZLIB=ON \
  -DMZ_BZIP2=OFF \
  -DMZ_LZMA=OFF \
  -DMZ_PPMD=OFF \
  -DMZ_ZSTD=OFF \
  -DMZ_LIBCOMP=OFF \
  -DMZ_FETCH_LIBS=OFF \
  -DMZ_FORCE_FETCH_LIBS=OFF \
  -DMZ_PKCRYPT=OFF \
  -DMZ_WZAES=OFF \
  -DMZ_OPENSSL=OFF \
  -DMZ_LIBBSD=OFF \
  -DMZ_ICONV=OFF \
  -DMZ_ICU=OFF \
  -DMZ_DECOMPRESS_ONLY=ON \
  -DMZ_BUILD_TESTS=OFF \
  -DMZ_BUILD_UNIT_TESTS=OFF \
  -DMZ_BUILD_FUZZ_TESTS=OFF

cmake --build "$build_dir" --target minizip-ng
cp "$build_dir/libminizip-ng.a" "$output/libminizip-stage-a.a"
cp "$build_dir/mz_config.h" "$output/mz_config.h"

"$clang" \
  -arch arm64 \
  -isysroot "$sdk" \
  -mios-simulator-version-min=16.0 \
  -std=c11 \
  -I"$repo_root/Executor" \
  -I"$source_dir" \
  -I"$build_dir" \
  -c "$repo_root/Executor/WujiStageAZipBridge.c" \
  -o "$output/WujiStageAZipBridge.o"
xcrun libtool -static \
  -o "$output/libwuji_stage_a_zip_bridge.a" \
  "$output/WujiStageAZipBridge.o"

test -s "$output/libminizip-stage-a.a"
test -s "$output/libwuji_stage_a_zip_bridge.a"
test -s "$output/mz_config.h"
printf 'Built fixed Stage A minizip closure in %s\n' "$output"
