import SwiftUI

struct QualityPickerView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var queue: DownloadQueueService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let probe = app.activeProbe {
                VStack(alignment: .leading, spacing: 4) {
                    Text(probe.title)
                        .font(FKFont.display(20, weight: .semibold))
                        .foregroundStyle(FKColor.paper)
                        .lineLimit(2)
                    Text("\(probe.sourceHost)  ·  \(probe.durationLabel)")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.paperMuted)
                }

                Picker("用途", selection: $app.pickerPreset) {
                    ForEach(DefaultFormatPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: app.pickerPreset) { preset in
                    let next = probe.recommendedFormat(for: preset)
                    DispatchQueue.main.async {
                        app.pickerCustom = next
                    }
                }

                Text(app.pickerPreset.subtitle)
                    .font(FKFont.body(12))
                    .foregroundStyle(FKColor.paperMuted)

                if app.pickerPreset == .custom {
                    if probe.formats.isEmpty {
                        EmptyStateView(title: "沒有可選格式", detail: "解析結果沒有列出格式。可以改用擷取。")
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(probe.formats) { format in
                                    Button {
                                        app.pickerCustom = format
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(format.label)
                                                    .foregroundStyle(FKColor.paper)
                                                Text(format.codecLabel)
                                                    .font(FKFont.body(11))
                                                    .foregroundStyle(FKColor.paperMuted)
                                            }
                                            Spacer()
                                            if let size = format.sizeLabel {
                                                Text(size)
                                                    .font(FKFont.body(11))
                                                    .foregroundStyle(FKColor.paperFaint)
                                            }
                                        }
                                        .padding(8)
                                        .background(app.pickerCustom?.id == format.id ? FKColor.amberDim : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(minHeight: 180, maxHeight: 240)
                    }
                } else if let pick = app.pickerCustom {
                    Text("將使用：\(pick.selectionLabel)")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.amber)
                }

                if probe.requiresCookie {
                    Text("此內容可能需要 cookie。請只匯入你自己匯出的 cookies.txt。")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.amber)
                }

                HStack {
                    AmberButton(title: "加入佇列") {
                        app.enqueueCurrentPick()
                    }
                    AmberButton(title: "改用擷取", prominent: false) {
                        app.switchToCaptureFromPicker()
                    }
                    Spacer()
                    GhostButton(title: "取消") {
                        if let id = app.activeJobID, let job = queue.jobs.first(where: { $0.id == id }) {
                            app.cancel(job)
                        }
                        app.showingPicker = false
                    }
                }
            } else {
                EmptyStateView(title: "尚無解析結果", detail: "請回到首頁貼上連結。")
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 320)
        .background(FKColor.graphite)
    }
}
