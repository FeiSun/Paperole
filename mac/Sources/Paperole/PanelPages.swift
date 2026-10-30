import AppKit
import SwiftUI

/// The switch between the Comments and Changes tabs (UX.md §1; v2.2, the advisor, 2026-10-18: "from the Comments tab
/// to Changes the blocks switch stiffly; a smooth animation from one to the other would be much better"). The shown
/// tab's segment slides to the other tab, and the pages under it slide the same way while they cross-fade, in 0.25 s,
/// eased out; at once with Reduce Motion. Both pages live as long as the panel (`PanelPager`), so each keeps its scroll
/// position, its rows and its expanded card or change, and a switch lays nothing out.
enum TabMotion {
    @MainActor static var duration: Double { 0.25 * slow }
    /// --debug-script motion: slowed down, so a screenshot catches a switch in flight.
    @MainActor static var slow = 1.0
    /// Ease-out (the standard one, CSS's and Core Animation's), for the segment and the pages alike.
    static let curve = (0.0, 0.0, 0.58, 1.0)
    /// The page left fades out over the switch's first 35%, the page shown fades in over the rest from 30%, so the two
    /// lists' words barely overlap (the shared-axis pattern of tabbed content); both slide the whole time.
    static let fadeOut = (0.0, 0.35), fadeIn = (0.3, 1.0)
    /// How far a page slides: an eighth of the panel, at most 56 pt. A whole panel's width read as a pager; this is
    /// enough to say which way the other tab is.
    static func shift(width: CGFloat) -> CGFloat { min(width * 0.125, 56) }

    /// Reduce Motion (System Settings › Accessibility › Display): no slide, no fade, the segment at once.
    @MainActor static var reduced: Bool { reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Tests: Reduce Motion on or off whatever the system's setting.
    @MainActor static var reduceOverride: Bool?

    /// The segment's animation, nil with Reduce Motion.
    @MainActor static var animation: Animation? {
        reduced ? nil : .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)  // .easeOut's
    }
}

/// The panel's two tabs (UX.md §1, POLISH §2.3; v2.2): a quiet track across the panel with the shown tab on a raised
/// segment (white with a soft shadow; a lighter grey in Dark Mode), as the system's segmented control at its large
/// size looks, but the segment slides to the tab clicked (`TabMotion`). 13 pt: the shown tab's name in the label
/// colour, the other's in the second label colour. Each tab says what is left to do there (UX.md §1, §16). Measured
/// once by the panel (`MeasuredOnce`, §10.10); it is SwiftUI's own text, so even that is cheap now.
struct PanelTabs: View {
    @Binding var tab: PanelTab
    let comments: String
    let changes: String
    @Environment(\.colorScheme) private var scheme
    static let height: CGFloat = 28

    /// The panel's tabs in the window (--debug-script focus: there are none in Focus).
    @MainActor static var shown = 0

    var body: some View {
        HStack(spacing: 0) {
            segment(.comments, comments)
            segment(.changes, changes)
        }
        .padding(2)
        .background { indicator }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.chipFill)))
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel")
        .onAppear { Self.shown += 1 }
        .onDisappear { Self.shown -= 1 }
    }

    /// The raised segment under the shown tab, sliding between the two halves.
    private var indicator: some View {
        GeometryReader { g in
            let w = max((g.size.width - 4) / 2, 0)
            RoundedRectangle(cornerRadius: 6)
                .fill(scheme == .dark ? Color.white.opacity(0.17) : .white)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(scheme == .dark ? 0 : 0.05), lineWidth: 0.5))
                .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.12), radius: 1.2, y: 0.6)
                .frame(width: w, height: max(g.size.height - 4, 0))
                .offset(x: 2 + (tab == .changes ? w : 0), y: 2)
                .animation(TabMotion.animation, value: tab)
        }
        .accessibilityHidden(true)
    }

    private func segment(_ t: PanelTab, _ title: String) -> some View {
        Button { if tab != t { tab = t } } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(tab == t ? Ink.label : Ink.label2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabSegmentStyle(shown: tab == t))
        .accessibilityAddTraits(tab == t ? [.isSelected] : [])
    }
}

/// A tab's segment: a quiet fill while it is pressed (the shown one is already raised).
private struct TabSegmentStyle: ButtonStyle {
    let shown: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Palette.hover))
                .opacity(configuration.isPressed && !shown ? 1 : 0))
    }
}

/// The Comments tab's page: the line of student notes not used (UX.md §3) and the comment list.
struct CommentsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // on this page whichever tab is shown, so it slides away with it
            if model.noteWarningsLine {
                NoteWarningsLine(warnings: model.noteWarnings, round: model.round?.n ?? 0, open: model.roundIsOpen,
                                 shown: $model.showNoteWarnings)
            }
            // the list's menu, with a filter's count and Show All (UX.md §27); Focus's panel is one card
            if !model.focus { CommentListBar(bar: model.listBar) }
            if !model.focus { Divider() }
            CommentList(panel: model.panel, actions: model.actions, edit: model.edit)
        }
    }
}

/// The Changes tab's page: its one sentence (UX.md §16) and the change list.
struct ChangesPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.focus, let header = ChangesHeader.text(model.state, left: model.toCheck) {
                Text(header)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if !model.focus { Divider() }
            ChangeList(panel: model.changes, actions: model.actions, edit: model.edit)
        }
    }
}

