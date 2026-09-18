#!/usr/bin/env python3
"""
summarize.py - 解析 fio json+ 輸出與 arcstats 快照，產出 summary.txt。

用法: python3 summarize.py <results_dir>
    <results_dir> 例如 results/20260917-020000，其下有 round1/、round2/ 兩個子目錄，
    每個子目錄下有 00_prepare/ 10_prefill/ 20_l2arc_warm/ 30_isolation/
    40_coldhot/ 50_write/ 60_mixed/ 70_slog/ 八個 phase 目錄。

不依賴 jq（此系統未安裝），純 python3 標準函式庫。
"""

import json
import sys
from pathlib import Path

ARC_KEYS = (
    "demand_data_hits",
    "demand_data_misses",
    "l2_hits",
    "l2_misses",
)

SLOG_CONDITIONS = ("standard", "disabled", "removed")
SLOG_VARIANCE_WARN_PCT = 15.0


def load_json(path: Path):
    try:
        with path.open() as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[summarize] 警告: 無法解析 {path}: {exc}", file=sys.stderr)
        return None


def load_arcstats(path: Path):
    """解析 /proc/spl/kstat/zfs/arcstats 格式快照: 每行 'name type value'。"""
    stats = {}
    try:
        with path.open() as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3 and parts[1].isdigit():
                    stats[parts[0]] = int(parts[2])
    except OSError as exc:
        print(f"[summarize] 警告: 無法讀取 {path}: {exc}", file=sys.stderr)
    return stats


def ns_to_us(value):
    return value / 1000.0 if value is not None else None


def extract_fio_metrics(data):
    """從 fio json+ 輸出擷取 read/write 的 iops/bw/延遲百分位。回傳 None 代表該方向無資料。"""
    if not data or not data.get("jobs"):
        return {}
    job = data["jobs"][0]
    result = {}
    for direction in ("read", "write"):
        d = job.get(direction, {})
        iops = d.get("iops", 0) or 0
        if iops <= 0:
            continue
        clat = d.get("clat_ns", {})
        percentile = clat.get("percentile", {})
        result[direction] = {
            "iops": iops,
            "bw_kbs": d.get("bw", 0),
            "lat_mean_us": ns_to_us(clat.get("mean")),
            "lat_p95_us": ns_to_us(percentile.get("95.000000")),
            "lat_p99_us": ns_to_us(percentile.get("99.000000")),
        }
    return result


def arc_attribution(pre: dict, post: dict):
    """計算讀取請求命中 ARC / L2ARC / 實體磁碟的比例，依計畫書公式。"""
    def delta(key):
        return post.get(key, 0) - pre.get(key, 0)

    demand_hits = delta("demand_data_hits")
    demand_misses = delta("demand_data_misses")
    l2_hits = delta("l2_hits")

    total = demand_hits + demand_misses
    if total <= 0:
        return None

    disk = max(demand_misses - l2_hits, 0)
    return {
        "total_demand_reads": total,
        "arc_hit_pct": 100.0 * demand_hits / total,
        "l2arc_hit_pct": 100.0 * l2_hits / total,
        "disk_pct": 100.0 * disk / total,
    }


def fmt(value, unit="", decimals=1):
    if value is None:
        return "n/a"
    return f"{value:.{decimals}f}{unit}"


class TestResult:
    def __init__(self, name, phase_dir):
        self.name = name
        self.json_path = phase_dir / f"{name}.json"
        self.pre_path = phase_dir / f"{name}.arcstats_pre"
        self.post_path = phase_dir / f"{name}.arcstats_post"
        self.metrics = extract_fio_metrics(load_json(self.json_path)) if self.json_path.exists() else {}
        self.attribution = None
        if self.pre_path.exists() and self.post_path.exists():
            self.attribution = arc_attribution(
                load_arcstats(self.pre_path), load_arcstats(self.post_path)
            )

    def read_iops(self):
        return self.metrics.get("read", {}).get("iops")

    def write_iops(self):
        return self.metrics.get("write", {}).get("iops")

    def read_lat_p99(self):
        return self.metrics.get("read", {}).get("lat_p99_us")

    def write_lat_p99(self):
        return self.metrics.get("write", {}).get("lat_p99_us")


