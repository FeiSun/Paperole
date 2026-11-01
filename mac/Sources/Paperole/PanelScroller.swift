import AppKit
import SwiftUI

/// Scrolls a panel list to its expanded card or change (UX.md §6 Panel scroll). The card's place comes from the list's
/// table (PanelTable), which knows every row's rect at once; the scrolling moves the table's NSScrollView, so it can
/// be animated briefly or done at once.
@MainActor
final class PanelScroller {
    weak var table: PanelTable?
    var scrollView: NSScrollView? { table?.scrollView }
    static let header: CGFloat = 34  // the floating section header covers the top of the viewport (POLISH §7)
    private var pending: (id: String, mode: ScrollMode, tries: Int)?
    /// The mode of the request not decided yet: the table reads it when the expanded card changes (`.slot`).
    var pendingMode: ScrollMode? { pending?.mode }
    /// What the last request decided (for --debug-script).
    private(set) var lastDecision = ""

    /// Called before the panel's expanded card changes; decides on the next turn of the run loop, when the table has
    /// laid out the new card (PanelTable keeps the new card's top where it was while a card above it collapses).
    func request(_ id: String, mode: ScrollMode) {
        pending = (id, mode, 0)
        DispatchQueue.main.async { [weak self] in self?.perform() }
    }

    private func perform() {
        guard let p = pending else { return }
        pending?.tries += 1
        guard p.tries < 40 else { pending = nil; return }
        guard let t = table, let sv = scrollView, sv.window != nil, sv.contentView.bounds.height > 0,
              let frame = t.frame(of: p.id, header: p.mode != .slot) else {
            // The panel is not on screen yet (at launch), or the card is not listed yet: wait for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.perform() }
            return
        }
        pending = nil
        let reduce = Motion.reduced
        let viewport = sv.contentView.bounds.height
        let minY = frame.minY - Self.header, maxY = frame.maxY - Self.header
        var d = ScrollDecision.decide(minY: minY, maxY: maxY, viewport: viewport - Self.header, mode: p.mode,
                                      reduceMotion: reduce)
        // a centred card lands whole: the row above it whole under the floating header or hidden by it (BRIEF E3)
        if p.mode == .centre, let delta = d?.delta, let above = t.frame(above: p.id) {
            d?.delta = ScrollDecision.whole(delta: delta, above: above, card: frame, header: Self.header, viewport: viewport)
        }
        lastDecision = "\(p.mode) minY=\(Int(minY)) maxY=\(Int(maxY)) -> " +
            (d.map { "\(Int($0.delta)) \($0.animated ? "animated" : "instant")" } ?? "none")
        if let d { scroll(by: d.delta, animated: d.animated) }
    }

    /// Moves the content up by `delta` points (negative: down).
    func scroll(by delta: CGFloat, animated: Bool) {
        guard let sv = scrollView else { return }
        let clip = sv.contentView
        var b = clip.bounds
        b.origin.y += delta  // the table is flipped
        let target = clip.constrainBoundsRect(b).origin
        guard abs(target.y - clip.bounds.origin.y) >= 0.5 else { return }
        ScrollAnimator.scroll(sv, to: target, duration: animated ? 0.2 : 0)
    }

    func debugScroll(_ dy: CGFloat) { scroll(by: dy, animated: false) }

    /// For --debug-script dump: the offset from the top, the viewport, and the expanded card's edges in it.
    var dump: [String: Any] {
        var d: [String: Any] = ["decision": lastDecision]
        if let sv = scrollView {
            d["viewport"] = Double(sv.contentView.bounds.height)
            d["flipped"] = true
            d["offset"] = Double(sv.contentView.bounds.minY)
        }
        if let t = table, let id = t.expandedID, let f = t.frame(of: id) {
            d["card"] = [Double(f.minY), Double(f.maxY)]
            d["cardID"] = id
        }
        if let p = table?.pin { d["pin"] = Double(p.offset) }  // the answer row moved up (UX.md §2)
        return d
    }
}

/// One listed item of a panel table: a comment's card, a comment closed this round (a line in its folded group), or a
/// change on the Changes tab (UX.md §1, §16).
enum PanelItem: Equatable {
    case card(CardModel)
    case line(CardModel)
    case change(ChangeModel)

    var id: String {
        switch self {
        case .card(let c), .line(let c): return c.id
        case .change(let c): return c.id
        }
    }

    var card: CardModel? {
        switch self {
        case .card(let c), .line(let c): return c
        case .change: return nil
        }
    }

    /// The compact row's height: 44 pt, a closed comment's line 30 pt (UX.md §2).
    var height: CGFloat {
        if case .line = self { return 30 }
        return 44
    }
}

/// What a compact row shows besides its model (POLISH §6, §7): dimmed while another card is expanded, and the pointer
/// over it, which shows it as it is. One per row, set by the table, so a J/K step from one card to another changes
/// none and lays out no row.
@MainActor
final class RowLook: ObservableObject {
    @Published var dimmed = false
    /// The pointer is over the row: set only by the table, from its one hovered row (`PanelTable.hovered`).
    @Published var hovering = false

    /// The row is drawn faded.
    var quiet: Bool { dimmed && !hovering }

    /// A dimmed row is drawn whole at this opacity, its bar, sign, id, words and note alike, so it keeps its own order
    /// and reads as stepped back (POLISH §7: its text in the secondary grey was not seen as dimmed; in Dark Mode that
    /// grey is as light as the card's paper text). The note then has about 5:1 on the panel in either appearance
    /// (label on panel: 14:1), still easy to read; the pointer restores it.
    nonisolated static func opacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.55 : 0.66 }
}

