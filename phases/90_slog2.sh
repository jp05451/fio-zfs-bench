#!/bin/bash
# 90_slog2.sh - SLOG 併發度掃描（--diag 模式，只在 Round 2 跑，ARC 48GiB 讓測試檔全在記憶體）。
# 動機：Phase 70 在 4 併發下 standard(1470) ≈ removed(1492) ≈ SLOG 裸裝置(1653)，
# 代表 SLOG 已頂到自己的 flush 上限，而拔掉後 iSCSI 後端回應 sync 寫入一樣快。
# 這裡掃 numjobs，對每個併發度各量三種條件，看 SLOG 的價值是否隨併發度出現：
#   standard : sync=standard，SLOG 在位（走 SLOG）
#   removed  : 拔除 SLOG，ZIL 落回主 pool（iSCSI）
#   rawdev   : SLOG 分割區裸裝置，同併發度的硬體 flush 上限
# removed 與 rawdev 共用同一次拔除視窗，減少 pool 組態變動次數。
# 依賴 common.sh / fiorun.sh 已被 source；_wait_slog_removed 定義於 70_slog.sh，
# _wait_zvol_links_ready 定義於 40_coldhot.sh，run_all.sh 會把它們 source 進同一個 shell。

phase_90_slog2() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 90: SLOG 併發度掃描"

    local -a cycles=()
    local n rep
    for n in "${SLOG2_NUMJOBS[@]}"; do
        for (( rep = 1; rep <= SLOG2_REPEATS; rep++ )); do
            cycles+=("${n}:${rep}")
        done
    done
    # 打亂順序，避免固定的先後順序偏差
    mapfile -t cycles < <(printf '%s\n' "${cycles[@]}" | shuf)
    log_info "本次 SLOG 併發度測試順序（已打亂，格式 numjobs:重複編號）: ${cycles[*]}"

    local cycle
    for cycle in "${cycles[@]}"; do
        _slog2_run_cycle "${cycle%%:*}" "${cycle##*:}" "$outdir"
    done

    log_info "Phase 90 完成"
}

# _slog2_run_cycle <numjobs> <rep> <outdir>
# 一個週期 = standard 一次 + (拔除 SLOG → removed 一次 + rawdev 一次 → 裝回)。
# standard 與拔除視窗的先後順序隨機，避免順序偏差。
_slog2_run_cycle() {
    local n="$1" rep="$2" outdir="$3"

    if (( RANDOM % 2 == 0 )); then
        _slog2_standard "$n" "$rep" "$outdir"
        _slog2_removed_and_rawdev "$n" "$rep" "$outdir"
    else
        _slog2_removed_and_rawdev "$n" "$rep" "$outdir"
        _slog2_standard "$n" "$rep" "$outdir"
    fi
}

# 產生對 ZFS 檔案的 sync 隨機寫參數（每次用獨立檔案，避免序列污染），一行一個參數
_slog2_zfs_args() {
    local file="$1" n="$2"
    printf '%s\n' \
        --ioengine=psync --rw=randwrite --bs=4K --numjobs="$n" --iodepth=1 --sync=1 \
        --filename="$file" --size="${SLOG_TEST_SIZE_MIB}M" \
        --time_based --runtime="$RUNTIME_SLOG2" \
        --group_reporting --randrepeat=0 --norandommap
}

_slog2_standard() {
    local n="$1" rep="$2" outdir="$3"
    local name="slog2_standard_j${n}_r${rep}"
    local file="${DATASET_MOUNT}/${name}.dat"
    local -a args
    mapfile -t args < <(_slog2_zfs_args "$file" "$n")

    log_info "組態 ${name}: sync=standard（走 SLOG）"
    if zfs set sync=standard "$DATASET"; then
        run_fio_test "$name" "$outdir" "${args[@]}" \
            || log_warn "${name} 回傳非零狀態，繼續流程"
    else
        record_failure "90_slog2:${name}" "設定 sync=standard 失敗，跳過此組態"
    fi
    rm -f "$file"
}

_slog2_removed_and_rawdev() {
    local n="$1" rep="$2" outdir="$3"
    local name_rm="slog2_removed_j${n}_r${rep}" name_raw="slog2_rawdev_j${n}_r${rep}"
    local file="${DATASET_MOUNT}/${name_rm}.dat"
    local raw_dev="/dev/disk/by-id/${SLOG_DEVICE}"
    local -a args
    mapfile -t args < <(_slog2_zfs_args "$file" "$n")

    if [[ ! -b "$raw_dev" ]]; then
        record_failure "90_slog2:j${n}_r${rep}" "找不到裝置節點 $raw_dev，略過此週期的拔除/裸裝置測試"
        return
    fi

    log_info "週期 j${n}_r${rep}: 拔除 SLOG 裝置 $SLOG_DEVICE"
    if ! { zfs set sync=standard "$DATASET" && zpool remove "$POOL" "$SLOG_DEVICE"; }; then
        record_failure "90_slog2:j${n}_r${rep}" "設定 sync=standard 或移除 SLOG 裝置失敗，略過此週期的拔除/裸裝置測試"
        return
    fi
    _wait_slog_removed || log_warn "等待 SLOG 移除逾時，仍繼續執行測試"

    run_fio_test "$name_rm" "$outdir" "${args[@]}" \
        || log_warn "${name_rm} 回傳非零狀態，繼續流程"
    rm -f "$file"

    # 二次確認裝置確實已脫離 pool，避免 fio 與 ZFS 同時寫入同一裝置
    if zpool status "$POOL" | grep -q "$SLOG_DEVICE"; then
        record_failure "90_slog2:${name_raw}" "SLOG 裝置移除後仍出現在 zpool status，為安全起見取消裸裝置測試"
    else
        run_fio_test "$name_raw" "$outdir" \
            --ioengine=psync --direct=1 --rw=randwrite --bs=4K --numjobs="$n" --iodepth=1 --sync=1 \
            --filename="$raw_dev" --size="${SLOG_TEST_SIZE_MIB}M" \
            --time_based --runtime="$RUNTIME_SLOG2_RAW" \
            --group_reporting --randrepeat=0 --norandommap \
            || log_warn "${name_raw} 回傳非零狀態，繼續流程"
    fi

    log_info "測試結束，裝回 SLOG 裝置"
    if ! zpool add "$POOL" log "$SLOG_DEVICE"; then
        die "SLOG 裝回失敗！請立即手動執行: zpool add $POOL log $SLOG_DEVICE"
    fi
    log_info "SLOG 裝置已裝回"
    _wait_zvol_links_ready \
        || log_warn "zvol 裝置連結逾時未出現，請人工確認 /dev/zvol/${POOL}/"
}