def collect_round(round_dir: Path):
    """回傳 {test_name: TestResult} 這一輪所有找得到的測試結果。"""
    results = {}
    for phase_dir in sorted(round_dir.iterdir()):
        if not phase_dir.is_dir():
            continue
        for json_file in phase_dir.glob("*.json"):
            name = json_file.stem
            results[name] = TestResult(name, phase_dir)
    return results


def collect_fill_ratios(round_dir: Path):
    ratios = {}
    prefill_dir = round_dir / "10_prefill"
    if not prefill_dir.exists():
        return ratios
    for txt in prefill_dir.glob("fill_ratio_*.txt"):
        kv = {}
        for line in txt.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                kv[k] = v
        tier = kv.get("tier", txt.stem.replace("fill_ratio_", ""))
        ratios[tier] = kv
    return ratios


def load_failures(results_dir: Path) -> list[str]:
    """讀取 run_all.sh 產出的 failures.log（每行 'timestamp|context|message'），不存在則回傳空清單。"""
    path = results_dir / "failures.log"
    if not path.exists():
        return []
    return [line for line in path.read_text().splitlines() if line.strip()]


def section_failures(out: list, results_dir: Path) -> None:
    out.append("## 已知失敗/跳過項目（軟性容錯，不影響其餘測試繼續執行）")
    failures = load_failures(results_dir)
    if not failures:
        out.append("(無 — 本次測試所有階段皆正常完成)")
        out.append("")
        return
    out.append(f"共 {len(failures)} 筆，以下項目的數據可能缺失或不完整，解讀其餘結果時請留意：")
    for line in failures:
        parts = line.split("|", 2)
        if len(parts) == 3:
            ts, context, message = parts
            out.append(f"  [{ts}] {context}: {message}")
        else:
            out.append(f"  {line}")
    out.append("")


def section_env_snapshot(out, round_name, round_dir):
    out.append(f"## {round_name} 環境快照")
    prepare_log = round_dir / "00_prepare" / "00_prepare.log"
    if prepare_log.exists():
        out.append(prepare_log.read_text().strip())
    out.append("")


def section_fill_ratios(out, round_name, ratios):
    out.append(f"## {round_name} 填充率斷言（證明讀取數據未受稀疏空洞污染，門檻 0.95）")
    if not ratios:
        out.append("(無資料)")
    for tier, kv in sorted(ratios.items()):
        out.append(f"  tier={tier} ratio={kv.get('ratio', 'n/a')} "
                    f"apparent={kv.get('apparent_bytes', 'n/a')} allocated={kv.get('allocated_bytes', 'n/a')}")
    out.append("")


def section_metrics_table(out, round_name, results):
    out.append(f"## {round_name} 測試結果 (IOPS / 延遲)")
    out.append(f"{'test':<26}{'r_iops':>10}{'r_p99(us)':>12}{'w_iops':>10}{'w_p99(us)':>12}")
    for name, r in sorted(results.items()):
        out.append(
            f"{name:<26}{fmt(r.read_iops(), decimals=0):>10}{fmt(r.read_lat_p99(), decimals=0):>12}"
            f"{fmt(r.write_iops(), decimals=0):>10}{fmt(r.write_lat_p99(), decimals=0):>12}"
        )
    out.append("")


def section_cache_attribution(out, round_name, results):
    out.append(f"## {round_name} 快取歸因表 (讀取請求命中比例)")
    out.append(f"{'test':<26}{'ARC%':>8}{'L2ARC%':>8}{'disk%':>8}")
    found = False
    for name, r in sorted(results.items()):
        if r.attribution is None:
            continue
        found = True
        a = r.attribution
        out.append(
            f"{name:<26}{fmt(a['arc_hit_pct'], decimals=1):>8}"
            f"{fmt(a['l2arc_hit_pct'], decimals=1):>8}{fmt(a['disk_pct'], decimals=1):>8}"
        )
    if not found:
        out.append("(無可用的 arcstats 前後快照)")
    out.append("")


