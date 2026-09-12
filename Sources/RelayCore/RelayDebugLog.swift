import Foundation

// Opt-in verbose diagnostics, redaction-first: `RelayConfig.debug` gates everything below, and
// every helper here is built so it CANNOT be used to leak a secret even by accident — there is no
// "raw URL" or "raw object" logging helper anywhere in the SDK, only these.
//
// Guarantee: debug logs never include auth tokens, TURN credentials, message content, attachment
// URLs, or user display names/avatars — only connection state, request paths (no query strings),
// event types, and non-content ids. See `packages/ios/README.md`'s "Debugging" section.

/// Scheme + host + path only — strips the query string entirely. Use this for ANY URL that might
/// carry secrets (the gateway URL embeds `?key=...&token=...`; REST URLs could carry query params
/// too) before it ever reaches `logger`.
///
/// Public (not just RelayCore-internal) so sibling modules — RelayCall, RelayUI — can redact a
/// URL before logging it too, rather than reinventing this or logging one raw.
public func redactedURL(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.path.isEmpty ? "<url>" : url.path
    }
    components.query = nil
    components.fragment = nil
    // Rebuilding via URLComponents keeps scheme/host/port/path only — no user/password either.
    return components.string ?? components.path
}

/// No-ops unless `config.debug && config.logger != nil`. `@autoclosure` means `message()` (and
/// any string interpolation inside it) is never evaluated when debug logging is off — callers can
/// pass arbitrarily expensive-to-build strings without a cost in the default (non-debug) path.
///
/// Public so RelayCall/RelayUI route their own debug lines through the same gate rather than
/// rolling their own (which could bypass the `debug`/`logger` check or the redaction discipline).
public func debugLog(_ config: RelayConfig, _ message: @autoclosure () -> String) {
    guard config.debug, let logger = config.logger else { return }
    logger(message())
}
