import AppKit

/// Reduce Motion, read once for the whole app (design/review-page/BRIEF.md E11): the system's setting, or the debug
/// item's override (`reducemotion on|off|system`) and the tests'. The column and its window, the find bar, the tabs,
/// the map, the flash, the PDF's reveal and the panel's scroll all ask here.
enum Motion {
    nonisolated(unsafe) static var override: Bool?
    @MainActor static var reduced: Bool { override ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// When the column's window opens, moves and closes (BRIEF §4.1; mac/UX.md §42.3), kept apart from the column's
/// drawing and the window's rows. Pure but for its timers: the column tells it where the pointer is and what is
/// pressed, and it says what changed. Positions are the column's (y down, from its top).
@MainActor
final class LaneHover {
    /// A cold open waits this long with the pointer within `slop` (twice the overview's 150 ms: the column lies on the
    /// page's margin, where a reader parks the pointer). Named, to be tuned with the advisor's own mouse.
    static var dwell: TimeInterval = 0.3
    static let slop: CGFloat = 3
    /// A zone entered this soon after a window closed opens at once (`OverviewHover`'s rule).
    static let warm: TimeInterval = 0.6
    /// On the way to the window, a zone crossed inside the triangle takes over only after this rest.
    static let aim: TimeInterval = 0.15
    /// The window stays this long after the pointer left both its zone and it.
    static let grace: TimeInterval = 0.25

    enum Change: Equatable { case grow, open(instant: Bool), glide, close(fade: Bool), pointer }

    /// The group drawn grown, the window's group, and whether the button is down in a zone (drawn at rest size).
    private(set) var grown: Int?
    private(set) var shown: Int?
    private(set) var pressed = false
    private(set) var inWindow = false
    /// The group under the pointer when the window closed at once (a click, Esc, a key): it previews again only once
    /// the pointer has left it.
    private(set) var blocked: Int?
    /// The pointer's zone and place, nil off the column's zones.
    private(set) var zone: Int?
    private(set) var pointer: CGPoint?
    /// The window's frame in the column's coordinates while it shows, for the aim's triangle.
    var windowFrame: CGRect?
    /// Whether a window may open now (no button down, no scroll, no other float; BRIEF §4.1); asked when it would.
    var canOpen: () -> Bool = { true }
    var changed: (Change) -> Void = { _ in }

    private var lastClosed: TimeInterval = -.infinity
    private var rest: (at: CGPoint, group: Int)?
    private var exit: CGPoint?  // the last point in the shown group's zone
    private var aimAt: (group: Int, at: CGPoint)?
    private var dwellTimer: Timer?
    private var graceTimer: Timer?
    private var aimTimer: Timer?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The pointer is in group `g`'s zone at `p`, or (nil) in no zone.
    func point(_ g: Int?, at p: CGPoint?) {
        zone = g
        pointer = p
        if let b = blocked, g != b { blocked = nil }
        guard let g, let p else { return left() }
        graceTimer?.invalidate()
        graceTimer = nil
        if let s = shown {
            if g == s {
                cancelAim()
                exit = p
                if grown != g { grown = g; changed(.grow) }
                changed(.pointer)  // a find run's rows follow the pointer
                return
            }
            // another group while the window shows: inside the triangle to the window, it waits for a rest (aim)
            if let e = exit, let w = windowFrame, Self.inTriangle(p, e, CGPoint(x: w.maxX, y: w.minY), CGPoint(x: w.maxX, y: w.maxY)) {
                if aimAt?.group != g || hypot(p.x - aimAt!.at.x, p.y - aimAt!.at.y) > Self.slop {
                    aimAt = (g, p)
                    aimTimer?.invalidate()
                    aimTimer = timer(Self.aim) { [weak self] in
                        guard let self, self.zone == g, self.shown != nil else { return }
                        self.take(g)
                    }
                }
                return
            }
            return take(g)
        }
        if grown != g { grown = g; changed(.grow) }
        guard g != blocked, !pressed else { return }
        if now - lastClosed < Self.warm, canOpen() { return open(g, instant: true) }
        if rest?.group != g || hypot(p.x - rest!.at.x, p.y - rest!.at.y) > Self.slop {
            rest = (p, g)
            dwellTimer?.invalidate()
            dwellTimer = timer(Self.dwell) { [weak self] in
                guard let self, self.zone == g, self.shown == nil, self.blocked != g, !self.pressed, self.canOpen() else { return }
                self.open(g, instant: false)
            }
        }
    }

    /// Off every zone: no dwell; the window, if it shows and the pointer is not in it, goes after the grace.
    private func left() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        rest = nil
        cancelAim()
        if shown != nil {
            if !inWindow { startGrace() }
        } else if grown != nil, !pressed {
            grown = nil
            changed(.grow)
        }
    }

    func enterWindow() {
        inWindow = true
        graceTimer?.invalidate()
        graceTimer = nil
        cancelAim()
    }

    func leaveWindow() {
        inWindow = false
        if zone == nil, shown != nil { startGrace() }
    }

    /// The button down in a zone (drawn at rest size until it comes up), or up.
    func press(_ down: Bool) {
        guard pressed != down else { return }
        pressed = down
        if down { dwellTimer?.invalidate() }
        changed(.grow)
    }

    /// Closes the window at once (a click, Esc, a key, a zoom, Find, change marks, another round: BRIEF §4.1); the group
    /// under the pointer stays grown and previews again once the pointer has left it.
    func closeNow() {
        dwellTimer?.invalidate()
        graceTimer?.invalidate()
        graceTimer = nil
        cancelAim()
        rest = nil
        blocked = zone
        guard shown != nil else { return }
        shown = nil
        lastClosed = now
        windowFrame = nil
        if grown != zone { grown = zone }
        changed(.close(fade: false))
    }

    /// The column laid again under the window: the shown group's new index (nil: it is gone, and the window closes).
    func remap(shown g: Int?) {
        guard shown != nil else { return }
        guard let g else { return closeNow() }
        shown = g
        grown = g
        zone = g
    }

    /// Another paper or round, Review hidden, the column gone: nothing grown, nothing shown, nothing waiting.
    func reset() {
        let had = shown != nil || grown != nil
        dwellTimer?.invalidate()
        graceTimer?.invalidate()
        graceTimer = nil
        cancelAim()
        shown = nil
        grown = nil
        zone = nil
        pointer = nil
        blocked = nil
        pressed = false
        inWindow = false
        rest = nil
        windowFrame = nil
        if had { changed(.close(fade: false)) }
    }

    private func open(_ g: Int, instant: Bool) {
        dwellTimer?.invalidate()
        shown = g
        grown = g
        exit = pointer
        changed(.open(instant: instant))
    }

    private func take(_ g: Int) {
        cancelAim()
        shown = g
        grown = g
        exit = pointer
        changed(.glide)
    }

    private func startGrace() {
        guard graceTimer == nil else { return }
        graceTimer = timer(Self.grace) { [weak self] in
            guard let self else { return }
            self.graceTimer = nil
            guard self.shown != nil, !self.inWindow, self.zone == nil else { return }
            self.shown = nil
            self.grown = nil
            self.windowFrame = nil
            self.lastClosed = self.now
            self.changed(.close(fade: true))
        }
    }

    private func cancelAim() {
        aimTimer?.invalidate()
        aimTimer = nil
        aimAt = nil
    }

    private func timer(_ t: TimeInterval, _ run: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: t, repeats: false) { _ in MainActor.assumeIsolated { run() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Whether `p` is inside the triangle a, b, c.
    nonisolated static func inTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (p.x - r.x) * (q.y - r.y) - (q.x - r.x) * (p.y - r.y) }
        let d1 = side(p, a, b), d2 = side(p, b, c), d3 = side(p, c, a)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }
}

/// The column beside the scroller (BRIEF §3; mac/UX.md §42): one AppKit view in the PDF view, under the find's button,
/// clear of the scroller, drawn in layers (one per glyph, by a stable id), so a scroll moves nothing in it and a hover
/// redraws only the group it grows. Only its zones take the mouse, and not where an id label or a link is under the
/// pointer: elsewhere the page has the clicks, drags and right button; the scroll wheel always goes to the PDF.
final class MarkLane: NSView {
    weak var controller: PDFController?
    private(set) var laneLayout = StripLayout.Layout()
    private(set) var items: [ScrollerMark] = []
    private(set) var find = false
    /// The glyph with the selection's halo, the current match's y, and a grown run's match nearest the pointer.
    private(set) var halo: Int?
    private(set) var current: CGFloat?
    private(set) var near: CGFloat?
    private(set) var rail = false
    /// The group drawn grown, and whether the button is down in it.
    private(set) var grown: Int?
    private(set) var pressed = false
    private var glyphLayers: [String: CAShapeLayer] = [:]
    private let haloLayer = CAShapeLayer()
    private let currentLayer = CAShapeLayer()
    private let nearLayer = CAShapeLayer()
    private let railLayer = CALayer()
    private var elements: [LaneElement] = []
    /// The column's top in the view: zones reach `StripLayout.above` over it, so the view starts that much higher.
    static let pad = StripLayout.above

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [haloLayer, currentLayer, nearLayer] {
            l.fillColor = nil
            l.zPosition = 2
            layer?.addSublayer(l)
        }
        haloLayer.strokeColor = LaneInk.selected.cgColor
        haloLayer.lineWidth = 1.5
        currentLayer.fillColor = LaneInk.selected.cgColor
        currentLayer.zPosition = 3
        nearLayer.fillColor = LaneInk.find.cgColor
        nearLayer.zPosition = 3
        // over printed text when zoomed in: white at 80% with a hairline, in both appearances (the page is white)
        railLayer.backgroundColor = NSColor(white: 1, alpha: 0.8).cgColor
        railLayer.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        railLayer.borderWidth = 0.5
        railLayer.cornerRadius = 8
        railLayer.zPosition = -1
        railLayer.isHidden = true
        layer?.addSublayer(railLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Marks")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Column y (from the column's top) to this view's y, and back.
    private func local(_ y: CGFloat) -> CGFloat { y + Self.pad }
    func column(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - Self.pad) }

