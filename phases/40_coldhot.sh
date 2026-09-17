#!/bin/bash
# 40_coldhot.sh - 對每個 tier 用 zpool export/import 保證 ARC 完全清空，
# 做 1 次冷讀 + 立刻 3 次熱讀重複讀取，量化 ARC/L2ARC 命中對延遲與 IOPS 的影響。
# 前提：呼叫前 nas-zfs-pool 上所有 VM 已停機（run_all.sh 於流程開頭確保）。
# 依賴 common.sh / fiorun.sh 已被 source。

phase_40_coldhot() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 40: 冷讀 / 熱讀對照"

    local tier file
    for tier in "${TIER_NAMES[@]}"; do
        file=$(tier_file "$tier")
        log_info "tier=$tier 開始 export/import 清空 ARC"

        if ! _export_import_pool "$tier"; then
            record_failure "40_coldhot:${tier}" "export/import 失敗，跳過此 tier 的冷熱讀對照，繼續下一個"
            continue
        fi

        log_info "沉澱 ${SETTLE_AFTER_IMPORT}s（L2ARC 索引重建）"
        sleep "$SETTLE_AFTER_IMPORT"

        run_fio_test "coldhot_${tier}_cold" "$outdir" \
            --ioengine=psync --rw=randread --bs=4K --numjobs=4 --iodepth=1 \
            --filename="$file" \
            --time_based --runtime="$RUNTIME_COLDHOT" \
            --group_reporting --randrepeat=0 --norandommap \
            || log_warn "coldhot_${tier}_cold 回傳非零狀態，繼續流程"

        local i
        for i in 1 2 3; do
            run_fio_test "coldhot_${tier}_hot${i}" "$outdir" \
                --ioengine=psync --rw=randread --bs=4K --numjobs=4 --iodepth=1 \
                --filename="$file" \
                --time_based --runtime="$RUNTIME_COLDHOT" \
                --group_reporting --randrepeat=0 --norandommap \
                || log_warn "coldhot_${tier}_hot${i} 回傳非零狀態，繼續流程"
        done
    done

    log_info "Phase 40 完成"
}

# export 後 import 回來；import 成功後等待 zvol 裝置連結重新出現（udev 非同步建立，
# 過去曾在這裡漏掉等待，導致測試結束後 VM 復原階段找不到 /dev/zvol/... 而啟動失敗，見事故紀錄）。
# export 失敗：pool 應仍維持原本已 import 狀態，記錄後回傳 1 讓呼叫端跳過該 tier。
# import 重試多次仍失敗：pool 可能處於不可用狀態，屬安全關鍵，直接 die 要求人工立即介入。
_export_import_pool() {
    local tier="${1:-}"
    # 避免 cwd 落在即將 export 的掛載點內導致 device busy
    cd / || { record_failure "40_coldhot:${tier}" "cd / 失敗"; return 1; }

    if ! zpool export "$POOL"; then
        record_failure "40_coldhot:${tier}" "zpool export 失敗，pool 應仍維持原本已 import 狀態"
        return 1
    fi

    local tries=3 i
    for (( i = 1; i <= tries; i++ )); do
        if zpool import "$POOL"; then
            _wait_zvol_links_ready \
                || record_failure "40_coldhot:${tier}" "zvol 裝置連結逾時未出現，後續若需啟動掛在此 pool 上的 VM 可能失敗，請人工確認 /dev/zvol/${POOL}/"
            return 0
        fi
        log_warn "zpool import 第 ${i}/${tries} 次失敗，3 秒後重試"
        sleep 3
    done

    die "zpool export 已執行但重試 ${tries} 次 import 皆失敗，pool 可能處於不可用狀態，必須立即人工介入: zpool import ${POOL}"
}

# 輪詢等待 zvol 裝置連結目錄重新出現（zpool import 後 udev 非同步建立，需要等待）。
_wait_zvol_links_ready() {
    local tries=30
    udevadm settle --timeout=10 2>/dev/null || true
    while (( tries-- > 0 )); do
        [[ -d "/dev/zvol/${POOL}" ]] && return 0
        sleep 2
    done
    return 1
}
