#!/bin/bash
# arcstats.sh - 快照 /proc/spl/kstat/zfs/arcstats。
# 依賴 common.sh 已被 source。差值計算交給 summarize.py（讀 pre/post 兩份快照）。

snapshot_arcstats() {
    local dest="$1"
    cp "$ARCSTATS_PATH" "$dest"
}