    // MARK: Drawing

    /// New items or a new layout: the glyphs' layers kept by id, new ones added, gone ones removed, all at rest size.
    func set(_ items: [ScrollerMark], layout: StripLayout.Layout, find: Bool) {
        self.items = items
        self.laneLayout = layout
        self.find = find
        var keep = Set<String>()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in laneLayout.glyphs {
            keep.insert(g.id)
            let l = glyphLayers[g.id] ?? {
                let l = CAShapeLayer()
                l.lineCap = .round
                layer?.addSublayer(l)
                glyphLayers[g.id] = l
                return l
            }()
            draw(l, g, grown: false)
        }
        for (id, l) in glyphLayers where !keep.contains(id) {
            l.removeFromSuperlayer()
            glyphLayers[id] = nil
        }
        CATransaction.commit()
        grown = nil
        pressed = false
        near = nil
        placeExtras(animated: false)
        updateAccessibility()
    }

    private func draw(_ l: CAShapeLayer, _ g: StripLayout.Glyph, grown: Bool) {
        var (r, stroke) = StripLayout.box(g, grown: grown)
        r.origin.y = local(r.origin.y)
        let ink: NSColor
        switch g.shape {
        case .ring, .capsule: ink = LaneInk.ring
        case .tick, .unaskedTick: ink = LaneInk.edit
        case .findTick, .run: ink = LaneInk.find
        }
        if stroke > 0 {  // the path down the stroke's middle, so its outer edge is the box
            let p = r.insetBy(dx: stroke / 2, dy: stroke / 2)
            l.path = CGPath(roundedRect: p, cornerWidth: p.width / 2, cornerHeight: min(p.width, p.height) / 2, transform: nil)
            l.lineWidth = stroke
            l.strokeColor = ink.cgColor
            l.fillColor = nil
        } else {
            let c = min(r.width, r.height) / 2
            l.path = CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
            l.lineWidth = 0
            l.strokeColor = nil
            l.fillColor = ink.cgColor
        }
        l.zPosition = grown ? 1 : 0  // grown glyphs over their neighbours
    }

