# App Updates — MoPanel 原生擴充

這個模組由 MoPanel 新實作，**不是免費 Mole CLI 的命令**，也不是付費 Mole GUI 的私有程式碼。它提供 Homebrew cask 的原生版本列表、官方 Dry Run、逐項確認更新，以及其他 App 的原生更新入口。Mole 的清理、卸載及磁碟分析引擎不參與這個模組。

## 已實作範圍

| 操作 | 實際介接 | 完成條件與限制 |
|---|---|---|
| 偵測既有 Homebrew | 標準路徑、PATH、使用者選擇的 bin/brew；解析 symlink，檢查本機安裝結構、版本與 help | 不安裝 Homebrew、不執行下載腳本；結構辨識不是 checkout 真偽的密碼學證明 |
| cask 版本清單 | `brew info --json=v2 --cask --installed` 與 `brew outdated --cask --json=v2` | 嚴格解析、以 token/tap 綁定，不使用 App 顯示名稱猜測；兩份資料不一致時拒絕 |
| App 路徑 | Homebrew JSON artifact 的明確 `target` | 支援自訂 appdir；沒有 target 就標未提供，不拼接 `/Applications/<name>.app` |
| 搜尋、篩選 | 原生 SwiftUI、LazyVStack | 搜尋名稱、cask 與路徑；篩選不會改變任何安裝計畫 |
| 單一 App 更新預覽 | `brew upgrade --cask --no-quit --require-sha --dry-run <tap/token>` | 先讀取新 JSON 並確認 App 沒在執行，再顯示原始官方預覽；不解析預覽文字猜測索引 |
| 確認更新 | 同一 typed argv，移除 `--dry-run`；ManagedProcess + 原生內嵌 PTY | 明確逐項確認，確認前再次檢查來源、版本、路徑、checksum、可用參數、Homebrew launcher 與 App 執行狀態 |
| 更新後驗證 | 再讀 `info` 與 `outdated` | Exit 0 與安裝版本符合預覽分別判定；不能確認時不宣稱更新成功 |
| 更新 Homebrew／索引 | 額外確認後執行 `brew update` | 明確說明會更新 Homebrew 本身、既有 taps、索引，可能做資料遷移；之後需重新偵測及檢查 |
| 其他 App 來源 | 讀 `/Applications`、`~/Applications` 下的 Info.plist、收據存在與相關簽章 | 深度與數量有上限，忽略 package 內嵌 App；不搜尋個人文件、不上傳整份 App 清單 |
| Sparkle | 本機 `SUFeedURL` 來源辨識 | 顯示合格 feed 資訊、原生開啟 App；**不抓取 feed、不查詢遠端最新版、不下載／安裝更新** |
| App Store | NSWorkspace 開啟 `com.apple.AppStore` | 使用者再選擇官方 Updates 側邊欄；不讀 Apple Account，不使用未公開的 Updates 深連結，不提供假更新數量 |
| Finder | NSWorkspace 顯示原始精確路徑 | 路徑失效會提示重新讀取 |
| 取消與關閉 | 受控子程序、cooperative cancellation、guardian | 唯讀工作可取消；更新要求取消時不強殺正在替換／回復的程序，不保證已完成變更可復原 |

## 直接更新的刻意邊界

目前原生直接升級只開放 `homebrew/cask` 的一般 App，且需有 64 字元 SHA-256、可確認的 `.app` target、已安裝版本與不同的索引版本。允許的現行 artifact 是 `app`、`binary`、`manpage` 與不會在這個命令中執行的 `zap` 描述；不傳 `--zap`。

含 `pkg`、`installer`、preflight/postflight、uninstall hook、未知 artifact、套件相依，或第三方 tap 的項目仍會顯示版本，但不提供直接更新按鈕。釘選、停用、無法比較的 `latest` 版本、缺少 checksum、缺少 target 或不相容 help 也不直接更新。這些項目需由原 App 或 Homebrew 自己處理；這個版本沒有宣稱已完成任意供應商更新器的安全自動化。

Homebrew 會依自己已安裝的配方與實作完成替換、驗證、下載及回復。MoPanel 的現行 JSON 檢查不能保證歷史 cask recipe 沒有 hook，也不能提供原子交易或完整回復保證。更新前仍應儲存工作，並保持必要備份。

## 同意與狀態一致性

