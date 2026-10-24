# MoPanel

Mole CLI 的非官方原生 macOS 操作介面。主要目標是 **macOS 27+、Apple Silicon ARM64**，以 SwiftUI、AppKit、Swift Charts 與原生 Liquid Glass 建立介面。繁體中文為預設，可切換英文、深色或淺色。

**本次工作快照是否已有可執行 App，請以 `TEST_REPORT.md` 的實際結果為準。原始碼存在或 CI workflow 已建立，並不代表 macOS 編譯、Code Signing 與啟動驗證已通過。**

## 核心原則

MoPanel 將官方 Mole 當作獨立、可更新的執行引擎。沒有 Node.js/Web Server、沒有第二套清理引擎，也沒有把官方 Mole 永久內建成固定舊版。官方的路徑保護、卸載分析、確認與管理員互動由官方 CLI 保留。

- 有正式 JSON/NDJSON 的總覽、磁碟分析、App 清單和歷史，以原生介面顯示。
- 尚無穩定項目操作 API 的清理、最佳化、Purge、Installer、Slim 等，使用原生嵌入式 SwiftTerm 終端顯示官方互動介面，另提供原生功能按鈕與選項。
- 終端後備功能不是純原生項目編輯器。介面不會假裝勾選了 CLI 無法接受的刪除計畫，也不會猜測互動選單編號。
- 破壞性操作先由使用者觸發與確認；支援的命令提供 Dry Run。預覽與真正執行之間，官方仍會重新掃描。

完整入口、參數、介接方式與程式碼對照見 `CLI_COVERAGE.md`。

## 安裝與啟動

下列步驟適用於已成功建置驗證的 `MoPanel-macOS27-arm64.zip`：

1. 比對附上的 `SHA256SUMS.txt`。解壓縮 ZIP。
2. 將 `MoPanel.app` 拖入 `/Applications`，或先放在自己的 Applications 目錄測試。
3. 開啟 MoPanel。App 不會在啟動時執行清理，會先偵測 CLI 及其公開介面。
4. 若沒有 Mole，在設定中選擇 Homebrew 安裝入口；確認後才會執行 `brew install mole`。Homebrew 本身未安裝時，App 開啟官方安裝說明，不私自執行下載腳本。
5. 若 Mole 裝在自訂位置，在設定選取正式執行檔，重新偵測。
6. 需要完整磁碟存取時，依介面引導到「系統設定 → 隱私權與安全性 → 完整磁碟存取」，手動授權；程式不修改 TCC 資料庫。

ad-hoc 版本沒有 Apple Developer ID 或公證。若 macOS 因為來源驗證而阻擋，先核對來源與校驗值，再使用 macOS 提供的「隱私權與安全性／仍要打開」流程。不要關閉 Gatekeeper，也不需要修改 SIP。本程式不自動清除 quarantine。

## Mole 偵測位置

依序檢查使用者指定位置、`/opt/homebrew/bin/mo`、`/usr/local/bin/mo`、`~/.local/bin/mo` 及 PATH 中的絕對目錄。設定頁顯示執行檔、符號連結解析結果、資源位置、版本、來源與相容狀態。找不到或不相容時，相關操作停用並提供原因。

自訂路徑代表要執行使用者選定的程式；請只選官方 Mole 的 `mo`/`mole` launcher。help 身分檢查不是加密驗證或防惡意程式沙箱。

## 使用方式

| 頁面 | 操作方式 |
|---|---|
| 總覽 | 原生指標與趨勢圖；單一 `status --watch` 工作；預設離開頁面或視窗不活動時停止。可明確啟用共用串流的選單列監控 |
| 系統清理 | Dry Run、支援選項及官方內嵌互動；清楚提示可能永久刪除和清空垃圾桶 |
| 軟體卸載 | 官方清單的原生搜尋與選取；官方預覽與確認保留；個人資料預設保留 |
| App 更新 | **MoPanel 新實作**；Homebrew 結構化版本、官方預覽、逐項確認與更新後檢查；Sparkle／App Store 交回原 App |
| 啟動項目 | **MoPanel 新實作**；有界的 plist 中繼資料清單、目前使用者 LaunchAgent 的原生確認與狀態驗證；其他項目交由系統設定 |
| 系統最佳化 | 官方項目、Dry Run、白名單與互動結果；不新增舊式調校 |
| 磁碟分析 | 官方 JSON 逐層瀏覽、大小排序、搜尋、Finder 入口；保留不完整狀態 |
| 專案清理 | 選擇掃描根目錄、Dry Run、paths 設定及官方選取 |
| Git 工作目錄 | **MoPanel 新實作**；只檢查選定倉庫，保護未保存內容，先保留 HEAD 分支，再由正式 Git 命令移除／重建工作目錄 |
| 安裝檔 | 官方掃描與選取；不假造無正式 API 的刪除計畫 |
| App 瘦身 | 官方 Universal App 檢查、Dry Run、選取與簽章檢查結果 |
| 操作歷史 | 原生 JSON 歷史與搜尋，保留未明確歸屬紀錄 |
| 系統工具 | **MoPanel 新實作**；Keep Awake、Clean Screen 基本遮罩、確認後安全退出外接磁碟、Doctor 唯讀報告 |
| 設定 | 路徑、更新、權限引導、白名單、Touch ID、completion、主選單與進階 remove |