/// The two pages in one view (`PagerView`), the shown tab's in front.
struct PanelPager: NSViewRepresentable {
    let model: AppModel
    let tab: PanelTab

    func makeNSView(context: Context) -> PagerView {
        let pages: [NSView] = [AnyView(CommentsPage()), AnyView(ChangesPage())].map {
            let host = NSHostingView(rootView: AnyView($0.environmentObject(model)))
            host.sizingOptions = []  // the pager sets their frames: their content never resizes the panel
            return host
        }
        let v = PagerView(pages: pages)
        v.show(tab.page, animated: false)
        return v
    }

    func updateNSView(_ v: PagerView, context: Context) {
        v.show(tab.page, animated: !TabMotion.reduced && !context.transaction.disablesAnimations)
    }
}

extension PanelTab {
    /// Its page in the pager, in the tabs' order.
    var page: Int { self == .comments ? 0 : 1 }
}

/// Pages laid over each other, one shown. A switch moves the two pages' layers only, with Core Animation: the page
/// left slides `TabMotion.shift` toward the tab it leaves for and fades out in the first half; the page shown comes from
/// the other side and fades in; no view is laid out and SwiftUI updates nothing per frame. Clicks, the pointer and the
/// scroll wheel go to the shown page alone, from the start; the other is hidden once it has gone (a hidden list keeps
/// no hover, `PanelTableView.viewDidHide`). A switch during a switch starts from where the pages are.
final class PagerView: NSView {
    let pages: [NSView]
    private(set) var shown = -1
    /// The switch running: its number, so a switch that replaced it does not hide the page it shows.
    private var run = 0
    private(set) var animating = false

    init(pages: [NSView]) {
        self.pages = pages
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true  // the pages slide under the tabs' edge, never over the PDF
        for p in pages {
            p.frame = bounds
            p.autoresizingMask = [.width, .height]
            p.wantsLayer = true
            p.isHidden = true
            addSubview(p)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown >= 0, frame.contains(point) else { return nil }
        return pages[shown].hitTest(convert(point, from: superview))
    }

    func show(_ i: Int, animated: Bool) {
        guard i != shown, pages.indices.contains(i) else { return }
        let old = shown
        shown = i
        run += 1
        let incoming = pages[i]
        incoming.isHidden = false
        addSubview(incoming, positioned: .above, relativeTo: nil)  // in front: it takes the clicks at once
        guard animated, old >= 0, window != nil, bounds.width > 0,
              let inLayer = incoming.layer, let outLayer = pages[old].layer else {
            return settle()
        }
        let dir: CGFloat = i > old ? 1 : -1  // to Changes, the right-hand tab: the pages move left
        let shift = TabMotion.shift(width: bounds.width)
        // from where the pages are now: a switch back during a switch turns round
        let inFrom = presented(inLayer, x: dir * shift, opacity: 0), outFrom = presented(outLayer, x: 0, opacity: 1)
        let t = run
        animating = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.run == t else { return }
                self.settle()
            }
        }
        slide(inLayer, from: inFrom, to: (0, 1), fade: TabMotion.fadeIn)
        slide(outLayer, from: outFrom, to: (-dir * shift, 0), fade: TabMotion.fadeOut)
        CATransaction.commit()
    }

    /// Where a page's layer is drawn now: its slide and opacity, or the given ones when it is not moving.
    private func presented(_ layer: CALayer, x: CGFloat, opacity: Float) -> (x: CGFloat, opacity: Float) {
        guard layer.animation(forKey: "pager.move") != nil, let p = layer.presentation() else { return (x, opacity) }
        let moved = (p.value(forKeyPath: "transform.translation.x") as? NSNumber).map { CGFloat($0.doubleValue) }
        return (moved ?? x, p.opacity)
    }

    /// The slide over the whole switch, eased out; the fade over `fade` (fractions of it).
    private func slide(_ layer: CALayer, from: (x: CGFloat, opacity: Float), to: (x: CGFloat, opacity: Float),
                       fade: (start: Double, end: Double)) {
        let c = TabMotion.curve
        let timing = CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1), Float(c.2), Float(c.3))
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = from.x
        move.toValue = to.x
        move.timingFunction = timing
        let alpha = CAKeyframeAnimation(keyPath: "opacity")
        alpha.values = [from.opacity, from.opacity, to.opacity, to.opacity]
        alpha.keyTimes = [0, NSNumber(value: fade.start), NSNumber(value: fade.end), 1]
        let linear = CAMediaTimingFunction(name: .linear)
        alpha.timingFunctions = [linear, CAMediaTimingFunction(name: to.opacity > from.opacity ? .easeOut : .easeIn), linear]
        let group = CAAnimationGroup()
        group.animations = [move, alpha]
        group.duration = TabMotion.duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.removeAnimation(forKey: "pager.move")
        layer.add(group, forKey: "pager.move")
    }

    /// The switch is over: the shown page as it is, the others hidden.
    private func settle() {
        animating = false
        for (k, p) in pages.enumerated() {
            p.layer?.removeAnimation(forKey: "pager.move")
            if p.isHidden != (k != shown) { p.isHidden = k != shown }
        }
    }
}
