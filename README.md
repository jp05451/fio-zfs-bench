# fio-zfs-bench

針對 ZFS pool 拆解 ARC / L2ARC / SLOG 各自對 I/O 效能的貢獻度，產出可歸因的量化數據，用來評估這台機器是否適合承載高密度 4K 隨機 I/O + 密集 fsync 的工作負載（設計目標為 Hyperledger Fabric 模擬節點）。

## 這套工具做什麼

1. **循序填滿測試資料**（非稀疏檔），並用填充率斷言確保後續讀取測試不會打到空洞
2. 在同一份資料上切換 `primarycache`/`secondarycache` 屬性，用差分法拆解 **ARC 貢獻** 與 **L2ARC 貢獻**
3. 用 `zpool export/import` 保證 ARC 完全清空，做冷讀 vs 熱讀對照
4. 用屬性法（`sync=standard` vs `sync=disabled`）與拔除法（暫時移除 SLOG 裝置）量化 **SLOG 貢獻**：每種組態用獨立檔案重複多次、執行順序打亂，並附一組 SLOG 分割區的裸裝置基準線用來交叉驗證
5. 對 ARC 上限做兩輪對照（預設值 vs 放大後的值），觀察加大 ARC 的實際增益
6. 全程監控 `zpool iostat` / `arcstat` / `arcstats` 差值，換算成「ARC 命中 % : L2ARC 命中 % : 實體磁碟 %」三層歸因
7. 產出 `summary.txt`，包含歸因表、冷熱對比倍率、各層貢獻量化、Round1 vs Round2 對照、已知失敗/跳過項目
8. **診斷模式 `--diag`**：用更嚴謹的方法重新驗證第 2、4 項的結論（見下方「診斷模式」）

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

以下不需要設定，程式會自動偵測，避免設定檔過期：

- **SLOG 裝置**：從 `zpool status $POOL` 的 `logs` 區塊即時讀取，換過 SLOG 硬碟後不需要改設定
- **L2ARC 裝置**：從 `zpool status $POOL` 的 `cache` 區塊即時讀取（只有 `--diag` 需要它存在）
- **部署路徑**：就是 `run_all.sh` 所在目錄，`results/`、`state/` 都存在這裡面

## 用法

```bash
./run_all.sh --preflight-only     # 只跑安全檢查，不執行任何測試、不動 VM
./run_all.sh --smoke              # 縮小規模驗證邏輯（約 10-15 分鐘）
./run_all.sh --full               # 正式規模（約 12 小時，兩輪）
./run_all.sh --full --round=2     # 只跑指定的一輪（--round=1 或 --round=2），中止後補跑用
./run_all.sh --smoke --diag       # 診斷模式縮小規模驗證（約 10 分鐘）
./run_all.sh --full --diag        # 診斷模式正式規模（約 3.5-4 小時）
```

建議背景執行正式規模的測試。若是透過 `ssh` 遠端啟動，請把 stdin/stdout 都重導並用 `setsid`，否則背景行程會握住 ssh 連線，指令一直不返回：

```bash
setsid nohup ./run_all.sh --full > full.out 2>&1 < /dev/null &
```

之後用另一條 ssh 連線確認：`pgrep -af '[r]un_all\.sh'`，並 `tail full.out` 看進度。

執行前，`scan_iscsi_vms()` 會動態掃描目前哪些 VM 的硬碟/efidisk/tpmstate 掛在 `ISCSI_STORAGE_ID` 上（`NEVER_TOUCH_VMS` 白名單內的機器一律排除），停止其中正在運行的機器，測試結束後只還原「本次因測試而停機」的那些機器——原本就停機的機器（包括開跑前你手動停掉的）絕不會被腳本啟動，需要你自己 `qm start`。

## 診斷模式（`--diag`）

一般模式的隔離測試（Phase 30）與 SLOG 測試（Phase 70）有幾個已知的方法學缺陷，`--diag` 用兩個新的 phase 重新驗證，不重做預熱與其他 phase：

