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

        // O_APPEND, not seek-then-write. FileHandle(forWritingTo:) opens without
        // it, which makes choosing the offset and writing two separate syscalls
        // and lets the agent's own append land in between and be overwritten.
        // O_CREAT here also avoids a createFile() that would truncate a log the
        // agent had just started.
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try? handle.write(contentsOf: line)
    }

    /// Reads the log, newest first. A missing file is an empty history.
    static func read(from url: URL = defaultURL, limit: Int = 500) -> [HistoryEvent] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return HistoryEvent.parse(contents: contents, limit: limit)
    }
}
