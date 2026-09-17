#!/bin/bash
# 60_mixed.sh - 70/30 混合讀寫（沿用舊版邏輯，含 --sync=1，貼近 Fabric 讀寫交錯 + fsync 的實際型態）。
# 依賴 common.sh / fiorun.sh 已被 source。

phase_60_mixed() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 60: 70/30 混合讀寫"

    local file="${DATASET_MOUNT}/mixed_test.dat"

    run_fio_test "mixed_7030" "$outdir" \
        --ioengine=psync --rw=randrw --rwmixread=70 --bs=4K --numjobs=4 --iodepth=1 --sync=1 \
        --filename="$file" --size="${MIXED_TEST_SIZE_MIB}M" \
        --time_based --runtime="$RUNTIME_MIXED" \
        --group_reporting --randrepeat=0 --norandommap \
        || log_warn "mixed_7030 回傳非零狀態，繼續流程"

    log_info "Phase 60 完成"
}
