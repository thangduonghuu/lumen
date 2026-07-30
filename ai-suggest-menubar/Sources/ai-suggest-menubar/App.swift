import SwiftUI
import AppKit

// Menu bar toggle for ai-suggest's automatic (as-you-type) suggestions.
// State is a single file the zsh plugin polls before firing an automatic
// suggestion (see _ai_suggest_enabled in ai-suggest.plugin.zsh) — this app
// and the shell plugin are separate processes with no shared memory, so a
// file is the simplest thing that works across both, and reading one small
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

    var body: some View {
        Button(state.enabled ? "Disable automatic suggestions" : "Enable automatic suggestions") {
            state.toggle()
        }
        Text(state.enabled
             ? "Suggestions fire as you type in new shells."
             : "Suggestions are paused. Ctrl-Space still works.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@main
struct AiSuggestMenuBarApp: App {
    @StateObject private var state = ToggleState()

    init() {
        // No Dock icon, no app-switcher entry — menu bar only.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra(state.enabled ? "✨" : "⏸") {
            MenuContent(state: state)
        }
    }
}
