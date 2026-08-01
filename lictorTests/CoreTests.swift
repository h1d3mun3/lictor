//
//  CoreTests.swift
//  lictorTests
//
//  Tests for the app's pure logic: computeDisplay, formatting, and the state
//  file encoding.
//
//  What is deliberately NOT here:
//
//  The agent suites (agent/test-agent*.sh) stay in shell because the thing under
//  test is a shell script. tests/run-socket.sh and tests/run-interop.sh also stay
//  outside Xcode because they drive real external processes -- a fake LocalAPI
//  server over a unix socket, and the bash agent parsing a file this app wrote.
//  Those cross-language contracts are exactly where a silent break would hide,
//  and they are not expressible as unit tests of Swift code alone.
//

import Foundation
import Testing

@testable import lictor

/// Reference instant for every time-dependent test: 2026-08-01T12:00:00Z
private let now = SessionState.parseISO8601("2026-08-01T12:00:00Z")!

private func session(expires: String, duration: Int? = 1800) -> SessionState {
    let json = """
    {"version":1,"expiresAt":"\(expires)","enabledAt":"2026-08-01T11:00:00Z",\
    "durationSeconds":\(duration.map(String.init) ?? "null")}
    """
    return SessionState.decode(from: Data(json.utf8))!
}

private let healthy = TailscaleSnapshot(
    runSSH: false, backendState: "Running", health: [], operatorUser: "tester")

private var enabled: TailscaleSnapshot {
    var snapshot = healthy
    snapshot.runSSH = true
    return snapshot
}

private func display(_ snapshot: TailscaleSnapshot, _ state: SessionState?) -> Display {
    computeDisplay(snapshot: snapshot, session: state, currentUser: "tester", now: now)
}

// MARK: -

@Suite("computeDisplay")
struct ComputeDisplayTests {

    @Test("an unreachable LocalAPI reports unavailable rather than guessing")
    func unreachable() {
        #expect(display(.unreachable, nil).state
                == .unavailable(reason: "Cannot reach tailscaled"))
    }

    @Test("a backend that is not Running reports unavailable")
    func backendStopped() {
        var snapshot = healthy
        snapshot.backendState = "Stopped"
        #expect(display(snapshot, nil).state
                == .unavailable(reason: "Tailscale is Stopped"))
    }

    @Test("RunSSH false is off")
    func off() {
        #expect(display(healthy, nil).state == .off)
    }

    @Test("a leftover state file does not make an off session look on")
    func offWithLeftoverState() {
        #expect(display(healthy, session(expires: "2026-08-01T13:00:00Z")).state == .off)
    }

    @Test("RunSSH true with no state file is unmanaged; the agent will close it")
    func unmanaged() {
        #expect(display(enabled, nil).state == .unmanaged)
    }

    @Test("within the deadline reports the remaining time")
    func active() {
        #expect(display(enabled, session(expires: "2026-08-01T13:00:00Z")).state
                == .active(remaining: 3600))
    }

    @Test("past the deadline reports closing, never off")
    func closing() {
        // Enforcement runs on a 60 second tick, so SSH really is still open here.
        // Reporting it as off would be a lie the user could act on.
        #expect(display(enabled, session(expires: "2026-08-01T11:59:59Z")).state == .closing)
    }

    @Test("the deadline boundary matches the agent's decide(): now == expiresAt is expired")
    func boundaryAtDeadline() {
        #expect(display(enabled, session(expires: "2026-08-01T12:00:00Z")).state == .closing)
    }

    @Test("one second before the deadline is still active")
    func boundaryBeforeDeadline() {
        #expect(display(enabled, session(expires: "2026-08-01T12:00:01Z")).state
                == .active(remaining: 1))
    }
}

// MARK: -

@Suite("Warnings")
struct WarningTests {

