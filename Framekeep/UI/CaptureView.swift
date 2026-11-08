import AppKit
import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var capture: CapturePipeline
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            preview
            controlBar
        }
        .background(FKColor.graphite)
        .onAppear {
            if case .idle = capture.phase {
                capture.captureHDR = settings.captureHDRByDefault
                capture.preferredCaptureFPS = settings.captureFPSChoice
            }
            clampPreferredFPS()
            Task { await capture.prepareIfPermitted() }
        }
        .onChange(of: capture.captureHDR) { _ in
            clampPreferredFPS()
            settings.captureHDRByDefault = capture.captureHDR
        }
        .onChange(of: capture.preferredCaptureFPS) { newValue in
            settings.captureFPSChoice = newValue
        }
        .onChange(of: capture.selectedDisplayID) { _ in
            clampPreferredFPS()
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

                fpsPicker

                Toggle("系統音訊", isOn: $capture.includeSystemAudio)
                    .toggleStyle(.checkbox)
                    .frame(minHeight: FKTouch.minTarget)
                Toggle("麥克風", isOn: $capture.includeMicrophone)
                    .toggleStyle(.checkbox)
                    .frame(minHeight: FKTouch.minTarget)
                Toggle("HDR", isOn: $capture.captureHDR)
                    .toggleStyle(.checkbox)
                    .help("以 ScreenCaptureKit HDR + HEVC 擷取，適合 PROLED／XDR 螢幕。檔案較大。")
                    .frame(minHeight: FKTouch.minTarget)
                    .disabled(capture.phase == .recording || capture.phase == .paused || capture.phase == .saving)

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

    private var fpsPicker: some View {
        let displayHz = capture.selectedDisplay?.refreshRateHz ?? 0
        let captureFPS = isActivelyCapturing ? capture.activeCaptureFPS : capture.plannedCaptureFPS
        return HStack(spacing: 8) {
            if displayHz > 0 {
                Text("螢幕 \(displayHz)Hz")
                    .font(FKFont.body(12, weight: .medium))
                    .foregroundStyle(FKColor.paperMuted)
                    .monospacedDigit()
            }
            Picker("幀率", selection: $capture.preferredCaptureFPS) {
                ForEach(capture.availableCaptureFPSChoices) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .labelsHidden()
            .frame(minWidth: 88)
            .disabled(isActivelyCapturing)
            Text(isActivelyCapturing ? "擷取 \(captureFPS)fps" : "→ \(captureFPS)fps")
                .font(FKFont.body(12, weight: .medium))
                .foregroundStyle(FKColor.amber)
                .monospacedDigit()
                .help("可自訂擷取幀率。不會超過螢幕原生更新率；未開 HDR 時最高 60fps。")
        }
        .frame(minHeight: FKTouch.minTarget)
    }

    private var isActivelyCapturing: Bool {
        switch capture.phase {
        case .recording, .paused, .saving: return true
        default: return false
        }
    }

    private func clampPreferredFPS() {
        let allowed = capture.availableCaptureFPSChoices
        if !allowed.contains(capture.preferredCaptureFPS) {
            capture.preferredCaptureFPS = .auto
        }
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
                    .frame(width: FKTouch.minTarget, height: FKTouch.minTarget)
                    .overlay(Circle().stroke(FKColor.line, lineWidth: 1))
                Circle()
                    .fill(recordFill)
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.08 : 1)
            }
            .contentShape(Circle())
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