內嵌終端可直接用鍵盤，或點選箭頭、空白鍵、Enter、Esc 等按鈕。所有確認內容以當下官方畫面為準。管理員密碼走 CLI 的 TTY 密碼流程，不存入 MoPanel 日誌；終端輸入不被程式記錄。

`⌘.` 停止目前作業；`⇧⌘P` 暫停監控；`⇧⌘R` 重新偵測 CLI；`⌘,` 開啟設定。取消會停止程序，已執行的變更不會自動復原。

## 與官方付費 GUI 的功能差異

使用者追加的比較範圍是官方 Mole for Mac **1.17 正式版**，1.18 Preview 另列。MoPanel 並未達到全部功能對等。免費 CLI 沒有公開任意逐項清理／卸載計畫 API，相關工作仍在內嵌官方互動介面完成；不能把它稱為與官方付費 App 完全相同的原生選取流程。

以上四個新增頁面、選單列、行程搜尋／排序／置頂與受保護的 App 結束要求，都會標記 **MoPanel 新實作**。它們使用 Apple 原生 API 或其他已安裝的官方工具，各自需要維護相容性。Homebrew 直接更新只開放可驗證的一般官方 cask；其他來源不會被包裝成已實作的自動更新引擎。

Git 工作目錄使用已安裝的正式 Git，不是 Mole CLI 的隱藏功能。只能移除通過保護檢查的 linked worktree；保留分支可重建已提交內容，但依賴原倉庫與物件仍存在，並非獨立備份。沒有 AI 對話判讀、閒置天數推測或自動清理。使用方式、安全限制與隔離測試見 `docs/GIT_WORKTREES.md`。

風扇模式、充電限制、AWDL 控制、AI sessions／閒置工具管理、Parallels VM compact，以及部分官方 GUI 細部互動與權限／硬體驗收仍未完成。本版本沒有提供無作用的控制項，也沒有對這些功能宣稱已測試通過。完整對照見 `Source/docs/GUI_PARITY.md`（來源 repository 中為 `docs/GUI_PARITY.md`），新增內容與限制見 `docs/MOPANEL_ADDITIONS.md`、`docs/APP_UPDATES.md`、`docs/STARTUP.md`、`docs/NATIVE_CONTROLS.md`。

## 安全與資料

MoPanel 以一般使用者權限執行，不建立 LaunchAgent、Login Item 或常駐服務。結束時由 guardian 向所屬程序發出停止並管理其生命週期。它不操作 BuhoCleaner 的設定、白名單或資料庫。

Slim 的 App 替換階段採合作式取消，避免在官方交換原 App／副本的關鍵時刻強制終止而破壞 App。這類操作可能要等官方到達安全停止點；不能保證按下停止後兩秒內就退出。macOS 的完整異常終止流程仍須實機驗證。

Mole 有些操作是永久刪除，不是移至垃圾桶。不要把 Dry Run 當成完整備份或可回復交易。CLI 自己要求的再次確認會保留。

預設不長期保存終端逐字紀錄；官方 Mole 歷史仍由官方管理。無法準確歸屬、部分掃描或失敗結果不會改寫成成功／零空間。

非互動作業結束後可按「儲存此次輸出」匯出擷取到的 CLI 輸出、退出碼、取消／逾時狀態。輸出有記憶體上限；超過時停止並標記不完整。互動 PTY 的文字只保留在終端有限的回捲畫面，不存入擷取紀錄；其按鈕為「儲存執行摘要」，只匯出狀態與子程序管理診斷，**不是完整終端逐字日誌**。History 顯示 Mole 自己提供的紀錄，亦保留不完整或無法歸屬的狀態。MoPanel 不記錄鍵盤輸入。

## 更新

在設定中重新檢查官方 release。Homebrew 安裝以 Homebrew 的更新路徑處理，官方腳本安裝可使用 `mo update`；nightly 僅在確認安裝來源支援時開放。任何更新都需要使用者明確選擇。

CLI 更新後重新偵測版本、help 與結構化輸出。相容性不是固定版本比較：已驗證的公開指令與選項仍相符的新穩定 1.x 可使用保留官方確認的操作；新 major、舊版、nightly 或無法解析的介面會停止受影響變更。GUI 自身的更新與 CLI 分開管理，詳見 `COMPATIBILITY.md`。

來源、資源與 update 契約已確認的官方腳本 Nightly／dev 安裝，可透過「返回官方穩定版…」呼叫官方 `mo update`。這是僅允許回穩定版的窄範圍例外，更新後仍須重新驗證；Homebrew HEAD、不明來源與新 major 不適用。

## 原始碼與建置

原始碼與建置說明一同提供。`scripts/build.sh` 與 `.github/workflows/build.yml` 實作真正 macOS 27 ARM64 編譯、測試、ad-hoc 簽章、原生視窗 smoke test、資源取樣、ZIP 解壓驗證及 SHA-256。完整環境要求見 `docs/BUILD_ENVIRONMENT.md`。

官方 CLI：<https://github.com/tw93/Mole>。研究參考 GUI：<https://github.com/michaelcspeed/mole-ui>。MoPanel 與官方 Mole 商業 App 沒有從屬關係。授權與來源見 `LICENSE`、`THIRD_PARTY_NOTICES.md`。
