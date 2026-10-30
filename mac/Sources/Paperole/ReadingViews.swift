import AppKit
import SwiftUI

/// The reading parts of the window (UX.md §10.5, §18), each observed only by its own view: the toast over the PDF
/// (this object), the sidebar's Contents (`contents`), the section the PDF is in (`current`), and the count in the
/// status line under the PDF (`status`).
@MainActor
final class ReadingModel: ObservableObject {
    @Published var toast: String?  // what N, C or Shift-C just did, or why it could not
    let contents = ContentsModel()
    let current = CurrentSection()
    let status = ReadingStatus()
}

/// The sidebar's Contents: its rows, or why there are none yet.
@MainActor
final class ContentsModel: ObservableObject {
    @Published var rows: [OutlineRow] = []
    @Published var message: String?  // no paragraphs yet: why
    @Published var canMark = false  // the shown round is open: Mark Section Read / Unread
}

/// The section the PDF is in (POLISH §5: in an object of its own, not in the list's data). Each Contents row observes
/// only its own look, so scrolling the PDF redraws the row it leaves and the row it enters, and nothing else; `block`
/// is observed only by the sidebar's follower, which keeps that row in view.
@MainActor
final class CurrentSection: ObservableObject {
    @Published private(set) var block: Int?
    private var looks: [Int: SectionLook] = [:]
    /// How many times the section changed (--debug-scroll-perf pdf).
    private(set) var changes = 0

    func look(_ b: Int) -> SectionLook {
        if let l = looks[b] { return l }
        let l = SectionLook(current: b == block)
        looks[b] = l
        return l
    }

    func set(_ b: Int?) {
        guard b != block else { return }
        if let old = block { looks[old]?.current = false }
        block = b
        if let b { looks[b]?.current = true }
        changes += 1
    }
}

@MainActor
final class SectionLook: ObservableObject {
    @Published var current: Bool
    init(current: Bool) { self.current = current }
}

/// The reading count in the status line (POLISH §3 row 3); only that part of the line observes it. `frames`: where
/// its buttons are, for --debug-script statusclick (not published).
@MainActor
final class ReadingStatus: ObservableObject {
    @Published var line: ReadingLine?
    var frames: [String: CGRect] = [:]
}

/// The sidebar's Contents (UX.md §18; POLISH §3 row 2): the numbered sections, an olive dot after a section with
/// changed paragraphs to read, its open comments; the section the PDF is in is Semibold on a light fill of its own,
/// beside the system's selection of the open paper. A click scrolls the PDF there; the context menu marks a section
/// read or unread.
struct ContentsSection: View {
    @ObservedObject var contents: ContentsModel
    let current: CurrentSection
    let model: AppModel

    var body: some View {
        if !contents.rows.isEmpty || contents.message != nil {
            Section {
                if let m = contents.message {
                    Text(m).font(.system(size: 11)).foregroundStyle(.secondary).selectionDisabled()
                } else {
                    ForEach(contents.rows) { row in
                        let look = current.look(row.block)
                        ContentsRow(row: row, look: look)
                            .contentShape(Rectangle())
                            .onTapGesture { model.outlineOpen(row.block) }
                            .contextMenu {
                                if row.tracked && contents.canMark && row.count > 0 {
                                    Button(row.done ? "Mark Section Unread" : "Mark Section Read") { model.markSection(row) }
                                }
                            }
                            .listRowBackground(CurrentFill(look: look))
                            .selectionDisabled()
                    }
                }
            } header: {
                Text("Contents").modifier(SidebarHeader())
            }
        }
    }
}

/// One Contents row: the number in a column of its own, the title (13 Medium for a section, Regular in the second
/// label colour for a subsection, Semibold where the PDF is), an olive dot when it has changed paragraphs to read, and
/// its open comments. No fractions or progress bars (POLISH §6, 7).
struct ContentsRow: View {
    let row: OutlineRow
    @ObservedObject var look: SectionLook

    var body: some View {
        let _ = { BodyCount.section += 1 }()
        let top = row.level == 1
        HStack(spacing: 6) {
            Text(row.number ?? "")
                .font(.system(size: 13, weight: top ? .medium : .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: top ? 18 : 26, alignment: .leading)
                .fixedSize()
            Text(row.name)  // the only part that gives way: truncated at its end
                .font(.system(size: 13, weight: look.current ? .semibold : top ? .medium : .regular))
                .foregroundStyle(top || look.current ? Color.primary : Ink.label2)
                .lineLimit(1)
            if row.changed {
                Circle().fill(Color(nsColor: Palette.reading)).frame(width: 6, height: 6)
            }
            Spacer(minLength: 4)
            if row.open > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "text.bubble")
                    Text("\(row.open)").monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            }
        }
        .padding(.leading, CGFloat(min(row.level - 1, 2)) * 24)
        .help(row.title + (row.changed ? " · changed paragraphs to read" : "")
              + (row.open > 0 ? " · " + count(row.open, "open comment") : ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title + (row.changed ? ", changed paragraphs to read" : "")
                            + (row.open > 0 ? ", \(count(row.open, "open comment"))" : "") + (look.current ? ", shown" : ""))
    }
}

