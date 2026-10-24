#!/usr/bin/env python3
"""Write release-specific findings from actual successful build evidence."""
import datetime
import json
import os
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
real_performance_path = reports / "performance-real-cli.json"
real_performance = json.loads(real_performance_path.read_text()) if real_performance_path.exists() else None
if os.environ.get("GITHUB_ACTIONS") == "true" and real_performance is None:
    raise RuntimeError("CI release requires actual read-only engine performance evidence")
if real_performance is not None:
    if (real_performance.get("fixture_only") is not False
            or real_performance.get("read_only_enforced") is not True
            or {mode.get("mode") for mode in real_performance.get("modes", [])} != {"idle", "monitor", "scan"}
            or len(real_performance["modes"]) != 3
            or any(mode.get("app_evidence", {}).get("completed") is not True
                   or mode.get("app_evidence", {}).get("read_only_enforced") is not True
                   for mode in real_performance["modes"])):
        raise RuntimeError("Incomplete official read-only engine performance evidence")
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
# SwiftBuild can launch one .xctest bundle per module, each with its own
# "All tests" footer. Sum unique bundle summaries instead of taking a maximum
# (which would report only 47 of the first Mac run's actual 47 + 20 tests).
bundle_test_counts = {}
test_lines = test_log.splitlines()
for index, line in enumerate(test_lines[:-1]):
    suite = re.search(r"Test Suite '([^']+\.xctest)' passed", line)
    count = re.search(r"Executed (\d+) tests?, with", test_lines[index + 1])
    if suite and count:
        bundle_test_counts[suite.group(1)] = int(count.group(1))
total_swift_tests = sum(bundle_test_counts.values()) if bundle_test_counts else max(int(x[0]) for x in test_counts)
guardian_log = (reports / "guardian-test.log").read_text()
guardian_count = re.search(r"Ran (\d+) tests? in", guardian_log)
if not guardian_count or not re.search(r"^OK\s*$", guardian_log, re.MULTILINE):
    raise RuntimeError("Guardian integration tests did not finish without failures/skips")
