#!/bin/bash
# run_all.sh - 進入點。驅動 preflight -> 停 VM -> 兩輪測試（ARC 3.13GiB / 48GiB）
# -> 每輪跑 8 個 phase -> 還原所有組態 -> 產出 summary.txt。
#
# 用法:
#   ./run_all.sh --preflight-only   只跑安全檢查，不執行任何測試/不動 VM
#   ./run_all.sh --smoke            縮小規模驗證邏輯（約 10-15 分鐘）
#   ./run_all.sh --full             正式規模（約 10 小時，兩輪）
#
# 建議搭配 nohup 背景執行:
#   nohup ./run_all.sh --smoke > smoke.out 2>&1 & echo $! > run.pid

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION=""
ROUND_ONLY=""
for arg in "$@"; do
    case "$arg" in
        --preflight-only) ACTION="preflight-only" ;;
        --smoke)          ACTION="run"; MODE="smoke" ;;
        --full)           ACTION="run"; MODE="full" ;;
        --round=1|--round=2) ROUND_ONLY="${arg#--round=}" ;;
        *) echo "未知參數: $arg" >&2; exit 1 ;;
    esac
done
if [[ -z "$ACTION" ]]; then
    echo "用法: $0 --preflight-only | --smoke | --full [--round=1|--round=2]" >&2
    exit 1
fi
MODE="${MODE:-smoke}"
export MODE

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# --round=N：只跑指定的一輪（例如上次跑到一半中止後只補跑 Round 2）
[[ -n "$ROUND_ONLY" ]] && ROUNDS=("$ROUND_ONLY")
# shellcheck source=lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/vmctl.sh
source "${SCRIPT_DIR}/lib/vmctl.sh"
# shellcheck source=lib/monitor.sh
source "${SCRIPT_DIR}/lib/monitor.sh"
# shellcheck source=lib/arcstats.sh
source "${SCRIPT_DIR}/lib/arcstats.sh"
# shellcheck source=lib/fiorun.sh
source "${SCRIPT_DIR}/lib/fiorun.sh"

if [[ "$ACTION" == "preflight-only" ]]; then
    run_preflight_basic
    log_info "Preflight-only 模式結束，未執行任何測試、未變更任何組態"
    exit 0
fi

# ---- 以下為實際執行測試的路徑 ----

# shellcheck source=phases/00_prepare.sh
source "${SCRIPT_DIR}/phases/00_prepare.sh"
# shellcheck source=phases/10_prefill.sh
source "${SCRIPT_DIR}/phases/10_prefill.sh"
# shellcheck source=phases/20_l2arc_warm.sh
source "${SCRIPT_DIR}/phases/20_l2arc_warm.sh"
# shellcheck source=phases/30_isolation.sh
source "${SCRIPT_DIR}/phases/30_isolation.sh"
# shellcheck source=phases/40_coldhot.sh
source "${SCRIPT_DIR}/phases/40_coldhot.sh"
# shellcheck source=phases/50_write.sh
source "${SCRIPT_DIR}/phases/50_write.sh"
# shellcheck source=phases/60_mixed.sh
source "${SCRIPT_DIR}/phases/60_mixed.sh"
# shellcheck source=phases/70_slog.sh
source "${SCRIPT_DIR}/phases/70_slog.sh"

TS="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="${BASE_DIR}/results/${TS}"
mkdir -p "$RESULTS_DIR"
init_failure_log "${RESULTS_DIR}/failures.log"

_RESTORED=0
_on_exit() {
    local rc=$?
    if (( _RESTORED == 0 )); then
        _RESTORED=1
        restore_state
    fi
    exit "$rc"
}
trap _on_exit EXIT
trap 'log_error "收到中斷訊號"; exit 1' INT TERM

log_section "run_all.sh 開始 (MODE=$MODE, RESULTS_DIR=$RESULTS_DIR)"

run_preflight_basic
save_state
stop_vms
run_preflight_export_ready

set_arc_max_for_round() {
    local round="$1"
    local target
    if [[ "$round" == "1" ]]; then
        target="$ORIG_ARC_MAX"
    else
        target="$ARC_MAX_ROUND2_BYTES"
    fi
    log_info "設定 zfs_arc_max = $target (round $round)"
    if ! echo "$target" > "$ARC_MAX_PARAM"; then
        record_failure "round${round}:set_arc_max" "設定 zfs_arc_max=$target 失敗，本輪 ARC 上限可能仍是先前的值，但仍繼續執行本輪測試"
    fi
}

load_state  # 取得 ORIG_ARC_MAX 供 round1 使用

for round in "${ROUNDS[@]}"; do
    log_section "===== Round $round 開始 ====="
    set_arc_max_for_round "$round"
    sleep 5  # 讓 arc_max 生效

    round_dir="${RESULTS_DIR}/round${round}"
    mkdir -p "$round_dir"

    phase_00_prepare     "${round_dir}/00_prepare"    || record_failure "round${round}:00_prepare"    "phase 回傳非零狀態，繼續下一階段"
    phase_10_prefill      "${round_dir}/10_prefill"    || record_failure "round${round}:10_prefill"    "phase 回傳非零狀態，繼續下一階段"
    phase_20_l2arc_warm   "${round_dir}/20_l2arc_warm" || record_failure "round${round}:20_l2arc_warm" "phase 回傳非零狀態，繼續下一階段"
    phase_30_isolation    "${round_dir}/30_isolation"  || record_failure "round${round}:30_isolation"  "phase 回傳非零狀態，繼續下一階段"
    phase_40_coldhot      "${round_dir}/40_coldhot"    || record_failure "round${round}:40_coldhot"    "phase 回傳非零狀態，繼續下一階段"
    phase_50_write        "${round_dir}/50_write"      || record_failure "round${round}:50_write"      "phase 回傳非零狀態，繼續下一階段"
    phase_60_mixed        "${round_dir}/60_mixed"      || record_failure "round${round}:60_mixed"      "phase 回傳非零狀態，繼續下一階段"
    phase_70_slog         "${round_dir}/70_slog"       || record_failure "round${round}:70_slog"       "phase 回傳非零狀態，繼續下一階段"

    log_section "===== Round $round 結束 ====="
done

log_section "產出 summary.txt"
python3 "${SCRIPT_DIR}/summarize.py" "$RESULTS_DIR" || log_warn "summarize.py 執行失敗，請人工檢查 $RESULTS_DIR"

log_info "run_all.sh 全部完成: $RESULTS_DIR"
