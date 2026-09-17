#!/bin/bash
# 30_isolation.sh - raw / arconly / full 三組態隨機讀（對 T2，L2ARC 量級的 tier）。
# ARC 貢獻 = arconly - raw；L2ARC 貢獻 = full - arconly（差分法，見計畫書）。
# 依賴 common.sh / fiorun.sh 已被 source。

phase_30_isolation() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 30: 快取層隔離矩陣 (raw/arconly/full)"

    local file
    file=$(tier_file "t2")

    _run_isolation_case "raw"     "none" "none" "$file" "$outdir" \
        || record_failure "30_isolation:raw" "raw 組態測試失敗，跳過，繼續下一組態"
    _run_isolation_case "arconly" "all"  "none" "$file" "$outdir" \
        || record_failure "30_isolation:arconly" "arconly 組態測試失敗，跳過，繼續下一組態"
    _run_isolation_case "full"    "all"  "all"  "$file" "$outdir" \
        || record_failure "30_isolation:full" "full 組態測試失敗"

    # 測試結束後恢復生產組態，供後續 phase 使用
    zfs set primarycache=all "$DATASET" || record_failure "30_isolation:restore" "還原 primarycache=all 失敗"
    zfs set secondarycache=all "$DATASET" || record_failure "30_isolation:restore" "還原 secondarycache=all 失敗"

    log_info "Phase 30 完成"
}

_run_isolation_case() {
    local label="$1" primarycache="$2" secondarycache="$3" file="$4" outdir="$5"

    log_info "組態=$label primarycache=$primarycache secondarycache=$secondarycache"
    if ! zfs set primarycache="$primarycache" "$DATASET"; then
        record_failure "30_isolation:$label" "設定 primarycache 失敗"
        return 1
    fi
    if ! zfs set secondarycache="$secondarycache" "$DATASET"; then
        record_failure "30_isolation:$label" "設定 secondarycache 失敗"
        return 1
    fi

    run_fio_test "isolation_${label}" "$outdir" \
        --ioengine=psync --rw=randread --bs=4K --numjobs=4 --iodepth=1 \
        --filename="$file" \
        --time_based --runtime="$RUNTIME_ISOLATION" \
        --group_reporting --randrepeat=0 --norandommap \
        || log_warn "isolation_${label} 測試回傳非零狀態，繼續流程"
}
