import AppKit
import ApplicationServices
import Foundation

/// Plain-file logging, bypassing NSLog: launched via `open` (the officially
/// supported way to start a .app bundle — matters for how Accessibility
/// permission gets associated), stdout/stderr aren't capturable by simply
/// redirecting a shell pipe, and the unified system log redacts
/// string-interpolated content as "<private>" by default. A dumb append-
/// to-file gives full-fidelity diagnostics regardless of launch method.
func debugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let path = "/tmp/lumen-overlay-debug.log"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Fine-tuning knobs for TerminalPositioner, overridable at runtime from
/// ~/.config/lumen/overlay_position.json without rebuilding the app.
/// This exists specifically because iterating on these constants by editing
/// Swift source means: rebuild -> re-sign (new ad-hoc hash) -> Accessibility
/// permission gets invalidated -> remove+re-add in System Settings -> native
/// prompt -> relaunch, every single time, even for a one-number tweak. A
/// plain JSON file sidesteps all of that for exactly the values that
/// actually need visual back-and-forth tuning (title bar heights per app,
/// how much gap to leave around the cursor's row) — code changes to the
/// actual POSITIONING LOGIC still need the full rebuild cycle, but pixel
/// calibration doesn't have to.
struct PositionerConfig: Decodable {
    var titleBarHeights: [String: Double] = [
        "com.googlecode.iterm2": 28,
        "com.apple.Terminal": 28,
    ]
    var defaultTitleBarHeight: Double = 28
    /// Extra space (points) to leave between the panel and the cursor's own
    /// row, in whichever direction it ends up placed — pushes the panel's
    /// top further down when placed below, or its bottom further up when
    /// flipped above, so it doesn't visually touch/overlap the row.
    var verticalGap: Double = 6

    init() {}

    // Custom decoder (rather than relying on synthesized Decodable) so a
    // JSON file overriding just ONE field — e.g. only {"verticalGap": 10}
    // to nudge the gap without having to also restate titleBarHeights —
    // works. Swift's auto-synthesized decoding would otherwise require
    // every field to be present, ignoring the property defaults above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleBarHeights = try c.decodeIfPresent([String: Double].self, forKey: .titleBarHeights)
            ?? Self().titleBarHeights
        defaultTitleBarHeight = try c.decodeIfPresent(Double.self, forKey: .defaultTitleBarHeight)
            ?? Self().defaultTitleBarHeight
        verticalGap = try c.decodeIfPresent(Double.self, forKey: .verticalGap) ?? Self().verticalGap
    }

    private enum CodingKeys: String, CodingKey {
        case titleBarHeights, defaultTitleBarHeight, verticalGap
    }

    static let shared: PositionerConfig = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lumen/overlay_position.json")
        guard let data = try? Data(contentsOf: path) else {
            debugLog("Lumen: no overlay_position.json at \(path.path), using built-in defaults")
            return PositionerConfig()
        }
        do {
            let decoded = try JSONDecoder().decode(PositionerConfig.self, from: data)
            debugLog("Lumen: loaded overlay_position.json override from \(path.path)")
            return decoded
        } catch {
            debugLog("Lumen: failed to parse overlay_position.json: \(error) — using built-in defaults")
            return PositionerConfig()
        }
    }()
}

