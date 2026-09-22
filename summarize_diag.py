#!/usr/bin/env python3
"""
summarize_diag.py - 解析 --diag 診斷模式的輸出，產出 diag_summary.txt。

用法: python3 summarize_diag.py <results_dir>
    <results_dir> 下有 round1/80_iso2、round2/80_iso2、round2/90_slog2，以及 setup/。

涵蓋:
  - Phase 80 隔離矩陣 v2（真正乾淨的 raw / arconly / full）：IOPS、命中歸因、逐時 IOPS、
    由「未命中率 × 每次未命中成本」回推的模型檢查、乾淨版 ARC / L2ARC 貢獻。
  - Phase 90 SLOG 併發度掃描：standard / removed / rawdev 三種條件 × numjobs。
不依賴 jq，純 python3 標準函式庫；fio 輸出解析與歸因計算沿用 summarize.py。
"""

import sys
from collections import defaultdict
from pathlib import Path

import re

from summarize import TestResult, collect_round, fmt, load_failures, load_json, ns_to_us

GIB = 1024 ** 3
ISO2_CONFIGS = ("raw", "arconly", "full")
SLOG2_CONDITIONS = ("standard", "removed", "rawdev")
ISO2_NUMJOBS = 4                 # Phase 80 隨機讀的併發數，用於由 IOPS 回推每次未命中成本
STEADY_TAIL_SEC = 300            # 以量測期間最後這段時間平均，視為近似穩態
SERIES_PRINT_EVERY_SEC = 60      # 逐時 IOPS 每隔多久印一個點
SPREAD_WARN_PCT = 15.0           # 重複測試間差異超過此值視為不穩定
SLOG_SIGNIFICANT_PCT = 15.0      # standard 與 removed 平均差超過此值才算有意義
MIN_DISK_PCT_FOR_MODEL = 5.0     # 未命中率太低時，回推未命中成本沒有意義
BACKEND_RANDOM_READ_IOPS = 64    # 實測後端 LUN 隨機讀飽和值（1/4/16/64 併發: 14/60/63/64 IOPS）


def parse_kv(path: Path) -> dict[str, int]:
    """解析 'key value' 每行一筆的快取狀態檔（dump_cache_state 的輸出）。"""
    stats: dict[str, int] = {}
    if not path.exists():
        return stats
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            stats[parts[0]] = int(parts[1])
    return stats


def read_log_avg_msec(outdir: Path) -> int:
    meta = outdir / "iso2_meta.txt"
    if meta.exists():
        for line in meta.read_text().splitlines():
            if line.startswith("log_avg_msec="):
                return int(line.split("=", 1)[1])
    return 10000


def read_iops_series(outdir: Path, prefix: str, log_avg_msec: int) -> list[tuple[float, float]]:
    """把 fio 各 job 的 iops log 依時間桶加總，回傳 [(秒, 總IOPS)]。"""
    buckets: dict[int, float] = defaultdict(float)
    for log_file in sorted(outdir.glob(f"{prefix}_iops.*.log")):
        for line in log_file.read_text().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 2:
                continue
            try:
                t_ms, value = int(parts[0]), float(parts[1])
            except ValueError:
                continue
            buckets[round(t_ms / log_avg_msec)] += value
    return [(k * log_avg_msec / 1000.0, v) for k, v in sorted(buckets.items())]


def steady_iops(series: list[tuple[float, float]]) -> float | None:
    """量測期間最後 STEADY_TAIL_SEC 秒的平均 IOPS；資料不足時退而取全部平均。"""
    if not series:
        return None
    end = series[-1][0]
    tail = [v for t, v in series if t > end - STEADY_TAIL_SEC]
    values = tail or [v for _, v in series]
    return sum(values) / len(values)


def miss_cost_ms(result: TestResult) -> float | None:
    """由 IOPS 與未命中率回推「每次真正打到磁碟的讀取」平均延遲（毫秒）。
    模型: 平均延遲 = numjobs / IOPS ≈ 未命中率 × 未命中成本（命中幾乎免費）。"""
    iops = result.read_iops()
    if not iops or result.attribution is None:
        return None
    disk_pct = result.attribution["disk_pct"]
    if disk_pct < MIN_DISK_PCT_FOR_MODEL:
        return None
    return ISO2_NUMJOBS * 1000.0 / iops / (disk_pct / 100.0)


def _warm_bandwidth_mbs(warm: TestResult | None) -> float | None:
    if warm is None or not warm.metrics.get("read"):
        return None
    return warm.metrics["read"]["bw_kbs"] / 1024.0


