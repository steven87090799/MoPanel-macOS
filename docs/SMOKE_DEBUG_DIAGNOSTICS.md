# UI 啟動失敗的隔離診斷

這個流程只用於明確的 macOS GitHub Actions 測試，而且必須先有正式 release bundle 的 smoke 失敗。額外LLDB僅限signal崩潰、逾時、App報告缺失或格式無效；已產生完整有效JSON的邏輯檢查失敗直接保存失敗證據，不重跑拷貝。這不改變原本的驗收結果，也不產生可發行的替代 App。

正式 smoke 維持 45 秒期限，保存原始退出訊號、stdout、stderr、JSON。逾時時可對仍存活的自身子程序取樣；已崩潰時僅收集身分與時間吻合的自身 crash report。若 runner 沒有產生這些報告，另執行一次最長 60 秒的隔離診斷：

1. 記錄正式 App 主程式、CodeResources 及兩個 helper 的 SHA-256。
2. 將同一個已編譯的 release App 複製到 RUNNER_TEMP 的全新私有目錄；確認 bytes 相同且不共用檔案 inode。
3. 只對拷貝使用 ad-hoc runtime 簽章加上 `com.apple.security.get-task-allow`。
4. 由正式 guardian 管控 LLDB 子程序樹與逾時，以固定 `--smoke-test` 啟動拷貝；停用 lldbinit 載入，維持 ASLR，批次取得所有執行緒各最多 128 frames 的 backtrace。針對已觀察到的 SIGPIPE，以公開 `process handle SIGPIPE --stop true --notify true --pass true` 在 run 前設定除錯器暫停／通知，仍保留傳遞訊號；只影響此隔離 debug session，不修改正式 App 或 host 的訊號設定，也不吞掉失敗。
5. 保存獨立的 debugger log 與診斷 JSON，清除暫存拷貝，再核對正式 App 四個檔案的 SHA-256。

LLDB 或 codesign 遭拒絕時如實記錄；不提升權限，不修改 TCC、SIP、Gatekeeper 或系統設定。拷貝使用不同的 smoke JSON 路徑，即使在 debugger 下完成測試也不會覆蓋正式結果。原 smoke 失敗後仍明確非零退出，不進效能或 ZIP 封裝。

`verify-package.sh` 透過 `signature_policy.py` 檢查正式主程式與兩個 helper，若出現 `get-task-allow` key 即拒絕；值為 false 也不接受。診斷 App 不在來源清單或發行包目錄中。

`test_debug_smoke_failure.py` 使用合成檔案與 mocked codesign／LLDB，驗證 CI／失敗條件、只簽拷貝、報告隔離、原檔 hash、簽章拒絕、固定命令與 guardian、正式簽章拒絕策略。這些測試不是實際 LLDB stack 證據；真正 Mac 診斷結果保存於對應 run artifact。

官方參考：

- Swift backtrace 與 macOS debug entitlement 說明：<https://github.com/swiftlang/swift/blob/main/docs/Backtracing.rst>
- LLDB `--batch`、`--no-lldbinit`、`--one-line-on-crash`：<https://lldb.llvm.org/man/lldb.html>
