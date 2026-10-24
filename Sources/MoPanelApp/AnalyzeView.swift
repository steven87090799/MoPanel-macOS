import SwiftUI
import MoPanelCore

struct AnalyzeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var showOnlyFolders = false
    @State private var sortBySize = true
    var entries: [AnalyzeEntry] {
        (model.analysis?.entries ?? []).filter {
            (!showOnlyFolders || $0.isDir) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search))
        }.sorted { a, b in
            if sortBySize { return (a.measuredBytes ?? -1) > (b.measuredBytes ?? -1) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeading(title: model.t("空間用在哪裡", "See where space goes"), subtitle: model.t("資料來自 mo analyze --json；未知容量與部分掃描會明確保留。", "Uses mo analyze --json. Unknown sizes and partial scans remain explicit."), symbol: "chart.pie")
                HStack {
                    NativeActionButton(model.t("掃描總覽", "Scan Overview"), identifier: "mopanel.analyze.overview") {
                        Task { await model.analyze(path: nil) }
                    }
                    Button(model.t("選擇資料夾／外接磁碟…", "Choose Folder / External Drive…")) { model.chooseFolder { url in Task { await model.analyze(path: url.path) } } }.buttonStyle(.borderedProminent)
                    if let scan = model.analysis {
                        NativeActionButton(model.t("重新掃描", "Rescan"), identifier: "mopanel.analyze.rescan") {
                            Task { await model.analyze(path: scan.overview ? nil : scan.path) }
                        }
                        if !scan.overview, scan.path != "/" {
                            NativeActionButton(model.t("上一層", "Parent"), identifier: "mopanel.analyze.parent", systemImage: "arrow.up") {
                                Task { await model.analyze(path: URL(fileURLWithPath: scan.path).deletingLastPathComponent().path) }
                            }
                        }
                    }
                    Spacer()
                }.disabled(!model.canStart)
                if let scan = model.analysis {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(scan.overview ? model.t("官方概覽", "Official Overview") : scan.path).font(.headline).textSelection(.enabled)
                            Text(stateText(scan.scanStatus)).font(.callout).foregroundStyle(scan.scanStatus == .complete ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(sizeText(scan.measuredTotalBytes, state: scan.scanStatus)).font(.title2.monospacedDigit())
                            if let count = scan.totalFiles { Text("\(count) " + model.t("個已計數檔案", "counted files")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if scan.scanStatus != .complete {
                        Notice(text: model.t("部分掃描的數字是實際量到的下限；無法取得的大小不是 0。官方 JSON 不提供每項詳細失敗原因，請查看原始輸出或確認讀取權限。", "Partial sizes are measured lower bounds. An unavailable size is not zero. Per-item error reasons are not present in the JSON; inspect output or check read permissions."), warning: true)
                    }
                    let measured = Array(entries.filter { ($0.measuredBytes ?? 0) > 0 }.sorted { left, right in
                        let leftSize = left.measuredBytes ?? 0, rightSize = right.measuredBytes ?? 0
                        if leftSize != rightSize { return leftSize > rightSize }
                        if left.path != right.path { return left.path < right.path }
                        return left.name < right.name
                    }.prefix(30))
                    if !measured.isEmpty {
                        Treemap(entries: measured) { entry in
                            if entry.isDir { Task { await model.analyze(path: entry.path) } } else { model.reveal(entry.path) }
                        }.frame(height: 300).disabled(!model.canStart)
                        Text(model.t("色塊表示篩選後最大 30 個可測量項目的相對大小。點資料夾可向下掃描；點檔案可在 Finder 顯示。", "Tiles show relative sizes of the largest 30 measured filtered entries. Click a folder to scan deeper or a file to reveal it in Finder."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField(model.t("搜尋名稱或路徑", "Search name or path"), text: $search).textFieldStyle(.roundedBorder)
                        Toggle(model.t("僅資料夾", "Folders only"), isOn: $showOnlyFolders).toggleStyle(.checkbox)
                        Toggle(model.t("容量排序", "Sort by size"), isOn: $sortBySize).toggleStyle(.checkbox)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDir ? "folder" : "doc").foregroundStyle(entry.isDir ? Color.teal : Color.secondary)
                                Button {
                                    if entry.isDir { Task { await model.analyze(path: entry.path) } } else { model.reveal(entry.path) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.name).foregroundStyle(.primary)
                                        Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).disabled(!model.canStart)
                                Text(sizeText(entry.measuredBytes, state: entry.scanStatus)).font(.callout.monospacedDigit())
                                if entry.scanStatus != .complete { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(stateText(entry.scanStatus)) }
                                Button { model.reveal(entry.path) } label: { Image(systemName: "folder.badge.questionmark") }.help(model.t("在 Finder 顯示", "Show in Finder"))
                            }.padding(.vertical, 11).padding(.horizontal, 8)
                                .contextMenu {
                                    Button(model.t("在 Finder 顯示", "Show in Finder")) { model.reveal(entry.path) }
                                    Button(model.t("開啟官方介面以移至垃圾桶…", "Open Official Interface to Move to Trash…")) {
                                        let path = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
                                        model.request(.analyze, options: [.analyzePath(path)], title: model.t("官方檔案選取與垃圾桶操作", "Official File Selection and Trash"))
                                    }.disabled(!model.canStart)
                                }
                            Divider()
                        }
                    }
                    if entries.isEmpty { ContentUnavailableView.search(text: search) }
                    if !scan.largeFiles.isEmpty {
                        DisclosureGroup(model.t("大型檔案", "Large Files")) {
                            LazyVStack(spacing: 10) {
                                ForEach(scan.largeFiles.sorted { $0.size > $1.size }) { file in
                                    HStack { Text(file.path).font(.caption).lineLimit(1); Spacer(); Text(DisplayFormat.bytes(file.size)); Button(model.t("Finder", "Finder")) { model.reveal(file.path) } }
                                }
                            }.padding(10)
                        }
                    }
                    HStack {
                        Button(model.t("以官方互動介面瀏覽／移至垃圾桶", "Browse / Move to Trash in Mole")) {
                            model.request(.analyze, options: scan.overview ? [] : [.analyzePath(scan.path)])
                        }.disabled(!model.canStart)
                        Spacer()
                    }
                    Notice(text: model.t("垃圾桶操作保留官方 Mole 的路徑驗證與確認。MoPanel 不會根據圖表自行刪除檔案，也不會將 GUI 選取轉成猜測的選單編號。", "Trash operations retain Mole's path validation and confirmation. MoPanel never deletes from chart data or converts a GUI selection to a guessed menu index."))
                } else { ContentUnavailableView(model.t("選擇要分析的位置", "Choose a Location"), systemImage: "externaldrive", description: Text(model.t("不會自動掃描整個磁碟。你可以選擇家目錄、資料夾或外接磁碟。", "Choose an overview, folder or external volume to begin a read-only scan."))) }
            }.padding(26)
        }
    }
    private func stateText(_ state: ScanState) -> String {
        switch state {
        case .complete: return model.t("complete · 已完成（依官方排除規則）", "complete · Finished within Mole's exclusion rules")
        case .partial: return model.t("partial · 部分掃描", "partial · Incomplete scan")
        case .unavailable: return model.t("unavailable · 無法取得", "unavailable · Could not measure")
        }
    }
    private func sizeText(_ size: Int64?, state: ScanState) -> String {
        guard let size else { return model.t("未知容量", "Unknown size") }
        return DisplayFormat.bytes(size) + (state == .partial ? "+" : "")
    }
}

