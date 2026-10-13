import AlgorithmCore
import Foundation
import JSOrefCore
import XCTest

/// Plan S0.2 `DeterminismTests`: the core is a pure function of (inputs, clock, time zone).
final class DeterminismTests: XCTestCase {
    private func firstFixture() throws -> ScenarioFixture {
        let all = try ScenarioFixture.loadAll()
        guard let f = all.first(where: { $0.name == "rising_smb_capped_at_basal_x_30min" }) else {
            throw DosingCoreError.missingResource("rising fixture")
        }
        return f
    }

    func testSameInputsSameOutput() throws {
        try TestSupport.skipUnlessUTC()
        let core = try TestSupport.makeCore()
        let f = try firstFixture()
        let a = try core.run(f.inputs, clock: f.clock, timeZone: f.timeZone)
        let b = try core.run(f.inputs, clock: f.clock, timeZone: f.timeZone)
        XCTAssertEqual(a.determination.text, b.determination.text)
        XCTAssertEqual(a.iob.text, b.iob.text)
        XCTAssertEqual(a.meal.text, b.meal.text)
        // And a second core instance (fresh virtual machine) agrees byte-for-byte.
        let other = try TestSupport.makeCore()
        let c = try other.run(f.inputs, clock: f.clock, timeZone: f.timeZone)
        XCTAssertEqual(a.determination.text, c.determination.text)
    }

    func testClockIsHonoured() throws {
        try TestSupport.skipUnlessUTC()
        let core = try TestSupport.makeCore()
        let f = try firstFixture()
        let base = try core.run(f.inputs, clock: f.clock, timeZone: f.timeZone)
        XCTAssertEqual(base.summary.deliverAt, f.clock.orefISO8601, "deliverAt must be the injected clock, not wall-clock time")

        // Ten minutes later with the same (now stale-looking) data: deliverAt follows the clock,
        // and the BG-age guard changes the decision (no SMB on data older than 12 min).
        let later = f.clock.addingTimeInterval(10 * 60)
        let shifted = try core.run(f.inputs, clock: later, timeZone: f.timeZone)
        XCTAssertEqual(shifted.summary.deliverAt, later.orefISO8601)
        XCTAssertNotEqual(shifted.determination.text, base.determination.text)
    }

    func testTimeZoneMismatchIsRefused() throws {
        let core = try TestSupport.makeCore()
        let f = try firstFixture()
        let other = TimeZone.current.identifier == "Pacific/Chatham" ? TimeZone(identifier: "UTC")! : TimeZone(identifier: "Pacific/Chatham")!
        XCTAssertThrowsError(try core.run(f.inputs, clock: f.clock, timeZone: other)) { error in
            guard case DosingCoreError.timeZoneMismatch = error else { return XCTFail("expected timeZoneMismatch, got \(error)") }
        }
    }

    func testFingerprintHashesEveryScript() throws {
        let core = try TestSupport.makeCore()
        let names = Set(core.fingerprint.scriptSHA256.keys)
        for required in ["bundle/determine-basal.js", "bundle/iob.js", "bundle/meal.js", "bundle/profile.js", "bundle/autosens.js", "prepare/determine-basal.js", "middleware/determine_basal.js"] {
            XCTAssertTrue(names.contains(required), "fingerprint missing \(required)")
        }
        XCTAssertEqual(core.fingerprint.timeZoneIdentifier, TimeZone.current.identifier)
        for (_, hash) in core.fingerprint.scriptSHA256 { XCTAssertEqual(hash.count, 64) }
    }
}
