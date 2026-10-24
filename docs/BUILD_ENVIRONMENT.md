# 建置環境與產物驗證

## 必要平台

- Apple Silicon ARM64。
- macOS 27 與 Xcode 27 或更新版本。
- SwiftPM，系統 AppKit、SwiftUI、Charts。
- Python 3 僅供建置和測試使用；App 本身不依賴 Python、Node.js 或 Web Server。

2026-10-24 檢查的 GitHub 官方資料提供 `xcode-27` ARM64 runner。該映像版本 `20261012.0260.1` 使用 macOS 27.0.1，預設 Xcode 27.0、macOS SDK 27.0。這是預覽 runner，排隊或映像變動仍可能造成 CI 失敗。

來源：

- <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>
- <https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md>
- <https://github.com/actions/runner-images/issues/14404>

### 公開 repository 的標準 runner

`xcode-27` 列在官方 standard ARM64 runners 表中。本 workflow 使用該標準 runner；GitHub 官方說明公開 repository 使用 standard GitHub-hosted runners 的執行免費。依公開文件，沒有另行加入 preview 名單的要求。此處建置採 ad-hoc 簽章，不需要 Apple Developer ID，但仍必須完成真正的編譯、簽章完整性與啟動驗證。

來源（2026-10-24 核對）：

- <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>
- <https://docs.github.com/en/actions/concepts/billing-and-usage>
- <https://docs.github.com/en/billing/concepts/product-billing/github-actions>
- <https://docs.github.com/en/billing/reference/actions-runner-pricing>

## 可重現流程

`bash scripts/build.sh` 會依序執行真正的 Swift 編譯與測試、建立 App bundle、加入原創圖示、簽署 guardian 和 App、驗證 ARM64、啟動安全 UI smoke test、採集三種 fixture 狀態的 CPU/RSS、測試子程序生命週期、建立包含原始碼與報告的 ZIP，最後解壓並重新驗證。

任何必要步驟失敗都會停止，不會把空 `.app` 或僅原始碼 ZIP 標記為 App 發行版。`build/releases/MoPanel-macOS27-arm64.zip` 僅會在上述步驟成功後建立。最後的 ZIP 完整性檢查若失敗，CI 不會上傳發行產物。

SwiftPM 原生 executable 的 `Bundle.module` 可能回退到編譯主機的絕對 build 路徑。App 安裝後不能依賴這個位置，因此 fixture 資源會先從 App `Contents/Resources` 內的 target bundle 尋找，smoke test 必須證明實際 fixture 路徑在 App bundle 裡。否則即使編譯主機上能開啟也不算通過。

`scripts/prepare_mole_fixture.py` 是 CI 用途：從官方 repository 取得固定基準與當前 macOS 穩定版、排除 Windows／預發行 tag、下載官方 ARM64 analyze/status binary 並核對官方 SHA256SUMS。固定 V1.62.0 同時核對來源 commit，避免同名 tag 移動後默認沿用。它不執行安裝腳本、不使用 sudo、不修改 shell 設定。`scripts/audit_cli.py` 僅執行 help/version/status/history、uninstall 的唯讀清單與暫存目錄的 analyze，會比對官方基準 help 選項並限制 watch 的 frame 大小和等待時間；不執行任何清理、卸載、最佳化或瘦身。

SwiftTerm 的 package manifest 包含 Metal shader resource，即使 App 選用 CoreText 繪圖也可能需要 Metal 編譯工具。因此 CI 先檢查 `xcrun metal --version`，只有缺少時依 Apple 官方流程下載 MetalToolchain。這是建置用元件，不會隨 MoPanel App 安裝，也不需要把 GUI 改成 Metal renderer。來源：<https://developer.apple.com/documentation/Xcode/downloading-and-installing-additional-xcode-components>。

發行包的 `Source/Vendor` 保留實際解析的 SwiftPM 相依原始碼與原始授權；`Package.resolved` 與 `Reports/dependencies.json` 記錄完整 revision。SwiftTerm manifest 會另外解析 Argument Parser 與文件工具，這不表示 MoPanel 連結或啟動它們。此來源副本也不代表已配置離線建置。

## 簽章

