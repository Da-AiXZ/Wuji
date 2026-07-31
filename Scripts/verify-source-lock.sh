#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ish="$repo_root/ThirdParty/ish"

test "$(git -C "$ish" rev-parse HEAD)" = "de124dd66124a15239cea1465164f74980ada245"
test "$(git -C "$ish" show -s --format=%T HEAD)" = "b94281841315d439cd9b1b222c192a2919b63694"
test "$(git -C "$ish/deps/libarchive" rev-parse HEAD)" = "fc6563f5130d8a7ee1fc27c0e55baef35119f26c"

test ! -e "$ish/deps/libapps/.git"
test ! -e "$ish/deps/linux/.git"

printf 'Verified iSH %s\n' "$(git -C "$ish" rev-parse HEAD)"
printf 'Verified libarchive %s\n' "$(git -C "$ish/deps/libarchive" rev-parse HEAD)"
printf 'Verified excluded submodules: deps/libapps, deps/linux\n'
