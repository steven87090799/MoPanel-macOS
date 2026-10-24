# Git Worktrees：MoPanel 原生新增功能

此模組以已安裝的正式 Git 管理使用者選定倉庫的 linked worktrees。它不是 Mole CLI 指令，不修改 Mole，也不包含官方付費 GUI 的私有程式碼。介面有繁體中文／英文的列表、搜尋、保護原因、重新掃描、單項移除預覽、明確確認、停止、Finder 定位與由保留分支重建的入口。

它沒有 AI session 掃描或格式推測，也不實作官方 GUI 不同版本的 3 天／2 週候選門檻。目錄 mtime 與 commit 日期均不能可靠證明工作目錄已閒置，本模組不以這些資料自行判定可刪除。

## 使用方式與資料後果

1. 開啟 Git Worktrees，按「選擇倉庫」。可選主倉庫或 linked worktree，只讀取此倉庫的 Git 清單，不遞迴搜尋使用者家目錄。
2. 檢視工作目錄、HEAD、分支與保護原因。原始路徑保留空白、換行與 Unicode，不以文字選取編號執行移除。
3. 按單項「移除預覽」。此時只有唯讀檢查，不建立分支或刪除檔案。Git `worktree remove` 沒有 dry-run，介面不冒稱是官方 dry-run。
4. 儲存工作、關閉使用該目錄的 IDE、終端與建置後，閱讀後果並勾選確認。MoPanel 先建立 `refs/heads/mopanel-recovery/<UUID>` 分支保留目前 HEAD，驗證 ref，重新檢查目標，最後呼叫 `git worktree remove -- <精確絕對路徑>`。從不加 `--force`，也不自行 `rm` 來源。
5. 「保留分支與重建」會從官方 ref 清單找出此命名空間的 UUID 分支；重新開啟 App 後選同一倉庫、重新掃描仍可辨識。選擇尚不存在的新位置、再次確認後，由 `git worktree add --no-guess-remote -- <新位置> <保留分支>` 重建並核對 HEAD、索引 entries 與乾淨狀態。

**移除是永久刪除，不經垃圾桶。保留分支依賴原倉庫和 Git 物件仍存在，不是獨立備份。** 它保留 Git 已提交的內容，不保存完整檔案系統狀態、空目錄、ACL、延伸屬性或完整 reflog；不提供刪除保留分支的按鈕。已忽略、未追蹤及未提交內容會使移除受阻，不會被當成可丟棄資料。原本 detached HEAD 的目前提交也必須先有保留分支才可移除。

## 實際保護條件

| 狀態 | 處理 |
| --- | --- |
| 主工作目錄、bare、locked、prunable | 顯示並保護；不 force、unlock、prune 或 repair |
| tracked 修改／衝突、untracked、ignored | 阻擋移除；ignored 也明確列為保護原因 |
| submodule/gitlink | 阻擋；不以 force 越過 Git 本身限制 |
| skip-worktree／assume-unchanged | 阻擋，避免索引旗標隱藏變更 |
| 私有 refs、進行中 merge/rebase/bisect 等中繼資料 | 阻擋；未知檔案不猜測可刪 |
| HEAD reflog 或 ORIG_HEAD 有未被目前 HEAD 或本地分支保留的提交 | 阻擋，避免僅保留當前 HEAD 就丟失之前的 detached 歷史 |
| COMMIT_EDITMSG | 最多 64 KiB，以原始 bytes 比對 HEAD commit 的原始 message；不同或過大即保護。含編輯器註解的訊息也可能因不完全相符而受阻 |
| 空 refs 目錄結構 | 支援新版 Git 正常建立的空 refs scaffolding；非空私有 ref 檔案、符號連結或未知結構受保護 |
| filter、sparse、partial clone、worktree-specific config、config include、相對路徑特殊設定 | 保守阻擋，不修改使用者設定來強行相容 |
| alternates／http-alternates、grafts、shallow 或非標準物件儲存位置 | 阻擋，避免把依賴其他物件庫的 ref 說成完整復原點 |
| 缺少權限、擁有者不符、可被其他帳號寫入、leaf symlink、路徑重疊、格式不明／截斷 | 不產生可執行移除計畫 |
| 預覽後 HEAD、branch、config、路徑、inode/device、關鍵中繼資料或狀態變更 | 要求重新掃描／預覽，不沿用舊計畫 |
| 已存在或確認後才出現的恢復目的地 | 阻擋，保留其內容，不覆寫 |