/// The light fill under the section the PDF is in (the open paper has the system's selection).
private struct CurrentFill: View {
    @ObservedObject var look: SectionLook

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(look.current ? Color.primary.opacity(0.045) : .clear)  // lighter than the open paper's selection
            .padding(.horizontal, 10)
    }
}

/// Keeps the section the PDF is in within the sidebar's view, with the least scroll, as the PDF scrolls; and when its
/// row fits in the sidebar's first screen, the sidebar goes to its top, so Papers' header is in view again once the
/// PDF is back near its start (BACKLOG O30; UX.md §19: the least scroll had left the header, "○ 1 more to check",
/// above the view until the sidebar was scrolled by hand).
struct SectionFollower: View {
    @ObservedObject var current: CurrentSection
    let proxy: ScrollViewProxy
    /// The sidebar's row of a section's block: the Papers header and the papers shown, the Contents header, then its rows.
    let row: (Int) -> Int?
    @State private var probe = SidebarProbe()

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .background(SidebarProbeView(probe: probe))
            .onChange(of: current.block) { _, b in
                guard let b else { return }
                if let t = probe.table, let r = row(b), r < t.numberOfRows, let clip = t.enclosingScrollView?.contentView,
                   let top = SidebarFollow.top(row: t.rect(ofRow: r), clip: clip) {
                    clip.scroll(to: top)
                    t.enclosingScrollView?.reflectScrolledClipView(clip)
                } else {
                    proxy.scrollTo(b)
                }
            }
    }
}

enum SidebarFollow {
    /// The clip view's origin at the list's top when the row is wholly in view there and the list is not at its top
    /// already; else nil (the least scroll keeps the row in view).
    @MainActor static func top(row: CGRect, clip: NSClipView) -> NSPoint? {
        let b = clip.bounds
        let top = clip.constrainBoundsRect(NSRect(x: b.minX, y: -1_000_000, width: b.width, height: b.height)).origin
        let inset = clip.enclosingScrollView?.contentInsets.bottom ?? 0
        return goesToTop(rowMaxY: row.maxY, offset: b.minY, top: top.y, height: b.height - inset) ? top : nil
    }

    /// The row's foot is within a view `height` tall at the list's top (`top`, the clip view's least origin, below 0
    /// under a top inset), and the list is lower than that now.
    static func goesToTop(rowMaxY: CGFloat, offset: CGFloat, top: CGFloat, height: CGFloat) -> Bool {
        offset > top + 0.5 && rowMaxY <= top + height - 4
    }
}

/// The sidebar's list as AppKit has it (a SwiftUI List is an NSTableView): the window's leftmost table that is not a
/// panel's, found once from the probe's window and kept weakly.
@MainActor
final class SidebarProbe {
    weak var view: NSView?
    private weak var found: NSTableView?

    var table: NSTableView? {
        if let t = found, t.window != nil { return t }
        guard let root = view?.window?.contentView else { return nil }
        var all: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView, !(t is PanelTableView) { all.append(t) }
            v.subviews.forEach(walk)
        }
        walk(root)
        found = all.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        return found
    }
}

private struct SidebarProbeView: NSViewRepresentable {
    let probe: SidebarProbe

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        probe.view = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

/// The reading count at the right of the status line (POLISH §3 row 3): "▍12 changed paragraphs to read · ↓ Next ·
/// ✓ Mark Read", counting down; "✓ All changed paragraphs are read"; a closed round's line states what was left and
/// has no buttons. Next and Mark Read name N and C in their help tags only (POLISH §6). Narrower, "12 to read".
struct ReadingStatusView: View {
    @ObservedObject var status: ReadingStatus
    let model: AppModel

    var body: some View {
        if let line = status.line {
            ViewThatFits(in: .horizontal) {
                content(line, line.text, titles: true)
                content(line, line.short, titles: true)
                content(line, line.short, titles: false)
            }
        }
    }

    private func content(_ line: ReadingLine, _ text: String, titles: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if line.bar {
                    RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: Palette.reading)).frame(width: 2.5, height: 11)
                } else if line.done {
                    Image(systemName: "checkmark")
                }
                Text(text)
            }
            .foregroundStyle(Ink.label2)  // the count in the second label colour, in the status line
            .help(line.text)
            if line.actions {
                button("next", "Next", "arrow.down", titles,
                       help: "Go to the next changed paragraph to read (N)") { model.perform(.nextUnread) }
                button("read", "Mark Read", "checkmark", titles,
                       help: "Mark read the paragraph Next went to, or the one you selected text in (C)") { model.perform(.markRead) }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func button(_ key: String, _ title: String, _ icon: String, _ titles: Bool, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if titles { Label(title, systemImage: icon) } else { Image(systemName: icon).accessibilityLabel(title) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Ink.label2)
        .help(help)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [status] in status.frames[key] = $0 }
    }
}

/// What N, C or Shift-C just did, or why they could not, at the bottom of the PDF for 2.5 s.
struct ReadingToast: View {
    @ObservedObject var reading: ReadingModel

    var body: some View {
        if let t = reading.toast {
            HStack(spacing: 6) {
                Capsule().fill(Color(nsColor: Palette.reading)).frame(width: 3, height: 14)
                Text(t).font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .padding(.bottom, 14)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
