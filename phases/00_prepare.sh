#!/bin/bash
# 00_prepare.sh - 建立/確保專用測試 dataset 存在，設定 atime=off compression=off。
# recordsize 沿用父 dataset (128K)，因為要反映生產組態的真實 recordsize。
# 依賴 common.sh 已被 source。

phase_00_prepare() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 00: 準備測試 dataset $DATASET"

    if zfs list "$DATASET" >/dev/null 2>&1; then
        log_info "dataset $DATASET 已存在，僅確認屬性"
    else
        log_info "建立 dataset $DATASET"
        if ! zfs create "$DATASET"; then
            record_failure "00_prepare:create" "建立 dataset $DATASET 失敗，本輪後續 phase 可能大量失敗，但仍繼續嘗試"
            return 1
        fi
    fi

    zfs set atime=off "$DATASET" || record_failure "00_prepare:atime" "設定 atime=off 失敗"
    zfs set compression=off "$DATASET" || record_failure "00_prepare:compression" "設定 compression=off 失敗"
    zfs set primarycache=all "$DATASET" || record_failure "00_prepare:primarycache" "設定 primarycache=all 失敗"
    zfs set secondarycache=all "$DATASET" || record_failure "00_prepare:secondarycache" "設定 secondarycache=all 失敗"
    zfs set sync=standard "$DATASET" || record_failure "00_prepare:sync" "設定 sync=standard 失敗"

    {
        echo "dataset properties after phase 00:"
        zfs get atime,compression,primarycache,secondarycache,sync,recordsize,mountpoint "$DATASET"
    } | tee "${outdir}/00_prepare.log"

    log_info "Phase 00 完成"
}
