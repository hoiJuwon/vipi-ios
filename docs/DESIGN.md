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
- **Functional glass:** one floating composer surface and system-provided toolbar, menu, tab, and transient navigation controls form the functional layer above content. Avoid nested custom Glass surfaces.
- **Atmosphere:** the canvas stays nearly neutral. Ambient gradients are faint, and the transcript remains visually dominant.
- **Identity:** Ice Blue is reserved for the animated progress core and limited state emphasis. User bubbles use a neutral solid surface with white text instead of Liquid Glass or a saturated brand fill.
- **Working state:** progress reads like the next assistant message, never a button or card. Italic activity copy and duration, compact English timing (`42s`, `2m 13s`), and the animated Ice Blue luminous core form one leading-aligned vertical stack. The core visibly travels, stretches, and pulses at 30 fps while its Metal texture evolves; extra breathing room separates it from the duration. Reduce Motion freezes it to a representative frame.
- **Submitted turn:** after a prompt is accepted, its user bubble scrolls to the top of the response viewport with progress directly beneath it, reserving the remaining viewport for the incoming answer.
- **Quoted context:** selecting assistant prose offers `Add to Chat`; the chosen excerpt appears as a compact removable quote annotation above the composer and stays scoped to that session's next prompt.
- **Blocking requests:** permission confirmations, choices, and required text input expand inside the single composer Glass surface instead of creating another card. Only the affirmative action is prominent; denial or cancellation remains monochrome, and prompt entry pauses until the request is resolved. Requests from another session use one standalone Glass surface above the tab bar rather than interrupting with a modal sheet.
- **Launch identity:** cold launch uses the selected dark Liquid Halo artwork, followed by a small lowercase `vipi` wordmark in a monospaced code face and a blinking terminal-style block cursor. The overlay lasts briefly, fades into the app, and freezes its cursor under Reduce Motion.
- **Markdown tables:** GitHub-style pipe tables render as native, selectable cells with a distinct header, aligned numeric columns, wrapped mobile widths for up to three columns, and horizontal scrolling for wider tables.
- **Composer additions:** a plain 44 pt `+` control sits on the same center line as the field and send/stop action. Its system menu exposes only `/goal` and Photo Library. `/goal` is inserted directly into the draft; selected photos appear as removable thumbnails above the field.
- **Controls:** use standard toolbar and button appearances so iOS supplies Liquid Glass, interaction states, and adaptation. Icon controls maintain at least a 44×44 pt hit region.
- **Primary actions:** send and stop use the same deep primary-action surface with a white symbol, keeping their stable composer position and avoiding a semantic color shift after submission.
- **Status color:** color communicates state but never serves as the only indicator. System red is reserved for destructive actions.
- **Motion:** freeze the Liquid Orb to a representative frame when Reduce Motion is enabled.
