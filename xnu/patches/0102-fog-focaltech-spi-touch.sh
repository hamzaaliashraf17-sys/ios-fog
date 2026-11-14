#!/bin/bash
# dxb runs patches/*.sh from XNU root BEFORE *.patch, so this only stages files.
# The FTS code edit is merged into 0101. This stages the fw header for it.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
src=""
for c in "$(dirname "$0")/focaltech_fw_xinli.h" "${GITHUB_WORKSPACE:-}/xnu/patches/focaltech_fw_xinli.h" "xnu/patches/focaltech_fw_xinli.h"; do
  if [[ -f "$c" ]]; then src="$c"; break; fi
done
[[ -n "$src" ]] || { echo "0102: focaltech_fw_xinli.h not found" >&2; exit 1; }
cp "$src" bsd/dev/focaltech_fw_xinli.h
echo "0102 staged focaltech_fw_xinli.h from $src"
