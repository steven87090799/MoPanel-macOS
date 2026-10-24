#!/usr/bin/env python3
"""Write release-specific findings from actual successful build evidence."""
import datetime
import json
import pathlib
import platform
import re
import sys

package = pathlib.Path(sys.argv[1]).resolve()
reports = package / "Reports"
smoke = json.loads((reports / "smoke-test.json").read_text())
performance = json.loads((reports / "performance.json").read_text())
if (not smoke.get("success") or not smoke.get("window_created") or not smoke.get("fixture_only")
        or smoke.get("checks", {}).get("fixture_resource_inside_app") is not True):
    raise RuntimeError("Missing successful safe native UI smoke evidence")
if not performance.get("fixture_only") or len(performance.get("modes", [])) != 3:
    raise RuntimeError("Incomplete three-mode performance evidence")
bundle_log = (reports / "bundle-verification.txt").read_text()
if "PASS: bundle layout, ARM64 executables, signature integrity" not in bundle_log:
    raise RuntimeError("Bundle validation did not pass")
test_log = (reports / "swift-test.log").read_text()
test_counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", test_log)
# XCTest includes an extra skipped-count phrase on runs with skipped cases.
skipped_counts = re.findall(r"Executed (\d+) tests?, with (\d+) tests? skipped and (\d+) failures?", test_log)
test_counts += [(count, failures) for count, _, failures in skipped_counts]
skips = max((int(skipped) for _, skipped, _ in skipped_counts), default=0)
if not test_counts or any(int(failures) != 0 for _, failures in test_counts):
    raise RuntimeError("Swift tests do not show a clean result")
if skips:
    raise RuntimeError("Required Swift tests were skipped; no verified App release will be emitted")
guardian_log = (reports / "guardian-test.log").read_text()
guardian_count = re.search(r"Ran (\d+) tests? in", guardian_log)
if not guardian_count or not re.search(r"^OK\s*$", guardian_log, re.MULTILINE):
    raise RuntimeError("Guardian integration tests did not finish without failures/skips")
date = datetime.datetime.now(datetime.timezone.utc).isoformat()
lines = ["# 實際建置與驗證報告", "", f"產生時間：{date}", "",
         f"建置平台：{platform.platform()}；架構：{platform.machine()}。", "",
         "此報告由成功建置後的實際紀錄產生；原始紀錄位於 `Reports/`。", "",
         "| 驗證 | 結果與範圍 |", "|---|---|",
         f"| Swift 編譯與單元測試 | 最多匯總 {max(int(x[0]) for x in test_counts)} 個 XCTest，{skips} skipped，0 failures。見 swift-test.log；略過項目不算已驗證 |",
         f"| Guardian 程序整合測試 | {guardian_count.group(1)} 個案例通過，0 failures／skipped。見 guardian-test.log |",
         "| ARM64 | 主程式、guardian 與原生 paths 編輯器均通過 lipo 檢查，只有 arm64 |",
         "| App Bundle | Info.plist、主程式、helper、圖示與必要資源存在 |",
         "| Code Signing | ad-hoc 簽章與 codesign strict/deep 完整性驗證通過 |",
         "| Apple 公證 | 未進行；沒有宣稱 Developer ID 身分 |",
         "| UI 啟動 | 原生 App 視窗已建立，fixture-only smoke test 通過 |",
         "| 真實個人資料操作 | 未執行清理、卸載、最佳化或瘦身 |",
         "| UI 完整互動驗收 | Smoke test 不能代表每個按鈕、VoiceOver 與實機權限流程都已驗證 |",
         "| ZIP | 建置流程在封裝後解壓並驗證 manifest、結構與簽章；最終結果見外部 zip-verification.txt |",
         "", "## CLI 相容性實測", ""]
for filename, label in [("cli-contract.json", "基準"), ("latest-cli-contract.json", "建置時最新穩定版")]:
    path = reports / filename
    if path.exists():
        report = json.loads(path.read_text())
        if not report.get("passed"):
            raise RuntimeError("CLI contract report failed")
        lines.append(f"- {label}：`{report['version']}`；read-only help/status/watch/analyze/history 合約檢查通過。")
    else:
        lines.append(f"- {label}：未執行；不可推定相容。")
lines += ["", "## 實際效能取樣", "", "以下使用合成資料，量測 GUI 與 Mock CLI，不代表真實 CLI 大型磁碟成本。CPU 是 ps 的程序平均值。", "",
          "| 狀態 | 平均 CPU % | 峰值 CPU % | 平均 RSS MiB | 峰值 RSS MiB |", "|---|---:|---:|---:|---:|"]
for mode in performance["modes"]:
    lines.append(f"| {mode['mode']} | {mode['cpu_mean_percent']:.3f} | {mode['cpu_peak_percent']:.3f} | "
                 f"{mode['rss_mean_bytes']/1048576:.2f} | {mode['rss_peak_bytes']/1048576:.2f} |")
lines += ["", "## 尚須實機驗收", "",
          "管理員驗證、完整磁碟存取、真實 Homebrew cask、第三方 App 簽章、外接硬碟、完整 VoiceOver 操作，以及 macOS 更新後的行為，仍須使用者在自己的 Mac 上依官方確認逐項驗證。取消已完成的操作不會回復被永久刪除的資料。", ""]
(package / "TEST_REPORT.md").write_text("\n".join(lines))
