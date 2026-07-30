import Foundation
import Testing
@testable import Torpor

/// Parsing `/api/oauth/usage`.
///
/// The per-model rows went missing for three separate reasons at once, and none
/// of them failed loudly: the reader looked for a `name` or `model` string on
/// each entry (the name is nested two levels down under `scope`), it looked for
/// `utilization` where entries carry `percent`, and it parsed `resets_at` with a
/// formatter that returns nil for six fractional digits. Every one of those
/// degrades to "absent" by design, so the bar simply never appeared.
///
/// The fixture is a real response captured on 2026-07-30, trimmed only of the
/// account's spend figures.
@Suite struct SubscriptionUsageTests {

    static let live = """
    {
      "five_hour": {"utilization": 9.0, "resets_at": "2026-07-30T07:59:59.464866+00:00",
                    "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
      "seven_day": {"utilization": 83.0, "resets_at": "2026-08-02T00:00:00.464888+00:00",
                    "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
      "seven_day_oauth_apps": null,
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "seven_day_cowork": null,
      "seven_day_omelette": null,
      "tangelo": null,
      "iguana_necktie": null,
      "nimbus_quill": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null,
                      "utilization": null, "user_disabled": true, "spend_limit_reached": false},
      "limits": [
        {"kind": "session", "group": "session", "percent": 9, "severity": "normal",
         "resets_at": "2026-07-30T07:59:59.464866+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 83, "severity": "warning",
         "resets_at": "2026-08-02T00:00:00.464888+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 12, "severity": "normal",
         "resets_at": "2026-08-02T00:00:00.465116+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
         "is_active": false}
      ],
      "member_dashboard_available": false
    }
    """

    private func parse(_ json: String) throws -> QuotaSnapshot {
        try UsageAPI.parseSubscription(Data(json.utf8)).0
    }

    // MARK: - The row that was missing

