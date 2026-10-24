import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: LibraryService
    @Environment(\.openWindow) private var openWindow

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
                            LibraryCard(item: item) {
                                app.trimTarget = item
                                openWindow(id: "trim")
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(FKColor.graphite)
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
    var onTrim: () -> Void
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
        .task(id: item.filePath) {
            let ffmpegPath = app.settings.ffmpegPath
            guard let data = await VideoThumbnail.jpeg(for: item, ffmpegPath: ffmpegPath) else { return }
            thumbnail = NSImage(data: data)
        }
        .onTapGesture(count: 2) {
            library.open(item)
        }
        .contextMenu {
            Button("用預設程式播放") { library.open(item) }
            Button("在 Finder 顯示") { library.reveal(item) }
            Button("重新命名…") {
                app.renameText = item.title
                app.renameTarget = item
            }
            Button("剪接…") { onTrim() }
            Divider()
            Button("從媒體庫移除", role: .destructive) {
                try? library.delete(item, deleteFile: false)
            }
            Button("刪除檔案", role: .destructive) {
                try? library.delete(item, deleteFile: true)
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
