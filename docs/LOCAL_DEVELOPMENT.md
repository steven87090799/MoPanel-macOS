# 本機開發環境

此專案使用 Apple Silicon、macOS 27、完整 Xcode 27+、Metal Toolchain、Python 3.15。Xcode 包含 Swift、XCTest、LLDB、Instruments、Accessibility Inspector 與 macOS SDK；只安裝 Command Line Tools 無法完成本專案的全部 UI 與效能驗收。

`Brewfile` 記錄命令列工具與 Xcode 的 App Store ID。Python 用於驗證與封裝，GitHub CLI 用於 PR／Actions，ShellCheck 用於 shell 審查，ripgrep 用於原始碼搜尋；Go 供獨立上游 Mole 原始碼的測試。App 執行本身不需要 Python、Go 或 Homebrew。Mole CLI 仍由使用者獨立管理。

## 重建環境

```sh
brew bundle install --no-upgrade --file Brewfile
/opt/homebrew/bin/python3.15 -m venv .venv
```

App Store 安裝可能需要本人登入 Apple 帳號或在 macOS 視窗授權。首次開啟 Xcode，閱讀並確認 Apple 的 Xcode／SDK 授權條款，再完成必要元件設定並選擇 macOS 開發環境；本專案不需要其他平台的 Simulator。條款尚未接受時，Apple 的命令列工具也可能暫時拒絕執行。再依 [Apple 文件](https://developer.apple.com/documentation/Xcode/downloading-and-installing-additional-xcode-components)安裝 Metal Toolchain：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

## 使用專案環境

`dev-run.sh` 只替該次命令選擇 Homebrew、專案虛擬環境與完整 Xcode，不修改使用者的 shell 設定。若 Xcode 在其他位置，可明確設定 `DEVELOPER_DIR`。

```sh
bash scripts/dev-run.sh bash scripts/doctor-environment.sh
bash scripts/dev-run.sh swift package resolve
bash scripts/dev-run.sh bash scripts/test-core.sh
bash scripts/dev-run.sh bash scripts/build.sh
```

完整建置包含測試、fixture UI、短時間效能記錄、簽章及封裝。長時觀察另見 `PRODUCT_READINESS_AUDIT.md`。不要將工具安裝、單一 target 建置或 CI 的結果當成本機完整驗收。

`.venv`、SwiftPM `.build`、`build/reports` 與安裝日誌不提交到 Git。套件的真實 revision 由 `Package.resolved` 固定。工具版本可用 doctor 與各工具的 version 指令確認。