/// A panel list (UX.md §10; the Comments and Changes tabs) as an NSTableView: section headers that float, fixed 44 pt
/// compact rows, and the expanded item measured at the panel's width. Each listed item has its own hosting view for
/// its compact row (content from `compact`), and the expanded item is one more hosting controller (`expandedView`),
/// laid over its row and kept in the table while the panel shows: a J/K step gives it the next item's model (the same
/// views with new data, not a new view tree), notes two rows' heights and moves it. No view is added, moved or removed (a hosting view moved between rows rebuilt its
/// SwiftUI graph), the cost does not grow with the number of comments, and the window around the panel is not laid
/// out again (the SwiftUI lazy stack re-measured every row above the expanded card on each step). Its owner (a
/// CommentListController or ChangeListController) follows its model through Combine, not through SwiftUI, and hands
/// the table its rows (`show`) and the expanded item (`setExpanded`), so a selection never re-renders the panel.
@MainActor
final class PanelTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        /// A group's header (`SectionHeader`): `sub`, quieter words after it ("goes in the Round 3 final.pdf"); `count`, in a
        /// capsule; `glyph`, the sign before it.
        case header(String, sub: String = "", count: Int? = nil, glyph: HeaderGlyph = .none)
        /// A header whose group folds, with Show / Hide (`onFold`): the whole header is the button.
        case fold(String, String, sub: String = "", group: FoldedGroup, count: Int? = nil, glyph: HeaderGlyph = .none)
        case gap  // 10 pt of panel above a group's header that does not start the list (`spaced`)
        case hint(String)
        case done(round: Int)  // nothing left in the round: the done card on top, with Finish Round… (onFinish)
        case empty  // no comments yet: what to do first
        case focusHint(changes: Bool)  // Focus with nothing selected: what to click (POLISH §7)
        case item(PanelItem)

        var cardID: String? { if case .item(let i) = self { return i.id } else { return nil } }

        var isDone: Bool { if case .done = self { return true } else { return false } }

        var isHeader: Bool {
            switch self {
            case .header, .fold: return true
            default: return false
            }
        }
    }

    /// `rows` with a gap above every group's header but the list's first (and one under the done card, which has its
    /// own margin): the groups read as separate sections (POLISH §7).
    static func spaced(_ rows: [Row]) -> [Row] {
        var out: [Row] = []
        for r in rows {
            if r.isHeader, let last = out.last, last != .gap, !(last.isDone) { out.append(.gap) }
            out.append(r)
        }
        return out
    }

    let scrollView = NSScrollView()
    private let table = PanelTableView()
    private weak var scroller: PanelScroller?
    private let compactView: (PanelItem, RowLook) -> AnyView
    private let expandedView: (PanelItem) -> AnyView
    private var rows: [Row] = []
    private var index: [String: Int] = [:]  // item id → row
    private(set) var expandedID: String?
    var onFold: ((FoldedGroup) -> Void)?
    /// The done card's Finish Round… (POLISH §3 row 9).
    var onFinish: (() -> Void)?
    /// The rows other than the expanded card are dimmed while a card is expanded (the comment list, POLISH §6).
    var dims = false
    /// The expanded card's answer row, kept at the bottom edge while the card is taller than the panel (UX.md §2).
    var pin: PinState? { didSet { pin?.measured = { [weak self] in self?.updatePin() } } }
    /// Where the panel's toast goes (`ToastPlace`): under the card while `toastUnderCard` (Focus, whose list shows
    /// the one card at its top).
    var toastPlace: ToastPlace?
    var toastUnderCard = false { didSet { if toastUnderCard != oldValue { updatePin() } } }
    private var hosts: [String: (view: NSHostingView<AnyView>, cell: NSView, model: PanelItem, look: RowLook)] = [:]  // compact rows
    /// The expanded item, over its row; measured at the column's width, and again when its content changes size (an
    /// editor opens, "Show all": `cardContentChanged`).
    private let card = NSHostingController(rootView: AnyView(EmptyView()))
    private var cardModel: PanelItem?
    private var cardHeight: (id: String, width: CGFloat, height: CGFloat)?
    /// The heights of the rows measured at the column's width (a hint, the done card, the empty state), by kind.
    private var measured: [String: (width: CGFloat, height: CGFloat)] = [:]
    /// The done card's Finish Round… button: its hosting view and its frame there (--debug-script doneclick).
    private var doneButton: (host: NSView, frame: CGRect)?
    private var resizeNoted = false
    private static let headerID = NSUserInterfaceItemIdentifier("header")
    /// The one row drawn under the pointer (UX.md §1 Hover): its look's `hovering`, the only one set. It is the listed
    /// item under the pointer as a click would reach it (`item(at:)`), from the list's own pointer tracking while the
    /// window is key; nil when the pointer leaves the list, when the list scrolls or its rows come or go, and when the
    /// window resigns key or the app resigns active; found again where the pointer is once the list is still for
    /// `settleDelay` (a scroll's end, rows that moved) and when the window becomes key. A row's own pointer events
    /// (SwiftUI's onHover) missed exits: in the background, with the window covered, or rows moving under a still
    /// pointer, and two rows stayed hovered.
    private(set) var hovered: String? {
        didSet {
            guard hovered != oldValue else { return }
            if let old = oldValue { hosts[old]?.look.hovering = false }
            if let new = hovered { hosts[new]?.look.hovering = true }
        }
    }
    /// Where the pointer is in the window, or nil while the window is not key or the app is not active (tests and
    /// --debug-script hover put a pointer of their own here).
    lazy var pointerLocation: () -> NSPoint? = { [weak self] in
        guard let w = self?.table.window, w.isKeyWindow, NSApp.isActive else { return nil }
        return w.mouseLocationOutsideOfEventStream
    }
    /// The list is moving: a live scroll (a trackpad gesture, the scroller's knob), or less than `settleDelay` since
    /// it scrolled or its rows moved. No row is hovered then.
    private var liveScroll = false
    private var settlePending = false
    private var settleTurn = 0  // the latest settle's number: only it ends the wait
    private var moving: Bool { liveScroll || settlePending }
    static let settleDelay = 0.15

    /// The rows touch, as in design/ui-v2: flat rows with a bar, no boxes.
    init(scroller: PanelScroller, expanded: String?, compact: @escaping (PanelItem, RowLook) -> AnyView,
         expandedView: @escaping (PanelItem) -> AnyView) {
        compactView = compact
        self.expandedView = expandedView
        self.scroller = scroller
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("card"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.floatsGroupRows = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.wantsLayer = true
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        // No Auto Layout size constraints from SwiftUI content (the table sets the frames): with them every new model
        // made AppKit ask the whole card for its minimum size again in the window's constraint pass.
        (card.view as? NSHostingView<AnyView>)?.sizingOptions = []
        card.view.wantsLayer = true
        card.view.layer?.zPosition = 5  // over the rows, under the floating section headers (10)
        card.view.isHidden = true
        table.addSubview(card.view)
        table.overlay = card.view
        table.place = { [weak self] in self?.placeCard() }
        table.pointer = { [weak self] p in self?.pointerMoved(to: p) }
        table.onHidden = { [weak self] h in self?.hiddenChanged(h) }
        NotificationCenter.default.addObserver(self, selector: #selector(columnResized),
                                               name: NSTableView.columnDidResizeNotification, object: table)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(liveScrollChanged(_:)), name: name, object: scrollView)
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        scroller.table = self
        expandedID = expanded
        if let expanded { scroller.request(expanded, mode: .centre) }  // a list made with a card open (the panel shown)
    }

    /// A folded group's header in window coordinates, scrolled into view first as a person would (--debug-script
    /// foldclick), or nil.
    func foldFrame(_ g: FoldedGroup) -> CGRect? {
        guard let i = rows.firstIndex(where: { if case .fold(_, _, _, g, _, _) = $0 { return true } else { return false } })
        else { return nil }
        table.scrollRowToVisible(i)
        table.layoutSubtreeIfNeeded()
        let row = table.rowView(atRow: i, makeIfNecessary: false)
        return row.map { $0.convert($0.bounds, to: nil) }
    }

    /// An item's row in window coordinates, scrolled into view first as a person would (--debug-script rowclick), or nil.
    func rowFrame(_ id: String) -> CGRect? {
        guard let i = index[id] else { return nil }
        table.scrollRowToVisible(i)
        table.layoutSubtreeIfNeeded()
        return table.rowView(atRow: i, makeIfNecessary: false).map { $0.convert($0.bounds, to: nil) }
    }

    /// The listed items whose rows are dimmed now, in order (--debug-script groups); a row not made yet is made so.
    var dimmed: [String] {
        rows.compactMap(\.cardID).filter { id in id != expandedID && (hosts[id]?.look.dimmed ?? dimming) }
    }

    /// Whether the rows are dimmed: a card is expanded, in a list that dims.
    private var dimming: Bool { dims && expandedID != nil }

    /// A row's look (--debug-script hover).
    func look(_ id: String) -> RowLook? { hosts[id]?.look }

    /// The rows drawn under the pointer, in order (--debug-script hover): one at most.
    var hoveredRows: [String] { rows.compactMap(\.cardID).filter { hosts[$0]?.look.hovering == true } }

    /// The rows listed, in order: headers by their words (and count), the done card, the empty state, hints, the items'
    /// ids; not the gaps (--debug-script groups).
    var listed: [String] {
        rows.compactMap { r in
            switch r {
            case .header(let t, _, let n, _), .fold(let t, _, _, _, let n, _): return "header: " + t + (n.map { " · \($0)" } ?? "")
            case .gap: return nil
            case .hint(let t): return "hint: " + t
            case .done: return "done"
            case .empty: return "empty"
            case .focusHint: return "focus hint"
            case .item(let c): return c.id
            }
        }
    }

    /// The headers listed, as drawn: words, count, sign, and Show / Hide (--debug-script groups).
    var headers: [[Any]] {
        rows.compactMap { r -> [Any]? in
            switch r {
            case .header(let t, let sub, let n, let g): return [t, n ?? NSNull(), sub, g.symbol ?? NSNull(), NSNull()]
            case .fold(let t, let b, let sub, _, let n, let g): return [t, n ?? NSNull(), sub, g.symbol ?? NSNull(), b]
            default: return nil
            }
        }
    }

    /// Focus shows one card at the top of the panel (POLISH §7): the list starts at its top.
    func scrollToTop() {
        ScrollAnimator.stop(scrollView)  // a scroll to the card that was selected before Focus
        let clip = scrollView.contentView
        guard clip.bounds.minY != 0 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The middle of the done card's Finish Round… button in window coordinates, its row scrolled into view first, or
    /// nil (--debug-script doneclick).
    func donePoint() -> CGPoint? {
        guard let i = rows.firstIndex(where: { if case .done = $0 { return true } else { return false } }) else { return nil }
        table.scrollRowToVisible(i)
        table.layoutSubtreeIfNeeded()
        guard let b = doneButton, b.host.window != nil else { return nil }
        let y = b.host.isFlipped ? b.frame.midY : b.host.bounds.height - b.frame.midY
        return b.host.convert(CGPoint(x: b.frame.midX, y: y), to: nil)
    }

    /// The expanded card in window coordinates (--debug-script cardclick), or nil.
    var cardFrame: CGRect? { card.view.isHidden ? nil : card.view.convert(card.view.bounds, to: nil) }

    /// The rect of a card's row relative to the top of the visible area, or nil. With `header`, up over its group's
    /// header when it is the group's first, so a card placed under the floating header leaves its own header in view
    /// rather than half under the other (behaviour review 2026-10-19).
    /// The item row just above a card (none when a header is), from the visible top as `frame(of:)`: E3's rounding.
    func frame(above id: String) -> CGRect? {
        guard let i = index[id], i > 0 else { return nil }
        var k = i - 1
        while k > 0, case .gap = rows[k] { k -= 1 }
        guard case .item = rows[k] else { return nil }
        return table.rect(ofRow: k).offsetBy(dx: 0, dy: -scrollView.contentView.bounds.minY)
    }

    func frame(of id: String, header: Bool = false) -> CGRect? {
        guard let i = index[id] else { return nil }
        var r = table.rect(ofRow: i)
        if header, i > 0, rows[i - 1].isHeader { r = r.union(table.rect(ofRow: i - 1)) }
        return r.offsetBy(dx: 0, dy: -scrollView.contentView.bounds.minY)
    }

    // MARK: Rows

    /// The rows to list. Rows that stay keep their views (a hosting view moved to another row rebuilt its SwiftUI
    /// graph): the table only removes and inserts the rows that come or go, and the items are updated in place when
    /// only their content changed. When rows come or go (a card that the selection left moves to its group), the
    /// expanded card keeps its place on screen if it is in view, else the first listed item in view that stays, so
    /// nothing moves under the pointer.
    func show(_ r: [Row]) {
        let old = rows
        let diff = r.map(kindAndID).difference(from: old.map(kindAndID))
        let keep = diff.isEmpty ? nil : inView(staying: Set(r.compactMap(\.cardID)))
        var removed = IndexSet(), inserted = IndexSet()
        for change in diff {
            switch change {
            case .remove(let i, _, _): removed.insert(i)
            case .insert(let i, _, _): inserted.insert(i)
            }
        }
        // The rows that stay, in order (old row, new row): headers and hints whose text changed are drawn again, and
        // the expanded card is measured again if its model changed.
        let stay = zip(old.indices.filter { !removed.contains($0) }, r.indices.filter { !inserted.contains($0) })
            .filter { old[$0.0] != r[$0.1] }
        let changed = stay.map(\.1)
        let measures: (Int) -> Bool = { Self.isMeasured(r[$0]) }
        var heights = IndexSet(changed.filter(measures))
        if let e = expandedID, let i = r.firstIndex(where: { $0.cardID == e }), changed.contains(i) { heights.insert(i) }
        // The most the list can lose: the rows that go, and those measured again as if they went. Decided while the
        // rows are still the table's (the headers' floating asks for them).
        let lost = removed.union(IndexSet(stay.filter { heights.contains($0.1) }.map(\.0)))
        let unfloated = beginUpdate(losing: lost.reduce(0) { $0 + table.rect(ofRow: $1).height })
        if !diff.isEmpty { clearHover() }  // rows come or go under the pointer
        rows = r
        // measured by kind ("hint"), so a row that comes or changes is measured again, before the table asks for it
        // in its update: an earlier hint's height cut or padded a new one's words
        for i in Array(inserted) + changed where measures(i) { measured[kindAndID(r[i])] = nil }
        index = [:]
        for (i, row) in r.enumerated() { if let id = row.cardID { index[id] = i } }
        hosts = hosts.filter { index[$0.key] != nil }
        for (id, host) in hosts {
            if case .item(let c) = r[index[id]!], c != host.model { setCompact(c, host.view, host.cell, host.look) }
        }
        showCard()
        if !diff.isEmpty {
            BodyCount.list += 1
            withoutAnimation {
                table.beginUpdates()
                table.removeRows(at: removed, withAnimation: [])
                table.insertRows(at: inserted, withAnimation: [])
                table.endUpdates()
            }
        }
        let redraw = IndexSet(changed.filter { r[$0].cardID == nil })
        if !redraw.isEmpty { table.reloadData(forRowIndexes: redraw, columnIndexes: [0]) }
        if !heights.isEmpty { withoutAnimation { table.noteHeightOfRows(withIndexesChanged: heights) } }
        var target: CGFloat?
        if let keep, let i = index[keep.id] {
            let clip = scrollView.contentView
            let shift = table.rect(ofRow: i).minY - clip.bounds.minY - keep.y
            if abs(shift) >= 0.5 {
                target = clip.bounds.minY + shift
                ScrollAnimator.shift(scrollView, by: shift)
            }
        }
        endUpdate(unfloated, scrollingTo: target)
        placeCard()
    }

    /// Before a change of the table's rows or heights that can make the list `loss` shorter: when that could leave
    /// it shorter than its scroll, the section headers stop floating until the change is over (`endUpdate`), and true.
    /// The table resizes itself range by range inside a change (a collapsing card before the one that opens below
    /// it), so the list can scroll in the middle of the table's update; when that brought a floating header's place
    /// back into view, the table gave the header a second view, and its next update threw "The row at 0 is not
    /// floating" (visual review, 2026-10-18: the demo at the panel's 400 pt, R1-19, R2-07, then R2-08's mark clicked).
    /// With no header floating, the update has none to get wrong, and the header floats again once it is over.
    private func beginUpdate(losing loss: CGFloat) -> Bool {
        let clip = scrollView.contentView.bounds
        guard clip.minY > 0.5, loss > 0.5,
              table.frame.height - loss + scrollView.contentInsets.bottom < clip.maxY - 0.5 else { return false }
        table.floatsGroupRows = false
        return true
    }

    /// After a change of the table's rows or heights: the list scrolled at once to `y` (within its rows), and the
    /// headers floating again if `beginUpdate` stopped them.
    private func endUpdate(_ unfloated: Bool, scrollingTo y: CGFloat?) {
        if let y {
            let clip = scrollView.contentView
            var b = clip.bounds
            b.origin.y = y
            let o = clip.constrainBoundsRect(b).origin
            if abs(o.y - clip.bounds.minY) >= 0.5 {
                clip.scroll(to: o)
                scrollView.reflectScrolledClipView(clip)
            }
        }
        if unfloated { table.floatsGroupRows = true }
    }

    /// The most `rows` get shorter when their heights are noted: each one's new height, asked for now as the table asks
    /// during its update (the measures are kept).
    private func loss(_ rows: IndexSet) -> CGFloat {
        rows.reduce(0) { $0 + max(0, table.rect(ofRow: $1).height - tableView(table, heightOfRow: $1)) }
    }

    /// The listed item to keep in place, among those `staying`, and its top relative to the visible area: the expanded
    /// card when it is in view, else the first item in view.
    private func inView(staying: Set<String>) -> (id: String, y: CGFloat)? {
        let clip = scrollView.contentView.bounds
        let visible = table.rows(in: clip)
        let order = (expandedID.flatMap { index[$0] }.map { [$0] } ?? []) + Array(visible.location..<NSMaxRange(visible))
        for i in order where i < rows.count {
            let r = table.rect(ofRow: i)
            if let id = rows[i].cardID, staying.contains(id), r.intersects(clip) { return (id, r.minY - clip.minY) }
        }
        return nil
    }

    private func kindAndID(_ r: Row) -> String {
        switch r {
        case .header, .fold: return "h"  // a header's text is redrawn in place
        case .gap: return "gap"
        case .focusHint: return "focushint"
        case .hint: return "hint"
        case .done: return "done"
        case .empty: return "empty"
        case .item(.line(let c)): return "l" + c.id  // 30 pt, not 44
        case .item(let c): return "c" + c.id
        }
    }

    /// A J/K step, a click on a row or a mark: the expanded card shows the new one and the two rows change height.
    /// The new card's top stays where it was on screen when a card above it collapses, so a clicked row stays under
    /// the pointer; the scroller then moves the panel if it has to. After an answer (the scroller's `.slot`), the new
    /// card's top goes where the answered card's top was (under the floating header when that was above the view), so
    /// it takes its place, and nothing else moves once the answered card leaves its group (`show`).
    func setExpanded(_ id: String?) {
        guard id != expandedID else { return }
        let old = expandedID
        expandedID = id
        cardHeight = nil
        // the card over the row has the pointer now; the rows around it change height, so the row under a still
        // pointer is found again once they settle (with the pointer off the list, a step changes no row's look)
        if let id, hovered == id { hovered = nil }
        settle()
        showCard()
        let indexes = IndexSet([old, id].compactMap { $0.flatMap { index[$0] } })
        guard !indexes.isEmpty else { return placeCard() }
        let anchor = id.flatMap { index[$0] }
        let clip = scrollView.contentView
        let slot = scroller?.pendingMode == .slot ? old.flatMap { index[$0] } : nil
        var before = (slot ?? anchor).map { table.rect(ofRow: $0).minY }
        if slot != nil, let b = before { before = b > clip.bounds.maxY ? nil : max(b, clip.bounds.minY + PanelScroller.header) }
        let shown = clip.bounds  // the list in view before the change (it can scroll in it)
        let unfloated = beginUpdate(losing: loss(indexes))
        withoutAnimation { table.noteHeightOfRows(withIndexesChanged: indexes) }
        var target: CGFloat?
        if let anchor, let before, before >= shown.minY - 44, before <= shown.maxY {
            let shift = table.rect(ofRow: anchor).minY - before
            if abs(shift) >= 0.5 {
                target = shown.minY + shift
                ScrollAnimator.shift(scrollView, by: shift)
            }
        }
        endUpdate(unfloated, scrollingTo: target)
        placeCard()
    }

    /// The expanded item's model in its hosting controller (same views, new data), or hidden.
    private func showCard() {
        guard let id = expandedID, let i = index[id], case .item(let c) = rows[i] else {
            cardModel = nil
            card.view.isHidden = true
            return
        }
        guard c != cardModel else { return }
        cardModel = c
        cardHeight = nil
        // The content's own height, which the table's frame does not bound: it changes when an editor opens or
        // grows, the choice row shows, or "Show all". (The hosting controller's preferredContentSize changes too,
        // but posts no KVO notification.)
        card.rootView = AnyView(expandedView(c).onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] h in
            MainActor.assumeIsolated { self?.cardContentChanged(h) }
        })
    }

    /// Lays the expanded card over its row (the compact row under it is hidden), and dims the other rows while a card
    /// is expanded (the hidden row too, so a step from one card to another changes no row).
    private func placeCard() {
        let dim = dimming
        for (id, host) in hosts {
            if host.view.isHidden != (id == expandedID) { host.view.isHidden = id == expandedID }
            if host.look.dimmed != dim { host.look.dimmed = dim }
        }
        guard let id = expandedID, let i = index[id], cardModel != nil else {
            if !card.view.isHidden { card.view.isHidden = true }
            updatePin()
            return
        }
        let r = table.rect(ofRow: i)
        if card.view.frame != r { card.view.frame = r }
        if card.view.isHidden { card.view.isHidden = false }
        updatePin()
    }

    @objc private func scrolled() {
        // a scroll the table makes in its own update (the list got shorter than its scroll): the pin waits for the
        // update's end, as its row's rect asked then re-entered the table's heights (AppKit's "reentrant operation"
        // warning; UX.md §27, a switch of the list's arrangement)
        if updating { pinPending = true } else { updatePin() }
        clearHover()  // the rows move under a still pointer, which sends no event
    }

    // MARK: Hover

    /// The pointer moved in the list, or left it (nil): the row under it is the hovered one, unless the list is moving
    /// (its end finds it).
    func pointerMoved(to point: NSPoint?) {
        guard let point else { hovered = nil; return }
        if !moving { hovered = item(at: point) }
    }

    /// The listed item whose compact row is under a point in window coordinates, as a click there would reach it: not
    /// under the expanded card, a floating header, the toast or anything else over the list, nor outside the visible
    /// list; nil when none is.
    func item(at point: NSPoint) -> String? {
        let i = table.row(at: table.convert(point, from: nil))
        guard i >= 0, i < rows.count, let id = rows[i].cardID, id != expandedID, let cell = hosts[id]?.cell,
              let frame = table.window?.contentView?.superview else { return nil }
        var v = frame.hitTest(point)
        while let view = v, view !== cell { v = view.superview }
        return v == nil ? nil : id
    }

    /// No row is hovered until the list has been still for `settleDelay`, then the one under the pointer is.
    private func clearHover() {
        hovered = nil
        settle()
    }

    /// The row under the pointer is found again once the list has been still for `settleDelay`; until then the
    /// pointer's moves are ignored.
    private func settle() {
        settlePending = true
        settleTurn += 1
        let turn = settleTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.settleTurn == turn else { return }
            self.settlePending = false
            self.refreshHover()
        }
    }

    /// The row under the pointer where it is now: none while the list moves, the window is not key or the app is
    /// not active.
    private func refreshHover() {
        hovered = moving ? nil : pointerLocation().flatMap { item(at: $0) }
    }

    @objc private func liveScrollChanged(_ n: Notification) {
        liveScroll = n.name == NSScrollView.willStartLiveScrollNotification
        if liveScroll { hovered = nil } else { settle() }
    }

    @objc private func keyChanged(_ n: Notification) {
        guard let w = n.object as? NSWindow, w === table.window else { return }
        if n.name == NSWindow.didBecomeKeyNotification { refreshHover() } else { hovered = nil }
    }

    @objc private func resignedActive() { hovered = nil }

    /// While the expanded card is taller than the visible panel and runs past its bottom edge, its answer row (the
    /// last thing on it, 12 pt above the card's bottom, which is 8 pt above its row's) is moved up to 8 pt above that
    /// edge, never above the card's first 120 pt; otherwise it stays in place.
    private func updatePin() {
        defer { updateToastPlace() }  // after the pin, which it reads (review, 2026-10-18: it lagged a pin with no scroll)
        guard let pin else { return }
        var offset: CGFloat = 0
        if let id = expandedID, let i = index[id], cardModel != nil {
            let r = table.rect(ofRow: i), visible = scrollView.documentVisibleRect
            let bottom = visible.maxY - scrollView.contentInsets.bottom - 8, natural = r.maxY - 20
            if r.height > visible.height - 16, natural > bottom {
                offset = min(0, max(bottom - natural, r.minY + 120 - natural))
            }
        }
        if abs(pin.offset - offset) >= 0.5 { pin.offset = offset }
    }

    /// In Focus, the toast 12 pt under the card's foot (its row less the card's 8 pt bottom margin), from the visible
    /// top, while the panel has room for it there; else at the panel's foot: over the pinned answer row, and above a
    /// group's header it would cover (`ToastPlace.bottom`). Only the shown tab's list says where: the other one is
    /// hidden, and both share the toast (`PagerView`).
    private func updateToastPlace() {
        guard let place = toastPlace, !table.isHiddenOrHasHiddenAncestor else { return }
        let visible = scrollView.documentVisibleRect
        var below: CGFloat?
        if toastUnderCard, let id = expandedID, let i = index[id], cardModel != nil {
            let foot = table.rect(ofRow: i).maxY - 8 - visible.minY
            if foot >= 0, foot + 12 + 44 <= visible.height - scrollView.contentInsets.bottom { below = foot + 12 }
        }
        switch (place.below, below) {
        case (nil, nil): break
        case let (old?, new?) where abs(old - new) < 0.5: break
        default: place.below = below
        }
        let shown = table.rows(in: visible)
        let headers = (shown.location..<NSMaxRange(shown)).filter { $0 < rows.count && rows[$0].isHeader }.map { i in
            let r = table.rect(ofRow: i)
            return (top: r.minY - visible.minY, bottom: r.maxY - visible.minY)
        }
        // the expanded card's answer row (and field): its bottom as `updatePin` places it, its height as laid out
        var answers: (top: CGFloat, bottom: CGFloat)?
        if !toastUnderCard, let pin, let h = pin.height, let id = expandedID, h.id == id, h.height > 0, let i = index[id],
           cardModel != nil {
            let foot = table.rect(ofRow: i).maxY - 20 + pin.offset - visible.minY
            answers = (foot - h.height, foot)
        }
        let bottom = ToastPlace.bottom(base: (pin?.offset ?? 0) < 0 ? 56 : 16, height: visible.height, headers: headers,
                                       answers: answers)
        if abs(place.bottom - bottom) >= 0.5 { place.bottom = bottom }
    }

    /// The list's page was hidden (the other tab shown, `PagerView`): no row stays drawn under a pointer it no longer
    /// sees. Shown again, it says where the toast goes.
    fileprivate func hiddenChanged(_ hidden: Bool) {
        if hidden { hovered = nil } else { updatePin() }
    }

    private func setCompact(_ c: PanelItem, _ view: NSHostingView<AnyView>, _ cell: NSView, _ look: RowLook) {
        view.rootView = compactView(c, look)
        if view.frame.height != c.height { view.frame.size.height = c.height }  // a card that became a closed line
        hosts[c.id] = (view, cell, c, look)
    }

    /// A compact row: its hosting view, 44 pt high (a closed line 30) at the top of a plain cell, so a row that moves
    /// or grows (the expanded one, under the card) never resizes or re-lays out its SwiftUI content.
    private func compact(_ c: PanelItem) -> NSView {
        if let h = hosts[c.id] { return h.cell }
        let cell = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: c.height))
        let view = NSHostingView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []  // the table sets its frame; its content never resizes the panel or the window
        view.frame = NSRect(x: 0, y: 0, width: width, height: c.height)
        view.autoresizingMask = [.width]
        cell.addSubview(view)
        let look = RowLook()
        look.dimmed = dimming
        setCompact(c, view, cell, look)
        view.isHidden = c.id == expandedID
        return cell
    }

    private func withoutAnimation(_ body: () -> Void) {
        let outer = !updating
        updating = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            body()
        }
        guard outer else { return }
        updating = false
        if pinPending {
            pinPending = false
            updatePin()
        }
    }

    /// The table's rows or heights are being changed (`withoutAnimation`), and a scroll in it left the pin to place.
    private var updating = false
    private var pinPending = false

    private var width: CGFloat { max(table.tableColumns.first?.width ?? 0, 1) }

    /// The column's width changed (the window or the panel resized): the expanded card, the hint, the done card and the
    /// empty state, the only rows measured at the width, are measured again, on the next turn of the run loop. The
    /// table is still setting its rows' frames when it posts this, and noting heights then (every row's, the floating
    /// headers' too) threw "The row at 0 is not floating" (visual review, 2026-10-17).
    @objc private func columnResized() {
        guard !resizeNoted else { return }
        resizeNoted = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeNoted = false
            let w = self.width
            var stale = IndexSet()
            if let e = self.expandedID, let i = self.index[e], self.cardModel != nil,
               self.cardHeight.map({ $0.id != e || $0.width != w }) ?? true {
                self.cardHeight = nil
                stale.insert(i)
            }
            let measuredRows = IndexSet(self.rows.indices.filter { Self.isMeasured(self.rows[$0]) })
            if measuredRows.contains(where: { self.measured[self.kindAndID(self.rows[$0])]?.width != w }) {
                self.measured = [:]
                stale.formUnion(measuredRows)
            }
            guard !stale.isEmpty else { return }
            let unfloated = self.beginUpdate(losing: self.loss(stale))
            self.withoutAnimation { self.table.noteHeightOfRows(withIndexesChanged: stale) }
            self.endUpdate(unfloated, scrollingTo: nil)
            self.placeCard()
        }
    }

    /// The expanded card's content changed size (an editor opened or grew, the choice row, Show all): its row takes
    /// the new height. A J/K step measured the new card already, so it changes nothing then.
    private func cardContentChanged(_ height: CGFloat) {
        guard let id = expandedID, let i = index[id], let old = cardHeight, old.id == id, old.width == width,
              abs(ceil(height) - old.height) >= 0.5 else { return }
        cardHeight = (id, width, ceil(height))
        let unfloated = beginUpdate(losing: loss([i]))
        withoutAnimation { table.noteHeightOfRows(withIndexesChanged: [i]) }
        endUpdate(unfloated, scrollingTo: nil)
        placeCard()
        settle()  // the rows under it moved
    }

    private func measureCard() -> CGFloat {
        let height = ceil(card.sizeThatFits(in: NSSize(width: width, height: 100_000)).height)
        cardHeight = (expandedID ?? "", width, height)
        return height
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header, .fold: return PanelScroller.header
        case .gap: return 10
        case .hint, .done, .empty, .focusHint:
            let key = kindAndID(rows[row])
            if let h = measured[key], h.width == width { return h.height }
            let host = NSHostingController(rootView: block(rows[row]))
            let h = max(ceil(host.sizeThatFits(in: NSSize(width: width, height: 10_000)).height), 20)
            measured[key] = (width, h)
            return h
        case .item(let c):
            guard c.id == expandedID, cardModel != nil else { return c.height }
            if let h = cardHeight, h.id == c.id, h.width == width { return h.height }
            return measureCard()
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].isHeader }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ClearRowView()
        v.fillsBackground = self.tableView(tableView, isGroupRow: row)  // a floating header hides the rows under it
        return v
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        if self.tableView(tableView, isGroupRow: row) {  // the floating section headers stay over the expanded card
            rowView.wantsLayer = true
            rowView.layer?.zPosition = 10
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let t, let sub, let count, let glyph):
            let v = headerView(tableView)
            v.onClick = nil
            v.rootView = AnyView(SectionHeader(text: t, sub: sub, count: count, glyph: glyph, state: v.state))
            return v
        case .fold(let t, let button, let sub, let g, let count, let glyph):
            let v = headerView(tableView)
            let fold = { [weak self] () -> Void in self?.onFold?(g) }
            v.onClick = fold
            v.rootView = AnyView(SectionHeader(text: t, sub: sub, count: count, glyph: glyph, button: button, action: fold,
                                               state: v.state))
            return v
        case .gap:
            return NSView()
        case .hint, .done, .empty, .focusHint:
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = block(rows[row], in: host)
            return host
        case .item(let c):
            return compact(c)
        }
    }

    /// The rows measured at the column's width.
    private static func isMeasured(_ r: Row) -> Bool {
        switch r {
        case .hint, .done, .empty, .focusHint: return true
        default: return false
        }
    }

    /// A hint, the done card or the empty state; `host`: the view it is shown in (for the done card's button).
    private func block(_ r: Row, in host: NSView? = nil) -> AnyView {
        switch r {
        case .done(let n):
            return AnyView(DoneCard(round: n, finish: { [weak self] in self?.onFinish?() }, buttonFrame: { [weak self, weak host] f in
                if let host { self?.doneButton = (host, f) }
            }))
        case .empty:
            return AnyView(EmptyComments())
        case .focusHint(let changes):
            return AnyView(FocusHint(changes: changes))
        case .hint(let t):
            return AnyView(Text(t).font(.callout).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26).padding(.trailing, 16))  // as the rows' text
        default:
            return AnyView(EmptyView())
        }
    }

    /// A header's view, reused as the table reuses its rows.
    private func headerView(_ tableView: NSTableView) -> HeaderHost {
        if let v = tableView.makeView(withIdentifier: Self.headerID, owner: nil) as? HeaderHost {
            v.state.pressed = false
            return v
        }
        let v = HeaderHost(rootView: AnyView(EmptyView()))
        v.sizingOptions = []
        v.identifier = Self.headerID
        return v
    }
}

