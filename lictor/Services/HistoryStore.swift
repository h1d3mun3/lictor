//
//  HistoryStore.swift
//  lictor
//
//  Append to and read `~/.local/state/lictor/history.jsonl`.
//
//  Appending uses O_APPEND, where a single small write lands atomically even
//  though the agent may be writing the same file at the same moment. Nothing
//  here ever rewrites existing lines, which is what keeps that guarantee.
//
//  There is no trimming and no clear function. The file is a log: it is deleted
//  by hand if anyone wants it gone. Growth is roughly a few hundred bytes a day,
//  and the viewer caps how much it renders rather than the writer capping what it
//  keeps.
//

import Foundation

nonisolated enum HistoryStore {

    static var defaultURL: URL {
        StateFileStore.defaultDirectory.appendingPathComponent("history.jsonl")
    }

    /// Appends one event. Failure is deliberately silent.
    ///
    /// Callers are on the path that enables or disables SSH, and losing a log
    /// line must never turn into losing the operation (principle 1).
    static func append(_ event: HistoryEvent, to url: URL = defaultURL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let line = Data((event.line() + "\n").utf8)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return          // see the note above: a lost log line is not an error
        }
    }

    /// Reads the log, newest first. A missing file is an empty history.
    static func read(from url: URL = defaultURL, limit: Int = 500) -> [HistoryEvent] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return HistoryEvent.parse(contents: contents, limit: limit)
    }
}
