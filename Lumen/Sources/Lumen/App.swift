import SwiftUI
import AppKit
import ApplicationServices

// Menu bar toggle for Lumen's automatic (as-you-type) suggestions.
// State is a single file the zsh plugin polls before firing an automatic
// suggestion (see _ai_suggest_auto_enabled in ai-suggest.plugin.zsh) — this
// app and the shell plugin are separate processes with no shared memory, so
// a file is the simplest thing that works across both, and reading one small
// file per keystroke is cheap enough not to matter.
//
// Manual suggestions (Ctrl-Space in the shell) are NOT gated by this state
// on purpose: the point of the toggle is to let automatic suggestions stay
// off by default and only turn on when wanted, not to block an explicit ask.

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/ai-suggest")
let stateFile = stateDir.appendingPathComponent("enabled")

final class ToggleState: ObservableObject {
    @Published var enabled: Bool

    init() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if let raw = try? String(contentsOf: stateFile, encoding: .utf8) {
            enabled = raw.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
        } else {
            enabled = true
            persist()
        }
    }

    func toggle() {
        enabled.toggle()
        persist()
    }

    private func persist() {
        try? (enabled ? "1" : "0").write(to: stateFile, atomically: true, encoding: .utf8)
    }
}

struct MenuContent: View {
    @ObservedObject var state: ToggleState
    @State private var quitHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Lumen")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Toggle(isOn: Binding(get: { state.enabled }, set: { _ in state.toggle() })) {
                    Text("Automatic suggestions")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack(spacing: 5) {
                    Circle()
                        .fill(state.enabled ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 5.5, height: 5.5)
                    Text(state.enabled
                         ? "Fires as you type in new shells"
                         : "Paused — Ctrl-Space still works")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 10.5))
                    Text("Quit Lumen")
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(quitHovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .onHover { quitHovering = $0 }
        }
        .frame(width: 220)
        .background(.regularMaterial)
    }
}

/// Bridges incoming overlay socket messages to the panel: parses the JSON
/// dict from OverlayServer into candidates/selection/cursor info and calls
/// OverlayController.show/hide accordingly. A separate object (rather than
/// folding this into LumenApp) so the parsing logic has a
/// concrete owner instead of living inline in a closure.
final class OverlayBridge {
    private let server: OverlayServer
    private let controller = OverlayController()

    // Positions pushed directly by a terminal app's own process (currently just TermHub — see
    // `cursorScreenPosition` below), keyed by that process's pid. Checked ahead of the
    // AX-based `TerminalPositioner.anchor(for:)` lookup: for apps that push their own position,
    // it's authoritative and skips `NSAccessibility` entirely — added because that query path,
    // despite the underlying math on TermHub's own side being independently confirmed correct,
    // was still sometimes answered with a stale/unflipped value by macOS's own accessibility
    // bridging, in a way tracing narrowed down but couldn't fully pin to one root cause. Apps
    // that don't push anything (iTerm2, Terminal.app) are unaffected — they just never appear
    // in this dictionary, so the existing AX path runs exactly as before.
    private var pushedCursorPositions: [pid_t: TerminalPositioner.ScreenAnchor] = [:]

