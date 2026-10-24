# mole-ui 整合方式與重用評估

檢查日期：2026-10-24。第三方基準為
[`michaelcspeed/mole-ui@06e7f4633b39d9f1dddc5b64e9d95c22013d7ae0`](https://github.com/michaelcspeed/mole-ui/tree/06e7f4633b39d9f1dddc5b64e9d95c22013d7ae0)。
本文件是架構與關鍵整合程式碼評估，不是對整個第三方專案的安全認證。

## 結論

MoPanel 採取獨立 SwiftUI/AppKit 前端、官方 CLI 公開指令與 JSON、原生內嵌 PTY。
參考 mole-ui 的單一監控程序、分離掃描與操作、明確缺少依賴的狀態、失敗後停止使用解析資料、檔案身分檢查，以及完整 CLI 互動備援。
沒有複製其 Web UI、Node 服務、Python PTY 程式或清理執行器。

這個選擇的主要原因是 mole-ui 的逐項原生清理並不是單純轉呼叫公開 CLI：它在記憶體或暫存檔中改寫官方 shell 原始碼、掛入內部函式，再由另一個 Trash helper 執行選定項目。其實作有來源錨點、規則指紋及檔案身分保護；但這個內部介面會受上游程式佈局影響，也偏離本任務「主要破壞性功能交由官方 CLI」與可持續更新的優先順序。

## 逐模組評估

| 第三方檔案 | 實際機制與保護 | MoPanel 採用方式 |
|---|---|---|
| `scripts/MoleUI.swift`、`server.mjs` | AppKit/WKWebView 外殼啟動 loopback HTTP/WebSocket Node 服務；服務驗證來源並管理操作 | 不重用執行架構，改為 SwiftUI 直接呼叫 Swift 服務。沒有 Web Server 或 Node 常駐。 |
| `commands.mjs`、`pty_bridge.py` | 固定命令目錄；Python `pty.fork`、`execve` 以 argv 執行；方向鍵/resize/停止經訊息傳遞；關閉 stdin 後送停止訊號 | 重用設計概念；獨立實作 C `MoPanelGuardian` + Swift `ManagedProcess`，無 Python 執行依賴。 |
| `mole-runtime.mjs` | `realpath` 找安裝實體；只解析受限字面 launcher 路徑，不直接 eval launcher | GUI 偵測保留路徑解析與來源識別；執行公開入口，不 source 安裝目錄內部函式。 |
| `monitor.mjs` | 單一 `status --watch --interval=2s`，有界 NDJSON、閒置停止、失敗重試節制；只列白名單欄位，移除行程完整參數/IP | 原生儀表板使用單一 watch；輸出有界、離頁停止。行程完整命令列可能存在最近快照與原始結果的記憶體中，UI 不展示，也不長期儲存或上傳。Swift Codable 契約依官方原始碼重新建立。 |
| `cleanup.mjs` | 對 `append_dry_run_cleanup_target` 等精確錨點掛鉤，輸出 NUL 分隔候選；來源與白名單 fingerprint；`dev/ino/mtime`、範圍/重疊/符號連結檢查；另呼叫 native Trash | 不沿用改寫腳本與 GUI 自行清理路徑。`mo clean --dry-run` 顯示官方預覽，真實清理由 `mo clean` 與其確認完成。沒有假裝逐項勾選形成官方計畫。 |
| `review.mjs` | Purge/Installer 掛入官方內部掃描函式；App 掃描使用原生 inventory；分離 App 與相關資料，重查檔案身分 | 未公開結構化的清理結果留在官方互動介面；原生選擇、搜尋、預覽入口不推測資料所有權。 |
| `uninstall-integration.mjs` | `source bin/uninstall.sh` 後呼叫 `_batch_scan_app_details`；依 18 欄 pipe 格式解析；Homebrew 以已安裝 receipt、hash 與 `nozap` 驗證；拒絕未可檢視 flight hooks | 不綁內部 18 欄格式；`--list` 只讀清單，具體移除走官方 PTY 確認，個人資料預設不加 `--with-data`。 |
| `performance.mjs` | source 官方維護函式，固定 task catalog，分離 admin 動作、指紋與結果；部分執行跳過原 CLI 主入口 | 不直接選呼內部維護函式。Optimize 公開 dry-run/whitelist/interactive 保留官方判斷。 |
| `disk.mjs` | 直接呼叫安裝資源中的 `analyze-go --json`；驗證 report path/直接子路徑/大小；partial、unavailable；Finder 前重查身分 | 使用公開 `mo analyze --json`，維持狀態差異及資料驗證；不將讀不到的項目當零。 |
| `slim.mjs` | 使用 `MOLE_TEST_MODE` 來源掛鉤呼叫候選、簽章檢查與 slim 函式；clone 驗證後替換；明確禁止對替換交易強制 kill | 保留公開 `mo slim`；重要發現：Slim 操作採合作式取消，等官方延遲訊號交易完成，絕不套用通用兩秒 SIGKILL。 |
| `protections.mjs` | source whitelist 模組讀有效/強制保護；revision、符號連結檢查、原子設定寫入 | 使用官方 `clean/optimize --whitelist` 互動；Purge 路徑使用官方 EDITOR 擴充點配原生編輯器，不覆寫其他清理軟體設定。 |
| `scripts/app-inventory.swift`、`scripts/trash-helper.swift` | 原生應用程式資訊/圖示與 Trash；後者依 `dev/ino/mtime` 和允許範圍再驗證 | 參考 native API 選擇與再驗證原則；不當作另一套 clean/uninstall 引擎。 |

來源定位均可從固定 commit 的同名檔案檢閱，例如
[`cleanup.mjs`](https://github.com/michaelcspeed/mole-ui/blob/06e7f4633b39d9f1dddc5b64e9d95c22013d7ae0/cleanup.mjs)、
[`uninstall-integration.mjs`](https://github.com/michaelcspeed/mole-ui/blob/06e7f4633b39d9f1dddc5b64e9d95c22013d7ae0/uninstall-integration.mjs)、
[`slim.mjs`](https://github.com/michaelcspeed/mole-ui/blob/06e7f4633b39d9f1dddc5b64e9d95c22013d7ae0/slim.mjs)、
[`docs/ARCHITECTURE.md`](https://github.com/michaelcspeed/mole-ui/blob/06e7f4633b39d9f1dddc5b64e9d95c22013d7ae0/docs/ARCHITECTURE.md)。

## 測試參考

已閱讀 `tests/cleanup.test.mjs`、`review.test.mjs`、`uninstall-integration.test.mjs`、`monitor.test.mjs`、`disk.test.mjs`、`slim.test.mjs`、`commands.test.mjs`。
值得保留的案例包括：未知來源佈局拒絕、變更後計畫失效、Homebrew receipt 不同於線上 cask、資料與 App 分離、未完成掃描保留 partial、NDJSON 跨 chunk、只使用一個 watch、未驗證資料不得執行刪除。

MoPanel 重新用 Swift XCTest、隔離 fixture 和 C guardian 真實子程序測試驗證自己的介面。第三方測試沒有原封移植，第三方通過不代表本 App 已通過；macOS UI、Apple Silicon、簽章與實機權限測試必須另看 `TEST_REPORT.md` 的實際結果。

## 原生終端相依套件

`SwiftTerm` 採固定版本 **1.20.0**（上游 tag `v1.20.0`），MIT 授權，完整聲明在 `ThirdParty/SwiftTerm-LICENSE.txt`。
這是 GUI 終端繪圖依賴的可重現版本；不代表 Mole CLI 被固定於舊版。
選擇現成 VT 終端是為了正確處理 ANSI、游標移動、UTF-8/TUI 與鍵盤，而不是把原始控制字元當成普通文字。
使用 CoreText 原生繪圖，未啟用 Metal renderer，保留 500 行 scrollback、停用 image cache；無 WebView、Node/Python 服務。
終端拒絕 OSC 剪貼簿讀寫與任意 URL scheme 開啟，不保存使用者輸入或管理員密碼。

## 取消及程序生命週期的實際界線

- 每個操作一個非特權 guardian；一般取消送 SIGINT，兩秒後對仍存活的程序群與已觀察的後代升級 SIGKILL。
- App 關閉或意外結束會關閉專屬 stdin 管線，guardian 因 EOF 啟動相同取消處理。
- macOS 用 `libproc`、Linux 測試用 `/proc` 追蹤後代及出生身分，避免只憑重用的 PID 殺到其他程序。
- 真實 Slim 採 `--cooperative`。取消或 App 結束後，guardian 可以暫時存活，直到官方替換交易到達安全停止點；這段時間不能宣稱所有程序已立刻結束。
- 同使用者 guardian 無法保證殺掉改變權限、故意脫離監督或未被觀察到的惡意程序。只對官方來源且相容的 CLI 開啟破壞性功能；macOS sudo/授權與原版交易行為仍須在實機驗證。

## 原生 Purge 路徑編輯器

`MoPanelEditor` 是官方 `mo purge --paths` 以 `$EDITOR` 呼叫的原生 AppKit 編輯器。CLI 仍負責建立及重新載入設定。
編輯器只接受本使用者 `~/.config/mole/purge_paths`，拒絕符號連結、非一般檔案、非使用者所有與超過 256 KiB 的檔案；以 NSOpenPanel 加資料夾。
儲存前驗證絕對路徑或 `~/`、可用資料夾、文字大小及控制字元。保留檔案權限，使用有界讀取、寫入同步、原子 rename，並比較原檔內容與 inode/mtime/dev。
NSFileCoordinator 與檔案鎖協調相容編輯器；對忽略協調的外部寫入者，在最後比較與原子 rename 之間仍有作業系統未提供原子 compare-and-swap 的極小競態窗，因此不要同時用其他程式改同一份設定。這不適用於資料刪除；只影響此單一使用者設定檔。

## 授權與品牌

`mole-ui` 為 MIT；未重用其私有素材或 App 圖示，仍提供其 MIT 聲明以標示架構參考來源。
官方 Mole 為 GPL-3.0；MoPanel 採 GPL-3.0-or-later 並交付完整對應原始碼。正式散布仍須包含實際連結相依套件授權。
MoPanel 是非官方介面，未使用官方付費 GUI 原始碼、圖示或商標作為產品名稱。
