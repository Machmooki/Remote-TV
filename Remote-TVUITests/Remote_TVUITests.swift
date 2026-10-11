import XCTest

final class Remote_TVUITests: XCTestCase {
    @MainActor
    func testTouchpadShortcutsAndRealDeviceDiagnostics() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.buttons["key_select"].isEnabled)
        XCTAssertFalse(app.buttons["shortcut_netflix"].isEnabled)
        XCTAssertFalse(app.buttons["shortcut_youtube"].isEnabled)
        XCTAssertFalse(app.buttons["enableDemo"].exists)
        let pad = app.descendants(matching: .any)["touchpad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 3))
        pad.press(forDuration: 0.8)
        XCTAssertFalse(app.staticTexts["Menu transmitted"].exists)
        let remote = XCTAttachment(screenshot: app.screenshot())
        remote.name = "Minimal-remote-light"
        remote.lifetime = .keepAlways
        add(remote)

        app.buttons["chooseDevice"].tap()
        let address = app.textFields["manualIP"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap()
        address.typeText("127.0.0.1")
        app.buttons["checkAddress"].tap()
        XCTAssertTrue(app.staticTexts["Compatibility unverified"].waitForExistence(timeout: 12))
        app.buttons["dismissSheet"].tap()
        XCTAssertTrue(app.buttons["key_select"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["key_select"].isEnabled)
        XCTAssertFalse(app.buttons["shortcut_netflix"].isEnabled)
    }

    @MainActor
    func testManualConnectionSurfacesRealTLSFailure() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["chooseDevice"].tap()
        let address = app.textFields["manualIP"]
        address.tap(); address.typeText("127.0.0.1")
        app.buttons["checkAddress"].tap()
        XCTAssertTrue(app.staticTexts["Compatibility unverified"].waitForExistence(timeout: 12))
        let connect = app.buttons["connectDevice"]
        for _ in 0..<5 {
            if connect.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(connect.isHittable)
        connect.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Connection needs attention")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Connected · authenticated Android TV Remote v2"].exists)
        app.buttons["dismissSheet"].tap()
        XCTAssertFalse(app.buttons["key_select"].isEnabled)
    }

    @MainActor
    func testInvalidAddressShowsErrorInsideSheet() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["chooseDevice"].tap()
        let address = app.textFields["manualIP"]
        address.tap()
        address.typeText("999.1.1.1")
        app.buttons["checkAddress"].tap()
        XCTAssertTrue(app.alerts["Unable to continue"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
    }

    @MainActor
    func testPhoneKeyboardDisconnectedState() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["openKeyboard"].tap()
        XCTAssertTrue(app.textFields["tvKeyboardInput"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["tvKeyboardInput"].isEnabled)
        XCTAssertFalse(app.buttons["sendTVText"].isEnabled)
        app.buttons["dismissSheet"].tap()
        XCTAssertFalse(app.buttons["key_select"].isEnabled)
    }

    @MainActor
    func testSettingsCanOpenAndClose() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.sliders["Swipe distance"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.switches["demoToggle"].exists)
        XCTAssertFalse(app.staticTexts["Demo mode"].exists)
        app.buttons["dismissSheet"].tap()
        XCTAssertTrue(app.buttons["chooseDevice"].waitForExistence(timeout: 3))
    }
    @MainActor
    func testMinimalDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "dark", "-automaticConnection", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["chooseDevice"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["openKeyboard"].isHittable)
        XCTAssertFalse(app.buttons["enableDemo"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Minimal-remote-dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["openKeyboard"].tap()
        XCTAssertTrue(app.textFields["tvKeyboardInput"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["searchTVText"].isEnabled)
    }

}
