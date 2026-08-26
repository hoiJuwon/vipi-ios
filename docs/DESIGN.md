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
- **Atmosphere:** restrained Ice Blue and blue gradients provide color for the glass to sample without competing with text.
- **Identity:** Ice Blue is the primary accent across bubbles, controls, selection, and ambient gradients; use a dark foreground on bright Ice Blue surfaces in dark appearance.
- **Working state:** progress reads like the next assistant message, never a button or card. Italic activity copy, compact English duration (`42s`, `2m 13s`), and the animated Ice Blue luminous core form one leading-aligned vertical stack; the orb shell, material background, and border stay hidden.
- **Submitted turn:** after a prompt is accepted, its user bubble scrolls to the top of the response viewport with progress directly beneath it, reserving the remaining viewport for the incoming answer.
- **Quoted context:** selecting assistant prose offers `Add to Chat`; the chosen excerpt appears as a compact removable quote annotation above the composer and stays scoped to that session's next prompt.
- **Blocking requests:** permission confirmations, choices, and required text input appear in a non-dismissible system sheet with the session name, explicit deny/cancel behavior, and one primary response action.
- **Status color:** color communicates state but never serves as the only indicator.
- **Motion:** freeze the Liquid Orb to a representative frame when Reduce Motion is enabled.
