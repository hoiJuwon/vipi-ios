import SwiftUI

enum VipiTheme {
    static let canvas = Color(hex: 0x070A12)
    static let surface = Color.white.opacity(0.055)
    static let elevated = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.12)
    static let highlight = Color.white.opacity(0.22)
    static let primary = Color(hex: 0xF7F8FC)
    static let secondary = Color(hex: 0xA8AFC0)
    static let accent = Color(hex: 0x9B8CFF)
    static let cyan = Color(hex: 0x61D9F0)
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

struct VipiBackdrop: View {
    var body: some View {
        ZStack {
            VipiTheme.canvas
            RadialGradient(
                colors: [VipiTheme.accent.opacity(0.22), .clear],
                center: UnitPoint(x: 0.82, y: 0.08),
                startRadius: 8,
                endRadius: 330
            )
            RadialGradient(
                colors: [VipiTheme.cyan.opacity(0.12), .clear],
                center: UnitPoint(x: 0.05, y: 0.7),
                startRadius: 10,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
}

struct VipiCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: VipiTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VipiTheme.cardRadius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [VipiTheme.highlight, VipiTheme.stroke], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75
                    )
            }
    }
}

struct VipiGlassModifier<S: Shape>: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(VipiTheme.stroke, lineWidth: 0.75) }
        }
    }
}

extension View {
    func vipiCard() -> some View { modifier(VipiCardModifier()) }

    func vipiGlass<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        modifier(VipiGlassModifier(tint: tint, interactive: interactive, shape: shape))
    }
}
