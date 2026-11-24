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
    func testPhoneConnectionRequiresAddressAndToken() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-acpServerAddresses", "()"]
        app.launch()

        let connect = app.buttons["连接服务器"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled)
        let address = app.textFields["服务器地址"]
        address.tap()
        address.typeText("ws://example.invalid/acp\n")
        XCTAssertFalse(connect.isEnabled)
        app.secureTextFields.firstMatch.typeText("test-token")
        XCTAssertTrue(connect.isEnabled)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        app.staticTexts["填写设备可以访问的 ACP 服务器地址。"].tap()
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