def section_iso2_round(out: list[str], round_name: str, round_dir: Path) -> dict[str, TestResult]:
    iso_dir = round_dir / "80_iso2"
    out.append(f"## {round_name} Phase 80 隔離矩陣 v2（每組態先拆 L2ARC + export/import 清 ARC，再循序暖機）")
    if not iso_dir.exists():
        out.append("(無資料)")
        out.append("")
        return {}

    results = collect_round(round_dir)
    log_avg_msec = read_log_avg_msec(iso_dir)

    out.append(f"{'config':<9}{'r_iops':>9}{'steady':>9}{'p99(us)':>10}{'ARC%':>7}{'L2%':>7}{'disk%':>7}"
               f"{'miss_ms':>9}{'ARC_GiB':>9}{'L2_GiB':>8}{'warm_MB/s':>11}")
    found: dict[str, TestResult] = {}
    series_by_cfg: dict[str, list[tuple[float, float]]] = {}
    for cfg in ISO2_CONFIGS:
        r = results.get(f"iso2_{cfg}")
        if r is None:
            out.append(f"{cfg:<9}(無資料)")
            continue
        found[cfg] = r
        series = read_iops_series(iso_dir, f"iso2_{cfg}", log_avg_msec)
        series_by_cfg[cfg] = series
        end_state = parse_kv(iso_dir / f"iso2_{cfg}_state_end.txt")
        arc_gib = end_state["size"] / GIB if "size" in end_state else None
        l2_gib = end_state["l2_asize"] / GIB if "l2_asize" in end_state else None
        a = r.attribution or {}
        out.append(
            f"{cfg:<9}{fmt(r.read_iops(), decimals=0):>9}{fmt(steady_iops(series), decimals=0):>9}"
            f"{fmt(r.read_lat_p99(), decimals=0):>10}"
            f"{fmt(a.get('arc_hit_pct'), decimals=1):>7}{fmt(a.get('l2arc_hit_pct'), decimals=1):>7}"
            f"{fmt(a.get('disk_pct'), decimals=1):>7}{fmt(miss_cost_ms(r), decimals=1):>9}"
            f"{fmt(arc_gib, decimals=1):>9}{fmt(l2_gib, decimals=1):>8}"
            f"{fmt(_warm_bandwidth_mbs(results.get(f'iso2_{cfg}_warm')), decimals=0):>11}"
        )
    out.append("  (steady = 量測期間最後 5 分鐘平均 IOPS；miss_ms = 4 併發下由 IOPS/未命中率回推的每次未命中成本)")
    out.append("")

    for cfg, series in series_by_cfg.items():
        out.append(f"  逐時 IOPS [{cfg}]（每 {SERIES_PRINT_EVERY_SEC}s 一點）:")
        step = max(1, round(SERIES_PRINT_EVERY_SEC * 1000 / log_avg_msec))
        picked_points = series[step - 1::step]
        if series and (not picked_points or picked_points[-1] != series[-1]):
            picked_points = picked_points + [series[-1]]   # 一律附上最後一點
        picked = [f"{t:.0f}s={v:.0f}" for t, v in picked_points]
        out.append("    " + (" ".join(picked) if picked else "(無 iops log)"))
        json_iops = found[cfg].read_iops()
        series_mean = sum(v for _, v in series) / len(series) if series else None
        if json_iops and series_mean:
            out.append(f"    [校驗] iops log 平均 {series_mean:.0f} vs fio json {json_iops:.0f}")
    out.append("")
    return found


def _gain_line(label: str, new: float, base: float) -> str:
    if not base:
        return f"    {label}: n/a"
    return f"    {label}: {new - base:+.0f} IOPS ({(new / base - 1) * 100:+.0f}%)"


