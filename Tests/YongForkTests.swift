import XCTest
@testable import Codenotch

/// The yong fork's additions: the Claude reading shared with the status line,
/// the opencodex accounts, and the Dori's lanes.
final class YongForkTests: XCTestCase {

    // MARK: - Claude usage shared with the status line

    private func temporaryCache() throws -> ClaudeUsageCacheFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YongForkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ClaudeUsageCacheFile(url: directory.appendingPathComponent("usage-cache.json"))
    }

    func testThePayloadHasTheStatusLineScriptsShape() throws {
        let reset = Date(timeIntervalSince1970: 1_792_389_000)
        let windows = [
            LimitWindow(id: "session", label: "Current session", usedFraction: 0.06, resetsAt: reset),
            LimitWindow(id: "weekly_scoped", label: "Fable", usedFraction: 0.04, resetsAt: reset),
            LimitWindow(id: "spend", label: "Spend limit", usedFraction: 0.1,
                        money: UsageMoneyBreakdown(currency: "USD", spent: 1, remaining: 9))
        ]
        let body = ClaudeUsageCacheFile.payload(windows: windows, capturedAt: Date(timeIntervalSince1970: 100),
                                                writtenAt: Date(timeIntervalSince1970: 160))
        XCTAssertEqual(body["generated_at"] as? Int, 160)
        XCTAssertEqual(body["captured_at"] as? Int, 100)
        let limits = try XCTUnwrap(body["limits"] as? [[String: Any]])
        XCTAssertEqual(limits.map { $0["kind"] as? String }, ["session", "weekly_scoped"])
        XCTAssertTrue(limits[0]["model"] is NSNull)
        XCTAssertEqual(limits[1]["model"] as? String, "Fable")
        XCTAssertEqual(limits[0]["percent"] as? Int, 6)
        XCTAssertEqual(limits[0]["severity"] as? String, "normal")
        XCTAssertEqual(limits[0]["resets_at"] as? String, "2026-10-19T05:50:00.000000+00:00")
    }

    func testTheFileIsNeverWoundBack() throws {
        let cache = try temporaryCache()
        let window = [LimitWindow(id: "session", label: "Current session", usedFraction: 0.5)]
        XCTAssertTrue(cache.write(windows: window, capturedAt: Date(timeIntervalSince1970: 200),
                                  writtenAt: Date(timeIntervalSince1970: 300)))
        XCTAssertFalse(cache.write(windows: window, capturedAt: Date(timeIntervalSince1970: 100),
                                   writtenAt: Date(timeIntervalSince1970: 400)))
        // The same reading confirmed again moves `generated_at`, so the status
        // line's age check sees a live source.
        XCTAssertTrue(cache.write(windows: window, capturedAt: Date(timeIntervalSince1970: 200),
                                  writtenAt: Date(timeIntervalSince1970: 500)))
        let held = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.url)) as? [String: Any]
        XCTAssertEqual(held?["generated_at"] as? Int, 500)
        XCTAssertEqual(held?["captured_at"] as? Int, 200)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func add() { lock.lock(); value += 1; lock.unlock() }
    }

    /// Two live looks inside two minutes are one `claude /usage`, and the
    /// reading lands in the status line's file.
    func testLiveLooksShareOneNetworkReadingAndTheFileGetsIt() async throws {
        let cache = try temporaryCache()
        let calls = Calls()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d 'at' h:mma"
        let reset = formatter.string(from: Date().addingTimeInterval(2 * 86400)).lowercased()
        let cli = ClaudeUsageCLI(binary: URL(fileURLWithPath: "/usr/bin/true")) { _ in
            calls.add()
            return "Current session: 38% used · resets \(reset) (UTC)\n"
        }
        let suite = "YongForkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let provider = ClaudeOAuthProvider(archive: UsageArchive(defaults: defaults),
                                           loadCredentials: { throw UsageProviderError.needsAuth },
                                           cli: cli,
                                           liveCLIRefreshInterval: 0,
                                           desktopCache: nil,
                                           minNetworkInterval: 2 * 60,
                                           usageCacheFile: cache)

        _ = try await provider.fetchSnapshot(freshness: .live)
        let second = try await provider.fetchSnapshot(freshness: .live)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(second.headline?.usedFraction ?? -1, 0.38, accuracy: 0.0001)
        let held = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.url)) as? [String: Any]
        let limits = try XCTUnwrap(held?["limits"] as? [[String: Any]])
        XCTAssertEqual(limits.first?["percent"] as? Int, 38)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.lockURL.path))
    }

    // MARK: - opencodex accounts

    func testAPassedResetReadsAsNothingUsed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let windows = OpenCodexAccounts.windows(quota: [
            "shortPercent": 40, "shortResetAt": 999_000, "shortWindowSeconds": 18000,
            "weeklyPercent": 12, "weeklyResetAt": 1_100_000
        ], now: now)
        XCTAssertEqual(windows.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(windows[0].usedFraction, 0)
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.12, accuracy: 0.0001)
    }

    func testOnlyTheFirstFourCharactersOfAnAddressShow() {
        XCTAssertEqual(OpenCodexAccounts.masked("someone@example.com"), "some**")
        XCTAssertEqual(OpenCodexAccounts.masked(nil), "?")
    }

    // MARK: - The Dori's lanes

    func testClosedLanesAreLeftOutAndAMissingStatusIsWorking() {
        let files = [
            #"{"key":"b-lane","title":"B","status":"done-claimed"}"#,
            #"{"key":"a-lane","title":"A"}"#,
            #"{"key":"old","title":"Old","status":"closed","closedAt":"2026-10-19T06:44:35Z"}"#
        ].map { Data($0.utf8) }
        XCTAssertEqual(DoriLanes.openLanes(from: files), [
            DoriLanes.Lane(key: "a-lane", title: "A", status: "working"),
            DoriLanes.Lane(key: "b-lane", title: "B", status: "done-claimed")
        ])
    }

    func testABossCallIsDatedByTheLastTimestampBeforeIt() throws {
        let log = """
        REPORT [블로그] 시작 2026-10-19 15:31:20
        REPORT [블로그] 사장 필요: 로그인
        REPORT [블로그] 이정표 1/2
        """
        let modified = Date()
        let call = try XCTUnwrap(DoriLanes.lastBossCall(in: log, fileModified: modified))
        XCTAssertEqual(call.line, "REPORT [블로그] 사장 필요: 로그인")
        XCTAssertEqual(call.at, DoriLanes.timestamp(in: "2026-10-19 15:31:20"))

        let last = try XCTUnwrap(DoriLanes.lastBossCall(in: "REPORT [x] 사장 필요: y", fileModified: modified))
        XCTAssertEqual(last.at, modified)
    }

    func testARecentBossCallTurnsTheCellCritical() {
        let now = Date()
        let lanes = [DoriLanes.Lane(key: "k", title: "T", status: "working")]
        let quiet = DoriLanes.windows(lanes: lanes, bossCall: nil, now: now)
        XCTAssertEqual(quiet.first?.bandOverride, .ample)
        XCTAssertEqual(quiet.first?.usedText, "1")
        XCTAssertEqual(quiet.map(\.id), ["lanes", "lane:k"])

        let call = DoriLanes.BossCall(line: "REPORT [k] 사장 필요: 승인", at: now.addingTimeInterval(-60))
        let calling = DoriLanes.windows(lanes: lanes, bossCall: call, now: now)
        XCTAssertEqual(calling.first?.bandOverride, .critical)
        XCTAssertEqual(calling.map(\.id), ["lanes", "boss", "lane:k"])

        let stale = DoriLanes.BossCall(line: call.line, at: now.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(DoriLanes.windows(lanes: lanes, bossCall: stale, now: now).first?.bandOverride, .ample)
    }
}
