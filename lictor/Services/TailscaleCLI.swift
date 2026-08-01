//
//  TailscaleCLI.swift
//  lictor
//
//  Writes RunSSH by invoking the tailscale CLI.
//
//  Per ADR-0003 the app reads through the LocalAPI but writes through the CLI:
//  `tailscale set` performs a check-prefs validation pass that a raw PATCH skips,
//  and it keeps the app on the same code path as the launchd agent.
//
//  **This blocks.** Call it off the main thread.
//

import Foundation

nonisolated enum TailscaleCLIError: Error, CustomStringConvertible {
    case binaryNotFound
    case failed(status: Int32, message: String)

    var description: String {
        switch self {
        case .binaryNotFound:
            return "Could not find the tailscale binary"
        case .failed(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "tailscale exited with status \(status)"
                : detail
        }
    }
}

nonisolated enum TailscaleCLI {

    /// launchd and app bundles do not inherit a shell PATH, so the binary is
    /// located explicitly rather than resolved from the environment.
    static let candidatePaths = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static func resolveBinary() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func setSSH(_ enabled: Bool) throws {
        guard let binary = resolveBinary() else {
            throw TailscaleCLIError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["set", "--ssh=\(enabled)"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        // Read before waiting so a chatty failure cannot fill the pipe and deadlock
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TailscaleCLIError.failed(
                status: process.terminationStatus,
                message: String(data: errorData, encoding: .utf8) ?? ""
            )
        }
    }
}
