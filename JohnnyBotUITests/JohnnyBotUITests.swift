//
//  JohnnyBotUITests.swift
//  JohnnyBotUITests
//
//  Created by 林满佳 on 2026/11/22.
//

import XCTest

final class JohnnyBotUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

#if os(iOS)
    @MainActor
    func testSeamlessHistoryOnPhone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-testHistoryPagination"]
        app.launch()
        func message(_ index: Int) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "测试消息 \(index)")).firstMatch
        }
        let last = message(124)
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let ending = app.textViews.matching(
            NSPredicate(format: "label ENDSWITH %@", "已完成验证。")
        ).firstMatch
        XCTAssertTrue(ending.waitForExistence(timeout: 5), app.debugDescription)
        let gap = last.frame.minY - ending.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, 0)
        XCTAssertLessThan(gap, 48)
        let earlier = message(24)
        for _ in 0..<30 {
            if earlier.exists && earlier.isHittable { break }
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(earlier.isHittable)
        XCTAssertFalse(app.buttons["加载更早的消息"].exists)
        XCTAssertFalse(app.staticTexts["历史消息"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "连续浏览历史消息"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testPhoneConnectionRequiresAddressAndFingerprint() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mqttServerTabs", "()"]
        app.launch()

        let connect = app.buttons["连接服务器"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled)
        let address = app.textFields["服务器地址"]
        address.tap()
        address.typeText("mqtts://example.invalid:8883/test\n")
        XCTAssertFalse(connect.isEnabled)
        app.textFields["SHA-256 指纹"].typeText(String(repeating: "a", count: 64))
        XCTAssertTrue(connect.isEnabled)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        app.staticTexts["末尾的服务标识取自 Go 服务的 -host 参数。"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        XCTAssertTrue(connect.isEnabled)
    }
#endif

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