    init(socketPath: String) {
        server = OverlayServer(socketPath: socketPath)
        server.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    func start() {
        server.start()
    }

    private func handle(_ message: [String: Any]) {
        if message["hide"] as? Bool == true {
            controller.hide()
            return
        }

        if let pos = message["cursorScreenPosition"] as? [String: Any],
           let pid = pos["pid"] as? Int,
           let x = pos["x"] as? Double,
           let cellBottomY = pos["cellBottomY"] as? Double,
           let cellTopY = pos["cellTopY"] as? Double {
            pushedCursorPositions[pid_t(pid)] = TerminalPositioner.ScreenAnchor(
                x: x, cellTopY: cellTopY, cellBottomY: cellBottomY
            )
            return
        }

        if message["dumpAXTree"] as? Bool == true {
            TerminalPositioner.dumpAXTreeForFrontmostApp()
            return
        }

        // Diagnostic only: rather than requiring the trigger and "the
        // target app becoming frontmost" to line up within the same
        // instant (impossible over a chat round-trip — switching back to
        // reply always re-focuses whatever's driving the conversation),
        // poll until the named app is actually frontmost, then dump. Lets
        // the person just switch to the target app whenever they're ready,
        // any time within the window, with no precise timing required.
        if let namePart = message["waitAndDumpApp"] as? String {
            let timeout = (message["timeoutSeconds"] as? Double) ?? 30
            waitAndDump(matching: namePart.lowercased(), deadline: Date().addingTimeInterval(timeout))
            return
        }

        guard
            let candidateStrings = message["candidates"] as? [String],
            let descriptions = message["descriptions"] as? [String],
            let labels = message["labels"] as? [String],
            let selectedIndex = message["selectedIndex"] as? Int,
            let cursorRow = message["cursorRow"] as? Int,
            let cursorCol = message["cursorCol"] as? Int,
            let columns = message["columns"] as? Int,
            let lines = message["lines"] as? Int
        else { return }

        // Optional: older shell-plugin builds (before the icons field was
        // added) simply won't send it, so a missing/short array falls back
        // to CandidateIcon's own default (.command) per row rather than
        // failing the whole guard above.
        let icons = message["icons"] as? [String] ?? []
        let candidates = labels.indices.map { i in
            OverlayCandidate(
                label: labels[i],
                description: i < descriptions.count ? descriptions[i] : "",
                icon: CandidateIcon(raw: i < icons.count ? icons[i] : nil)
            )
        }
        _ = candidateStrings // the raw insertable text isn't needed for display, only labels/descriptions are

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pushedAnchor = frontmostPID.flatMap { pushedCursorPositions[$0] }
        let cursor = TerminalPositioner.CursorInfo(row: cursorRow, col: cursorCol, columns: columns, lines: lines)
        guard let anchor = pushedAnchor ?? TerminalPositioner.anchor(for: cursor) else { return }

        controller.show(candidates: candidates, selectedIndex: selectedIndex, at: anchor, anchoredPID: frontmostPID)
    }

    private func waitAndDump(matching namePart: String, deadline: Date) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let name = frontmost?.localizedName?.lowercased() ?? ""
        let bundleId = frontmost?.bundleIdentifier?.lowercased() ?? ""
        if name.contains(namePart) || bundleId.contains(namePart) {
            debugLog("Lumen: [ax-dump] matched \"\(namePart)\" -> "
                + "\(frontmost?.localizedName ?? "?"), dumping now")
            TerminalPositioner.dumpAXTreeForFrontmostApp()
            return
        }
        guard Date() < deadline else {
            debugLog("Lumen: [ax-dump] timed out waiting for \"\(namePart)\" to become frontmost "
                + "(last seen: \(frontmost?.localizedName ?? "?"))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitAndDump(matching: namePart, deadline: deadline)
        }
    }
}

@main
struct LumenApp: App {
    @StateObject private var state = ToggleState()
    private let overlayBridge = OverlayBridge(
        socketPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/ai-suggest/overlay.sock").path
    )

    init() {
        // No Dock icon, no app-switcher entry — menu bar only.
        NSApplication.shared.setActivationPolicy(.accessory)
        overlayBridge.start()

        // Triggers macOS's own native Accessibility permission dialog
        // (with a direct "Open System Settings" button) instead of relying
        // on the user finding and manually adding this app themselves —
        // manual list-editing across rebuilds was unreliable during
        // development (see TerminalPositioner's comment on ad-hoc code
        // signatures). Harmless to call every launch: a no-op once already
        // trusted, and macOS only actually shows the prompt once per app
        // identity regardless of how often this runs.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        debugLog("Lumen: AXIsProcessTrustedWithOptions(prompt)=\(trusted)")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.enabled ? "sparkles" : "pause.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