    @Test("a foreign operator is a warning, not a failure to read state")
    func foreignOperator() {
        var snapshot = enabled
        snapshot.operatorUser = "someone-else"
        let result = display(snapshot, session(expires: "2026-08-01T13:00:00Z"))

        #expect(result.warnings
                == [.operatorMismatch(expected: "tester", actual: "someone-else")])
        // The toggle will not work, but the state is still observable, and the
        // user needs to be able to tell those two situations apart.
        #expect(result.state == .active(remaining: 3600))
    }

    @Test("an unset operator warns too")
    func unsetOperator() {
        var snapshot = enabled
        snapshot.operatorUser = nil
        #expect(display(snapshot, session(expires: "2026-08-01T13:00:00Z")).warnings
                == [.operatorMismatch(expected: "tester", actual: nil)])
    }

    @Test("Tailscale's own health reports are surfaced")
    func health() {
        var snapshot = healthy
        snapshot.health = ["not logged in"]
        #expect(display(snapshot, nil).warnings == [.tailscaleHealth(["not logged in"])])
    }

    @Test("health warnings survive an unreachable daemon")
    func healthWhenUnreachable() {
        let snapshot = TailscaleSnapshot(
            runSSH: nil, backendState: nil, health: ["boom"], operatorUser: nil)
        #expect(computeDisplay(snapshot: snapshot, session: nil,
                               currentUser: "tester", now: now).warnings
                == [.tailscaleHealth(["boom"])])
    }

    @Test("a healthy system produces no warnings")
    func quietWhenHealthy() {
        #expect(display(healthy, nil).warnings.isEmpty)
    }
}

// MARK: -

/// Explicitly typed: an inline array of mixed numeric literals sends the type
/// checker into an exponential search and the build times out.
private let remainingCases: [(TimeInterval, String)] = [
    (0, "0:00"),
    (-120, "0:00"),     // clamped; a negative countdown is meaningless
    (59, "0:59"),
    (60, "1:00"),
    (60.9, "1:00"),     // truncated, never rounded up
    (2840, "47:20"),
    (3599, "59:59"),
    (3600, "1:00"),
    (6420, "1:47"),
    (28800, "8:00"),
]

@Suite("formatRemaining")
struct FormattingTests {

    @Test("renders as mm:ss under an hour and h:mm above it", arguments: remainingCases)
    func remaining(interval: TimeInterval, expected: String) {
        #expect(formatRemaining(interval) == expected)
    }
}

// MARK: -

@Suite("SessionState coding")
struct SessionStateCodingTests {

    @Test("reads the file dev-enable.sh writes")
    func decodesAgentFormat() throws {
        let json = """
        {"version":1,"expiresAt":"2026-08-01T14:30:00Z",\
        "enabledAt":"2026-08-01T12:30:00Z","durationSeconds":7200}
        """
        let state = try #require(SessionState.decode(from: Data(json.utf8)))

        #expect(state.expiresAt == SessionState.parseISO8601("2026-08-01T14:30:00Z"))
        #expect(state.durationSeconds == 7200)
        #expect(state.version == 1)
    }

    @Test("accepts fractional seconds")
    func decodesFractionalSeconds() {
        let json = #"{"version":1,"expiresAt":"2026-08-01T14:30:00.123Z"}"#
        #expect(SessionState.decode(from: Data(json.utf8)) != nil)
    }

    @Test("unusable input decodes to nil so the app treats it as no session",
          arguments: [
            #"{"version":1}"#,                              // no expiresAt
            #"{"version":1,"expiresAt":"nonsense"}"#,       // unparsable timestamp
            "not json",
            "",
          ])
    func rejectsBadInput(json: String) {
        #expect(SessionState.decode(from: Data(json.utf8)) == nil)
    }

    @Test("encode and decode round-trip")
    func roundTrip() throws {
        let state = SessionState.make(duration: .twoHours, now: now)
        let data = try #require(SessionState.encode(state))
        #expect(SessionState.decode(from: data) == state)
    }

    @Test("expiresAt is emitted as a plain string on one line")
    func agentParsableShape() throws {
        // The agent greps this file with
        //   "expiresAt"[[:space:]]*:[[:space:]]*"[^"]*"
        // so the value must stay a quoted string. tests/run-interop.sh proves the
        // real cross-language path; this catches the encoding change earlier.
        let data = try #require(SessionState.encode(SessionState.make(duration: .twoHours, now: now)))
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("\"expiresAt\" : \""))
        #expect(!text.contains("\"expiresAt\" : 7"))    // not a numeric timestamp
    }
}

// MARK: -

@Suite("SessionDuration")
struct SessionDurationTests {

