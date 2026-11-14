#!/bin/bash
# dxb runs patches/*.sh from XNU root BEFORE *.patch, so this only stages files.
# The code edit is in 0102-fog-focaltech-spi-touch.patch (applied after 0101).
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
cp "$(dirname "$0")/focaltech_fw_xinli.h" bsd/dev/focaltech_fw_xinli.h
echo "0102 staged focaltech_fw_xinli.h"