檔案系統身分以 POSIX `realpath` 與 `lstat` 證據綁定，不靠 Foundation 對 `/var`、`/private/var` 的 URL 字面表示相等。使用者選取的祖先別名先轉成已驗證實體路徑；工作目錄本身、Git pointer 或關鍵中繼資料的 symlink 不會變成可移除目標。新目的地的實體父目錄與身分也要重新驗證。

## Git 呼叫契約

所有參數為直接 argv，沒有 shell 拼接或執行解析出的文字。Git 來源限既有 `/opt/homebrew/bin/git` 的正式 Cellar layout，或 `/usr/bin/git`。不下載／安裝 Git。已選執行檔在高階操作前計算 SHA-256 與檔案身分，確認後重新比對；每個子程序開始前再次核對 metadata。Apple 的 `/usr/bin/git` 仍由已安裝的 Apple 開發工具提供實際 Git。

| 目的 | 正式命令／介面 |
| --- | --- |
| 能力探測 | 完整保護 prefix 加 `--version`，不因舊 Git 缺旗標而移除保護 |
| 清單 | `worktree list --porcelain -z`，最多 128 個 worktrees |
| 根目錄／共用 Git dir | `rev-parse --path-format=absolute` 搭配 `--show-toplevel`、`--absolute-git-dir`、`--git-common-dir` |
| 狀態 | `status --porcelain=v2 -z --untracked-files=all --ignored=matching --ignore-submodules=none` |
| 索引／隱藏旗標 | `ls-files --stage -z`、`ls-files -v -z` |
| 特殊設定 | `config --local --null --name-only --get-regexp <固定樣式>`；只取名稱，不展示 config 的值或憑證 |
| 提交與歷史保護 | `cat-file commit <HEAD>`、`reflog show --max-count=2049 --format=%H HEAD --`、`rev-list --max-count=1 … --not <HEAD> --branches --` |
| ref 存在性／型態／值 | `symbolic-ref --quiet`、`show-ref --exists`、`rev-parse --verify --quiet --end-of-options <ref>^{commit}` |
| 建立保留分支 | `update-ref --no-deref --create-reflog <新 UUID ref> <HEAD> <零 OID>` |
| 移除 | `worktree remove -- <已重驗絕對路徑>`，不加 force |
| 找回保留分支 | `for-each-ref` 的固定 NUL 欄位（refname、objectname、symref） |
| 重建／驗證 | `ls-tree -r -z --full-tree <commit>`、`worktree add --no-guess-remote -- …`、重新讀取清單／索引／status |

每次呼叫使用 `--no-pager --no-optional-locks --no-lazy-fetch --no-replace-objects --literal-pathspecs`，並用 per-command `-c` 關閉 hooks、fsmonitor、untracked cache、自動 gc／maintenance、submodule recursion 與 Git transport。固定環境隔離系統／全域 Git config、系統 attributes，並停用終端憑證提示。復原 ref 的 reflog 使用固定 `MoPanel Recovery <recovery@mopanel.invalid>` 身分，不修改持久 config，也不建立新的 commit。既有本機 filter／特殊設定在狀態與復原動作前受到檢查。

唯讀子程序有 45 秒 timeout；輸出上限為 16 MiB。變更步驟採合作式取消，不以兩秒強殺截斷 Git 的處理。所有子程序經 `ManagedProcess`／guardian 管理。建構 controller、開啟頁面與 App 閒置都不啟動掃描或輪詢，沒有 LaunchAgent、常駐服務或自動清理。測試及效能模式不會回退到真實使用者倉庫。

## 並行寫入與失敗邊界

Git 的 worktree 狀態檢查、ref 建立及檔案移除不是對外部 IDE／Git 程序的單一原子交易。確認框要求停止此工作目錄的外部寫入，MoPanel 會重驗，並保留 Git 本身的 no-force 檢查，但不能宣稱能排除所有同時寫入競態。

特別驗證了 Git 2.51.1 的一個差異：`update-ref --no-deref` 的零舊 OID **仍可替換 dangling symbolic ref**，`--stdin create` 也有此行為。因此不能用 `rev-parse` 無法解析提交就推論 ref 不存在。MoPanel 在預覽與建立前最後階段，用 `symbolic-ref` 和不要求解析 object 的 `show-ref --exists` 檢查碰撞；建立後及移除前再次要求 direct ref 與精確 OID。這是前後重驗，**不是持鎖的原子 absent-ref 保證**。本版本沒有新增互動式 `update-ref prepare/commit` 協定，也不會以不實的 atomic/no-overwrite 宣稱掩蓋外部程序在檢查與建立間變更 ref 的邊界。

