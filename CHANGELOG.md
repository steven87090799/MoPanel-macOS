# CHANGELOG

## 0.1.0 開發候選版 — 2026-10-24

- 新增 SwiftUI/AppKit 原生 MoPanel 介面，目標 macOS 27 Apple Silicon，原創圖示、繁體中文／英文與外觀設定。
- 以官方 Mole V1.62.0 來源盤點建立獨立指令、選項及 JSON/NDJSON 相容層；不內建固定版清理引擎。
- 新增總覽、清理、卸載、最佳化、磁碟分析、Purge、Installer、Slim、歷史、設定十個操作入口。
- JSON 可用處採原生畫面；未提供穩定逐項 API 處保留原生嵌入終端，清楚說明限制。
- 新增 Dry Run 入口、變更前確認、個人資料預設保留、版本與能力變更檢查。
- 新增 C guardian，提供正確 argv、PTY、生命週期、取消及逾時保護；不紀錄密碼輸入。
- 新增基準資料模型、特殊檔名、失敗狀態、版本相容、程序取消、逾時與異常退出測試。
- 新增 macOS27 ARM64 CI、ad-hoc 簽章、bundle/ZIP 驗證、UI smoke test 和安全效能測量流程。

**開發候選版不是已驗收發行版。實際編譯、測試及未完成項目以 TEST_REPORT.md 為準。**
