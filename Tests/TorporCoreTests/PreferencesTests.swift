import Foundation
import Testing
@testable import Torpor

@Suite struct PreferencesTests {

    /// A realistic `preferences.json`: the encoded defaults with `overrides`
    /// applied. That is the exact shape `Preferences.load` feeds the decoder,
    /// and it matters — the synthesized `init(from:)` ignores the properties'
    /// default values, so a partial object would fail for reasons that have
    /// nothing to do with what a test is asking about.
    private func decode(overriding overrides: [String: Any]) throws -> Preferences {
        let encoded = try JSONEncoder().encode(Preferences())
        var merged = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, value) in overrides { merged[key] = value }
        return try JSONDecoder().decode(
            Preferences.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    // MARK: - The menu bar metric migration

    /// `memory`, `highest` and `model` were real choices in shipped builds, so
    /// those strings are sitting in the preferences file of everyone who picked
    /// one. Losing a setting to a rename is a migration we owe the user.
    @Test(arguments: ["memory", "highest", "model", "", "fiveHourOrSevenDay", "nonsense"])
    func aRemovedOrUnknownMenuBarMetricLandsOnFiveHour(_ raw: String) throws {
        let decoded = try JSONDecoder().decode(
            MenuBarMetric.self, from: Data("\"\(raw)\"".utf8))
        #expect(decoded == .fiveHour)
    }

    @Test func theSurvivingMenuBarMetricsStillDecodeAsThemselves() throws {
        #expect(try JSONDecoder().decode(MenuBarMetric.self,
                                         from: Data(#""fiveHour""#.utf8)) == .fiveHour)
        #expect(try JSONDecoder().decode(MenuBarMetric.self,
                                         from: Data(#""sevenDay""#.utf8)) == .sevenDay)
        // Round-trips, so the lenient reader has not quietly changed what is
        // written back out.
        for metric in MenuBarMetric.allCases {
            let blob = try JSONEncoder().encode(metric)
            #expect(try JSONDecoder().decode(MenuBarMetric.self, from: blob) == metric)
        }
    }

    /// The point of the hand-written initializer: one stale value costs that
    /// setting, not the rest of the file.
    @Test func anUnknownMetricDoesNotCostTheOtherSettingsInTheSameFile() throws {
        let preferences = try decode(overriding: [
            "menuBarMetric": "memory",
            "groupByProject": false,
            "pollSeconds": 11,
            "notifyQuotaPercent": 65,
            "hiddenUsageRows": ["Sonnet"],
            "authMode": "pastedToken",
        ])
        #expect(preferences.menuBarMetric == .fiveHour)
        #expect(preferences.groupByProject == false)
        #expect(preferences.pollSeconds == 11)
        #expect(preferences.notifyQuotaPercent == 65)
        #expect(preferences.hiddenUsageRows == ["Sonnet"])
        #expect(preferences.authMode == .pastedToken)
    }

    /// The other appearance enums have no migration of their own — a value a
    /// later build removed fails their decode, and `Preferences.load` recovers
    /// by restoring that one key and retrying. Recorded so that nobody deletes
    /// `MenuBarMetric.init(from:)` believing the retry loop already covers it:
    /// it does, but only as a side effect of corrupt-file machinery.
    @Test func theOtherAppearanceEnumsRelyOnLoadsRetryLoopInstead() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MenuBarStyle.self, from: Data(#""logo""#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ColorMode.self, from: Data(#""rainbow""#.utf8))
        }
    }

    // MARK: - The consent gate

    /// Live network calls must never become reachable without the per-mode
    /// acknowledgement. This is a consent gate, not a preference.
    @Test func liveFetchStaysForbiddenUntilTheSelectedModeIsAcknowledged() {
        var preferences = Preferences()
        #expect(preferences.liveFetchPermitted == false)

        for mode in [AuthMode.cliCredentials, .pastedToken] {
            preferences.authMode = mode
            preferences.acknowledgedRiskModes = []
            #expect(preferences.liveFetchPermitted == false)

            // Acknowledging one mode must not pre-acknowledge another.
            preferences.acknowledgedRiskModes = [mode == .pastedToken ? .cliCredentials
                                                                      : .pastedToken]
            #expect(preferences.liveFetchPermitted == false)

            preferences.acknowledgedRiskModes = [mode]
            #expect(preferences.liveFetchPermitted == true)
        }

        preferences.authMode = .statusline
        preferences.acknowledgedRiskModes = Set(AuthMode.allCases)
        #expect(preferences.liveFetchPermitted == false,
                "the credential-free mode never makes a network call")

        preferences.authMode = .consoleAPIKey
        preferences.consoleUsageEnabled = false
        #expect(preferences.liveFetchPermitted == false)
        preferences.consoleUsageEnabled = true
        #expect(preferences.liveFetchPermitted == true)
    }

    /// Defaulting the acknowledgement set non-empty anywhere — including in a
    /// migration — would defeat the point of showing the disclosure.
    @Test func aFileThatNamesARiskyModeStillCarriesNoAcknowledgement() throws {
        let preferences = try decode(overriding: ["authMode": "cliCredentials"])
        #expect(preferences.acknowledgedRiskModes.isEmpty)
        #expect(preferences.liveFetchPermitted == false)
    }

    // MARK: - Round trip

    /// What `save()` writes, `load()` must read back unchanged.
    @Test func everySettingSurvivesAnEncodeDecodeRoundTrip() throws {
        var preferences = Preferences()
        preferences.authMode = .pastedToken
        preferences.acknowledgedRiskModes = [.pastedToken]
        preferences.hiddenUsageRows = ["Sonnet", "Fable"]
        preferences.menuBarMetric = .sevenDay
        preferences.menuBarStyle = .percentage
        preferences.memoryFigure = .reclaimable
        preferences.timeMarker = .both
        preferences.colorMode = .monochrome
        preferences.hideWhenIdle = true
        preferences.launchAtLogin = true
        preferences.autoHibernateEnabled = true
        preferences.pollSeconds = 9

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let back = try JSONDecoder().decode(Preferences.self, from: encoder.encode(preferences))

        #expect(back.authMode == .pastedToken)
        #expect(back.acknowledgedRiskModes == [.pastedToken])
        #expect(back.hiddenUsageRows == ["Sonnet", "Fable"])
        #expect(back.menuBarMetric == .sevenDay)
        #expect(back.menuBarStyle == .percentage)
        #expect(back.memoryFigure == .reclaimable)
        #expect(back.timeMarker == .both)
        #expect(back.colorMode == .monochrome)
        #expect(back.hideWhenIdle == true)
        #expect(back.launchAtLogin == true)
        #expect(back.autoHibernateEnabled == true)
        #expect(back.pollSeconds == 9)
        #expect(back.liveFetchPermitted == true)
    }
}
