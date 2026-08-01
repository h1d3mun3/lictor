//
//  HistoryEvent.swift
//  lictor
//
//  One line of `~/.local/state/lictor/history.jsonl`.
//
//  Both the app and the agent append to this file, so the format is the contract
//  between them, exactly as state.json is. It is JSON Lines rather than a single
//  JSON document because appending a line is a single atomic write, while
//  rewriting a document is not, and the agent may be appending while the app is
//  reading.
//
//  **Nothing here may block enforcement.** A history write that fails is
//  discarded silently: being unable to record that SSH closed is never a reason
//  to leave it open (principle 1).
//
//  Parsing is deliberately forgiving. A malformed or unrecognised line is
//  skipped, not surfaced as an error, because this file is a log that outlives
//  the format that wrote it.
//

import Foundation

nonisolated struct HistoryEvent: Equatable, Sendable, Identifiable {

    enum Kind: String, Sendable {
        case enabled
        case extended
        case disabled
    }

    enum Reason: String, Sendable {
        /// The user pressed Turn off
        case user
        /// The deadline passed
        case expired
        /// RunSSH was true with no state file (ADR-0005)
        case noState = "no-state"
        /// The state file could not be parsed
        case badState = "bad-state"

        /// Whether this reason means something happened that Lictor did not do.
        ///
        /// This is the reason the history exists: spotting a session nobody here
        /// opened matters more than any other entry in the file.
        var isAnomalous: Bool { self == .noState || self == .badState }
    }

    let at: Date
    let kind: Kind
    let reason: Reason?
    let expiresAt: Date?
    let durationSeconds: Int?

    /// Position in the parsed log, newest first.
    ///
    /// Both writers stamp whole seconds, so two events can genuinely share an
    /// instant and a kind -- the user pressing Turn off in the same second the
    /// agent records an expiry, which the five-minute warning actively invites.
    /// Without the ordinal those two collide, and `List` silently renders one
    /// row for them, dropping the older. The row it drops is exactly the
    /// anomalous one the window exists to surface.
    var ordinal: Int = 0

    var id: String { "\(ordinal)-\(at.timeIntervalSince1970)-\(kind.rawValue)" }

    // MARK: - Writing

    /// Renders one line, compact and without a trailing newline.
    ///
    /// Written by hand rather than with JSONEncoder so the field order is fixed
    /// and matches what the agent's printf produces. Values are all timestamps,
    /// enum cases or integers, so none of them can contain a quote to escape.
    func line() -> String {
        var parts = [
            "\"at\":\"\(HistoryEvent.format(at))\"",
            "\"event\":\"\(kind.rawValue)\"",
        ]
        if let reason {
            parts.append("\"reason\":\"\(reason.rawValue)\"")
        }
        if let durationSeconds {
            parts.append("\"durationSeconds\":\(durationSeconds)")
        }
        if let expiresAt {
            parts.append("\"expiresAt\":\"\(HistoryEvent.format(expiresAt))\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Reading

    /// Parses one line. Returns nil for anything unusable.
    static func parse(line: String) -> HistoryEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atText = object["at"] as? String,
              let at = SessionState.parseISO8601(atText),
              let eventText = object["event"] as? String,
              let kind = Kind(rawValue: eventText)
        else { return nil }

        return HistoryEvent(
            at: at,
            kind: kind,
            reason: (object["reason"] as? String).flatMap(Reason.init(rawValue:)),
            expiresAt: (object["expiresAt"] as? String).flatMap(SessionState.parseISO8601),
            durationSeconds: object["durationSeconds"] as? Int
        )
    }

    /// Parses a whole file, newest first.
    ///
    /// - Parameter limit: how many entries to keep. The file is append-only and
    ///   never trimmed, so the viewer caps what it renders rather than letting a
    ///   year of entries decide how long the window takes to open.
    static func parse(contents: String, limit: Int = 500) -> [HistoryEvent] {
        contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .lazy
            .compactMap { parse(line: String($0)) }
            .prefix(limit)
            .enumerated()
            .map { index, event in
                var numbered = event
                numbered.ordinal = index
                return numbered
            }
    }
}