| 缺陷 | 說明 | 診斷模式的作法 |
|---|---|---|
| 隔離組態不乾淨 | `primarycache=none` / `secondarycache=none` 只阻止「新資料進快取」，不會讓已在 ARC/L2ARC 的資料失效，`raw` 組態仍會命中前一階段暖機留下的快取，導致快取貢獻被低估 | **Phase 80**：每個組態先移除 L2ARC 裝置（重新加入後為全新空裝置）、再 `export/import` 清空 ARC |
| 量到的是暖機過程 | 低 IOPS 下快取只在未命中時填入，填滿要好幾個小時，單次測試量到的不是穩態 | **Phase 80**：先循序讀整個測試檔暖機，再量 5–15 分鐘並以 fio iops log 記錄逐時 IOPS，可看出是否收斂 |
| SLOG 只測過 4 併發 | 4 併發下 SLOG 已頂到自己的 flush 上限，看不出併發提高後的差異 | **Phase 90**（僅 Round 2）：併發數 1/4/16/64 × {有 SLOG, 拔除 SLOG, SLOG 裸裝置} × 重複 2 次，順序打亂 |

Phase 80 另外會記錄儲存環境快照（`env_storage.txt`）：iSCSI LUN 的 `write_cache` / `rotational` / 佇列深度、iscsiadm session 參數、相關 ZFS 可調參數，用來解釋後端 sync 寫入為何那麼快。

**副作用**：診斷模式會暫時拆裝 L2ARC 與 SLOG 裝置，並暫時調高 `l2arc_write_max`、把 `l2arc_noprefetch` 設為 0。這些都是線上可逆操作，且有雙重保險：每個 phase 結束時立即裝回，全域 `trap` 也會在中斷/崩潰時裝回並還原參數。診斷測試檔為獨立的 `iso2_t2.dat`（與一般模式的 tier 檔案分開），結束時自動刪除。

診斷模式需要 pool 上已有 L2ARC (cache) 裝置，否則 preflight 直接中止。輸出為 `results/<timestamp>/diag_summary.txt`。

## 安全機制

- **Preflight 檢查**：無其他 fio 行程在跑、pool 健康、掛載可寫、可用空間足夠、必要工具存在、`zfs_arc_max` 可寫、測試池上所有應停機 VM 均已停機；`--diag` 另外要求 L2ARC 裝置存在——任何一項失敗直接中止，不自動修復
- **狀態檔 + 還原**：開跑前把 `zfs_arc_max`、`l2arc_write_max`、`l2arc_noprefetch`、當時運行中的 VM 清單、SLOG 是否存在、L2ARC 裝置名稱寫入 `state/original.env`；全域 `trap EXIT/INT/TERM` 保證中斷或崩潰時仍會還原參數、裝回 SLOG 與 L2ARC
- **白名單防呆**：`NEVER_TOUCH_VMS` 內的機器即使日後被搬到同一顆儲存上，也絕不會被停機或啟動
- **try/catch 式容錯**：只有真正危險的情況（VM 停機失敗/逾時、`zpool import` 重試多次仍失敗、SLOG/L2ARC 裝回失敗、狀態檔遺失）才會中止整個流程；其餘資料品質類的失敗（單一屬性設定失敗、單一測試回傳非零、單一 tier 的 export/import 失敗）都會記錄進 `failures.log` 並繼續跑下一項，確保一次測試失敗不會讓其他數小時的結果全部消失
- **export/import 競態處理**：`zpool export` 後 pool 可能被 zed 等機制自動 import 回來，導致後續手動 `zpool import` 回報 "already exists"。重試迴圈每次先確認 pool 是否已在線，並在重試間做 `udevadm settle`
- 全程不觸碰 `.env` 設定範圍以外的 pool/storage

## 檔案結構

