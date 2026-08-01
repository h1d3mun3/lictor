//
//  StatusPanel.swift
//  lictor
//
//  Contents of the dropdown (.menuBarExtraStyle(.window)). Spec: docs/principles.md, display rules.
//
//  Laid out as a menu bar panel, not as a small application window: a title with
//  the countdown, one line of state, then rows. See MenuRow for why rows rather
//  than bordered buttons.
//
//  `.window` is the right container even though this is not a menu. The panels
//  macOS itself ships for anything stateful -- Wi-Fi, Bluetooth, Control Center
//  -- are custom views too, because an NSMenu cannot hold a switch, a slider, or
//  the multi-line warning that ADR-0008 requires be shown at all times.
//

import SwiftUI

struct StatusPanel: View {
    @Bindable var monitor: Monitor

    private var state: DisplayState { monitor.display.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            warnings
            Divider().padding(.vertical, 5)
            actions
            errorRow
            Divider().padding(.vertical, 5)
            footer
        }
        .padding(6)
        .frame(width: 268)
    }

    // MARK: - State and why

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tailscale SSH")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let countdown {
                    Text(countdown)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.top, 3)
        .padding(.bottom, 5)
    }

    private var countdown: String? {
        switch state {
        case .active(let remaining): return formatRemaining(remaining)
        case .closing:               return "0:00"
        default:                     return nil
        }
    }

    private var subtitle: String {
        switch state {
        case .off:
            return "Not accepting inbound connections"
        case .active:
            // The countdown is already in the header; this line carries the
            // wall-clock deadline instead, which is what gets acted on.
            guard let session = monitor.session else { return "On" }
            return "On until \(formatExpiry(session.expiresAt))"
        case .closing:
            // Up to 60 seconds pass between the deadline and the actual close.
            // Do not claim it is already shut.
            return "Expired. Closing within 60 seconds"
        case .unmanaged:
            return "Enabled outside Lictor. Closing automatically"
        case .unavailable(let reason):
            return reason
        }
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warnings: some View {
        if !monitor.display.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(monitor.display.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                        Text(text(for: warning))
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
        }
    }

    private func text(for warning: DisplayWarning) -> String {
        switch warning {
        case .operatorMismatch(let expected, let actual):
            let current = actual.map { "\"\($0)\"" } ?? "unset"
            return "Tailscale operator is \(current), expected \"\(expected)\". "
                 + "Lictor cannot toggle SSH in this state."
        case .tailscaleHealth(let items):
            return "Tailscale reports: " + items.joined(separator: " / ")
        }
    }

    // MARK: - Actions

    /// Turning off stays at the top level; every way of keeping SSH open sits one
    /// level down. The hierarchy is not only tidiness -- it keeps the cost on the
    /// dangerous direction (principle 3).
    @ViewBuilder
    private var actions: some View {
        if isSSHOpen(state) {
            MenuRow(title: "Turn off", systemImage: "lock.fill",
                    isEnabled: !monitor.isWorking) {
                Task { await monitor.disable() }
            }
            // Stated unconditionally. Detecting whether a session is live is log
            // parsing and can silently miss (ADR-0004); a warning that comes and goes
            // is worse than one that is always there (ADR-0008).
            MenuRowCaption(text: "Disconnects any SSH session that is connected.")

            if canExtend(state: state, session: monitor.session) {
                MenuDisclosure(title: "Extend by",
                               systemImage: "clock.arrow.circlepath",
                               isEnabled: !monitor.isWorking) {
                    durationRows { duration in
                        Task { await monitor.extend(by: duration) }
                    }
                    MenuRowCaption(text: "Added to the current deadline. Requires Touch ID.")
                }
            }
        } else {
            MenuDisclosure(title: "Enable for",
                           systemImage: "lock.open.fill",
                           isEnabled: !monitor.isWorking && !isUnavailable) {
                durationRows { duration in
                    Task { await monitor.enable(for: duration) }
                }
                // No indefinite option, by design (principle 4).
                MenuRowCaption(text: "Requires Touch ID.")
            }
        }
    }

    /// One list of durations serves both enabling and extending, so the two
    /// cannot drift apart and neither can grow an indefinite option.
    @ViewBuilder
    private func durationRows(_ action: @escaping (SessionDuration) -> Void) -> some View {
        ForEach(SessionDuration.allCases, id: \.rawValue) { duration in
            MenuRow(title: duration.longLabel, isEnabled: !monitor.isWorking) {
                action(duration)
            }
        }
    }

    @ViewBuilder
    private var errorRow: some View {
        if let error = monitor.lastError {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption2)
                Text(error)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.top, 3)
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Last check folded into the row that triggers one, rather than
            // occupying a label-and-value line of its own
            MenuRow(title: "Re-check",
                    systemImage: "arrow.clockwise",
                    trailing: monitor.lastCheck.map { formatExpiry($0) } ?? "never",
                    isEnabled: !monitor.isChecking) {
                Task { await monitor.refresh() }
            }
            MenuRow(title: "Quit Lictor", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
