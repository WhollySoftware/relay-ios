import SwiftUI
@_exported import RelayCore

/// Colours and shapes for every RelayUI view. Override any of them and inject with
/// `.relayTheme(...)`; defaults follow the system palette so the kit looks native untouched.
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

    public init() {}
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
}

// MARK: - Formatting helpers (shared by the views; also usable by hosts that bring their own UI)

public enum RelayFormat {
    /// Compact relative age for list rows: "now", "5m", "3h", "2d", or a short date.
    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded()))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d yyyy")
        return f.string(from: date)
    }

    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Today", "Yesterday", weekday, or a short date — for day separators.
    public static func day(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    public static func lastSeen(online: Bool?, lastSeenAt: Date?) -> String {
        if online == true { return "Online" }
        guard let lastSeenAt else { return "Offline" }
        let rel = relative(lastSeenAt)
        return rel == "now" ? "Last seen just now" : "Last seen \(rel)\(rel.last.map { "mhd".contains($0) } == true ? " ago" : "")"
    }

    public static func initials(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "?" }
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Stable hue for a fallback avatar colour.
    public static func hue(for key: String) -> Double {
        var h: UInt32 = 0
        for u in key.utf8 { h = h &* 31 &+ UInt32(u) }
        return Double(h % 360) / 360
    }

    public static func displayName(for userId: UserId, in conversation: Conversation?, me: RelayUser?) -> String {
        if let me, me.userId == userId { return "You" }
        if let peer = conversation?.peer, peer.userId == userId { return peer.displayName ?? userId }
        return conversation?.members.first { $0.userId == userId }?.displayName ?? userId
    }
}
