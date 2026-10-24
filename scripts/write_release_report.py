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
validation_gates = json.loads((reports / "validation-gates.json").read_text())
if (validation_gates.get("schema_version") != 1
        or set(validation_gates.get("required_gates", [])) != {"swift-test", "fixture-smoke"}
        or set(validation_gates.get("gates", {})) != {"swift-test", "fixture-smoke"}
        or validation_gates.get("all_required_passed") is not True
        or any(gate.get("passed") is not True or gate.get("pipeline_exit_code") != 0
               or gate.get("command_exit_code") != 0 or gate.get("tee_exit_code") != 0
               for gate in validation_gates["gates"].values())):
    raise RuntimeError("Both independent XCTest/fixture-UI gates must have complete successful evidence")
gate_harness_log = (reports / "validation-gate-harness.log").read_text()
gate_harness_count = re.search(r"Ran (\d+) tests? in", gate_harness_log)
if (not gate_harness_count or not re.search(r"^OK\s*$", gate_harness_log, re.MULTILINE)
        or re.search(r"^(FAILED|ERROR:)", gate_harness_log, re.MULTILINE)):
    raise RuntimeError("Independent validation gate harness did not finish without failures/skips")
smoke_driver_log = (reports / "smoke-driver-tests.log").read_text()
smoke_driver_count = re.search(r"Ran (\d+) tests? in", smoke_driver_log)
if (not smoke_driver_count or not re.search(r"^OK\s*$", smoke_driver_log, re.MULTILINE)
        or re.search(r"^(FAILED|ERROR:)", smoke_driver_log, re.MULTILINE)):
    raise RuntimeError("Smoke diagnostic driver tests did not finish without failures/skips")
crash_evidence_log = (reports / "crash-evidence-tests.log").read_text()
crash_evidence_count = re.search(r"Ran (\d+) tests? in", crash_evidence_log)
if (not crash_evidence_count or not re.search(r"^OK\s*$", crash_evidence_log, re.MULTILINE)
        or re.search(r"^(FAILED|ERROR:)", crash_evidence_log, re.MULTILINE)):
    raise RuntimeError("Own-process crash evidence tests did not finish without failures/skips")
