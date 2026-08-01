//
//  main.swift (interop helper)
//
//  Writes a state.json exactly as the app would, so that the bash agent can be
//  pointed at it. Driven by tests/run-interop.sh.
//
//      interop-writer <state-dir> <duration-seconds> <now-epoch>
//
//  Prints the expiresAt it wrote, for the shell side to compare against.
//

import Foundation

guard CommandLine.arguments.count == 4,
      let durationRaw = Int(CommandLine.arguments[2]),
      let duration = SessionDuration(rawValue: durationRaw),
      let epoch = TimeInterval(CommandLine.arguments[3])
else {
    print("usage: interop-writer <state-dir> <duration-seconds> <now-epoch>")
    exit(2)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let url = directory.appendingPathComponent("state.json")
let now = Date(timeIntervalSince1970: epoch)
let state = SessionState.make(duration: duration, now: now)

do {
    try StateFileStore.write(state, to: url)
} catch {
    print("write failed: \(error)")
    exit(1)
}

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime]
print(formatter.string(from: state.expiresAt))
