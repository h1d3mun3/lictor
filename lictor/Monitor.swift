//
//  Monitor.swift
//  lictor
//
//  Fetches and holds observed state. The decision of what to show lives in the
//  pure functions in Core/Models.swift.
//
//  **This class does not enforce deadlines.** Enforcement is the job of the
//  launchd agent; the app is allowed to die at any moment (principle 1).
//  Never add a Timer-driven auto-disable here.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Monitor {

    /// Polling interval under normal conditions
    private static let normalInterval: Duration = .seconds(30)
    /// Interval used between the deadline and the actual close. The agent can
    /// take up to 60 seconds, so look more often while that is pending.
    private static let closingInterval: Duration = .seconds(5)

    private(set) var display = Display(state: .unavailable(reason: "Starting up"))
    private(set) var snapshot = TailscaleSnapshot.unreachable
    private(set) var session: SessionState?
    private(set) var lastCheck: Date?
    private(set) var isChecking = false
    private(set) var isWorking = false
    /// Message from the most recent failed toggle. Cleared by the next attempt.
    private(set) var lastError: String?

    private let currentUser = NSUserName()
    private let notifier = Notifier()
    /// The deadline the expiry warning was last fired for. Extending produces a
    /// new deadline, which re-arms the warning.
    private var lastWarnedFor: Date?
    /// Refreshes are numbered so a slow one cannot publish over a newer result.
    private var startedRefreshes = 0
    private var publishedRefresh = 0
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

    init() {
        // Under `xcodebuild test` this app is launched as the test host, and its
        // poll loop would then read the real /var/run/tailscaled.socket and the
        // live ~/.local/state/lictor/state.json -- which CLAUDE.md, run-all.sh and
        // the CI workflow all promise the suites never do. The tests exercise pure
        // logic and need nothing from a running Monitor.
        guard !Monitor.isRunningUnderTest else { return }
        start()
    }

    private static var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    // No deinit: the Monitor lives for the lifetime of the app, and a deinit
    // cannot touch main-actor-isolated properties. The tasks die with the process.

    // MARK: - Loops

    private func start() {
        notifier.onExtend = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.extend(by: Notifier.extensionGranted)
            }
        }
        Task { await notifier.configure() }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.display.state == .closing
                    ? Monitor.closingInterval
                    : Monitor.normalInterval
                try? await Task.sleep(for: interval)
            }
        }

        // Refresh only the countdown text once a second. This never touches the
        // LocalAPI; the display is always recomputed from the cached snapshot.
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.recompute()
            }
        }

        // Re-evaluate immediately on wake (docs/principles.md). Right after waking,
        // the deadline has very likely passed already.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    // MARK: - Fetching

    /// Manual re-check; also invoked from the dropdown button.
    func refresh() async {
        isChecking = true
        defer { isChecking = false }

        // @MainActor gives mutual exclusion between suspension points, not across
        // them, so without this the refresh that FINISHES last wins rather than
        // the one that SAMPLED last. A poll that read RunSSH=false and then
        // stalled would republish "off" over a session the user had just enabled,
        // and the menu bar would show a closed lock for up to 30 seconds while
        // SSH was open -- the one thing the display is not allowed to do.
        startedRefreshes += 1
        let generation = startedRefreshes

        let socketPath = TailscaleLocalAPI.defaultSocketPath

        // Socket I/O blocks, so keep it off the main thread
        let observed = await Task.detached(priority: .utility) {
            TailscaleLocalAPI.snapshot(socketPath: socketPath)
        }.value

        let stored = await Task.detached(priority: .utility) {
            StateFileStore.read()
        }.value

        guard generation > publishedRefresh else { return }
        publishedRefresh = generation

        snapshot = observed
        session = stored
        lastCheck = Date()
        recompute()
    }

    // MARK: - Toggling

    /// Enables SSH for a bounded duration, behind Touch ID.
    ///
    /// Authentication happens before anything is written, so a cancelled prompt
    /// leaves no trace.
    func enable(for duration: SessionDuration) async {
        lastError = nil
        isWorking = true
        defer { isWorking = false }

        do {
            try await Authenticator.authenticate(
                reason: "enable Tailscale SSH for \(duration.label)")
            try await SessionController.enable(duration: duration)
        } catch let error as AuthenticationError {
            // A cancelled prompt is a normal outcome, not a failure to report
            if case .denied = error { return }
            lastError = error.description
        } catch let error as CustomStringConvertible {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }

        await refresh()

        // Announce only what actually happened. If the CLI failed, session is nil
        // and there is nothing to announce.
        if lastError == nil, let session {
            lastWarnedFor = nil                 // a fresh deadline re-arms the warning
            notifier.notifyEnabled(until: session.expiresAt)
        }
    }

    /// Adds to the current deadline, behind Touch ID.
    ///
    /// Extending keeps SSH open longer, which is the dangerous direction, so it
    /// costs exactly what enabling costs (principle 3). It also means a
    /// stray click on the notification cannot silently prolong a session.
    func extend(by duration: SessionDuration) async {
        lastError = nil
        isWorking = true
        defer { isWorking = false }

        do {
            try await Authenticator.authenticate(
                reason: "extend Tailscale SSH by \(duration.label)")
            try await SessionController.extend(by: duration)
        } catch let error as AuthenticationError {
            if case .denied = error { return }
            lastError = error.description
        } catch let error as CustomStringConvertible {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }

        await refresh()

        if lastError == nil, let session {
            // The new deadline is a different value, so the five-minute warning
            // re-arms for the extended session on its own.
            notifier.notifyExtended(until: session.expiresAt)
        }
    }

    /// Disables SSH. No authentication: the safe direction stays frictionless
    /// (principle 3), even though it disconnects live sessions (ADR-0008).
    func disable() async {
        lastError = nil
        isWorking = true
        defer { isWorking = false }

        do {
            try await SessionController.disable()
        } catch let error as CustomStringConvertible {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }

        await refresh()
    }

    // MARK: - Display

    private func recompute() {
        display = computeDisplay(
            snapshot: snapshot,
            session: session,
            currentUser: currentUser,
            now: Date()
        )

        // Checked on the display tick rather than on a scheduled timer, so that
        // waking from sleep past the warning point still fires it.
        if shouldWarnAboutExpiry(state: display.state,
                                 session: session,
                                 lastWarnedFor: lastWarnedFor),
           case .active(let remaining) = display.state {
            lastWarnedFor = session?.expiresAt
            notifier.notifyExpiringSoon(remaining: remaining)
        }
    }
}
