//
//  Models.swift
//  lictor
//
//  Core logic that decides what to display.
//
//  This file depends only on Foundation and has no side effects.
//  The current time is always injected; never call Date() in here (CLAUDE.md, testing).
//  It is the app-side counterpart to decide() in agent/lictor-agent.sh.
//

import Foundation

// MARK: - State file

/// Contents of `~/.local/state/lictor/state.json`.
///
/// The contract is defined in docs/principles.md and `agent/dev-enable.sh`.
/// **No file means no active session.**
nonisolated struct SessionState: Equatable, Sendable, Codable {
    let version: Int
    let expiresAt: Date
    let enabledAt: Date?
    let durationSeconds: Int?

    /// Builds the state for a session starting now.
    static func make(duration: SessionDuration, now: Date) -> SessionState {
        SessionState(
            version: 1,
            expiresAt: now.addingTimeInterval(TimeInterval(duration.seconds)),
            enabledAt: now,
            durationSeconds: duration.seconds
        )
    }

    /// Builds the state for extending an existing session.
    ///
    /// The duration is **added to the current deadline**, not measured from now:
    /// a button labelled "Extend 30 min" means half an hour more than you had.
    ///
    /// The base is the later of the current deadline and now. Extending a session
    /// whose deadline has already passed would otherwise grant less than the
    /// stated amount, or even a deadline in the past.
    ///
    /// `enabledAt` is carried over, so it keeps meaning "when this session began"
    /// rather than "when it was last touched". `durationSeconds` therefore
    /// accumulates into the total granted so far.
    static func extending(
        _ current: SessionState?,
        by duration: SessionDuration,
        now: Date
    ) -> SessionState {
        let base = max(current?.expiresAt ?? now, now)
        let expiresAt = base.addingTimeInterval(TimeInterval(duration.seconds))
        let enabledAt = current?.enabledAt ?? now

        return SessionState(
            version: 1,
            expiresAt: expiresAt,
            enabledAt: enabledAt,
            durationSeconds: Int(expiresAt.timeIntervalSince(enabledAt).rounded())
        )
    }

    /// Serialises in the shape the agent expects.
    ///
    /// The agent parses this file with grep, matching
    /// `"expiresAt"[[:space:]]*:[[:space:]]*"[^"]*"`, so `expiresAt` must stay a
    /// plain ISO 8601 string on a single line. tests/run-interop.sh asserts that
    /// the two implementations still agree.
    static func encode(_ state: SessionState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try? encoder.encode(state)
    }

    /// Parses ISO 8601 (UTC), accepting fractional seconds or not.
    ///
    /// `ISO8601DateFormatter` is not Sendable, so formatters are built per call
    /// rather than reused. The state file is read roughly every 30 seconds,
    /// which makes the allocation cost irrelevant.
    static func parseISO8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func decode(from data: Data) -> SessionState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseISO8601(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "not a valid ISO 8601 timestamp: \(text)"))
            }
            return date
        }
        return try? decoder.decode(SessionState.self, from: data)
    }
}

// MARK: - Durations offered when enabling

/// The only durations the UI offers.
///
/// There is deliberately no "until I turn it off" option: forgetting is designed
/// out rather than guarded against (principle 4).
nonisolated enum SessionDuration: Int, CaseIterable, Sendable {
    case thirtyMinutes = 1800
    case twoHours = 7200
    case eightHours = 28800

    var seconds: Int { rawValue }

    /// Compact form, for places where space is tight such as a notification action.
    var label: String {
        switch self {
        case .thirtyMinutes: return "30 min"
        case .twoHours:      return "2 hours"
        case .eightHours:    return "8 hours"
        }
    }

    /// Spelled out, for menu rows that read as a sentence.
    var longLabel: String {
        switch self {
        case .thirtyMinutes: return "30 minutes"
        case .twoHours:      return "2 hours"
        case .eightHours:    return "8 hours"
        }
    }
}

// MARK: - Observed Tailscale state

/// What the LocalAPI reported at a point in time.
///
/// A `nil` value means "could not read". Do not conflate it with `false`.
nonisolated struct TailscaleSnapshot: Equatable, Sendable {
    /// Whether the SSH server feature is enabled. `nil` means the read failed
    var runSSH: Bool?
    /// `"Running"` is healthy
    var backendState: String?
    /// An empty array is healthy. Any entry means Tailscale is reporting a problem
    var health: [String]
    /// The user configured via `tailscale set --operator`
    var operatorUser: String?

    static let unreachable = TailscaleSnapshot(
        runSSH: nil, backendState: nil, health: [], operatorUser: nil)
}

// MARK: - Display state

nonisolated enum DisplayState: Equatable, Sendable {
    /// Closed. The normal resting state
    case off
    /// Enabled and within its deadline
    case active(remaining: TimeInterval)
    /// The deadline has passed but RunSSH is still true.
    ///
    /// The agent ticks every 60 seconds, so up to a minute elapses between the
    /// deadline and the actual close.
    /// **Never render this as "closed" -- SSH really is still open.**
    case closing
    /// RunSSH is true with no state.json. The agent will close it at once (ADR-0005)
    case unmanaged
    /// State could not be read (tailscaled down, LocalAPI unreachable, ...)
    case unavailable(reason: String)
}

