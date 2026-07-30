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
    @State private var quitHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("ai-suggest")
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
                    Text("Quit ai-suggest")
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

@main
struct AiSuggestMenuBarApp: App {
    @StateObject private var state = ToggleState()

    init() {
        // No Dock icon, no app-switcher entry — menu bar only.
        NSApplication.shared.setActivationPolicy(.accessory)
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