    /// The selection's halo (at once, no motion), the current match and the rail.
    func setHalo(_ glyph: Int?, current: CGFloat?, rail: Bool) {
        halo = glyph
        self.current = current
        self.rail = rail
        placeExtras(animated: false)
    }

    /// The group under the pointer grows (BRIEF §4.2): each of its glyphs drawn at its new size, path and line width
    /// animated together (120 ms ease-out; back in 160 ms ease-in-out); at once with Reduce Motion or while pressed.
    /// `near`: on a grown run, the match a click opens.
    func setGrown(_ g: Int?, pressed: Bool, near: CGFloat?) {
        let before = grown, wasPressed = self.pressed
        grown = g
        self.pressed = pressed
        self.near = near
        let changedGroups = Set([before, g].compactMap { $0 })
        if before != g || wasPressed != pressed {
            CATransaction.begin()
            let growing = g != nil && !pressed
            if Motion.reduced || pressed || wasPressed {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(growing ? 0.12 : 0.16)
                CATransaction.setAnimationTimingFunction(growing ? CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
                                                         : CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1))
            }
            for k in changedGroups where k < laneLayout.groups.count {
                for gi in laneLayout.groups[k].glyphs {
                    let gl = laneLayout.glyphs[gi]
                    if let l = glyphLayers[gl.id] { draw(l, gl, grown: k == g && !pressed) }
                }
            }
            CATransaction.commit()
        }
        placeExtras(animated: false)
    }