debug_guard_log = (reports / "debug-diagnostic-tests.log").read_text()
debug_guard_count = re.search(r"Ran (\d+) tests? in", debug_guard_log)
if (not debug_guard_count or not re.search(r"^OK\s*$", debug_guard_log, re.MULTILINE)
        or re.search(r"^(FAILED|ERROR:)", debug_guard_log, re.MULTILINE)):
    raise RuntimeError("Disposable-debug-copy safety tests did not finish without failures/skips")
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
git_suite_counts = {}
test_lines = test_log.splitlines()
for index, line in enumerate(test_lines[:-1]):
    suite = re.search(r"Test Suite '([^']+\.xctest)' passed", line)
    count = re.search(r"Executed (\d+) tests?, with", test_lines[index + 1])
    if suite and count:
        bundle_test_counts[suite.group(1)] = int(count.group(1))
    git_suite = re.search(r"Test Suite '(GitWorktreeIntegrationTests|GitWorktreeParserTests)' passed", line)
    if git_suite and count and int(count.group(1)) > 0:
        git_suite_counts[git_suite.group(1)] = int(count.group(1))
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
         f"| 獨立驗收 gate harness | {gate_harness_count.group(1)} 個隔離Bash管線案例通過；Swift／smoke／tee非零與skip皆不能進後續phase。見 validation-gate-harness.log |",
         f"| Smoke 診斷 driver | {smoke_driver_count.group(1)} 個隔離案例通過；進度輸出保留、逾時不被診斷錯誤掩蓋、只取樣存活的自身子程序。sampler權限情境使用mock。見 smoke-driver-tests.log |",
         f"| 自身 crash report 辨識 | {crash_evidence_count.group(1)} 個合成案例通過；僅本次 MoPanel PID／時間／名稱符合才保存，拒絕舊報告、其他程式與symlink。見 crash-evidence-tests.log |",
         f"| 隔離 debug 診斷 guards | {debug_guard_count.group(1)} 個合成／mock案例通過；診斷不能將失敗變成功，正式bundle不允許get-task-allow。見 debug-diagnostic-tests.log |",
         "| XCTest／fixture UI gate | 兩者分別保存command、tee與pipeline退出碼，全部為0且無略過；見 validation-gates.json |",
         f"| Swift 編譯與單元測試 | 合計 {total_swift_tests} 個 XCTest，{skips} skipped，0 failures；多個 .xctest bundle 分別加總。見 swift-test.log |",
         f"| Guardian 程序整合測試 | {guardian_count.group(1)} 個案例通過，0 failures／skipped。見 guardian-test.log |",
         "| ARM64 | 主程式、guardian 與原生 paths 編輯器均通過 lipo 檢查，只有 arm64 |",
         "| App Bundle | Info.plist、主程式、helper、圖示與必要資源存在 |",
         "| Code Signing | ad-hoc 簽章與 codesign strict/deep 完整性驗證通過；正式主程式及helpers皆無get-task-allow除錯entitlement |",
         "| Apple 公證 | 未進行；沒有宣稱 Developer ID 身分 |",
         "| UI 啟動 | 原生 App 視窗已建立，fixture-only smoke test 通過 |",
         "| 真實個人資料操作 | 未執行清理、卸載、最佳化或瘦身 |",
         "| UI 完整互動驗收 | Smoke test 不能代表每個按鈕、VoiceOver 與實機權限流程都已驗證 |",
         "| ZIP | 建置流程在封裝後解壓並驗證 manifest、結構與簽章；最終結果見外部 zip-verification.txt |",
         "", "## 原生 UI 與安全系統 API 測試", ""]
checks = smoke.get("checks", {})
lines.append(f"- 本次 smoke 有 {sum(value is True for value in checks.values())}／{len(checks)} 項檢查通過；逐項布林結果見 smoke-test.json。")
if checks.get("navigation_routes_selected_with_window_alive") is True:
    lines.append(f"- 已依序選取 {len(smoke.get('navigation_sections_selected', []))} 個路由且視窗保持存活；這只能驗證路由切換存活，不證明每個頁面都完整或正確渲染。")
native_ui = smoke.get("native_ui", {})
if native_ui.get("passed") is True:
    actions = native_ui.get("actions", [])
    identifiers = {action.get("identifier") for action in actions}
    lines.append(f"- 透過自身行程的公開 AppKit accessibility 介面，對 {len(identifiers)} 種明確識別的控制項執行 {len(actions)} 次按壓並驗證效果；沒有以直接呼叫 action 方法替代按壓。導覽準備仍使用 model state，不能稱為完整人工操作或所有按鈕的端到端驗收。")
else:
    lines.append("- 本次沒有通過自身行程的 accessibility 按鈕驗收；不宣稱已測試實際控制項按壓。")
if checks.get("native_assertion_created_and_released") is True:
    lines.append("- IOPM 防休眠 assertion 已實際建立、讀取、釋放並確認不存在。")
if checks.get("native_clean_screen_windows_constructed_and_closed") is True:
    lines.append("- 螢幕清潔 overlay 視窗已建立與關閉；測試未呈現全螢幕遮罩、攔截輸入或退出磁碟。")
if checks.get("startup_mock_enable_disable_readback") is True:
    lines.append("- Startup 的啟用／停用／回讀、取消與不明格式流程使用私有 mock 驗證；零真實 launchctl 變更或常駐 job。")
