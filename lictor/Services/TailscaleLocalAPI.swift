//
//  TailscaleLocalAPI.swift
//  lictor
//
//  Reads from the Tailscale LocalAPI. See docs/localapi.md for the measured contract.
//
//  **Read only.** Writes (changing RunSSH) go through the CLI per ADR-0003.
//  Do not add a write method here.
//

import Foundation

nonisolated enum TailscaleLocalAPI {

    /// Default path for the Homebrew formula build of tailscaled (verified on the M1 Max)
    static let defaultSocketPath = "/var/run/tailscaled.socket"

    /// Reads the current state from the LocalAPI.
    ///
    /// Returns `.unreachable` rather than throwing when it cannot connect:
    /// being unable to read is itself a state worth displaying, not a crash.
    ///
    /// - Important: blocks. Call it from a background context.
    static func snapshot(socketPath: String = defaultSocketPath) -> TailscaleSnapshot {
        var snapshot = TailscaleSnapshot.unreachable

        if let prefs = get("/localapi/v0/prefs", socketPath: socketPath),
           let object = try? JSONSerialization.jsonObject(with: prefs) as? [String: Any] {
            snapshot.runSSH = object["RunSSH"] as? Bool
            snapshot.operatorUser = object["OperatorUser"] as? String
        }

        if let status = get("/localapi/v0/status", socketPath: socketPath),
           let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any] {
            snapshot.backendState = object["BackendState"] as? String
            // Health is an array of strings; empty means healthy
            snapshot.health = object["Health"] as? [String] ?? []
        }

        return snapshot
    }

    private static func get(_ path: String, socketPath: String) -> Data? {
        do {
            let response = try UnixSocketHTTP.request(socketPath: socketPath, path: path)
            guard response.status == 200 else { return nil }
            return response.body
        } catch {
            return nil
        }
    }
}