def section_coldhot(out, round_name, results):
    out.append(f"## {round_name} 冷熱讀取對比結論")
    tiers = sorted({n.split("_")[1] for n in results if n.startswith("coldhot_")})
    for tier in tiers:
        cold = results.get(f"coldhot_{tier}_cold")
        hots = [results.get(f"coldhot_{tier}_hot{i}") for i in (1, 2, 3)]
        hots = [h for h in hots if h is not None]
        if cold is None or not hots:
            continue
        cold_iops = cold.read_iops() or 0
        hot_iops_avg = sum(h.read_iops() or 0 for h in hots) / len(hots)
        ratio = (hot_iops_avg / cold_iops) if cold_iops > 0 else None
        cold_lat = cold.read_lat_p99()
        hot_lat_avg = sum(h.read_lat_p99() or 0 for h in hots if h.read_lat_p99()) / max(
            len([h for h in hots if h.read_lat_p99()]), 1
        )
        out.append(
            f"  tier={tier}: 冷讀 IOPS={fmt(cold_iops, decimals=0)}  "
            f"熱讀平均 IOPS={fmt(hot_iops_avg, decimals=0)}  倍率={fmt(ratio, 'x', 2)}  "
            f"冷讀p99={fmt(cold_lat, 'us', 0)} 熱讀p99平均={fmt(hot_lat_avg, 'us', 0)}"
        )
    if not tiers:
        out.append("(無資料)")
    out.append("")


def _collect_slog_condition(results, cond):
    """回傳某 SLOG 組態（standard/disabled/removed）的 (name, TestResult) list，依重複編號排序。"""
    items = [(name, r) for name, r in results.items() if name.startswith(f"slog_{cond}_r")]
    items.sort(key=lambda nr: nr[0])
    return items


def _mean_and_spread_pct(values):
    """回傳 (平均值, 相對變異幅度%)；values 為空回傳 (None, None)。"""
    if not values:
        return None, None
    mean = sum(values) / len(values)
    spread_pct = ((max(values) - min(values)) / mean * 100.0) if mean > 0 else None
    return mean, spread_pct


def section_slog_repeats(out, round_name, results):
    """列出 SLOG 三組態各自的重複測試明細 + 平均值，並標示波動過大的組態。
    回傳 {condition: 平均IOPS} 供 section_layer_contribution 計算貢獻量化使用。
    """
    out.append(f"## {round_name} SLOG 重複測試明細（各組態獨立檔案 + 打亂執行順序，避免序列污染/順序偏差）")
    means = {}
    for cond in SLOG_CONDITIONS:
        items = _collect_slog_condition(results, cond)
        if not items:
            continue
        values = [r.write_iops() or 0 for _, r in items]
        mean, spread_pct = _mean_and_spread_pct(values)
        means[cond] = mean
        detail = ", ".join(f"{name}={fmt(r.write_iops(), decimals=0)}" for name, r in items)
        warn = ""
        if spread_pct is not None and spread_pct > SLOG_VARIANCE_WARN_PCT:
            warn = f"  [警告: 重複測試間差異 {spread_pct:.1f}%，超過 {SLOG_VARIANCE_WARN_PCT:.0f}% 門檻，結果可能不穩定]"
        out.append(f"  {cond:<10} {detail}  平均={fmt(mean, decimals=0)}{warn}")

    raw = results.get("slog_raw_device")
    if raw:
        out.append(
            f"  裸裝置基準線 (slog_raw_device，繞過 ZFS 直接測 SLOG partition): "
            f"IOPS={fmt(raw.write_iops(), decimals=0)} p99={fmt(raw.write_lat_p99(), 'us', 0)}"
            "  （僅供人工交叉比對，不納入下方自動貢獻量化計算）"
        )
    else:
        out.append("  裸裝置基準線: (無資料)")
    out.append("")
    return means