此流程使用 ad-hoc 簽章 (`codesign --sign -`)。它能驗證 bundle 完整性，無法提供 Apple Developer ID 身分或公證。`spctl` 結果會保留，ad-hoc build 被 Gatekeeper 拒絕不會被寫成「已公證」。流程不會關閉 Gatekeeper、移除 quarantine 或改變 macOS 安全設定。

## 效能測量的範圍

`scripts/profile.py` 每 0.5 秒取樣一次 GUI 及其可觀察子程序的 `ps` CPU/RSS，依 App 回報的 workload 開始時間排除啟動、CLI 偵測、前 2 秒暖機及關閉時間。既有 fixture 模式會量測 GUI／Mock CLI 的閒置、監控、掃描負擔，寫入 `performance.json`。

CI 另外以 `--real-cli` 指定已校驗的官方 baseline，經 App 的唯讀 allowlist 執行真正的閒置、單一 status watch、analyze 掃描，另寫入 `performance-real-cli.json`。每個模式建立獨立 RUNNER_TEMP session；掃描 corpus 為 5,000 個各 4,096 bytes 的新平面檔案，沒有子目錄或 symlink。GUI 的 HOME 不變，只有唯讀 CLI 子程序取得專用 HOME／TMPDIR。scan 取樣還必須落在 App 回報的真實掃描區間，且全部掃描都要完整完成。

重複掃描會使用溫熱的 OS 檔案系統快取；這不代表完整磁碟、外接磁碟、權限受限資料或破壞性清理工作的成本。`ps` CPU 值是程序存活期平均值，峰值是觀察樣本最大值，並非 Instruments 的瞬時追蹤。GUI 與子程序 RSS 相加可能重複計算共用頁面，不是唯一實體記憶體占用或活動監視器的記憶體壓力。測量數據僅能在實際執行後記入 TEST_REPORT；GitHub CI 發行流程要求兩組效能證據都成功才可封裝。

## 本次本地環境

本地工作環境為 Linux x86_64，沒有 Xcode、AppKit 或 macOS SDK。已另外在暫存工作區安裝官方 Swift 6.4.1 Linux toolchain 及本地 libncurses runtime，供 Foundation 和程序測試。Linux 通過不等於 macOS GUI 編譯通過；最終 macOS 建置結果須以實際 Actions run 或 Mac 執行紀錄為準。

## 公開 GitHub Actions 建置狀態

公開repository [steven87090799/MoPanel-macOS](https://github.com/steven87090799/MoPanel-macOS)使用免費標準`xcode-27` ARM64 runner，實際image20261022.0305.3、macOS27.0.1、Xcode27.1、Apple Swift6.4。API token只送同host官方release metadata請求；binary與checksum下載無授權header。

最新[run40078440635](https://github.com/steven87090799/MoPanel-macOS/actions/runs/40078440635)通過140Mac XCTest、App及helpers release編譯、ARM64與ad-hoc完整性，正式executables沒有get-task-allow。Python／Bash的Homebrew15、gate6、driver8、crash辨識5、debug guard8也通過。

這次正式App不再崩潰，10.129秒完成safe smoke JSON及自己的視窗截圖，20項中19項通過：adapter／watch／路由存活、安全IOPM assertion與overlay生命週期／Doctor唯讀資料／Startup私有mock皆成功。公開selector bridge已真Mac編譯通過，掃到257個節點（173 protocol＋84 selector-only，unsupported0），但仍無MoPanel IDs。唯一失敗仍是dashboard snapshot控制項辨識，尚未執行任何AX按壓。截圖中的可見按鈕不能代替真正操作驗收；沒有直接action fallback。

兩個獨立gate保留XCTest成功與smoke失敗，仍非零退出，效能、guardian Python、baseline probe和ZIP尚未執行。有完整JSON的明確邏輯失敗不再多跑LLDB副本，driver8項與實際FAIL保存都已在Mac驗證。前幾輪scene graph重入stack保留為修前證據；這次不是崩潰或逾時。下一輪仍須完整通過AX及其後所有門檻。

`scripts/audit_platform.py` 已在真macOS執行四組固定、唯讀的 `launchctl` 公開介面探測。help與print-disabled exit0，對不存在fixture服務的print exit113。原始輸出保留於 `platform-contracts.json`，沒有呼叫 enable、disable、bootstrap或bootout，也未讀取私有BTM資料庫。
