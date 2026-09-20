#!/bin/bash
# 80_iso2.sh - 快取層隔離矩陣 v2（--diag 模式）。修正舊 30_isolation 的兩個問題：
#   1. 舊版不清快取：raw 組態其實吃到前一階段暖機留下的 ARC/L2ARC 資料（表上 raw 仍有
#      25%~35% 命中），低估了快取貢獻。這裡每個組態都先拆掉 L2ARC 裝置、再 export/import
#      清空 ARC，從真正的零開始。
#   2. 舊版量測時快取尚未暖好（約 100 IOPS 時，快取每秒只增加約 12MB），量到的是暖機過程
#      而非穩態。這裡先用循序讀把整個測試檔讀過一遍暖機，再量 RUNTIME_ISO2_MEASURE 秒，
#      並以 fio iops log 記錄逐時 IOPS，可直接看出是否收斂。
# 依賴 common.sh / fiorun.sh / l2arc.sh 已被 source；_export_import_pool 定義於 40_coldhot.sh，
# _assert_fill_ratio 定義於 10_prefill.sh，run_all.sh 會把它們 source 進同一個 shell。

ISO2_FILE_NAME="iso2_t2.dat"

iso2_file() { echo "${DATASET_MOUNT}/${ISO2_FILE_NAME}"; }

# 循序寫滿診斷測試檔並斷言填充率（與 phase 10 同一套標準），整輪診斷只做一次。
phase_80_iso2_setup() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 80 setup: 建立診斷測試檔 (${ISO2_SIZE_MIB}MiB)"

    local file
    file=$(iso2_file)
    rm -f "$file"

    if ! fio --ioengine=psync --rw=write --bs=1M \
        --size="${ISO2_SIZE_MIB}M" --filename="$file" --direct=0 \
        --group_reporting --output-format=json+ \
        --output="${outdir}/prefill_iso2.json" --name=prefill_iso2; then
        record_failure "80_iso2:setup" "診斷測試檔填充失敗，跳過整個 Phase 80"
        rm -f "$file"
        return 1
    fi

    zpool sync "$POOL" || log_warn "zpool sync 失敗，填充率量測可能不準確"

    if ! _assert_fill_ratio "iso2" "$file" "$outdir"; then
        record_failure "80_iso2:setup" "診斷測試檔填充率斷言未通過，跳過整個 Phase 80"
        rm -f "$file"
        return 1
    fi
}

phase_80_iso2_cleanup() {
    rm -f "$(iso2_file)"
}

phase_80_iso2() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 80: 快取層隔離矩陣 v2（真正乾淨的 raw / arconly / full）"

    local file
    file=$(iso2_file)
    if [[ ! -f "$file" ]]; then
        record_failure "80_iso2" "找不到診斷測試檔 $file（setup 失敗？），略過本 phase"
        return 1
    fi

    echo "log_avg_msec=${ISO2_LOG_AVG_MSEC}" > "${outdir}/iso2_meta.txt"
    snapshot_storage_env "${outdir}/env_storage.txt"

    local cfg
    for cfg in raw arconly full; do
        _iso2_run_config "$cfg" "$file" "$outdir" \
            || record_failure "80_iso2:${cfg}" "該組態測試失敗或未完成，數據可能缺失"
    done

    # 還原生產組態，並確保 L2ARC 裝置在位（run_all.sh 的全域 trap 也會再確認一次）
    zfs set primarycache=all "$DATASET" && zfs set secondarycache=all "$DATASET" \
        || record_failure "80_iso2:restore" "還原 primarycache/secondarycache=all 失敗，請人工確認 $DATASET"
    l2arc_attach || die "L2ARC 裝回失敗！請立即手動執行: zpool add $POOL cache $L2ARC_DEVICE"

    log_info "Phase 80 完成"
}

