import SwiftUI

enum VipiTheme {
    static let canvas = Color(hex: 0x0B0D12)
    static let surface = Color(hex: 0x12151D)
    static let elevated = Color(hex: 0x191D27)
    static let stroke = Color.white.opacity(0.08)
    static let primary = Color(hex: 0xF3F4F7)
    static let secondary = Color(hex: 0x969CAB)
    static let accent = Color(hex: 0x8B7CFF)
    static let cyan = Color(hex: 0x64D7E8)
    static let success = Color(hex: 0x58D68D)
    static let warning = Color(hex: 0xF7C65F)
    static let danger = Color(hex: 0xFF7272)

    static let cardRadius: CGFloat = 18
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

struct VipiCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(VipiTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: VipiTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VipiTheme.cardRadius, style: .continuous)
                    .stroke(VipiTheme.stroke, lineWidth: 1)
            }
    }
}

extension View {
    func vipiCard() -> some View { modifier(VipiCardModifier()) }
}