    @Test("offers exactly the three documented durations")
    func options() {
        #expect(SessionDuration.allCases.map(\.seconds) == [1800, 7200, 28800])
    }

    @Test("has no indefinite option, by design")
    func noIndefiniteOption() {
        // principle 4: forgetting is designed out, not guarded against.
        #expect(SessionDuration.allCases.allSatisfy { $0.seconds > 0 })
    }

    @Test("both labels are populated for every duration")
    func labels() {
        // The compact label goes in the notification action, the long one in menu
        // rows. A missing one would ship a blank button.
        #expect(SessionDuration.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(SessionDuration.allCases.allSatisfy { !$0.longLabel.isEmpty })
    }

    @Test("make() derives the deadline from the injected instant")
    func make() {
        let state = SessionState.make(duration: .twoHours, now: now)

        #expect(state.enabledAt == now)
        #expect(state.expiresAt == now.addingTimeInterval(7200))
        #expect(state.durationSeconds == 7200)
        #expect(state.version == 1)
    }
}

// MARK: -

@Suite("Expiry warning")
struct ExpiryWarningTests {

    private let deadline = now.addingTimeInterval(240)   // four minutes out

    private var nearlyExpired: DisplayState { .active(remaining: 240) }

    @Test("fires inside the threshold")
    func firesWhenClose() {
        #expect(shouldWarnAboutExpiry(
            state: nearlyExpired,
            session: SessionState.make(duration: .thirtyMinutes, now: now),
            lastWarnedFor: nil))
    }

    @Test("stays quiet outside the threshold")
    func quietWhenFarOut() {
        #expect(!shouldWarnAboutExpiry(
            state: .active(remaining: 301),
            session: SessionState.make(duration: .thirtyMinutes, now: now),
            lastWarnedFor: nil))
    }

    @Test("fires exactly at the threshold")
    func firesAtBoundary() {
        #expect(shouldWarnAboutExpiry(
            state: .active(remaining: 300),
            session: SessionState.make(duration: .thirtyMinutes, now: now),
            lastWarnedFor: nil))
    }

    @Test("fires only once for a given deadline")
    func firesOnlyOnce() {
        let session = SessionState.make(duration: .thirtyMinutes, now: now)
        #expect(!shouldWarnAboutExpiry(
            state: nearlyExpired, session: session, lastWarnedFor: session.expiresAt))
    }

    @Test("extending re-arms the warning")
    func extendingReArms() {
        // Extending produces a new expiresAt, so the previously warned deadline
        // no longer matches and the extended session gets its own warning.
        let original = SessionState.make(duration: .thirtyMinutes, now: now)
        let extended = SessionState.make(duration: .thirtyMinutes,
                                         now: now.addingTimeInterval(1500))
        #expect(shouldWarnAboutExpiry(
            state: nearlyExpired, session: extended, lastWarnedFor: original.expiresAt))
    }

    @Test("never warns once the deadline has passed")
    func silentWhenClosing() {
        // .closing means expiry already happened; a warning would be noise about
        // something the user can no longer prevent.
        #expect(!shouldWarnAboutExpiry(
            state: .closing,
            session: SessionState.make(duration: .thirtyMinutes, now: now),
            lastWarnedFor: nil))
    }

    @Test("never warns in states where there is no deadline",
          arguments: [DisplayState.off,
                      .unmanaged,
                      .unavailable(reason: "Cannot reach tailscaled")])
    func silentWithoutADeadline(state: DisplayState) {
        #expect(!shouldWarnAboutExpiry(state: state, session: nil, lastWarnedFor: nil))
    }
}

// MARK: -

@Suite("Extending a session")
struct ExtendingTests {

    @Test("adds to the existing deadline rather than restarting from now")
    func addsToDeadline() {
        // A button labelled "Extend 30 min" means half an hour more than you had.
        // With 4 minutes left, that is 34 minutes, not 30.
        let current = SessionState.make(duration: .thirtyMinutes, now: now)
        let later = now.addingTimeInterval(1560)          // 4 minutes remaining
        let extended = SessionState.extending(current, by: .thirtyMinutes, now: later)

        #expect(extended.expiresAt == current.expiresAt.addingTimeInterval(1800))
        #expect(extended.expiresAt.timeIntervalSince(later) == 2040)   // 34 minutes
    }

