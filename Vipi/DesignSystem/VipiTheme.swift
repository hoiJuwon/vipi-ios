import SwiftUI
import UIKit

enum VipiTheme {
    static let canvas = adaptive(light: 0xF4F7FB, dark: 0x070A12)
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.055) : UIColor.black.withAlphaComponent(0.035)
    })
    static let elevated = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.white.withAlphaComponent(0.72)
    })
    static let stroke = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.12)
    })
    static let highlight = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.22) : UIColor.white.withAlphaComponent(0.9)
    })
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let accent = adaptive(light: 0x1677C8, dark: 0x8EEBFF)
    static let accentForeground = adaptive(light: 0xFFFFFF, dark: 0x06131F)
    static let cyan = Color(hex: 0x4F9DFF)
    static let success = Color(hex: 0x58D68D)
    static let warning = Color(hex: 0xF7C65F)
    static let danger = Color(hex: 0xFF7272)

    static let cardRadius: CGFloat = 18

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
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