    private func placeExtras(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let h = halo, h < laneLayout.glyphs.count {
            let g = laneLayout.glyphs[h]
            var r = StripLayout.haloBox(g, grown: g.group == grown && !pressed)
            r.origin.y = local(r.origin.y)
            let p = r.insetBy(dx: 0.75, dy: 0.75)
            haloLayer.path = CGPath(roundedRect: p, cornerWidth: min(p.width, p.height) / 2, cornerHeight: min(p.width, p.height) / 2,
                                    transform: nil)
            haloLayer.isHidden = false
        } else {
            haloLayer.isHidden = true
        }
        if let y = current {
            let up = laneLayout.group(at: y) == grown && grown != nil && !pressed
            var r = StripLayout.currentBox(y: y, grown: up)
            r.origin.y = local(r.origin.y)
            currentLayer.path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
            currentLayer.isHidden = false
        } else {
            currentLayer.isHidden = true
        }
        if let y = near, grown != nil, !pressed {
            var r = StripLayout.nearBox(y: y)
            r.origin.y = local(r.origin.y)
            nearLayer.path = CGPath(roundedRect: r, cornerWidth: 1, cornerHeight: 1, transform: nil)
            nearLayer.isHidden = false
        } else {
            nearLayer.isHidden = true
        }
        railLayer.isHidden = !rail || laneLayout.glyphs.isEmpty
        railLayer.frame = CGRect(x: 0, y: Self.pad - 4, width: bounds.width, height: max(0, bounds.height - Self.pad - StripLayout.below + 8))
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        placeExtras(animated: false)
    }

    // MARK: The mouse

    /// The group whose zone holds a point of this view (nil: none, or the page's label or link is under it).
    func group(at p: CGPoint) -> Int? {
        guard p.x >= 0, p.x <= bounds.width, let g = laneLayout.group(at: column(p).y) else { return nil }
        let pageWins = MainActor.assumeIsolated { controller?.pageWins(at: convert(p, to: superview)) ?? false }
        return pageWins ? nil : g
    }