若取消或錯誤發生在 ref 建立後，保留該 ref，顯示「已驗證／尚未驗證」與精確名稱。Git 移除或重建可能部分完成；MoPanel 不手動清除來源／目的地、不強制回復，也不將單純 exit 0 當成完整成功。操作後會讀回狀態；未通過驗證時清空舊的可執行清單，要求重新掃描。介面顯示執行摘要，不宣稱提供完整 Git stderr 日誌；config 值與原始錯誤輸出不匯出。

切換離開頁面會清除尚未確認的計畫及取消唯讀檢查，已確認的變更繼續由 guardian 管理。關閉 App／要求停止則取消目前擁有的作業。pending 計畫清除與停止要求只在狀態真正改變時發布，避免在 SwiftUI host teardown 反覆發布同值。

## 實測與仍未驗證的部分

新增測試位於 `GitWorktreeParserTests.swift`、`GitWorktreeIntegrationTests.swift`。Linux 使用 Swift 6.4.1 與實際 Git 2.51.1，在每案新建的私有 `MoPanelGitCase-<UUID>` 臨時倉庫執行；不使用 MoPanel 原始碼 checkout 或任何使用者倉庫。解析／契約 7 案，加真 Git 整合 21 案，共 28 案通過，零失敗／零 skip。原始執行輸出隨交付證據提供。

實際驗證包括 unique／detached HEAD 的保留與移除、重新建立及內容比對，原分支保存；main、bare、prunable、locked、dirty、untracked、ignored、submodule、skip／assume、私有 refs、reflog 未保留歷史、COMMIT_EDITMSG 草稿與過大內容保護；確認後身分／狀態／config／目的地變化；直接與 symbolic／dangling ref 碰撞；hook 與 filter canary 未執行；特殊路徑、特殊檔名、binary bytes、追蹤 symlink、祖先別名、未知／截斷格式和界限。失敗／取消後的保留 ref 行為使用真倉庫與受控命令結果注入，不假裝曾中斷真實使用者清理。

同環境 `/usr/bin/git 2.43.0` 實際拒絕 `--no-lazy-fetch`，此情況明確停用功能；沒有省略旗標以求通過。上述 Linux 測試不能替代新頁面的 macOS SDK 編譯、原生 UI 按鈕、VoiceOver 或各使用者倉庫驗收。這些平台結果由後續真正 macOS CI 的報告分開記錄，不把既有 140 項 Mac 測試當成本模組的新驗收。

## 程式碼位置

- `Sources/MoPanelCore/GitWorktreeModels.swift`：資料、保護原因、NUL 解析及固定契約。
- `Sources/MoPanelCore/GitWorktreeService.swift`：唯讀檢查、確認計畫、ref 保留、官方 remove／add、身分與結果重驗；抽象 async runner。
- `Sources/MoPanelApp/GitWorktreeController.swift`：原生檔案面板、已安裝 Git 身分、owned process、全域操作 gate、取消與摘要。
- `Sources/MoPanelApp/GitWorktreeView.swift`：完整繁中／英文入口、保護狀態、預覽與確認。

## 官方來源

- [Git worktree](https://git-scm.com/docs/git-worktree)：穩定 porcelain／NUL 格式、main／locked／dirty／submodule 限制、私有 refs 與 worktree config。
- [Git status](https://git-scm.com/docs/git-status)：porcelain v2、untracked 與 ignored 介面。
- [Git ls-files](https://git-scm.com/docs/git-ls-files)：stage、gitlink 與 skip-worktree／assume-unchanged 旗標。
- [Git update-ref](https://git-scm.com/docs/git-update-ref)：舊 OID 比較、no-deref、reflog 與 transaction 邊界。
- [Git show-ref](https://git-scm.com/docs/git-show-ref)：`--exists` 不要求 ref 能解析為物件，並區分不存在與其他錯誤。
- [Git configuration](https://git-scm.com/docs/git-config) 與 [Git global options](https://git-scm.com/docs/git)：per-command hooks／fsmonitor、no-lazy-fetch、no-replace-objects 與 optional locks。
- [Git 2.51.1 files backend](https://github.com/git/git/blob/v2.51.1/refs/files-backend.c) 與 [update-ref implementation](https://github.com/git/git/blob/v2.51.1/builtin/update-ref.c)：配合隔離實測，核對 dangling symbolic ref 的零 OID 行為；沒有複製其實作進 MoPanel。
