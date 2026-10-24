# Mole CLI 相容性

## 已盤點的基準

| 項目 | 值 |
|---|---|
| 官方來源 | https://github.com/tw93/Mole |
| 最新穩定版本查詢日期 | 2026-10-24 |
| 已盤點版本 | V1.62.0 |
| 固定來源 commit | `91a7bf44f96995361b10b5a0e9efae36a1490bf9` |
| GUI 目標平台 | macOS27+，Apple Silicon ARM64 |
| 本次本地測試主機 | Linux x86_64 + Swift6.4.1 |
| Mac 真實 CLI 實測 | 須以 TEST_REPORT.md 與 Reports/cli-contract.json 實際紀錄判定 |

版本來源：<https://github.com/tw93/Mole/releases/tag/V1.62.0>。盤點文件以 release 固定來源為基準，不能把 main 的新增功能冒充 release 已支援。

## 相容策略

`MoPanelCore/MoleCompatibility` 檢查版本及命令 help 公開介面；`CLIProbe` 檢查執行檔、資源位置、來源與 fingerprint；每次結構化結果仍經由 `MoleJSON` 完整解碼。GUI 不修改已安裝 Mole 的原始碼。

- V1.62.0：來源盤點基準，仍需真實 macOS 驗收；不能把 synthetic parser test 寫成官方完整操作驗證。
- 更新的穩定 1.x：逐命令檢查必要旗標，將相容公開介面標為「介面相容」。這不是對新版核心行為重新審核的保證；真實操作仍保留官方確認。
- 新 major、比基準舊的版本、無法解析版本或身分：停止受影響的變更操作，要求更新相容性資料。
- Nightly／dev：清理等變更操作停用。唯一的復原例外為來源及資源已確認的官方腳本安裝、數字版本仍是已知的 1.62.0 以上同 major、`update --help` 契約完整，且執行不含 `--nightly` 的 `mo update`。這條路徑仍需使用者確認，更新後重新偵測；不放行未知來源或新 major。
- Homebrew HEAD：仍停用變更操作。官方 `mo update` 呼叫 `brew upgrade mole`，會沿用原安裝選項，不能將它宣稱為切回穩定版。
- 某命令 help、必要旗標或 JSON 格式不相符：停止該功能，不將自由文字解析成可刪除計畫。
- JSON 增加未使用欄位可容忍；必要欄位、型別、負值與掃描狀態錯誤會回報不相容。

這個策略可持續使用公開 API 相容的官方更新，且不保證所有未來版本永遠不需要更新 GUI。大版本介面變更必須重新驗證。

## 原生與互動邊界

原生 JSON：`status --json`／`--watch`、`analyze --json`、`uninstall --list`、`history --json`。

官方 PTY：清理、卸載預覽／確認、最佳化、Purge、Installer、Slim、白名單／paths、Touch ID、completion、update、remove 與主選單。部分 Dry Run 可透過捕獲輸出原生顯示，但輸出是官方文字，不是可任意勾選的結構化刪除計畫。

`mo purge --paths` 的官方 `EDITOR` 擴充點指定到 App bundle 內的 `MoPanelEditor` 原生 AppKit helper，由官方 CLI 啟動，提供圖形化路徑編輯，不需要操作 vim 或輸入 shell 指令。

完整參數與 GUI／程式碼對照見 `CLI_COVERAGE.md`。

## 更新方法

Homebrew 安裝以其公式更新機制處理；官方腳本安裝使用 `mo update`；nightly 只在安裝來源已確認支援時顯示。使用者明確確認後才會進行更新。完成後 MoPanel 重新偵測能力；官方引擎和 GUI 分開更新。

官方腳本安裝的 Nightly／dev 可使用設定中的「返回官方穩定版…」。Mole V1.62.0 的更新流程會讀取該安裝的 channel receipt，將最新正式版本標籤交給官方 installer，即使數字版本相同，也會切回 stable。MoPanel 不另寫下載或降版引擎。`--force`／`--debug` 不改變這個穩定通道目標；`--nightly` 不在復原例外內。

此復原政策的 adapter／fixture 測試已執行，但本次沒有在真實 Mac 上更新或降版 Mole。Homebrew HEAD 需要由 Homebrew 管理其安裝通道；MoPanel 不在背景卸載重裝它，也不聲稱裸 `mo update` 能完成該通道切換。

流程依據：[Mole V1.62.0 更新器](https://github.com/tw93/Mole/blob/V1.62.0/lib/manage/update.sh)、[Mole Homebrew 更新實作](https://github.com/tw93/Mole/blob/V1.62.0/lib/core/common.sh) 與 [Homebrew 官方 upgrade 說明](https://docs.brew.sh/Manpage#upgrade-options-installed_formula--installed_cask-)。

CI 會另外讀取建置當下的 `releases/latest`，取得官方 source/binaries，核對官方 SHA256SUMS，執行 read-only CLI 合約探測。這不執行真實清理，也不能取代卸載、Slim、sudo、完整磁碟存取的實機 acceptance test。
