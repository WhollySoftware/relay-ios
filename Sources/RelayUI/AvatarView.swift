import SwiftUI

/// Round avatar: remote image when available, coloured initials otherwise.
public struct AvatarView: View {
    let name: String?
    let url: String?
    let colorKey: String
    var size: CGFloat = 44

    public init(name: String?, url: String?, colorKey: String? = nil, size: CGFloat = 44) {
        self.name = name; self.url = url; self.colorKey = colorKey ?? name ?? "?"; self.size = size
    }

    public var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(name ?? "Avatar")
    }

    private var fallback: some View {
        let hue = RelayFormat.hue(for: colorKey)
        return ZStack {
            Color(hue: hue, saturation: 0.45, brightness: 0.92)
            Text(RelayFormat.initials(name))
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Color(hue: hue, saturation: 0.5, brightness: 0.35))
        }
    }
}

/// Small online/offline dot, positioned by the caller.
public struct PresenceDot: View {
    @Environment(\.relayTheme) private var theme
    let online: Bool?
    public init(online: Bool?) { self.online = online }
    public var body: some View {
        if let online {
            Circle()
                .fill(online ? theme.online : Color.gray)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color(white: 1), lineWidth: 2))
                .accessibilityLabel(online ? "Online" : "Offline")
        }
    }
}

public struct TypingIndicatorView: View {
    @Environment(\.relayTheme) private var theme
    let names: [String]
    @State private var phase = 0
    public init(names: [String]) { self.names = names }
    public var body: some View {
        if !names.isEmpty {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(theme.secondaryText).frame(width: 6, height: 6).opacity(phase == i ? 1 : 0.3)
                    }
                }
                Text("\(joined) \(names.count == 1 ? "is" : "are") typing…")
                    .font(.footnote).foregroundStyle(theme.secondaryText)
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    phase = (phase + 1) % 3
                }
            }
            .accessibilityLabel("\(joined) typing")
        }
    }
    private var joined: String {
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }
}