/// The panel's table: never takes keys (J/K and the others go through the app's routing). The expanded card lies over
/// its row as a subview of the table (`overlay`): clicks in it go to it, though rows added later are above it in
/// the subview order, except where a floating section header covers it; `place` lays it out again with the rows.
/// The pointer over the list goes to `pointer` (`PanelTable.pointerMoved`), its moves and nil when it leaves, while
/// the window is key: the rows have no pointer tracking of their own.
final class PanelTableView: NSTableView {
    weak var overlay: NSView?
    var place: (() -> Void)?
    var pointer: ((NSPoint?) -> Void)?
    /// The list, or the page it is on, was hidden (true) or shown again.
    var onHidden: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func viewDidHide() {
        super.viewDidHide()
        onHidden?(true)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onHidden?(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === area { pointer?(event.locationInWindow) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointer?(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === area { pointer?(nil) }
    }

    override func layout() {
        super.layout()
        place?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let o = overlay, !o.isHidden, let sup = superview {
            let p = convert(point, from: sup)
            let header = subviews.contains { v in
                guard let r = v as? NSTableRowView, r.isGroupRowStyle else { return false }
                return r.frame.contains(p)
            }
            if !header, o.frame.contains(p), let hit = o.hitTest(p) { return hit }
        }
        return super.hitTest(point)
    }
}

/// A row without a selection or group-row background (the cards and headers draw their own).
final class ClearRowView: NSTableRowView {
    var fillsBackground = false

    override func drawBackground(in dirtyRect: NSRect) {
        guard fillsBackground else { return }
        Palette.panel.setFill()
        dirtyRect.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// Scrolls an NSScrollView with plain scroll steps on a 120 Hz timer, eased out: what a trackpad gives, so the panel
/// and PDFView follow it cheaply. An NSAnimationContext animation of the clip view's bounds makes PDFView lay out the
/// whole window on every frame. A new scroll of the same view replaces one still running. Each step stays within the
/// content as it is then: rows that went meanwhile (Focus began during the scroll to a card, leaving one card) left
/// the list scrolled past its end, under a header that no longer had a row (the demo's stale "To check" over the card
/// in Focus, 2026-10-18).
@MainActor
enum ScrollAnimator {
    @MainActor private final class Run {
        var start: NSPoint
        var target: NSPoint
        var timer: Timer?
        init(start: NSPoint, target: NSPoint) { self.start = start; self.target = target }
    }

    private static var running: [ObjectIdentifier: Run] = [:]

    static func scroll(_ sv: NSScrollView, to target: NSPoint, duration: Double) {
        let key = ObjectIdentifier(sv)
        stop(sv)
        let clip = sv.contentView
        guard duration > 0 else {
            clip.scroll(to: target)
            sv.reflectScrolledClipView(clip)
            return
        }
        let run = Run(start: clip.bounds.origin, target: target), t0 = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak sv] timer in
            MainActor.assumeIsolated {
                guard let sv else { return timer.invalidate() }
                let t = min((CACurrentMediaTime() - t0) / duration, 1)
                let e = 1 - pow(1 - t, 3)
                let (a, b) = (run.start, run.target)
                let clip = sv.contentView
                var r = clip.bounds
                r.origin = NSPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
                clip.scroll(to: clip.constrainBoundsRect(r).origin)
                sv.reflectScrolledClipView(clip)
                if t >= 1 {
                    timer.invalidate()
                    if running[key] === run { running[key] = nil }
                }
            }
        }
        run.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        running[key] = run
    }

    /// Ends a scroll still running where it is (the list jumped: Focus shows its one card at the top).
    static func stop(_ sv: NSScrollView) {
        running.removeValue(forKey: ObjectIdentifier(sv))?.timer?.invalidate()
    }

    /// The content moved by `dy` under a running scroll (rows came or went above, and the list kept what was in view
    /// in place): the scroll goes on from there, to its target moved as much.
    static func shift(_ sv: NSScrollView, by dy: CGFloat) {
        guard let r = running[ObjectIdentifier(sv)] else { return }
        r.start.y += dy
        r.target.y += dy
    }

    static func isRunning(_ sv: NSScrollView) -> Bool { running[ObjectIdentifier(sv)] != nil }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
