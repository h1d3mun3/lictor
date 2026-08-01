//
//  StateFileStore.swift
//  lictor
//
//  Reads and writes `~/.local/state/lictor/state.json`.
//  The contract lives in docs/principles.md and agent/dev-enable.sh.
//
//  Writes are atomic (temp file plus rename) and mode 0600. The agent may read
//  this file at any moment, so it must never observe a partial write.
//

import Foundation

nonisolated enum StateFileStoreError: Error, CustomStringConvertible {
    case encodingFailed
    case writeFailed(String)

    var description: String {
        switch self {
        case .encodingFailed:        return "Could not serialise the session state"
        case .writeFailed(let text): return "Could not write the state file: \(text)"
        }
    }
}

nonisolated enum StateFileStore {

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/state/lictor", isDirectory: true)
    }

    static var defaultURL: URL {
        defaultDirectory.appendingPathComponent("state.json")
    }

    /// Reads state.json.
    ///
    /// **No file means no active session** (docs/principles.md).
    /// A corrupt file also yields nil: the agent fails safe and cleans it up,
    /// so the app can simply treat it as absent.
    static func read(from url: URL = defaultURL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SessionState.decode(from: data)
    }

    /// Writes state.json atomically with mode 0600.
    ///
    /// The temp file is created in the same directory so that `rename` stays
    /// within one filesystem and is therefore atomic.
    static func write(_ state: SessionState, to url: URL = defaultURL) throws {
        guard let data = SessionState.encode(state) else {
            throw StateFileStoreError.encodingFailed
        }

        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".state.\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])

            // createDirectory only applies attributes to directories it creates,
            // so an existing directory keeps whatever mode it had. Set it every
            // time, matching what the agent does on each tick.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)

            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporary.path)

            // Replaces any existing file in one step; a reader sees old or new,
            // never a truncated file.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw StateFileStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Removes state.json. Absence is success, not an error.
    static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
