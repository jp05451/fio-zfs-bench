#!/bin/bash
# l2arc.sh - L2ARC（cache 裝置）拆裝輔助，供 --diag 診斷測試取得「真正乾淨」的組態。
# 依賴 common.sh 已被 source。
#
# 為什麼一定要拆裝裝置：secondarycache=none 只阻止「新資料寫進 L2ARC」，不會讓 L2ARC 內
# 既有的資料失效，讀取路徑仍會命中（同理 primarycache=none 也擋不住 ARC 內既有資料）。
# 舊的 30_isolation 因此把前一階段暖機留下的快取算進 raw 組態，低估了快取貢獻。
# 只有把 cache 裝置移除、再加回（ZFS 視為全新的空 L2ARC）才能保證從零開始。

l2arc_is_attached() {
    local pool_status
    pool_status=$(zpool status "$POOL" 2>/dev/null)
    [[ "$pool_status" == *"$L2ARC_DEVICE"* ]]
}

# 移除 cache 裝置並等到 zpool status 不再列出它。已經不在就直接成功。
l2arc_detach() {
    l2arc_is_attached || return 0
    log_info "移除 L2ARC 裝置 $L2ARC_DEVICE"
    zpool remove "$POOL" "$L2ARC_DEVICE" || return 1

    local tries=15
    while (( tries-- > 0 )); do
        l2arc_is_attached || return 0
        sleep 2
    done
    return 1
}

# 把 cache 裝置以全新的空 L2ARC 加回。已經在就直接成功。
l2arc_attach() {
    l2arc_is_attached && return 0
    log_info "加回 L2ARC 裝置 $L2ARC_DEVICE"
    zpool add "$POOL" cache "$L2ARC_DEVICE" || return 1
    l2arc_is_attached
}

# dump_cache_state <dest>：記錄當下 ARC/L2ARC 大小，供事後確認暖機結果與組態是否真的乾淨。
dump_cache_state() {
    local dest="$1"
    awk '/^(size|c|c_max|l2_size|l2_asize|l2_hdr_size) /{print $1, $3}' "$ARCSTATS_PATH" > "$dest"
}
