import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: LibraryService
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<MediaItem.ID>()
    @State private var selectionAnchor: MediaItem.ID?
    @State private var moveTargets: [MediaItem] = []

    private let columns = [
        GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if library.visibleItems.isEmpty {
                Spacer()
                EmptyStateView(
                    title: emptyTitle,
                    detail: emptyDetail
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(library.visibleItems) { item in
                            LibraryCard(
                                item: item,
                                isSelected: selection.contains(item.id)
                            ) {
                                select(item.id)
                            } onOpen: {
                                library.open(item)
                            } onTrim: {
                                app.trimTarget = item
                                openWindow(id: "trim")
                            } onRemove: { items, deleteFile in
                                remove(Set(items.map(\.id)), deleteFile: deleteFile)
                            } onMove: { items in
                                moveTargets = items
                            } targets: {
                                targets(including: item.id)
                            }
                        }
                    }
                    .padding(20)
                }
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = []
                            selectionAnchor = nil
                        }
                }
            }
        }
        .background(FKColor.graphite)
        .onChange(of: library.items.map(\.id)) { ids in
            selection.formIntersection(Set(ids))
            if let selectionAnchor, !selection.contains(selectionAnchor) {
                self.selectionAnchor = selection.first
            }
        }
        .onChange(of: library.filter) { _ in
            keepFormatFilterValid()
            trimSelectionToVisible()
        }
        .onChange(of: library.formatFilter) { _ in
            trimSelectionToVisible()
        }
        .onChange(of: library.availableFormats) { _ in
            keepFormatFilterValid()
        }
        .background {
            VStack {
                Button(action: selectAll) {}
                    .keyboardShortcut("a", modifiers: .command)
                Button(action: { remove(selection, deleteFile: false) }) {}
                    .keyboardShortcut(.delete)
            }
            .buttonStyle(.plain)
            .disabled(app.renameTarget != nil)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(item: $app.renameTarget) { item in
            RenameSheet(item: item)
                .environmentObject(app)
                .environmentObject(library)
        }
        .sheet(isPresented: Binding(
            get: { !moveTargets.isEmpty },
            set: { if !$0 { moveTargets = [] } }
        )) {
            MoveLibrarySheet(items: moveTargets) {
                moveTargets = []
            }
            .environmentObject(app)
            .environmentObject(library)
        }
    }

    private var header: some View {
        HStack {
            Text("媒體庫")
                .font(FKFont.display(22, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            Spacer()
            if !selection.isEmpty {
                GhostButton(title: "移動所選 \(selection.count) 項") {
                    beginMove(selection)
                }
                GhostButton(title: "移除所選 \(selection.count) 項") {
                    remove(selection, deleteFile: false)
                }
            }
            Picker("格式", selection: $library.formatFilter) {
                Text("全部格式").tag("")
                ForEach(library.availableFormats, id: \.self) { format in
                    Text(format).tag(format)
                }
            }
            .frame(width: 120)
            Picker("", selection: $library.filter) {
                ForEach(LibraryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func select(_ id: MediaItem.ID) {
        let flags = NSEvent.modifierFlags
        let items = library.visibleItems
        if flags.contains(.shift),
           let anchor = selectionAnchor,
           let start = items.firstIndex(where: { $0.id == anchor }),
           let end = items.firstIndex(where: { $0.id == id }) {
            let range = items[min(start, end)...max(start, end)].map(\.id)
            if flags.contains(.command) {
                selection.formUnion(range)
            } else {
                selection = Set(range)
            }
            return
        }
        if flags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            selectionAnchor = id
            return
        }
        selection = [id]
        selectionAnchor = id
    }

    private func trimSelectionToVisible() {
        let visible = Set(library.visibleItems.map(\.id))
        selection.formIntersection(visible)
        if let selectionAnchor, !selection.contains(selectionAnchor) {
            self.selectionAnchor = selection.first
        }
    }

    private func keepFormatFilterValid() {
        guard !library.formatFilter.isEmpty else { return }
        if !library.availableFormats.contains(library.formatFilter) {
            library.formatFilter = ""
        }
    }

    private func selectAll() {
        selection = Set(library.visibleItems.map(\.id))
        selectionAnchor = library.visibleItems.first?.id
    }

    private func targets(including id: MediaItem.ID) -> [MediaItem] {
        let ids = selection.contains(id) ? selection : [id]
        return library.visibleItems.filter { ids.contains($0.id) }
    }

    private func beginMove(_ ids: Set<MediaItem.ID>) {
        let targets = library.visibleItems.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        moveTargets = targets
    }

    private func remove(_ ids: Set<MediaItem.ID>, deleteFile: Bool) {
        let targets = library.visibleItems.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        try? library.delete(targets, deleteFile: deleteFile)
        selection.subtract(ids)
        if let selectionAnchor, !selection.contains(selectionAnchor) {
            self.selectionAnchor = selection.first
        }
    }

    private var emptyTitle: String {
        if !library.itemsMatchingKind.isEmpty {
            return "沒有 \(library.formatFilter) 檔案"
        }
        switch library.filter {
        case .all: return "還沒有媒體"
        case .downloads: return "還沒有下載項目"
        case .captures: return "還沒有擷取項目"
        }
    }

    private var emptyDetail: String {
        library.itemsMatchingKind.isEmpty
            ? "完成下載或擷取後，檔案會出現在這裡。"
            : "改選其他格式，或選回全部格式。"
    }
}

private struct LibraryCard: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: LibraryService
    let item: MediaItem
    var isSelected: Bool
    var onSelect: () -> Void
    var onOpen: () -> Void
    var onTrim: () -> Void
    var onRemove: ([MediaItem], Bool) -> Void
    var onMove: ([MediaItem]) -> Void
    var targets: () -> [MediaItem]
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .background {
                    ZStack {
                        FKColor.graphitePanel
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: item.kind == .capture ? "record.circle" : "film")
                                .font(.system(size: 22))
                                .foregroundStyle(FKColor.amber)
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if !item.durationLabel.isEmpty {
                        Text(item.durationLabel)
                            .font(FKFont.body(10, weight: .medium))
                            .foregroundStyle(FKColor.paper)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.fileFormat)
                .font(FKFont.body(10, weight: .medium))
                .foregroundStyle(FKColor.amber)
            Text(item.title)
                .font(FKFont.body(12, weight: .medium))
                .foregroundStyle(FKColor.paper)
                .lineLimit(2)
            Text("\(item.kind.title)  ·  \(item.host ?? "")")
                .font(FKFont.body(10))
                .foregroundStyle(FKColor.paperFaint)
        }
        .padding(8)
        .fkCard(corner: 10)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? FKColor.amber : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .task(id: item.filePath) {
            let ffmpegPath = app.settings.ffmpegPath
            guard let data = await VideoThumbnail.jpeg(for: item, ffmpegPath: ffmpegPath) else { return }
            thumbnail = NSImage(data: data)
        }
        .contextMenu {
            let chosen = targets()
            let count = chosen.count
            Button(count > 1 ? "播放所選 \(count) 項" : "用預設程式播放") {
                library.open(chosen)
            }
            Button(count > 1 ? "在 Finder 顯示所選" : "在 Finder 顯示") {
                library.reveal(chosen)
            }
            if count == 1 {
                Button("重新命名…") {
                    app.renameText = item.title
                    app.renameTarget = item
                }
                Button("剪接…") { onTrim() }
            }
            Button(count > 1 ? "移動所選 \(count) 項…" : "移動到…") {
                onMove(chosen)
            }
            Divider()
            Button(count > 1 ? "從媒體庫移除所選 \(count) 項" : "從媒體庫移除", role: .destructive) {
                onRemove(chosen, false)
            }
            Button(count > 1 ? "刪除所選 \(count) 個檔案" : "刪除檔案", role: .destructive) {
                onRemove(chosen, true)
            }
        }
    }
}

private struct RenameSheet: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: LibraryService
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重新命名")
                .font(FKFont.display(16, weight: .semibold))
            TextField("名稱", text: $app.renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { app.renameTarget = nil }
                Button("儲存") {
                    try? library.rename(item, to: app.renameText)
                    app.renameTarget = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct MoveLibrarySheet: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var settings: AppSettings
    let items: [MediaItem]
    var onClose: () -> Void
    @State private var notice: String?
    @State private var progress: LibraryMoveProgress?
    @State private var moving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(moving ? "正在移動" : "移動 \(items.count) 個檔案")
                .font(FKFont.display(16, weight: .semibold))
            Text("最多 \(AppSettings.folderFavoriteLimit) 組最愛。也可以這次另外選一個資料夾。")
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
            if settings.folderFavorites.isEmpty {
                Text("還沒有最愛目錄。")
                    .font(FKFont.body(12))
                    .foregroundStyle(FKColor.paperFaint)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(settings.folderFavorites) { favorite in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(favorite.name)
                                        .font(FKFont.body(13, weight: .medium))
                                        .foregroundStyle(FKColor.paper)
                                        .lineLimit(1)
                                    Text(favorite.path)
                                        .font(FKFont.body(10))
                                        .foregroundStyle(FKColor.paperFaint)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                GhostButton(title: "移除") {
                                    settings.removeFolderFavorite(favorite.id)
                                }
                                AmberButton(title: "移動", enabled: !moving, prominent: false) {
                                    move(to: favorite.url)
                                }
                            }
                            .padding(10)
                            .fkCard(corner: 8)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(progress.index) / \(progress.total)　\(progress.title)")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.paper)
                        .lineLimit(1)
                    ProgressView(value: progress.fraction)
                        .tint(FKColor.amber)
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                        .font(FKFont.body(11))
                        .foregroundStyle(FKColor.paperMuted)
                        .monospacedDigit()
                }
            }
            if let notice {
                Text(notice)
                    .font(FKFont.body(12))
                    .foregroundStyle(FKColor.danger)
            }
            HStack {
                AmberButton(title: "加入最愛…", enabled: !moving && settings.folderFavorites.count < AppSettings.folderFavoriteLimit, prominent: false) {
                    addFavorite()
                }
                AmberButton(title: "選擇其他資料夾…", enabled: !moving, prominent: false) {
                    chooseAndMove()
                }
                Spacer()
                Button("完成") { onClose() }
                    .disabled(moving)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(FKColor.graphite)
        .foregroundStyle(FKColor.paper)
        .interactiveDismissDisabled(moving)
    }

    private func addFavorite() {
        guard let url = pickDirectory(prompt: "加入最愛", message: "選擇要記住的資料夾。") else { return }
        notice = settings.addFolderFavorite(url)
    }

    private func chooseAndMove() {
        guard let url = pickDirectory(prompt: "移動", message: "選擇這次要移入的資料夾。") else { return }
        move(to: url)
    }

    private func move(to directory: URL) {
        guard !moving else { return }
        moving = true
        progress = LibraryMoveProgress(index: 1, total: items.count, title: items.first?.title ?? "", fraction: 0)
        Task {
            let message = await library.move(items, to: directory) { update in
                progress = update
            }
            app.banner = message
            moving = false
            onClose()
        }
    }

    private func pickDirectory(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.message = message
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