/// A warning shown alongside the display state, about problems that are
/// independent of whether SSH is open.
nonisolated enum DisplayWarning: Equatable, Sendable {
    /// `OperatorUser` is somebody else, so the toggle cannot work (mitigation for ADR-0001)
    case operatorMismatch(expected: String, actual: String?)
    /// Tailscale itself is reporting a problem
    case tailscaleHealth([String])
}

nonisolated struct Display: Equatable, Sendable {
    var state: DisplayState
    var warnings: [DisplayWarning]

    init(state: DisplayState, warnings: [DisplayWarning] = []) {
        self.state = state
        self.warnings = warnings
    }
}

// MARK: - Decision

/// Derives the display state from observations. Pure function.
///
/// - Parameters:
///   - snapshot: Tailscale state read from the LocalAPI
///   - session: contents of state.json, or nil when the file is absent
///   - currentUser: the user this app runs as
///   - now: current time (always injected)
nonisolated func computeDisplay(
    snapshot: TailscaleSnapshot,
    session: SessionState?,
    currentUser: String,
    now: Date
) -> Display {
    var warnings: [DisplayWarning] = []

    if !snapshot.health.isEmpty {
        warnings.append(.tailscaleHealth(snapshot.health))
    }

    // Without RunSSH there is nothing further we can claim
    guard let runSSH = snapshot.runSSH else {
        return Display(state: .unavailable(reason: "Cannot reach tailscaled"),
                       warnings: warnings)
    }

    if let backend = snapshot.backendState, backend != "Running" {
        return Display(state: .unavailable(reason: "Tailscale is \(backend)"),
                       warnings: warnings)
    }

    // A foreign operator breaks the toggle, but the state is still observable,
    // so keep displaying it and attach a warning instead of bailing out.
    if snapshot.operatorUser != currentUser {
        warnings.append(.operatorMismatch(expected: currentUser, actual: snapshot.operatorUser))
    }

    guard runSSH else {
        // Closed. A leftover state.json does not matter; the agent cleans it up
        return Display(state: .off, warnings: warnings)
    }

    guard let session else {
        return Display(state: .unmanaged, warnings: warnings)
    }

    let remaining = session.expiresAt.timeIntervalSince(now)
    // Keep the boundary identical to decide() in the agent:
    // now == expiresAt already counts as expired.
    return Display(state: remaining > 0 ? .active(remaining: remaining) : .closing,
                   warnings: warnings)
}

// MARK: - What the controls may offer

/// Whether SSH is open as far as the app can tell.
///
/// `.closing` counts as on: the deadline has passed but SSH really is still
/// accepting connections until the agent closes it.
nonisolated func isSSHOpen(_ state: DisplayState) -> Bool {
    switch state {
    case .active, .closing, .unmanaged: return true
    case .off, .unavailable:            return false
    }
}

/// Whether extending is offered.
///
/// Requires a session to extend. `.unmanaged` deliberately does not qualify:
/// there is no deadline to add to, and offering Extend there would turn Lictor
/// into a way to adopt a session someone opened behind its back, which is the
/// case ADR-0005 exists to close.
nonisolated func canExtend(state: DisplayState, session: SessionState?) -> Bool {
    guard session != nil else { return false }
    switch state {
    case .active, .closing:                    return true
    case .off, .unmanaged, .unavailable:       return false
    }
}

// MARK: - Expiry warning

/// How long before expiry the warning fires.
nonisolated let expiryWarningThreshold: TimeInterval = 300

/// Whether the five-minute warning is due right now.
///
/// Pure, so the "fire exactly once per session" rule is testable without waiting
/// five minutes. Identity is the session's own deadline: extending produces a new
/// `expiresAt`, which re-arms the warning for the extended session.
///
/// - Parameters:
///   - state: the current display state. Only `.active` can warn -- `.closing`
///     is already past the deadline, where a warning is pointless
///   - session: the session being warned about
///   - lastWarnedFor: the `expiresAt` most recently warned about, or nil
nonisolated func shouldWarnAboutExpiry(
    state: DisplayState,
    session: SessionState?,
    lastWarnedFor: Date?,
    threshold: TimeInterval = expiryWarningThreshold
) -> Bool {
    guard case .active(let remaining) = state, let session else { return false }
    guard remaining <= threshold else { return false }
    return lastWarnedFor != session.expiresAt
}

// MARK: - Formatting

/// Renders the remaining time compactly enough for the menu bar.
///
/// - one hour or more: `h:mm` (e.g. `1:47`)
/// - under an hour:    `mm:ss` (e.g. `47:20`)
///
/// Same convention as a video player. Negative values clamp to `0:00`.
nonisolated func formatRemaining(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60

    if hours > 0 {
        return String(format: "%d:%02d", hours, minutes)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

/// Renders a wall-clock time for humans, in the local time zone.
nonisolated func formatExpiry(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateFormat = "H:mm"
    return formatter.string(from: date)
}
