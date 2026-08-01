//
//  main.swift (socket tests)
//
//  Exercises UnixSocketHTTP and TailscaleLocalAPI against a fake LocalAPI server.
//
//      bash tests/run-socket.sh
//
//  Covers sockaddr_un construction, request formatting and response parsing.
//  When this breaks, the app silently reports "state unavailable" forever.
//

import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: socket-tests <socket-path> [framing]")
    exit(2)
}
let socketPath = CommandLine.arguments[1]
let framing = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "length"

var passed = 0
var failed = 0

func check<T: Equatable>(_ name: String, _ want: T, _ got: T) {
    if want == got {
        passed += 1
        print("  ok    \(name)")
    } else {
        failed += 1
        print("  FAIL  \(name)")
        print("        want = \(want)")
        print("        got  = \(got)")
    }
}

// The framing suites run against a server started in one specific mode, so they
// only assert the thing that mode is there to prove.
if framing != "length" {
    print("=== framing: \(framing) ===")

    if framing == "slam" {
        // A peer that closes without reading raises SIGPIPE on write. Reaching
        // this line at all means the signal was suppressed; the process would
        // otherwise have died of signal 13 before printing anything.
        do {
            _ = try UnixSocketHTTP.request(socketPath: socketPath, path: "/localapi/v0/prefs")
            failed += 1
            print("  FAIL  a slammed connection should not look like a valid response")
        } catch {
            passed += 1
            print("  ok    a peer that closes without reading throws instead of killing us")
        }
    } else {
        // Both of these carry the same JSON. A client that ignores framing gets
        // chunk-size lines mixed into it and silently parses nothing.
        let snapshot = TailscaleLocalAPI.snapshot(socketPath: socketPath)
        check("BackendState survives \(framing) framing", "Running", snapshot.backendState)
        check("RunSSH survives \(framing) framing", true, snapshot.runSSH)
    }

    print("\n────────────────────────────────")
    print("  PASS \(passed) / FAIL \(failed)")
    print("────────────────────────────────")
    exit(failed == 0 ? 0 : 1)
}

print("=== UnixSocketHTTP ===")

// 1. Happy path
do {
    let response = try UnixSocketHTTP.request(socketPath: socketPath, path: "/localapi/v0/prefs")
    check("parses a 200", 200, response.status)
    let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    check("body decodes as JSON", true, json?["RunSSH"] as? Bool)
    check("reads the whole body", true, response.body.count > 20)
} catch {
    failed += 1
    print("  FAIL  happy path threw: \(error)")
}

// 2. 404
do {
    let response = try UnixSocketHTTP.request(socketPath: socketPath, path: "/localapi/v0/nope")
    check("parses a 404", 404, response.status)
} catch {
    failed += 1
    print("  FAIL  404 case threw: \(error)")
}

// 3. Wrong Host gets 403 (matches the measurement in docs/localapi.md §2)
do {
    let response = try UnixSocketHTTP.request(
        socketPath: socketPath, path: "/localapi/v0/prefs", host: "example.com")
    check("wrong Host is rejected with 403", 403, response.status)
} catch {
    failed += 1
    print("  FAIL  Host validation threw: \(error)")
}

// 4. Missing socket throws instead of hanging
do {
    _ = try UnixSocketHTTP.request(socketPath: "/tmp/lictor-no-such.sock", path: "/")
    failed += 1
    print("  FAIL  missing socket did not throw")
} catch let error as UnixSocketHTTPError {
    if case .connectionFailed = error {
        passed += 1
        print("  ok    missing socket -> connectionFailed")
    } else {
        failed += 1
        print("  FAIL  unexpected error: \(error)")
    }
} catch {
    failed += 1
    print("  FAIL  unexpected error: \(error)")
}

// 5. Over-long paths are rejected before connecting
do {
    _ = try UnixSocketHTTP.request(
        socketPath: String(repeating: "a", count: 200), path: "/")
    failed += 1
    print("  FAIL  over-long path did not throw")
} catch let error as UnixSocketHTTPError {
    if case .pathTooLong = error {
        passed += 1
        print("  ok    over-long path -> pathTooLong")
    } else {
        failed += 1
        print("  FAIL  unexpected error: \(error)")
    }
} catch {
    failed += 1
    print("  FAIL  unexpected error: \(error)")
}

print("\n=== TailscaleLocalAPI ===")

let snapshot = TailscaleLocalAPI.snapshot(socketPath: socketPath)
check("reads RunSSH",       true,      snapshot.runSSH)
check("reads OperatorUser", "tester",  snapshot.operatorUser)
check("reads BackendState", "Running", snapshot.backendState)
check("reads Health",       [],        snapshot.health)

let unreachable = TailscaleLocalAPI.snapshot(socketPath: "/tmp/lictor-no-such.sock")
check("unreachable daemon yields .unreachable rather than throwing",
      TailscaleSnapshot.unreachable, unreachable)

print("\n────────────────────────────────")
print("  PASS \(passed) / FAIL \(failed)")
print("────────────────────────────────")
exit(failed == 0 ? 0 : 1)
