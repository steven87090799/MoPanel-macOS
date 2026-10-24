# MoPanel 新增的選單列與行程操作

這些功能是 MoPanel 自行實作，不是官方 Mole CLI 的新指令，也不是官方付費 GUI 私有程式碼。指標仍由獨立安裝的官方 CLI 提供。

## 選單列

`MenuBarPanel.swift` 使用原生 `MenuBarExtra`，預設關閉，可在設定啟用。選單列與總覽共用 `AppModel` 的同一個 `mo status --json --watch` 程序；不會另建採樣器。使用者明確啟用後，視窗失去前景或切換頁面仍會更新。暫停會停止這個串流；關閉最後視窗會結束 App，沒有 LaunchAgent 或 Login Item。

這個版本提供 CPU、記憶體、健康分數與所選網路介面，沒有隱藏 Dock 或登入自動啟動。它不是官方選單列全部偏好的完整複製。

## 行程列表與結束 App

`ProcessInspectorView.swift` 對官方傳回的高用量行程提供搜尋、CPU／記憶體／名稱排序與當前頁面的置頂。CLI 目前只傳回有限的 top-process 樣本；置頂不會額外掃描全部程序，也不會補造未回傳的讀值。

只有可以由 `NSWorkspace.runningApplications` 確認的一般 App 才有結束要求。控制器保存原本的 `NSRunningApplication` 物件，確認前後比對 PID、bundle identifier、canonical App／執行檔路徑、啟動日期與 CLI 樣本。樣本超過 15 秒、標示 stale、早於 App 啟動，或 CLI 路徑不能精確對應，均停止該動作。未知行程不使用 PID `kill`。

Apple 系統 App、MoPanel、BuhoCleaner、helper／背景程序不提供此動作。使用者在原生確認窗核對 App 後，才會呼叫 AppKit 的 `terminate()` 或明確選擇的 `forceTerminate()`。一般結束可能等待儲存提示；強制結束可能遺失尚未儲存的內容。API 接受要求不等於 App 已退出，結果文字明確區分。

這不是官方 GUI 的所有程序說明庫，也不能退出任意系統或背景程序。可使用真正的「開啟系統活動監視器」入口處理其他情況。

## 已執行的測試

2026-10-24，Swift 6.4.1 Linux，`NativeControlPolicyTests` **7 項通過、0 失敗、0 略過，0.205 秒**。測試涵蓋監控需求組合、手動暫停與關閉、PID 重用／路徑／啟動日期改變、舊樣本、未知命令、系統與自身保護、測試模式禁止結束、特殊檔名保持字面值。

新增及變更的原生 App Swift 檔已通過 grammar parsing；這不是 Apple SDK typecheck。實際 macOS 編譯、原生選單列呈現與 AppKit 行為以該版本的 CI `Reports/` 為準。本次測試未結束任何真實使用者 App，也未宣稱完成任意第三方 App 儲存／拒絕／強制結束的實機驗收。

## 原始 API 依據

- [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Apple NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication)
- [Apple terminate()](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate())
- [Apple launchDate](https://developer.apple.com/documentation/appkit/nsrunningapplication/launchdate)
- [Mole V1.62.0 程序採樣](https://github.com/tw93/Mole/blob/V1.62.0/cmd/status/metrics_process.go)
