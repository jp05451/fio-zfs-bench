#!/bin/bash
# run_all.sh - 進入點。驅動 preflight -> 停 VM -> 兩輪測試（ARC 3.13GiB / 48GiB）
# -> 每輪跑 8 個 phase -> 還原所有組態 -> 產出 summary.txt。
#
# 用法:
#   ./run_all.sh --preflight-only   只跑安全檢查，不執行任何測試/不動 VM
#   ./run_all.sh --smoke            縮小規模驗證邏輯（約 10-15 分鐘）
#   ./run_all.sh --full             正式規模（約 10 小時，兩輪）
#   ./run_all.sh --full --round=2   只跑指定的一輪（--round=1 或 --round=2，中止後補跑用）
#   ./run_all.sh --full --diag      診斷模式：只跑 Phase 80（隔離矩陣 v2）與 Phase 90（SLOG 併發掃描），
#                                   會暫時拆裝 L2ARC 與 SLOG 裝置（約 4 小時）；--smoke --diag 為縮小規模驗證
#
# 建議搭配 nohup 背景執行:
#   nohup ./run_all.sh --smoke > smoke.out 2>&1 & echo $! > run.pid

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION=""
ROUND_ONLY=""
DIAG=0
for arg in "$@"; do
    case "$arg" in
        --preflight-only) ACTION="preflight-only" ;;
        --smoke)          ACTION="run"; MODE="smoke" ;;
        --full)           ACTION="run"; MODE="full" ;;
        --round=1|--round=2) ROUND_ONLY="${arg#--round=}" ;;
        --diag)           DIAG=1 ;;
        *) echo "未知參數: $arg" >&2; exit 1 ;;
    esac
done
if [[ -z "$ACTION" ]]; then
    echo "用法: $0 --preflight-only | --smoke | --full [--round=1|--round=2] [--diag]" >&2
    exit 1
fi
if [[ "$DIAG" == "1" && "$ACTION" != "run" ]]; then
    echo "--diag 必須搭配 --smoke 或 --full" >&2
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
# shellcheck source=lib/l2arc.sh
source "${SCRIPT_DIR}/lib/l2arc.sh"

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
# shellcheck source=phases/80_iso2.sh
source "${SCRIPT_DIR}/phases/80_iso2.sh"
# shellcheck source=phases/90_slog2.sh
source "${SCRIPT_DIR}/phases/90_slog2.sh"

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
# 診斷模式會拆裝 L2ARC：必須在 save_state 之前確認它目前在位，否則狀態檔會記下空的裝置名稱而無法還原
if [[ "$DIAG" == "1" && -z "$L2ARC_DEVICE" ]]; then
    die "--diag 需要 pool 上有 L2ARC (cache) 裝置，但 zpool status ${POOL} 找不到；若上次中斷過請先參考 state/original.env 的 ORIG_L2ARC_DEVICE 手動裝回"
fi
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

# --diag：只跑診斷 phase（80 隔離矩陣 v2、90 SLOG 併發掃描），不重做預熱與其他 phase。
# Phase 90 只在 Round 2（ARC 48GiB，測試檔全進記憶體）跑，讓 sync 寫入不混入讀取。
run_diag_flow() {
    phase_00_prepare "${RESULTS_DIR}/setup/00_prepare" \
        || record_failure "diag:00_prepare" "phase 回傳非零狀態，繼續下一階段"
    phase_80_iso2_setup "${RESULTS_DIR}/setup" \
        || record_failure "diag:setup" "診斷測試檔建立失敗，Phase 80 各輪將被略過"

    local round round_dir
    for round in "${ROUNDS[@]}"; do
        log_section "===== 診斷 Round $round 開始 ====="
        set_arc_max_for_round "$round"
        sleep 5  # 讓 arc_max 生效

        round_dir="${RESULTS_DIR}/round${round}"
        mkdir -p "$round_dir"

        phase_80_iso2 "${round_dir}/80_iso2" \
            || record_failure "round${round}:80_iso2" "phase 回傳非零狀態，繼續下一階段"
        if [[ "$round" == "2" ]]; then
            phase_90_slog2 "${round_dir}/90_slog2" \
                || record_failure "round${round}:90_slog2" "phase 回傳非零狀態，繼續下一階段"
        fi

        log_section "===== 診斷 Round $round 結束 ====="
    done

    phase_80_iso2_cleanup

    log_section "產出 diag_summary.txt"
    python3 "${SCRIPT_DIR}/summarize_diag.py" "$RESULTS_DIR" \
        || log_warn "summarize_diag.py 執行失敗，請人工檢查 $RESULTS_DIR"
}

load_state  # 取得 ORIG_ARC_MAX 供 round1 使用

if [[ "$DIAG" == "1" ]]; then
    run_diag_flow
    log_info "run_all.sh 診斷模式全部完成: $RESULTS_DIR"
    exit 0   # 由 EXIT trap 執行 restore_state
fi

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
