#!/bin/bash
# 50_write.sh - 同步寫入（--sync=1，代表 SLOG 路徑，模擬 LevelDB fsync）
# 與非同步寫入（無 sync/fsync，觀察一般 buffered write 在大 RAM 下的表現）。
# 使用獨立測試檔，不影響 tier 資料（後續 phase 60/70 也各自用獨立檔案）。
# 依賴 common.sh / fiorun.sh 已被 source。

phase_50_write() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 50: 同步 / 非同步寫入"

    local file="${DATASET_MOUNT}/write_test.dat"

    run_fio_test "write_sync" "$outdir" \
        --ioengine=psync --rw=randwrite --bs=4K --numjobs=4 --iodepth=1 --sync=1 \
        --filename="$file" --size="${WRITE_TEST_SIZE_MIB}M" \
        --time_based --runtime="$RUNTIME_WRITE" \
        --group_reporting --randrepeat=0 --norandommap \
        || log_warn "write_sync 回傳非零狀態，繼續流程"

    run_fio_test "write_async" "$outdir" \
        --ioengine=psync --rw=randwrite --bs=4K --numjobs=4 --iodepth=1 \
        --filename="$file" --size="${WRITE_TEST_SIZE_MIB}M" \
        --time_based --runtime="$RUNTIME_WRITE" \
        --group_reporting --randrepeat=0 --norandommap \
        || log_warn "write_async 回傳非零狀態，繼續流程"

    log_info "Phase 50 完成"
}
