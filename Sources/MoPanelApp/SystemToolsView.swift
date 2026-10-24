// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import MoPanelCore

struct SystemToolsView: View {
    @ObservedObject var controller: SystemToolsController
    let language: String
    var operationInProgress = false
    var cliSummary: String?
    @State private var mode: KeepAwakeMode = .displayAndSystem
    @State private var duration: KeepAwakeDuration = .oneHour
    @State private var lightScreen = false
    @State private var pendingEject: EjectableVolume?
    @State private var showEjectConfirmation = false

    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(t("系統工具", "System Tools"), systemImage: "wrench.and.screwdriver").font(.largeTitle.bold())
                    Text(t("MoPanel 新實作 · 透過 macOS 原生 API 執行，不是 Mole CLI 指令。", "MoPanel implementation · Uses native macOS APIs, separate from Mole CLI.")).foregroundStyle(.secondary)
                }
                keepAwake
                cleanScreen
                volumes
                doctor
            }.padding(26)
        }
        .onAppear { controller.language = language }
        .onChange(of: language) { _, value in controller.language = value }
        .confirmationDialog(t("退出這個磁碟？", "Eject this volume?"), isPresented: $showEjectConfirmation, titleVisibility: .visible) {
            if let volume = pendingEject {
                Button(t("退出 ", "Eject ") + volume.name) {
                    guard !operationInProgress else { return }
                    Task { await controller.ejectVolume(volume); pendingEject = nil }
                }.disabled(operationInProgress)
            }
            Button(t("取消", "Cancel"), role: .cancel) { pendingEject = nil }
        } message: {
            Text((pendingEject?.url.path ?? "") + "\n" + t("請先儲存並關閉磁碟上的檔案。退出可能同時卸載同一裝置的其他分割區；使用中的磁碟會由 macOS 拒絕，不會強制退出。", "Save and close files first. Ejection can unmount other partitions on the same device. macOS may refuse a busy device; MoPanel never forces it."))
        }
        .alert(t("系統工具無法完成", "System tool could not finish"), isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button(t("關閉", "Close")) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private var keepAwake: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(t("保持喚醒", "Keep Awake"), systemImage: "sun.max").font(.title3.bold())
                Picker(t("模式", "Mode"), selection: $mode) {
                    Text(t("螢幕與系統", "Display and system")).tag(KeepAwakeMode.displayAndSystem)
                    Text(t("僅系統（螢幕可關閉）", "System only (display may sleep)")).tag(KeepAwakeMode.system)
                }.pickerStyle(.segmented).disabled(controller.hasKeepAwakeSession)
                HStack {
                    Picker(t("時間", "Duration"), selection: $duration) {
                        ForEach(KeepAwakeDuration.allCases, id: \.rawValue) { value in
                            Text(value == .untilStopped ? t("直到手動停止", "Until stopped") : "\(value.rawValue) " + t("小時", "hours")).tag(value)
                        }
                    }.frame(maxWidth: 320).disabled(controller.hasKeepAwakeSession)
                    Spacer()
                    if controller.hasKeepAwakeSession {
                        Button(t("停止", "Stop")) { controller.stopKeepAwake() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(t("開始", "Start")) { controller.startKeepAwake(mode: mode, duration: duration) }.buttonStyle(.borderedProminent)
                            .disabled(!controller.userToolActionsAllowed)
                    }
                }
                if !controller.keepAwakeMessage.isEmpty {
                    Label(controller.keepAwakeMessage, systemImage: controller.assertionIsActive ? "sun.max.fill" : "pause.circle").font(.callout)
                }
                if let end = controller.keepAwakeEndsAt {
                    Text(t("原定結束：", "Ends: ") + end.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(t("20% 以下電量會暫停，接電後在原期限內恢復。睡眠或退出 App 會釋放要求；不修改 pmset，也不承諾關蓋後保持運作。", "Pauses at 20% battery or below and resumes on power within the original time limit. Sleep or app exit releases assertions. No pmset changes or closed-lid override.")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }

    private var cleanScreen: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(t("清潔螢幕", "Clean Screen"), systemImage: "display").font(.title3.bold())
                Text(t("以純色覆蓋目前所有螢幕。按 Esc、點「結束」或切換到其他 App 即可離開，5 分鐘後會自動關閉。", "Covers all current displays with a plain color. Esc, Finish, or switching apps exits; overlays close automatically after 5 minutes."))
                HStack {
                    Toggle(t("白色背景", "White background"), isOn: $lightScreen)
                    Spacer()
                    Button(t("開始清潔螢幕", "Start Clean Screen")) { controller.startCleanScreen(light: lightScreen) }
                        .buttonStyle(.bordered).disabled(controller.isCleaningScreen || !controller.userToolActionsAllowed)
                }
                Text(t("這個模式不鎖住系統鍵盤或滑鼠，不需要輔助使用權限。清潔鍵盤時仍可能觸發快捷鍵；請先儲存工作。", "This mode does not lock system keyboard or mouse input and requires no Accessibility permission. Keyboard shortcuts can still work; save your work first.")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }

    private var volumes: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("退出外接磁碟", "Eject External Volumes"), systemImage: "eject").font(.title3.bold())
                    Spacer()
                    if controller.isRefreshingVolumes { ProgressView().controlSize(.small) }
                    Button(t("重新整理", "Refresh")) { Task { await controller.refreshVolumes() } }
                        .disabled(controller.isRefreshingVolumes || controller.ejectingVolumeID != nil)
                }
                if controller.volumes.isEmpty {
                    Text(controller.volumesLoaded ? t("目前沒有可安全確認退出資格的外接磁碟。", "No external volume currently has confirmed eject eligibility.") : t("按重新整理，讀取目前掛載磁碟；不會掃描內容。", "Refresh to read mounted volume metadata; file contents are not scanned.")).foregroundStyle(.secondary)
                }
                ForEach(controller.volumes) { volume in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(volume.name).font(.headline)
                            Text(volume.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let available = volume.availableBytes, let total = volume.totalBytes {
                                Text(t("可用 ", "Available ") + ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if controller.ejectingVolumeID == volume.id { ProgressView().controlSize(.small) }
                        Button(t("退出…", "Eject…")) { pendingEject = volume; showEjectConfirmation = true }
                            .disabled(operationInProgress || controller.ejectingVolumeID != nil || controller.isRefreshingVolumes)
                    }.padding(.vertical, 5)
                }
                if operationInProgress { Text(t("目前有 Mole 作業執行中，暫停退出磁碟。", "Volume ejection is paused while a Mole operation is running.")).font(.caption).foregroundStyle(.secondary) }
                if !controller.volumeMessage.isEmpty { Text(controller.volumeMessage).font(.caption).foregroundStyle(.secondary) }
                Text(t("不提供啟動磁碟、內建磁碟，或包含目前家目錄與 MoPanel 的磁碟。未能確認的裝置也不提供退出操作。", "Startup/internal volumes and volumes containing your home or MoPanel are protected. Devices with uncertain metadata cannot be ejected here.")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }

    private var doctor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("Doctor 唯讀報告", "Read-only Doctor Report"), systemImage: "stethoscope").font(.title3.bold())
                    Spacer()
                    if controller.isGeneratingDoctor { ProgressView().controlSize(.small) }
                    Button(t("產生報告", "Generate Report")) { Task { await controller.generateDoctorReport(cliSummary: cliSummary) } }.disabled(controller.isGeneratingDoctor)
                }
                Text(t("讀取版本、系統硬體、電源、顯示器及磁碟中繼資料。沒有目錄內容掃描、不讀私人檔案、不執行修復，也不上傳報告。", "Reads version, hardware, power, display and volume metadata. No directory content scan, private-file probe, repair action or upload."))
                if let report = controller.doctorReport {
                    Text(report.generatedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(report.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                LabeledContent(entry.title, value: entry.value)
                                Text(entry.source + " · " + entry.state).font(.caption2).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }.textSelection(.enabled)
                    HStack {
                        Button(t("複製報告", "Copy Report")) { controller.copyDoctorReport() }
                        Button(t("儲存報告…", "Save Report…")) { controller.exportDoctorReport() }
                    }
                } else { Text(t("尚未產生報告。", "No report generated yet.")).foregroundStyle(.secondary) }
            }.padding(12)
        }
    }
}
