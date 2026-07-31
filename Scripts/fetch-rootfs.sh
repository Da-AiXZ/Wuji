#!/usr/bin/env bash
set -euo pipefail

readonly url="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz"
readonly expected_size="3851686"
readonly expected_sha256="f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$repo_root/Wuji/Resources/rootfs.tar.gz"
temporary="$(mktemp "${TMPDIR:-/tmp}/wuji-rootfs.XXXXXX")"
trap 'rm -f "$temporary"' EXIT

curl --fail --location --retry 2 --retry-all-errors --output "$temporary" "$url"

actual_size="$(wc -c < "$temporary" | tr -d ' ')"
test "$actual_size" = "$expected_size"

actual_sha256="$(shasum -a 256 "$temporary" | awk '{print $1}')"
test "$actual_sha256" = "$expected_sha256"

mkdir -p "$(dirname "$destination")"
mv "$temporary" "$destination"
printf 'Verified rootfs size=%s sha256=%s\n' "$actual_size" "$actual_sha256"
