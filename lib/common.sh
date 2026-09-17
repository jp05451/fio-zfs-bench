#!/bin/bash
# common.sh - 共用常數、log 函式、尺寸換算
# 由 run_all.sh 與所有 phases/*.sh source，需先設定 MODE=smoke|full 才能取得正確參數。

set -uo pipefail

# ---- log 函式（提前到最前面，因為載入 .env 時就需要用來報錯）----
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { echo "[$(_ts)] [INFO]  $*"; }
log_warn()    { echo "[$(_ts)] [WARN]  $*" >&2; }
log_error()   { echo "[$(_ts)] [ERROR] $*" >&2; }
log_section() { echo; echo "===== [$(_ts)] $* ====="; }

die() {
    log_error "$*"
    exit 1
}

# ---- 載入環境專屬設定（.env，內容為此主機的基礎設施識別資訊，不進 git）----
# SCRIPT_DIR 由 run_all.sh 在 source 本檔之前設定。
ENV_FILE="${SCRIPT_DIR:?SCRIPT_DIR 未設定，common.sh 須由 run_all.sh source}/.env"
[[ -f "$ENV_FILE" ]] || die "找不到 $ENV_FILE，請先複製 .env.example 為 .env 並填入正確值"
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

: "${POOL:?POOL 未設定，請檢查 .env}"
: "${ISCSI_STORAGE_ID:?ISCSI_STORAGE_ID 未設定，請檢查 .env}"
: "${SLOG_DEVICE:?SLOG_DEVICE 未設定，請檢查 .env}"
: "${NEVER_TOUCH_VMS:?NEVER_TOUCH_VMS 未設定，請檢查 .env}"
: "${BASE_DIR:?BASE_DIR 未設定，請檢查 .env}"
NEVER_TOUCH_VMS=($NEVER_TOUCH_VMS)   # .env 存的是空白分隔字串，這裡轉成陣列

# ---- 路徑常數 ----
DATASET="${POOL}/fiotest"
DATASET_MOUNT="/${DATASET}"
STATE_DIR="${BASE_DIR}/state"
ARCSTATS_PATH="/proc/spl/kstat/zfs/arcstats"

# ---- ZFS 可調參數路徑 ----
ARC_MAX_PARAM="/sys/module/zfs/parameters/zfs_arc_max"
L2ARC_WRITE_MAX_PARAM="/sys/module/zfs/parameters/l2arc_write_max"
ARC_MAX_ROUND2_BYTES=51539607552   # 48 GiB
L2ARC_WRITE_MAX_WARM_BYTES=536870912  # 512 MiB/s，暖機期間暫時調高

# ---- VM 分組 ----
# 不再寫死 VM 清單：改成動態掃描「哪些 VM 的硬碟/efidisk/tpmstate 掛在這個 Proxmox storage 上」，
# 見 scan_iscsi_vms()。NEVER_TOUCH_VMS（.env 設定）是唯一絕對不可觸碰的白名單。

# ---- fio 基準參數 ----
FIO_COMMON_ARGS=(--ioengine=psync --bs=4K --numjobs=4 --iodepth=1
                  --time_based --group_reporting --randrepeat=0 --norandommap
                  --output-format=json+)

# ---- MODE 相關參數（MODE 需在 source 本檔前設定為 smoke 或 full）----
MODE="${MODE:-smoke}"

if [[ "$MODE" == "smoke" ]]; then
    TIER_NAMES=(t1 t2)                 # 跳過 300G 級
    declare -A TIER_SIZE_MIB=([t1]=256 [t2]=2048)
    RUNTIME_ISOLATION=20
    RUNTIME_COLDHOT=20
    RUNTIME_WRITE=20
    RUNTIME_MIXED=20
    RUNTIME_SLOG=20
    L2ARC_WARM_DURATION=60
    SETTLE_AFTER_IMPORT=10
    ROUNDS=(1 2)
    WRITE_TEST_SIZE_MIB=256
    MIXED_TEST_SIZE_MIB=256
    SLOG_TEST_SIZE_MIB=128
else
    TIER_NAMES=(t1 t2 t3)
    declare -A TIER_SIZE_MIB=([t1]=2048 [t2]=65536 [t3]=307200)
    RUNTIME_ISOLATION=600
    RUNTIME_COLDHOT=300
    RUNTIME_WRITE=1800
    RUNTIME_MIXED=1800
    RUNTIME_SLOG=600
    L2ARC_WARM_DURATION=2400
    SETTLE_AFTER_IMPORT=60
    ROUNDS=(1 2)
    WRITE_TEST_SIZE_MIB=4096
    MIXED_TEST_SIZE_MIB=4096
    SLOG_TEST_SIZE_MIB=2048
fi

MIN_FILL_RATIO="0.95"   # 預熱填充率斷言門檻
MIN_AVAIL_GIB=500       # preflight 最低可用空間

# ---- 容錯輔助：記錄失敗但絕不中止腳本（僅安全關鍵項目才用 die）----
FAILURES_LOG=""

# run_all.sh 建立 RESULTS_DIR 後呼叫一次，之後 record_failure 才會落地成檔案
init_failure_log() {
    FAILURES_LOG="$1"
    mkdir -p "$(dirname "$FAILURES_LOG")"
    : > "$FAILURES_LOG"
}

# 記錄一筆非致命失敗：印出 ERROR 並（若已 init）寫入 failures.log。
# 一律回傳 0（純記錄，不影響流程）；需要跳過/continue 由呼叫端自行用 if 判斷原始指令是否失敗。
record_failure() {
    local context="$1" message="$2"
    log_error "[SOFT-FAIL] ${context}: ${message}"
    if [[ -n "$FAILURES_LOG" ]]; then
        echo "$(_ts)|${context}|${message}" >> "$FAILURES_LOG"
    fi
    return 0
}

# ---- VM 掃描輔助 ----
_in_array() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# 掃描目前所有 VM，回傳「硬碟/efidisk/tpmstate 任一項掛在 $ISCSI_STORAGE_ID 上」
# 且不在 NEVER_TOUCH_VMS 白名單中的 vmid 清單（每行一個）。
scan_iscsi_vms() {
    local vmid cfg
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        _in_array "$vmid" "${NEVER_TOUCH_VMS[@]}" && continue
        cfg=$(qm config "$vmid" 2>/dev/null) || continue
        if grep -qE ": *${ISCSI_STORAGE_ID}:" <<< "$cfg"; then
            echo "$vmid"
        fi
    done < <(qm list 2>/dev/null | awk 'NR>1{print $1}')
}

# ---- 尺寸換算 ----
mib_to_bytes() { echo $(( "$1" * 1024 * 1024 )); }
gib_to_bytes() { echo $(( "$1" * 1024 * 1024 * 1024 )); }

# 回傳 tier 檔名對應大小（MiB）
tier_size_mib() {
    local tier="$1"
    echo "${TIER_SIZE_MIB[$tier]}"
}

tier_file() {
    local tier="$1"
    echo "${DATASET_MOUNT}/${tier}.dat"
}
