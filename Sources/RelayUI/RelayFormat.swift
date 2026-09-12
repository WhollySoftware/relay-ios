import SwiftUI
// Re-exported (not just imported) so the rest of RelayUI keeps seeing RelayCore's types
// (Conversation, Message, UserId, RelayClient, ...) without every file adding its own import —
// matching the visibility the old RelayTheme.swift provided before RelayTheme moved to RelayCore.
@_exported import RelayCore

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

    /// Full date + time — e.g. for "Message info" read/delivered timestamps, where the compact
    /// `relative`/`time` helpers above are too coarse.
    public static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
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

    /// First http(s) URL in a message body — decides which link gets the preview card under the
    /// bubble. Bare domains ("google.com") deliberately don't count, same rule on web/Android so a
    /// message previews identically everywhere.
    public static func firstUrl(in text: String) -> String? {
        guard let range = text.range(of: #"https?://[^\s<>"')\]]+"#, options: .regularExpression) else { return nil }
        var url = String(text[range])
        while let last = url.last, ".,;:!?".contains(last) { url.removeLast() } // trailing punctuation isn't part of the link
        return url.isEmpty ? nil : url
    }

    public static func fileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
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
