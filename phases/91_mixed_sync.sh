#!/bin/bash
# 91_mixed_sync.sh - 讀寫混合下的 SLOG 價值（--diag2 模式）。
# 動機：Phase 90 只有 sync 寫入，且 NAS 完全沒有其他負載。真實環境中，讀取未命中會打到
# 只有約 64 IOPS 的後端 LUN 並排隊；沒有 SLOG 時 ZIL 也要寫進同一顆後端，sync 寫入延遲
# 會被讀取的排隊拖垮。有 SLOG 時 ZIL 在本機 NVMe，不受後端排隊影響。這個測試同時跑
#   mix_read  : MIXSYNC_READERS 個隨機讀者，打向大檔（拆掉 L2ARC + 冷 ARC，讀取幾乎都未命中）
#   mix_write : MIXSYNC_WRITERS 個 sync 隨機寫者
# 比較 standard（有 SLOG）與 removed（拔除 SLOG），各重複、順序打亂，兩組讀寫指標同時記錄。
# 依賴 common.sh / fiorun.sh / monitor.sh / arcstats.sh / l2arc.sh 已被 source；
# iso2_file 定義於 80_iso2.sh、_export_import_pool / _wait_zvol_links_ready 定義於 40_coldhot.sh、
# _wait_slog_removed 定義於 70_slog.sh，run_all.sh 會把它們 source 進同一個 shell。

phase_91_mixed_sync() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 91: 讀寫混合 sync 寫入（有無 SLOG）"

    local rfile
    rfile=$(iso2_file)
    if [[ ! -f "$rfile" ]]; then
        record_failure "91_mixed_sync" "找不到讀取用測試檔 $rfile，略過本 phase"
        return 1
    fi

    # 拆掉 L2ARC，讀取才會確實打到後端而不是被 NVMe 吸收
    if ! l2arc_detach; then
        record_failure "91_mixed_sync" "移除 L2ARC 裝置失敗，讀取無法保證打到後端，略過本 phase"
        return 1
    fi

    local -a runs=()
    local cond rep
    for cond in standard removed; do
        for (( rep = 1; rep <= MIXSYNC_REPEATS; rep++ )); do
            runs+=("${cond}:${rep}")
        done
    done
    mapfile -t runs < <(printf '%s\n' "${runs[@]}" | shuf)
    log_info "本次讀寫混合測試順序（已打亂，格式 組態:重複編號）: ${runs[*]}"

    local run
    for run in "${runs[@]}"; do
        _mixsync_run "${run%%:*}" "${run##*:}" "$rfile" "$outdir"
    done

    l2arc_attach || die "L2ARC 裝回失敗！請立即手動執行: zpool add $POOL cache $L2ARC_DEVICE"
    log_info "Phase 91 完成"
}

# _mixsync_run <standard|removed> <rep> <read_file> <outdir>
_mixsync_run() {
    local cond="$1" rep="$2" rfile="$3" outdir="$4"
    local name="mixsync_${cond}_r${rep}"
    local wfile="${DATASET_MOUNT}/${name}_w.dat"

    # 每次都從冷 ARC 開始，讀取才會確實打到後端
    if ! _export_import_pool "$name"; then
        record_failure "91_mixed_sync:${name}" "export/import 失敗，略過此次測試"
        return 1
    fi
    if ! zfs set sync=standard "$DATASET"; then
        record_failure "91_mixed_sync:${name}" "設定 sync=standard 失敗，略過此次測試"
        return 1
    fi
    sleep "$SETTLE_AFTER_IMPORT"

    if [[ "$cond" == "removed" ]]; then
        log_info "組態 ${name}: 拔除 SLOG 裝置 $SLOG_DEVICE"
        if ! zpool remove "$POOL" "$SLOG_DEVICE"; then
            record_failure "91_mixed_sync:${name}" "移除 SLOG 裝置失敗，略過此次拔除法測試"
            return 1
        fi
        _wait_slog_removed || log_warn "等待 SLOG 移除逾時，仍繼續執行測試"
    else
        log_info "組態 ${name}: sync=standard（走 SLOG）"
    fi

    _mixsync_fio "$name" "$rfile" "$wfile" "$outdir" \
        || log_warn "${name} 回傳非零狀態，繼續流程"
    rm -f "$wfile"

    if [[ "$cond" == "removed" ]]; then
        log_info "測試結束，裝回 SLOG 裝置"
        if ! zpool add "$POOL" log "$SLOG_DEVICE"; then
            die "SLOG 裝回失敗！請立即手動執行: zpool add $POOL log $SLOG_DEVICE"
        fi
        log_info "SLOG 裝置已裝回"
        _wait_zvol_links_ready \
            || log_warn "zvol 裝置連結逾時未出現，請人工確認 /dev/zvol/${POOL}/"
    fi
}

# 兩組工作同時跑（fio 兩個 group，json 內 jobs[0]=讀取者、jobs[1]=寫入者）。
# 不能用 run_fio_test：它會在參數尾端自動追加 --name，會變成多出第三個無參數的 job。
_mixsync_fio() {
    local name="$1" rfile="$2" wfile="$3" outdir="$4"

    log_info "開始測試: $name (outdir=$outdir)"
    snapshot_arcstats "${outdir}/${name}.arcstats_pre"
    start_monitor "$outdir" "$name"

    local rc=0
    fio --ioengine=psync --bs=4K --iodepth=1 --time_based --runtime="$RUNTIME_MIXSYNC" \
        --randrepeat=0 --norandommap --group_reporting \
        --name=mix_read --new_group --rw=randread --numjobs="$MIXSYNC_READERS" \
            --filename="$rfile" --size="${ISO2_SIZE_MIB}M" \
        --name=mix_write --new_group --rw=randwrite --sync=1 --numjobs="$MIXSYNC_WRITERS" \
            --filename="$wfile" --size="${SLOG_TEST_SIZE_MIB}M" \
        --output-format=json+ --output="${outdir}/${name}.json" \
        || rc=$?

    stop_monitor
    snapshot_arcstats "${outdir}/${name}.arcstats_post"

    if (( rc != 0 )); then
        log_error "fio 測試 $name 回傳非零狀態碼: $rc"
    else
        log_info "測試完成: $name"
    fi
    return "$rc"
}
