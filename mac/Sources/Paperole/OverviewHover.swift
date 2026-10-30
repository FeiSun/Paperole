import AppKit
import SwiftUI

/// What the pointer is over in the overview (OVERVIEW-v2 §5.1 "悬停"): the map's target (its dashed ring and its row's
/// section names), a comment hovered anywhere (its path previewed dashed on the map), and the help tag, which the
/// overview draws itself, at once: an NSView help tag waits about a second and cannot point at part of a Canvas. Kept
/// apart from `OverviewModel`, so a move of the pointer redraws the hover layer and the tag, never the map.
@MainActor
final class OverviewHover: ObservableObject {
    struct Tip: Equatable {
        var lines: [String]
        /// The pointer, in the overview's visible frame (`OverviewLayout.viewport`).
        var at: CGPoint
        var key: String
    }

    @Published private(set) var target: MapTarget?
    @Published private(set) var comment: String?
    @Published private(set) var tip: Tip?
    /// The map's and the strip's top left in the overview's visible frame, for their tags (they hit-test in their own
    /// coordinates); written as the overview scrolls, read only when a tag is shown.
    var mapOrigin: CGPoint = .zero
    var stripOrigin: CGPoint = .zero
    /// The map drawn last, for the debug script's `ovhover` (it points at a thing by its name).
    var scene: MapScene?
    /// The help tag shows this long after the pointer comes to rest on something; at once while another was just shown
    /// (as the system's do).
    static let delay: TimeInterval = 0.35
    private var key: String?
    private var task: Task<Void, Never>?
    private var lastShown: TimeInterval = 0

    /// The pointer is over `key` (nil: nothing with a tag) at `p`: `target` and `comment` change at once, the tag after
    /// the delay. `lines` is asked for only when the tag shows. Nothing while the app is not active (a test run's
    /// window behind the others), unless `force` (the debug script's `ovhover`).
    func point(at p: CGPoint, key: String?, target: MapTarget? = nil, comment: String? = nil, force: Bool = false,
               lines: @escaping () -> [String]) {
        guard force || NSApp.isActive else { return }
        if self.target != target { self.target = target }
        if self.comment != comment { self.comment = comment }
        guard key != self.key else { return }
        self.key = key
        task?.cancel()
        if tip != nil { lastShown = ProcessInfo.processInfo.systemUptime; tip = nil }
        guard let key else { return }
        let warm = ProcessInfo.processInfo.systemUptime - lastShown < 0.6
        if force || warm {
            show(lines(), at: p, key: key)
            return
        }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.key == key else { return }
            self.show(lines(), at: p, key: key)
        }
    }

    private func show(_ lines: [String], at p: CGPoint, key: String) {
        tip = lines.isEmpty ? nil : Tip(lines: lines, at: p, key: key)
    }

    /// The pointer left `key` (nil: whatever it was over), or the overview.
    func leave(_ key: String? = nil) {
        guard key == nil || key == self.key else { return }
        task?.cancel()
        if tip != nil { lastShown = ProcessInfo.processInfo.systemUptime }
        self.key = nil
        if target != nil { target = nil }
        if comment != nil { comment = nil }
        if tip != nil { tip = nil }
    }

    /// A click: the tag goes (the thing clicked changes), the hover stays.
    func dismissTip() {
        task?.cancel()
        key = nil
        if tip != nil { tip = nil }
    }
}

/// The overview's help tags, over its scroll view, in its visible frame: under and right of the pointer, or above it
/// near the bottom, and never past the right edge.
struct OverviewTipLayer: View {
    @ObservedObject var hover: OverviewHover
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: size.width, height: size.height)  // the frame the tag's guides place it in
            if let t = hover.tip {
                MapTip(lines: t.lines)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in -max(8, min(t.at.x + 14, size.width - d.width - 8)) }
                    .alignmentGuide(.top) { d in -(t.at.y + 20 + d.height > size.height - 6 ? max(4, t.at.y - d.height - 10) : t.at.y + 20) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A help tag of the overview's own on a SwiftUI view (a panel's line or chip, a table's cell): the pointer in the
/// overview's visible frame, the lines asked for when the tag shows, and a comment to preview on the map.
struct OverviewHoverTip: ViewModifier {
    let hover: OverviewHover
    let key: String
    var comment: String?
    let lines: () -> [String]

    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .named(OverviewLayout.viewport)) { phase in
            switch phase {
            case .active(let p): hover.point(at: p, key: key, comment: comment, lines: lines)
            case .ended: hover.leave(key)
            }
        }
    }
}

extension View {
    func overviewTip(_ hover: OverviewHover, key: String, comment: String? = nil, lines: @escaping () -> [String]) -> some View {
        modifier(OverviewHoverTip(hover: hover, key: key, comment: comment, lines: lines))
    }
}

/// Text whose ○ is amber (OVERVIEW-v2 §4.7: amber only for ○).
func amberRings(_ s: String) -> Text {
    let parts = s.components(separatedBy: "○")
    var t = Text(parts[0])
    for p in parts.dropFirst() { t = t + Text("○").foregroundColor(Color(nsColor: Palette.toCheck)) + Text(p) }
    return t
}