def section_clean_contribution(out: list[str], iso_by_round: dict[str, dict[str, TestResult]]) -> None:
    out.append("## 乾淨版快取貢獻（對照舊 Phase 30 的 ARC +3~6 / L2ARC +5~16 IOPS）")
    for round_name, found in sorted(iso_by_round.items()):
        raw, arc, full = found.get("raw"), found.get("arconly"), found.get("full")
        if not (raw and arc and full):
            out.append(f"  {round_name}: 資料不完整，略過")
            continue
        r, a, f = raw.read_iops() or 0, arc.read_iops() or 0, full.read_iops() or 0
        out.append(f"  {round_name}: raw={r:.0f}  arconly={a:.0f}  full={f:.0f}")
        out.append(_gain_line("ARC 貢獻 (arconly-raw)   ", a, r))
        out.append(_gain_line("L2ARC 貢獻 (full-arconly)", f, a))
        out.append(_gain_line("整體快取貢獻 (full-raw)  ", f, r))
    raws = [(n, f["raw"].read_iops()) for n, f in sorted(iso_by_round.items()) if "raw" in f]
    if len(raws) == 2 and all(v for _, v in raws):
        lo, hi = sorted(v for _, v in raws)
        out.append(f"  raw 兩輪重複: {raws[0][1]:.0f} vs {raws[1][1]:.0f}（差 {(hi - lo) / lo * 100:.1f}%，可當作雜訊底線）")
    out.append("")


def collect_slog2(results: dict[str, TestResult]) -> dict[tuple[str, int], list[TestResult]]:
    """名稱格式 slog2_<cond>_j<N>_r<rep>，回傳 {(cond, N): [TestResult...]}。"""
    grouped: dict[tuple[str, int], list[TestResult]] = defaultdict(list)
    for name, r in results.items():
        parts = name.split("_")
        if len(parts) == 4 and parts[0] == "slog2" and parts[2].startswith("j") and parts[2][1:].isdigit():
            grouped[(parts[1], int(parts[2][1:]))].append(r)
    return grouped


def _mean_spread(values: list[float]) -> tuple[float | None, float | None]:
    if not values:
        return None, None
    mean = sum(values) / len(values)
    spread = (max(values) - min(values)) / mean * 100.0 if mean > 0 else None
    return mean, spread


def _slog_verdict(std: tuple, rm: tuple) -> str:
    if std[0] is None or rm[0] is None:
        return "資料不完整"
    if any(s is not None and s > SPREAD_WARN_PCT for s in (std[1], rm[1])):
        return f"不穩定（重複差異>{SPREAD_WARN_PCT:.0f}%），不下結論"
    diff_pct = (std[0] / rm[0] - 1) * 100.0
    if abs(diff_pct) < SLOG_SIGNIFICANT_PCT:
        return "無顯著差異"
    return f"有 SLOG 快 {diff_pct:.0f}%" if diff_pct > 0 else f"有 SLOG 反而慢 {-diff_pct:.0f}%"


def section_slog2(out: list[str], round_dir: Path) -> None:
    out.append("## Phase 90 SLOG 併發度掃描（Round 2，ARC 48GiB，sync 4K 隨機寫，IOPS 為各重複平均）")
    if not any(round_dir.glob("90_slog2*")):
        out.append("(無資料)")
        out.append("")
        return

    grouped = collect_slog2(collect_round(round_dir))
    out.append(f"{'numjobs':>8}{'standard':>11}{'removed':>11}{'rawdev':>10}{'std/removed':>13}"
               f"{'std_p99us':>11}{'rm_p99us':>10}  判定")
    for n in sorted({n for _, n in grouped}):
        stats: dict[str, tuple[float | None, float | None, float | None]] = {}
        for cond in SLOG2_CONDITIONS:
            rs = grouped.get((cond, n), [])
            mean, spread = _mean_spread([r.write_iops() or 0 for r in rs])
            p99s = [r.write_lat_p99() for r in rs if r.write_lat_p99()]
            stats[cond] = (mean, spread, sum(p99s) / len(p99s) if p99s else None)
        std, rm, raw = stats["standard"], stats["removed"], stats["rawdev"]
        ratio = (std[0] / rm[0]) if std[0] and rm[0] else None
        out.append(f"{n:>8}{fmt(std[0], decimals=0):>11}{fmt(rm[0], decimals=0):>11}{fmt(raw[0], decimals=0):>10}"
                   f"{fmt(ratio, 'x', 2):>13}{fmt(std[2], decimals=0):>11}{fmt(rm[2], decimals=0):>10}"
                   f"  {_slog_verdict(std, rm)}")
    out.append("  (rawdev = 繞過 ZFS 直接對 SLOG 分割區做同併發度的 sync 寫，代表該硬體的 flush 上限)")
    out.append("")


def _job_by_name(data: dict, jobname: str) -> dict:
    for job in data.get("jobs", []):
        if job.get("jobname") == jobname:
            return job
    return {}


def _direction_stats(direction: dict) -> dict[str, float | None]:
    clat = direction.get("clat_ns", {})
    return {
        "iops": direction.get("iops"),
        "mean_us": ns_to_us(clat.get("mean")),
        "p99_us": ns_to_us(clat.get("percentile", {}).get("99.000000")),
    }


