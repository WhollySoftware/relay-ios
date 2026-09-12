import SwiftUI

/// Colours and shapes for every RelayUI/RelayCall view. Override any of them and inject with
/// `.relayTheme(...)`; defaults follow the system palette (RelayUI) / today's call-screen chrome
/// (RelayCall) so both kits look native untouched. Lives in RelayCore (rather than RelayUI) so
/// RelayCall — which doesn't depend on RelayUI — can read it too.
public struct RelayTheme: Sendable {
    public var accent: Color = .accentColor
    public var bubbleMine: Color = .accentColor
    public var bubbleMineText: Color = .white
    public var bubbleTheirs: Color = Color.gray.opacity(0.18)
    public var bubbleTheirsText: Color = .primary
    public var secondaryText: Color = .secondary
    public var online: Color = .green
    public var danger: Color = .red
    public var cornerRadius: CGFloat = 18
    public var avatarSize: CGFloat = 44

    /// Foreground for content drawn on an accent-tinted surface — e.g. the icon inside a
    /// `danger`/`online` call-control circle (hang up, answer, decline).
    public var accentForeground: Color = .white
    /// Full-screen call background (`RelayCallView`/`GroupCallView`'s black backdrop).
    public var callScrimStart: Color = .black
    /// Secondary call surface — video tiles and the local preview box.
    public var callScrimEnd: Color = Color(white: 0.14)
    /// Saturation for a per-user fallback-avatar background (hue is computed per key).
    public var avatarSaturation: Double = 0.45
    /// Brightness for a per-user fallback-avatar background (hue is computed per key).
    public var avatarLightness: Double = 0.92

    /// Custom font family name (as registered with the system, e.g. via an Info.plist-bundled
    /// font) applied as the default `Text` font at each major entry view. `nil` (the default)
    /// leaves every view's own explicit `.font(...)` calls — the vast majority of text in
    /// RelayUI/RelayCall — and the system default untouched. Only `Text` that does *not* set its
    /// own `.font()` picks this up; see `View.relayTypography(_:)` for the partial-coverage
    /// caveat.
    public var fontFamily: String? = nil
    /// Overall text-size multiplier, applied at each major entry view by mapping to the nearest
    /// `DynamicTypeSize` case (see `RelayTheme.nearestDynamicTypeSize(for:)`). `1.0` (the default)
    /// is "today's behavior": no override is applied at all, so the system's own Dynamic Type
    /// accessibility setting keeps flowing through exactly as it does today.
    public var fontScale: Double = 1.0

    public init() {}

    /// Best-effort mapping from an arbitrary `fontScale` multiplier (`1.0` == `.large`, the
    /// system default) to the nearest `DynamicTypeSize` case, using Apple's published
    /// approximate relative type-size ratios. Exposed for callers who want to drive
    /// `dynamicTypeSize` themselves instead of going through `relayTypography(_:)`.
    public static func nearestDynamicTypeSize(for scale: Double) -> DynamicTypeSize {
        let table: [(DynamicTypeSize, Double)] = [
            (.xSmall, 0.82), (.small, 0.88), (.medium, 0.95), (.large, 1.0),
            (.xLarge, 1.12), (.xxLarge, 1.23), (.xxxLarge, 1.35),
            (.accessibility1, 1.64), (.accessibility2, 1.95), (.accessibility3, 2.35),
            (.accessibility4, 2.76), (.accessibility5, 3.12),
        ]
        return table.min(by: { abs($0.1 - scale) < abs($1.1 - scale) })!.0
    }
}

private struct RelayThemeKey: EnvironmentKey {
    static let defaultValue = RelayTheme()
}

public extension EnvironmentValues {
    var relayTheme: RelayTheme {
        get { self[RelayThemeKey.self] }
        set { self[RelayThemeKey.self] = newValue }
    }
}

public extension View {
    func relayTheme(_ theme: RelayTheme) -> some View { environment(\.relayTheme, theme) }

    /// Applies `theme.fontScale`/`theme.fontFamily` to this view's subtree. Call once at each
    /// major entry view (`RelayChatView`, `ConversationListView`, `MessageThreadView`,
    /// `RelayCallOverlay`, `IncomingCallBanner`) as the *last* modifier in the chain — after any
    /// `.sheet`/`.navigationDestination` — so the override reaches presented sheets and pushed
    /// destinations too, not just directly-nested children. Calling it more than once (e.g. it's
    /// also applied inside a view reached through one of those entry points) is harmless: the
    /// same value is simply re-applied.
    ///
    /// Neither environment key is touched when the theme hasn't customized it — an untouched
    /// `RelayTheme()` (`fontScale == 1.0`, `fontFamily == nil`) leaves `dynamicTypeSize`/`font`
    /// exactly as SwiftUI's system Dynamic Type and default font would already render them, so a
    /// host that doesn't opt in sees pixel-identical output to before this API existed.
    ///
    /// Coverage caveat: `fontFamily` only affects `Text` views that don't already set their own
    /// `.font(...)` — most call sites in RelayUI/RelayCall use explicit semantic styles like
    /// `.font(.headline)` and are unaffected by design (see `RelayTheme.fontFamily`'s doc);
    /// `fontScale` has no such gap since `dynamicTypeSize` scales every semantic font.
    func relayTypography(_ theme: RelayTheme) -> some View {
        modifier(RelayTypographyModifier(theme: theme))
    }
}

private struct RelayTypographyModifier: ViewModifier {
    let theme: RelayTheme
    func body(content: Content) -> some View {
        content
            .modifier(OptionalDynamicTypeSize(size: theme.fontScale == 1.0 ? nil : RelayTheme.nearestDynamicTypeSize(for: theme.fontScale)))
            .modifier(OptionalCustomFont(family: theme.fontFamily))
    }
}

private struct OptionalDynamicTypeSize: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        if let size { content.environment(\.dynamicTypeSize, size) } else { content }
    }
}

private struct OptionalCustomFont: ViewModifier {
    let family: String?
    func body(content: Content) -> some View {
        if let family { content.environment(\.font, .custom(family, size: 17)) } else { content }
    }
}