`BrewUpdatePlan` 保存原始 cask identity、版本、明確 target 與 payload checksum；確認頁有效期五分鐘。確認後重新取得同一安裝來源的 JSON，任何欄位改變、重複 token、未知 identity、版本不一致、被釘選／停用或 App 重新啟動，均中止並要求重新預覽。這份 identity 快照不是 Homebrew 的可鎖定交易；外部程序若在最後檢查後更改 Homebrew，仍存在同機競爭窗口。Homebrew 的鎖定與安全驗證保留。

沒有升級全部的命令建構子；每次升級一定有一個經驗證的完整 `tap/token`。不經 shell 解析、不以 App 名稱當 token、不傳下載 URL、不使用 `--force`、`--zap` 或 `--no-quarantine`。`--no-quit` 防止 Homebrew 自動結束執行中 App；執行前另外確認目標 App 已關閉，也不允許從這個模組更新正在執行的 MoPanel。

App root 可透過 `externalOperationInProgress` 提供跨模組的同步互斥檢查，防止與 Mole 清理、卸載、其他原生變更同時啟動。`isBusy` 供 root 顯示與鎖定操作；回呼必須排除此 controller 自身。`cancelReadOnly()` 只取消掃描／查詢，`shutdown()` 取消所有受控工作。建立 controller 不會啟動任何背景工作。所有 smoke／benchmark 測試啟動旗標均停用真實更新服務與外部啟動，不會回退到使用者 Homebrew。

## Homebrew 環境與網路

每次命令固定啟用 `HOMEBREW_NO_ANALYTICS=1`；額外保護只接受精確值 `1`：

- `HOMEBREW_NO_AUTO_UPDATE`：一般檢查、預覽與升級不隱式更新 Homebrew／索引。
- `HOMEBREW_NO_INSTALL_CLEANUP`：不順便清理 Homebrew 快取與其他舊版本。
- `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`：不順便更新無關的已安裝 dependents。

其他 Homebrew env、mirror／remote 變更、skip-ask、script hooks 不由呼叫者傳入。既有 ManagedProcess 仍移除 shell 啟動與動態載入 hook，參數由 argv 傳遞。

「檢查更新」表示查目前 Homebrew 中繼資料；不是保證已讀到供應商伺服器此刻最新版。缺少 API cache 時 Homebrew 仍可能取得公開資料。要刷新索引，使用者需明確確認獨立的 `brew update`。這也會更新 Homebrew 自身與既有 taps，所以按鈕和確認頁不把它偽裝成純唯讀操作。

MoPanel 不自行向第三方伺服器傳送本機 App 清單，也不掃描或記錄帳號憑證。Homebrew 在使用者要求檢查／更新時依自身網路機制連線。PTY 保留官方互動；密碼按鍵不記錄，互動原始逐字輸出不保存或匯出。

## Sparkle 與 App Store 的誠實狀態

`SUFeedURL` 是 App 宣告的預設 appcast 來源，執行時可以改變。顯示 feed 前，使用 Security.framework 檢查已安裝 bundle 的本機簽章，再要求 HTTPS、無使用者／密碼、無 query／fragment、非本機／數字 IP、預設 HTTPS port。沒有執行 feed 請求；顯示的網址也不提供一鍵下載或安裝。有效本機簽章不能單獨證明出版商所有權，因此 UI 用「App 宣告的 feed」，沒有把它稱為已驗證的最新版或已認證供應商更新。

App Store 收據檔案存在是本機來源線索，不代表 MoPanel 驗證了購買權或可用更新。版本與更新同意交由 Apple 的 App Store。沒有可識別來源的 App 可開啟原 App 或 Finder，狀態明示來源未知。

## 程式碼位置與測試

