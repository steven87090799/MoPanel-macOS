> 開發中審查：2026-10-24 的新工作分支、有限測試與未完成項目見 [PRODUCT_READINESS_AUDIT.md](docs/PRODUCT_READINESS_AUDIT.md)。下列歷史成功結果不適用於新分支，不能當成目前版本已驗收。
>
> 發行驗收版本：MoPanel 0.1.0 本機測試版。以下原始報告來自成功的 macOS 建置；文中的 `Reports/` 是發行 ZIP 內的原始證據目錄。
> 建置提交：`5e3d84a13e4a01caa1576f0d8585d92e18138955`。
> 實際 CI：[run 40082801624](https://github.com/steven87090799/MoPanel-macOS/actions/runs/40082801624)。

# 實際建置與驗證報告

產生時間：2026-10-24T09:46:32.632158+00:00

建置平台：macOS-27.0.1-arm64-arm-64bit-Mach-O；架構：arm64。

此報告由成功建置後的實際紀錄產生；原始紀錄位於 `Reports/`。

| 驗證 | 結果與範圍 |
|---|---|
| 獨立驗收 gate harness | 6 個隔離Bash管線案例通過；Swift／smoke／tee非零與skip皆不能進後續phase。見 validation-gate-harness.log |
| Smoke 診斷 driver | 8 個隔離案例通過；進度輸出保留、逾時不被診斷錯誤掩蓋、只取樣存活的自身子程序。sampler權限情境使用mock。見 smoke-driver-tests.log |
| 自身 crash report 辨識 | 5 個合成案例通過；僅本次 MoPanel PID／時間／名稱符合才保存，拒絕舊報告、其他程式與symlink。見 crash-evidence-tests.log |
| 隔離 debug 診斷 guards | 9 個合成／mock案例通過；診斷不能將失敗變成功，正式bundle不允許get-task-allow。見 debug-diagnostic-tests.log |
| XCTest／fixture UI gate | 兩者分別保存command、tee與pipeline退出碼，全部為0且無略過；見 validation-gates.json |
| Swift 編譯與單元測試 | 合計 177 個 XCTest，0 skipped，0 failures；多個 .xctest bundle 分別加總。見 swift-test.log |
| Guardian 程序整合測試 | 17 個案例通過，0 failures／skipped。見 guardian-test.log |
| ARM64 | 主程式、guardian 與原生 paths 編輯器均通過 lipo 檢查，只有 arm64 |
| App Bundle | Info.plist、主程式、helper、圖示與必要資源存在 |
| Code Signing | ad-hoc 簽章與 codesign strict/deep 完整性驗證通過；正式主程式及helpers皆無get-task-allow除錯entitlement |
| Apple 公證 | 未進行；沒有宣稱 Developer ID 身分 |
| UI 啟動 | 原生 App 視窗已建立，fixture-only smoke test 通過 |
| 真實個人資料操作 | 未執行清理、卸載、最佳化或瘦身 |
| UI 完整互動驗收 | Smoke test 不能代表每個按鈕、VoiceOver 與實機權限流程都已驗證 |
| ZIP | 建置流程在封裝後解壓並驗證 manifest、結構與簽章；最終結果見外部 zip-verification.txt |

## 原生 UI 與安全系統 API 測試

- 本次 smoke 有 20／20 項檢查通過；逐項布林結果見 smoke-test.json。
- 已依序選取 14 個路由且視窗保持存活；這只能驗證路由切換存活，不證明每個頁面都完整或正確渲染。
- 透過自身行程的公開 AppKit accessibility 介面，對 14 種明確識別的控制項執行 17 次按壓並驗證效果；沒有以直接呼叫 action 方法替代按壓。導覽準備仍使用 model state，不能稱為完整人工操作或所有按鈕的端到端驗收。
- IOPM 防休眠 assertion 已實際建立、讀取、釋放並確認不存在。
- 螢幕清潔 overlay 視窗已建立與關閉；測試未呈現全螢幕遮罩、攔截輸入或退出磁碟。
- Startup 的啟用／停用／回讀、取消與不明格式流程使用私有 mock 驗證；零真實 launchctl 變更或常駐 job。
- 上述測試沒有要求外部 Accessibility／TCC 權限或注入實體輸入，也不代表真實清理、App 升級或硬體控制已驗證。

## Git worktree 隔離驗證

以下數量取自本次 swift-test.log 的實際 passed suite 與其緊接的 XCTest summary；已包含在前述 XCTest 總數，不另行相加。

- GitWorktreeParserTests：7 個案例通過，驗證 NUL 記錄解析與保護政策。
- GitWorktreeIntegrationTests：21 個案例通過；使用真 Git 與每個測試新建的私有暫存倉庫，驗證保護檢查、保留分支、移除／恢復、內容保留及失敗拒絕。沒有操作使用者的既有倉庫。
- 這些測試不等同 Git 頁面的完整 UI、AI session 格式、第三方工具整合或任意外部程序同時寫入情況的驗收。

## CLI 相容性實測

- 基準：`Mole version 1.62.0
macOS: 27.0.1
Architecture: arm64
Kernel: 27.0.0
SIP: Disabled
Disk Free: 37.97GB
Install: Manual
Shell: /bin/bash`；read-only help/status/watch/analyze/history 合約檢查通過。
- 建置時最新穩定版：`Mole version 1.62.0
macOS: 27.0.1
Architecture: arm64
Kernel: 27.0.0
SIP: Disabled
Disk Free: 38.87GB
Install: Manual
Shell: /bin/bash`；read-only help/status/watch/analyze/history 合約檢查通過。

## 原生擴充的唯讀平台契約

- Homebrew：`Homebrew 7.0.10` 的唯讀 help／installed／outdated JSON 契約通過；觀察到 5 個已安裝 cask 與 0 個過期 cask。未保存 App 名稱、路徑或網址。
- Homebrew 升級參數：必要參數在 help 中可用。沒有執行 upgrade、update、install 或真實 App 更新。
- Runner 沒有涵蓋全部非空記錄類型；空陣列僅驗證 JSON 外層，不能當成實際 App 更新成功。詳細限制見 homebrew-readonly.json。
- caskroom 位置介面已探測，但沒有讀取 runner 的舊安裝 recipe／receipt；這些安全拒絕條件由隔離 Swift fixture 驗證，不能視為真實舊 App 升級驗收。
- Homebrew audit harness：15 個隔離案例通過，0 failures／skipped。
- launchctl 固定唯讀探測：`help` → exit 0；`help print-disabled` → exit 0；`print-disabled gui/501` → exit 0；`print gui/501/com.mopanel.nonexistent.fixture` → exit 113。非零退出原樣保存，沒有推定服務存在或把錯誤當成功。
- 未執行 launchctl 啟用、停用、載入或卸載；未讀取或修改私有 BTM 資料庫。

## Fixture 效能取樣

以下使用合成資料，量測 GUI 與 Mock CLI，不代表真實 CLI 大型磁碟成本。CPU 是 ps 的程序存活期平均值，峰值是觀察樣本最大值。

兩組效能表的 RSS 都將 GUI 與觀察到的子程序相加，共用頁面可能被重複計算；不是唯一實體記憶體占用，也不等同活動監視器的記憶體壓力。

| 狀態 | 平均 CPU % | 峰值 CPU % | 平均 RSS MiB | 峰值 RSS MiB |
|---|---:|---:|---:|---:|
| idle | 0.769 | 1.300 | 140.98 | 141.00 |
| monitor | 4.300 | 24.100 | 151.63 | 151.88 |
| scan | 35.561 | 68.800 | 156.14 | 160.84 |

## 真實官方 CLI 唯讀效能取樣

使用已校驗的官方 CLI，明確禁止變更操作。每個模式使用新的隔離 session；scan corpus 為 5,000 個各 4,096 bytes 的平面檔案。重複掃描有溫熱的 OS 檔案系統快取，不代表完整磁碟或清理工作的成本。CLI 子程序採專用 HOME／TMPDIR；沒有改寫 GUI 或工作 shell 的 HOME。

取樣涵蓋 GUI 與可觀察子程序，排除偵測、兩秒暖機與關閉時間；scan 僅統計實際官方掃描區間。CPU 為 ps 程序平均值，無法取代 Instruments 的瞬時追蹤。

| 狀態 | 平均 CPU % | 觀察峰值 CPU % | 平均 RSS MiB | 觀察峰值 RSS MiB |
|---|---:|---:|---:|---:|
| idle | 0.622 | 1.300 | 140.82 | 140.91 |
| monitor | 3.688 | 18.300 | 172.48 | 174.38 |
| scan | 74.255 | 95.700 | 171.19 | 187.86 |

實測 CLI：`1.62.0`，官方來源 `V1.62.0`／`91a7bf44f96995361b10b5a0e9efae36a1490bf9`。逐模式 fingerprint、corpus 數量、scan intervals 與原始取樣見 `Reports/performance-real-cli.json`。

## 尚須實機驗收

管理員驗證、完整磁碟存取、真實 Homebrew cask、第三方 App 簽章、外接硬碟、完整 VoiceOver 操作，以及 macOS 更新後的行為，仍須使用者在自己的 Mac 上依官方確認逐項驗證。取消已完成的操作不會回復被永久刪除的資料。

## 發行包下載後的獨立複核

- 檔名：`MoPanel-macOS27-arm64.zip`，7,525,826 bytes。
- SHA-256：`efd527b6f04064dc8ea9487a81b95c046d71fd152218eb1e8cd4b7239828b7fb`。
- GitHub artifact 外層 SHA-256、下載後 ZIP CRC、808 個 manifest 檔案的 SHA-256、Info.plist 與對應建置提交均吻合。兩個第三方來源目錄的符號連結都指向同一 ZIP 內的相對目錄，已另外確認。
- 三個實際執行檔均為 ARM64 Mach-O，均含 code signature；主程式為 10,795,232 bytes，Guardian 為 52,800 bytes，原生路徑編輯器為 280,800 bytes。
- Apple `codesign` 的 strict／deep 驗證，在打包前及解壓後均通過。Linux 下載端的 Mach-O／簽章區塊檢查沒有被當成 Apple 簽章驗證的替代品。
- macOS 的 Gatekeeper assessment 實際為 rejected，符合此版只有 ad-hoc 簽章、沒有 Developer ID／Apple 公證的狀態；沒有停用 Gatekeeper 或清除 quarantine。
- 新增的四個獨立 SIG_DFL 管線回歸案例在 macOS 全部通過：peer 已關閉但 session 仍 running 時的 resize／send／cancel，以及既有 pending signal 與 thread mask 保留。原始結果見 ZIP 內 `Reports/control-pipe-sigpipe.json`。

## 仍然存在的驗收與功能界線

- 此版本已通過上述自動化驗收，但沒有完成所有按鈕、VoiceOver、真實管理員密碼、完整磁碟存取及實體周邊的人工驗收。測試沒有清理或卸載使用者的真實檔案／App。
- 官方 CLI 的版本輸出回報該 GitHub macOS runner 原有狀態為 `SIP: Disabled`。本專案沒有執行變更 SIP 的指令，也不要求使用者關閉 SIP；SIP 啟用的一般個人 Mac 權限情境仍未完成實機驗收。
- 官方免費 CLI 的入口已接妥，未提供穩定項目 API 的操作保留官方 PTY。它們不是完整原生逐項刪除計畫。
- 與官方 Mole for Mac 1.17 的完整功能對等仍未完成：風扇模式、充電限制、AWDL、AI sessions／閒置 AI 工具管理、Parallels 回收，以及完整跨來源更新／背景項目管理等仍有缺口；沒有以無作用控制項代替。
- App Updates、Startup、Git 工作目錄、System Tools、選單列與受保護的 App 結束要求是 **MoPanel 新實作**。完整責任與差異位於 ZIP 的 `Source/docs/MOPANEL_ADDITIONS.md`、`Source/docs/GUI_PARITY.md`；官方所有指令與參數對照在 `CLI_COVERAGE.md`。
- 本報告的下載後補充沒有改動已驗證 ZIP；ZIP 內原始報告、原始碼、簽章與 manifest 維持建置時的實際內容。