    /// Only a zone takes the mouse; a right or other button never (the page's own menu shows for that point).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sv = superview else { return nil }
        let p = convert(point, from: sv)
        guard bounds.contains(p) else { return nil }
        if let t = NSApp.currentEvent?.type, [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel].contains(t) {
            return nil
        }
        return group(at: p) == nil ? nil : self
    }

    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { moved(event) }
    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.lanePointer(nil, at: nil) }
    }

    private func moved(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let g = bounds.contains(p) ? group(at: p) : nil
        if g != nil { NSCursor.pointingHand.set() }  // set on every move: the PDF view sets its own under it
        MainActor.assumeIsolated { controller?.lanePointer(g, at: column(p)) }
    }

    /// A press in a zone: the group drawn at rest size until the button comes up; up inside the zone goes there, up
    /// outside does nothing; the second click of a double click does nothing.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let g = group(at: start), let window else { return }
        let ctl = controller
        if event.clickCount > 1 { return }
        MainActor.assumeIsolated { ctl?.lanePress(true) }
        var up: NSPoint?
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
                                       dequeue: true) {
            if e.type == .leftMouseUp { up = convert(e.locationInWindow, from: nil); break }
        }
        MainActor.assumeIsolated { ctl?.lanePress(false) }
        guard let p = up, bounds.contains(p), laneLayout.group(at: column(p).y) == g else { return }
        MainActor.assumeIsolated { ctl?.laneClick(g, at: column(p)) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if group(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    // MARK: VoiceOver (BRIEF §3.8)

    /// "16 to check, 19 edits" ("21 matches" in Find), and one element per item in page order (per page in Find), each
    /// pressed as a click is.
    private func updateAccessibility() {
        let shown = items.indices.sorted { (items[$0].fraction, $0) < (items[$1].fraction, $1) }
        if find {
            setAccessibilityValue(LaneText.matches(items.count))
        } else {
            let waits = items.filter { $0.kind == .toCheck || $0.kind == .unasked && $0.waits }.count
            let edits = items.filter { ($0.kind == .edit || $0.kind == .unasked) && $0.tick }.count
            setAccessibilityValue(edits > 0 ? "\(waits) to check, " + count(edits, "edit") : "\(waits) to check")
        }
        var out: [LaneElement] = []
        if find {
            var pages: [Int: [Int]] = [:]
            for i in shown { pages[items[i].page, default: []].append(i) }
            for p in pages.keys.sorted() {
                let idx = pages[p]!
                let e = LaneElement(lane: self, items: idx)
                e.setAccessibilityLabel("\(LaneText.matches(idx.count)), page \(p + 1)")
                out.append(e)
            }
        } else {
            for i in shown {
                let e = LaneElement(lane: self, items: [i])
                e.setAccessibilityLabel(items[i].label)
                out.append(e)
            }
        }
        elements = out
        setAccessibilityChildren(out)
        refreshCurrentLabel()
    }

    /// In Find the page holding the current match says so.
    func refreshCurrentLabel() {
        guard find, let cur = controller.flatMap({ c in MainActor.assumeIsolated { c.find.index } }) else { return }
        for e in elements {
            let idx = e.items
            let page = items[idx[0]].page
            var label = "\(LaneText.matches(idx.count)), page \(page + 1)"
            if idx.contains(where: { items[$0].target == .find(cur) }) { label += ", current match \(cur + 1) of \(items.count)" }
            e.setAccessibilityLabel(label)
        }
    }

    /// An element's frame on screen: its items' y in the column, the column's width.
    fileprivate func screenFrame(_ idx: [Int]) -> NSRect {
        let ys = idx.compactMap { $0 < laneLayout.ys.count ? laneLayout.ys[$0] : nil }
        let lo = (ys.min() ?? 0) - 4, hi = (ys.max() ?? 0) + 4
        let r = CGRect(x: 0, y: local(lo), width: bounds.width, height: hi - lo)
        guard let w = window else { return r }
        return w.convertToScreen(convert(r, to: nil))
    }

    fileprivate func press(_ idx: [Int]) {
        MainActor.assumeIsolated { controller?.laneAccessibilityPress(idx) }
    }
}

/// One of the column's VoiceOver elements: a comment's, an edit's, or a page's matches. Not a Tab stop.
final class LaneElement: NSAccessibilityElement {
    weak var lane: MarkLane?
    let items: [Int]

    init(lane: MarkLane, items: [Int]) {
        self.lane = lane
        self.items = items
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(lane)
    }

    override func accessibilityFrame() -> NSRect { lane?.screenFrame(items) ?? .zero }
    override func accessibilityPerformPress() -> Bool {
        lane?.press(items)
        return true
    }
}