    @Test("keeps the original enabledAt so it still means when the session began")
    func preservesEnabledAt() {
        let current = SessionState.make(duration: .thirtyMinutes, now: now)
        let extended = SessionState.extending(
            current, by: .thirtyMinutes, now: now.addingTimeInterval(1560))

        #expect(extended.enabledAt == now)
    }

    @Test("accumulates durationSeconds into the total granted")
    func accumulatesDuration() {
        let current = SessionState.make(duration: .thirtyMinutes, now: now)
        let extended = SessionState.extending(
            current, by: .thirtyMinutes, now: now.addingTimeInterval(1560))

        #expect(extended.durationSeconds == 3600)
    }

    @Test("a deadline already in the past grants the full duration from now")
    func pastDeadlineMeasuresFromNow() {
        // Otherwise "Extend 30 min" pressed during .closing would grant less than
        // 30 minutes, or even a deadline still in the past.
        let expired = SessionState.make(duration: .thirtyMinutes, now: now)
        let later = now.addingTimeInterval(3000)          // 20 minutes past expiry
        let extended = SessionState.extending(expired, by: .thirtyMinutes, now: later)

        #expect(extended.expiresAt == later.addingTimeInterval(1800))
    }

    @Test("extending with no existing session behaves like enabling")
    func noExistingSession() {
        let extended = SessionState.extending(nil, by: .twoHours, now: now)

        #expect(extended.expiresAt == now.addingTimeInterval(7200))
        #expect(extended.enabledAt == now)
        #expect(extended.durationSeconds == 7200)
    }

    @Test("repeated extensions keep stacking")
    func stacks() {
        var state = SessionState.make(duration: .thirtyMinutes, now: now)
        state = SessionState.extending(state, by: .thirtyMinutes, now: now)
        state = SessionState.extending(state, by: .thirtyMinutes, now: now)

        #expect(state.expiresAt == now.addingTimeInterval(5400))   // 90 minutes
    }

    @Test("the extended deadline re-arms the expiry warning")
    func reArmsWarning() {
        let current = SessionState.make(duration: .thirtyMinutes, now: now)
        let extended = SessionState.extending(
            current, by: .thirtyMinutes, now: now.addingTimeInterval(1560))

        #expect(shouldWarnAboutExpiry(
            state: .active(remaining: 240),
            session: extended,
            lastWarnedFor: current.expiresAt))
    }
}

// MARK: -

@Suite("What the controls offer")
struct ControlAvailabilityTests {

    private let live = SessionState.make(duration: .thirtyMinutes, now: now)

    @Test("closing counts as open, because SSH really is still accepting connections")
    func closingIsOpen() {
        #expect(isSSHOpen(.closing))
    }

    @Test("open and closed states", arguments: [
        (DisplayState.active(remaining: 60), true),
        (.closing, true),
        (.unmanaged, true),
        (.off, false),
        (.unavailable(reason: "Cannot reach tailscaled"), false),
    ])
    func openStates(state: DisplayState, expected: Bool) {
        #expect(isSSHOpen(state) == expected)
    }

    @Test("extending is offered while a session is running")
    func extendWhenActive() {
        #expect(canExtend(state: .active(remaining: 60), session: live))
    }

    @Test("extending is still offered after the deadline, before the agent closes it")
    func extendWhenClosing() {
        // There is a window of up to 60 seconds here (ADR-0008) and the user may well
        // be reacting to the warning inside it.
        #expect(canExtend(state: .closing, session: live))
    }

    @Test("extending is never offered for an unmanaged session")
    func noExtendWhenUnmanaged() {
        // There is no deadline to add to, and offering it would turn Lictor into
        // a way to adopt a session opened behind its back, which is the case ADR-0005
        // exists to close.
        #expect(!canExtend(state: .unmanaged, session: nil))
        #expect(!canExtend(state: .unmanaged, session: live))
    }

    @Test("extending is never offered without a session file")
    func noExtendWithoutSession() {
        #expect(!canExtend(state: .active(remaining: 60), session: nil))
        #expect(!canExtend(state: .closing, session: nil))
    }

    @Test("extending is never offered while off or unreadable")
    func noExtendWhenClosed() {
        #expect(!canExtend(state: .off, session: live))
        #expect(!canExtend(state: .unavailable(reason: "boom"), session: live))
    }
}

