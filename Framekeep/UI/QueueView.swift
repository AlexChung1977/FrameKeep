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
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(queue.jobs) { job in
                            QueueRow(job: job, selected: selection.contains(job.id)) {
                                toggleSelection(job.id)
                            }
                            .contextMenu {
                                Button(selection.contains(job.id) && selection.count > 1
                                       ? "移除所選 \(selection.count) 項"
                                       : "移除", role: .destructive) {
                                    let ids = selection.contains(job.id) ? selection : [job.id]
                                    remove(ids)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
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
                GhostButton(title: "移除所選 \(selection.count) 項", compact: true) {
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

    private func toggleSelection(_ id: DownloadJob.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
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
    var selected: Bool = false
    var onSelect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.title)
                    .font(FKFont.body(13, weight: .semibold))
                    .foregroundStyle(FKColor.paper)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text(job.state.title)
                    .font(FKFont.body(11, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            if let detail = mediaDetail {
                Text(detail)
                    .font(FKFont.body(11))
                    .foregroundStyle(FKColor.paperMuted)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if job.state.canPause {
                    GhostButton(title: "暫停", compact: true) { app.pause(job) }
                }
                if job.state.canResume {
                    GhostButton(title: "繼續", compact: true) { app.resume(job) }
                }
                if job.state.canRetry {
                    GhostButton(title: "重試", compact: true) { app.retry(job) }
                }
                if job.state.canCancel {
                    GhostButton(title: "取消", role: .destructive, compact: true) { app.cancel(job) }
                }
                if job.state == .failed {
                    GhostButton(title: "開啟擷取", compact: true) { app.switchToCapture(from: job) }
                }
                if job.state == .completed, let path = job.outputPath {
                    GhostButton(title: "在 Finder 顯示", compact: true) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? FKColor.amberDim : FKColor.graphiteElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? FKColor.amber.opacity(0.55) : FKColor.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { onSelect?() }
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