lines += ["- 上述測試沒有要求外部 Accessibility／TCC 權限或注入實體輸入，也不代表真實清理、App 升級或硬體控制已驗證。", ""]
if git_suite_counts:
    lines += ["## Git worktree 隔離驗證", "",
              "以下數量取自本次 swift-test.log 的實際 passed suite 與其緊接的 XCTest summary；已包含在前述 XCTest 總數，不另行相加。", ""]
    parser_count = git_suite_counts.get("GitWorktreeParserTests")
    integration_count = git_suite_counts.get("GitWorktreeIntegrationTests")
    if parser_count:
        lines.append(f"- GitWorktreeParserTests：{parser_count} 個案例通過，驗證 NUL 記錄解析與保護政策。")
    if integration_count:
        lines.append(f"- GitWorktreeIntegrationTests：{integration_count} 個案例通過；使用真 Git 與每個測試新建的私有暫存倉庫，驗證保護檢查、保留分支、移除／恢復、內容保留及失敗拒絕。沒有操作使用者的既有倉庫。")
    else:
        lines.append("- 本次沒有可核對的 GitWorktreeIntegrationTests passed summary，不宣稱已執行真 Git 整合驗證。")
    lines += ["- 這些測試不等同 Git 頁面的完整 UI、AI session 格式、第三方工具整合或任意外部程序同時寫入情況的驗收。", ""]
lines += ["## CLI 相容性實測", ""]
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
    homebrew_test_log = (reports / "homebrew-audit-tests.log").read_text()
    homebrew_test_count = re.search(r"Ran (\d+) tests? in", homebrew_test_log)
    if not homebrew_test_count or not re.search(r"^OK\s*$", homebrew_test_log, re.MULTILINE) or re.search(r"^(FAILED|ERROR:)", homebrew_test_log, re.MULTILINE):
        raise RuntimeError("Homebrew audit harness did not finish without failures/skips")
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
        if homebrew.get("caskroom_contract", {}).get("installed_recipe_files_audited") is False:
            lines.append("- caskroom 位置介面已探測，但沒有讀取 runner 的舊安裝 recipe／receipt；這些安全拒絕條件由隔離 Swift fixture 驗證，不能視為真實舊 App 升級驗收。")
    lines.append(f"- Homebrew audit harness：{homebrew_test_count.group(1)} 個隔離案例通過，0 failures／skipped。")
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
lines += ["", "## Fixture 效能取樣", "", "以下使用合成資料，量測 GUI 與 Mock CLI，不代表真實 CLI 大型磁碟成本。CPU 是 ps 的程序存活期平均值，峰值是觀察樣本最大值。", "",
          "兩組效能表的 RSS 都將 GUI 與觀察到的子程序相加，共用頁面可能被重複計算；不是唯一實體記憶體占用，也不等同活動監視器的記憶體壓力。", "",
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

# These are distribution copies. Preserve development snapshots and feature
# gaps verbatim, while making this artifact's current evidence easy to find.
for relative_path, prefix in [
        ("COMPATIBILITY.md", ""),
        ("Source/COMPATIBILITY.md", "../"),
        ("Source/docs/GUI_PARITY.md", "../../"),
        ("Source/docs/MOPANEL_ADDITIONS.md", "../../")]:
    document = package / relative_path
    if document.exists():
        original = document.read_text()
        note = ("<!-- MOPANEL_GENERATED_RELEASE_NOTE -->\n"
                "## 本發行產物的驗證註記（自動產生）\n\n"
                f"產生時間：{date}。本份產物的當次驗證以 [TEST_REPORT.md]({prefix}TEST_REPORT.md) "
                f"與 [Reports/]({prefix}Reports/) 的實際紀錄為準。\n\n"
                "下文保留開發時的相容性基準、功能缺口與進度快照；舊 run 的失敗或待驗證狀態是歷史紀錄，"
                "不代表本份產物的最新測試結果。這不解除既有功能限制、相容性邊界或尚未驗證的真實資料、權限與硬體事項，"
                "也不表示全部 UI 或官方付費功能已驗收。\n\n"
                "<!-- END_MOPANEL_GENERATED_RELEASE_NOTE -->\n\n")
        document.write_text(note + original)
