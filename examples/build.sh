#!/usr/bin/env bash
# Builds importable Lazer plugin ZIPs from the example folders next to this file.
#
#   ./build.sh                 -> dist/<plugin-id>-<version>.zip
#   ./build.sh <output-dir>    -> <output-dir>/<plugin-id>-<version>.zip
#
# Needs python3 (it reads manifest.json and writes the archives, so the result
# matches build.bat byte for byte in layout). build.bat is the Windows entry
# point and drives build.ps1 instead.

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="${1:-dist}"

if command -v python3 >/dev/null 2>&1; then
  python=python3
elif command -v python >/dev/null 2>&1; then
  python=python
else
  echo "build.sh needs python3 on PATH to read manifests and write the ZIPs." >&2
  exit 1
fi

"$python" - "$here" "$output" <<'PY'
import json
import os
import sys
import zipfile

root = os.path.abspath(sys.argv[1])
output = sys.argv[2]
if not os.path.isabs(output):
    output = os.path.join(root, output)
os.makedirs(output, exist_ok=True)

projects = ["gateway-mock", "theme-plugin"]

for project in projects:
    source = os.path.join(root, project)
    manifest_path = os.path.join(source, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise SystemExit("Missing manifest: %s" % manifest_path)

    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)

    zip_path = os.path.join(output, "%s-%s.zip" % (manifest["id"], manifest["version"]))
    if os.path.exists(zip_path):
        os.remove(zip_path)

    # manifest.json sits at the archive root, which is what the plugin manager
    # requires; entry points and modules stay next to it.
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for current, _, files in sorted(os.walk(source)):
            for name in sorted(files):
                full = os.path.join(current, name)
                relative = os.path.relpath(full, source).replace(os.sep, "/")
                archive.write(full, relative)

    print("%-14s -> %s (%d bytes)" % (project, zip_path, os.path.getsize(zip_path)))
PY