// MARK: -

@Suite("History log")
struct HistoryTests {

    @Test("round-trips an enable")
    func roundTripEnabled() throws {
        let event = HistoryEvent(at: now, kind: .enabled, reason: nil,
                                 expiresAt: now.addingTimeInterval(7200),
                                 durationSeconds: 7200)
        let parsed = try #require(HistoryEvent.parse(line: event.line()))
        #expect(parsed == event)
    }

    @Test("round-trips a disable with a reason")
    func roundTripDisabled() throws {
        let event = HistoryEvent(at: now, kind: .disabled, reason: .expired,
                                 expiresAt: nil, durationSeconds: nil)
        let parsed = try #require(HistoryEvent.parse(line: event.line()))
        #expect(parsed == event)
    }

    @Test("reads exactly what the agent's printf produces")
    func parsesAgentOutput() throws {
        // agent/lictor-agent.sh writes this shape. tests/run-interop.sh proves the
        // real path; this catches a format change without running the agent.
        let line = #"{"at":"2026-08-01T12:00:00Z","event":"disabled","reason":"no-state"}"#
        let parsed = try #require(HistoryEvent.parse(line: line))

        #expect(parsed.kind == .disabled)
        #expect(parsed.reason == .noState)
        #expect(parsed.at == now)
    }

    @Test("unusable lines are skipped, never surfaced as errors", arguments: [
        "",
        "   ",
        "not json",
        #"{"event":"enabled"}"#,                                // no timestamp
        #"{"at":"2026-08-01T12:00:00Z"}"#,                      // no event
        #"{"at":"nonsense","event":"enabled"}"#,                // bad timestamp
        #"{"at":"2026-08-01T12:00:00Z","event":"teleported"}"#, // unknown event
    ])
    func skipsJunk(line: String) {
        #expect(HistoryEvent.parse(line: line) == nil)
    }

    @Test("a log is returned newest first, with junk dropped in place")
    func parsesFileNewestFirst() {
        let contents = """
        {"at":"2026-08-01T12:00:00Z","event":"enabled","durationSeconds":1800}
        this line is corrupt
        {"at":"2026-08-01T12:20:00Z","event":"extended"}
        {"at":"2026-08-01T12:50:00Z","event":"disabled","reason":"expired"}
        """
        let events = HistoryEvent.parse(contents: contents)

        #expect(events.count == 3)
        #expect(events.map(\.kind) == [.disabled, .extended, .enabled])
    }

    @Test("the viewer caps how much it renders")
    func respectsLimit() {
        // The file is append-only and never trimmed, so the reader is what keeps
        // a year of entries from deciding how long the window takes to open.
        let contents = (0..<50)
            .map { #"{"at":"2026-08-01T12:00:0\#($0 % 10)Z","event":"enabled"}"# }
            .joined(separator: "\n")
        #expect(HistoryEvent.parse(contents: contents, limit: 10).count == 10)
    }

    @Test("only the reasons Lictor did not cause count as anomalies")
    func anomalies() {
        #expect(HistoryEvent.Reason.noState.isAnomalous)
        #expect(HistoryEvent.Reason.badState.isAnomalous)
        #expect(!HistoryEvent.Reason.user.isAnomalous)
        #expect(!HistoryEvent.Reason.expired.isAnomalous)
    }

    @Test("an empty log is empty, not an error")
    func emptyLog() {
        #expect(HistoryEvent.parse(contents: "").isEmpty)
    }

    @Test("events sharing a second and a kind still get distinct ids")
    func idsStayUnique() {
        // Both writers stamp whole seconds, so this is reachable: the user
        // pressing Turn off in the same second the agent records an expiry. With
        // colliding ids `List` renders one row for the pair and drops the older,
        // which is the anomalous one the window exists to show.
        let contents = """
        {"at":"2026-08-01T12:00:00Z","event":"disabled","reason":"expired"}
        {"at":"2026-08-01T12:00:00Z","event":"disabled","reason":"user"}
        {"at":"2026-08-01T12:00:00Z","event":"disabled","reason":"no-state"}
        """
        let events = HistoryEvent.parse(contents: contents)

        #expect(events.count == 3)
        #expect(Set(events.map(\.id)).count == events.count)
    }
}
