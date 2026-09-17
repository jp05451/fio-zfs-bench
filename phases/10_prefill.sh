#!/bin/bash
# 10_prefill.sh - 循序寫滿各 tier 測試檔，並斷言填充率 >= MIN_FILL_RATIO。
# 這是解決「舊腳本讀取測試打在稀疏空洞上」問題的關鍵步驟：
# 絕不用 --time_based 的 randwrite 去填檔案，一律循序寫滿整個宣告大小。
# 依賴 common.sh / fiorun.sh 已被 source。

phase_10_prefill() {
    local outdir="$1"
    mkdir -p "$outdir"
    log_section "Phase 10: 循序預熱填充"

    local tier size_mib file
    for tier in "${TIER_NAMES[@]}"; do
        size_mib=$(tier_size_mib "$tier")
        file=$(tier_file "$tier")
        log_info "填充 tier=$tier size=${size_mib}MiB file=$file"

        rm -f "$file"
        if ! fio --ioengine=psync --rw=write --bs=1M \
            --size="${size_mib}M" \
            --filename="$file" \
            --direct=0 \
            --group_reporting \
            --output-format=json+ \
            --output="${outdir}/prefill_${tier}.json" \
            --name="prefill_${tier}"; then
            record_failure "10_prefill:${tier}" "預熱填充失敗，本 tier 後續測試（isolation/coldhot 等）數據可能無效或缺失，跳過此 tier 繼續下一個"
            continue
        fi

        # direct=0 的寫入資料在 txg flush 前仍停留在 ZFS dirty buffer，
        # du 量到的實際配置空間會是 0；強制 sync 才能拿到真實配置量。
        zpool sync "$POOL" || log_warn "zpool sync 失敗，填充率量測可能不準確"

        if ! _assert_fill_ratio "$tier" "$file" "$outdir"; then
            record_failure "10_prefill:${tier}" "填充率斷言未通過，測試檔案可能含大量稀疏空洞（見發現1），跳過此 tier 繼續下一個"
            continue
        fi
    done

    log_info "Phase 10 完成"
}

# 比對 apparent size 與實際配置 (du) 大小；低於 MIN_FILL_RATIO 回傳非零，由呼叫端決定是否跳過該 tier。
_assert_fill_ratio() {
    local tier="$1" file="$2" outdir="$3"
    local apparent_bytes allocated_bytes ratio

    apparent_bytes=$(stat -c '%s' "$file") || { record_failure "10_prefill:${tier}" "無法 stat $file"; return 1; }
    # du -B1 回傳的是實際配置的區塊大小（bytes）
    allocated_bytes=$(du -B1 "$file" | awk '{print $1}')

    ratio=$(python3 -c "print(f'{${allocated_bytes}/${apparent_bytes}:.4f}')")

    {
        echo "tier=${tier}"
        echo "apparent_bytes=${apparent_bytes}"
        echo "allocated_bytes=${allocated_bytes}"
        echo "ratio=${ratio}"
    } > "${outdir}/fill_ratio_${tier}.txt"

    log_info "tier=$tier 填充率 = $ratio (apparent=${apparent_bytes} allocated=${allocated_bytes})"

    local ok
    ok=$(python3 -c "print(1 if ${ratio} >= ${MIN_FILL_RATIO} else 0)")
    [[ "$ok" == "1" ]]
}