# _iso2_run_config <raw|arconly|full> <file> <outdir>
_iso2_run_config() {
    local cfg="$1" file="$2" outdir="$3"
    local primary secondary runtime warm
    case "$cfg" in
        raw)     primary=none; secondary=none; runtime="$RUNTIME_ISO2_RAW";     warm=0 ;;
        arconly) primary=all;  secondary=none; runtime="$RUNTIME_ISO2_MEASURE"; warm=1 ;;
        full)    primary=all;  secondary=all;  runtime="$RUNTIME_ISO2_MEASURE"; warm=1 ;;
    esac
    log_section "組態 ${cfg}: primarycache=${primary} secondarycache=${secondary} 暖機=${warm}"

    # 1) 拆掉 L2ARC 裝置：唯一能讓 L2ARC 既有資料真正失效的方法
    if ! l2arc_detach; then
        record_failure "80_iso2:${cfg}" "移除 L2ARC 裝置失敗，本組態無法保證乾淨，略過"
        return 1
    fi

    # 2) export/import 清空 ARC
    _export_import_pool "iso2_${cfg}" || return 1

    # 3) 只有 full 需要 L2ARC：以全新的空裝置加回，之後的內容全部來自這次暖機
    if [[ "$cfg" == "full" ]] && ! l2arc_attach; then
        record_failure "80_iso2:${cfg}" "加回 L2ARC 裝置失敗，略過 full 組態"
        return 1
    fi

    # 4) 設定快取屬性並沉澱
    if ! { zfs set primarycache="$primary" "$DATASET" && zfs set secondarycache="$secondary" "$DATASET"; }; then
        record_failure "80_iso2:${cfg}" "設定快取屬性失敗，略過"
        return 1
    fi
    log_info "沉澱 ${SETTLE_AFTER_IMPORT}s"
    sleep "$SETTLE_AFTER_IMPORT"
    dump_cache_state "${outdir}/iso2_${cfg}_state_start.txt"

    # full 才需要讓循序暖機的資料也能被餵進 L2ARC：預設 l2arc_noprefetch=1 會排除預取的資料
    local orig_write_max="" orig_noprefetch=""
    if [[ "$cfg" == "full" ]]; then
        orig_write_max=$(cat "$L2ARC_WRITE_MAX_PARAM")
        orig_noprefetch=$(cat "$L2ARC_NOPREFETCH_PARAM")
        echo "$L2ARC_WRITE_MAX_WARM_BYTES" > "$L2ARC_WRITE_MAX_PARAM" || log_warn "調高 l2arc_write_max 失敗"
        echo 0 > "$L2ARC_NOPREFETCH_PARAM" || log_warn "設定 l2arc_noprefetch=0 失敗"
    fi

    if (( warm )); then
        run_fio_test "iso2_${cfg}_warm" "$outdir" \
            --ioengine=psync --rw=read --bs=1M --numjobs=1 \
            --filename="$file" --size="${ISO2_SIZE_MIB}M" \
            || log_warn "iso2_${cfg}_warm 回傳非零狀態，繼續流程"
        if [[ "$cfg" == "full" ]]; then
            log_info "等待 L2ARC feed 追上（30s）"
            sleep 30
        fi
    fi
    dump_cache_state "${outdir}/iso2_${cfg}_state_after_warm.txt"

    run_fio_test "iso2_${cfg}" "$outdir" \
        --ioengine=psync --rw=randread --bs=4K --numjobs=4 --iodepth=1 \
        --filename="$file" \
        --time_based --runtime="$runtime" \
        --group_reporting --randrepeat=0 --norandommap \
        --write_iops_log="${outdir}/iso2_${cfg}" --log_avg_msec="$ISO2_LOG_AVG_MSEC" \
        || log_warn "iso2_${cfg} 回傳非零狀態，繼續流程"

    dump_cache_state "${outdir}/iso2_${cfg}_state_end.txt"

    if [[ "$cfg" == "full" ]]; then
        echo "$orig_write_max" > "$L2ARC_WRITE_MAX_PARAM" || log_warn "還原 l2arc_write_max 失敗"
        echo "$orig_noprefetch" > "$L2ARC_NOPREFETCH_PARAM" || log_warn "還原 l2arc_noprefetch 失敗"
    fi
}

# snapshot_storage_env <dest>：記錄 iSCSI LUN 的寫入快取模式、佇列參數與 ZFS 相關可調參數，
# 用來判斷後端 sync 寫入為什麼這麼快（例如 LUN 是否回報 write back）。失敗一律不影響流程。
snapshot_storage_env() {
    local dest="$1" dev base f param
    {
        echo "## zpool status -LP"
        zpool status -LP "$POOL" 2>&1
        echo
        while read -r dev; do
            base=$(basename "$dev" | sed 's/[0-9]*$//')
            echo "## /sys/block/${base} (from ${dev})"
            for f in queue/write_cache queue/rotational queue/scheduler queue/nr_requests \
                     queue/max_sectors_kb queue/read_ahead_kb device/queue_depth device/vendor device/model; do
                printf '%s: %s\n' "$f" "$(cat "/sys/block/${base}/${f}" 2>/dev/null || echo n/a)"
            done
            echo
        done < <(zpool status -LP "$POOL" 2>/dev/null | awk '$1 ~ /^\/dev\/sd/ {print $1}')

        echo "## iscsiadm session"
        iscsiadm -m session -P3 2>&1 | grep -E 'Target:|Current Portal|Iface Name|HeaderDigest|DataDigest|MaxRecvDataSegmentLength|FirstBurstLength|MaxBurstLength|ImmediateData|InitialR2T|MaxOutstandingR2T|Attached scsi disk' || echo n/a
        echo
        echo "## zfs module parameters"
        for param in zfs_arc_max zfs_dirty_data_max zfs_txg_timeout zfs_immediate_write_sz zil_slog_bulk \
                     zfs_vdev_sync_write_max_active zfs_vdev_async_write_max_active zfs_vdev_max_active \
                     l2arc_write_max l2arc_noprefetch l2arc_headroom l2arc_feed_again l2arc_rebuild_enabled; do
            printf '%s: %s\n' "$param" "$(cat "/sys/module/zfs/parameters/${param}" 2>/dev/null || echo n/a)"
        done
        echo
        echo "## dataset / pool properties"
        zfs get -H -o property,value logbias,sync,primarycache,secondarycache,recordsize,compression "$DATASET" 2>&1
        zpool get -H -o property,value ashift "$POOL" 2>&1
    } > "$dest" 2>&1
}
