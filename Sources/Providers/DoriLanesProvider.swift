import Foundation

/// **Yong fork:** the Dori's lanes, as one cell in the notch.
///
/// A lane is a piece of delegated work with a JSON file of its own under
/// `~/.dori/state/lanes`. The cell counts the lanes not yet closed, its arc is
/// the share of them still working, and its colour turns critical when a
/// `REPORT` line in `~/.omo/omomeow/reports.log` has said "사장 필요" (the boss
/// is needed) within the hour. The card lists each open lane by key and title.
///
/// Read-only: neither file is ever written.
enum DoriLanes {
    struct Lane: Equatable {
        let key: String
        let title: String
        let status: String
    }

    struct BossCall: Equatable {
        let line: String
        let at: Date
    }

    static let marker = "사장 필요"
    static let recentFor: TimeInterval = 3600

    static var lanesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dori/state/lanes", isDirectory: true)
    }
    static var reportsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".omo/omomeow/reports.log")
    }

    /// Lanes not closed, by key. A lane file written before the launcher
    /// recorded a status is a lane still working.
    static func openLanes(from files: [Data]) -> [Lane] {
        files.compactMap { data -> Lane? in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = object["key"] as? String else { return nil }
            let status = object["status"] as? String ?? "working"
            guard status != "closed", object["closedAt"] == nil else { return nil }
            return Lane(key: key, title: object["title"] as? String ?? "", status: status)
        }
        .sorted { $0.key < $1.key }
    }

    /// The latest "사장 필요" report in `text`, with when it was made.
    ///
    /// The log's lines carry no time of their own, so a line's time is the
    /// last timestamp written on or before it — a lower bound — and the final
    /// line of the file is as old as the file. Lines this app watches arrive
    /// are dated on arrival instead; see `DoriLanesProvider`.
    static func lastBossCall(in text: String, fileModified: Date) -> BossCall? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var lastStamp: Date?
        var found: BossCall?
        for (index, line) in lines.enumerated() {
            if let stamp = timestamp(in: line) { lastStamp = stamp }
            guard isBossCall(line) else { continue }
            let at = index == lines.count - 1 ? fileModified : lastStamp
            if let at { found = BossCall(line: line, at: at) }
        }
        return found
    }

    static func isBossCall(_ line: String) -> Bool {
        line.hasPrefix("REPORT") && line.contains(marker)
    }

    private static let stampPattern = try! NSRegularExpression(
        pattern: #"(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?"#)

    /// `2026-10-19 15:31:20`, in this Mac's time zone, wherever it appears.
    static func timestamp(in line: String) -> Date? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = stampPattern.matches(in: line, range: range).last else { return nil }
        func part(_ index: Int) -> Int? {
            Range(match.range(at: index), in: line).flatMap { Int(line[$0]) }
        }
        var components = DateComponents()
        components.year = part(1); components.month = part(2); components.day = part(3)
        components.hour = part(4); components.minute = part(5); components.second = part(6) ?? 0
        return Calendar.current.date(from: components)
    }

    static let statusNames = ["working": "작업 중", "done-claimed": "끝 주장",
                              "verified-done": "확인됨", "not-done": "미완"]

    static let listedLanes = 8

    static func windows(lanes: [Lane], bossCall: BossCall?, now: Date) -> [LimitWindow] {
        let working = lanes.filter { $0.status == "working" }.count
        let calling = bossCall.map { now.timeIntervalSince($0.at) < recentFor } ?? false
        let band: UsageBand = calling ? .critical
            : lanes.contains { $0.status == "not-done" } ? .watch : .ample
        let counts = ["working", "done-claimed", "verified-done", "not-done"].compactMap { status -> String? in
            let n = lanes.filter { $0.status == status }.count
            return n == 0 ? nil : "\(statusNames[status] ?? status) \(n)"
        }
        var windows = [LimitWindow(
            id: "lanes", label: "Dori lanes",
            // Short of 1, so a board of working lanes never reads as a spent limit.
            usedFraction: lanes.isEmpty ? 0 : min(Double(working) / Double(lanes.count), 0.99),
            usedText: "\(lanes.count)",
            detail: counts.isEmpty ? "열린 레인 없음" : counts.joined(separator: " · "),
            bandOverride: band, prefersUsedText: true)]
        if calling, let bossCall {
            windows.append(LimitWindow(id: "boss", label: marker,
                                       detail: String(bossCall.line.dropFirst("REPORT ".count).prefix(60)),
                                       bandOverride: .critical))
        }
        for lane in lanes.prefix(listedLanes) {
            windows.append(LimitWindow(id: "lane:\(lane.key)", label: lane.key,
                                       detail: "\(statusNames[lane.status] ?? lane.status) · \(lane.title)"))
        }
        return windows
    }
}

actor DoriLanesProvider: UsageProvider {
    static let providerID = "dori-lanes"
    nonisolated let id = DoriLanesProvider.providerID
    nonisolated let displayName = "Dori lanes"
    nonisolated let glyph = ProviderGlyph.third

    private let lanesDirectory: URL
    private let reportsURL: URL
    private let now: @Sendable () -> Date
    private var readLength: UInt64?
    private var bossCall: DoriLanes.BossCall?

    init(lanesDirectory: URL = DoriLanes.lanesDirectory,
         reportsURL: URL = DoriLanes.reportsURL,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.lanesDirectory = lanesDirectory
        self.reportsURL = reportsURL
        self.now = now
    }

    nonisolated var isVisibleWhenAbsent: Bool { false }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: lanesDirectory.path) else {
            throw UsageProviderError.needsAuth
        }
        let files = names.filter { $0.hasSuffix(".json") }
            .compactMap { try? Data(contentsOf: lanesDirectory.appendingPathComponent($0)) }
        let lanes = DoriLanes.openLanes(from: files)
        readReports()
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok,
            windows: DoriLanes.windows(lanes: lanes, bossCall: bossCall, now: now()),
            headlineID: "lanes")
    }

    /// The whole tail on the first read; after that only what was appended,
    /// dated as it is seen.
    private func readReports() {
        guard let handle = try? FileHandle(forReadingFrom: reportsURL) else { return }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: reportsURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date ?? now()

        if let readLength, readLength <= size {
            guard size > readLength else { return }
            try? handle.seek(toOffset: readLength)
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            if let line = text.split(whereSeparator: \.isNewline).map(String.init).last(where: DoriLanes.isBossCall) {
                bossCall = DoriLanes.BossCall(line: line, at: now())
            }
        } else {
            let tail: UInt64 = 256 * 1024
            try? handle.seek(toOffset: size > tail ? size - tail : 0)
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            bossCall = DoriLanes.lastBossCall(in: text, fileModified: modified)
        }
        readLength = size
    }

    nonisolated func account() -> ProviderAccount? {
        guard FileManager.default.fileExists(atPath: lanesDirectory.path) else { return nil }
        return ProviderAccount(label: "~/.dori/state/lanes", plan: nil, source: "Dori", manageURL: nil)
    }

    nonisolated var signInRoute: SignInRoute { .guidance("Lanes appear when the Dori launches one.") }
    func signOut() async {}
    nonisolated func presentSignIn() {}
    nonisolated func forgetCachedCredential() {}
}
