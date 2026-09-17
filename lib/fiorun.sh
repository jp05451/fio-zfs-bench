#!/bin/bash
# fiorun.sh - 包裝單次 fio 測試：前後 arcstats 快照 + 背景監控 + JSON 輸出。
# 依賴 common.sh / monitor.sh / arcstats.sh 已被 source。

# run_fio_test <test_name> <outdir> <fio-args...>
# fio-args 不需包含 --name/--output/--output-format，本函式會自動補上。
run_fio_test() {
    local test_name="$1" outdir="$2"
    shift 2
    mkdir -p "$outdir"

    log_info "開始測試: $test_name (outdir=$outdir)"

    snapshot_arcstats "${outdir}/${test_name}.arcstats_pre"
    start_monitor "$outdir" "$test_name"

    local rc=0
    fio "$@" \
        --name="$test_name" \
        --output-format=json+ \
        --output="${outdir}/${test_name}.json" \
        || rc=$?

    stop_monitor
    snapshot_arcstats "${outdir}/${test_name}.arcstats_post"

    if (( rc != 0 )); then
        log_error "fio 測試 $test_name 回傳非零狀態碼: $rc"
    else
        log_info "測試完成: $test_name"
    fi
    return "$rc"
}
