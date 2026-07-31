import AppKit
import SwiftUI

struct OverlayCandidate {
    let label: String
    let description: String
}

final class OverlayState: ObservableObject {
    @Published var candidates: [OverlayCandidate] = []
    @Published var selectedIndex: Int = 0
}

/// Owns the floating suggestion panel: a real NSPanel positioned outside
/// the terminal's character grid (see TerminalPositioner), instead of the
/// zsh plugin's ANSI POSTDISPLAY box. `.nonactivatingPanel` + never made
/// key means it never steals keyboard focus — all typing keeps going to
/// the terminal exactly as it does today; this panel is purely visual.
final class OverlayController {
    private var panel: NSPanel?
    private let state = OverlayState()

    /// `anchor` describes the cursor's own character cell on screen (both
    /// edges — see TerminalPositioner.ScreenAnchor). This picks whichever
    /// side actually fits once the panel's real size is known: anchor the
    /// panel's TOP at the cell's bottom edge (normal — panel appears below,
    /// touching the cursor's row) if there's room on screen for it, else
    /// anchor the panel's BOTTOM at the cell's top edge instead (flipped —
    /// panel appears above, touching the row from above), matching how a
    /// normal dropdown/autocomplete behaves near the bottom of a screen —
    /// the deciding factor is the panel's ACTUAL rendered height, which
    /// isn't known until the SwiftUI content below is measured, so this
    /// can't be decided any earlier (e.g. back in TerminalPositioner).
    func show(candidates: [OverlayCandidate], selectedIndex: Int, at anchor: TerminalPositioner.ScreenAnchor) {
        state.candidates = candidates
        state.selectedIndex = selectedIndex

        let panel = panel ?? makePanel()
        self.panel = panel

        let hosting: NSHostingView<OverlayContentView>
        if let existing = panel.contentView as? NSHostingView<OverlayContentView> {
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: OverlayContentView(state: state))
            panel.contentView = hosting
        }

        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        panel.setContentSize(fitting)

        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.x, y: anchor.cellBottomY)) }
            ?? NSScreen.main
        let screenMinY = screen?.frame.minY ?? 0

        // verticalGap (see PositionerConfig) leaves a small visible gap
        // between the panel and the cursor's row instead of touching it
        // exactly — pushes the panel further down when placed below, or
        // further up when flipped above, symmetric around the row either
        // way. Runtime-tunable so calibrating it doesn't need a rebuild.
        let gap = CGFloat(PositionerConfig.shared.verticalGap)
        let belowOrigin = NSPoint(x: anchor.x, y: anchor.cellBottomY - gap - fitting.height)
        if belowOrigin.y >= screenMinY {
            panel.setFrameOrigin(belowOrigin)
        } else {
            panel.setFrameOrigin(NSPoint(x: anchor.x, y: anchor.cellTopY + gap))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }
}

struct OverlayContentView: View {
    @ObservedObject var state: OverlayState

    private var selectedDescription: String? {
        guard state.candidates.indices.contains(state.selectedIndex) else { return nil }
        let desc = state.candidates[state.selectedIndex].description
        return desc.isEmpty ? nil : desc
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(state.candidates.enumerated()), id: \.offset) { idx, candidate in
                let selected = idx == state.selectedIndex
                HStack(spacing: 8) {
                    Text("$")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.53, green: 0.37, blue: 0.69))
                        )
                    Text(candidate.label)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(selected ? .bold : .regular)
                        .foregroundStyle(selected ? .primary : .secondary)
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear)
                )
            }
            if let desc = selectedDescription {
                Divider().padding(.top, 2)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 2)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .fixedSize()
    }
}
