//
//  HistoryView.swift
//  lictor
//
//  The history window. A log viewer and nothing else: no editing, no clearing,
//  no filtering. Deleting history.jsonl by hand is the way to clear it.
//
//  It lives in a window rather than in the dropdown because reviewing a list is
//  not the same activity as glancing at a state. The dropdown answers "is SSH
//  open right now"; this answers "was there a session I did not open", which is
//  the question the log exists for.
//

import SwiftUI

struct HistoryView: View {
    @State private var events: [HistoryEvent] = []

    var body: some View {
        VStack(spacing: 0) {
            if events.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock",
                    description: Text("Sessions appear here once SSH has been enabled."))
            } else {
                List(events) { event in
                    HistoryRow(event: event)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(events.isEmpty ? "" : "\(events.count) entries, newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { reload() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 420, minHeight: 300)
        .task { reload() }
    }

    private func reload() {
        events = HistoryStore.read()
    }
}

// MARK: -

private struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)

            Text(timestamp)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 70, alignment: .leading)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d  HH:mm:ss"
        return formatter.string(from: event.at)
    }

    private var title: String {
        switch event.kind {
        case .enabled:  return "Enabled"
        case .extended: return "Extended"
        case .disabled: return "Disabled"
        }
    }

    private var detail: String {
        switch event.kind {
        case .enabled:
            let granted = event.durationSeconds.map { "\($0 / 60) min" }
            let until = event.expiresAt.map { "until \(formatExpiry($0))" }
            return [granted, until].compactMap { $0 }.joined(separator: ", ")
        case .extended:
            return event.expiresAt.map { "until \(formatExpiry($0))" } ?? ""
        case .disabled:
            switch event.reason {
            case .user:      return "turned off manually"
            case .expired:   return "deadline reached"
            case .noState:   return "enabled outside Lictor"
            case .badState:  return "state file was unreadable"
            case nil:        return ""
            }
        }
    }

    private var symbol: String {
        if event.reason?.isAnomalous == true { return "exclamationmark.triangle.fill" }
        switch event.kind {
        case .enabled:  return "lock.open.fill"
        case .extended: return "clock.arrow.circlepath"
        case .disabled: return "lock.fill"
        }
    }

    /// Anomalies are the reason to open this window at all, so they are the only
    /// rows that carry colour.
    private var tint: Color {
        event.reason?.isAnomalous == true ? .orange : .secondary
    }
}
