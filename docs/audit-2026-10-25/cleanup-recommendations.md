# MoPanel 預選規則與來源

版本 `2e3e574`。Mole 的 clean-list.txt 提供候選路徑與掃描容量；MoPanel 以固定本機規則決定預選，不把候選清單或 MoPanel 建議冒稱為 Mole 推薦。介面現已顯示「Mole 提供掃描候選 · MoPanel 判斷預選」，每項細節也標明來源。掃描時不詢問 AI。

這次新增預選：

- npm／Gradle 的已知套件快取。
- GoogleUpdater 的 crx_cache 與指定舊更新紀錄；下載快取在 Chrome／更新器執行時保留。
- 指定 Logi／UGREEN App 的 Code Cache、GPUCache、Dawn 系列及 Cache_Data；對應程式仍在執行時保留，不泛化到整個 Application Support。
- 家目錄內指定專案位置的 __pycache__。只有所有子項目都是目前使用者的普通 CPython .pyc，且都有同位置的普通 .py 原始碼，沒有連結或其他檔案，才允許並預選。最多接受 1000 個直接子項目。來源缺失、混入其他內容、隱藏工具資料或 App 內路徑均不允許。

權限、路徑身分、保護清單、掃描過期及執行前重新驗證仍保留。程式狀態檢查只在掃描／執行時做唯讀快照，不新增計時器、不結束 App；這不構成阻止其他程式同時啟動的鎖。快取可重建也不表示必須刪除，使用者仍可取消選取。

260 項 XCTest（零失敗／略過）、20 項 fixture、46 項原生 UI 斷言／29 次已驗證按鈕派送、17 項 Guardian 與 App／ZIP 驗證通過。24 項生產檔案操作整合檢查只移動 nonce 合成資料。新增測試涵蓋窄路徑判斷、執行中的對應 App、原始碼缺失後撤銷核准、混入個人檔案、目錄與符號連結。

以使用者當時清單做唯讀核對，預選從 29 項／78.8 MB 增為 55 項／約 997.9 MB，其中新增 18 個經原始碼核對的 Python 快取；正在執行的 App 快取、無法讀取的資料及來源不明項目仍保留。此數字是當時快照，不保證下次掃描相同。私人路徑與原始清單只留在本機。

參考資料：

- [npm 快取說明](https://docs.npmjs.com/cli/v7/commands/npm-cache/)
- [Chromium Updater 功能規格](https://chromium.googlesource.com/chromium/src/+/main/docs/updater/functional_spec.md)
- [Electron session／產生的程式碼快取](https://www.electronjs.org/docs/latest/api/session)
- [Python 編譯模組快取](https://docs.python.org/3.13/tutorial/modules.html)

已更新本機版本並保留前版備份。本次沒有清理使用者檔案，也沒有改變權限設定。
