import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: LibraryService
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<MediaItem.ID>()
    @State private var selectionAnchor: MediaItem.ID?

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
                    detail: "完成下載或擷取後，檔案會出現在這裡。"
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
        .onChange(of: library.filter) { _ in
            let visible = Set(library.visibleItems.map(\.id))
            selection.formIntersection(visible)
            if let selectionAnchor, !selection.contains(selectionAnchor) {
                self.selectionAnchor = selection.first
            }
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
    }

    private var header: some View {
        HStack {
            Text("媒體庫")
                .font(FKFont.display(22, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            Spacer()
            if !selection.isEmpty {
                GhostButton(title: "移除所選 \(selection.count) 項") {
                    remove(selection, deleteFile: false)
                }
            }
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

    private func selectAll() {
        selection = Set(library.visibleItems.map(\.id))
        selectionAnchor = library.visibleItems.first?.id
    }

    private func targets(including id: MediaItem.ID) -> [MediaItem] {
        let ids = selection.contains(id) ? selection : [id]
        return library.visibleItems.filter { ids.contains($0.id) }
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
        switch library.filter {
        case .all: return "還沒有媒體"
        case .downloads: return "還沒有下載項目"
        case .captures: return "還沒有擷取項目"
        }
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
