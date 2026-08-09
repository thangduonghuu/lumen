import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Row icon kind, mirrored from the zsh plugin's _AI_SUGGEST_ICONS —
/// "dir"/"branch" from the cd/git-branch matchers, or one of
/// _ai_suggest_tool_icon_kind's per-tool identifiers for everything from a
/// static/nested subcommand table (see _ai_suggest_overlay_show in
/// ai-suggest.plugin.zsh). Falls back to `.command` for anything empty or
/// unrecognized, so an older shell-side build without the "icons" field, or
/// a tool this build doesn't have a specific glyph for yet, still renders
/// (as the original plain "$" badge) instead of crashing the JSON parse.
enum CandidateIcon: String {
    case directory = "dir"
    case branch
    case git
    case docker
    case kubectl
    case npm
    case yarn
    case pnpm
    case aws
    case gcloud
    case az
    case terraform
    case helm
    case gh
    case glab
    case kafka
    case rabbitmq
    case command = "cmd"

    init(raw: String?) {
        self = CandidateIcon(rawValue: raw ?? "") ?? .command
    }
}

struct OverlayCandidate {
    let label: String
    let description: String
    let icon: CandidateIcon
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

    /// pid of the app the panel is currently anchored against (whatever was
    /// frontmost when `show` was last called). Used to tell "user switched
    /// away from the terminal" (hide) apart from "user switched between two
    /// windows of that same terminal app, or nothing changed" (leave it).
    private var anchoredPID: pid_t?
    private var activationObserver: NSObjectProtocol?

    init() {
        // NSWorkspace.didActivateApplicationNotification fires for every
        // app activation, including Cmd-Tab and clicking another app's
        // window — exactly "the terminal lost focus" from the user's
        // perspective, without needing anything from the zsh plugin (a
        // focus switch produces no keystroke, so there'd be nothing to
        // trigger a hide from the shell side).
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleActivation(notification)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    private func handleActivation(_ notification: Notification) {
        guard let anchoredPID else { return }
        let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .processIdentifier
        guard activatedPID != anchoredPID else { return }
        hide()
    }

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
    ///
    /// `anchoredPID` is the pid of the app this anchor was computed
    /// against (the frontmost app at the time), so a later switch away from
    /// it can auto-hide the panel — see `handleActivation`. Pass nil if
    /// unknown; the panel just won't auto-hide on app switch in that case.
    func show(
        candidates: [OverlayCandidate],
        selectedIndex: Int,
        at anchor: TerminalPositioner.ScreenAnchor,
        anchoredPID: pid_t?
    ) {
        self.anchoredPID = anchoredPID
        state.candidates = candidates
        state.selectedIndex = selectedIndex

        let panel = panel ?? makePanel()
        self.panel = panel

        let hosting: NSHostingView<OverlayContentView>
        if let existing = panel.contentView as? NSHostingView<OverlayContentView> {
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: OverlayContentView(state: state, onSelect: { [weak self] idx in
                self?.acceptCandidate(at: idx)
            }))
            panel.contentView = hosting
        }

        // .fittingSize on a just-created NSHostingView, before it's been
        // through a layout pass as part of the panel's view hierarchy, can
        // report a stale/oversized value (observed: large enough that the
        // "not enough room below" branch below fires on the very first
        // suggestion of a session even near the top of a tall window,
        // flipping the panel above the cursor instead of below it).
        // Forcing a layout pass first makes fittingSize reflect the real
        // SwiftUI-measured content size.
        hosting.layoutSubtreeIfNeeded()
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
        debugLog("Lumen: overlay panel: fitting=\(fitting) anchor=\(anchor) "
            + "belowOrigin=\(belowOrigin) screenMinY=\(screenMinY) chose=\(belowOrigin.y >= screenMinY ? "below" : "flipped-above")")
    }

    func hide() {
        panel?.orderOut(nil)
        anchoredPID = nil
    }

    /// Handles a click on candidate row `idx`. There's no back-channel from
    /// this app to the zsh plugin (OverlayServer is fire-and-forget,
    /// shell -> app only — see its header comment), and the plugin's Tab
    /// widget only ever accepts whatever candidate it currently considers
    /// selected (`_AI_SUGGEST_CANDIDATES[$_AI_SUGGEST_INDEX]`). So a click
    /// is turned into the same real keystrokes Up/Down/Tab navigation
    /// already sends — Down/Up-arrow `delta` times to walk the shell's own
    /// selection over to `idx` (its modulo-wrapping cycle logic, see
    /// _ai_suggest_move in ai-suggest.plugin.zsh, makes this exact), then
    /// Tab to accept — posted straight to the anchored terminal's pid via
    /// Quartz Event Services rather than needing the terminal to be key/
    /// frontmost (`.nonactivatingPanel` means clicking this panel doesn't
    /// activate Lumen.app or steal focus, so the terminal never stops being
    /// the target). Reuses the same Accessibility grant already required
    /// for cursor positioning — no extra permission prompt.
    private func acceptCandidate(at idx: Int) {
        guard let pid = anchoredPID, state.candidates.indices.contains(idx) else {
            debugLog("Lumen: overlay click ignored: anchoredPID=\(String(describing: anchoredPID)) "
                + "idx=\(idx) candidateCount=\(state.candidates.count)")
            return
        }
        let delta = idx - state.selectedIndex
        debugLog("Lumen: overlay click idx=\(idx) selectedIndex=\(state.selectedIndex) delta=\(delta) "
            + "pid=\(pid) AXIsProcessTrusted=\(AXIsProcessTrusted())")
        let stepKey: CGKeyCode = delta >= 0 ? 0x7D : 0x7E // Down arrow : Up arrow
        for _ in 0..<abs(delta) {
            postKey(stepKey, toPID: pid)
        }
        postKey(0x30, toPID: pid) // Tab — accepts the now-selected candidate
    }

