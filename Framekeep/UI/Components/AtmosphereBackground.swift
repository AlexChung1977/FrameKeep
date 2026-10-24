import SwiftUI

struct AtmosphereBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shift: CGFloat = 0

    var body: some View {
        ZStack {
            FKColor.graphite
            RadialGradient(
                colors: [FKColor.amber.opacity(0.18), Color.clear],
                center: UnitPoint(x: 0.72 + (reduceMotion ? 0 : shift), y: 0.22),
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color.white.opacity(0.05), Color.clear],
                center: UnitPoint(x: 0.18, y: 0.78),
                startRadius: 10,
                endRadius: 280
            )
            DotGrid()
                .opacity(0.18)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                    shift = 0.08
                }
            }
        }
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 14
            var x: CGFloat = 8
            while x < size.width {
                var y: CGFloat = 8
                while y < size.height {
                    let rect = CGRect(x: x, y: y, width: 1.1, height: 1.1)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
