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
2. Prefer standard navigation bars, sheets, menus, search, and controls so the OS supplies its current appearance and accessibility behavior.
3. Remove opaque custom backgrounds from navigation and input controls where they interfere with system effects.
4. Use `glassEffect` sparingly for the composer, high-value status controls, and primary actions.
5. Use `Glass.interactive()` only on controls that actually respond to input.
6. Keep transcript and session content legible on restrained material cards rather than stacking glass effects.
7. Preserve an iOS 18–25 fallback with system materials.
8. Test Reduce Transparency, Increase Contrast, Reduce Motion, light/dark appearance, Dynamic Type, and VoiceOver.

## Visual hierarchy

- **Content:** transcript and session data remain visually dominant.
- **Functional glass:** one floating composer surface and system-provided toolbar, menu, and transient navigation controls form the functional layer above content. Avoid nested custom Glass surfaces.
- **Atmosphere:** the canvas stays nearly neutral. Ambient gradients are faint, and the transcript remains visually dominant.
- **Identity:** everyday interface chrome is monochrome. Brand blue is reserved for the app icon, launch artwork, and animated progress core; user bubbles remain neutral solid surfaces with white text.
- **Working state:** progress reads like the next assistant message, never a button or card. Italic activity copy and duration, compact English timing (`42s`, `2m 13s`), and the animated Ice Blue luminous core form one leading-aligned vertical stack. A restrained highlight travels back and forth through the activity title, while the enlarged compact core travels, stretches, and pulses on a slower 2.4-second cycle as its Metal texture evolves. Extra breathing room separates it from the duration. Reduce Motion lowers displacement amplitude without making the live state appear static.
- **Submitted turn:** after a prompt is accepted, its user bubble scrolls to the top of the response viewport with progress directly beneath it, reserving the remaining viewport for the incoming answer.
- **Quoted context:** selecting assistant prose offers `Add to Chat`; the chosen excerpt appears as a compact removable quote annotation above the composer and stays scoped to that session's next prompt.
- **Blocking requests:** permission confirmations, choices, and required text input expand inside the single composer Glass surface instead of creating another card. Only the affirmative action is prominent; denial or cancellation remains monochrome, and prompt entry pauses until the request is resolved. Requests from another session use one standalone Glass surface above the active screen rather than interrupting with a modal sheet.
- **Launch identity:** cold launch uses the selected dark Liquid Halo artwork, then types the small lowercase `vipi` wordmark in a monospaced code face before briefly blinking its terminal-style block cursor. The entire interaction stays within the short launch overlay and fades into the app, including when system motion reduction is enabled.
- **Markdown tables:** GitHub-style pipe tables render as native, selectable cells with a distinct header, aligned numeric columns, wrapped mobile widths for up to three columns, and horizontal scrolling for wider tables.
- **Composer layout:** prompt text occupies a full-width first row so typing starts near the leading edge without a dead gap. A second 44 pt control row keeps `+` at the leading edge and send/stop at the trailing edge. The `+` menu exposes only `/goal` and Photo Library; selected photos appear above the field. Before any sendable content exists, the trailing action stays a neutral outlined surface rather than appearing as an active black button.
- **Session list:** the transcript index follows the compact Messages hierarchy without avatars: centered title, connection state at the leading edge, Settings at the trailing edge, text-first rows with time and chevron, and a small monochrome unread dot. Search and new-session actions share a floating bottom Glass dock; Settings is navigation, not a persistent footer tab.
- **New sessions:** the session-list toolbar exposes one native `+` action. Its sheet presents registered workspaces first for quick reuse, then a remote Mac folder browser with one persistent monochrome “Start in …” action. Files, tmux coordinates, and terminal controls remain hidden.
- **Notifications:** Settings exposes one contextual opt-in for answer alerts. Notification content is deliberately private—a session name and generic completion sentence only—and tapping an alert opens that session. The system permission prompt is never shown automatically at cold launch.
- **Controls:** use standard toolbar and button appearances so iOS supplies Liquid Glass, interaction states, and adaptation. Icon controls maintain at least a 44×44 pt hit region.
- **Primary actions:** send and stop use the same high-contrast monochrome treatment—black with a white symbol in light appearance, white with a black symbol in dark appearance—so state changes do not introduce a new hue.
- **Status color:** reserve color for semantic warning, success, unread, and destructive states, and never use color as the only indicator.
- **Motion:** reduce Liquid Orb displacement amplitude under Reduce Motion without making the working indicator appear static.