private struct TreemapTile: Identifiable {
    let entry: AnalyzeEntry
    let rect: CGRect
    let color: Int
    var id: String { entry.id }
}
private struct Treemap: View {
    let entries: [AnalyzeEntry]
    let select: (AnalyzeEntry) -> Void
    private let colors: [Color] = [.teal, .blue, .indigo, .cyan, .mint]
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(tiles(entries, rect: CGRect(origin: .zero, size: geometry.size))) { tile in
                    Button { select(tile.entry) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if tile.rect.width > 70 && tile.rect.height > 38 {
                                Text(tile.entry.name).font(.caption.weight(.semibold)).lineLimit(2)
                                if tile.rect.height > 60 { Text(DisplayFormat.bytes(tile.entry.measuredBytes) + (tile.entry.scanStatus == .partial ? "+" : "")).font(.caption2) }
                            }
                        }.foregroundStyle(.white).padding(8).frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3), alignment: .topLeading)
                            .background(colors[tile.color % colors.count].gradient, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).position(x: tile.rect.midX, y: tile.rect.midY)
                        .accessibilityLabel(tile.entry.name + " " + DisplayFormat.bytes(tile.entry.measuredBytes))
                        .help(tile.entry.path + " · " + DisplayFormat.bytes(tile.entry.measuredBytes))
                }
            }
        }
    }
    private func tiles(_ values: [AnalyzeEntry], rect: CGRect, offset: Int = 0) -> [TreemapTile] {
        guard !values.isEmpty else { return [] }
        if values.count == 1 { return [TreemapTile(entry: values[0], rect: rect, color: offset)] }
        let total = values.reduce(0.0) { $0 + Double(max(0, $1.size)) }
        guard total > 0 else { return [] }
        var sum = 0.0, split = 1
        for index in 0..<(values.count - 1) {
            sum += Double(max(0, values[index].size)); split = index + 1
            if sum >= total / 2 { break }
        }
        let fraction = sum / total
        var first = rect, second = rect
        if rect.width > rect.height {
            first.size.width = rect.width * fraction
            second.origin.x = rect.minX + first.width; second.size.width = rect.width - first.width
        } else {
            first.size.height = rect.height * fraction
            second.origin.y = rect.minY + first.height; second.size.height = rect.height - first.height
        }
        return tiles(Array(values.prefix(split)), rect: first, offset: offset) + tiles(Array(values.dropFirst(split)), rect: second, offset: offset + split)
    }
}
