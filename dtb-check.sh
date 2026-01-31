# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/bash

# Usage:
# ./dtb-check.sh --kernel-src <KERNEL_SRC_PATH> --base <BASE_SHA> --head <HEAD_SHA>

set -x

# Load shared utilities
source "$(dirname "$0")/script-utils.sh"

# Parse and validate input arguments
parse_args "$@"
validate_args

# Enter kernel source directory
enter_kernel_dir

# Initialize variables
exit_status=0
dt_dir="arch/arm64/boot/dts/"
base_log_file="base_dtbs_errors.log"
head_log_file="head_dtbs_errors.log"
temp_out="temp-out"

# Check for devicetree changes
if ! git diff --name-only "$base_sha" "$head_sha" -- "$dt_dir" | grep -q .; then
    echo "No changes in Devicetree"
    leave_kernel_dir
    exit 0
fi

# Build DTBs at base SHA
git checkout "$base_sha" > /dev/null 2>&1
run_in_kmake_image make -s -j"$(nproc)" O="$temp_out" defconfig
run_in_kmake_image make -s -j"$(nproc)" O="$temp_out" dtbs

# Checkout to head SHA and run make dtbs to
# get the list of devicetree files impacted
# by the head_sha
git checkout "$head_sha" > /dev/null 2>&1
run_in_kmake_image make -s -j"$(nproc)" O="$temp_out" defconfig

# Collect DTB paths from the build output
dtb_files=$(
  run_in_kmake_image make -j"$(nproc)" O="$temp_out" dtbs \
  | grep -oP 'arch/arm64/boot/dts/.*?\.dtb' \
  | sort -u
)

if [[ -z "$dtb_files" ]]; then
    echo "No DTBs were built under head; nothing to validate."
    # Cleanup
    rm -rf "$temp_out"
    leave_kernel_dir
    exit 0
fi

git checkout "$base_sha" > /dev/null 2>&1
run_in_kmake_image make -s -j"$(nproc)" O="$temp_out" defconfig

for devicetree in $dtb_files; do
    target="$(echo "$devicetree" | sed 's|^arch/arm64/boot/dts/||')"

    run_in_kmake_image \
      make  -j"$(nproc)" O="$temp_out" CHECK_DTBS=y \
      "$target"  >> "$base_log_file" 2>&1
done

git checkout "$head_sha" > /dev/null 2>&1
run_in_kmake_image make -s -j"$(nproc)" O="$temp_out" defconfig

for devicetree in $dtb_files; do
    echo "Validating $devicetree"

    target="$(echo "$devicetree" | sed 's|^arch/arm64/boot/dts/||')"

    run_in_kmake_image \
      make  -j"$(nproc)" O="$temp_out" CHECK_DTBS=y \
      "$target"  >> "$head_log_file" 2>&1
done

log_summary=$(grep -vFf "$base_log_file" "$head_log_file")

# If log_summary is non-empty, set exit_status=1
if [ -n "$log_summary" ]; then
    echo -e "Log Summary: Test failed\n$log_summary"
    exit_status=1
else
    echo -e "Log Summary: Test passed"
fi

# Cleanup
rm -rf "$temp_out"
rm -f "$base_log_file"
rm -f "$head_log_file"
leave_kernel_dir

exit $exit_status
