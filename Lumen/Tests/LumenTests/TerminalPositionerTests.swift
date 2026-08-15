import XCTest
import CoreGraphics
@testable import Lumen

// TerminalPositioner.computeAnchor is pure arithmetic (window frame ÷
// columns/lines -> screen point), deliberately split out from the
// AX/NSWorkspace calls in TerminalPositioner.anchor(for:) specifically so
// it's testable without Accessibility permission — see its doc comment.
// These cases pin that math down directly rather than relying on manual
// on-screen verification.
final class TerminalPositionerTests: XCTestCase {
    func testBasicWindowNoTitleBar() throws {
        let cursor = TerminalPositioner.CursorInfo(row: 5, col: 10, columns: 80, lines: 24)
        let result = TerminalPositioner.computeAnchor(
            windowPosition: CGPoint(x: 0, y: 0),
            windowSize: CGSize(width: 800, height: 600),
            titleBarHeight: 0,
            mainScreenHeight: 1000,
            cursor: cursor
        )

        let anchor = try XCTUnwrap(result)
        // cellWidth = 800/80 = 10, cellHeight = 600/24 = 25
        XCTAssertEqual(anchor.x, 90, accuracy: 0.001)
        XCTAssertEqual(anchor.cellTopY, 900, accuracy: 0.001)
        XCTAssertEqual(anchor.cellBottomY, 875, accuracy: 0.001)
    }

    func testWindowWithTitleBarAndOffsetPosition() throws {
        let cursor = TerminalPositioner.CursorInfo(row: 2, col: 3, columns: 50, lines: 20)
        let result = TerminalPositioner.computeAnchor(
            windowPosition: CGPoint(x: 100, y: 50),
            windowSize: CGSize(width: 500, height: 828),
            titleBarHeight: 28,
            mainScreenHeight: 900,
            cursor: cursor
        )

        let anchor = try XCTUnwrap(result)
        // contentHeight = 828-28 = 800, cellWidth = 500/50 = 10, cellHeight = 800/20 = 40
        XCTAssertEqual(anchor.x, 120, accuracy: 0.001)
        XCTAssertEqual(anchor.cellTopY, 782, accuracy: 0.001)
        XCTAssertEqual(anchor.cellBottomY, 742, accuracy: 0.001)
    }

    func testZeroColumnsReturnsNil() {
        let cursor = TerminalPositioner.CursorInfo(row: 1, col: 1, columns: 0, lines: 24)
        let result = TerminalPositioner.computeAnchor(
            windowPosition: .zero,
            windowSize: CGSize(width: 800, height: 600),
            titleBarHeight: 0,
            mainScreenHeight: 1000,
            cursor: cursor
        )
        XCTAssertNil(result)
    }

    func testZeroLinesReturnsNil() {
        let cursor = TerminalPositioner.CursorInfo(row: 1, col: 1, columns: 80, lines: 0)
        let result = TerminalPositioner.computeAnchor(
            windowPosition: .zero,
            windowSize: CGSize(width: 800, height: 600),
            titleBarHeight: 0,
            mainScreenHeight: 1000,
            cursor: cursor
        )
        XCTAssertNil(result)
    }

    func testTitleBarTallerThanWindowReturnsNil() {
        // contentHeight = windowSize.height - titleBarHeight <= 0 is nonsensical
        // geometry (e.g. a stale/garbage AX frame) and must not divide-by-near-zero
        // into a bogus cell height.
        let cursor = TerminalPositioner.CursorInfo(row: 1, col: 1, columns: 80, lines: 24)
        let result = TerminalPositioner.computeAnchor(
            windowPosition: .zero,
            windowSize: CGSize(width: 800, height: 20),
            titleBarHeight: 28,
            mainScreenHeight: 1000,
            cursor: cursor
        )
        XCTAssertNil(result)
    }
}
