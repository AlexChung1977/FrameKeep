import AppKit
import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var capture: CapturePipeline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            preview
            controlBar
        }
        .background(FKColor.graphite)
        .onAppear {
            Task { await capture.prepareIfPermitted() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await capture.prepareIfPermitted() }
        }
    }

    private var preview: some View {
        ZStack {
            FKColor.graphiteElevated
            if let image = capture.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(FKColor.paperFaint)
                    Text(capture.permission.screenGranted ? "等候預覽…" : "需要螢幕錄製權限才能預覽")
                        .font(FKFont.body(13))
                        .foregroundStyle(FKColor.paperMuted)
                }
            }
            VStack {
                HStack {
                    Text(capture.hint)
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.paper)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Spacer()
                }
                .padding(12)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            if let error = capture.lastError ?? app.banner {
                BannerView(text: error)
            }
            HStack(spacing: 16) {
                if capture.displays.isEmpty {
                    Text("尚未取得顯示器")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.paperMuted)
                        .frame(maxWidth: 280, alignment: .leading)
                } else {
                    Picker("顯示器", selection: Binding(
                        get: { capture.selectedDisplayID ?? capture.displays.first?.id ?? 0 },
                        set: { newValue in
                            Task { await capture.selectDisplay(newValue) }
                        }
                    )) {
                        ForEach(capture.displays) { display in
                            Text(display.label).tag(display.id)
                        }
                    }
                    .frame(maxWidth: 280)
                    .disabled(capture.phase == .recording || capture.phase == .paused || capture.phase == .saving)
                }

                Toggle("系統音訊", isOn: $capture.includeSystemAudio)
                    .toggleStyle(.checkbox)
                Toggle("麥克風", isOn: $capture.includeMicrophone)
                    .toggleStyle(.checkbox)

                audioMeter

                Spacer()

                Text(capture.elapsedLabel)
                    .font(FKFont.display(20, weight: .medium))
                    .foregroundStyle(capture.phase == .recording ? FKColor.amber : FKColor.paper)
                    .monospacedDigit()

                recordButton
                if capture.phase == .recording || capture.phase == .paused {
                    AmberButton(title: capture.phase == .paused ? "繼續" : "暫停", prominent: false) {
                        capture.pauseOrResume()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    AmberButton(title: "停止") {
                        Task { await app.stopCapture() }
                    }
                }

                if !capture.permission.screenGranted {
                    AmberButton(title: "打開系統設定", prominent: false) {
                        Task { await capture.requestPermissions(includingMicrophone: capture.includeMicrophone) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(FKColor.graphiteElevated)
        .overlay(Divider().background(FKColor.line), alignment: .top)
    }

    private var audioMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(FKColor.graphitePanel)
                Capsule()
                    .fill(FKColor.amber)
                    .frame(width: geo.size.width * CGFloat(capture.audioLevel))
            }
        }
        .frame(width: 72, height: 8)
    }

    private var recordButton: some View {
        Button {
            Task { await app.startCapture() }
        } label: {
            ZStack {
                Circle()
                    .fill(FKColor.graphitePanel)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(FKColor.line, lineWidth: 1))
                Circle()
                    .fill(recordFill)
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.08 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(capture.phase == .recording || capture.phase == .saving)
        .keyboardShortcut("r", modifiers: .command)
        .help("開始擷取")
    }

    private var recordFill: Color {
        capture.phase == .recording ? FKColor.danger : FKColor.amber
    }

    private var pulse: Bool {
        !reduceMotion && capture.phase == .recording
    }
}
