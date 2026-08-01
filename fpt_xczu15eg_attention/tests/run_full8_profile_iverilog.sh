#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 PROJECT_ROOT BUILD_DIR" >&2
    exit 2
fi
project_root=$1
build_dir=$2
package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$build_dir"
(
    cd "$project_root"
    find rtl/core -type f \( -name '*.v' -o -name '*.sv' \) \
        -print | LC_ALL=C sort > "$build_dir/rtl_files.txt"
    iverilog -g2012 -s tb_v30_full8_golden_profile \
        -o "$build_dir/v30_full8_profile.out" \
        -f "$build_dir/rtl_files.txt" \
        tb/sim_models/floating_point_behavioral.sv \
        "$package_root/tb/tb_v30_full8_golden_profile.sv"
)
ln -s "$project_root/mem" "$build_dir/mem"
ln -s "$project_root/vitis" "$build_dir/vitis"
(
    cd "$build_dir"
    vvp ./v30_full8_profile.out
)
