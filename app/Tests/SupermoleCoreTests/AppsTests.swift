import XCTest
@testable import SupermoleCore

final class AppsTests: XCTestCase {
    private func fixture<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try MoleJSON.decode(type, from: Data(contentsOf: url))
    }

    func testTheListReadsRawSizesAndLastUseAndLeavesUnknownsEmpty() throws {
        let apps = try fixture([InstalledApp].self, "installed_apps")

        XCTAssertEqual(apps[0].bytes, 184320 * 1024)
        XCTAssertEqual(apps[0].lastUsed, Date(timeIntervalSince1970: 1790000000))
        XCTAssertTrue(apps[1].isHomebrew)
        XCTAssertNil(apps[2].bytes)
        XCTAssertNil(apps[2].lastUsed)
        XCTAssertTrue(InstalledApps.lacksSizes(apps))
        XCTAssertEqual(InstalledApp.arguments, ["uninstall", "--list"])
    }

    func testOrdersPutUnknownValuesLastAndTiesByName() throws {
        let apps = try fixture([InstalledApp].self, "installed_apps")

        XCTAssertEqual(InstalledApps.arranged(apps, matching: "", by: .size).map(\.name), ["atlas", "Slack", "Maccy", "Cold Start"])
        XCTAssertEqual(InstalledApps.arranged(apps, matching: "", by: .lastUsed).map(\.name), ["Maccy", "atlas", "Slack", "Cold Start"])
        XCTAssertEqual(InstalledApps.arranged(apps, matching: "", by: .name).map(\.name), ["atlas", "Cold Start", "Maccy", "Slack"])
    }

    func testSearchMatchesAnyPartOfTheNameWhateverTheCase() throws {
        let apps = try fixture([InstalledApp].self, "installed_apps")

        XCTAssertEqual(InstalledApps.arranged(apps, matching: " ACC ", by: .name).map(\.name), ["Maccy"])
        XCTAssertTrue(InstalledApps.arranged(apps, matching: "zzz", by: .name).isEmpty)
    }

    func testThePlanSumsWhatEachAppRemovesAndSplitsOffAdminApps() throws {
        let plan = try fixture(UninstallPlan.self, "uninstall_plan")
        let slack = try XCTUnwrap(plan.apps.first)

        // Bundle, cache and removed personal data; review-only rows stay.
        XCTAssertEqual(slack.bytes, (184320 + 2048 + 1024) * 1024)
        XCTAssertEqual(slack.removedRows.map(\.path).last, "/Users/test/Library/Preferences/com.example.slack.plist")
        XCTAssertEqual(slack.personalData.keep.map(\.path), ["/Users/test/Library/Group Containers/group.com.example.slack"])
        XCTAssertTrue(slack.running)
        XCTAssertEqual(plan.appsWithoutAdmin.map(\.name), ["Slack"])
        XCTAssertEqual(plan.appsNeedingAdmin.map(\.homebrewCask), ["maccy"])
        XCTAssertEqual(plan.blocked.map(\.vendor), ["Acme"])
        XCTAssertEqual(plan.manual.map(\.name), ["Odd App"])
        XCTAssertTrue(plan.withData)
    }

    func testThePreviewAndTheRunNameTheSameAppsByPath() throws {
        let paths = ["/Applications/Slack.app", "/Users/test/Applications/Cold Start.app"]
        let plan = try fixture(UninstallPlan.self, "uninstall_plan")

        XCTAssertEqual(UninstallPlan.arguments(paths: paths, withData: false), ["uninstall", "--dry-run", "--json"] + paths)
        // The run confirms this very plan, and leaves out the app needing an administrator.
        XCTAssertEqual(
            plan.uninstallArguments(),
            ["uninstall", "--yes", "--plan=" + String(repeating: "ab", count: 32), "--with-data", "/Applications/Slack.app"]
        )
        XCTAssertEqual(plan.deleteMode, "trash")
    }

    func testTheSlimPreviewListsAppsAndSlimsOnlyTheNamedOnes() throws {
        let preview = try fixture(SlimPreview.self, "slim_preview")

        XCTAssertEqual(preview.apps.map(\.name), ["Browser", "Notes Pro"])
        XCTAssertEqual(preview.totalIntelBytes, 861746864)
        XCTAssertTrue(preview.apps[0].running)
        XCTAssertEqual(SlimPreview.arguments, ["slim", "--dry-run", "--json"])
        XCTAssertEqual(SlimPreview.slimArguments(paths: ["/Applications/Browser.app"]), ["slim", "--yes", "/Applications/Browser.app"])
    }
}
