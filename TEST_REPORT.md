# 本次實際測試報告

日期：2026-10-24。工作環境：Ubuntu 24.04、x86_64，官方 Swift 6.4.1 Linux toolchain。

最新修復整合後的 Linux 全套 XCTest 實際通過：**140 個案例，0 failures、0 skipped，5.581 秒**（116 Core、24 Process／Editor／Streaming；`docs/INTEGRATION_TEST_OUTPUT.txt`）。這是完整套件同次執行結果，不把各 filtered run 重複加總；Apple SDK、AppKit 與發行封裝仍必須由本批 macOS CI 另外通過。

## 交付狀態

**已編譯並真正啟動 macOS27 ARM64 原生App；20項safe smoke檢查中19項通過，剩餘accessibility按鈕驗收仍阻擋ZIP交付。**

最新[run40078440635](https://github.com/steven87090799/MoPanel-macOS/actions/runs/40078440635)，commit `60e9baecedf8e92df31b7c488294279c42f71eec`，使用macOS27.0.1、Xcode27.1、Apple Swift6.4 ARM64。**140／140 Mac XCTest通過，0失敗／略過**（116 Core、24 Process／Editor／Streaming）。主App與兩個helpers完成release編譯、ARM64、ad-hoc完整性驗證，且正式executables沒有`get-task-allow`。

Homebrew audit15、獨立gate harness6、smoke driver8、crash辨識5、debug guard8個Python／Bash案例在真Mac全過，最新官方穩定CLI唯讀契約也通過。這些不與XCTest重複加總。

本輪原App不再SIGSEGV，正式smoke在10.129秒產生完整JSON與自身視窗截圖；此輪沒有崩潰或逾時；前一輪正式／debug log也沒有先前publishing-during-update警告。實際通過的範圍包含：原生視窗建立、4組adapter資料解碼、真watch串流及離頁停止、13路由選取存活、IOPM assertion建立／讀取／釋放確認、1個overlay視窗建立／關閉（未呈現或攔截輸入）、18項Doctor唯讀資料，以及Startup私有mock的啟用／停用／回讀／取消／未知格式拒絕。沒有真實launchctl變更、磁碟退出或使用者資料清理。

唯一失敗是own-process accessibility harness無法找到`mopanel.dashboard.snapshot`的唯一啟用控制項；實際按鈕在截圖中可見，但這不等於已測試按壓。公開selector bridge已通過真Mac編譯並運作，AX掃描最多257個節點（173個protocol、84個selector-only，unsupported child為0），仍0項action、0個MoPanel已識別ID；沒有直接action fallback。本輪精簡證據在`docs/MACOS_SMOKE_RUN40078440635.json`，完整原始JSON及tree trace在run artifact。**不能宣稱17項按鈕流程或完整VoiceOver已通過。**

正式smoke維持exit1與45秒deadline，不進效能、guardian Python、baseline probe或ZIP。這次已有完整有效JSON，driver正確略過不必要的LLDB副本且原失敗仍阻擋ZIP。Guardian新增17項已於Linux全過，但本輪Mac仍未抵達該階段。

driver窄修已在本輪Mac驗證：8個案例全過，且真實完整JSON的邏輯失敗沒有重跑LLDB，仍非零退出。signal／timeout／缺失或無效報告的診斷路徑保留。

先前run40076975513的main-thread scene graph重入stack與原始hash證據保留於`docs/STARTUP_CRASH_EVIDENCE.json`／`docs/STARTUP_STACK_TRACE.txt`。修正移除錯誤的view-disappear狀態發布並防止同值發布後，本輪已越過該啟動失敗；尚須修復並重新通過真正AX控制項驗收，再完成所有後續門檻。

## 已實際執行

| 測試 | 結果 | 證據與範圍 |
|---|---|---|
| Core Swift 編譯 | 通過 | Swift6.4.1 Linux；不含 SwiftUI/AppKit |
| Core XCTest | **57 通過，0 略過，0 失敗** | `docs/READONLY_BENCHMARK_CORE_TEST_OUTPUT.txt`；1.998 秒；36 個模型／adapter、11 個探索、10 個唯讀 benchmark 測項 |
| 程序與路徑編輯 Swift 編譯／XCTest | **基準 20 通過，0 失敗** | `docs/PROCESS_TEST_OUTPUT.txt`；後續加入環境與串流回歸的24案例也通過，見 `docs/PROCESS_STREAMING_REGRESSION_OUTPUT.txt`（Linux2.61秒）及 run40073252380（Mac3.060秒） |
| C guardian 編譯 | 通過 | Linux gcc，`-Wall -Wextra -Werror` |
| C guardian 整合測試 | **16 通過，0 略過，0 失敗** | `docs/GUARDIAN_TEST_OUTPUT.txt`；4.946 秒；包含分離 session 子孫清理及合作式取消 |
| 官方 history renderer | 通過 | V1.62.0 `history.sh --json` 處理合成 operations/deletions 日誌，輸出再供 Swift 解碼 |
| 官方 help contract | 通過 | 來源 help function 安全抽取／隔離執行，建立固定基準 fixture；不是任意手寫 mirror |
| JSON／NDJSON | 通過 | 欄位、型別、缺少值、未知掃描狀態、UTF-8 分段、過大 frame、截斷 frame、增補欄位 |
| 更新相容策略 | 通過單元測試 | 新穩定1.x、舊版、新major、nightly/dev、HEAD、版本不能解析、help旗標缺失；已驗證官方腳本的窄範圍 stable 復原例外；不是實機升級測試 |
| 參數與特殊檔名 | 通過 | 繁體中文、空白、引號、換行、`$()`、分號等原樣 argv；沒有 shell interpolation |
| 無 CLI／權限不足／無 helper | 通過程序測試 | 明確失敗；使用隔離路徑與不可執行 fixture |
| Homebrew／安裝器資源探索 | 通過 Core 測試 | symlink、`mo` alias 的真正 companion、搬移後 pin、Unicode／跳脫 Bash literal 的無 eval 解析、自訂路徑不可回退、不明／過大 launcher 拒絕 |
| 取消、Task 取消、逾時、非零退出 | 通過 | 真正子程序與訊號、忽略 SIGINT 的程序、退出碼、stderr |
| PTY 及密碼 echo | 通過 | 真正 controlling terminal、輸入、resize，關閉 echo 後密碼不回傳；沒有使用真實密碼 |
| GUI 父程序 lifeline 中斷 | 通過 Linux 基本測試 | 控制 pipe EOF 導致清理所屬程序；不是 macOS App 強制結束的實機驗收 |
| 大量輸出／上限 | 通過 | 大量輸出正確接收、超過安全上限停止，watch 不持續累積 stdout |
| 建置腳本語法 | 通過 | `bash -n`、Python `py_compile` |
| CI read-only probe 輔助檢查 | 10 項通過 | `docs/BUILD_HELPER_CHECKS.json`；watch 分段／截斷／大小上限、程序群組逾時、macOS stable tag 篩選、官方 help 選項缺失偵測、CI token host／redirect 範圍與修改後 Python 語法；不是 macOS CLI 實測 |
| 效能測量 harness 單元測試 | **5 通過，0 失敗** | `docs/PROFILE_HARNESS_TEST_OUTPUT.txt`；驗證隔離 corpus、唯讀來源證據、fixture 區隔、暖機／停止／實際掃描區間、樣本不足拒絕；未產生真實效能數字 |
| Swift 原始碼語法解析 | **初次凍結快照的 28 個檔案通過** | `docs/SWIFT_SYNTAX_REPORT.json`；記錄當時 22 個產品 Swift 檔、4 個測試檔、Package manifest 與圖示產生器的 SHA-256。之後新增的 benchmark／工具模組不在該快照內；該語法檢查沒有驗證 macOS import／型別／API，完整來源以後續實際 CI 編譯為準 |
| Info.plist metadata | 通過 | plist parser 檢查 target27、arm64、bundle executable |
| Linux 建置防誤交付 | 通過 | build.sh 明確拒絕在 Linux 輸出 App；沒有建立假 bundle |

上述三組 Linux 基準主要測試合計 **93 個案例實際通過**（Core 57、程序與路徑編輯 20、guardian 16）。這個數字不包含 10 項 CI 輔助檢查、5 個效能 harness 測試、語法解析、文件檢查或尚未執行的 macOS 驗收。

### 後續增量的已執行回歸

| 增量 | 實際結果與尚待驗證範圍 |
|---|---|
| App Updates 與舊安裝 receipt | `docs/APP_UPDATES_TEST_OUTPUT.txt`：32 個 Linux filtered XCTest 通過，0 失敗，0.952 秒；其中18個既有更新模型、12個 receipt 案例、2個程序環境案例。後兩項亦包含在程序24案例中，不可重複加總。12項receipt案例已在run40074913811通過Mac，沒有真實App升級 |
| Homebrew audit cleanup 與 caskroom | `docs/HOMEBREW_AUDIT_TEST_OUTPUT.txt`：15個Linux Python案例通過，0失敗，0.309秒；Mac15項回歸及caskroom probe已在run40074350936通過。沒有讀取runner舊recipe／receipt |
| 增量管線讀取 | `docs/PROCESS_STREAMING_REGRESSION_OUTPUT.txt`：24個Linux程序／Editor／Streaming案例通過；相同24案例在run40073252380的Mac也通過，包含小量stdout／stderr與PTY提示即時送達，尚不能代替UI監控smoke |
| System Tools policy | `docs/SYSTEM_TOOLS_POLICY_TEST_OUTPUT.txt`：7個Linux政策案例通過；run40073252380對應Mac測項亦通過。本輪另有安全IOPM assertion建立／讀取／釋放實測；仍不是螢幕輸入攔截或硬碟退出驗收 |
| Startup inventory | run40073252380兩案例在Mac失敗；修前以相對base URL在Linux重現，見`docs/STARTUP_URL_REGRESSION_BEFORE.txt`。第二次修後15個Linux案例通過（`docs/STARTUP_TEST_OUTPUT.txt`），含真Mac launchctl樣本及enumerated child重建回歸；15項已在run40074913811通過Mac，本輪私有Startup controller mock流程亦通過；沒有真實launchctl變更 |

上述增量與基準測試有重疊；最終發行包僅由一次實際成功的Mac整合測試、完整smoke、六種效能模式及ZIP驗證產生，不以重複加總取代驗收。

較早的 CORE_TEST_OUTPUT 最後一個彙總曾包含其他 suite 的 12 個 helper 未指定略過；這些程序測試隨後已使用正確 helper 完整重跑，結果在獨立 PROCESS_TEST_OUTPUT。Core 增加探索測試後的最新證據位於 DISCOVERY_CORE_TEST_OUTPUT。不可把早期略過當成通過；上表依最後各 suite 的實際結果分列。

### C 子孫程序測試的環境修正

初次沙箱 `/proc` 使用 host PID，而 `getpid()` 使用 namespace PID，分離 session 的孫程序枚舉測試曾略過。之後在允許的隔離 fixture 執行環境重跑，修正缺少 kernel children 列表時的 `/proc` fallback，最後 **16 個案例全部通過，沒有略過**。macOS 版本使用 libproc，該平台路徑尚須在 macOS runner 執行，不能以 Linux 結果推定它通過。

## 尚未執行或尚未驗證

| 項目 | 狀態 |
|---|---|
| macOS27 SwiftUI/AppKit/Charts 編譯 | run40078440635完整整合版release與140XCTest通過；已建立視窗、smoke19／20通過 |
| SwiftTerm 與 MoPanelEditor macOS 編譯 | 基礎版本通過 |
| 真正 ARM64 Mach-O 產物 | runner 已編譯並驗證；因 smoke 失敗未上傳發行 App |
| ad-hoc Code Signing／codesign verify | 基礎版本通過 build.sh 的 bundle gate |
| Apple Developer ID／公證 | 未進行，未宣稱 |
| macOS 原生視窗 smoke test | run40078440635視窗／adapter／watch／安全系統API及Startup mock通過；唯一失敗為AX控制項辨識，沒有繞過或降低gate |
| 十個頁面的全部按鈕與 VoiceOver | 未完整實機驗收 |
| 官方 status/analyze/uninstall-list 的真實 Mac 整合 | CLI 唯讀合約通過；原生 GUI 真實引擎 benchmark 待接續驗證 |
| Full Disk Access／Touch ID／sudo | 尚未實機驗證 |
| 真實清理、卸載、Purge、Installer、Slim | 未執行；刻意避免對個人資料測試 |
| macOS GUI 意外終止後全部子孫清理 | 尚未實機驗證；Linux 基本案例通過 |
| Slim 合作式取消 | 保護官方 App 原子替換；等待安全停止點，沒有兩秒內必定退出的保證，須 macOS 實機驗證 |
| 閒置、監控、掃描 CPU/RSS | 尚無 macOS 實測值；不填假數字 |
| ZIP 解壓後 App 簽章及開啟 | 尚無編譯 ZIP，因此未執行 |

## 已準備的 macOS 驗收流程

`.github/workflows/build.yml` 使用已確認存在的 `xcode-27` ARM64 runner。流程會取得固定 V1.62.0 及最新穩定 CLI，核對 release binaries SHA256，執行 read-only API 合約測試，編譯與測試 Swift，建立完整 bundle 與原創圖示，簽署兩個 helper 及主程式，驗證 ARM64 和 codesign，啟動 UI safe smoke test，分別量測三種 fixture 狀態與三種官方唯讀 CLI 狀態，最後 ZIP、解壓、manifest／簽章驗證及 SHA-256。

所有必要步驟通過後才會上傳 App ZIP。成功發行包中的 TEST_REPORT 將由 `scripts/write_release_report.py` 根據真正的 build logs、smoke JSON 與測量數據產生，和這份尚未完成發行驗收的工作紀錄清楚區分。

## 測試資料與安全範圍

status/analyze/apps 的 parser fixtures 依官方來源 schema 建立，明確標記為合成測試資料。history fixture 是官方 renderer 對合成日誌的真實輸出。效能和 UI smoke 的 Mock CLI 僅在明確測試參數下使用，不作為正式介面的 fallback 數據。

沒有執行使用者資料的清理、卸載或瘦身，沒有停用 Gatekeeper、修改 SIP、寫入密碼、建立 Login Item 或 LaunchAgent。