/// Converts a terminal's reported cursor grid position into a screen pixel
/// point, so the overlay panel can be placed against the real terminal
/// cursor instead of somewhere arbitrary.
///
/// Two approaches, tried in order:
///
/// 1. PRIMARY — ask the focused element directly where its own text cursor
///    renders (AXSelectedTextRange + AXBoundsForRange), the same mechanism
///    macOS input-method/spell-check popups use. This is the app's own
///    authoritative answer, not something we compute — no title-bar-height
///    guessing, no per-app calibration, and it isn't confused by split-pane
///    or tiled window layouts, because the bounds are relative to whatever
///    text range is actually focused, however that's laid out on screen.
///    Only works for apps that implement real NSAccessibility text
///    protocols for their content (see `caretRect`).
///
/// 2. FALLBACK — frontmost app → AXUIElement → focused window/pane →
///    position/size, minus a per-app title-bar-height estimate, then cell
///    size = content frame size / (columns, lines) from the shell's own
///    $COLUMNS/$LINES, and point = content origin + (cursorCol, cursorRow)
///    * cell size. Used only when approach 1 isn't available. This is the
///    one with real limitations: the title-bar-height table is a fixed
///    per-app constant (won't account for an optional tab bar), and it can
///    be badly wrong for apps whose "window" is actually several tiled
///    panes sharing one frame (see the screen-bounds/cell-size validation
///    below, added specifically because this happened in practice).
///
/// Both paths validate their result against actual screen bounds
/// (`isOnSomeScreen`) before trusting it — geometry that resolves nowhere
/// near a real screen is rejected outright rather than shown.
///
/// Requires the user to grant Accessibility permission to this app
/// (System Settings → Privacy & Security → Accessibility) — without it,
/// every AXUIElementCopyAttributeValue call fails and `anchor(for:)`
/// returns nil, same as any other positioning failure. Callers must treat
/// nil as "don't show the overlay this time," never guess a fallback
/// position.
enum TerminalPositioner {
    struct CursorInfo {
        let row: Int
        let col: Int
        let columns: Int
        let lines: Int
    }

    /// Where the cursor's own character cell sits on screen (AppKit
    /// coordinates, origin bottom-left) — both edges, not just one point,
    /// so the caller (OverlayController) can choose to anchor the panel's
    /// TOP at cellBottomY (normal: panel appears below the cursor) or the
    /// panel's BOTTOM at cellTopY (flipped: panel appears above) depending
    /// on which actually fits given the panel's real rendered size and the
    /// screen bounds — a decision that has to happen after the panel's
    /// content is measured, not here.
    struct ScreenAnchor {
        let x: CGFloat
        let cellTopY: CGFloat
        let cellBottomY: CGFloat
    }

    /// Estimated title-bar height (points) to subtract from a window's AX
    /// frame to approximate where its text content actually starts, keyed
    /// by bundle identifier. Runtime-overridable — see PositionerConfig.
    private static var titleBarHeights: [String: CGFloat] {
        PositionerConfig.shared.titleBarHeights.mapValues { CGFloat($0) }
    }
    private static var defaultTitleBarHeight: CGFloat {
        CGFloat(PositionerConfig.shared.defaultTitleBarHeight)
    }

    /// Returns the point (AppKit screen coordinates, origin bottom-left)
    /// just below the cursor where the overlay panel's top edge should
    /// sit, or nil if positioning isn't possible right now — no frontmost
    /// app window found, Accessibility permission not granted, or any AX
    /// call failed. Callers must fall back (i.e. just not show the
    /// overlay) when nil, never guess.
    // A real monospace terminal font's character cell realistically falls in
    // this range. Used to reject geometry that clearly isn't a terminal grid
    // at all (e.g. some unrelated small control an app's AX tree happened to
    // report as "focused") rather than computing a nonsense position from
    // it — this is what actually caught the case that motivated adding it:
    // a different frontmost app than intended returned an 8x16pt element,
    // derived cell width ~0.05pt, wildly outside any real font's cell size.
    private static let cellWidthRange: ClosedRange<CGFloat> = 3...40
    private static let cellHeightRange: ClosedRange<CGFloat> = 6...60

