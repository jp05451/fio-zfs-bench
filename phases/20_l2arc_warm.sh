#!/bin/bash
# 20_l2arc_warm.sh - 暫時調高 l2arc_write_max，對 T2（落在 L2ARC 量級的 tier）
# 做持續隨機讀，讓資料透過 ARC 淘汰佇列被餵進 L2ARC。結束後把 l2arc_write_max 還原。
# 依賴 common.sh / fiorun.sh 已被 source。

phase_20_l2arc_warm() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 20: L2ARC 暖機"

    if [[ ! " ${TIER_NAMES[*]} " == *" t2 "* ]]; then
        log_warn "TIER_NAMES 中沒有 t2，略過 L2ARC 暖機"
        return 0
    fi

    local warm_file orig_write_max
    warm_file=$(tier_file "t2")
    orig_write_max=$(cat "$L2ARC_WRITE_MAX_PARAM")

    log_info "暫時調高 l2arc_write_max: ${orig_write_max} -> ${L2ARC_WRITE_MAX_WARM_BYTES}"
    if ! echo "$L2ARC_WRITE_MAX_WARM_BYTES" > "$L2ARC_WRITE_MAX_PARAM"; then
        record_failure "20_l2arc_warm" "調整 l2arc_write_max 失敗，略過本次 L2ARC 暖機"
        return 1
    fi

    run_fio_test "l2arc_warm" "$outdir" \
        --ioengine=psync --rw=randread --bs=4K --numjobs=4 --iodepth=1 \
        --filename="$warm_file" \
        --time_based --runtime="$L2ARC_WARM_DURATION" \
        --group_reporting --randrepeat=0 --norandommap \
        || log_warn "L2ARC 暖機測試回傳非零狀態，繼續流程"

    log_info "還原 l2arc_write_max: ${L2ARC_WRITE_MAX_WARM_BYTES} -> ${orig_write_max}"
    echo "$orig_write_max" > "$L2ARC_WRITE_MAX_PARAM" \
        || log_warn "還原 l2arc_write_max 失敗，請手動執行: echo $orig_write_max > $L2ARC_WRITE_MAX_PARAM"

    awk '/^l2_asize/{printf "l2_asize after warm = %.2f GiB\n", $3/1073741824}' "$ARCSTATS_PATH" \
        | tee "${outdir}/l2arc_warm_result.txt"

    log_info "Phase 20 完成"
}
