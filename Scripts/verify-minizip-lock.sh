#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo_root/ThirdParty/minizip-ng"
lock="$source_dir/WUJI_SOURCE_LOCK.json"

python3 - "$source_dir" "$lock" <<'PY'
import hashlib
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).resolve()
lock_path = pathlib.Path(sys.argv[2]).resolve()
data = json.loads(lock_path.read_text(encoding="utf-8"))

assert data["sourceArtifact"] == "minizip-ng-develop.zip"
assert data["sourceArtifactBytes"] == 666200
assert data["sourceArtifactSHA256"] == "0289b08aa2a1a111a330f2e7ada6826b411d47518acf2f4d334ac444e38daad7"
assert data["sourceEntryCount"] == 140
assert data["internalVersion"] == "4.2.2"
assert data["gitIdentity"] is None

expected = {item["path"]: item for item in data["files"]}
actual = {
    path.relative_to(source).as_posix(): path
    for path in source.rglob("*")
    if path.is_file() and path.name != lock_path.name
}
if set(actual) != set(expected):
    raise SystemExit("vendored minizip file set mismatch")

for relative, item in expected.items():
    payload = actual[relative].read_bytes()
    if len(payload) != item["bytes"]:
        raise SystemExit(f"vendored minizip size mismatch: {relative}")
    if hashlib.sha256(payload).hexdigest() != item["sha256"]:
        raise SystemExit(f"vendored minizip hash mismatch: {relative}")

cmake = (source / "CMakeLists.txt").read_text(encoding="utf-8")
if 'set(VERSION "4.2.2")' not in cmake:
    raise SystemExit("vendored minizip internal version mismatch")
print("STAGE_A_MINIZIP_SOURCE_LOCK=PASS")
PY
