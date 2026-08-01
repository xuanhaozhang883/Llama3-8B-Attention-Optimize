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

rtl_list="$build_dir/rtl_files.txt"
(
    cd "$project_root"
    find rtl/core -type f \( -name '*.v' -o -name '*.sv' \) \
        -print | LC_ALL=C sort > "$rtl_list"
    iverilog -g2012 \
        -s tb_v30_online_attention_system_8gqa \
        -o "$build_dir/v30_8gqa_smoke.out" \
        -f "$rtl_list" \
        tb/sim_models/floating_point_behavioral.sv \
        "$package_root/tb/tb_v30_online_attention_system_8gqa.sv"
    vvp "$build_dir/v30_8gqa_smoke.out"
)