def collect_mixsync(phase_dir: Path) -> dict[str, list[dict]]:
    """名稱格式 mixsync_<cond>_r<rep>.json，jobs 內 mix_read / mix_write 兩個 group。"""
    grouped: dict[str, list[dict]] = defaultdict(list)
    for json_path in sorted(phase_dir.glob("mixsync_*_r*.json")):
        data = load_json(json_path)
        if not data:
            continue
        grouped[json_path.stem.split("_")[1]].append({
            "name": json_path.stem,
            "read": _direction_stats(_job_by_name(data, "mix_read").get("read", {})),
            "write": _direction_stats(_job_by_name(data, "mix_write").get("write", {})),
        })
    return grouped


def section_mixsync(out: list[str], round_dir: Path) -> None:
    out.append("## Phase 91 讀寫混合：16 讀取者（打向後端，L2ARC 已拆）+ 16 sync 寫入者，有無 SLOG")
    phase_dir = round_dir / "91_mixed_sync"
    if not phase_dir.exists():
        out.append("(無資料)")
        out.append("")
        return

    grouped = collect_mixsync(phase_dir)
    out.append(f"{'run':<24}{'read_iops':>10}{'read_p99(ms)':>14}{'sync_w_iops':>13}{'w_mean(us)':>12}{'w_p99(us)':>12}")
    for cond in ("standard", "removed"):
        for run in grouped.get(cond, []):
            r, w = run["read"], run["write"]
            out.append(f"{run['name']:<24}{fmt(r['iops'], decimals=0):>10}"
                       f"{fmt(r['p99_us'] / 1000 if r['p99_us'] else None, decimals=0):>14}"
                       f"{fmt(w['iops'], decimals=0):>13}{fmt(w['mean_us'], decimals=0):>12}{fmt(w['p99_us'], decimals=0):>12}")

    means = {cond: _mean_spread([run["write"]["iops"] or 0 for run in runs])[0]
             for cond, runs in grouped.items()}
    std, rm = means.get("standard"), means.get("removed")
    if std and rm:
        out.append(f"  sync 寫入 IOPS 平均: standard={std:.0f}  removed={rm:.0f}  倍率={std / rm:.1f}x")
    out.append("  (讀取者會把後端 LUN 打到飽和；沒有 SLOG 時 ZIL 寫入要和讀取排同一條佇列)")
    out.append("")


def section_arcsweep(out: list[str], round_dir: Path, ws_gib: float | None) -> None:
    out.append("## Phase 92 ARC 大小掃描（L2ARC 暖好，固定熱資料集，4 併發 4K 隨機讀）")
    sweep_dir = round_dir / "92_arcsweep"
    if not sweep_dir.exists():
        out.append("(無資料)")
        out.append("")
        return

    populate = parse_kv(sweep_dir / "arcsweep_populate_state.txt")
    if populate:
        used_warm_fallback = (sweep_dir / "arcsweep_warm_state.txt").exists()
        out.append(f"  L2ARC 暖機後 l2_asize={populate.get('l2_asize', 0) / GIB:.1f}GiB"
                   f"（{'覆寫不足，退回循序讀暖機' if used_warm_fallback else '覆寫填入即達標，未用循序讀暖機'}）"
                   f"  熱資料集={fmt(ws_gib, 'GiB', 1)}")

    results = collect_round(round_dir)
    log_avg_msec = read_log_avg_msec(sweep_dir)
    sizes = sorted(int(m.group(1)) for n in results if (m := re.fullmatch(r"arcsweep_(\d+)g", n)))
    out.append(f"{'ARC_GiB':>8}{'ARC/資料集':>11}{'r_iops':>9}{'steady':>9}{'ARC%':>7}{'L2%':>7}{'disk%':>7}"
               f"{'cap_by_miss':>12}{'p99(us)':>10}{'L2_GiB':>8}{'l2hdr_MiB':>10}")
    for gib in sizes:
        name = f"arcsweep_{gib}g"
        r = results[name]
        series = read_iops_series(sweep_dir, name, log_avg_msec)
        start = parse_kv(sweep_dir / f"{name}_state_start.txt")
        end = parse_kv(sweep_dir / f"{name}_state_end.txt")
        a = r.attribution or {}
        disk_pct = a.get("disk_pct")
        cap = BACKEND_RANDOM_READ_IOPS / (disk_pct / 100.0) if disk_pct and disk_pct >= 0.5 else None
        ratio = f"{gib / ws_gib * 100:.0f}%" if ws_gib else "n/a"
        l2_gib = start["l2_asize"] / GIB if "l2_asize" in start else None
        hdr_mib = end["l2_hdr_size"] / (1024 ** 2) if "l2_hdr_size" in end else None
        out.append(f"{gib:>8}{ratio:>11}{fmt(r.read_iops(), decimals=0):>9}{fmt(steady_iops(series), decimals=0):>9}"
                   f"{fmt(a.get('arc_hit_pct'), decimals=1):>7}{fmt(a.get('l2arc_hit_pct'), decimals=1):>7}"
                   f"{fmt(disk_pct, decimals=1):>7}{fmt(cap, decimals=0):>12}{fmt(r.read_lat_p99(), decimals=0):>10}"
                   f"{fmt(l2_gib, decimals=1):>8}{fmt(hdr_mib, decimals=0):>10}")
    if not sizes:
        out.append("(無資料)")
    out.append(f"  (cap_by_miss = {BACKEND_RANDOM_READ_IOPS} ÷ 未命中率：後端只能給約 {BACKEND_RANDOM_READ_IOPS} 次隨機讀/秒時，"
               "該未命中率下的 IOPS 上限；L2_GiB 為 export/import 後 L2ARC 保留量)")
    out.append("")


