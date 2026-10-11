import XCTest
@testable import AwakeCore

final class DurationTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(parseDuration("90"), 5400)
        XCTAssertEqual(parseDuration("90m"), 5400)
        XCTAssertEqual(parseDuration("2h"), 7200)
        XCTAssertEqual(parseDuration("1h30m"), 5400)
        XCTAssertEqual(parseDuration("1D"), 86400)
        XCTAssertEqual(parseDuration("45s"), 45)
    }

    func testParseRejects() {
        for bad in ["", "0", "-5", "h", "2x", "1h30", "abc", "0m"] {
            XCTAssertNil(parseDuration(bad), bad)
        }
    }

    func testFormat() {
        XCTAssertEqual(formatRemaining(45), "45с")
        XCTAssertEqual(formatRemaining(23 * 60), "23м")
        XCTAssertEqual(formatRemaining(2 * 3600 + 5 * 60), "2ч05м")
        XCTAssertEqual(formatRemaining(27 * 3600), "1д3ч")
        XCTAssertEqual(formatRemaining(-3), "0с")
    }
}

final class PolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let ac = Battery(onBattery: false, percent: 5)

    func plan(_ s: Session, lid: Bool = false, battery: Battery? = nil, floor: Int = 15) -> Plan {
        makePlan(session: s, now: now, lidClosed: lid, battery: battery, batteryFloor: floor)
    }

    func testOff() {
        let p = plan(.off)
        XCTAssertFalse(p.preventSystemSleep || p.preventDisplaySleep || p.disableSleep || p.lidActions)
    }

    func testAwakeLidOpenAndClosed() {
        let open = plan(Session(mode: .awake))
        XCTAssertTrue(open.preventSystemSleep && open.preventDisplaySleep)
        XCTAssertFalse(open.disableSleep || open.lidActions)

        let closed = plan(Session(mode: .awake), lid: true)
        XCTAssertFalse(closed.preventDisplaySleep || closed.disableSleep || closed.lidActions)
    }

    func testLidMode() {
        let s = Session(mode: .lid, until: now + 60)
        let open = plan(s)
        XCTAssertTrue(open.disableSleep && open.preventDisplaySleep)
        XCTAssertFalse(open.lidActions)

        let closed = plan(s, lid: true)
        XCTAssertTrue(closed.disableSleep && closed.lidActions)
        XCTAssertFalse(closed.preventDisplaySleep)
        XCTAssertEqual(closed.session, s)
    }

    func testExpiryEndsSession() {
        let p = plan(Session(mode: .lid, until: now), lid: true)
        XCTAssertEqual(p.session, Session(mode: .off, endedReason: "time"))
        XCTAssertFalse(p.disableSleep || p.lidActions || p.preventSystemSleep)
    }

    func testBatteryFloor() {
        let s = Session(mode: .lid, until: now + 60)
        XCTAssertEqual(plan(s, battery: Battery(onBattery: true, percent: 15)).session.endedReason, "battery:15")
        XCTAssertEqual(plan(s, battery: Battery(onBattery: true, percent: 16)).session, s)
        XCTAssertEqual(plan(s, battery: ac).session, s, "на зарядке пол не действует")
        XCTAssertEqual(plan(s, battery: Battery(onBattery: true, percent: 3), floor: 0).session, s, "floor 0 выключает защиту")
        XCTAssertEqual(plan(s, battery: nil).session, s, "десктоп без батареи")
    }

    func testThermal() {
        let s = Session(mode: .lid, until: now + 60)
        func run(_ t: ProcessInfo.ThermalState, lid: Bool) -> Session {
            makePlan(session: s, now: now, lidClosed: lid, battery: nil, batteryFloor: 15, thermal: t).session
        }
        XCTAssertEqual(run(.critical, lid: false).endedReason, "thermal:critical")
        XCTAssertEqual(run(.critical, lid: true).endedReason, "thermal:critical")
        XCTAssertEqual(run(.serious, lid: true).endedReason, "thermal:serious")
        XCTAssertEqual(run(.serious, lid: false), s, "за столом serious не рвёт сессию")
        XCTAssertEqual(run(.fair, lid: true), s)
    }

    func testHoldsRaiseMode() {
        let p = makePlan(session: .off, now: now, lidClosed: true, battery: nil, batteryFloor: 15, heldMode: .lid)
        XCTAssertEqual(p.mode, .lid)
        XCTAssertTrue(p.disableSleep && p.lidActions)
        XCTAssertEqual(p.session, .off, "холд не создаёт ручную сессию")
    }

    func testHoldsTakeMaxWithSession() {
        let awake = Session(mode: .awake)
        XCTAssertEqual(makePlan(session: awake, now: now, lidClosed: false, battery: nil, batteryFloor: 15, heldMode: .lid).mode, .lid)
        let lid = Session(mode: .lid, until: now + 60)
        XCTAssertEqual(makePlan(session: lid, now: now, lidClosed: false, battery: nil, batteryFloor: 15, heldMode: .awake).mode, .lid)
    }

    func testGuardsSuppressHoldsWithoutEndingThem() {
        let low = Battery(onBattery: true, percent: 10)
        let p = makePlan(session: .off, now: now, lidClosed: true, battery: low, batteryFloor: 15, heldMode: .lid)
        XCTAssertEqual(p.mode, .off)
        XCTAssertEqual(p.holdsSuppressed, "battery:10")
        XCTAssertFalse(p.disableSleep)

        let hot = makePlan(session: .off, now: now, lidClosed: true, battery: nil, batteryFloor: 15, thermal: .serious, heldMode: .lid)
        XCTAssertEqual(hot.mode, .off)
        XCTAssertNil(makePlan(session: .off, now: now, lidClosed: true, battery: low, batteryFloor: 15).holdsSuppressed,
                     "без холдов нечего глушить")
    }

    func testModeOrder() {
        XCTAssertTrue(Mode.off < .awake && Mode.awake < .lid)
    }
}
