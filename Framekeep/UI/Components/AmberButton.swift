import SwiftUI

struct AmberButton: View {
    let title: String
    var enabled: Bool = true
    var prominent: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FKFont.body(13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(prominent ? (enabled ? FKColor.amber : FKColor.amber.opacity(0.35)) : Color.clear)
                .foregroundStyle(prominent ? FKColor.graphite : FKColor.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(prominent ? Color.clear : FKColor.line, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct GhostButton: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(FKFont.body(12, weight: .medium))
                .foregroundStyle(role == .destructive ? FKColor.danger : FKColor.paperMuted)
        }
        .buttonStyle(.plain)
    }
}
