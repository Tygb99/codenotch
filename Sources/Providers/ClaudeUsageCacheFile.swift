import Foundation

/// **Yong fork:** the Claude reading this app takes, handed to the terminal.
///
/// On the machine this fork is for, a Claude Code status line also reads the
/// usage endpoint, through its own script, and caches the answer in
/// `~/.claude/statusline/usage-cache.json`. Two readers of one rate-limited
/// endpoint is how the endpoint ends up answering 429 for hours. So this app
/// writes every reading it takes into that same file, in the script's own
/// shape, and the status line reads the file instead of asking again.
///
/// The shape is the script's (`usage_agg.py`):
///
///     {"generated_at": 1792378573,
///      "limits": [{"kind": "session", "model": null, "percent": 6,
///                  "severity": "normal", "resets_at": "2026-10-19T05:50:00.000000+00:00"}]}
///
/// `resets_at` keeps a `+00:00` offset and six fractional digits because the
/// status line runs on Python 3.9, whose `fromisoformat` reads neither `Z` nor
/// three-digit fractions.
struct ClaudeUsageCacheFile: Sendable {
    let url: URL

    /// The status line's lock. Touched on every network attempt this app makes,
    /// so the status line's own five-minute lock also holds it back.
    var lockURL: URL { URL(fileURLWithPath: url.path + ".lock") }

    /// Where the status line keeps it, or nil where there is no status line
    /// directory — another machine, which this fork leaves alone.
    static func statusLine(home: URL = ClaudeProfile.homeDirectory,
                           fileManager: FileManager = .default) -> ClaudeUsageCacheFile? {
        let directory = home.appendingPathComponent(".claude/statusline", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return ClaudeUsageCacheFile(url: directory.appendingPathComponent("usage-cache.json"))
    }

    /// The file's body for these windows. Money windows are left out — the
    /// script never wrote one — and so is any window without a percentage.
    ///
    /// `generated_at` is when this app last confirmed the reading, which is
    /// what the status line's age check means: re-reading Desktop's entry is a
    /// fresh confirmation even when the entry itself is a few minutes old.
    /// When the numbers were actually taken goes in `captured_at`.
    static func payload(windows: [LimitWindow], capturedAt: Date, writtenAt: Date) -> [String: Any] {
        let limits: [[String: Any]] = windows.compactMap { window in
            guard window.money == nil, let fraction = window.usedFraction else { return nil }
            let percent = Int((fraction * 100).rounded())
            return [
                "kind": window.id,
                // The script names the model only for a model-scoped window.
                "model": (window.id == "session" || window.id == "weekly_all")
                    ? NSNull() : window.label as Any,
                "percent": percent,
                // Not in any reading this app takes; derived the way the
                // endpoint was seen to label them (75% came back "warning").
                "severity": percent >= 90 ? "critical" : percent >= 75 ? "warning" : "normal",
                "resets_at": window.resetsAt.map(timestamp) ?? NSNull()
            ]
        }
        return ["generated_at": Int(writtenAt.timeIntervalSince1970),
                "captured_at": Int(capturedAt.timeIntervalSince1970),
                "limits": limits]
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxxxx"
        return formatter.string(from: date)
    }

    /// Writes the reading, atomically, unless the file already holds one taken
    /// later — a Desktop cache entry can be older than what the endpoint last
    /// answered, and the numbers must never go backwards. A file the script
    /// wrote has no `captured_at`; its `generated_at` is the same thing there.
    @discardableResult
    func write(windows: [LimitWindow], capturedAt: Date, writtenAt: Date = Date()) -> Bool {
        let body = Self.payload(windows: windows, capturedAt: capturedAt, writtenAt: writtenAt)
        guard let limits = body["limits"] as? [[String: Any]], !limits.isEmpty else { return false }
        if let held = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: held) as? [String: Any],
           let heldAt = (object["captured_at"] ?? object["generated_at"]) as? Double,
           heldAt > capturedAt.timeIntervalSince1970 {
            return false
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// One line per Claude request and per outcome, in a file of the user's
    /// own: the unified log cannot always be read back on this Mac, and the
    /// fork promises a count of requests. Never a token, only what happened.
    static let logURL = ClaudeProfile.homeDirectory
        .appendingPathComponent("Library/Logs/Codenotch/yong-usage.log")

    static func log(_ message: String, at date: Date = Date()) {
        guard !Runtime.isUnderTest else { return }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let line = Data("\(formatter.string(from: date)) \(message)\n".utf8)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            fileManager.createFile(atPath: logURL.path, contents: line)
        }
    }

    func markAttempt(at date: Date = Date()) {
        let path = lockURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }
}
