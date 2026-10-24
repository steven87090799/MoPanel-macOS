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
        let filtered = model.apps.filter { app in !model.uninstallReview.removedPaths.contains(app.path) && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.path.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search)) }
        return filtered.sorted {
            if sort == "size", sizeValue($0.size) != sizeValue($1.size) { return sizeValue($0.size) > sizeValue($1.size) }
            if sort == "source", $0.source != $1.source { return $0.source < $1.source }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeading(title: model.t("卸載 App", "Uninstall Apps"), subtitle: model.t("選擇 App，勾選要一起移除的檔案；未勾選的資料會保留。", "Select apps and related files to remove. Unchecked data stays in place."), symbol: "square.grid.2x2")
                HStack {
                    TextField(model.t("搜尋 App、Bundle ID 或路徑", "Search app, bundle ID or path"), text: $search).textFieldStyle(.roundedBorder)
                    Picker(model.t("排序", "Sort"), selection: $sort) {
                        Text(model.t("名稱", "Name")).tag("name")
                        Text(model.t("容量（官方顯示值）", "Size (display estimate)")).tag("size")
                        Text(model.t("來源", "Source")).tag("source")
                    }.frame(width: 210)
                    NativeActionButton(model.t("掃描／重新整理", "Scan / Refresh"), identifier: "mopanel.uninstall.scan") {
                        Task { await model.loadApps(); model.uninstallReview.reconcileInventory(); await model.uninstallReview.prepareApps(model.apps.filter { selected.contains($0.id) && !model.uninstallReview.removedPaths.contains($0.path) }, force: true) }
                    }.disabled(!model.canStart)
                }
                if model.apps.isEmpty {
                    ContentUnavailableView(model.t("尚無 App 清單", "No App Inventory"), systemImage: "app.dashed", description: Text(model.t("按「掃描」取得官方清單；無權限或掃描失敗會顯示錯誤。", "Scan to retrieve the official inventory. Permission or scan failures appear explicitly.")))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(rows) { app in
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle(isOn: Binding(get: { selected.contains(app.id) }, set: { value in
                                        if value { selected.insert(app.id) } else { selected.remove(app.id) }
                                    })) {
                                        HStack(spacing: 12) {
                                            AppIcon(path: app.path)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(app.name).font(.headline)
                                                Text(app.source).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(app.size).font(.callout.monospacedDigit())
                                        }
                                    }.toggleStyle(.checkbox).disabled(model.hasRunningOperation)
                                    if selected.contains(app.id) {
                                        if model.uninstallReview.appsNeedingQuit.contains(app.path) {
                                            Button(model.t("先結束此 App", "Quit This App First")) { Task { await model.uninstallReview.requestQuit(app.path) } }.disabled(model.hasRunningOperation)
                                        }
                                        FileReviewView(controller: model.uninstallReview, language: model.language, operationInProgress: model.hasRunningOperation, categoryFilter: app.path, showsActions: false)
                                    }
                                }.padding(12)
                                    .background(.primary.opacity(selected.contains(app.id) ? 0.055 : 0.015), in: RoundedRectangle(cornerRadius: 14))
                                    .contextMenu { Button(model.t("在 Finder 顯示", "Show in Finder")) { model.reveal(app.path) } }
                            }
                        }
                    }.frame(height: min(max(CGFloat(rows.count) * 64 + CGFloat(selected.intersection(Set(rows.map(\.id))).count) * 240, 260), 500))
                    Text("\(rows.count) " + model.t("個 App；選取 ", "apps; selected ") + "\(selected.intersection(Set(rows.map(\.id))).count)").font(.caption).foregroundStyle(.secondary)
                }
                if !selected.isEmpty || !model.uninstallReview.message.isEmpty { FileReviewView(controller: model.uninstallReview, language: model.language, operationInProgress: model.hasRunningOperation, showsCategories: selected.intersection(Set(rows.map(\.id))).isEmpty) }
                DisclosureGroup(model.t("進階與官方完整模式", "Advanced and Full CLI Mode")) {
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
                }
            }.padding(26)
        }.onAppear { selected = model.uninstallSelected }
        .onChange(of: selected) { _, ids in
            model.uninstallSelected = ids
            Task { await model.uninstallReview.prepareApps(model.apps.filter { ids.contains($0.id) && !model.uninstallReview.removedPaths.contains($0.path) }) }
        }
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

struct AppIcon: View {
    let path: String
    var size: CGFloat = 40
    @State private var icon: NSImage?
    private static let cache = NSCache<NSString, NSImage>()
    static func clearCache() { cache.removeAllObjects() }
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "app").resizable().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: path) {
                if let cached = Self.cache.object(forKey: path as NSString) { icon = cached }
                else {
                    Self.cache.countLimit = 128
                    Self.cache.totalCostLimit = 6 * 1024 * 1024
                    // Workspace icons can retain every large representation. Keep
                    // only a 96-pixel bitmap for the 26/40-point UI instead.
                    let source = NSWorkspace.shared.icon(forFile: path)
                    let image = NSImage(size: NSSize(width: 48, height: 48))
                    if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                       let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                        source.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
                        NSGraphicsContext.restoreGraphicsState()
                        bitmap.size = image.size; image.addRepresentation(bitmap)
                    }
                    Self.cache.setObject(image, forKey: path as NSString, cost: 96 * 96 * 4); icon = image
                }
            }
    }
}