def section_layer_contribution(out, round_name, results, slog_means=None):
    out.append(f"## {round_name} 快取層貢獻量化")

    raw = results.get("isolation_raw")
    arconly = results.get("isolation_arconly")
    full = results.get("isolation_full")
    if raw and arconly and full:
        arc_gain = (arconly.read_iops() or 0) - (raw.read_iops() or 0)
        l2_gain = (full.read_iops() or 0) - (arconly.read_iops() or 0)
        out.append(f"  ARC 貢獻 (arconly-raw)   : {fmt(arc_gain, ' IOPS', 0)}"
                    f"  (raw={fmt(raw.read_iops(),decimals=0)} arconly={fmt(arconly.read_iops(),decimals=0)})")
        out.append(f"  L2ARC 貢獻 (full-arconly): {fmt(l2_gain, ' IOPS', 0)}"
                    f"  (arconly={fmt(arconly.read_iops(),decimals=0)} full={fmt(full.read_iops(),decimals=0)})")
    else:
        out.append("  ARC/L2ARC 貢獻: (isolation 測試資料不完整)")

    w_sync = results.get("write_sync")
    w_async = results.get("write_async")
    if w_sync and w_async:
        out.append(f"  fsync 成本 (async-sync IOPS 差): "
                    f"async={fmt(w_async.write_iops(),decimals=0)} sync={fmt(w_sync.write_iops(),decimals=0)}")

    slog_means = slog_means or {}
    std_mean = slog_means.get("standard")
    dis_mean = slog_means.get("disabled")
    rm_mean = slog_means.get("removed")
    if std_mean is not None and dis_mean is not None:
        out.append(f"  SLOG fsync 成本 (standard vs disabled，取重複測試平均): "
                    f"standard={fmt(std_mean,decimals=0)} disabled(理論上限)={fmt(dis_mean,decimals=0)}")
    if std_mean is not None and rm_mean is not None:
        slog_gain = std_mean - rm_mean
        out.append(f"  SLOG 貢獻 (standard-removed IOPS 差，取重複測試平均): {fmt(slog_gain, ' IOPS', 0)}"
                    f"  (standard={fmt(std_mean,decimals=0)} removed={fmt(rm_mean,decimals=0)})")
    out.append("")


def section_round_comparison(out, round_results):
    if len(round_results) < 2:
        return
    out.append("## Round 1 vs Round 2 對照 (ARC 3.13 GiB -> 48 GiB)")
    r1 = round_results.get("round1", {})
    r2 = round_results.get("round2", {})
    names = sorted(set(r1) & set(r2))
    out.append(f"{'test':<26}{'r1_r_iops':>12}{'r2_r_iops':>12}{'gain%':>10}")
    for name in names:
        a, b = r1[name], r2[name]
        a_iops, b_iops = a.read_iops(), b.read_iops()
        if a_iops is None or b_iops is None:
            continue
        gain = ((b_iops - a_iops) / a_iops * 100.0) if a_iops > 0 else None
        out.append(f"{name:<26}{fmt(a_iops,decimals=0):>12}{fmt(b_iops,decimals=0):>12}{fmt(gain,'%',1):>10}")
    out.append("")


def main():
    if len(sys.argv) != 2:
        print("用法: python3 summarize.py <results_dir>", file=sys.stderr)
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    if not results_dir.is_dir():
        print(f"找不到目錄: {results_dir}", file=sys.stderr)
        sys.exit(1)

    out = []
    out.append(f"# fio-zfs-bench Summary")
    out.append(f"# 產出目錄: {results_dir}")
    out.append("")

    section_failures(out, results_dir)

    round_results = {}
    for round_name in ("round1", "round2"):
        round_dir = results_dir / round_name
        if not round_dir.exists():
            continue
        results = collect_round(round_dir)
        round_results[round_name] = results
        ratios = collect_fill_ratios(round_dir)

        section_env_snapshot(out, round_name, round_dir)
        section_fill_ratios(out, round_name, ratios)
        section_metrics_table(out, round_name, results)
        section_cache_attribution(out, round_name, results)
        section_coldhot(out, round_name, results)
        slog_means = section_slog_repeats(out, round_name, results)
        section_layer_contribution(out, round_name, results, slog_means)

    section_round_comparison(out, round_results)

    out.append("## 備註")
    out.append("- IOPS/延遲數字為 fio json+ 輸出直接擷取，未經額外平滑處理。")
    out.append("- 快取歸因表僅涵蓋隨機讀測試 (isolation_*/coldhot_*/l2arc_warm)，寫入測試無 arcstats 讀取歸因。")
    out.append("- 效能斷崖判定與 Fabric 部署建議請對照上方各表人工解讀（tier 越大若 IOPS 驟降代表打穿該層快取）。")

    summary_path = results_dir / "summary.txt"
    summary_path.write_text("\n".join(out) + "\n")
    print(f"已產出 {summary_path}")


if __name__ == "__main__":
    main()
