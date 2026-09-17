#!/bin/bash
# monitor.sh - 啟停背景監控（zpool iostat / arcstat / iostat -x）。
# 依賴 common.sh 已被 source。以全域陣列 _MONITOR_PIDS 記錄目前拉起的背景 PID。

_MONITOR_PIDS=()

# 啟動一組背景監控，log 落在 <outdir>/<test_name>.{zpooliostat,arcstat,iostat}.log
start_monitor() {
    local outdir="$1" test_name="$2"
    mkdir -p "$outdir"
    _MONITOR_PIDS=()

    zpool iostat -v "$POOL" 5 > "${outdir}/${test_name}.zpooliostat.log" 2>&1 &
    _MONITOR_PIDS+=("$!")

    arcstat 5 > "${outdir}/${test_name}.arcstat.log" 2>&1 &
    _MONITOR_PIDS+=("$!")

    if command -v iostat >/dev/null 2>&1; then
        iostat -x 5 nvme0n1 > "${outdir}/${test_name}.iostat.log" 2>&1 &
        _MONITOR_PIDS+=("$!")
    fi
}

# 收掉 start_monitor 拉起的所有背景行程
stop_monitor() {
    local pid
    for pid in "${_MONITOR_PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null
    done
    # 給背景行程一點時間把最後一筆 buffer flush 掉再確認已終止
    sleep 1
    for pid in "${_MONITOR_PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    _MONITOR_PIDS=()
}