```
run_all.sh              # 入口：驅動 preflight → 停 VM → 兩輪測試（或 --diag）→ 還原 → summary
lib/
  common.sh             # 共用常數（讀取 .env）、log 函式、容錯輔助、VM 掃描、SLOG/L2ARC 自動偵測、尺寸換算
  preflight.sh          # 所有前置安全檢查
  state.sh              # 記錄/還原原始組態（arc_max、l2arc 參數、VM、SLOG、L2ARC 裝置）
  vmctl.sh              # 停機/復原 VM
  monitor.sh            # 背景採樣器（zpool iostat / arcstat / iostat）的啟停
  arcstats.sh           # arcstats 快照
  fiorun.sh             # 包裝 fio：前後快照 + 監控 + JSON 輸出
  l2arc.sh              # L2ARC 裝置拆裝（診斷模式用）與 ARC/L2ARC 大小快照
phases/
  00_prepare.sh          # 建立測試 dataset、設定屬性
  10_prefill.sh          # 循序填滿各 tier + 填充率斷言
  20_l2arc_warm.sh       # L2ARC 暖機
  30_isolation.sh        # raw / arconly / full 三組態隔離矩陣（不清快取，見「已知限制」）
  40_coldhot.sh          # export/import 冷讀 + 連續熱讀
  50_write.sh            # 同步/非同步寫入
  60_mixed.sh            # 混合讀寫
  70_slog.sh             # SLOG 屬性法 + 拔除法 + 裸裝置基準線（重複 + 打亂順序）
  80_iso2.sh             # [--diag] 乾淨的隔離矩陣 v2 + 暖機 + 逐時 IOPS + 儲存環境快照
  90_slog2.sh            # [--diag] SLOG 併發度掃描（Round 2）
summarize.py             # 解析 fio JSON + arcstats 差值 → summary.txt
summarize_diag.py        # 解析診斷模式輸出 → diag_summary.txt（沿用 summarize.py 的解析函式）
results/<timestamp>/     # 每次執行的輸出（含 failures.log），已列入 .gitignore
state/original.env       # 執行期間的原始組態快照，已列入 .gitignore
```

## 輸出結果

`results/<timestamp>/summary.txt`（一般模式）內容包含：

1. 環境快照與填充率斷言結果
2. 各測試的 IOPS / 頻寬 / 延遲百分位
3. 快取歸因表（ARC % : L2ARC % : 磁碟 %）
4. 冷熱對比倍率
5. SLOG 重複測試明細（含重複間差異超過 15% 的不穩定警告）與裸裝置基準線
6. 各層貢獻量化（ARC / L2ARC / SLOG / fsync 成本）
7. Round 1 vs Round 2（ARC 上限調整前後）對照
8. 已知失敗/跳過項目（來自 `failures.log`）

`results/<timestamp>/diag_summary.txt`（診斷模式）內容包含：

1. 診斷測試檔填充率斷言
2. 各 Round 的 `raw` / `arconly` / `full`：IOPS、穩態 IOPS（最後 5 分鐘）、命中歸因、由 IOPS 與未命中率回推的「每次未命中成本」、ARC/L2ARC 實際大小、暖機頻寬，以及逐時 IOPS
3. 乾淨版 ARC / L2ARC / 整體快取貢獻，並用兩輪 `raw` 的差異當雜訊底線
4. SLOG 併發度掃描表：各 numjobs 的 standard / removed / rawdev，附穩定性判定
5. 儲存環境重點（LUN 寫入快取模式等）

## 已知限制

- **Phase 30 的隔離組態不乾淨**：`raw` 仍會命中前一階段暖機留下的 ARC/L2ARC 資料（`raw` 的歸因表仍顯示數十 % 命中），所以 `arconly − raw`、`full − arconly` 是低估。ARC/L2ARC 的貢獻請以 `--diag` 的 Phase 80 為準。
- **Round 1 的 SLOG 數字不穩定**：2GiB 測試檔放不進 3.13GiB 的 ARC，寫入會混入 128K record 的 read-modify-write，重複測試間差異可達 30–50%（`summary.txt` 會標警告）。SLOG 貢獻請以 Round 2 與 `--diag` 的 Phase 90 為準。
- **`sync=disabled` 不是有意義的上限**：測到的是寫進 ARC 的記憶體速度，不代表後端能力。
- **`die` 中止不會寫入 `failures.log`**：run 若被 `die`（例如 import 重試耗盡）中止，`summary.txt` 仍可能印「所有階段皆正常完成」。判斷一次執行是否完整，請同時看 `full.out` 是否有「run_all.sh 全部完成」。
- **手動停機的 VM 不會被腳本啟動**：開跑前你自己停掉的 VM（例如 export 需要關閉的 zvol 使用者），測試結束後要自己 `qm start`。
- **耗時**：`--full` 實測約 12 小時（Phase 10 填 300GiB 約 1 小時、各 30 分鐘級的寫入/混合測試），`--diag --full` 約 3.5–4 小時。

## 需求

`fio`、`zpool`/`zfs`、`qm`（Proxmox CLI）、`arcstat`、`python3`（3.10+，使用了 `X | None` 型別語法）、`shuf`（coreutils），以及 `bash` 4+（`declare -A` 需要，macOS 內建 bash 3.2 無法直接執行，僅能語法檢查）。`iscsiadm` 與 `iostat` 為選用：缺少時只是少記錄對應的環境快照/監控。
