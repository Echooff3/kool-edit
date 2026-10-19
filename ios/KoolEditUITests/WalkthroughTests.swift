import XCTest

/// Walks through the app the way a finger would: record a marked take, then
/// mark, select, zoom, play, apply an effect and share in the editor. Each
/// step saves a screenshot to the test results, and also as a PNG in $SHOTS
/// when it's set (`TEST_RUNNER_SHOTS=/some/folder xcodebuild test …`).
final class WalkthroughTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    func testRecordingAMarkedTake() throws {
        app.buttons["Record a new take"].tap()
        allowMicrophone()
        let record = app.buttons["Record"]
        let ready = wait(for: record, "isEnabled == true", timeout: 10)
        shot("recorder-ready")
        if !ready && app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'no audio input'")).firstMatch.exists {
            throw XCTSkip("The Simulator has no audio input on this Mac to record from.")
        }
        XCTAssertTrue(ready, "The recorder never got an input")

        record.tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["Mark"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("recorder-recording")
        app.buttons["Stop"].tap()

        // Straight into the editor with the new take and its marker.
        XCTAssertTrue(waveform.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Markers, 1"].exists)
        shot("editor-new-take")

        // Tidy up: back to the library and delete it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let newest = app.cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        newest.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete Take"].tap()
    }

    func testEditingAndSharingASelection() throws {
        try openATake()
        shot("editor")

        // Two markers, then a long press between them selects that stretch.
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        app.buttons["Add Marker"].tap()
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)).tap()
        app.buttons["Add Marker"].tap()
        XCTAssertTrue(app.buttons["Markers, 2"].exists)
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Share Selection"].waitForExistence(timeout: 2), "Long press didn't select between the markers")
        shot("editor-between-markers")

        // Drag out a selection of its own.
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        shot("editor-dragged")

        app.buttons["Zoom to Selection"].tap()
        shot("editor-zoomed")
        waveform.pinch(withScale: 6, velocity: 4)
        shot("editor-pinched")
        app.buttons["Zoom Out Full"].tap()

        app.buttons["Play"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("editor-playing")
        app.buttons["Stop"].tap()

        // An effect, undone.
        app.buttons["Effects"].tap()
        shot("editor-effects")
        app.buttons["Fade In"].tap()
        let undo = app.buttons["Undo Fade In"]
        XCTAssertTrue(wait(for: undo, "isEnabled == true", timeout: 10))
        undo.tap()
        XCTAssertTrue(wait(for: app.buttons["Redo Fade In"], "isEnabled == true", timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        shot("editor-landscape")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)

        app.buttons["Markers, 2"].tap()
        XCTAssertTrue(app.navigationBars["Markers"].waitForExistence(timeout: 3))
        shot("markers")
        app.buttons["Clear All"].tap()
        app.buttons["Done"].tap()

        app.buttons["Share Selection"].tap()
        XCTAssertTrue(app.navigationBars["Share Selection"].waitForExistence(timeout: 3))
        shot("export")
        app.navigationBars["Share Selection"].buttons["Share"].tap()
        // The system share sheet, holding the exported clip.
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15)
            || app.collectionViews.cells["Copy"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shot("share-sheet")
    }

    // MARK: Helpers

    private var waveform: XCUIElement { app.otherElements["Waveform"] }

    /// Opens "Sunday Jam" if it's there, otherwise the newest take.
    private func openATake() throws {
        let jam = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'Sunday Jam'")).firstMatch
        let take = jam.waitForExistence(timeout: 3) ? jam : app.cells.firstMatch
        guard take.exists else { throw XCTSkip("There are no takes to open.") }
        take.tap()
        XCTAssertTrue(waveform.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func allowMicrophone() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["SHOTS"] {
            let url = URL(fileURLWithPath: folder)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? png.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}