date = datetime.datetime.now(datetime.timezone.utc).isoformat()
lines = ["# 實際建置與驗證報告", "", f"產生時間：{date}", "",
         f"建置平台：{platform.platform()}；架構：{platform.machine()}。", "",
         "此報告由成功建置後的實際紀錄產生；原始紀錄位於 `Reports/`。", "",
         "| 驗證 | 結果與範圍 |", "|---|---|",
         f"| Swift 編譯與單元測試 | 合計 {total_swift_tests} 個 XCTest，{skips} skipped，0 failures；多個 .xctest bundle 分別加總。見 swift-test.log |",
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
lines += ["", "## 原生擴充的唯讀平台契約", ""]
homebrew_path = reports / "homebrew-readonly.json"
if homebrew_path.exists():
    homebrew = json.loads(homebrew_path.read_text())
    if homebrew.get("status") not in {"passed", "read_only_compatible_upgrade_unavailable", "not_available"}:
        raise RuntimeError("Homebrew read-only audit did not reach a supported final state")
    if homebrew.get("mutations_executed") != [] or homebrew.get("real_app_updates_tested") is not False:
        raise RuntimeError("Homebrew audit scope does not match the read-only release gate")
    if homebrew["status"] == "not_available":
        lines.append("- Homebrew：runner 未安裝指定位置的 Homebrew；此項是不可用，沒有當成通過。")
    else:
        contract = homebrew["json_contract"]
        upgrade = homebrew["capabilities"]["upgrade_contract_compatible"]
        lines.append(f"- Homebrew：`{homebrew['brew_version']}` 的唯讀 help／installed／outdated JSON 契約通過；觀察到 {contract['installed_cask_count']} 個已安裝 cask 與 {contract['outdated_cask_count']} 個過期 cask。未保存 App 名稱、路徑或網址。")
        lines.append("- Homebrew 升級參數：" + ("必要參數在 help 中可用。" if upgrade else "缺少必要參數，原生升級入口必須停用。") + "沒有執行 upgrade、update、install 或真實 App 更新。")
        if not contract["installed_record_fields_exercised"] or not contract["outdated_record_fields_exercised"]:
            lines.append("- Runner 沒有涵蓋全部非空記錄類型；空陣列僅驗證 JSON 外層，不能當成實際 App 更新成功。詳細限制見 homebrew-readonly.json。")
else:
    lines.append("- Homebrew：本次沒有唯讀平台探測報告，不宣稱已驗證。")
platform_path = reports / "platform-contracts.json"
if platform_path.exists():
    platform_contract = json.loads(platform_path.read_text())
    if platform_contract.get("mutations_executed") != []:
        raise RuntimeError("Platform probe did not remain read-only")
    outcomes = [f"`{' '.join(command['arguments'])}` → exit {command['exit_code']}" + ("（逾時）" if command['timed_out'] else "") for command in platform_contract["commands"]]
    lines.append("- launchctl 固定唯讀探測：" + "；".join(outcomes) + "。非零退出原樣保存，沒有推定服務存在或把錯誤當成功。")
    lines.append("- 未執行 launchctl 啟用、停用、載入或卸載；未讀取或修改私有 BTM 資料庫。")
else:
    lines.append("- launchctl：本次沒有唯讀格式樣本，不宣稱已驗證。")
lines += ["", "## Fixture 效能取樣", "", "以下使用合成資料，量測 GUI 與 Mock CLI，不代表真實 CLI 大型磁碟成本。CPU 是 ps 的程序平均值，峰值是觀察樣本最大值。", "",
          "| 狀態 | 平均 CPU % | 峰值 CPU % | 平均 RSS MiB | 峰值 RSS MiB |", "|---|---:|---:|---:|---:|"]
for mode in performance["modes"]:
    lines.append(f"| {mode['mode']} | {mode['cpu_mean_percent']:.3f} | {mode['cpu_peak_percent']:.3f} | "
                 f"{mode['rss_mean_bytes']/1048576:.2f} | {mode['rss_peak_bytes']/1048576:.2f} |")
lines += ["", "## 真實官方 CLI 唯讀效能取樣", ""]
if real_performance is None:
    lines.append("本次未執行此項；沒有真實引擎量測值。CI 發行流程要求此證據才能產生正式驗證 ZIP。")
else:
    lines += ["使用已校驗的官方 CLI，明確禁止變更操作。每個模式使用新的隔離 session；scan corpus 為 5,000 個各 4,096 bytes 的平面檔案。重複掃描有溫熱的 OS 檔案系統快取，不代表完整磁碟或清理工作的成本。CLI 子程序採專用 HOME／TMPDIR；沒有改寫 GUI 或工作 shell 的 HOME。", "",
              "取樣涵蓋 GUI 與可觀察子程序，排除偵測、兩秒暖機與關閉時間；scan 僅統計實際官方掃描區間。CPU 為 ps 程序平均值，無法取代 Instruments 的瞬時追蹤。", "",
              "| 狀態 | 平均 CPU % | 觀察峰值 CPU % | 平均 RSS MiB | 觀察峰值 RSS MiB |", "|---|---:|---:|---:|---:|"]
    for mode in real_performance["modes"]:
        lines.append(f"| {mode['mode']} | {mode['cpu_mean_percent']:.3f} | {mode['cpu_peak_percent']:.3f} | "
                     f"{mode['rss_mean_bytes']/1048576:.2f} | {mode['rss_peak_bytes']/1048576:.2f} |")
    identity = real_performance["modes"][0]["app_evidence"]
    lines += ["", f"實測 CLI：`{identity['cli_version']}`，官方來源 `{identity['cli_source_tag']}`／`{identity['cli_source_commit']}`。逐模式 fingerprint、corpus 數量、scan intervals 與原始取樣見 `Reports/performance-real-cli.json`。"]
lines += ["", "## 尚須實機驗收", "",
          "管理員驗證、完整磁碟存取、真實 Homebrew cask、第三方 App 簽章、外接硬碟、完整 VoiceOver 操作，以及 macOS 更新後的行為，仍須使用者在自己的 Mac 上依官方確認逐項驗證。取消已完成的操作不會回復被永久刪除的資料。", ""]
prebuild_report = package / "TEST_REPORT.md"
if prebuild_report.exists():
    (reports / "pre-build-validation-snapshot.md").write_text(prebuild_report.read_text())
final_report = "\n".join(lines)
prebuild_report.write_text(final_report)
source_report = package / "Source/TEST_REPORT.md"
if source_report.exists():
    source_report.write_text(final_report)
