#!/bin/bash
# 70_slog.sh - SLOG 貢獻度測試（強化版）：
#   1. 屬性法 + 拔除法：sync=standard / sync=disabled / 拔除 SLOG 三種組態，
#      每種各自用獨立檔案重複跑 SLOG_REPEATS 次，且執行順序打亂，
#      避免「同檔案序列污染」與「固定執行順序偏差」混進「有沒有 SLOG」這個變數裡。
#   2. 裸裝置基準線：拔除 SLOG 後直接對其 partition 跑 fio，量測不經過 ZFS 的
#      硬體本身 fsync 延遲，用來交叉驗證 ZFS 層量到的 SLOG 貢獻數字合不合理。
# 拔除/裝回為線上可逆操作，SLOG 內容不需保留（只是加速器，裝回後 ZFS 視為全新
# log 裝置使用）。除了此處每次拔除後立即裝回，run_all.sh 的全域 trap 也會在
# 任何中斷/崩潰時再次確認 SLOG 已裝回（雙重保險）。
# 依賴 common.sh / fiorun.sh 已被 source；_wait_zvol_links_ready 定義於
# 40_coldhot.sh，run_all.sh 會把兩者都 source 進同一個 shell。

phase_70_slog() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 70: SLOG 貢獻度測試"

    local -a jobs=()
    local cond rep
    for cond in standard disabled removed; do
        for (( rep = 1; rep <= SLOG_REPEATS; rep++ )); do
            jobs+=("${cond}_r${rep}")
        done
    done
    # 打亂執行順序，避免「永遠先跑/後跑」本身造成的偏差混進「有沒有 SLOG」這個變數裡
    mapfile -t jobs < <(printf '%s\n' "${jobs[@]}" | shuf)
    log_info "本次 SLOG 測試順序（已打亂）: ${jobs[*]}"

    local job
    for job in "${jobs[@]}"; do
        _run_slog_job "$job" "$outdir"
    done

    _run_slog_raw_device_baseline "$outdir"

    log_info "Phase 70 完成"
}

# _run_slog_job <cond_rN> <outdir> - cond 為 standard/disabled/removed
_run_slog_job() {
    local job="$1" outdir="$2"
    local cond="${job%_r*}"
    local file="${DATASET_MOUNT}/slog_${job}.dat"
    local fio_args=(
        --ioengine=psync --rw=randwrite --bs=4K --numjobs=4 --iodepth=1 --sync=1
        --filename="$file" --size="${SLOG_TEST_SIZE_MIB}M"
        --time_based --runtime="$RUNTIME_SLOG"
        --group_reporting --randrepeat=0 --norandommap
    )

    case "$cond" in
        standard)
            log_info "組態 ${job}: sync=standard（走 SLOG）"
            if zfs set sync=standard "$DATASET"; then
                run_fio_test "slog_${job}" "$outdir" "${fio_args[@]}" \
                    || log_warn "slog_${job} 回傳非零狀態，繼續流程"
            else
                record_failure "70_slog:${job}" "設定 sync=standard 失敗，跳過此組態"
            fi
            ;;
        disabled)
            log_info "組態 ${job}: sync=disabled（不走 ZIL，理論上限）"
            if zfs set sync=disabled "$DATASET"; then
                run_fio_test "slog_${job}" "$outdir" "${fio_args[@]}" \
                    || log_warn "slog_${job} 回傳非零狀態，繼續流程"
            else
                record_failure "70_slog:${job}" "設定 sync=disabled 失敗，跳過此組態"
            fi
            zfs set sync=standard "$DATASET" \
                || record_failure "70_slog:${job}:restore_sync" "還原 sync=standard 失敗，請人工確認 $DATASET 的 sync 屬性"
            ;;
        removed)
            log_info "組態 ${job}: 拔除 SLOG 裝置 $SLOG_DEVICE"
            if zfs set sync=standard "$DATASET" && zpool remove "$POOL" "$SLOG_DEVICE"; then
                _wait_slog_removed || log_warn "等待 SLOG 移除逾時，仍繼續執行測試"

                run_fio_test "slog_${job}" "$outdir" "${fio_args[@]}" \
                    || log_warn "slog_${job} 回傳非零狀態，繼續流程"

                log_info "測試結束，裝回 SLOG 裝置"
                if ! zpool add "$POOL" log "$SLOG_DEVICE"; then
                    die "SLOG 裝回失敗！請立即手動執行: zpool add $POOL log $SLOG_DEVICE"
                fi
                log_info "SLOG 裝置已裝回"
                _wait_zvol_links_ready \
                    || log_warn "zvol 裝置連結逾時未出現，請人工確認 /dev/zvol/${POOL}/"
            else
                record_failure "70_slog:${job}" "設定 sync=standard 或移除 SLOG 裝置失敗，略過此次拔除法測試"
            fi
            ;;
    esac

    rm -f "$file"
}

_wait_slog_removed() {
    local tries=15
    while (( tries-- > 0 )); do
        zpool status "$POOL" | grep -q "$SLOG_DEVICE" || return 0
        sleep 2
    done
    return 1
}

# 拔除 SLOG 後直接對其 partition 跑 fio，量測不經過 ZFS 的硬體本身 fsync 延遲，
# 用來交叉驗證上面 ZFS 層量到的 SLOG 貢獻數字合不合理。完全不影響 pool 資料
# （SLOG 內容不需保留，裝回後 ZFS 直接視為全新 log 裝置使用）。
_run_slog_raw_device_baseline() {
    local outdir="$1"
    local raw_dev="/dev/disk/by-id/${SLOG_DEVICE}"

    log_info "裸裝置基準線: 拔除 SLOG 裝置 $SLOG_DEVICE 以量測其硬體本身 fsync 延遲"

    if [[ ! -b "$raw_dev" ]]; then
        record_failure "70_slog:raw_device" "找不到裝置節點 $raw_dev，略過裸裝置基準線測試"
        return
    fi

    if ! zpool remove "$POOL" "$SLOG_DEVICE"; then
        record_failure "70_slog:raw_device" "移除 SLOG 裝置失敗，略過裸裝置基準線測試"
        return
    fi
    _wait_slog_removed || log_warn "等待 SLOG 移除逾時，仍繼續執行裸裝置測試"

    # 二次確認裝置確實已脫離 pool，避免 fio 與 ZFS 同時寫入同一裝置造成衝突
    if zpool status "$POOL" | grep -q "$SLOG_DEVICE"; then
        record_failure "70_slog:raw_device" "SLOG 裝置移除後仍出現在 zpool status，為安全起見取消裸裝置測試"
    else
        run_fio_test "slog_raw_device" "$outdir" \
            --ioengine=psync --direct=1 --rw=randwrite --bs=4K --numjobs=1 --iodepth=1 --sync=1 \
            --filename="$raw_dev" --size="${SLOG_TEST_SIZE_MIB}M" \
            --time_based --runtime="$RUNTIME_SLOG_RAW" \
            --group_reporting --randrepeat=0 --norandommap \
            || log_warn "slog_raw_device 回傳非零狀態，繼續流程"
    fi

    log_info "測試結束，裝回 SLOG 裝置"
    if ! zpool add "$POOL" log "$SLOG_DEVICE"; then
        die "SLOG 裝回失敗！請立即手動執行: zpool add $POOL log $SLOG_DEVICE"
    fi
    log_info "SLOG 裝置已裝回"
    _wait_zvol_links_ready \
        || log_warn "zvol 裝置連結逾時未出現，請人工確認 /dev/zvol/${POOL}/"
}
