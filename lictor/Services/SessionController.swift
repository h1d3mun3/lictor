//
//  SessionController.swift
//  lictor
//
//  The write side: enabling and disabling Tailscale SSH.
//
//  This is the only place in the app that changes anything. It deliberately
//  exposes exactly two operations and nothing else (principle 5).
//
//  **It does not enforce deadlines.** Expiry belongs to the launchd agent, which
//  keeps working when this app is not running (principle 1).
//

import Foundation

enum SessionController {

    /// Enables SSH for a bounded duration.
    ///
    /// Ordering follows ADR-0006 and must not be rearranged:
    ///
    ///   1. write state.json
    ///   2. run `tailscale set --ssh=true`
    ///   3. on failure, delete state.json again
    ///
    /// The reverse order would leave a window where SSH is on with no recorded
    /// deadline. An agent tick landing in that window closes SSH at once (ADR-0005),
    /// silently undoing the very action the user just took. This order's window
    /// is the harmless one: a state file with SSH still off, which the agent
    /// simply cleans up.
    static func enable(duration: SessionDuration, now: Date = Date()) async throws {
        let state = SessionState.make(duration: duration, now: now)

        try StateFileStore.write(state)

        do {
            try await Task.detached(priority: .userInitiated) {
                try TailscaleCLI.setSSH(true)
            }.value
        } catch {
            StateFileStore.remove()
            throw error
        }
    }

    /// Extends the current session by adding to its deadline.
    ///
    /// Same ordering as `enable` (ADR-0006): the state file first, then the CLI. SSH is
    /// normally already on here, which makes `--ssh=true` a no-op, but it is not
    /// skipped: if the agent closed SSH between the warning firing and the user
    /// reacting, extending should genuinely reopen it rather than leave a state
    /// file describing a session that does not exist.
    static func extend(by duration: SessionDuration, now: Date = Date()) async throws {
        let previous = StateFileStore.read()
        let extended = SessionState.extending(previous, by: duration, now: now)

        try StateFileStore.write(extended)

        do {
            try await Task.detached(priority: .userInitiated) {
                try TailscaleCLI.setSSH(true)
            }.value
        } catch {
            // Restore what was there before rather than deleting outright: the
            // previous deadline is still the truth, and dropping the file would
            // make the agent close SSH within 60 seconds (ADR-0005).
            if let previous {
                try? StateFileStore.write(previous)
            } else {
                StateFileStore.remove()
            }
            throw error
        }
    }

    /// Disables SSH.
    ///
    /// **This terminates SSH sessions that are already established** (ADR-0008), so
    /// callers must say so in the UI before invoking it.
    ///
    /// SSH is turned off before the state file is removed. If the order were
    /// reversed and the CLI then failed, the result would be SSH on with no
    /// state file, which the agent would close within 60 seconds anyway. Both
    /// orders are safe; this one leaves no window where the UI claims a session
    /// exists that has already been closed.
    static func disable() async throws {
        try await Task.detached(priority: .userInitiated) {
            try TailscaleCLI.setSSH(false)
        }.value

        StateFileStore.remove()
    }
}
