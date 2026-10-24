import SwiftUI
import AppKit
import MoPanelCore

struct UninstallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected = Set<String>()
    @State private var search = ""
    @State private var sort = "name"
    @State private var withData = false
    @State private var permanent = false
    @State private var debug = false
    private var rows: [InstalledApp] {
        let filtered = model.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
        return filtered.sorted {
            if sort == "size", sizeValue($0.size) != sizeValue($1.size) { return sizeValue($0.size) > sizeValue($1.size) }
            if sort == "source", $0.source != $1.source { return $0.source < $1.source }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: model.t("讓卸載範圍清清楚楚", "Know what an uninstall will remove"), subtitle: model.t("App 清單來自 mo uninstall --list。殘留與個人資料的歸屬由 Mole 判斷。", "Inventory comes from mo uninstall --list. Mole determines ownership of related files and personal data."), symbol: "square.grid.2x2")
            HStack {
                TextField(model.t("搜尋 App、Bundle ID 或路徑", "Search app, bundle ID or path"), text: $search).textFieldStyle(.roundedBorder)
                Picker(model.t("排序", "Sort"), selection: $sort) {
                    Text(model.t("名稱", "Name")).tag("name")
                    Text(model.t("容量（官方顯示值）", "Size (display estimate)")).tag("size")
                    Text(model.t("來源", "Source")).tag("source")
                }.frame(width: 210)
                Button(model.t("掃描／重新整理", "Scan / Refresh")) { Task { await model.loadApps() } }.disabled(!model.canStart)
                    .accessibilityIdentifier("mopanel.uninstall.scan")
            }
            if model.apps.isEmpty {
                ContentUnavailableView(model.t("尚無 App 清單", "No App Inventory"), systemImage: "app.dashed", description: Text(model.t("按「掃描」取得官方清單；無權限或掃描失敗會顯示錯誤。", "Scan to retrieve the official inventory. Permission or scan failures appear explicitly.")))
            } else {
                List(selection: $selected) {
                    ForEach(rows) { app in
                        HStack(spacing: 14) {
                            AppIcon(path: app.path)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.headline)
                                Text(app.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(app.path)
                                Text(app.bundleID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(app.size).font(.callout.monospacedDigit())
                                Text(app.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4).tag(app.id)
                            .contextMenu { Button(model.t("在 Finder 顯示", "Show in Finder")) { model.reveal(app.path) } }
                    }
                }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("\(rows.count) " + model.t("個 App；選取 ", "apps; selected ") + "\(selected.count)").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(model.t("預選個人資料（--with-data；預設關閉）", "Preselect personal data (--with-data; off by default)"), isOn: $withData)
                    Toggle(model.t("詳細診斷（--debug）", "Detailed diagnostics (--debug)"), isOn: $debug)
                    DisclosureGroup(model.t("進階刪除方式", "Advanced Removal Mode")) {
                        Toggle(model.t("永久刪除，不放入垃圾桶（--permanent）", "Delete permanently, bypassing Trash (--permanent)"), isOn: $permanent)
                    }
                    Text(model.t("同名 App、無法唯一對應的 Homebrew 名稱或特殊檔名，請使用「官方選取器」。確認畫面的實際路徑才是最終移除範圍。", "For duplicate app names, ambiguous cask aliases or special filenames, use the official selector. Actual paths in its final review determine the removal scope."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            HStack {
                Button(model.t("預覽選取項目", "Preview Selected")) { Task { await model.uninstall(selected: selected, preview: true, withData: withData, permanent: permanent, debug: debug) } }
                    .buttonStyle(.borderedProminent).disabled(selected.isEmpty || !model.canStart)
                Button(model.t("確認卸載…", "Review Uninstall…")) { Task { await model.uninstall(selected: selected, preview: false, withData: withData, permanent: permanent, debug: debug) } }.disabled(selected.isEmpty || !model.canStart)
                Spacer()
                Button(model.t("官方選取器／預覽", "Official Selector / Preview")) { model.request(.uninstall, options: [.dryRun] + (debug ? [.debug] : []) + (withData ? [.withData] : []) + (permanent ? [.permanent] : [])) }.disabled(!model.canStart)
                Button(model.t("官方選取器／卸載", "Official Selector / Uninstall")) { model.request(.uninstall, options: (debug ? [.debug] : []) + (withData ? [.withData] : []) + (permanent ? [.permanent] : [])) }.disabled(!model.canStart)
                Button(model.t("說明", "Help")) { model.request(.uninstall, options: [.help]) }.disabled(!model.canStart)
            }
        }.padding(26)
    }
    // Sorting aid only; sizes remain the untouched human string in every row.
    private func sizeValue(_ text: String) -> Double {
        let compact = text.uppercased().replacingOccurrences(of: " ", with: "")
        let numeric = compact.prefix { "0123456789.".contains($0) }
        guard let number = Double(numeric) else { return -1 }
        for (unit, multiplier) in [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)] where compact.contains(unit) { return number * multiplier }
        return number
    }
}

private struct AppIcon: View {
    let path: String
    @State private var icon: NSImage?
    private static let cache = NSCache<NSString, NSImage>()
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "app").resizable().foregroundStyle(.secondary) }
        }.frame(width: 40, height: 40).accessibilityHidden(true)
            .task(id: path) {
                if let cached = Self.cache.object(forKey: path as NSString) { icon = cached }
                else {
                    Self.cache.countLimit = 128
                    let image = NSWorkspace.shared.icon(forFile: path)
                    Self.cache.setObject(image, forKey: path as NSString); icon = image
                }
            }
    }
}
