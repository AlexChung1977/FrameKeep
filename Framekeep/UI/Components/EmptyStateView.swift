import SwiftUI

struct EmptyStateView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(FKFont.body(15, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            Text(detail)
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .padding(24)
    }
}

struct BannerView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FKFont.body(12))
            .foregroundStyle(FKColor.paper)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FKColor.amberDim)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
