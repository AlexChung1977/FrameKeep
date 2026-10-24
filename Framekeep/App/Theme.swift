import AppKit
import SwiftUI

enum FKColor {
    static let graphite = Color(red: 26 / 255, green: 28 / 255, blue: 30 / 255)
    static let graphiteElevated = Color(red: 36 / 255, green: 38 / 255, blue: 41 / 255)
    static let graphitePanel = Color(red: 44 / 255, green: 46 / 255, blue: 49 / 255)
    static let line = Color.white.opacity(0.08)
    static let paper = Color(red: 0.96, green: 0.96, blue: 0.94)
    static let paperMuted = Color.white.opacity(0.58)
    static let paperFaint = Color.white.opacity(0.34)
    static let amber = Color(red: 224 / 255, green: 168 / 255, blue: 74 / 255)
    static let amberPressed = Color(red: 196 / 255, green: 140 / 255, blue: 48 / 255)
    static let amberDim = Color(red: 224 / 255, green: 168 / 255, blue: 74 / 255).opacity(0.16)
    static let danger = Color(red: 0.86, green: 0.33, blue: 0.28)
    static let success = Color(red: 0.45, green: 0.72, blue: 0.48)
}

enum FKFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "Familjen Grotesk", size: size) != nil {
            return .custom("Familjen Grotesk", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "Noto Sans TC", size: size) != nil {
            return .custom("Noto Sans TC", size: size).weight(weight)
        }
        if NSFont(name: "Source Han Sans TC", size: size) != nil {
            return .custom("Source Han Sans TC", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }
}

extension View {
    func fkCard(corner: CGFloat = 10) -> some View {
        background(FKColor.graphiteElevated)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(FKColor.line, lineWidth: 1)
            )
    }
}
