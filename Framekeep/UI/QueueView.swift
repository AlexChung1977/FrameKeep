import AppKit
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var queue: DownloadQueueService
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = Set<DownloadJob.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if queue.jobs.isEmpty {
                Spacer()
                EmptyStateView(title: "佇列是空的", detail: "貼上連結後，下載會出現在這裡。")
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(queue.jobs) { job in
                        QueueRow(job: job)
                            .tag(job.id)
                            .listRowBackground(FKColor.graphiteElevated)
                            .listRowSeparatorTint(FKColor.line)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
                .contextMenu(forSelectionType: DownloadJob.ID.self) { ids in
                    Button(ids.count > 1 ? "移除所選 \(ids.count) 項" : "移除", role: .destructive) {
                        remove(ids)
                    }
                    .disabled(ids.isEmpty)
                } primaryAction: { _ in }
                .onDeleteCommand {
                    remove(selection)
                }
            }
        }
        .background(FKColor.graphite)
    }

    private var header: some View {
        HStack {
            Text("佇列")
                .font(FKFont.display(22, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            Spacer()
            if !selection.isEmpty {
                GhostButton(title: "移除所選 \(selection.count) 項") {
                    remove(selection)
                }
            }
            Text("並行 \(settings.concurrency)")
                .font(FKFont.body(11))
                .foregroundStyle(FKColor.paperFaint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func remove(_ ids: Set<DownloadJob.ID>) {
        guard !ids.isEmpty else { return }
        selection.subtract(ids)
        app.removeFromQueue(ids)
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var app: AppState
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.title)
                    .font(FKFont.body(13, weight: .semibold))
                    .foregroundStyle(FKColor.paper)
                    .lineLimit(1)
                Spacer()
                Text(job.state.title)
                    .font(FKFont.body(11, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            if let detail = mediaDetail {
                Text(detail)
                    .font(FKFont.body(11))
                    .foregroundStyle(FKColor.paperMuted)
            }
            if job.state == .downloading || job.state == .remuxing || job.state == .paused {
                ProgressView(value: job.progress)
                    .tint(FKColor.amber)
                HStack {
                    Text(job.speed ?? "")
                    Spacer()
                    Text(job.eta.map { "剩餘 \($0)" } ?? "\(job.progressPercent)%")
                }
                .font(FKFont.body(11))
                .foregroundStyle(FKColor.paperFaint)
            }
            if job.state == .failed {
                Text(job.humanFailure)
                    .font(FKFont.body(12))
                    .foregroundStyle(FKColor.danger)
            }
            HStack(spacing: 12) {
                if job.state.canPause {
                    GhostButton(title: "暫停") { app.pause(job) }
                }
                if job.state.canResume {
                    GhostButton(title: "繼續") { app.resume(job) }
                }
                if job.state.canRetry {
                    GhostButton(title: "重試") { app.retry(job) }
                }
                if job.state.canCancel {
                    GhostButton(title: "取消", role: .destructive) { app.cancel(job) }
                }
                if job.state == .failed {
                    GhostButton(title: "開啟擷取") { app.switchToCapture(from: job) }
                }
                if job.state == .completed, let path = job.outputPath {
                    GhostButton(title: "在 Finder 顯示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .task(id: job.outputPath) {
            await app.queue.refreshFileDetail(job)
        }
    }

    private var mediaDetail: String? {
        job.formatLabel
    }

    private var statusColor: Color {
        switch job.state {
        case .failed: return FKColor.danger
        case .completed: return FKColor.success
        case .downloading, .remuxing: return FKColor.amber
        default: return FKColor.paperMuted
        }
    }
}
