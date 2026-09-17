#!/bin/bash
# vmctl.sh - 停機/復原 VM。絕不觸碰 NEVER_TOUCH_VMS。
# 依賴 common.sh 已被 source（含 scan_iscsi_vms/_in_array）。

# 動態掃描目前用到 $ISCSI_STORAGE_ID 的 VM，停止其中「目前確實在跑」的，等待完全關機。
# 停 VM 失敗/逾時屬安全關鍵：export 前必須確保全部關機，故此處仍用 die 立即中止（尚未開始跑測試，成本低）。
stop_vms() {
    log_section "掃描並停止使用 ${ISCSI_STORAGE_ID} 的 VM"
    local vmid status vmids
    vmids=$(scan_iscsi_vms)
    if [[ -z "$vmids" ]]; then
        log_warn "掃描結果沒有任何 VM 使用 ${ISCSI_STORAGE_ID}，請確認 storage ID 是否正確"
    fi
    for vmid in $vmids; do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        if [[ "$status" != "running" ]]; then
            log_info "VM $vmid 目前狀態為 '$status'，略過"
            continue
        fi
        log_info "停止 VM $vmid ..."
        qm stop "$vmid" || die "停止 VM $vmid 失敗（安全關鍵：export 前必須確保所有 VM 已關機）"
        _wait_vm_stopped "$vmid" || die "VM $vmid 逾時仍未停止（安全關鍵）"
        log_info "VM $vmid 已停止"
    done
}

_wait_vm_stopped() {
    local vmid="$1" tries=30 status
    while (( tries-- > 0 )); do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        [[ "$status" == "stopped" ]] && return 0
        sleep 2
    done
    return 1
}

_wait_vm_running() {
    local vmid="$1" tries=30 status
    while (( tries-- > 0 )); do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        [[ "$status" == "running" ]] && return 0
        sleep 2
    done
    return 1
}

# 只啟動「本次由腳本停掉」的 VM 清單（由 state.sh 傳入 ORIG_RUNNING_VMS，
# 該清單在開跑前由 scan_iscsi_vms 動態掃描產生，只含當時「確實在跑」的 VM）。
# 絕不啟動 NEVER_TOUCH_VMS，也絕不啟動未在傳入清單中的 VM。
restore_vms() {
    local orig_running_vms="${1:-}"
    if [[ -z "$orig_running_vms" ]]; then
        log_info "沒有需要復原的 VM（原本就沒有 VM 因本次測試而停機）"
        return 0
    fi

    log_section "復原原本運行中的 VM"
    local vmid
    for vmid in $orig_running_vms; do
        if _in_array "$vmid" "${NEVER_TOUCH_VMS[@]}"; then
            log_warn "VM $vmid 屬於『絕不觸碰』白名單，拒絕啟動（安全防呆觸發，請人工檢查狀態檔）"
            continue
        fi
        log_info "啟動 VM $vmid ..."
        qm start "$vmid" || { log_error "啟動 VM $vmid 失敗，請人工檢查"; continue; }
        _wait_vm_running "$vmid" || log_warn "VM $vmid 啟動指令已送出，但逾時未見 running 狀態，請人工確認"
        log_info "VM $vmid 已啟動"
    done
}
