# macOS 專用程式路徑靜態檢查

日期：2026-10-24。**這是以原始碼、固定版本相依套件介面及 Apple 官方文件進行的靜態檢查，不是 macOS 編譯、連結、簽章或啟動測試。** 實際平台驗證狀態請看 `TEST_REPORT.md`。

## SwiftTerm／SwiftUI 終端

核對 SwiftTerm `v1.20.0` 的 `MacTerminalView.swift`、`AppleTerminalView.swift`、`TerminalOptions.swift` 與 `TerminalViewDelegate.swift`：

- `TerminalView(frame:font:options:)`、`configureNativeColors()`、`feed(byteArray:)`、`optionAsMetaKey`、`allowMouseReporting` 皆為該固定版本公開 API，呼叫標籤與型別一致。
- `TerminalOptions` 支援 `cols`、`rows`、`.steadyBlock`、`scrollback`、`enableSixelReported`、`kittyImageCacheLimitBytes`。本 App 限制 scrollback 為 500 行、image cache 為零、未啟用 Metal renderer。
- Coordinator 實作該版本全部必要的 terminal delegate methods。使用 `@MainActor` 與 `@preconcurrency` 協定相容標記；輸出 callback 在主執行緒交給 AppKit。
- Apple 的 `NSViewRepresentable.dismantleNSView(_:coordinator:)` 介面具有 MainActor 隔離；目前實作在移除 view 時解除 callback 並請求取消。
- `MetalTerminalRenderer.candidateBundles()` 自行檢查 `Bundle.main.resourceURL/SwiftTerm_SwiftTerm.bundle`，避開 `Bundle.module` 的 fatalError。將相依資源放在 `Contents/Resources` 符合此版本 resolver，未依賴建置機絕對路徑。

參考：[SwiftTerm 固定版本](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0/Sources/SwiftTerm)、[Apple NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)。

## AppKit 路徑編輯器

檢查 `NSApplication`、`NSWindow`、`NSTextView`、`NSScrollView`、`NSStackView`、`NSOpenPanel`、`NSAlert`、`NSFileCoordinator` 的呼叫形狀，沒有發現可確定的 API 名稱或參數標籤不一致。

一處已改善：將已棄用的 `activate(ignoringOtherApps:)` 改為 macOS 現行的 `NSApplication.activate()`。仍須在 macOS 登入工作階段確認輔助程式取得焦點與原生選擇器操作。

設定檔後端的 Darwin `st_mtimespec`、`stat`、`openat`／`O_NOFOLLOW`、`fchmod`、`fsync`、`renameat`、`flock` 路徑已逐項檢查；數值轉換使用明確 Int64／UInt64，避免 Linux 與 Darwin `off_t`、`dev_t` 型別不同造成比較問題。

參考：[Apple activate()](https://developer.apple.com/documentation/appkit/nsapplication/activate())、[Apple NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)。

## C guardian 的 Darwin 分支

已對照 Apple 公開原始碼中的宣告與實作：

- `<util.h>` 宣告 `forkpty(int *, char *, struct termios *, struct winsize *)`，目前使用方式相符；macOS 不需要 Linux 的 `-lutil`。
- `<libproc.h>` 的 `proc_listpids(uint32_t, uint32_t, void *, int)` 與 `proc_pidinfo(int, int, uint64_t, void *, int)` 參數相符。
- `PROC_PPID_ONLY`、`PROC_PIDTBSDINFO`、`struct proc_bsdinfo.pbi_start_tvsec/pbi_start_tvusec` 存在。
- `proc_listpids` 回傳 bytes；目前以 `sizeof(pid_t)` 換算數量正確。Apple 的 `proc_listchildpids` 自己也執行同類除法。
- Linux 專用 `prctl`、`/proc`、namespace 檢查都被 `#ifndef __APPLE__` 分隔，不會進入 Darwin 分支。

參考：[Apple libproc.h](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h)、[Apple libproc.c](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)、[Apple proc_info.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h)、[Apple util.h](https://github.com/apple-oss-distributions/Libc/blob/main/include/util.h)。

## Bundle、簽章與權限

目前方案沒有開啟 App Sandbox；它與 Hardened Runtime 是不同機制。App 需要呼叫獨立安裝的官方 CLI、PTY 及使用者選定的檔案，因此不能只加上 `app-sandbox` 或 `inherit` entitlement 就宣稱整個清理流程可運作。

`Contents/Helpers` 是 Apple 文件列出的 helper 工具位置。建置腳本先對兩個 helper 分別簽章，再簽外層 App；每個工具有獨立 signing identifier。這是合理的巢狀程式碼簽章順序，仍須實際 `codesign --verify --deep --strict` 才能確認產物。

- guardian／editor 都以使用者權限執行，不需要 privileged helper、SMJobBless、LaunchDaemon、root GUI 或 SIP 修改。
- 沒有全域鍵盤監聽、Apple Events 自動化或 JIT，因此目前程式不需要為這些功能新增權限豁免。
- 完整磁碟存取仍是使用者在系統設定授權的 TCC 權限；ad-hoc 簽章不會自動取得或繞過權限。CLI 及子程序權限歸屬需在實機確認。
- ad-hoc 與 `--options runtime` 不是 Developer ID，也不是 Apple 公證。不能由簽章指令存在就宣稱 Gatekeeper 已接受下載版本。
- Slim 的合作式取消可能讓 guardian 短暫繼續監督交易；一般操作則採訊號與兩秒升級策略。對升權或脫離監督的任意子程序不能做絕對終止保證。

參考：[Apple Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)、[Apple Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)、[Apple 嵌入 helper 工具](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)。

## 結果

這次針對性檢查沒有發現其他可確定的 macOS API 型別／標籤錯誤；已修正一個棄用的 AppKit 啟用介面。沒有重跑既有 Linux 測試，也沒有把 Linux 語法檢查當成 macOS 編譯通過。實際 ARM64 Mac 編譯、native UI 啟動、libproc 與 PTY 系統互動、TCC、sudo、App bundle 與簽章檢查仍需完成。
