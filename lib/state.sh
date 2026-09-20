#!/bin/bash
# state.sh - 記錄原始組態並在結束/中斷時還原。
# 依賴 common.sh 已被 source。狀態檔落地於 $STATE_DIR/original.env，
# 即使 process 被殺掉、甚至機器重開機，也能用同一份檔案手動還原。

STATE_FILE="${STATE_DIR}/original.env"

# 開跑前呼叫一次：把當下的原始組態寫入狀態檔
save_state() {
    mkdir -p "$STATE_DIR"

    local orig_arc_max orig_l2_write_max orig_l2_noprefetch orig_running_vms slog_present

    orig_arc_max=$(cat "$ARC_MAX_PARAM")
    orig_l2_write_max=$(cat "$L2ARC_WRITE_MAX_PARAM")
    orig_l2_noprefetch=$(cat "$L2ARC_NOPREFETCH_PARAM" 2>/dev/null || echo "")

    orig_running_vms=""
    local vmid status
    for vmid in $(scan_iscsi_vms); do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        if [[ "$status" == "running" ]]; then
            orig_running_vms="${orig_running_vms} ${vmid}"
        fi
    done

    if zpool status "$POOL" | grep -q "$SLOG_DEVICE"; then
        slog_present=1
    else
        slog_present=0
    fi

    cat > "$STATE_FILE" <<EOF
ORIG_ARC_MAX=${orig_arc_max}
ORIG_L2ARC_WRITE_MAX=${orig_l2_write_max}
ORIG_RUNNING_VMS="${orig_running_vms# }"
ORIG_SLOG_PRESENT=${slog_present}
ORIG_L2ARC_NOPREFETCH=${orig_l2_noprefetch}
ORIG_L2ARC_DEVICE=${L2ARC_DEVICE}
STATE_SAVED_AT="$(_ts)"
EOF
    log_info "原始組態已記錄於 $STATE_FILE"
    cat "$STATE_FILE"
}

# 讀回狀態檔到目前 shell（供 restore 或其他模組查詢原始值使用）
load_state() {
    [[ -f "$STATE_FILE" ]] || die "找不到狀態檔 $STATE_FILE，無法還原"
    # shellcheck source=/dev/null
    source "$STATE_FILE"
}

# trap 呼叫的還原函式：把 arc_max / l2arc_write_max / VM 運行狀態 / SLOG 全部還原
restore_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        log_warn "找不到狀態檔，略過還原（可能尚未執行到 save_state）"
        return 0
    fi
    load_state

    log_section "還原原始組態"

    if [[ -w "$ARC_MAX_PARAM" ]]; then
        echo "$ORIG_ARC_MAX" > "$ARC_MAX_PARAM" 2>/dev/null \
            && log_info "zfs_arc_max 已還原為 $ORIG_ARC_MAX" \
            || log_warn "還原 zfs_arc_max 失敗，請手動執行: echo $ORIG_ARC_MAX > $ARC_MAX_PARAM"
    fi

    if [[ -w "$L2ARC_WRITE_MAX_PARAM" ]]; then
        echo "$ORIG_L2ARC_WRITE_MAX" > "$L2ARC_WRITE_MAX_PARAM" 2>/dev/null \
            && log_info "l2arc_write_max 已還原為 $ORIG_L2ARC_WRITE_MAX" \
            || log_warn "還原 l2arc_write_max 失敗，請手動執行: echo $ORIG_L2ARC_WRITE_MAX > $L2ARC_WRITE_MAX_PARAM"
    fi

    if [[ -n "${ORIG_L2ARC_NOPREFETCH:-}" && -w "$L2ARC_NOPREFETCH_PARAM" ]]; then
        echo "$ORIG_L2ARC_NOPREFETCH" > "$L2ARC_NOPREFETCH_PARAM" 2>/dev/null \
            && log_info "l2arc_noprefetch 已還原為 $ORIG_L2ARC_NOPREFETCH" \
            || log_warn "還原 l2arc_noprefetch 失敗，請手動執行: echo $ORIG_L2ARC_NOPREFETCH > $L2ARC_NOPREFETCH_PARAM"
    fi

    # 診斷模式會暫時拆掉 L2ARC（cache）裝置，中斷時務必裝回
    if [[ -n "${ORIG_L2ARC_DEVICE:-}" ]]; then
        local pool_status
        pool_status=$(zpool status "$POOL" 2>/dev/null)
        if [[ "$pool_status" != *"$ORIG_L2ARC_DEVICE"* ]]; then
            log_warn "L2ARC 裝置原本存在但目前不在 pool 中，嘗試裝回"
            zpool add "$POOL" cache "$ORIG_L2ARC_DEVICE" \
                && log_info "L2ARC 裝置已裝回" \
                || log_error "L2ARC 裝回失敗！請立即手動執行: zpool add $POOL cache $ORIG_L2ARC_DEVICE"
        fi
    fi

    if [[ "$ORIG_SLOG_PRESENT" == "1" ]] && ! zpool status "$POOL" | grep -q "$SLOG_DEVICE"; then
        log_warn "SLOG 裝置原本存在但目前不在 pool 中，嘗試裝回"
        zpool add "$POOL" log "$SLOG_DEVICE" \
            && log_info "SLOG 裝置已裝回" \
            || log_error "SLOG 裝回失敗！請立即手動執行: zpool add $POOL log $SLOG_DEVICE"
    fi

    restore_vms "$ORIG_RUNNING_VMS"

    log_info "組態還原流程結束"
}
