//
//  MenuBarLabel.swift
//  lictor
//
//  The always-visible menu bar item. Display spec: docs/principles.md, display rules.
//
//  Design notes:
//   - **Never hide the icon when SSH is off.** You cannot notice an absence.
//     Off should be quiet, not invisible.
//   - **Render the countdown as text.** A static icon dissolves into the
//     background within days; a decreasing number does not.
//   - While the deadline has passed but RunSSH is still true, do not claim the
//     session is closed -- up to 60 seconds remain.
//

import SwiftUI

struct MenuBarLabel: View {
    let display: Display

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if let text = trailingText {
                Text(text)
                    .monospacedDigit()
            }
        }
    }

    private var symbolName: String {
        // Menu bar labels are drawn as template images, so colour is a weak
        // signal. Distinguish by shape and by fill instead.
        switch display.state {
        case .off:
            return "lock"                       // thin outline; the resting state
        case .active:
            return "lock.open.fill"             // filled; currently open
        case .closing:
            return "lock.open"                  // waiting for the agent to close it
        case .unmanaged:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "questionmark.circle"
        }
    }

    private var trailingText: String? {
        switch display.state {
        case .off:
            return nil                          // keep the resting state maximally quiet
        case .active(let remaining):
            return formatRemaining(remaining)
        case .closing:
            return "0:00"
        case .unmanaged:
            return "?"
        case .unavailable:
            return nil
        }
    }
}