| 檔案 | 職責 |
|---|---|
| `Sources/MoPanelCore/AppUpdateModels.swift` | typed cask identity、命令白名單、能力協商、嚴格 JSON、更新計畫與 URL 政策、Homebrew layout |
| `Sources/MoPanelApp/AppUpdatesController.swift` | 明確觸發的偵測／查詢／預覽／確認、程序生命週期、簽章與本機 App 來源 |
| `Sources/MoPanelApp/AppUpdatesView.swift` | 原生列表、搜尋、完整狀態、確認、Homebrew 互動輸出、App Store／Sparkle handoff |
| `Sources/MoPanelProcess/ManagedProcess.swift` | 固定值 Homebrew 環境防護與既有子程序管理 |
| `Sources/MoPanelTerminal/TerminalPanel.swift` | engineName 參數，讓 Homebrew 互動介面不再誤標為 Mole |
| `Tests/MoPanelCoreTests/AppUpdateTests.swift` | 合成 JSON fixtures、schema 變更、身份歧義、命令注入、計畫漂移、腳本／相依限制、feed URL、路徑、5,000 項清單 |
| `Tests/MoPanelProcessTests/ManagedProcessTests.swift` | 只允許固定保護值1、拒絕任意 Homebrew env／mirror／hook |
| `scripts/audit_homebrew.py` | 真實 ARM64 macOS GitHub CI 的既有 Homebrew 版本/help/JSON 唯讀協定稽核 |
| `scripts/test_audit_homebrew.py` | 稽核腳本命令白名單、環境隔離、格式、串流界限／逾時的合成測試 |

本機執行結果保留在 `docs/APP_UPDATES_TEST_OUTPUT.txt`；這些是模型／安全政策與 process 環境測試。沒有在開發者或使用者 Mac 上真的升級任何 App。完整 macOS 編譯、啟動與本機 API 結果以該次發行的 `TEST_REPORT.md` 及 CI artifacts 為準；不能用 Linux 的 Swift parse 代替 Apple SDK typecheck。

2026-10-24 本機實際執行：App Updates 18 個 XCTest 與 Homebrew 環境 2 個 XCTest 全數通過、0 skip；另外 9 個稽核腳本測試通過，原始輸出為 `docs/HOMEBREW_AUDIT_TEST_OUTPUT.txt`。稽核腳本本身在 Linux 執行時如預期回報 `unsupported_environment`、exit 1，完全不啟動 Homebrew。

CI 可執行 `python3 scripts/audit_homebrew.py --output build/reports/homebrew-readonly.json`。腳本只允許 `/opt/homebrew/bin/brew` 的版本、四個 help、installed info JSON 與 outdated JSON，沒有執行真正的 update／install／upgrade，連 dry-run upgrade 也未執行。它要求非 root 的 ARM64 macOS GitHub Actions 環境、過濾憑證與 shell hooks，並限制輸出總量與時間；報告只保留計數、旗標、版本及結果，不保留 App 名稱、路徑、URLs 或原始 stderr。

報告狀態會區分 `passed`、`read_only_compatible_upgrade_unavailable`、`not_available`、`failed`、`unsupported_environment`。找不到 Homebrew 不算成功；runner 沒有安裝／過期 cask 時，報告明示只驗證到空 JSON envelope，不能宣稱在真實資料上驗證了全部欄位。它驗證的是 runner 的當前安裝版本；`latest_homebrew_version_verified` 固定為 false，因為這項唯讀稽核不更新 Homebrew，也不把 runner 版本冒充已確認的上游最新版。

## 官方資料來源（2026-10-24 查核）

- [Homebrew manpage](https://docs.brew.sh/Manpage)：info/outdated JSON v2、upgrade、dry-run、no-quit、require-sha、update 與相關環境開關。
- [Homebrew JSON 查詢說明](https://docs.brew.sh/Querying-Brew)：JSON v2 的 cask 支援與新增欄位政策。
- [Homebrew outdated.rb](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cmd/outdated.rb)：cask identity 與 `installed_versions` / `current_version`。
- [Homebrew cask.rb](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cask/cask.rb)：`to_h`、installed version、artifact target、auto-update 與 latest 行為。
- [Homebrew upgrade.rb](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cmd/upgrade.rb)：參數與官方確認流程；[cask/upgrade.rb](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cask/upgrade.rb)：搬移、安裝、finalize 與 rollback。
- [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)：installer／pkg／flight hook 行為與限制。
- [Sparkle customization](https://sparkle-project.org/documentation/customization/)：`SUFeedURL`、動態覆寫與簽章選項。
- [Apple：使用 App Store 更新 App](https://support.apple.com/guide/app-store/update-purchased-apps-fir9b01adda3/mac)：官方 Updates 操作。
- [Apple NSWorkspace.openApplication](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:))：原生開啟 App。

本模組未加入 Sparkle SDK、Homebrew 原始碼或新的第三方常駐服務。它使用現有原生 terminal dependency 及 Apple 系統 frameworks；原始碼沿用 MoPanel 的 GPL-3.0-or-later 授權。