    private func postKey(_ keyCode: CGKeyCode, toPID pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.postToPid(pid)
        up.postToPid(pid)
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
    let onSelect: (Int) -> Void

    @State private var hoveredIndex: Int?

    private var selectedDescription: String? {
        guard state.candidates.indices.contains(state.selectedIndex) else { return nil }
        let desc = state.candidates[state.selectedIndex].description
        return desc.isEmpty ? nil : desc
    }

    /// Number of rows visible before the list scrolls instead of growing
    /// further — pinned via `rowHeight` below rather than left to font
    /// metrics, so this stays exactly 5 regardless of system font size.
    private let visibleRowCount = 5
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 2
    private var maxListHeight: CGFloat {
        CGFloat(visibleRowCount) * rowHeight + CGFloat(visibleRowCount - 1) * rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(Array(state.candidates.enumerated()), id: \.offset) { idx, candidate in
                            let selected = idx == state.selectedIndex
                            HStack(spacing: 8) {
                                iconBadge(for: candidate.icon)
                                Text(candidate.label)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(selected ? .bold : .regular)
                                    .foregroundStyle(selected ? .primary : .secondary)
                                Spacer(minLength: 12)
                            }
                            .frame(height: rowHeight)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        selected ? Color.accentColor.opacity(0.28)
                                            : idx == hoveredIndex ? Color.primary.opacity(0.08)
                                            : Color.clear
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(idx) }
                            .onHover { hovering in hoveredIndex = hovering ? idx : nil }
                            .id(idx)
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
                // Keyboard-driven selection (see _ai_suggest_move in
                // ai-suggest.plugin.zsh) can move selectedIndex outside the
                // currently scrolled-to viewport; follow it so Down/Up
                // arrows past the visible rows keep the selection in view
                // the same way mouse-scrolling does.
                .onChange(of: state.selectedIndex) { newValue in
                    proxy.scrollTo(newValue, anchor: nil)
                }
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

    /// One badge per row, uniform size/shape (fixed-width so labels stay
    /// column-aligned down the list) so brand logos and the generic glyphs
    /// sit consistently regardless of kind. Brand-specific cases (git,
    /// docker, kubectl, ...) render the tool's actual logo — real SVG marks
    /// bundled into the app (Sources/Lumen/Resources/*.svg,
    /// sourced from the Simple Icons project, official brand color baked
    /// into each file — see the shell script this was fetched with), not a
    /// generic system glyph standing in for it. Directory/branch/fallback
    /// rows have no associated company, so those three keep using SF
    /// Symbols with a hand-picked accent color instead.
    @ViewBuilder
    private func iconBadge(for icon: CandidateIcon) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.07))
            switch icon {
            case .directory:
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color(red: 0.30, green: 0.55, blue: 0.90))
            case .branch:
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color(red: 0.86, green: 0.55, blue: 0.20))
            case .command:
                Text("$")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.53, green: 0.37, blue: 0.69))
            default:
                if let logo = brandImage(for: icon) {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                } else {
                    // Missing bundled asset (shouldn't happen for a shipped
                    // build) — fall back to a neutral placeholder rather
                    // than an empty badge.
                    Image(systemName: "square.dashed")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 20, height: 18)
    }

    /// Loads a bundled brand SVG by `CandidateIcon`'s raw value (which is
    /// exactly the asset's filename minus extension — e.g. `.docker` reads
    /// Resources/docker.svg) and caches the decoded NSImage: this view's
    /// body re-runs on every keystroke while suggestions are showing, and
    /// re-decoding the same handful of SVGs from disk that often would be
    /// wasted work for images that never change.
    ///
    /// Looked up under `Contents/Resources/` (where build.sh places the
    /// resource bundle) rather than via `Bundle.module`: SwiftPM's generated
    /// accessor only ever checks the app bundle's top level or a hardcoded
    /// absolute dev-machine path, and content sitting at the app bundle's
    /// top level (sibling of `Contents/`) fails `codesign` on current
    /// toolchains ("unsealed contents present in the bundle root") — signing
    /// only ever seals `Contents/`. `Bundle.module` is kept as a fallback so
    /// this still resolves when running unpackaged during development.
    private func brandImage(for icon: CandidateIcon) -> NSImage? {
        let name = icon.rawValue
        if let cached = Self.brandImageCache[name] { return cached }
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("Lumen_Lumen.bundle/Resources/\(name).svg")
        let url = packagedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        Self.brandImageCache[name] = image
        return image
    }

    private static var brandImageCache: [String: NSImage] = [:]
}
