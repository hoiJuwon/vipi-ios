# Vipi design direction

## Liquid Glass

Vipi follows Apple's Liquid Glass guidance for iOS 26 while retaining a material fallback on iOS 18–25.

Official references:

- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [`glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- [`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)

## Rules

1. Treat glass as a functional layer for navigation and controls, not as decoration on every content surface.
2. Prefer standard `TabView`, navigation bars, sheets, menus, search, and controls so the OS supplies its current appearance and accessibility behavior.
3. Remove opaque custom backgrounds from navigation and input controls where they interfere with system effects.
4. Use `glassEffect` sparingly for the composer, high-value status controls, and primary actions.
5. Use `Glass.interactive()` only on controls that actually respond to input.
6. Keep transcript and session content legible on restrained material cards rather than stacking glass effects.
7. Preserve an iOS 18–25 fallback with system materials.
8. Test Reduce Transparency, Increase Contrast, Reduce Motion, light/dark appearance, Dynamic Type, and VoiceOver.

## Visual hierarchy

- **Content:** transcript and session data remain visually dominant.
- **Functional glass:** composer, compact context/status layer, and toolbar actions float above content.
- **Atmosphere:** restrained accent/cyan gradients provide color for the glass to sample without competing with text.
- **Status color:** color communicates state but never serves as the only indicator.
