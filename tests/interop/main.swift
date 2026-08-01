//
//  main.swift (interop helper)
//
//  Exercises the app's side of the two files it shares with the bash agent, so
//  tests/run-interop.sh can point the agent at the result.
//
//      interop write-state   <state-dir> <duration-seconds> <now-epoch>
//      interop read-history  <history-path>
//
//  write-state prints the expiresAt it wrote; read-history prints one
//  "kind|reason" line per entry, newest first.
//

import Foundation

func fail(_ message: String) -> Never {
    print(message)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else {
    fail("usage: interop <write-state|read-history> ...")
}

switch mode {

case "write-state":
    guard arguments.count == 4,
          let durationRaw = Int(arguments[2]),
          let duration = SessionDuration(rawValue: durationRaw),
          let epoch = TimeInterval(arguments[3])
    else { fail("usage: interop write-state <state-dir> <duration-seconds> <now-epoch>") }

    let url = URL(fileURLWithPath: arguments[1], isDirectory: true)
        .appendingPathComponent("state.json")
    let state = SessionState.make(duration: duration,
                                  now: Date(timeIntervalSince1970: epoch))

    do {
        try StateFileStore.write(state, to: url)
    } catch {
        fail("write failed: \(error)")
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    print(formatter.string(from: state.expiresAt))

case "read-history":
    guard arguments.count == 2 else {
        fail("usage: interop read-history <history-path>")
    }

    let events = HistoryStore.read(from: URL(fileURLWithPath: arguments[1]))
    for event in events {
        print("\(event.kind.rawValue)|\(event.reason?.rawValue ?? "-")")
    }

default:
    fail("unknown mode: \(mode)")
}
