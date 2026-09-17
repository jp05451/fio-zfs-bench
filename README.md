# fio-zfs-bench

針對 ZFS pool 拆解 ARC / L2ARC / SLOG 各自對 I/O 效能的貢獻度，產出可歸因的量化數據，用來評估這台機器是否適合承載高密度 4K 隨機 I/O + 密集 fsync 的工作負載（設計目標為 Hyperledger Fabric 模擬節點）。

## 這套工具做什麼

1. **循序填滿測試資料**（非稀疏檔），並用填充率斷言確保後續讀取測試不會打到空洞
2. 在同一份資料上切換 `primarycache`/`secondarycache` 屬性，用差分法拆解 **ARC 貢獻** 與 **L2ARC 貢獻**
3. 用 `zpool export/import` 保證 ARC 完全清空，做冷讀 vs 熱讀對照
4. 用屬性法（`sync=standard` vs `sync=disabled`）與拔除法（暫時移除 SLOG 裝置）量化 **SLOG 貢獻**
5. 對 ARC 上限做兩輪對照（預設值 vs 放大後的值），觀察加大 ARC 的實際增益
6. 全程監控 `zpool iostat` / `arcstat` / `arcstats` 差值，換算成「ARC 命中 % : L2ARC 命中 % : 實體磁碟 %」三層歸因
7. 產出 `summary.txt`，包含歸因表、冷熱對比倍率、各層貢獻量化、Round1 vs Round2 對照、已知失敗/跳過項目

## 安裝設定

```bash
cp .env.example .env
```

編輯 `.env`，填入你環境的實際值：

| 變數 | 說明 |
|---|---|
| `POOL` | ZFS pool 名稱 |
| `ISCSI_STORAGE_ID` | Proxmox storage ID（底層對應到上面的 pool），用於動態掃描哪些 VM 用到這顆儲存 |
| `NEVER_TOUCH_VMS` | 絕不觸碰（測試期間絕不停機）的 VM ID 清單，以空白分隔 |

`.env` 內容為此主機的基礎設施識別資訊，**不會提交進 git**（已列在 `.gitignore`）。`.env.example` 只是格式範本，可安全提交。

以下兩項不需要設定，程式會自動偵測，避免設定檔過期：

- **SLOG 裝置**：從 `zpool status $POOL` 的 `logs` 區塊即時讀取，換過 SLOG 硬碟後不需要改設定
- **部署路徑**：就是 `run_all.sh` 所在目錄，`results/`、`state/` 都存在這裡面

## 用法

```bash
./run_all.sh --preflight-only   # 只跑安全檢查，不執行任何測試、不動 VM
./run_all.sh --smoke            # 縮小規模驗證邏輯（約 10-15 分鐘）
./run_all.sh --full             # 正式規模（約 10 小時，兩輪）
```

建議搭配 `nohup` 背景執行正式規模的測試：

```bash
nohup ./run_all.sh --full > full.out 2>&1 & echo $! > run.pid
```

執行前，`scan_iscsi_vms()` 會動態掃描目前哪些 VM 的硬碟/efidisk/tpmstate 掛在 `ISCSI_STORAGE_ID` 上（`NEVER_TOUCH_VMS` 白名單內的機器一律排除），停止其中正在運行的機器，測試結束後只還原「本次因測試而停機」的那些機器——原本就停機的機器絕不會被啟動。

## 安全機制

- **Preflight 檢查**：無其他 fio 行程在跑、pool 健康、掛載可寫、可用空間足夠、必要工具存在、`zfs_arc_max` 可寫、測試池上所有應停機 VM 均已停機——任何一項失敗直接中止，不自動修復
- **狀態檔 + 還原**：開跑前把 `zfs_arc_max`、`l2arc_write_max`、當時運行中的 VM 清單、SLOG 是否存在寫入 `state/original.env`；全域 `trap EXIT/INT/TERM` 保證中斷或崩潰時仍會還原
- **白名單防呆**：`NEVER_TOUCH_VMS` 內的機器即使日後被搬到同一顆儲存上，也絕不會被停機或啟動
- **try/catch 式容錯**：只有真正危險的情況（VM 停機失敗/逾時、`zpool import` 重試多次仍失敗、SLOG 裝回失敗、狀態檔遺失）才會中止整個流程；其餘資料品質類的失敗（單一屬性設定失敗、單一測試回傳非零、單一 tier 的 export/import 失敗）都會記錄進 `failures.log` 並繼續跑下一項，確保一次測試失敗不會讓其他 9 個多小時的結果全部消失
- 全程不觸碰 `.env` 設定範圍以外的 pool/storage

## 檔案結構

```
run_all.sh              # 入口：驅動 preflight → 停 VM → 兩輪測試 → 還原 → summary
lib/
  common.sh             # 共用常數（讀取 .env）、log 函式、容錯輔助、VM 掃描、尺寸換算
  preflight.sh          # 所有前置安全檢查
  state.sh              # 記錄/還原原始組態
  vmctl.sh              # 停機/復原 VM
  monitor.sh            # 背景採樣器（zpool iostat / arcstat）的啟停
  arcstats.sh           # arcstats 快照與差值計算
  fiorun.sh             # 包裝 fio：前後快照 + 監控 + JSON 輸出
phases/
  00_prepare.sh          # 建立測試 dataset、設定屬性
  10_prefill.sh          # 循序填滿各 tier + 填充率斷言
  20_l2arc_warm.sh       # L2ARC 暖機
  30_isolation.sh        # raw / arconly / full 三組態隔離矩陣
  40_coldhot.sh          # export/import 冷讀 + 連續熱讀
  50_write.sh            # 同步/非同步寫入
  60_mixed.sh            # 混合讀寫
  70_slog.sh             # SLOG 屬性法 + 拔除法對照
summarize.py             # 解析 fio JSON + arcstats 差值 → summary.txt
results/<timestamp>/     # 每次執行的輸出（含 failures.log），已列入 .gitignore
state/original.env       # 執行期間的原始組態快照，已列入 .gitignore
```

## 輸出結果

`results/<timestamp>/summary.txt` 內容包含：

1. 環境快照與填充率斷言結果
2. 各測試的 IOPS / 頻寬 / 延遲百分位
3. 快取歸因表（ARC % : L2ARC % : 磁碟 %）
4. 冷熱對比倍率
5. 各層貢獻量化（ARC / L2ARC / SLOG / fsync 成本）
6. Round 1 vs Round 2（ARC 上限調整前後）對照
7. 已知失敗/跳過項目（來自 `failures.log`）

## 需求

`fio`、`zpool`/`zfs`、`qm`（Proxmox CLI）、`arcstat`、`python3`、`bash` 4+（`declare -A` 需要，macOS 內建 bash 3.2 無法直接執行，僅能語法檢查）。