def section_env_highlights(out: list[str], round_dir: Path) -> None:
    out.append("## 儲存環境重點（完整內容見 round*/80_iso2/env_storage.txt）")
    env = round_dir / "80_iso2" / "env_storage.txt"
    if not env.exists():
        out.append("(無資料)")
        out.append("")
        return
    keys = ("## /sys/block", "write_cache", "rotational", "scheduler", "queue_depth", "vendor", "model",
            "Target:", "logbias", "sync", "ashift", "zfs_dirty_data_max", "zil_slog_bulk")
    out.extend(f"  {line}" for line in env.read_text().splitlines() if any(k in line for k in keys))
    out.append("")


def _dataset_gib(results_dir: Path) -> float | None:
    """從診斷測試檔的填充率斷言檔取得熱資料集大小（GiB）。"""
    fill = results_dir / "setup" / "fill_ratio_iso2.txt"
    if not fill.exists():
        return None
    for line in fill.read_text().splitlines():
        if line.startswith("apparent_bytes="):
            return int(line.split("=", 1)[1]) / GIB
    return None


def main() -> None:
    if len(sys.argv) != 2:
        print("用法: python3 summarize_diag.py <results_dir>", file=sys.stderr)
        sys.exit(1)
    results_dir = Path(sys.argv[1])
    if not results_dir.is_dir():
        print(f"找不到目錄: {results_dir}", file=sys.stderr)
        sys.exit(1)

    out: list[str] = ["# fio-zfs-bench 診斷摘要 (--diag)", f"# 產出目錄: {results_dir}", ""]

    failures = load_failures(results_dir)
    out.append("## 已知失敗/跳過項目")
    out.extend(f"  {line}" for line in failures) if failures else out.append("(無)")
    out.append("")

    fill = results_dir / "setup" / "fill_ratio_iso2.txt"
    if fill.exists():
        out.append("## 診斷測試檔填充率斷言")
        out.extend(f"  {line}" for line in fill.read_text().splitlines())
        out.append("")

    iso_by_round: dict[str, dict[str, TestResult]] = {}
    for round_name in ("round1", "round2"):
        round_dir = results_dir / round_name
        if (round_dir / "80_iso2").exists():
            iso_by_round[round_name] = section_iso2_round(out, round_name, round_dir)

    if iso_by_round:
        section_clean_contribution(out, iso_by_round)

    round2 = results_dir / "round2"
    if round2.exists():
        section_slog2(out, round2)
        if (round2 / "91_mixed_sync").exists():
            section_mixsync(out, round2)
        if (round2 / "92_arcsweep").exists():
            section_arcsweep(out, round2, _dataset_gib(results_dir))
    for round_name in ("round1", "round2"):
        if (results_dir / round_name / "80_iso2" / "env_storage.txt").exists():
            section_env_highlights(out, results_dir / round_name)
            break

    summary_path = results_dir / "diag_summary.txt"
    summary_path.write_text("\n".join(out) + "\n")
    print(f"已產出 {summary_path}")


if __name__ == "__main__":
    main()
