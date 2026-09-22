#!/bin/bash
# 92_arcsweep.sh - ARC 大小掃描（--diag2 模式）：L2ARC 暖好、熱資料集固定，只改 zfs_arc_max，
# 量隨機讀 IOPS 與命中分布，回答「ARC 該設多大」。
# 重點是 ARC 上限與熱資料集大小的「比例」，所以用固定的 DIAG2_ISO_SIZE_MIB 資料集掃 ARCSWEEP_SIZES_GIB。
# 依賴 common.sh / fiorun.sh / l2arc.sh 已被 source，且 run_all.sh 已 load_state（取得 ORIG_ARC_MAX）；
# iso2_file 定義於 80_iso2.sh、_export_import_pool 定義於 40_coldhot.sh。
#
# 暖 L2ARC 的方式：覆寫測試檔，寫入的資料被 ARC 淘汰時會餵進 L2ARC（暫時調高 l2arc_write_max，
# ARC 用固定的小基準 ARC_MAX_ROUND1_BYTES（與主機正式 zfs_arc_max 脫鉤），淘汰才會大量發生），
# 這比循序讀暖機快得多——後端讀取只有約 9MB/s，64GiB 循序讀暖機要 2 小時。
# 若覆寫後 L2ARC 沒有填到 90%，才退回循序讀暖機。

phase_92_arcsweep() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 92: ARC 大小掃描（L2ARC 暖好，固定熱資料集 ${ISO2_SIZE_MIB}MiB）"

    local file
    file=$(iso2_file)
    if [[ ! -f "$file" ]]; then
        record_failure "92_arcsweep" "找不到測試檔 $file，略過本 phase"
        return 1
    fi
    echo "log_avg_msec=${ISO2_LOG_AVG_MSEC}" > "${outdir}/iso2_meta.txt"

    local orig_write_max orig_noprefetch
    orig_write_max=$(cat "$L2ARC_WRITE_MAX_PARAM")
    orig_noprefetch=$(cat "$L2ARC_NOPREFETCH_PARAM")
    echo "$L2ARC_WRITE_MAX_WARM_BYTES" > "$L2ARC_WRITE_MAX_PARAM" || log_warn "調高 l2arc_write_max 失敗"
    echo 0 > "$L2ARC_NOPREFETCH_PARAM" || log_warn "設定 l2arc_noprefetch=0 失敗"
    echo "$ARC_MAX_ROUND1_BYTES" > "$ARC_MAX_PARAM" || log_warn "設定填 L2ARC 用的 arc_max 失敗"

    if _arcsweep_populate_l2arc "$file" "$outdir"; then
        local -a sizes
        mapfile -t sizes < <(printf '%s\n' "${ARCSWEEP_SIZES_GIB[@]}" | shuf)
        log_info "本次 ARC 大小測試順序（已打亂，GiB）: ${sizes[*]}"
        local gib
        for gib in "${sizes[@]}"; do
            _arcsweep_measure "$gib" "$file" "$outdir" \
                || record_failure "92_arcsweep:${gib}g" "該 ARC 大小測試失敗或未完成，數據可能缺失"
        done
    fi

    echo "$orig_write_max" > "$L2ARC_WRITE_MAX_PARAM" || log_warn "還原 l2arc_write_max 失敗"
    echo "$orig_noprefetch" > "$L2ARC_NOPREFETCH_PARAM" || log_warn "還原 l2arc_noprefetch 失敗"
    echo "$ORIG_ARC_MAX" > "$ARC_MAX_PARAM" || log_warn "還原 zfs_arc_max 失敗"
    log_info "Phase 92 完成"
}

# 以全新空的 L2ARC 開始，覆寫測試檔把它填滿；不夠再退回循序讀暖機。失敗回傳非零。
_arcsweep_populate_l2arc() {
    local file="$1" outdir="$2"
    local ws_bytes=$(( ISO2_SIZE_MIB * 1024 * 1024 ))

    if ! { zfs set primarycache=all "$DATASET" && zfs set secondarycache=all "$DATASET"; }; then
        record_failure "92_arcsweep" "設定 primarycache/secondarycache=all 失敗，略過本 phase"
        return 1
    fi
    if ! { l2arc_detach && l2arc_attach; }; then
        record_failure "92_arcsweep" "重置 L2ARC 裝置失敗，略過本 phase"
        return 1
    fi

    log_info "覆寫測試檔以填滿 L2ARC（寫入資料被淘汰時餵進 L2ARC）"
    run_fio_test "arcsweep_populate" "$outdir" \
        --ioengine=psync --rw=write --bs=1M --size="${ISO2_SIZE_MIB}M" \
        --filename="$file" --direct=0 --group_reporting \
        || log_warn "arcsweep_populate 回傳非零狀態，繼續流程"
    zpool sync "$POOL" || log_warn "zpool sync 失敗"
    log_info "等待 L2ARC feed 追上（30s）"
    sleep 30
    dump_cache_state "${outdir}/arcsweep_populate_state.txt"

    local l2_asize
    l2_asize=$(awk '/^l2_asize/{print $3}' "$ARCSTATS_PATH")
    if (( l2_asize >= ws_bytes * 9 / 10 )); then
        log_info "L2ARC 已填入 ${l2_asize} bytes（>= 90% 的 ${ws_bytes}），不需循序讀暖機"
        return 0
    fi

    log_warn "L2ARC 只填入 ${l2_asize} bytes（< 90% 的 ${ws_bytes}），退回循序讀暖機（後端讀取約 9MB/s，會很久）"
    run_fio_test "arcsweep_warm" "$outdir" \
        --ioengine=psync --rw=read --bs=1M --numjobs=1 \
        --filename="$file" --size="${ISO2_SIZE_MIB}M" \
        || log_warn "arcsweep_warm 回傳非零狀態，繼續流程"
    sleep 30
    dump_cache_state "${outdir}/arcsweep_warm_state.txt"
}

# _arcsweep_measure <ARC 大小 GiB> <file> <outdir>
_arcsweep_measure() {
    local gib="$1" file="$2" outdir="$3"
    local name="arcsweep_${gib}g"
    local bytes=$(( gib * 1024 * 1024 * 1024 ))

    log_section "ARC 上限 ${gib}GiB"
    if ! echo "$bytes" > "$ARC_MAX_PARAM"; then
        record_failure "92_arcsweep:${gib}g" "設定 zfs_arc_max=${bytes} 失敗，略過"
        return 1
    fi

    # export/import 清空 ARC；持久化 L2ARC 會重建，內容因此保留（start 快照可確認）
    _export_import_pool "$name" || return 1
    sleep "$SETTLE_AFTER_IMPORT"
    dump_cache_state "${outdir}/${name}_state_start.txt"

    run_fio_test "$name" "$outdir" \
        --ioengine=psync --rw=randread --bs=4K --numjobs=4 --iodepth=1 \
        --filename="$file" --size="${ISO2_SIZE_MIB}M" \
        --time_based --runtime="$RUNTIME_ARCSWEEP" \
        --group_reporting --randrepeat=0 --norandommap \
        --write_iops_log="${outdir}/${name}" --log_avg_msec="$ISO2_LOG_AVG_MSEC" \
        || log_warn "${name} 回傳非零狀態，繼續流程"

    dump_cache_state "${outdir}/${name}_state_end.txt"
}