    @Test func aModelScopedWeeklyRowBecomesAGauge() throws {
        let snapshot = try parse(Self.live)
        #expect(snapshot.scoped["Fable"]?.usedPercentage == 12,
                "the Fable row lives at limits[].scope.model.display_name, not at limits[].name")
    }

    @Test func theScopedRowKeepsItsOwnResetTime() throws {
        let snapshot = try parse(Self.live)
        #expect(snapshot.scoped["Fable"]?.resetsAt != nil,
                "six fractional digits must not cost the whole timestamp")
    }

    /// The server still sends the previous shape's keys as explicit nulls. They
    /// must not become empty gauges labelled "Opus" and "Sonnet".
    @Test func nullLegacyKeysDoNotBecomeRows() throws {
        let snapshot = try parse(Self.live)
        #expect(snapshot.scoped.count == 1)
        #expect(snapshot.scoped["Opus"] == nil)
        #expect(snapshot.scoped["Sonnet"] == nil)
        #expect(snapshot.scoped["Oauth apps"] == nil)
    }

    // MARK: - The two headline windows

    @Test func bothTopLevelWindowsParse() throws {
        let snapshot = try parse(Self.live)
        #expect(snapshot.fiveHour?.usedPercentage == 9)
        #expect(snapshot.sevenDay?.usedPercentage == 83)
        #expect(snapshot.fiveHour?.resetsAt != nil)
        #expect(snapshot.sevenDay?.resetsAt != nil)
    }

    /// If the top-level windows are ever dropped in favour of the array alone,
    /// the session and weekly_all entries carry the same numbers.
    @Test func theLimitsArrayAloneStillYieldsBothWindows() throws {
        let arrayOnly = """
        {"limits": [
          {"kind": "session", "percent": 9, "resets_at": "2026-07-30T07:59:59.464866+00:00"},
          {"kind": "weekly_all", "percent": 83, "resets_at": "2026-08-02T00:00:00.464888+00:00"}
        ]}
        """
        let snapshot = try parse(arrayOnly)
        #expect(snapshot.fiveHour?.usedPercentage == 9)
        #expect(snapshot.sevenDay?.usedPercentage == 83)
    }

    // MARK: - Shapes that must not throw the whole refresh away

    @Test func anUnrecognisedKindIsSkippedWithoutLosingTheRest() throws {
        let withFuture = """
        {"limits": [
          {"kind": "weekly_all", "percent": 40, "resets_at": "2026-08-02T00:00:00.1+00:00"},
          {"kind": "monthly_something_new", "percent": 5},
          {"kind": "weekly_scoped", "percent": 7,
           "scope": {"model": {"display_name": "Nimbus"}}}
        ]}
        """
        let snapshot = try parse(withFuture)
        #expect(snapshot.sevenDay?.usedPercentage == 40)
        #expect(snapshot.scoped["Nimbus"]?.usedPercentage == 7)
        #expect(snapshot.scoped.count == 1)
    }

    /// A nameless scoped row is dropped, and dropping it does not cost the
    /// windows that parsed alongside it.
    @Test func aScopedRowWithNoModelNameIsSkippedRatherThanLabelledEmpty() throws {
        let nameless = """
        {"limits": [
          {"kind": "weekly_all", "percent": 40},
          {"kind": "weekly_scoped", "percent": 7, "scope": {"model": {"id": null}}},
          {"kind": "weekly_scoped", "percent": 8, "scope": null}
        ]}
        """
        let snapshot = try parse(nameless)
        #expect(snapshot.scoped.isEmpty)
        #expect(snapshot.sevenDay?.usedPercentage == 40)
    }

    /// A payload carrying nothing recognisable throws, so a shape change reads
    /// as an error rather than as an account that has used nothing.
    @Test func aPayloadOfOnlyNamelessRowsThrows() {
        #expect(throws: (any Error).self) {
            _ = try parse("""
            {"limits": [{"kind": "weekly_scoped", "percent": 7, "scope": null}]}
            """)
        }
    }

    @Test func percentSurvivesArrivingAsAnIntegerOrAFraction() throws {
        let mixed = """
        {"limits": [
          {"kind": "weekly_all", "percent": 83},
          {"kind": "weekly_scoped", "percent": 12.5, "scope": {"model": {"display_name": "Fable"}}}
        ]}
        """
        let snapshot = try parse(mixed)
        #expect(snapshot.sevenDay?.usedPercentage == 83)
        #expect(snapshot.scoped["Fable"]?.usedPercentage == 12.5)
    }

    @Test(arguments: [
        "2026-08-02T00:00:00.465116+00:00",   // six digits, what the server sends
        "2026-08-02T00:00:00.465+00:00",      // three
        "2026-08-02T00:00:00+00:00",          // none
        "2026-08-02T00:00:00Z",               // Zulu
    ])
    func everyTimestampShapeTheEndpointHasSentParses(_ text: String) throws {
        let json = """
        {"limits": [{"kind": "weekly_all", "percent": 50, "resets_at": "\(text)"}]}
        """
        #expect(try parse(json).sevenDay?.resetsAt != nil, "failed on \(text)")
    }

    @Test func aPayloadWithNoLimitsAtAllThrowsRatherThanReportingZero() throws {
        #expect(throws: (any Error).self) {
            _ = try parse("""
            {"member_dashboard_available": false, "seven_day_opus": null}
            """)
        }
    }

    // MARK: - Identification

    /// The header used to be `claude-code/<version>`, scraped from the installed
    /// CLI. Anthropic's anti-spoofing work targeted exactly that, and the live
    /// endpoint answers 200 to a request that says what it is, so the disguise
    /// bought nothing. Pinned so it cannot come back by accident.
    @Test func torporIdentifiesItselfAsItself() {
        let agent = UsageAPI.userAgent
        #expect(agent.hasPrefix("Torpor/"))
        #expect(!agent.lowercased().contains("claude"))
    }
}