    static func anchor(for cursor: CursorInfo) -> ScreenAnchor? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            debugLog("Lumen: overlay position: no frontmost app")
            return nil
        }
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return nil }
        enableManualAccessibilityIfNeeded(pid: app.processIdentifier)

        // PRIMARY: ask the focused element directly where its text cursor
        // actually renders (AXBoundsForRange on AXSelectedTextRange) — the
        // same mechanism macOS input-method/spell-check candidate windows
        // use to position themselves under a text caret. This is the app's
        // own authoritative answer for "where is this rendered on screen",
        // not an approximation we compute from window frame ÷ columns/lines
        // — no title-bar-height guessing, no per-app calibration, and no
        // confusion from split-pane/tiled windows (the range bounds are
        // relative to whichever element actually has focus, however that
        // element is laid out). Only apps that implement real
        // NSAccessibility text protocols support this; falls through to the
        // frame-based computation below for ones that don't.
        if let focusedEl = focusedElement(pid: app.processIdentifier),
           let rect = caretRect(for: focusedEl) {
            // TermHub is the one app observed to hand back AXBoundsForRange
            // already in AppKit's bottom-up screen space instead of AX's
            // usual top-down space (every other app tested — Terminal.app,
            // iTerm2, Code — matches the top-down convention). Flipping it
            // again as done for those mirrors the point across the screen's
            // vertical center, landing the panel near the opposite edge
            // from the real cursor. Root-caused 2026-08-01 by comparing
            // reported rect.minY/maxY (962/978 on a 982pt-tall screen, i.e.
            // just under the tab bar) against the cursor's actual
            // known-near-top position — the un-flipped reading matches, the
            // flipped one doesn't.
            let result: ScreenAnchor
            if app.bundleIdentifier == "com.termhub.app" {
                result = ScreenAnchor(x: rect.minX, cellTopY: rect.maxY, cellBottomY: rect.minY)
            } else {
                result = ScreenAnchor(
                    x: rect.minX,
                    cellTopY: mainScreenHeight - rect.minY,
                    cellBottomY: mainScreenHeight - rect.maxY
                )
            }
            if isOnSomeScreen(result) {
                debugLog("Lumen: overlay position: using caret bounds for "
                    + "\(app.localizedName ?? "?") rect=\(rect) -> \(result)")
                return result
            }
            debugLog("Lumen: overlay position: caret bounds for \(app.localizedName ?? "?") "
                + "rect=\(rect) resolved off-screen, falling back to frame-based computation")
        }

        // SECONDARY, STILL CARET-BASED: VS Code's integrated terminal (and
        // presumably any other xterm.js-based Electron terminal) never
        // answers kAXFocusedUIElementAttribute at all — at the app level OR
        // system-wide (confirmed 2026-08-13) — so the PRIMARY path above
        // never even gets an element to ask. But xterm.js always keeps a
        // tiny hidden <textarea> positioned exactly over the current cursor
        // cell (standard technique for IME composition input), and once
        // Chromium's accessibility tree is active (see
        // enableManualAccessibilityIfNeeded) that textarea shows up as a
        // real AXTextField with its own AXSelectedTextRange — confirmed via
        // dumpAXTreeForFrontmostApp on VS Code: a character-cell-sized
        // (7x15pt) AXTextField sitting right at the real cursor position,
        // many levels below the window under a "Terminal Section" group.
        // There's no focus signal to find it by, so search for it
        // structurally instead: a text field whose size actually looks like
        // one terminal character cell (reusing the same plausibility range
        // the frame-based fallback below uses) with a real selected-text
        // range. Once found, it's fed straight back into the exact same
        // AXBoundsForRange caret-reading code the PRIMARY path already
        // trusts — no new position math needed.
        if let window = focusedWindow(pid: app.processIdentifier),
           let caretField = findTerminalCaretTextField(window, depth: 0, maxDepth: 40),
           let rect = caretRect(for: caretField) {
            let result = ScreenAnchor(
                x: rect.minX,
                cellTopY: mainScreenHeight - rect.minY,
                cellBottomY: mainScreenHeight - rect.maxY
            )
            if isOnSomeScreen(result) {
                debugLog("Lumen: overlay position: using xterm.js caret textfield for "
                    + "\(app.localizedName ?? "?") rect=\(rect) -> \(result)")
                return result
            }
            debugLog("Lumen: overlay position: xterm.js caret textfield for \(app.localizedName ?? "?") "
                + "rect=\(rect) resolved off-screen, falling back to frame-based computation")
        }

        // FALLBACK: compute from window/pane frame ÷ $COLUMNS/$LINES. Try
        // the FOCUSED UI ELEMENT before the focused WINDOW: a terminal
        // window split into multiple panes (iTerm2's split panes, tmux-like
        // layouts some terminals support) is still just ONE AX window
        // spanning all of them — using its frame directly would size cells
        // against the whole window's width while $COLUMNS/$LINES describe
        // only the one pane you're actually typing in, badly misplacing the
        // panel. The focused UI element, when the app exposes one with its
        // own position/size, is the specific pane/view. The title-bar-height
        // estimate only applies to the WHOLE WINDOW candidate — a pane has
        // no title bar of its own to subtract.
        //
        // Each candidate's geometry gets validated (see cellWidthRange/
        // cellHeightRange) before being trusted — an app can hand back a
        // "focused element" that isn't a terminal pane at all (see above),
        // so the first candidate that actually looks like a real character
        // grid for the reported columns/lines wins; anything implausible is
        // skipped rather than used.
        var candidates: [(element: AXUIElement, titleBarHeight: CGFloat, label: String)] = []
        if let paneElement = focusedElement(pid: app.processIdentifier) {
            candidates.append((paneElement, 0, "focused element"))
        }
        if let windowElement = focusedWindow(pid: app.processIdentifier) {
            let titleBarHeight = app.bundleIdentifier.flatMap { titleBarHeights[$0] } ?? defaultTitleBarHeight
            candidates.append((windowElement, titleBarHeight, "focused window"))
        }
        guard !candidates.isEmpty else {
            debugLog("Lumen: overlay position: no focused window/element for "
                + "\(app.localizedName ?? "?") (is Accessibility permission granted?)")
            return nil
        }

        for candidate in candidates {
            guard let position = attribute(candidate.element, kAXPositionAttribute, as: CGPoint.self, axType: .cgPoint),
                  let size = attribute(candidate.element, kAXSizeAttribute, as: CGSize.self, axType: .cgSize)
            else { continue }

            let cellWidth = size.width / CGFloat(cursor.columns)
            let cellHeight = (size.height - candidate.titleBarHeight) / CGFloat(cursor.lines)
            guard cellWidthRange.contains(cellWidth), cellHeightRange.contains(cellHeight) else {
                debugLog("Lumen: overlay position: rejecting \(candidate.label) for "
                    + "\(app.localizedName ?? "?") — implausible cell size \(cellWidth)x\(cellHeight) "
                    + "from position=\(position) size=\(size)")
                continue
            }

            guard let result = computeAnchor(
                windowPosition: position,
                windowSize: size,
                titleBarHeight: candidate.titleBarHeight,
                mainScreenHeight: mainScreenHeight,
                cursor: cursor
            ) else { continue }

            // Cell width/height alone can look individually plausible while
            // still being wrong — observed in practice: Terminal.app's
            // focused UI element reported size=(580, 737) for a 24-line
            // window, implying a cell height (~30pt) that passes the range
            // check above, but the SOURCE geometry was almost certainly the
            // full scrollback buffer rather than just the visible viewport
            // (position.y was deeply negative, well above any real
            // screen). The tell isn't the cell size, it's that the
            // RESULTING point ends up nowhere near an actual screen — so
            // validate that too, against every connected screen (not just
            // the main one), with generous slop since window chrome/insets
            // are only ever approximated.
            guard isOnSomeScreen(result) else {
                debugLog("Lumen: overlay position: rejecting \(candidate.label) for "
                    + "\(app.localizedName ?? "?") — resulting point \(result) isn't within any screen's "
                    + "bounds (position=\(position) size=\(size)); likely scrollback/off-screen geometry, "
                    + "not the visible viewport")
                continue
            }

            debugLog("Lumen: overlay position: using \(candidate.label) for "
                + "\(app.localizedName ?? "?") position=\(position) size=\(size) "
                + "cursor=(\(cursor.row),\(cursor.col))/\(cursor.columns)x\(cursor.lines) -> \(String(describing: result))")
            return result
        }

        debugLog("Lumen: overlay position: no plausible geometry for \(app.localizedName ?? "?")")
        return nil
    }

    /// The actual position math, decoupled from the AX/NSWorkspace calls
    /// above so it can be unit-tested with known values (e.g. from a
    /// terminal's own AppleScript-reported bounds) without needing
    /// Accessibility permission at all — only the AX-fetching in
    /// `anchor(for:)` needs that; this is pure arithmetic.
    static func computeAnchor(
        windowPosition: CGPoint,
        windowSize: CGSize,
        titleBarHeight: CGFloat,
        mainScreenHeight: CGFloat,
        cursor: CursorInfo
    ) -> ScreenAnchor? {
        guard cursor.columns > 0, cursor.lines > 0 else { return nil }
        let contentHeight = windowSize.height - titleBarHeight
        guard contentHeight > 0, windowSize.width > 0 else { return nil }

        let cellWidth = windowSize.width / CGFloat(cursor.columns)
        let cellHeight = contentHeight / CGFloat(cursor.lines)

        // AX space: origin top-left of main screen, Y grows downward — so
        // "row rows down from content top" is a straightforward add here.
        // axYBottom is the bottom edge of the cursor's row (row rows down
        // from content top); axYTop is that same row's top edge, exactly
        // one cell higher up (i.e. numerically smaller in this top-down
        // space).
        let axX = windowPosition.x + CGFloat(cursor.col - 1) * cellWidth
        let axYBottom = windowPosition.y + titleBarHeight + CGFloat(cursor.row) * cellHeight
        let axYTop = axYBottom - cellHeight

        // AppKit space: origin bottom-left of main screen, Y grows upward.
        // This is the standard AX↔AppKit conversion — flip against the
        // MAIN screen's height specifically, regardless of which display
        // the window is actually on (both coordinate systems share that
        // same reference origin). Note the flip also swaps which is
        // numerically larger: axYTop < axYBottom, but in AppKit's
        // grows-upward space the row's top is HIGHER on screen, so
        // cellTopY > cellBottomY.
        return ScreenAnchor(
            x: axX,
            cellTopY: mainScreenHeight - axYTop,
            cellBottomY: mainScreenHeight - axYBottom
        )
    }

    /// Whether either edge of an anchor falls within (or near — generous
    /// slop, since window chrome/insets are only ever approximated) any
    /// connected screen. Shared by both the caret-bounds path and the
    /// frame-based fallback: a result that's nowhere near a real screen is
    /// always wrong, regardless of which method produced it — e.g.
    /// Terminal.app's focused element once reported scrollback-buffer
    /// geometry whose resulting Y was far above the tallest screen.
    private static func isOnSomeScreen(_ anchor: ScreenAnchor) -> Bool {
        let margin: CGFloat = 200
        return NSScreen.screens.contains { screen in
            let bounds = screen.frame.insetBy(dx: -margin, dy: -margin)
            return bounds.contains(CGPoint(x: anchor.x, y: anchor.cellBottomY))
                || bounds.contains(CGPoint(x: anchor.x, y: anchor.cellTopY))
        }
    }

    /// The actual on-screen rectangle of the text cursor (or current
    /// selection), straight from the focused element's own accessibility
    /// implementation — AXSelectedTextRange identifies WHERE in its text
    /// model the cursor is, AXBoundsForRange (a parameterized attribute)
    /// asks it to convert that into real screen coordinates. Returns nil
    /// for any app that doesn't implement this (most non-text-editor
    /// controls, and apps without a proper NSAccessibility text bridge),
    /// which is exactly the signal `anchor(for:)` needs to fall back to the
    /// frame-based computation instead.
    private static func caretRect(for element: AXUIElement) -> CGRect? {
        guard let range = attribute(element, kAXSelectedTextRangeAttribute, as: CFRange.self, axType: .cfRange)
        else { return nil }

        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var boundsRef: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard error == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let boundsValue = boundsRef as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else { return nil }
        guard rect.width.isFinite, rect.height.isFinite, rect.height > 0 else { return nil }
        return rect
    }

    /// Chromium/Electron apps (VS Code among them) don't populate a full
    /// accessibility tree by default — Chromium only turns it on once it
    /// detects an actual assistive-technology client, which normally
    /// happens via VoiceOver's own internal handshake. Without that, every
    /// AX query against the app's controls answers kAXErrorNoValue, at
    /// both the per-app AND system-wide level (confirmed 2026-08-13: VS
    /// Code's terminal returned -25212 from both `focusedElement`'s
    /// app-level query and its system-wide fallback). Setting this
    /// boolean attribute on the app's own AXUIElement is Chromium's
    /// documented opt-in for external AX clients that aren't VoiceOver —
    /// it forces the same full accessibility tree VoiceOver's handshake
    /// would trigger. Safe/cheap to call on every lookup: non-Chromium
    /// apps that don't recognize the attribute just return an error here,
    /// which is intentionally ignored. Tree population can lag the set by
    /// a frame or two on a cold app, so the very first query right after
    /// launch/focus may still miss — self-corrects on the next keystroke.
    private static func enableManualAccessibilityIfNeeded(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        let error = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if error != .success {
            debugLog("Lumen: AXManualAccessibility set error=\(error.rawValue) (expected/harmless for non-Chromium apps)")
        }
    }

    /// Depth-first search for xterm.js's hidden cursor-tracking textarea —
    /// see the SECONDARY block in `anchor(for:)` for why this exists. Not
    /// findable by role/description alone (VS Code doesn't mark it in any
    /// AX-visible way beyond its own accessibility-help text, which isn't
    /// guaranteed stable across VS Code versions), so this identifies it
    /// structurally instead: an AXTextField sized like one real character
    /// cell (reusing `cellWidthRange`/`cellHeightRange`, the same
    /// plausibility bounds the frame-based fallback trusts) that actually
    /// has a selected text range to read bounds from. Returns on the first
    /// match (there's normally only one live cursor on screen at a time).
    /// Skips descending into the menu bar for the same reason
    /// `dumpAXTree`'s diagnostic does — it's deep, irrelevant, and not
    /// where a terminal's content would ever be.
    private static func findTerminalCaretTextField(_ element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute)

        if role == (kAXTextFieldRole as String),
           let size = attribute(element, kAXSizeAttribute, as: CGSize.self, axType: .cgSize),
           cellWidthRange.contains(size.width), cellHeightRange.contains(size.height),
           attribute(element, kAXSelectedTextRangeAttribute, as: CFRange.self, axType: .cfRange) != nil {
            return element
        }
        guard role != (kAXMenuBarRole as String) else { return nil }

        var childrenRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findTerminalCaretTextField(child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// The specific focused control/pane within the app, if it exposes one
    /// distinct from its window — e.g. the specific split pane you're
    /// typing in, for terminals that support splitting one window into
    /// several sessions. Returns nil (falling back to the whole window in
    /// `point(for:)`) when the app doesn't expose this, or the element it
    /// gives back doesn't have its own position/size to speak of.
    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var elementRef: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &elementRef)
        debugLog("Lumen: kAXFocusedUIElementAttribute error=\(error.rawValue)")

        // Electron/Chromium apps (VS Code's integrated terminal among them)
        // routinely answer kAXErrorNoValue here — their AXApplication root
        // element doesn't forward "what's focused" the way native AppKit
        // apps do, even though the OS itself knows perfectly well what has
        // keyboard focus. The system-wide element tracks that directly
        // (the same source macOS's own IME/spell-check candidate windows
        // read from) and isn't dependent on the target app implementing
        // this attribute at its root — falling back to it here is what
        // lets VS Code's terminal pane resolve instead of silently
        // dropping to the whole-window fallback below.
        if error != .success || elementRef == nil {
            let systemWide = AXUIElementCreateSystemWide()
            error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
            debugLog("Lumen: kAXFocusedUIElementAttribute (system-wide) error=\(error.rawValue)")
        }

        guard error == .success, let elementRef else { return nil }
        // swiftlint:disable:next force_cast
        let element = elementRef as! AXUIElement
        guard attribute(element, kAXPositionAttribute, as: CGPoint.self, axType: .cgPoint) != nil,
              attribute(element, kAXSizeAttribute, as: CGSize.self, axType: .cgSize) != nil
        else {
            debugLog("Lumen: focused UI element has no position/size, falling back to window")
            return nil
        }
        return element
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        debugLog("Lumen: AXIsProcessTrusted=\(AXIsProcessTrusted())")
        let appElement = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        debugLog("Lumen: kAXFocusedWindowAttribute error=\(error.rawValue)")
        if error == .success, let windowRef {
            // swiftlint:disable:next force_cast
            return (windowRef as! AXUIElement)
        }

        error = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef)
        debugLog("Lumen: kAXMainWindowAttribute error=\(error.rawValue)")
        if error == .success, let windowRef {
            // swiftlint:disable:next force_cast
            return (windowRef as! AXUIElement)
        }

        var windowsRef: CFTypeRef?
        error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        debugLog("Lumen: kAXWindowsAttribute error=\(error.rawValue) "
            + "count=\((windowsRef as? [AXUIElement])?.count ?? -1)")
        if error == .success, let windows = windowsRef as? [AXUIElement], let first = windows.first {
            return first
        }

        return nil
    }

    private static func attribute<T>(
        _ element: AXUIElement,
        _ name: String,
        as _: T.Type,
        axType: AXValueType
    ) -> T? {
        var valueRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &valueRef)
        guard error == .success, let valueRef else { return nil }
        guard CFGetTypeID(valueRef) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let axValue = valueRef as! AXValue
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AXValueGetValue(axValue, axType, result) else { return nil }
        return result.pointee
    }

    /// One-off diagnostic: walks the frontmost app's full accessibility
    /// tree and logs every element's role/position/size/value, to see
    /// what's actually exposed for apps where the shallow "focused
    /// element"/"focused window" queries above aren't enough — e.g. a
    /// Tauri/WebView-based app whose terminal renders to a <canvas> (no
    /// text semantics at that level) but whose underlying library (xterm.js
    /// ships one) maintains a hidden accessibility DOM mirror that might
    /// still surface somewhere deeper in the tree. Triggered by the zsh
    /// plugin sending {"dumpAXTree": true} — see OverlayBridge in App.swift.
    static func dumpAXTreeForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            debugLog("Lumen: [ax-dump] no frontmost app")
            return
        }
        debugLog("Lumen: [ax-dump] === \(app.localizedName ?? "?") "
            + "(\(app.bundleIdentifier ?? "?")) pid=\(app.processIdentifier) ===")
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        dumpAXTree(appElement, depth: 0, maxDepth: 40, maxChildrenPerNode: 20)
        debugLog("Lumen: [ax-dump] === done ===")
    }

    private static func dumpAXTree(_ element: AXUIElement, depth: Int, maxDepth: Int, maxChildrenPerNode: Int) {
        guard depth <= maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)

        let role = stringAttribute(element, kAXRoleAttribute)
        // The macOS menu bar's own AX subtree (File/Edit/... and every
        // submenu under it) is huge, deeply nested, and has nothing to do
        // with the app's actual window content — it drowned out the one
        // thing this diagnostic exists to find (2026-08-13: a 517-line dump
        // was ~95% AXMenuBarItem/AXMenuItem noise). Skip descending into it
        // entirely; the row itself still gets logged so its presence isn't
        // silently hidden.
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let description = stringAttribute(element, kAXDescriptionAttribute)
        let position = attribute(element, kAXPositionAttribute, as: CGPoint.self, axType: .cgPoint)
        let size = attribute(element, kAXSizeAttribute, as: CGSize.self, axType: .cgSize)
        let hasSelectedTextRange = attribute(element, kAXSelectedTextRangeAttribute, as: CFRange.self, axType: .cfRange) != nil
        var valueRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let valuePreview = (valueRef as? String).map { String($0.prefix(60)) }

        debugLog("\(indent)role=\(role ?? "?") subrole=\(subrole ?? "-") "
            + "pos=\(position.map { "\($0)" } ?? "-") size=\(size.map { "\($0)" } ?? "-") "
            + "desc=\(description ?? "-") hasSelectedTextRange=\(hasSelectedTextRange) "
            + "value=\(valuePreview ?? "-")")

        guard role != kAXMenuBarRole as String else { return }

        var childrenRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children.prefix(maxChildrenPerNode) {
            dumpAXTree(child, depth: depth + 1, maxDepth: maxDepth, maxChildrenPerNode: maxChildrenPerNode)
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
