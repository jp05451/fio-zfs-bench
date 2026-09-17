#!/bin/bash
# preflight.sh - 執行測試前的所有安全檢查。任何一項失敗就中止，不自動修復。
# 依賴 common.sh 已被 source。

# 檢查沒有其他 fio 行程在跑（本次事故的直接教訓：舊 benchmark 曾在探索期間仍在執行）
preflight_no_other_fio() {
    local running
    running=$(pgrep -x fio 2>/dev/null || true)
    if [[ -n "$running" ]]; then
        die "偵測到其他 fio 行程正在執行 (PID: $running)，請先確認並停止後再重試"
    fi
    log_info "PASS: 無其他 fio 行程在跑"
}

# 檢查 pool 健康狀態
preflight_pool_healthy() {
    local state
    state=$(zpool list -H -o health "$POOL" 2>/dev/null) || die "無法查詢 zpool $POOL 狀態"
    if [[ "$state" != "ONLINE" ]]; then
        die "zpool $POOL 狀態為 $state，非 ONLINE，中止"
    fi
    local health_msg
    health_msg=$(zpool status -x "$POOL")
    if [[ "$health_msg" != "pool '${POOL}' is healthy" ]]; then
        die "zpool status -x 回報異常: $health_msg；中止，請人工確認"
    fi
    log_info "PASS: zpool $POOL 為 ONLINE 且無異常 vdev ($health_msg)"
}

# 檢查掛載狀態
preflight_mount_ok() {
    if ! mount | grep -q " /${POOL} "; then
        die "$POOL 掛載點未在 mount 清單中找到，中止"
    fi
    local testfile="/${POOL}/.fio_preflight_write_test"
    if ! touch "$testfile" 2>/dev/null; then
        die "無法在 /${POOL} 寫入測試檔，掛載可能非可寫，中止"
    fi
    rm -f "$testfile"
    log_info "PASS: $POOL 已掛載且可寫"
}

# 檢查可用空間
preflight_space_ok() {
    local avail_bytes avail_gib
    avail_bytes=$(zfs get -Hp -o value avail "$POOL")
    avail_gib=$(( avail_bytes / 1024 / 1024 / 1024 ))
    if (( avail_gib < MIN_AVAIL_GIB )); then
        die "可用空間僅 ${avail_gib} GiB，低於門檻 ${MIN_AVAIL_GIB} GiB，中止"
    fi
    log_info "PASS: 可用空間 ${avail_gib} GiB >= ${MIN_AVAIL_GIB} GiB"
}

# 檢查必要工具存在
preflight_tools_ok() {
    local tool
    for tool in fio arcstat zpool zfs python3 qm; do
        command -v "$tool" >/dev/null 2>&1 || die "找不到必要工具: $tool"
    done
    [[ -r "$ARCSTATS_PATH" ]] || die "無法讀取 $ARCSTATS_PATH"
    log_info "PASS: 所有必要工具存在"
}

# 檢查 arc_max 可寫
preflight_arc_tunable_ok() {
    [[ -w "$ARC_MAX_PARAM" ]] || die "$ARC_MAX_PARAM 不可寫，無法執行 ARC 兩輪對照"
    log_info "PASS: $ARC_MAX_PARAM 可寫"
}

# 檢查 nas-zfs-pool 上無任何運行中的 VM（export/import 的必要條件）
# VM 清單為動態掃描（見 common.sh scan_iscsi_vms），不是寫死清單。
preflight_no_vm_running_on_pool() {
    local vmid status
    for vmid in $(scan_iscsi_vms); do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        if [[ "$status" == "running" ]]; then
            die "VM $vmid 仍在運行，export 前必須先停機（應由 vmctl.sh 處理，此處為最終確認失敗）"
        fi
    done
    log_info "PASS: 測試池上所有應停機 VM 均已停機"
}

# 基本 preflight（不含 VM 檢查，供 --preflight-only 與跑測試前的第一關使用）
run_preflight_basic() {
    log_section "Preflight 基本檢查"
    preflight_no_other_fio
    preflight_pool_healthy
    preflight_mount_ok
    preflight_space_ok
    preflight_tools_ok
    preflight_arc_tunable_ok
    log_info "Preflight 基本檢查全部通過"
}

# export 前的最終確認（VM 已停機之後呼叫）
run_preflight_export_ready() {
    log_section "Preflight export 前確認"
    preflight_no_vm_running_on_pool
    log_info "Preflight export 前確認通過"
}
