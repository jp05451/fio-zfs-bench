#!/bin/bash
# 70_slog.sh - SLOG 貢獻度測試：
#   1. 屬性法：sync=standard（走 SLOG）vs sync=disabled（不走 ZIL，理論上限）
#   2. 拔除法：暫時移除 SLOG 裝置，量測 ZIL 落在 iSCSI LUN 上的效能，測完裝回。
# 拔除/裝回為線上可逆操作。除了此處的立即裝回，run_all.sh 的全域 trap
# 也會在任何中斷/崩潰時再次確認 SLOG 已裝回（雙重保險）。
# 依賴 common.sh / fiorun.sh 已被 source。

phase_70_slog() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 70: SLOG 貢獻度測試"

    local file="${DATASET_MOUNT}/slog_test.dat"
    local fio_write_args=(
        --ioengine=psync --rw=randwrite --bs=4K --numjobs=4 --iodepth=1 --sync=1
        --filename="$file" --size="${SLOG_TEST_SIZE_MIB}M"
        --time_based --runtime="$RUNTIME_SLOG"
        --group_reporting --randrepeat=0 --norandommap
    )

    log_info "屬性法 1/2: sync=standard（走 SLOG）"
    if zfs set sync=standard "$DATASET"; then
        run_fio_test "slog_sync_standard" "$outdir" "${fio_write_args[@]}" \
            || log_warn "slog_sync_standard 回傳非零狀態，繼續流程"
    else
        record_failure "70_slog:sync_standard" "設定 sync=standard 失敗，跳過 slog_sync_standard 測試"
    fi

    log_info "屬性法 2/2: sync=disabled（不走 ZIL，理論上限）"
    if zfs set sync=disabled "$DATASET"; then
        run_fio_test "slog_sync_disabled" "$outdir" "${fio_write_args[@]}" \
            || log_warn "slog_sync_disabled 回傳非零狀態，繼續流程"
    else
        record_failure "70_slog:sync_disabled" "設定 sync=disabled 失敗，跳過 slog_sync_disabled 測試"
    fi

    zfs set sync=standard "$DATASET" \
        || record_failure "70_slog:restore_sync" "還原 sync=standard 失敗，請人工確認 $DATASET 的 sync 屬性"

    log_info "拔除法: 暫時移除 SLOG 裝置 $SLOG_DEVICE"
    if zpool remove "$POOL" "$SLOG_DEVICE"; then
        # zpool remove 為非同步，等待移除完成
        _wait_slog_removed || log_warn "等待 SLOG 移除逾時，仍繼續執行測試"

        run_fio_test "slog_removed_sync" "$outdir" "${fio_write_args[@]}" \
            || log_warn "slog_removed_sync 回傳非零狀態，繼續流程"

        log_info "測試結束，裝回 SLOG 裝置"
        if ! zpool add "$POOL" log "$SLOG_DEVICE"; then
            die "SLOG 裝回失敗！請立即手動執行: zpool add $POOL log $SLOG_DEVICE"
        fi
        log_info "SLOG 裝置已裝回"
        # _wait_zvol_links_ready 定義於 40_coldhot.sh，run_all.sh 會把兩者都 source 進同一個 shell
        _wait_zvol_links_ready \
            || log_warn "zvol 裝置連結逾時未出現，請人工確認 /dev/zvol/${POOL}/"
    else
        log_warn "移除 SLOG 裝置失敗，略過拔除法對照"
    fi

    log_info "Phase 70 完成"
}

_wait_slog_removed() {
    local tries=15
    while (( tries-- > 0 )); do
        zpool status "$POOL" | grep -q "$SLOG_DEVICE" || return 0
        sleep 2
    done
    return 1
}
