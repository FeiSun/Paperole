import AppKit
import PDFKit
import SwiftUI

/// --debug-script "item;…" (UX.md §13; --debug-drag is its M1 name). Runs once the PDF is settled and writes one JSON
/// value per item to --debug-out (or stderr). Pages are 0-based and points are contract points (top-left origin).
/// Mouse events are in-process NSEvents and keys go through the app's own routing, so no Accessibility permission is
/// needed.
///   page,x1,y1,x2,y2[,clicks]   drag between the points (or click `clicks` times at the first): the selection
///   clear                       clear the selection (no result)
///   return                      Return: the quote of the editor it opened
///   menu page,x,y[ title]       right-click: the PDF's menu (design/pdf-reader/PLAN.md §3) and, with a title, that item
///                               picked (in a submenu too): {menu: [title ("✓ " when on), "—", [title, [submenu]]], picked,
///                               selected, selection, editor, editorMode, after: {selected, selection, page, find,
///                               boxArmed}} (`selected`, `selection`: once the menu is built, before an item runs)
///   zoom [in|out|actual|fit|<percent>]  View's Zoom In, Zoom Out, Actual Size, Fit Width, or the status line's menu
///                               (PLAN §3.6); `zoom by <factor> page,x,y`: ⌘-scroll at that point: {zoom (nil: Fit Width),
///                               status, scale, auto, fit, focus, page, third, pointer: [[x, y] before, after] in the view}
///   click page,x,y              click without a drag: {click, expanded, tab, panelScrolled, flash}
///   optclick page,x,y           ⌥-click: {editor}
///   box page,x1,y1,x2,y2        ⌥-drag: {box, toolbar}
///   key <name>                  j k v r w b h u s f 1-6 return esc (escape) delete (backspace) up down, and cmd-return
///                               cmd-z cmd-shift-z: {key, handled, selected, editing, choice, ms} (`ms`: the key handled and
///                               the window laid out and drawn at once, as in the key's own turn)
///   type <text>                 insertText into the first responder (no result)
///   typeslow <cps> <text>       as `type`, one character at a time at <cps> characters a second, each pause ±30% from a
///                               fixed seed (a run repeats); the text is the rest of the item, inner spaces kept, or in
///                               "double quotes" with its spaces at either end kept (never a `;`): {typeslow, typed,
///                               start, end} (`typed`: the characters a text field took; `start`, `end`: the first and
///                               last one's ProcessInfo.systemUptime); the next item one pause after the last character
///   card <id> / note <id>       click the row / the note: {selected, editing, reanchor}
///   cardmenu <id> <title>       pick a … (or style) menu item: {selected, editing, reanchor}
///   button <resolve|followup|keep|discard|gotit> [<s>]  a click on the selected card's button (or the field's Discard,
///                               or the first-run tip's Got it), the next item <s> seconds later (0.6 by default):
///                               {selected, editing, reanchor, ignored, tip, toast} (`ignored`: too soon after an answer
///                               moved on to the card, ClickGuard, or while its own answer is with the engine; `tip`: the
///                               tip still shown; `toast`: the panel's toast)
///   rowclick <id>               a click on that row of the shown tab's list, scrolled into view first, as the mouse
///                               sends it: {selected, editing, reanchor, clicked, expanded}
///   toolbarclick                a click on the floating toolbar's Comment, as the mouse sends it: {clicked, editor,
///                               editorQuote, toolbar}
///   editorclick <save|cancel>   a click on the new-comment popover's Save or Cancel, as the mouse sends it: {clicked,
///                               editor, selected, confirmDiscard}
///   toastclick                  a click on the panel toast's Undo or Redo, as the mouse sends it: {clicked, toast,
///                               action, selected, verdict, undo, redo}
///   hover [<id>|off|away|resignkey|becomekey|resignactive]  the comment list's pointer, simulated (a background run's
///                               window is never key): moved onto that row's middle (scrolled into view first), off
///                               the list with an exit / with none, the window resigning or becoming key, the app
///                               resigning active (their notifications); nothing: as it is: {hovered: [ids drawn under
///                               the pointer], hit: the view a click there reaches}, plus {id, dimmed, quiet} for a row
///   field                       a click in the selected card's follow-up field: {selected, editing, reanchor}
///   cardclick <x>,<y>[,up]      a click at that point of the expanded card (points from its top left), as the mouse
///                               sends it (on its note or paper text: selectable text; `up`: the mouse-up to the same
///                               view at once, for its buttons): {selected, editing, reanchor, firstResponder}
///   quitcheck                   what quitting would ask about unsent drafts: {title, detail} or null
///   change <id>                 click a row of the Changes tab: {selected, expanded, panel, unrequested, answers,
///                               notes: [[comment id, the student's note]]}
///   notewarnings [show|hide]    the Comments tab's line of the student's notes not used, and its Details… popover
///                               shown or hidden: {line, shown, warnings: [[kind, file:line, text, message]]}
///   changecomment <id>          "Comment on this change": {editor, quote, editorQuote, box, selected} (`editorQuote`:
///                               the selected words the editor shows on top)
///   tab <comments|changes>      the panel's tab, as its control: {tab, selected, changeOutline}
///   fold / foldclick / headerclick [student|closed|linked]  a folded group (by default the shown tab's Closed this
///                               round, or its changes linked to comments), toggled / its Show or Hide clicked / its
///                               header clicked on its name, as the mouse sends it: {showStudent, showClosed} /
///                               {showLinked}, plus {clicked} for headerclick
///   groups                      the comment list's groups: {toCheck, forStudent, closed: [ids], showStudent, showClosed,
///                               selected, toast, dimmed: [ids], cardTop, ready, tip, rows, headers, studentNotes: [ids
///                               whose row has the student's note sign]} (`rows`: what the
///                               list shows, in order: "header: …", "done", "empty", "hint: …", "focus hint", ids;
///                               `headers`: [[name, count, sub, sign, Show|Hide]])
///   busy on|off                 the engine held busy without a request, as while it works (O27): {busy}
///   motion <factor>             the tab switch's motion that many times slower, for screenshots in flight: {motion}
///   doneclick                   a click on the done card's Finish Round…, as the mouse sends it: the finishsheet result
///                               plus {clicked}
///   nopaper [all]               no paper open (the page that says what to do); `all`, in a --fixture run only, also
///                               no paper listed (never saved): {paper, papers}
///   swatch <name> / kind <name> the floating toolbar's (or the editor's, or the selected card's) style: {color, kind}
///   markbar                     the toolbar by a new comment's mark (UX.md §8): {shown, id, color, kind, kinds, frame,
///                               lines, selected, toolbar, swatches} (`frame`, `lines`: the toolbar's and the mark's lines'
///                               frames in the PDF view, y up; `toolbar`: the selection's toolbar shown; `swatches`: the
///                               card whose colour dot's popover is open)
///   markbarclick <colour|kind|edit|delete>  a click on that button of the mark's toolbar, as the mouse sends it, the
///                               next item 0.8 s later: the markbar result plus {clicked, editing, confirmDelete, undo,
///                               redo, toast, style: [color, kind] of the selected comment}
///   dot [<id>|close]            the selected card's (or that card's) colour dot clicked: its popover of swatches and
///                               kinds opens (`swatch`/`kind` then restyle the card); `close` closes it: the markbar result
///   dump                        the selection, editors, the follow-up field (draft, drafts, choice, verdict, undo),
///                               the panel's toast, toolbar, re-anchor mode, panel and PDF geometry
///   thread                      the expanded card's thread: {id, status, row, fold, studentNote, sections: [{label,
///                               rounds, tags, edits, uncertain, revised, kind, text, trimmed, crop, said, students,
///                               entries}], turns: [{label, dot, date, link, section, uncertain, words, place,
///                               elsewhere}], attachments} (`entries`: "student R3", "said R2,R3", in the order they
///                               show; a student's "· edits c05": the edits its label links, outside the commented
///                               text; `turns`: the conversation the card shows, CARD.md option C, `words` an earlier
///                               round's cut ones with "[+N]" sentences left; `attachments`: the edits a note linked
///                               elsewhere, "c05 added § Q3 p.7")
///   showall                     opens the expanded card's fold, Show all of each section and of each cut bubble
///                               (no result)
///   window <w>,<h>              resizes the window's content (no result)
///   shot <path.png>             a screenshot of the app's own window (screencapture -l, as tools/shot.sh): {shot}
///   round <n>                   the toolbar's round picker: {round, latest, earlier, open, pdf, comments, changes,
///                               selected, marks, toast}
///   papers                      the papers list's next steps: [{path, step, badge, badgeShown}]
///   paper <path>                select that paper at the level shown (`paperopen` is the list's click since the
///                               overview): {paper, round, popover, toast}
///   paperclick <path>           selects that paper's row in the papers list's own table, which hands it to the list's
///                               selection binding as a click on the row does: {paper, listSelected, popover, toast,
///                               hit} (`listSelected`: the row the list shows selected)
///   close / closemenu           writes what the script has so far, then clicks the window's close button / closes it
///                               as File › Close does (performClose): the app quits, as from the menu ({delegate,
///                               question} before it; {closed, popover, asked} after it when it is still running)
///   finishsheet [send <id> [<s>]|discard <id> [<s>]|undo <id>|show <id>|left <comments|edits|paragraphs>|cancel|finish|
///                               done]  opens Finish Round…, or acts in it (a draft's Send as follow-up, Discard, a
///                               discard's Undo, Show, each as its click, guarded; a Left for you row's Review or Show;
///                               Cancel; Finish Round; the card's Done once finished), the next item <s> seconds later (2
///                               by default): {shown, sections, left: [[item, title, count]], goes: [[item, title, count]],
///                               followUps, new, toCheck, closed, drafts: [[id, text]], rows: [[id, unsent|sent|discarded]],
///                               unrequested, unread, card, finished, error, round, roundClosed, selected, tab, toast,
///                               notice, reading, before} (`card`: the round's card so far, as the summary result's;
///                               `finished`: the card the sheet turned into, or null; `notice`: the window's line and its
///                               buttons; `before`: a resumed round's "Finished before on …" line)
///   summary [<n>|export <path.png> [title] [student] [light|dark]|copy|done]  Round N Summary… (the shown round's, or
///                               round n's), its card written as Export Image… writes it, without the panel, its Copy
///                               Image (a --background run's own pasteboard), or its Done: {shown, round, words, wrote,
///                               figures: [[value, of, label]], tags: [[name, count]], praise, untagged, marks: [[page,
///                               y, column, kind]], pages, dateLine, student, facts, exported: {path, bytes, width,
///                               height}, copied: [pasteboard types]} (the next item 1 s later)
///   resume [ask|cancel|yes] [<path>]  Resume Round N (UX.md §31) for the paper shown, or that paper as its context
///                               menu: `ask` (the default) as the read-only box's button or a menu item (the
///                               confirmation shown), `cancel` its Cancel, `yes` its Resume (asked first when it was not),
///                               the next item 0.5 s (yes: 3 s) later: {asking, message, button, roundMenu, paperMenus:
///                               [[path, round]], round, latest, roundClosed, resumable, finishes: [{at, final, email}],
///                               level, tab, toast, alert}
///   key n|c|shift-c             as `key`, plus the reading result (below) (UX.md §18)
///   reading                     {round, marks, tracked, current, currentFullyVisible, unread, bars: [[block, page, x0, y0,
///                               x1, y1]], visible, toast, flash, outlineCurrent, status, statusShort, statusButtons,
///                               pdf: {page, visible}} (`status`: the status line's reading count)
///   outline                     the sidebar's Contents: [{block, title, number, name, level, read, count, open, changed,
///                               tracked, current}]
///   outlineclick <block>        a Contents row's action (the PDF to its heading): the reading result
///   contentsclick <block>       a click on that Contents row in the sidebar's own table, as the mouse sends it: the
///                               reading result, plus {clicked, listSelected}
///   barclick <block>            a click on the middle of that paragraph's bar, as `click`: its result plus {bar} and
///                               the reading result
///   barhover <block>            the pointer over that bar: {tooltip, cursor}
///   statusclick next|read       a click on the status line's Next or Mark Read, as the mouse sends it: the reading
///                               result plus {clicked}
///   sidebar                     {papersShown, header, othersToCheck, contents, message, current, currentRowVisible,
///                               listSelected, bodies: {sidebar, paper, section}}
///   papersfold                  folds or unfolds Papers, as its header's chevron does: the sidebar result
///   setting reading on|off      Settings' reading marks, as its toggle (a test run never saves it): the reading result
///                               plus {menus, dots, subtitle, ready} (`dots`: the Contents rows with an olive dot)
///   setting fold on|off         Settings' folding of a long appendix, as its toggle (never saved): the nav result
///   settings [general|overview|reading|tags|data]  the Settings window's tabs (toolbar tabs, as the Settings
///                               scene draws them) in a titled window of its own behind every other, on that tab
///                               (tools/shot.sh --pid … --all): {settings, on, size}
///   data [root|export|exportto|import|choose|settings|importnow|close|history|putback|remove|undo|comments|tags|clear|
///                               cancel …]  Settings › Data & Storage's work, Export…, Import…, Put Back an Earlier
///                               Ledger… and Remove from List without a panel, the result once it has finished
///                               (DataModel.debug)
///   migration                   whether this run would move the app's data to its new name (Migration.gate; never in a
///                               test run) and the places this run uses (DataHome): {gate, support, caches, reviews, notice}
///   icon [automatic|light|dark]  Settings › General's app icon style, as a click on it (a test run never saves it):
///                               {style, system, resource, dock, named, alert, about, distinct, remembers} (`dock`,
///                               `named`, `alert`, `about`: the Dock's image, the image named NSApplicationIcon, an
///                               alert's icon (laid out, never shown) and the About window's look as the icon shown
///                               now; `distinct`: the other form, light or dark, looks different)
///   appearance light|dark       the app's appearance changed while it runs, as the system's changes (an Automatic
///                               icon follows it): the icon result
///   ovpart show|fold appendix|references  a folded part shown at its real length, or folded again (its block or the
///                               axis's Show, the axis's Fold): the nav result
///   menubar [<menu>/<item>]     the menu bar's menus and the Reading menu's items; with a path, picks that item first
///                               (`items`: that menu's titles)
///   mark <name>                 creates the file <debug-out>.<name>, so a script outside can act at this point (take a
///                               screenshot with tools/shot.sh --pid); it holds the mark's ProcessInfo.systemUptime (the
///                               clock of ScreenCaptureKit's frame times), and the output gets {mark, uptime}
///   focus [on|off]              Focus on, off, or toggled, as the toolbar's button (POLISH §4.3, §7): the focus result:
///                               {focus, sidebar, panel, panelWidth, panelMax, panelItem, rows, tabs, status, pdf: {width,
///                               scale, auto, third}, widths, bodies} (`panelMax`: the panel's width cap in Focus,
///                               `panelItem`: its split view item's width; `rows`: what the shown tab's list shows, as in groups;
///                               `widths`: the PDF view's width at once, a turn later, then at 50, 150 and 400 ms: an
///                               instant switch has its last width at once; `third`: the point a third of the way down)
///   jump [<text>]               opens Jump (⌘K) and types the text into its field: {shown, query, firstResponder,
///                               groups: [[title, [[lead, title, detail, trailing]]]], highlighted}
///   jumpclick <n>               a click on the n-th row (from 0, across the groups), as the mouse sends it: {clicked,
///                               shown, selected, tab, focus, round, outlineCurrent, selection, toast, find}
///   find [<text>]               ⌘F (Edit › Find in Paper…), then the text typed into the toolbar's search field, as
///                               the user types (Find.swift): the find result once its search is in: {query, count,
///                               index, counter, searching, highlighted, inShownDocument, selection, selectionPage,
///                               visible, ring, toolbar, firstResponder, field} (`ring`: the current match's outline)
///   findkey return|shift-return|esc  the field's Return, ⇧Return or Esc: the find result
///   findclick next|previous     the counter's › or ‹, as its action: the find result
///   nav                         the navigation (UX.md §21): {level, paper, showsOverview, back, forward, canBack,
///                               canForward, overview: {status, paper, selection, strip, scroll, saved, rounds, sentence},
///                               review: {round, selected, tab, pdf, page}, title, subtitle, reviewHidden, sidebarShown,
///                               contents, firstResponder, pending, steps, forwardSteps, place, chip, flash, backHelp,
///                               forwardHelp} (`steps`: each Back place's PDF step, "p.4 · 2.1 Data", or null; `place`:
///                               the point a third of the way down, {label, page, y}; `chip`: {label, faded} or null)
///   paperopen <path> [review]   the sidebar's click on a paper (its overview), or double click (Review): the nav result
///   back / forward [<s>]        ⌘[ / ⌘]: the nav result <s> seconds later (1.5 by default)
///   sidebutton back|forward     a mouse's side button (3, 4) in the window, as it sends it: the nav result 1 s later
///   link <page> <n>             a click on the n-th link within the PDF on that page (both from 0), as the mouse sends
///                               it: {link: {words, to}, nav, preview} (the way back, PLAN §5; with the round's link
///                               table the click previews, PLAN §4)
///   preview [<what>]            the reference preview (PLAN §4) after <what>: `<page> <n>` a click on the n-th link of
///                               the round's link table on that page (both from 0; the engine's source links too),
///                               `again` / `double` a click on its link again / the second click of a double click,
///                               `go` its Go to ›, `picture <i>` a click on its i-th picture, `pin` its pin, `drag <dx>
///                               <dy>` its title row dragged, `cited <i>` its i-th "Cited on" page, `copy` Copy
///                               Reference, `scroll` the PDF scrolled 40 pt: {table, preview: {kind, title, page, box,
///                               entries: [[label, [w, h], drawn]], cited, count, footer, continues, side (above or
///                               below the link), gap (from its line, never < 0), frame, inView, widthShare,
///                               heightShare, scale, pageScale} or null, pinned: [titles], nav, clipboard (copy)}
///   allrounds / continue        the round menu's All Rounds / the overview's Continue Round N: the nav result
///   ovclick / ovopen <item>     a click / a double click on an overview item: section:<id>@<n>, round:<n>,
///                               page:<p>@<n> (p from 1), comment:<id>, none: the nav result
///   ovscroll <y>                the overview scrolled to y from its top: the nav result
///   ovwait                      waits (at most 10 s) until the overview's data is in: the nav result
///   tagfilter <tag>|untagged|off / groupby status|tag|section / list  the comment list's tag filter, its
///                               arrangement, and what it shows (UX.md §27): {filter, grouping, shown, options: [[id,
///                               name, count]], title, caption, selected, listed, rows, headers, toCheck, next}
///   listmenu [<title>]          the list's menu as its button opens it (the list result and menu: [[title, checked,
///                               count], "# Show", "—"]); with a title, that item chosen first
///   listmenuclick               a click on the list menu's button, as the mouse sends it: {clicked: [x, y, hit view],
///                               opened: {under: the button's frame in the window, menu}} (the menu is not opened)
///   panelwidth <w>              the review's divider moved so the panel is w pt wide, as a drag (screenshots; no result)
///   studenttag <tag>|untagged|off / studenttagopen <path>|<id>  the shown student's Topics row clicked: {student, tag,
///                               title, meta, papers: [[title, [[id, status, round]]]]}; a line's click: the nav result
///   wait <s>, quit
@MainActor
final class DebugScript {
    private let items: [String]
    private let out: String?
    private let quit: Bool
    private weak var controller: PDFController?
    private var results: [Any] = []
    private var model: AppModel? { controller?.model }

    init(spec: String, out: String?, quit: Bool, controller: PDFController) {
        items = spec.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.out = out
        self.quit = quit
        self.controller = controller
    }

    func start() { run(0) }

    private func run(_ i: Int) {
        guard i < items.count else { return finish() }
        let item = items[i]
        let next = { [weak self] (delay: Double, result: @escaping () -> Any?) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self else { return }
                if let r = result() { self.results.append(r) }
                self.run(i + 1)
            }
        }
        let (verb, rest) = Self.split(item)
        switch verb {
        case "clear":
            controller?.clearSelection()
            next(0.3) { nil }
        case "return":
            let quote = controller?.selectionAnchor()?.text ?? ""
            let handled = key("return")
            next(0.4) { [weak self] in "return handled=\(handled) editor=\(self?.controller?.popover?.isShown == true) quote=\(quote)" }
        case "wait":
            next(Double(rest) ?? 1) { nil }
        case "mark":
            let t = ProcessInfo.processInfo.systemUptime
            // written in place, not atomically: a temporary file beside it would match a watcher's `out.<name>*`
            if let out { try? Data(String(format: "%.6f\n", t).utf8).write(to: URL(fileURLWithPath: out + "." + rest)) }
            next(0) { ["mark": rest, "uptime": t] }
        case "quit":
            finish()
            NSApp.terminate(nil)
        case "panelscroll":
            model?.panel.scroller.debugScroll(CGFloat(Double(rest) ?? 0))
            next(0.3) { nil }
        case "dump":
            next(0.05) { [weak self] in self?.dump() }
        case "thread":
            next(0.05) { [weak self] in self?.thread() }
        case "showall":
            if let m = model, let id = m.panel.expanded, let card = m.panel.all.first(where: { $0.id == id }) {
                for key in card.thread.filter({ $0.short != nil }).map(\.id) + (card.fold != nil ? ["fold"] : [])
                    + card.turns.filter({ $0.words?.clamp != nil }).map({ $0.id + ".words" })
                    where !m.edit.showAll.contains(key) { m.actions.toggleShowAll(key) }
            }
            next(0.5) { nil }
        case "window":
            let v = rest.split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { window?.setContentSize(NSSize(width: v[0], height: v[1])) }
            next(0.8) { nil }
        case "shot":
            if let win = window {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-l", String(win.windowNumber), "-o", "-x", rest]
                try? p.run()
                p.waitUntilExit()
            }
            next(0.1) { ["shot": rest] }
        case "type":
            if let t = textResponder() { t.insertText(rest, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            next(0.3) { nil }
        case "typeslow":
            guard let a = Self.typeslowArguments(rest) else {
                next(0) { ["error": "typeslow <cps> <text>: \(rest)"] }
                break
            }
            typeSlowly(Array(a.text), Self.typingPauses(cps: a.cps, count: a.text.count)) { typed, start, end in
                next(0) { ["typeslow": a.text, "typed": typed, "start": start, "end": end] }
            }
        case "key":
            let t0 = ProcessInfo.processInfo.systemUptime
            let handled = key(rest)
            controller?.view?.window?.displayIfNeeded()  // the rest of the key's turn: the panel laid out and drawn
            let ms = ((ProcessInfo.processInfo.systemUptime - t0) * 10_000).rounded() / 10
            let reading = ["n", "c", "shift-c"].contains(rest)
            next(0.5) { [weak self] in
                var r: [String: Any] = ["key": rest, "handled": handled, "selected": nul(self?.selectedID), "editing": nul(self?.editing),
                                        "choice": nul(self?.model?.edit.choice?.verdict), "ms": ms]
                if reading, let d = self?.readingResult() { r.merge(d) { a, _ in a } }
                return r
            }
        case "reading":
            next(0.05) { [weak self] in self?.readingResult() }
        case "outline":
            next(0.05) { [weak self] in
                let current = self?.model?.reading.current.block
                return (self?.model?.reading.contents.rows ?? []).map {
                    ["block": $0.block, "title": $0.title, "number": nul($0.number), "name": $0.name, "level": $0.level,
                     "read": $0.read, "count": $0.count, "open": $0.open, "changed": $0.changed, "tracked": $0.tracked,
                     "current": $0.block == current] as [String: Any]
                }
            }
        case "contentsclick":
            var clicked: Any = NSNull()
            if let m = model, let t = sidebarTable(), let i = m.reading.contents.rows.firstIndex(where: { $0.block == Int(rest) }),
               let row = m.sidebarRows.firstIndex(of: .contents(i)) {
                // the rows as the list shows them (`SidebarLayout`): All Students, Your Move, the open paper, Contents
                if row < t.numberOfRows {
                    let r = t.convert(t.rect(ofRow: row), to: nil)
                    let p = CGPoint(x: r.midX, y: r.midY)
                    clicked = [row, Double(p.x), Double(p.y)] as [Any]
                    click(at: p, up: true)
                }
            }
            next(0.6) { [weak self] in
                var r = self?.readingResult() ?? [:]
                r["clicked"] = clicked
                r["listSelected"] = nul(self?.listSelected())
                return r
            }
        case "barclick", "barhover":
            guard let c = controller, let bar = c.readingBars.first(where: { $0.block == Int(rest) }) else {
                next(0) { ["error": "no bar for \(rest)"] }
                break
            }
            let spec = "\(bar.page),\((bar.rect[0] + bar.rect[2]) / 2),\((bar.rect[1] + bar.rect[3]) / 2)"
            mouse(verb == "barclick" ? "click" : "hover", spec, next: next)
        case "statusclick":
            var clicked: Any = NSNull()
            if let f = model?.reading.status.frames[rest == "read" ? "read" : "next"], let win = controller?.view?.window,
               let h = win.contentView?.bounds.height {
                let p = CGPoint(x: f.midX, y: h - f.midY)
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p)
            }
            next(0.6) { [weak self] in
                var r = self?.readingResult() ?? [:]
                r["clicked"] = clicked
                return r
            }
        case "sidebar":
            next(0.05) { [weak self] in self?.sidebarResult() }
        case "zoom":  // `zoom in|out|actual|fit|<percent>`: View's items or the status line's menu; `zoom by <f> page,x,y`: ⌘-scroll
            let a = rest.split(separator: " ").map(String.init)
            var pointer: [Any] = []
            if let c = controller, let v = c.view {
                switch a.first ?? "" {
                case "": break
                case "in": c.zoomStep(in: true)
                case "out": c.zoomStep(in: false)
                case "actual": c.setZoom(1)
                case "fit": c.setZoom(nil)
                case "by":
                    let d = a.count == 3 ? a[2].split(separator: ",").compactMap { Double($0) } : []
                    if let f = a.count == 3 ? Double(a[1]) : nil, d.count == 3, let page = v.document?.page(at: Int(d[0])) {
                        let cb = page.bounds(for: .cropBox), q = CGPoint(x: cb.minX + d[1], y: cb.maxY - d[2])
                        let at = v.convert(q, from: page)
                        c.zoom(by: f, at: at)
                        let now = v.convert(q, from: page)
                        pointer = [[Double(at.x), Double(at.y)], [Double(now.x), Double(now.y)]]
                    }
                default: if let pc = Double(a[0]) { c.setZoom(pc / 100) }
                }
            }
            next(0.4) { [weak self] in
                guard let c = self?.controller, let v = c.view else { return nil }
                return ["zoom": nul(c.zoom.map(Double.init)), "status": nul(c.position.zoom.map(ZoomRules.label)),
                        "scale": Double(v.scaleFactor), "auto": v.autoScales, "fit": Double(v.scaleFactorForSizeToFit),
                        "focus": self?.model?.focus ?? false, "page": nul(c.shownPage), "pointer": pointer,
                        "third": c.pointAtThird().map { [$0.page, $0.x, $0.y] as [Any] } ?? []] as [String: Any]
            }
        case "focus":
            guard let m = model else { next(0) { nil }; break }
            let v = controller?.view
            var widths: [Double] = []
            let before = controller?.pointAtThird().map { [$0.page, $0.x, $0.y] as [Any] } ?? []
            m.setFocus(rest == "on" ? true : rest == "off" ? false : !m.focus)
            widths.append(Double(v?.bounds.width ?? 0))
            DispatchQueue.main.async { widths.append(Double(v?.bounds.width ?? 0)) }
            for t in [0.05, 0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { widths.append(Double(v?.bounds.width ?? 0)) }
            }
            next(0.6) { [weak self] in
                var r = self?.focusResult() ?? [:]
                r["widths"] = widths
                r["before"] = before
                return r
            }
        case "motion":
            // the tab switch's motion slowed down (`motion 8`) so screenshots can catch it in flight; `motion 1` back
            TabMotion.slow = max(Double(rest) ?? 1, 1)
            next(0.05) { ["motion": TabMotion.slow] }
        case "busy":
            model?.holdBusy(rest != "off")
            next(0.1) { [weak self] in ["busy": self?.model?.busy ?? false] }
        case "gotopage":  // `gotopage 2`: the status line's Go to Page (design/pdf-reader/PLAN.md P1.4); `gotopage 2 300`: y 300 of it a third of the way down
            let a = rest.split(separator: " ").compactMap { Double($0) }
            if a.count == 2 { controller?.place(page: Int(a[0]), rect: [0, a[1], 0, a[1]]) } else { controller?.goToPage(Int(rest) ?? 0) }
            next(0.6) { [weak self] in
                ["page": nul(self?.controller?.position.page), "third": self?.controller?.pointAtThird().map { [$0.page, $0.x, $0.y] as [Any] } ?? [],
                 "chip": nul(self?.controller?.backChip.label)]
            }
        case "copytext":  // `copytext <page> <x0> <y0> <x1> <y1>` (contract points): selects from one point to the other, ⌘C (P1.2)
            let a = rest.split(separator: " ").compactMap { Double($0) }
            var copied: Any = NSNull()
            if a.count == 5, let v = controller?.view, let doc = v.document, let pg = doc.page(at: Int(a[0])) {
                let cb = pg.bounds(for: .cropBox)
                if let sel = pg.selection(from: CGPoint(x: cb.minX + a[1], y: cb.maxY - a[2]), to: CGPoint(x: cb.minX + a[3], y: cb.maxY - a[4])) {
                    v.setCurrentSelection(sel, animate: false)
                    v.copy(nil)
                    copied = ["clean": AppModel.clipboard.string(forType: .string) ?? "", "raw": sel.string ?? ""]
                }
            }
            next(0.2) { copied }
        case "windowclick":  // `windowclick <x> <y>`: a click at that point of the window's content, from its top left
            let a = rest.split(separator: " ").compactMap { Double($0) }
            var hit: Any = NSNull()
            if a.count == 2, let win = controller?.view?.window, let h = win.contentView?.bounds.height {
                let p = CGPoint(x: a[0], y: h - a[1])
                hit = win.contentView?.superview?.hitTest(p)?.className ?? "none"
                click(at: p)
            }
            next(0.6) { [weak self] in
                ["hit": hit, "firstResponder": nul(self?.keyTarget?.firstResponder.map { String(describing: type(of: $0)) }),
                 "windows": NSApp.windows.filter(\.isVisible).map { $0.className }]
            }
        case "strip":  // the markers beside the scroller (P1.6): kind, share of the height, label; the strip's inset
            next(0.3) { [weak self] in
                guard let c = self?.controller else { return nil }
                return ["inset": Double(c.strip.inset),
                        "items": c.strip.items.map { [String(describing: $0.kind), ($0.fraction * 1000).rounded() / 1000, $0.label] as [Any] },
                        "ticks": ScrollerMarks.ticks(c.strip.items, height: 600).map { [String(describing: $0.kind), Double($0.y), $0.help] as [Any] }]
            }
        case "stripclick":  // `stripclick <i>`: a click on the i-th tick of a 600 pt strip (`strip`'s order)
            if let c = controller, let i = Int(rest) {
                let ticks = ScrollerMarks.ticks(c.strip.items, height: 600)
                if i >= 0, i < ticks.count { c.goMark(ticks[i].target) }
            }
            next(0.8) { [weak self] in
                ["tab": self?.model?.tab.rawValue ?? "", "selected": nul(self?.selectedID), "chip": nul(self?.controller?.backChip.label),
                 "find": nul(self?.controller?.find.index)]
            }
        case "jump":
            if model?.jump.shown != true { model?.openJump() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !rest.isEmpty else { return }
                if let t = self.textResponder() {  // typed, as the user types
                    t.selectAll(nil)
                    t.insertText(rest, replacementRange: NSRange(location: NSNotFound, length: 0))
                } else {
                    self.model?.jump.setQuery(rest)
                }
            }
            next(0.8) { [weak self] in self?.jumpResult() }
        case "jumpclick":
            var clicked: Any = NSNull()
            if let f = model?.jump.frames[Int(rest) ?? 0], let win = controller?.view?.window, let h = win.contentView?.bounds.height {
                let p = CGPoint(x: f.midX, y: h - f.midY)
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p, up: true)  // the row's tap gesture needs the mouse-down and -up
            }
            next(1.0) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["clicked": clicked, "shown": m.jump.shown, "selected": nul(self?.selectedID), "tab": m.tab.rawValue,
                        "focus": m.focus, "round": nul(m.round?.n), "outlineCurrent": nul(m.reading.current.block),
                        "selection": nul(self?.controller?.view?.currentSelection?.string), "toast": nul(m.reading.toast),
                        "find": nul(m.findQuery), "firstResponder": self?.keyTarget?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull()]
            }
        case "find":
            model?.pdf.find.focusField()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !rest.isEmpty else { return }
                if let t = self.textResponder(), let f = self.model?.pdf.find.field, t.delegate === f {  // typed, as the user types
                    t.selectAll(nil)
                    t.insertText(rest, replacementRange: NSRange(location: NSNotFound, length: 0))
                } else {
                    self.model?.pdf.find.type(rest)
                }
            }
            afterFind(next, wait: 0.6)
        case "findkey":
            if let f = model?.pdf.find, let c = f.field?.delegate as? FindField.Coordinator {
                let sel = rest == "esc" ? #selector(NSResponder.cancelOperation(_:)) : #selector(NSResponder.insertNewline(_:))
                _ = c.command(sel, shift: rest == "shift-return")
            }
            afterFind(next, wait: 0.2)
        case "findclick":
            model?.pdf.find.step(previous: rest == "previous")
            afterFind(next, wait: 0.2)
        case "studentclick":  // a student's row selected in the sidebar's own table, as a click on it hands it to the list
            // (a background window takes no first click, so the table's selection is set as paperclick does)
            var hit: Any = NSNull()
            if let m = model, let t = sidebarTable(), let row = m.sidebarRows.firstIndex(of: .student(StudentName.key(rest))),
               row < t.numberOfRows {
                hit = [row, t.numberOfRows]
                t.selectRowIndexes([row], byExtendingSelection: false)
            }
            next(0.8) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["hit": hit, "hub": nul(m.hub.map { String(describing: $0) }), "folded": m.foldedStudents.sorted(),
                        "selectedRow": nul(self?.sidebarTable()?.selectedRow)]
            }
        case "studentfold":  // `studentfold <name>`: the student's chevron in the sidebar
            if let m = model { m.toggleStudentFold(StudentName.key(rest)) }
            next(0.4) { [weak self] in self?.sidebarResult() }
        case "hub":  // `hub all|move|student <name>`: the sidebar's All Students, Your Move or a student
            if let m = model {
                let page: HubPage? = rest == "all" ? .allStudents : rest == "move" ? .yourMove
                    : rest.hasPrefix("student ") ? .student(StudentName.key(String(rest.dropFirst(8)))) : nil
                if let page { m.openHub(page) }
            }
            waitForHub(0) { [weak self] in next(0.6) { self?.hubResult() } }
        case "hubwait":
            waitForHub(0) { [weak self] in next(0.3) { self?.hubResult() } }
        case "backfillwait":  // waits (at most 120 s) until the second engine process has filled in what it was asked
            waitForBackfill(0) { [weak self] in
                self?.waitForHub(0) {
                    next(0.5) { ["backfill": ["done": self?.model?.backfill.done ?? 0, "queued": self?.model?.backfill.queue.count ?? 0]] }
                }
            }
        case "hubscroll":  // the hierarchy's page scrolled to that offset from its top
            if let sv = model?.hubModel.scrollView { OverviewModel.scroll(sv, to: Double(rest) ?? 0) }
            next(0.4) { [weak self] in self?.hubResult() }
        case "editpaper":  // `editpaper <path>|title=<t>|student=<s>`: Edit Paper…'s Save (edit_paper)
            let parts = rest.split(separator: "|").map(String.init)
            let path = URL(fileURLWithPath: parts.first ?? "").standardizedFileURL.path
            func value(_ k: String) -> String? { parts.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
            model?.editPaper(path, title: value("title"), student: value("student"))
            next(2.0) { [weak self] in self?.sidebarResult() }
        case "renamestudent":  // `renamestudent <old>|<new>`: Rename Student…'s Rename
            let parts = rest.split(separator: "|").map(String.init)
            if parts.count == 2 { model?.renameStudent(StudentName.key(parts[0]), to: parts[1]) }
            next(2.5) { [weak self] in self?.sidebarResult() }
        case "finished":  // `finished <path> on|off`: Mark as (Not) Finished
            let parts = rest.split(separator: " ")
            let path = URL(fileURLWithPath: parts.first.map(String.init) ?? "").standardizedFileURL.path
            model?.setFinished(path, parts.last != "off")
            next(0.4) { [weak self] in self?.sidebarResult() }
        case "buckets":  // `buckets <path> <key>=<bucket>,…`: Map Headings…' Done for one paper ("" for its own column)
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let path = URL(fileURLWithPath: parts.first ?? "").standardizedFileURL.path
            var answers: [String: String] = [:]
            for pair in (parts.count > 1 ? parts[1] : "").split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if kv.count == 2 { answers[kv[0]] = kv[1] }
            }
            model?.setBuckets(path, answers)
            waitForHub(0) { [weak self] in next(0.5) { self?.hubResult() } }
        case "sheet":  // `sheet editpaper <path>|rename <name>|mapheadings <name>|none`: a sheet shown (screenshots)
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "editpaper": model?.editingPaper = URL(fileURLWithPath: arg).standardizedFileURL.path
            case "rename": model?.renamingStudent = StudentName.key(arg)
            case "mapheadings": model?.mappingHeadings = StudentName.key(arg)
            default:
                model?.editingPaper = nil
                model?.renamingStudent = nil
                model?.mappingHeadings = nil
            }
            next(1.0) { nil }
        case "movebutton":  // `movebutton <path>`: Your Move's button for that paper (Continue, Finish Round N…, Show Log…)
            let path = URL(fileURLWithPath: rest).standardizedFileURL.path
            if let m = model, let item = m.yourMove.first(where: { $0.paper.path == path }) { m.moveAction(item) }
            next(3.0) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["nav": (self?.navResult()).map { $0 as Any } ?? NSNull(), "finishSheet": m.showFinish] as [String: Any]
            }
        case "setting":  // `setting reading on|off`: Settings' reading marks, as its toggle (never saved by a test run)
            if rest.hasPrefix("fold") {
                model?.foldParts = !rest.hasSuffix("off")
                next(0.5) { [weak self] in self?.navResult() }
                break
            }
            if rest.hasPrefix("reading") { model?.readingMarksOn = !rest.hasSuffix("off") }
            next(0.5) { [weak self] in
                var r = self?.readingResult() ?? [:]
                r["menus"] = NSApp.mainMenu?.items.map(\.title) ?? []
                r["dots"] = self?.model?.reading.contents.rows.filter(\.changed).count ?? 0
                r["subtitle"] = self?.model?.windowSubtitle ?? ""
                r["ready"] = self?.model?.readyToFinish ?? false
                return r
            }
        case "settings":  // the Settings view in a window of its own, behind every other window (for tools/shot.sh --all)
            let words = rest.split(separator: " ").map(String.init)
            TagsSettings.debugSelection = words.count > 1 ? words[1] : nil  // `settings tags <id>`: that tag selected
            if let m = model { settingsWindow = Self.showSettings(m, tab: SettingsView.Tab(rawValue: words.first ?? "") ?? .general, close: settingsWindow) }
            next(0.6) { [weak self] in
                ["settings": self?.settingsWindow?.isVisible ?? false, "on": self?.model?.readingMarksOn ?? false,
                 "size": self?.settingsWindow.map { [Double($0.frame.width), Double($0.frame.height)] } ?? []]
            }
        case "data":  // Settings › Data & Storage without a panel (UX.md §28; DataModel.debug)
            if let m = model { m.data.debug(rest) { r in next(0) { r } } } else { next(0) { nil } }
        case "migration":  // UX.md §34: a test run never migrates, and takes the new names without looking at the disk
            let gate = Migration.gate(bundleID: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL,
                                      arguments: CommandLine.arguments, unitTest: LaunchOptions.unitTest, testRun: LaunchOptions.isTestRun)
            let home = DataHome.current(AppVariant.current)
            next(0) {
                ["gate": (gate?.name as Any?) ?? NSNull(), "support": home.support.path, "caches": home.caches.path,
                 "reviews": home.reviews.path, "notice": (Migration.notice?.title as Any?) ?? NSNull()]
            }
        case "icon":  // Settings › General's app icon style (UX.md §26)
            let icons = AppIconModel.shared
            for w in rest.split(separator: " ").map(String.init) {
                if let st = AppIconStyle(rawValue: w) { icons.style = st }
            }
            next(0.3) { Self.iconResult() }
        case "appearance":
            NSApp.appearance = NSAppearance(named: rest == "dark" ? .darkAqua : .aqua)
            next(0.5) { Self.iconResult() }
        // the writing tags, Reopen and the key page (UX.md §24)
        case "tags":  // the catalogue, the selected card's tags, the open picker, the overview's and the student's numbers
            next(0.05) { [weak self] in self?.tagsResult() }
        case "tagpicker":  // `tagpicker <id>`: the card's + (its picker opens); `tagpicker close`: a click outside it
            if rest == "close" { if let id = model?.edit.tagging { model?.closeTagPicker(id) } } else { model?.openTagPicker(rest) }
            next(rest == "close" ? 1.0 : 0.6) { [weak self] in self?.tagsResult() }
        case "tagclick":  // `tagclick <tag id>`: a chip of the open picker; `tagclick new <name>`: New Tag…, the name, Return
            if let sel = openPicker {
                if rest.hasPrefix("new ") {
                    sel.naming = true
                    sel.newName = String(rest.dropFirst(4))
                    if let t = model?.tags { sel.commitNew(t) }
                } else {
                    sel.toggle(rest)
                }
            }
            next(0.4) { [weak self] in self?.tagsResult() }
        case "settags":  // `settags <comment> <tag,tag>` (`-` for none): the comment's tags, as the picker writes them
            let parts = rest.split(separator: " ").map(String.init)
            if parts.count == 2 { model?.setTags(parts[0], parts[1] == "-" ? [] : parts[1].split(separator: ",").map(String.init)) }
            next(1.0) { [weak self] in self?.tagsResult() }
        case "revive":  // `revive <id>`: Reopen in Round N; `revive undo <id>`: Undo Reopen (confirmed)
            if rest.hasPrefix("undo ") { model?.undoRevive(String(rest.dropFirst(5)), confirmed: true) } else { model?.revive(rest) }
            next(2.5) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["round": nul(m.round?.n), "selected": nul(self?.selectedID), "editing": nul(self?.editing),
                        "toast": nul(m.panelToast.text), "groups": ["toCheck": m.panel.groups.toCheck.map(\.id)],
                        "card": nul(self?.tagsResult()["card"])] as [String: Any]
            }
        case "keypage":  // `keypage <round> <page>` (page from 1): Set as Key Page; `keypage off`: Use the Busiest Page
            if let m = model, let path = m.selectedPath {
                let v = rest.split(separator: " ").compactMap { Int($0) }
                m.setKeyPage(path, v.count == 2 ? KeyPageChoice(round: v[0], page: v[1] - 1) : nil)
            }
            next(2.0) { [weak self] in self?.tagsResult() }
        case "tagsheet":  // `tagsheet [student <name>]`: Tag Comments…; `tagsheet select <id>`; `tagsheet all`; `tagsheet close`
            if let m = model {
                if rest == "close" { m.closeTagComments() }
                else if rest == "all" { m.tagComments?.showAll.toggle() }
                else if rest.hasPrefix("select "), let s = m.tagComments {
                    let id = String(rest.dropFirst(7))
                    if let e = s.entries.first(where: { $0.id == id }) { s.select(e.key, tags: m.tags) }
                } else if rest.hasPrefix("student ") { m.openTagComments(student: StudentName.key(String(rest.dropFirst(8)))) }
                else { m.openTagComments() }
            }
            next(rest == "close" ? 1.5 : 0.8) { [weak self] in self?.tagsResult() }
        case "tagsetting":  // Settings › Tags: `rename <id> <name>`, `hide|show <id>`, `move <id> <±n>`, `group <id> <group>`,
            // `merge <from> <into>`, `delete <id>`, `restore`, `suggest on|off`, `add <name>`
            if let m = model {
                let a = rest.split(separator: " ", maxSplits: 2).map(String.init)
                switch a.first {
                case "rename" where a.count == 3: m.tags.update { _ = $0.rename(a[1], to: a[2]) }
                case "hide" where a.count >= 2: m.tags.update { $0.setHidden(a[1], true) }
                case "show" where a.count >= 2: m.tags.update { $0.setHidden(a[1], false) }
                case "move" where a.count == 3: m.tags.update { $0.step(a[1], by: Int(a[2]) ?? 0) }
                case "group" where a.count == 3: if let g = TagGroup(rawValue: a[2]) { m.tags.update { $0.setGroup(a[1], g) } }
                case "merge" where a.count == 3: m.mergeTags(from: a[1], into: a[2])
                case "delete" where a.count >= 2: m.tags.update { _ = $0.delete(a[1], used: 0) }
                case "restore": m.tags.update { $0.restoreDefaultNames() }
                case "suggest" where a.count >= 2: m.tags.suggest = a[1] != "off"
                case "add" where a.count >= 2: _ = m.tags.add(name: a.dropFirst().joined(separator: " "), sign: nil)
                default: break
                }
            }
            next(1.0) { [weak self] in self?.tagsResult() }
        // tags as a way to organise the comments (UX.md §27)
        case "tagfilter":  // `tagfilter <tag>|untagged|off`: the list shows only that tag's comments (the menu's Show)
            model?.setTagFilter(rest == "off" || rest.isEmpty ? nil : rest == "untagged" ? TagCatalog.untagged : rest)
            next(0.4) { [weak self] in self?.model?.listResult() }
        case "listmenu":  // `listmenu [<title>]`: the list's menu, as its button builds it; with a title, that item chosen
            if let m = model, !rest.isEmpty { _ = ListMenu.perform(rest, in: ListMenu.make(m.listBar)) }
            next(0.4) { [weak self] in
                guard let m = self?.model else { return nil }
                return m.listResult().merging(["menu": ListMenu.describe(ListMenu.make(m.listBar))]) { a, _ in a }
            }
        case "listmenuclick":  // a click on the list menu's button, as the mouse sends it; the menu kept, not opened
            var clicked: Any = NSNull(), opened: Any = NSNull()
            ListMenu.dryRun = { menu, v in
                let r = v.convert(v.bounds, to: nil)
                opened = ["under": [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)],
                          "menu": ListMenu.describe(menu)] as [String: Any]
            }
            func anchors(_ v: NSView) -> [NSView] {
                (v is MenuAnchor.Anchor && !v.isHiddenOrHasHiddenAncestor ? [v] : []) + v.subviews.flatMap(anchors)
            }
            if let win = controller?.view?.window, let root = win.contentView?.superview, let a = anchors(root).first {
                let p = a.convert(NSPoint(x: a.bounds.midX, y: a.bounds.midY), to: nil)
                clicked = [Double(p.x), Double(p.y), root.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p, up: true)
            }
            next(0.4) {
                ListMenu.dryRun = nil
                return ["clicked": clicked, "opened": opened]
            }
        case "panelwidth":  // `panelwidth <w>`: the review's divider moved so the panel is w pt wide (screenshots)
            var v = model?.panel.scroller.scrollView?.superview
            while let s = v, (s as? NSSplitView)?.isVertical != true { v = s.superview }
            if let w = Double(rest), let split = v as? NSSplitView {
                split.setPosition(split.bounds.width - CGFloat(w) - split.dividerThickness, ofDividerAt: 0)
            }
            next(0.8) { nil }
        case "groupby":  // `groupby status|tag|section`: the list menu's Arrange By (never saved by a test run)
            if let g = ListGrouping(rawValue: rest) { model?.listBar.group(g) }
            next(0.4) { [weak self] in self?.model?.listResult() }
        case "list":  // the line over the list and what the list shows
            next(0.05) { [weak self] in self?.model?.listResult() }
        case "studenttag":  // `studenttag <tag>|untagged|off`: a row of the shown student's Topics by round clicked
            model?.pickStudentTag(rest == "off" || rest.isEmpty ? nil : rest == "untagged" ? TagCatalog.untagged : rest)
            next(0.4) { [weak self] in self?.model?.studentTagResult() }
        case "studenttagopen":  // `studenttagopen <path>|<id>`: a click on that comment's line under it (Review there)
            let a = rest.split(separator: "|").map(String.init)
            if a.count == 2, let l = model?.studentTagLine(a[0], a[1]) { model?.openInReview(paper: l.path, comment: a[1], round: l.line.round) }
            next(3.0) { [weak self] in self?.navResult() }
        case "outlineclick":
            model?.outlineOpen(Int(rest) ?? 0)
            next(0.5) { [weak self] in self?.readingResult() }
        case "menubar":
            let menus = NSApp.mainMenu?.items ?? []
            var picked: Any = NSNull(), items: Any = NSNull()
            if let slash = rest.firstIndex(of: "/") {
                let menu = menus.first { $0.title == String(rest[..<slash]) }?.submenu
                if let menu { menu.delegate?.menuNeedsUpdate?(menu); menu.update() }  // as when it opens
                items = menu?.items.map(\.title) ?? []
                if let menu, let i = menu.items.firstIndex(where: { $0.title == String(rest[rest.index(after: slash)...]) }) {
                    menu.performActionForItem(at: i)
                    picked = [menu.items[i].title, menu.items[i].isEnabled] as [Any]
                }
            }
            next(0.5) { [weak self] in
                var r = self?.readingResult() ?? [:]
                r["menus"] = menus.map(\.title)
                r["reading"] = menus.first { $0.title == "Reading" }?.submenu?.items.map { [$0.title, $0.keyEquivalent, $0.isEnabled] as [Any] } ?? []
                r["picked"] = picked
                r["items"] = items  // the titles of the menu the item was looked for in
                return r
            }
        case "card":
            model?.actions.rowClicked(rest)
            next(0.6) { [weak self] in self?.cardResult() }
        case "note":
            model?.actions.editNote(rest)
            next(0.6) { [weak self] in self?.cardResult() }
        case "button":
            let (name, delay) = Self.split(rest)
            var ignored = false
            if let id = model?.selectedComment?.id, let a = model?.actions {
                ignored = model?.clickIgnored(id) ?? false
                switch name {
                case "resolve": a.press("verified", id)
                case "followup": if model?.draftText(id).isEmpty == false { a.sendDraft(id) } else { a.press("reopened", id) }
                case "keep": a.press("wontfix", id)
                case "discard": a.discardDraft(id)
                case "gotit": a.tips.dismiss()
                default: break
                }
            }
            next(Double(delay) ?? 0.6) { [weak self] in
                var r = self?.cardResult() as? [String: Any] ?? [:]
                r["ignored"] = ignored
                r["tip"] = self?.model?.actions.tips.answer ?? false
                r["toast"] = nul(self?.model?.panelToast.text)
                return r
            }
        case "rowclick":  // a click on a row of the shown tab's list, as the mouse sends it (its tap gesture: down and up)
            var clicked: Any = NSNull()
            let table = model?.tab == .changes ? model?.changes.scroller.table : model?.panel.scroller.table
            if let f = table?.rowFrame(rest), let win = controller?.view?.window {
                let p = CGPoint(x: f.midX, y: f.maxY - 12)  // line 1, clear of the expanded card laid over a selected row
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p, up: true)
            }
            next(0.6) { [weak self] in
                var r = self?.cardResult() as? [String: Any] ?? [:]
                r["clicked"] = clicked
                r["expanded"] = nul(self?.model?.tab == .changes ? self?.model?.changes.expanded : self?.model?.panel.expanded)
                return r
            }
        case "toolbarclick":  // the floating toolbar's Comment (its last button), as the mouse sends it
            var clicked: Any = NSNull()
            if let bar = controller?.toolbarView, controller?.toolbarShown == true, let win = bar.window {
                let r = bar.convert(bar.bounds, to: nil)
                let p = CGPoint(x: r.maxX - 30, y: r.midY)
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p, up: true)  // a SwiftUI button: the mouse-down and -up to its view
            }
            next(0.8) { [weak self] in
                ["clicked": clicked, "editor": self?.controller?.popover?.isShown == true,
                 "editorQuote": nul(self?.controller?.popover?.isShown == true ? self?.controller?.draft?.quote : nil),
                 "toolbar": self?.controller?.toolbarShown ?? false]
            }
        case "editorclick":  // the new-comment popover's Cancel or Save (its two AppKit buttons, in that order)
            var clicked: Any = NSNull()
            if let pop = controller?.popover, pop.isShown, let root = pop.contentViewController?.view, let win = root.window {
                var buttons: [NSButton] = []
                func walk(_ v: NSView) { if let b = v as? NSButton { buttons.append(b) }; v.subviews.forEach(walk) }
                walk(root)
                if buttons.count >= 2, let b = rest == "save" ? buttons.last : buttons.dropLast().last {
                    let p = b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
                    clicked = [Double(p.x), Double(p.y), b.className] as [Any]
                    click(at: p, in: win)  // an AppKit button tracks the queued mouse-up
                }
            }
            next(1.2) { [weak self] in
                ["clicked": clicked, "editor": self?.controller?.popover?.isShown == true, "selected": nul(self?.selectedID),
                 "confirmDiscard": self?.controller?.draft?.confirmDiscard ?? false]
            }
        case "toastclick":  // the toast's Undo or Redo, where it is on screen (SwiftUI's global frame: from the top left)
            var clicked: Any = NSNull()
            if let f = model?.panelToast.buttonFrame, model?.panelToast.text != nil, let win = controller?.view?.window,
               let h = win.contentView?.bounds.height {
                let p = CGPoint(x: f.midX, y: h - f.midY)
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p)
            }
            next(0.8) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["clicked": clicked, "toast": nul(m.panelToast.text), "action": nul(m.panelToast.action.map { "\($0)" }),
                        "selected": nul(self?.selectedID), "verdict": nul(m.selectedComment?.verdict),
                        "undo": m.history.undos.count, "redo": m.history.redos.count]
            }
        case "hover":
            hover(rest, next: next)
        case "field":  // as a click: the text view takes focus itself
            if let w = controller?.view?.window, let tv = fieldView(in: w.contentView) { w.makeFirstResponder(tv) }
            next(0.4) { [weak self] in self?.cardResult() }
        case "quitcheck":
            next(0.05) { [weak self] in
                self?.model?.unsentDraftsQuestion().map { ["title": $0.title, "detail": $0.detail] } ?? NSNull()
            }
        case "change":
            model?.actions.changeClicked(rest)
            next(0.6) { [weak self] in
                let ch = self?.model.flatMap { m in (m.changes.unrequested + m.changes.linked).first { $0.id == rest } }
                return ["selected": nul(self?.selectedID), "expanded": nul(self?.model?.changes.expanded),
                        "panel": self?.model?.changes.scroller.dump ?? [:], "unrequested": nul(ch?.unrequested),
                        "answers": ch?.links.map(\.id) ?? [], "notes": ch?.notes.map { [$0.id, $0.text] } ?? []]
            }
        case "notewarnings":  // the Comments tab's line of student notes not used; `show` / `hide` its Details… popover
            if rest == "show" || rest == "hide" { model?.showNoteWarnings = rest == "show" }
            next(0.6) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["line": m.noteWarningsLine, "shown": m.showNoteWarnings,
                        "warnings": m.noteWarnings.map { [$0.kind, nul($0.place), nul($0.text), $0.message] as [Any] }]
            }
        case "tab":
            // `ms`: from the switch to the next turn of the run loop, the switch's own turn (SwiftUI's update, the
            // layout and the drawing) done
            let t0 = ProcessInfo.processInfo.systemUptime
            var ms = -1.0
            model?.tab = PanelTab(rawValue: rest) ?? .comments
            DispatchQueue.main.async { ms = ((ProcessInfo.processInfo.systemUptime - t0) * 10_000).rounded() / 10 }
            next(0.4) { [weak self] in
                ["tab": self?.model?.tab.rawValue ?? "", "selected": nul(self?.selectedID),
                 "marks": self?.controller?.selectedMarks ?? [], "ms": ms]
            }
        case "round":
            model?.showRound(Int(rest) ?? 0)
            next(2.0) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["round": nul(m.round?.n), "latest": nul(m.latestRound?.n), "earlier": m.viewingEarlierRound,
                        "open": m.roundIsOpen, "pdf": nul(self?.controller?.loadedPath), "comments": m.state?.comments.count ?? 0,
                        "changes": m.state?.changes.count ?? 0, "selected": nul(self?.selectedID),
                        "marks": self?.controller?.selectedMarks ?? [], "toast": nul(m.reading.toast),
                        "third": self?.controller?.pointAtThird().map { [$0.page, $0.x, $0.y] as [Any] } ?? []]
            }
        case "paper":
            model?.selectPaper(URL(fileURLWithPath: rest).standardizedFileURL.path)
            next(2.0) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["paper": nul(m.selectedPath), "round": nul(m.round?.n), "popover": self?.controller?.popover?.isShown == true,
                        "toast": nul(m.reading.toast)]
            }
        case "paperclick":
            let path = URL(fileURLWithPath: rest).standardizedFileURL.path
            var hit: Any = NSNull()
            if let t = sidebarTable(), let row = model?.sidebarRows.firstIndex(of: .paper(path)), row < t.numberOfRows {
                hit = [row, t.numberOfRows]
                // the table's selection, which the list hands to its selection binding, as after a click on the row
                t.selectRowIndexes([row], byExtendingSelection: false)
            }
            next(2.0) { [weak self] in
                guard let m = self?.model else { return nil }
                return ["paper": nul(m.selectedPath), "listSelected": nul(self?.listSelected()),
                        "popover": self?.controller?.popover?.isShown == true, "toast": nul(m.reading.toast), "hit": hit]
            }
        case "close", "closemenu":
            let win = window
            results.append(["delegate": nul((win?.delegate as? NSObject)?.className),
                            "question": model?.unsentDraftsQuestion().map { ["title": $0.title, "detail": $0.detail] } ?? NSNull()])
            let text = results.map { r -> String in
                String(decoding: (try? JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed, .sortedKeys])) ?? Data(),
                       as: UTF8.self)
            }.joined(separator: "\n") + "\n"
            if let out { try? text.write(toFile: out, atomically: true, encoding: .utf8) } else { FileHandle.standardError.write(Data(text.utf8)) }
            if verb == "close" { win?.standardWindowButton(.closeButton)?.performClick(nil) } else { win?.performClose(nil) }
            next(1.0) { [weak self] in  // still here: the close did not quit
                ["closed": win?.isVisible == false, "popover": self?.controller?.popover?.isShown == true, "asked": QuitOnClose.asked,
                 "key": nul(NSApp.keyWindow?.className), "modal": nul(NSApp.modalWindow?.className)]
            }
        case "nav":
            next(0.05) { [weak self] in self?.navResult() }
        case "paperopen":  // `paperopen <path> [review]`: the sidebar's click (its overview) or double click (Review)
            let parts = rest.split(separator: " ")
            let path = URL(fileURLWithPath: parts.first.map(String.init) ?? "").standardizedFileURL.path
            model?.openPaper(path, level: parts.dropFirst().first == "review" ? .review : .overview)
            next(2.0) { [weak self] in self?.navResult() }
        case "back", "forward":
            if verb == "back" { model?.goBack() } else { model?.goForward() }
            next(Double(rest) ?? 1.5) { [weak self] in self?.navResult() }
        case "sidebutton":  // `sidebutton back|forward`: a mouse's side button (3 or 4) in the window, as it sends it
            if let w = controller?.view?.window, let e = Self.sideButton(rest == "forward" ? 4 : 3, in: w) {
                NSApp.postEvent(e, atStart: false)
            }
            next(1.0) { [weak self] in self?.navResult() }
        case "link":  // `link <page> <n>`: a click on the n-th link within the PDF on page <page> (both from 0)
            link(rest, next: next)
        case "preview":  // the reference preview (PLAN §4), after a click, a button or a scroll
            preview(rest, next: next)
        case "allrounds":
            model?.showAllRounds()
            next(Double(rest) ?? 1.0) { [weak self] in self?.navResult() }
        case "continue":
            if let m = model { m.openReview(ReviewTarget(round: m.continueButton?.round)) }
            next(Double(rest) ?? 1.5) { [weak self] in self?.navResult() }
        case "ovclick", "ovopen":  // a click (`ovopen`: a double click) on an overview item: section:<id>@<n>, round:<n>,
            // page:<p>@<n> (p from 1, as the strip's numbers), comment:<id>, none
            let item = Self.overviewItem(rest)
            let t0 = ProcessInfo.processInfo.systemUptime
            model?.overviewClicked(item, double: verb == "ovopen")
            next(verb == "ovopen" ? 2.0 : 0.5) { [weak self] in
                var r = self?.navResult() ?? [:]
                r["timing"] = Self.mapTiming(since: t0)
                return r
            }
        case "ovscroll":  // the overview scrolled to that offset from its top
            if let sv = model?.overview.scrollView { OverviewModel.scroll(sv, to: Double(rest) ?? 0) }
            next(0.3) { [weak self] in self?.navResult() }
        case "ovwait":  // until the overview's data is in (at most 10 s)
            waitForOverview(started: ProcessInfo.processInfo.systemUptime) { next(0) { [weak self] in self?.navResult() } }
        case "ovhover":  // the pointer on the map, as its hover handler gets it (a background run's window never gets
            // one): cell:<id>@<n>, round:<n> (its rail), edit:<id>@<n>, dot:<comment>@<n> (a path's point), at:<x>,<y> (the
            // map's own points); comment:<id> (a panel's line: its path previewed); off
            overviewHover(rest)
            next(0.4) { [weak self] in self?.navResult() }
        case "ovkey":  // a key while the map has the keys (`key` routes it as typed): left, right, up, down, return
            let t0 = ProcessInfo.processInfo.systemUptime
            let handled = key(rest)
            next(rest == "return" ? 2.0 : 0.4) { [weak self] in
                var r = self?.navResult() ?? [:]
                r["handled"] = handled
                r["timing"] = Self.mapTiming(since: t0)
                return r
            }
        case "ovtext":  // the overview's words and numbers as drawn: the header, each row of the map, the table
            next(0.05) { [weak self] in self?.overviewText() }
        case "ovpart":  // `ovpart show|fold appendix|references`: a folded part shown, or folded again
            let (what, kind) = Self.split(rest)
            if let k = FoldKind(rawValue: kind) { if what == "fold" { model?.foldPart(k) } else { model?.showPart(k) } }
            next(0.5) { [weak self] in self?.navResult() }
        case "ovtable":  // the paper map as a table (on) or as the map (off), as the legend's switch
            model?.setMapAsTable(rest == "on")
            next(0.5) { [weak self] in self?.navResult() }
        case "papers":
            next(0.05) { [weak self] in
                (self?.model?.papers ?? []).map {
                    ["path": $0.path, "step": nul(self?.model?.summaries[$0.path]?.text),
                     "badge": nul(self?.model?.summaries[$0.path]?.badge),
                     "badgeShown": self?.model?.summaries[$0.path]?.badge != nil && $0.path != self?.model?.selectedPath]
                }
            }
        case "finishsheet":
            let (what, args) = Self.split(rest)
            let (id, delay) = Self.split(args)
            if let m = model {
                switch what {
                case "send": m.finishDraft(id, send: true)
                case "discard": m.finishDraft(id, send: false)
                case "undo": m.finishRestoreDraft(id)
                case "show": m.review(.comment(id))
                case "left":
                    switch id {
                    case "comments": m.review(m.panel.groups.toCheck.first.map { .comment($0.id) })
                    case "edits": m.review(m.changes.unrequested.first { !$0.handled }.map { .change($0.id) })
                    default: m.reviewReading()
                    }
                case "cancel": m.showFinish = false
                case "finish": m.finishRound()
                case "done": m.closeFinishSummary()
                default: m.openFinish()
                }
            }
            next(Double(delay) ?? 2.0) { [weak self] in self?.finishResult() }
        case "summary":
            let (what, args) = Self.split(rest)
            var exported: Any = NSNull()
            if let m = model {
                switch what {
                case "export":
                    let words = args.split(separator: " ").map(String.init)
                    if let path = words.first, let ask = m.roundCard ?? m.finishPreview.done,
                       let png = RoundCardImage.png(ask.stats, showTitle: words.contains("title"), showStudent: words.contains("student"),
                                                    dark: words.contains("dark")) {
                        try? png.write(to: URL(fileURLWithPath: path))
                        let rep = NSBitmapImageRep(data: png)
                        exported = ["path": path, "bytes": png.count, "width": rep?.pixelsWide ?? 0, "height": rep?.pixelsHigh ?? 0]
                    }
                case "copy":
                    if let ask = m.roundCard ?? m.finishPreview.done,
                       let png = RoundCardImage.png(ask.stats, showTitle: false, showStudent: false, dark: false) {
                        RoundCardImage.copy(png)
                    }
                case "done": m.roundCard = nil
                default: m.openRoundSummary(Int(what))
                }
            }
            next(1.0) { [weak self] in
                guard let m = self?.model else { return nil }
                let ask = m.roundCard ?? m.finishPreview.done
                var out = ask.map { Self.cardResult($0.stats) } ?? [:]
                out["shown"] = ask != nil
                out["exported"] = exported
                out["copied"] = (AppModel.clipboard.types ?? []).map(\.rawValue)
                return out
            }
        case "resume":
            let (what, path) = Self.split(rest)
            if let m = model {
                let p = path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL.path
                switch what {
                case "cancel": m.confirmResume = nil
                case "yes":
                    if m.confirmResume == nil { m.askResume(p) }
                    if let a = m.confirmResume { m.resumeRound(a) }
                default: m.askResume(p)
                }
            }
            next(what == "yes" ? 3.0 : 0.5) { [weak self] in self?.resumeResult() }
        case "fold":
            model?.toggleFold(FoldedGroup(rawValue: rest))
            next(0.3) { [weak self] in self?.foldResult() }
        case "groups":
            next(0.05) { [weak self] in
                guard let m = self?.model else { return nil }
                let g = m.panel.groups
                return ["toCheck": g.toCheck.map(\.id), "forStudent": g.forStudent.map(\.id), "closed": g.closed.map(\.id),
                        "showStudent": m.panel.showStudent, "showClosed": m.panel.showClosed, "selected": nul(self?.selectedID),
                        "toast": nul(m.panelToast.text), "dimmed": m.panel.scroller.table?.dimmed ?? [],
                        "cardTop": nul((m.panel.scroller.dump["card"] as? [Double])?.first), "ready": m.panel.ready,
                        "tip": m.actions.tips.answer, "rows": m.panel.scroller.table?.listed ?? [],
                        "studentNotes": m.panel.cards.filter { $0.studentNote != nil }.map(\.id),
                        "headers": m.panel.scroller.table?.headers ?? []]
            }
        case "nopaper":
            if let m = model {
                m.selectPaper(nil)
                if rest == "all" && m.fixtureURL != nil { m.papers = [] }  // a fixture run never saves its list
            }
            next(0.5) { [weak self] in ["paper": nul(self?.model?.selectedPath), "papers": self?.model?.papers.count ?? 0] }
        case "doneclick":
            var clicked: Any = NSNull()
            if let p = model?.panel.scroller.table?.donePoint(), let win = controller?.view?.window {
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p)
            }
            next(2.0) { [weak self] in
                var r = self?.finishResult() as? [String: Any] ?? [:]
                r["clicked"] = clicked
                return r
            }
        case "foldclick", "headerclick":  // a click on a folded group's Show / Hide, or on its name, as the mouse sends it
            let g = FoldedGroup(rawValue: rest) ?? (model?.tab == .changes ? .linked : .closed)
            let scroller = g == .linked ? model?.changes.scroller : model?.panel.scroller
            var clicked: Any = NSNull()
            if let f = scroller?.table?.foldFrame(g), let win = controller?.view?.window {
                let p = CGPoint(x: verb == "foldclick" ? f.maxX - 26 : f.minX + 60, y: f.midY)
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p)
            }
            next(0.4) { [weak self] in
                var r = self?.foldResult() as? [String: Any] ?? [:]
                if verb == "headerclick" { r["clicked"] = clicked }
                return r
            }
        case "cardclick":
            let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let v = parts.prefix(2).compactMap { Double($0) }
            if v.count == 2, let f = model?.panel.scroller.table?.cardFrame {
                // `up`: the mouse-down and -up to the view at once, as a SwiftUI button's gesture needs them
                click(at: CGPoint(x: f.minX + v[0], y: f.maxY - v[1]), up: parts.count > 2 && parts[2] == "up")
            }
            next(0.4) { [weak self] in
                var r = self?.cardResult() as? [String: Any] ?? [:]
                r["firstResponder"] = self?.keyTarget?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull()
                return r
            }
        case "changecomment":
            model?.actions.commentOnChange(rest)
            next(1.0) { [weak self] in
                ["editor": self?.controller?.popover?.isShown == true,
                 "quote": nul(self?.controller?.selectionAnchor()?.text), "box": self?.controller?.pendingBox != nil,
                 "editorQuote": nul(self?.controller?.popover?.isShown == true ? self?.controller?.draft?.quote : nil),
                 "selected": nul(self?.selectedID)]
            }
        case "cardmenu":
            let (id, title) = Self.split(rest)
            if let m = model {
                _ = CardMenus.perform(title, in: CardMenus.more(id, model: m))
            }
            next(0.6) { [weak self] in self?.cardResult() }
        case "swatch", "kind":
            style(verb, rest)
            next(0.4) { [weak self] in self?.styleResult() }
        case "markbar":
            next(0.05) { [weak self] in self?.markBarResult() }
        case "markbarclick":
            var clicked: Any = NSNull()
            if let c = controller, c.markBarShown, let bar = c.markBarView, let host = bar.subviews.first,
               let f = c.markBar.frames[rest], let win = bar.window {
                let p = host.convert(CGPoint(x: f.midX, y: host.isFlipped ? f.midY : host.bounds.height - f.midY), to: nil)
                clicked = [Double(p.x), Double(p.y), win.contentView?.superview?.hitTest(p)?.className ?? "none"] as [Any]
                click(at: p, up: true)  // a SwiftUI button: the mouse-down and -up to its view
            }
            next(0.8) { [weak self] in
                guard let self, let m = self.model else { return nil }
                var r = self.markBarResult() as? [String: Any] ?? [:]
                r["clicked"] = clicked
                r["editing"] = nul(self.editing)
                r["confirmDelete"] = nul(m.confirmDelete)
                r["undo"] = m.history.undos.count
                r["redo"] = m.history.redos.count
                r["toast"] = nul(m.panelToast.text)
                r["style"] = m.selectedComment.map { [$0.markColor.rawValue, $0.markKind.rawValue] } ?? NSNull()
                return r
            }
        case "dot":
            if rest == "close" { model?.edit.swatches = nil } else if let id = rest.isEmpty ? model?.selectedComment?.id : rest {
                model?.actions.toggleSwatches(id)
            }
            next(0.6) { [weak self] in self?.markBarResult() }
        case "menu", "click", "optclick", "box":
            mouse(verb, rest, next: next)
        default:
            mouse("drag", item, next: next)
        }
    }

    /// A click at a point of the window, as the mouse sends it: the mouse-down to the view under it, found as NSWindow
    /// finds it (NSWindow.sendEvent would spend it on activating the window while the app is in the background). `up`:
    /// the mouse-up to the same view at once, as a list row's SwiftUI gesture needs it (a queued one never reached it).
    private func click(at p: CGPoint, up: Bool = false, in window: NSWindow? = nil) {
        guard let win = window ?? controller?.view?.window else { return }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let target = win.contentView?.superview?.hitTest(p)
        if up {
            target?.mouseDown(with: event(.leftMouseDown))
            target?.mouseUp(with: event(.leftMouseUp))
            return
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        target?.mouseDown(with: event(.leftMouseDown))
    }

    /// A mouse's other button `n` pressed in the window (NSEvent makes it as button 2; its CGEvent takes the number).
    static func sideButton(_ n: Int64, in w: NSWindow) -> NSEvent? {
        guard let cg = NSEvent.mouseEvent(with: .otherMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: 1)?.cgEvent else { return nil }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: n)
        return NSEvent(cgEvent: cg)
    }

    private static func split(_ s: String) -> (String, String) {
        guard let sp = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<sp]), String(s[s.index(after: sp)...]).trimmingCharacters(in: .whitespaces))
    }

    /// `typeslow`'s <cps> and text: the rest of the item, or what is inside its double quotes; nil when <cps> is not a
    /// positive number.
    static func typeslowArguments(_ rest: String) -> (cps: Double, text: String)? {
        let (a, b) = split(rest)
        guard let cps = Double(a), cps.isFinite, cps > 0 else { return nil }
        let quoted = b.count >= 2 && b.hasPrefix("\"") && b.hasSuffix("\"")
        return (cps, quoted ? String(b.dropFirst().dropLast()) : b)
    }

    /// `typeslow`'s pause after each character: 1/cps, ±30% at random from a fixed seed (SplitMix64), so every run of a
    /// script types at the same rhythm.
    static func typingPauses(cps: Double, count: Int, seed: UInt64 = 2027) -> [Double] {
        var s = seed
        return (0..<max(count, 0)).map { _ in
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = (s ^ (s >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let u = Double(z >> 11) / Double(UInt64(1) << 53)  // [0, 1)
            return (1 + 0.3 * (2 * u - 1)) / cps
        }
    }

    /// `ovclick` / `ovopen`'s item: section:<id>@<n>, round:<n>, page:<p>@<n> (p from 1), comment:<id>; else nil.
    static func overviewItem(_ s: String) -> OverviewItem? {
        let (kind, value) = (s.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "",
                             s.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? "")
        let at = value.split(separator: "@").map(String.init)
        switch kind {
        case "section": return at.count == 2 ? Int(at[1]).map { .section(at[0], round: $0) } : nil
        case "round": return Int(value).map { .round($0) }
        case "page": return at.count == 2 ? Int(at[0]).flatMap { p in Int(at[1]).map { .page(round: $0, page: p - 1) } } : nil
        case "comment": return value.isEmpty ? nil : .comment(value)
        case "tag": return value.isEmpty ? nil : .tag(value)
        default: return nil
        }
    }

    /// The picker open now: the new-comment popover's, else the card's, else Tag Comments…'s selected row.
    private var openPicker: TagSelection? {
        if controller?.popover?.isShown == true, let d = controller?.draft { return d.tags }
        return model?.edit.tagSelection ?? model?.tagComments?.selection
    }

    /// The writing tags as the app has them (UX.md §24 debug hooks).
    func tagsResult() -> [String: Any] {
        guard let m = model else { return [:] }
        var r: [String: Any] = ["catalog": m.tags.catalog.tags.map { [$0.id, $0.name, $0.hidden ? "hidden" : "shown", $0.group.rawValue] },
                                "suggest": m.tags.suggest, "store": m.tags.store.url.path, "tagging": nul(m.edit.tagging)]
        if let id = m.panel.expanded, let card = m.panel.cards.first(where: { $0.id == id }) {
            r["card"] = ["id": id, "tags": card.tags.map(\.name), "suggestion": nul(card.suggestion.map { [$0.name, $0.reason] }),
                         "reopenIn": nul(card.reopenIn), "revivedFrom": nul(card.revivedFrom), "word": nul(card.stateWord),
                         "turns": card.turns.map(\.label)] as [String: Any]
        }
        if let sel = openPicker {
            r["picker"] = ["on": sel.on, "accepted": sel.accepted, "suggestions": sel.suggestions.map { [$0.id, $0.reason] },
                           "naming": sel.naming, "message": nul(sel.message),
                           "chips": sel.shown(m.tags.catalog).map(\.name)] as [String: Any]
        }
        if let s = m.tagComments {
            r["sheet"] = ["title": s.title, "summary": s.summary, "listed": s.listed.map(\.id), "selected": nul(s.selected)] as [String: Any]
        }
        if let d = m.overview.data {
            r["overview"] = ["tagged": nul(d.tags?.tagged), "comments": nul(d.tags?.comments),
                             "keyPage": nul(d.keyPage.map { [$0.round, $0.page + 1, $0.chosen == true ? 1 : 0] }),
                             "topics": d.tags.map { t in TopicsTable.make(t, data: d, catalog: m.tags.catalog).rows.map { [$0.name] + $0.counts.map(String.init) + ["open \($0.open)", $0.writtenIn] } } ?? []
                            ] as [String: Any]
        }
        if let p = m.selectedPath { r["chosenKeyPage"] = nul(m.keyPage(of: p).map { [$0.round, $0.page + 1] }) }
        // WA-7: how the suggestions fall on the paper's notes, in numbers only (no note's words)
        if let d = m.overview.data {
            var n = [0, 0, 0], by: [String: Int] = [:], agree = 0, tagged = 0
            for c in d.comments {
                let s = TagSuggester.suggest(note: c.note ?? "", kind: c.kind.flatMap(MarkKind.init(rawValue:)), catalog: m.tags.catalog)
                n[min(s.count, 2)] += 1
                for x in s { by[x.id, default: 0] += 1 }
                if !c.tags.isEmpty { tagged += 1; if s.contains(where: { c.tags.contains($0.id) }) { agree += 1 } }
            }
            r["suggestions"] = ["comments": d.comments.count, "none": n[0], "one": n[1], "two": n[2], "byTag": by,
                                "tagged": tagged, "taggedWithASuggestionOn": agree] as [String: Any]
        }
        if case .student(let k)? = m.hub, let g = m.studentGroups.first(where: { $0.key == k }),
           let t = m.hubModel.stats(for: g.papers.map(\.path))?.tags {
            let titles = Dictionary(g.papers.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
            r["student"] = ["lede": ProfileText.lede(t, catalog: m.tags.catalog, titles: titles), "tagged": t.tagged, "comments": t.comments,
                            "focus": t.focus.map(\.tag), "trend": t.firstDrafts.trend.mapValues { [nul($0.word), nul($0.why)] },
                            "email": ProfileText.email(t.focus, catalog: m.tags.catalog, titles: titles)] as [String: Any]
        }
        return r
    }

    /// The navigation's state (UX.md §21): the level, the history, the overview's place and data, Review's place, the
    /// window's title and subtitle, whether Review's views are hidden and the sidebar's shown.
    private func navResult() -> [String: Any] {
        guard let m = model else { return [:] }
        func item(_ i: OverviewItem?) -> Any {
            switch i {
            case .section(let id, let n)?: return "section:\(id)@\(n)"
            case .round(let n)?: return "round:\(n)"
            case .page(let n, let p)?: return "page:\(p + 1)@\(n)"
            case .comment(let id)?: return "comment:" + id
            case .tag(let id)?: return "tag:" + id
            case nil: return NSNull()
            }
        }
        let o = m.overview
        let status: String = {
            switch o.status {
            case .idle: return "idle"
            case .loading: return "loading"
            case .loaded: return "loaded"
            case .unavailable: return "unavailable"
            case .failed(let e): return "failed: " + e
            }
        }()
        var hidden: Any = NSNull()
        if let v = controller?.view { hidden = PDFController.reviewRoot(of: v).isHiddenOrHasHiddenAncestor }
        let sidebar = sidebarTable().map { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil } ?? false
        // a place: "overview:reef", "review:reef", or a page of the hierarchy, "hub:allStudents"
        func place(_ p: NavPlace) -> String {
            p.hub.map { "hub:" + String(describing: $0) } ?? "\(p.level.rawValue):\((p.paper as NSString?)?.lastPathComponent ?? "-")"
        }
        return ["level": m.level.rawValue, "paper": nul(m.selectedPath), "showsOverview": m.showsOverview,
                "hub": nul(m.hub.map { String(describing: $0) }),
                "back": m.navHistory.back.map(place), "forward": m.navHistory.forward.map(place),
                "canBack": m.canGoBack, "canForward": m.canGoForward,
                "map": ["asTable": o.asTable, "hasKeys": o.hasKeys, "unfold": o.unfold, "folded": o.folded,
                        "parts": o.foldedParts.map(\.rawValue), "shownParts": o.shownParts.map(\.rawValue).sorted(),
                        "foldSetting": m.foldParts,
                        "hover": nul(o.hover.target.map { String(describing: $0) }), "preview": nul(o.hover.comment),
                        "tip": nul(o.hover.tip?.lines), "tipAt": nul(o.hover.tip.map { [$0.at.x, $0.at.y] }),
                        "mapOrigin": [o.hover.mapOrigin.x, o.hover.mapOrigin.y],
                        "panel": nul(o.selection.flatMap { s in o.data.flatMap { OverviewPanel.make(s, data: $0, strip: m.stripRound, student: "") } }
                            .map { ["title": $0.title, "meta": $0.meta, "buttons": $0.buttons.map(\.title)] })] as [String: Any],
                "overview": ["status": status, "paper": nul(o.paper), "selection": item(o.selection), "strip": nul(m.stripRound),
                             "scroll": nul(o.liveScroll.map { ($0 * 10).rounded() / 10 }), "saved": o.savedScroll,
                             "mapTop": o.mapTop, "visible": nul(o.scrollView.map { OverviewModel.visibleHeight($0) }),
                             "rounds": o.data?.rounds.map(\.n) ?? [],
                             "sentence": OverviewText.firstSentence(o.data, student: m.state?.paper.student ?? "",
                                                                    fallback: m.state?.rounds ?? [], errors: m.overviewBuildErrors)] as [String: Any],
                "review": ["round": nul(m.round?.n), "selected": nul(selectedID), "tab": m.tab.rawValue,
                           "pdf": nul(controller?.loadedPath.map { ($0 as NSString).lastPathComponent }),
                           "page": nul(m.pdf.position.page)] as [String: Any],
                // the way back (PLAN §5): each place's PDF step ("p.4 · 2.1 Data", null for a window's place), the
                // place being read, the chip, Back's flash
                "steps": m.navHistory.back.map { nul($0.step ? $0.review.pdf?.label : nil) },
                "forwardSteps": m.navHistory.forward.map { nul($0.step ? $0.review.pdf?.label : nil) },
                "place": nul(m.pdf.currentPlace().map { ["label": $0.label, "page": $0.page, "y": ($0.y * 10).rounded() / 10] as [String: Any] }),
                "chip": nul(m.pdf.backChip.label.map { ["label": $0, "faded": m.pdf.backChip.faded] as [String: Any] }),
                "flash": m.pdf.flashing, "backHelp": nul(m.backLabel), "forwardHelp": nul(m.forwardLabel),
                "toolbar": ["items": nul(window?.toolbar?.items.count), "visible": nul(window?.toolbar?.visibleItems?.count),
                            "nudges": m.toolbarNudges] as [String: Any],
                "title": m.state?.paper.title ?? "", "subtitle": m.windowSubtitle, "reviewHidden": hidden,
                "sidebarShown": sidebar, "contents": m.level == .review, "firstResponder": nul(controller?.view?.window?.firstResponder?.className),
                "pending": m.pendingReview.map { "\($0.target)" } ?? NSNull()]
    }

    /// The map's timings after a click or key at `t0`: the scene's build and the Canvas draw (ms), and from the event to
    /// the end of that draw (`shownMs`, null when the map was not drawn again).
    private static func mapTiming(since t0: TimeInterval) -> [String: Any] {
        ["buildMs": MapTiming.build, "drawMs": MapTiming.draw,
         "shownMs": MapTiming.drawnAt > t0 ? ((MapTiming.drawnAt - t0) * 10_000).rounded() / 10 : NSNull()]
    }

    /// `ovtext`: what the overview shows, in words: the header's first sentence and facts, the map as drawn (each row's
    /// rail, cells with the count drawn or nil when left out, chips, ticks, the "carried" and "unplaced" words, the
    /// readout and the Sage line), the structure labels, the legend's steps, each row's VoiceOver sentence and the
    /// table's rows and totals; and how long the overview's data took to come (`loadMs`).
    private func overviewText() -> [String: Any] {
        guard let m = model, let d = m.overview.data else { return ["data": false] }
        let student = OverviewText.firstName(m.state?.paper.student ?? "")
        let facts = OverviewText.facts(d, rounds: m.state?.rounds ?? [], pages: m.round?.build.pages)
        var out: [String: Any] = [
            "sentence": OverviewText.firstSentence(d, student: m.state?.paper.student ?? "", fallback: m.state?.rounds ?? [],
                                                   errors: m.overviewBuildErrors),
            "facts": [nul(facts.comments), nul(facts.rounds), facts.details.joined(separator: " · ")],
            "speech": d.rounds.map { MapSpeech.row(d, $0, student: student) },
            "loadMs": nul(m.overview.loadMs)]
        if let s = m.overview.hover.scene {
            out["steps"] = s.steps
            out["parts"] = ["foldable": s.plan.foldable.map(\.rawValue), "folded": s.plan.folded.map(\.rawValue),
                            "short": s.plan.short, "pageWidth": (s.plan.k * 10).rounded() / 10,
                            "blocks": s.plan.width.mapValues { ($0 * 10).rounded() / 10 }.reduce(into: [String: Double]()) { $0[$1.key.rawValue] = Double($1.value) },
                            "axis": s.axisParts.map { $0.text.text + $0.link.text }] as [String: Any]
            out["labels"] = s.labels.map(\.text.text)
            out["fold"] = nul(s.fold.map { $0.title.text + " · " + $0.text.text })
            out["rows"] = s.rows.map { r -> [String: Any] in
                ["n": r.n, "title": r.title.text, "dates": r.dates.text, "carried": nul(r.carried?.text),
                 "cells": r.cells.map { [$0.section, $0.count, nul($0.number?.text), nul($0.name?.text), nul($0.fold?.rawValue)] as [Any] },
                 "quiet": r.quiet.map(\.sections),
                 "chips": r.chips.map { "\($0.section) \($0.text.text)" },
                 "ticks": ["asked": r.ticks.filter { !$0.unrequested }.count, "nobody": r.ticks.filter(\.unrequested).count,
                           "toCheck": r.ticks.filter(\.toCheck).count],
                 "unplaced": nul(r.unplacedText?.text), "caption": nul(r.caption?.text), "failed": nul(r.failedText?.text),
                 "end": nul(r.endText?.text), "readout": r.readout.map(\.text), "sage": nul(r.sage?.text)]
            }
        }
        let t = MapTable.make(d, selection: m.overview.selection, student: student)
        out["table"] = ["columns": t.columns.map(\.n),
                        "rows": t.rows.map { r -> [Any] in
                            [r.key, r.cells.map { c in c.absent ?? (c.count > 0 ? "\(c.count)" : "") + (c.toCheck > 0 ? " ○\(c.toCheck)" : "") }, r.once]
                        },
                        "totals": t.totals.map { [$0.label] + $0.values }]
        return out
    }

    /// `ovhover`'s pointer: at the middle of the thing named, through the map's own hover handler (`PaperMapView.hover`),
    /// its tag at once.
    private func overviewHover(_ arg: String) {
        guard let m = model else { return }
        let h = m.overview.hover
        if arg == "off" || arg.isEmpty { return h.leave() }
        guard let scene = h.scene, let d = m.overview.data else { return }
        let student = OverviewText.firstName(m.state?.paper.student ?? "")
        let (kind, value) = Self.split(arg.replacingOccurrences(of: ":", with: " "))
        let at = value.split(separator: "@").map(String.init)
        var p: CGPoint?
        switch kind {
        case "cell":
            if at.count == 2, let n = Int(at[1]), let c = scene.rows.first(where: { $0.n == n })?.cells.first(where: { $0.section == at[0] }) {
                p = CGPoint(x: c.rect.midX, y: c.rect.midY)
            }
        case "round":
            if let n = Int(value), let r = scene.rows.first(where: { $0.n == n }) { p = CGPoint(x: 40, y: r.y + 10) }
        case "edit":
            if at.count == 2, let n = Int(at[1]), let t = scene.rows.first(where: { $0.n == n })?.ticks.first(where: { $0.id == at[0] }) {
                p = CGPoint(x: t.x, y: t.top + 4)
            }
        case "dot":
            if at.count == 2, let n = Int(at[1]) {
                p = scene.hits.first { $0.target == .comment(at[0], round: n) }.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
            }
        case "at":
            let v = value.split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { p = CGPoint(x: v[0], y: v[1]) }
        case "comment":  // a panel's line: its path previewed (no tag: the line's place is the panel's)
            return h.point(at: .zero, key: "line:" + value, comment: value, force: true) { [] }
        default: break
        }
        if let p { PaperMapView.hover(at: p, scene: scene, data: d, student: student, hover: h, force: true) }
    }

    private func waitForOverview(started: TimeInterval, _ done: @escaping () -> Void) {
        if model?.overview.status != .loading || ProcessInfo.processInfo.systemUptime - started > 10 { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitForOverview(started: started, done) }
    }

    private var selectedID: String? {
        switch model?.selection {
        case .comment(let id)?, .change(let id)?: return id
        case nil: return nil
        }
    }

    /// The editor that has the cursor: from the window's first responder, so a field that took focus by itself shows.
    private var editing: String? {
        switch model?.edit.field {
        case .note(let id)?: return "note:" + id
        case .remark(let id)?: return "remark:" + id
        case nil:
            if controller?.popover?.isShown == true { return "popover" }
            guard controller?.view?.window?.firstResponder is NSTextView else { return nil }
            return model?.edit.fieldFocused.map { "field:" + $0 } ?? "text"
        }
    }

    /// The follow-up field's text view in the panel (the only editor on a card to check).
    private func fieldView(in v: NSView?) -> NSTextView? {
        guard let v else { return nil }
        if let tv = v as? InlineTextEditor.EditorTextView { return tv }
        for sub in v.subviews { if let tv = fieldView(in: sub) { return tv } }
        return nil
    }

    /// What the Finish sheet states and shows (UX.md §17).
    private func finishResult() -> Any {
        guard let m = model else { return NSNull() }
        let s = FinishSummary(round: m.round?.n ?? 0, comments: m.state?.comments ?? [], drafts: m.drafts,
                              unrequested: m.toCheck, unread: m.unreadCount)
        let rows = FinishSummary.rows(s.drafts, handled: m.finishPreview.handled)
        let sections = (s.left.isEmpty ? [] : ["Left for you"]) + (rows.isEmpty ? [] : ["Words not sent yet"])
            + ["Goes to the student"]
        return ["shown": m.showFinish, "sections": sections, "left": s.left.map { [$0.item.rawValue, $0.title, $0.count] },
                "goes": s.goes.map { [$0.item.rawValue, $0.title, $0.count] }, "reading": ["current": nul(m.currentParagraph), "flash": controller?.flashing ?? false],
                "followUps": s.followUps, "new": s.new, "toCheck": s.toCheck, "closed": s.closed,
                "drafts": s.drafts.map { [$0.id, $0.text] }, "unrequested": s.unrequested, "unread": nul(s.unread),
                "rows": rows.map { [$0.id, $0.handled.map { $0.sent ? "sent" : "discarded" } ?? "unsent"] },
                "card": nul(m.state.map { Self.cardResult(m.roundStats($0)) }),
                "finished": nul(m.finishPreview.done.map { Self.cardResult($0.stats) }),
                "error": nul(m.finishPreview.error), "round": nul(m.round?.n),
                "roundClosed": m.round?.closed ?? false, "selected": nul(selectedID), "tab": m.tab.rawValue,
                "toast": nul(m.reading.toast),
                "notice": nul(m.notice.map { [$0.text, nul($0.action), nul($0.second)] }),
                "before": nul(m.round?.finishes.flatMap(FinishSummary.finishedBefore))]
    }

    /// A round card's numbers and words (the `summary` and `finishsheet` results).
    static func cardResult(_ s: RoundStats) -> [String: Any] {
        ["round": s.round, "words": s.words, "wrote": nul(s.wroteLine),
         "figures": s.figures.map { [$0.value, nul($0.of), $0.label] as [Any] },
         "tags": s.tags.map { [$0.name, $0.count] as [Any] }, "praise": s.praise, "untagged": s.untagged,
         "marks": s.marks.map { [$0.page, ($0.y * 100).rounded() / 100, $0.column, $0.kind.rawValue] as [Any] },
         "pages": s.pages, "dateLine": s.dateLine, "student": nul(s.studentLine(named: false).map { $0.lead + " · " + $0.rest }),
         "facts": s.facts]
    }

    /// Resume Round N's places and the round shown (UX.md §31).
    private func resumeResult() -> Any {
        guard let m = model else { return NSNull() }
        let r = m.round
        return ["asking": nul(m.confirmResume?.title), "message": nul(m.confirmResume?.message), "button": m.canResumeShown,
                "roundMenu": nul(m.resumable()?.round),
                "paperMenus": m.papers.compactMap { p in m.resumable(p.path).map { [p.path, $0.round] as [Any] } },
                "round": nul(r?.n), "latest": nul(m.latestRound?.n), "roundClosed": r?.closed ?? false,
                "resumable": nul(r?.resumable),
                "finishes": (r?.finishes ?? []).map { ["at": nul($0.at), "final": nul($0.final), "email": nul($0.email)] },
                "level": m.level.rawValue, "tab": m.tab.rawValue, "toast": nul(m.reading.toast), "alert": nul(m.alertMessage)]
    }

    private func foldResult() -> Any {
        model?.tab == .changes ? ["showLinked": model?.changes.showLinked ?? false]
            : ["showStudent": model?.panel.showStudent ?? false, "showClosed": model?.panel.showClosed ?? false]
    }

    /// The papers list: the window's table that is not a panel's, at the left.
    private func sidebarTable() -> NSTableView? {
        var found: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView, !(t is PanelTableView) { found.append(t) }
            v.subviews.forEach(walk)
        }
        if let root = window?.contentView { walk(root) }
        return found.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The app's window: the PDF view's, or (a page of the hierarchy shows no PDF) the window that holds the sidebar.
    private var window: NSWindow? {
        controller?.view?.window ?? NSApp.windows.first { $0.isVisible && $0.title == AppVariant.current.name } ?? NSApp.windows.first { $0.isVisible }
    }

    /// The paper the sidebar's table shows selected, or nil.
    private func listSelected() -> String? {
        guard let m = model, let t = sidebarTable(), t.selectedRow >= 0 else { return nil }
        let rows = m.sidebarRows
        guard rows.indices.contains(t.selectedRow), case .paper(let p) = rows[t.selectedRow] else { return nil }
        return p
    }

    /// The sidebar (UX.md §22): its rows as the list shows them (`rows`, in words, with each paper's badge or sign),
    /// how many the list's table has, what it selects, Your Move's count, the folded students, the Contents and the
    /// section the PDF is in, and the body counts so far.
    private func sidebarResult() -> Any {
        guard let m = model else { return NSNull() }
        let rows = m.sidebarRows
        var visible: Any = NSNull()  // the current section's row is within the sidebar's view
        if let t = sidebarTable(), let i = m.reading.contents.rows.firstIndex(where: { $0.block == m.reading.current.block }),
           let row = rows.firstIndex(of: .contents(i)) {
            visible = row < t.numberOfRows && t.visibleRect.intersects(t.rect(ofRow: row))
        }
        let groups = m.studentGroups
        let words: [String] = rows.map { r in
            switch r {
            case .allStudents: return "All Students"
            case .yourMove: return "Your Move \(m.yourMove.count)"
            case .header(let h): return "header: " + h
            case .student(let k): return "student: " + (groups.first { $0.key == k }?.name ?? k)
            case .paper(let p):
                guard let ref = m.papers.first(where: { $0.path == p }) else { return "paper: ?" }
                let st = m.status(of: ref)
                let trail = st?.badge.map { p == m.selectedPath ? "" : " [\($0)]" } ?? st.map { " (\(String(describing: $0)))" } ?? ""
                return "paper: " + ref.title + trail
            case .contentsHeader: return "header: Contents"
            case .contents(let i): return "contents \(i)"
            }
        }
        let t = sidebarTable()
        return ["rows": words, "tableRows": nul(t?.numberOfRows), "selectedRow": nul(t?.selectedRow), "selection": nul(m.sidebarSelection.map { String(describing: $0) }),
                "yourMove": m.yourMove.count, "folded": m.foldedStudents.sorted(), "currentRowVisible": visible,
                "contents": m.reading.contents.rows.count, "message": nul(m.reading.contents.message),
                "current": nul(m.reading.current.block), "listSelected": nul(listSelected()),
                "students": groups.map { ["name": $0.name, "papers": $0.papers.map(\.title)] as [String: Any] },
                "bodies": ["sidebar": BodyCount.sidebar, "paper": BodyCount.paper, "section": BodyCount.section]] as [String: Any]
    }

    private func waitForBackfill(_ n: Int, then: @escaping () -> Void) {
        if let b = model?.backfill, b.running != nil || !b.queue.isEmpty || n < 5, n < 600 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForBackfill(n + 1, then: then) }
        } else {
            then()
        }
    }

    /// Waits (at most 10 s) until the hierarchy's data is in.
    private func waitForHub(_ n: Int, then: @escaping () -> Void) {
        if let m = model, m.hubModel.status == .loading, n < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForHub(n + 1, then: then) }
        } else {
            then()
        }
    }

    /// A page of the hierarchy (UX.md §22): which, the toolbar's words, the data's status, Your Move (titles in order,
    /// with their status and button), All Students' heading and its detail, the students' groups with their numbers
    /// (the engine's `students`), the scroll, and the sidebar's selection.
    private func hubResult() -> Any {
        guard let m = model else { return NSNull() }
        let moves = m.yourMove
        let (review, failed) = Hierarchy.counts(moves)
        let page: String = {
            switch m.hub {
            case .allStudents?: return "all"
            case .yourMove?: return "move"
            case .student(let k)?: return "student " + k
            case nil: return "none"
            }
        }()
        let status: String = {
            switch m.hubModel.status {
            case .idle: return "idle"
            case .loading: return "loading"
            case .loaded: return "loaded"
            case .failed(let e): return "failed: " + e
            }
        }()
        let students = m.studentGroups.map { g -> [String: Any] in
            let st = m.hubModel.stats(for: g.papers.map(\.path))
            return ["name": g.name, "papers": g.papers.map(\.title), "rounds": nul(st?.rounds), "comments": nul(st?.comments),
                    "land": st?.land.map { l in zip(l.columns.map(\.title), l.total).map { "\($0.0) \($0.1)" } } ?? [],
                    "trips": (st?.time ?? []).map { "\($0.round)\($0.open ? " open" : "") you \($0.you ?? -1) student \($0.student ?? -1)" },
                    "closed": st?.closed.map { $0.total.values } ?? []]
        }
        return ["page": page, "status": status, "papers": m.papers.map(\.path), "args": CommandLine.arguments.count, "data": m.hubModel.data.count, "errors": m.hubModel.errors.count,
                "waits": HubText.waits(moves.count), "detail": HubText.waitsDetail(review: review, failed: failed),
                "yourMove": moves.map { "\($0.paper.title) · \(m.statusText($0.paper))" }, "sidebarCount": m.yourMove.count,
                "students": students, "scroll": nul(m.hubModel.liveScroll), "selection": nul(m.sidebarSelection.map { String(describing: $0) }),
                "paper": nul(m.selectedPath), "level": m.level.rawValue, "canBack": m.canGoBack,
                "loadMs": nul(m.hubModel.loadMs)]
    }

    /// Focus (POLISH §4.3, §7): whether it is on, the sidebar shown, the panel and its width, what its list shows and
    /// whether the tabs are there, the status line, the PDF view's width and scale, and the body counts so far.
    private func focusResult() -> [String: Any] {
        guard let m = model, let c = controller, let v = c.view else { return [:] }
        let scroller = m.tab == .changes ? m.changes.scroller : m.panel.scroller
        let panel = scroller.scrollView?.window != nil
        let sidebar = sidebarTable().map { $0.window != nil && $0.visibleRect.width > 1 } ?? false
        let tabs = PanelTabs.shown > 0  // the panel's tabs in the window
        return ["focus": m.focus, "sidebar": sidebar, "panel": panel, "sidebarShown": m.sidebarShown,
                "panelWidth": Double(scroller.scrollView?.frame.width ?? 0), "rows": scroller.table?.listed ?? [],
                "panelMax": nul(m.focusPanelWidth.map(Double.init)), "panelItem": nul(c.panelWidth.map(Double.init)),
                "tabs": tabs, "status": nul(m.reading.status.line?.text), "selected": nul(selectedID),
                "pdf": ["width": Double(v.bounds.width), "scale": Double(v.scaleFactor), "auto": v.autoScales,
                        "fit": Double(v.scaleFactorForSizeToFit),
                        "third": c.pointAtThird().map { [$0.page, $0.x, $0.y] as [Any] } ?? []] as [String: Any],
                "bodies": BodyCount.snapshot]
    }

    /// The Jump panel (POLISH §3 row 12): its query and groups, the highlighted row, and who has the keys.
    private func jumpResult() -> Any {
        guard let m = model else { return NSNull() }
        return ["shown": m.jump.shown, "query": m.jump.query, "highlighted": m.jump.highlighted,
                "firstResponder": keyTarget?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull(),
                "groups": m.jump.groups.map { g in [g.title, g.rows.map { [$0.lead, $0.title, $0.detail, $0.trailing] }] as [Any] }]
    }

    /// The find's result once its search is in (at most 5 s), and the reveal's scroll and the floating toolbar have
    /// settled (`wait`, then 0.5 s).
    private func afterFind(_ next: @escaping (Double, @escaping () -> Any?) -> Void, wait: Double) {
        func poll(_ left: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                if self?.model?.pdf.find.isSearching == true, left > 0 { return poll(left - 1) }
                next(0.5) { [weak self] in self?.findResult() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { poll(100) }
    }

    private func findResult() -> Any {
        guard let m = model else { return NSNull() }
        let f = m.pdf.find, v = controller?.view
        let sel = v?.currentSelection, page = sel?.pages.first
        let visible = page.map { p in v.map { $0.bounds.intersects($0.convert(sel?.bounds(for: p) ?? .zero, from: p)) } ?? false } ?? false
        return ["query": f.query, "count": nul(f.count), "index": nul(f.index), "counter": f.counter, "searching": f.isSearching,
                "highlighted": f.highlighted.count, "inShownDocument": f.highlighted.inShownDocument,
                "selection": nul(sel?.string), "selectionPage": nul(page.flatMap { v?.document?.index(for: $0) }),
                "visible": visible, "ring": f.ringShown, "toolbar": controller?.toolbarShown == true,
                "firstResponder": keyTarget?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull(),
                "field": nul(f.field?.stringValue)]
    }

    private func cardResult() -> Any {
        ["selected": nul(selectedID), "editing": nul(editing), "reanchor": nul(model?.toolbar.reanchor)]
    }

    private func markBarResult() -> Any {
        guard let c = controller, let model else { return [:] }
        let b = c.markBar
        var r: [String: Any] = ["shown": c.markBarShown, "id": nul(c.markBarID), "color": b.color.rawValue, "kind": b.kind.rawValue,
                                "kinds": b.kinds.map(\.rawValue), "selected": nul(selectedID), "toolbar": c.toolbarShown,
                                "swatches": nul(model.edit.swatches)]
        if let f = c.markBarView?.frame, c.markBarShown { r["frame"] = [f.minX, f.minY, f.width, f.height].map(Double.init) }
        if let id = c.markBarID, let v = c.view, let m = c.debugMark(id) {
            r["lines"] = m.lines.map { let f = v.convert($0, from: m.page); return [f.minX, f.minY, f.width, f.height].map(Double.init) }
        }
        return r
    }

    private func styleResult() -> Any {
        if let d = controller?.draft, controller?.popover?.isShown == true {
            return ["color": d.color.rawValue, "kind": d.kind.rawValue, "target": "editor"]
        }
        if controller?.toolbarShown == true || model?.hasPDFSelection == true || model?.toolbar.hasBox == true {
            return ["color": model?.toolbar.color.rawValue ?? "", "kind": model?.toolbar.kind.rawValue ?? "", "target": "toolbar"]
        }
        let c = model?.selectedComment
        return ["color": nul(c?.markColor.rawValue), "kind": nul(c?.kind), "target": "card"]
    }

    private func style(_ verb: String, _ name: String) {
        guard let model else { return }
        let color = MarkColor(rawValue: name), kind = MarkKind(rawValue: name)
        if let d = controller?.draft, controller?.popover?.isShown == true {
            if let color { d.color = color }
            if let kind, d.mode == .text { d.kind = kind }
        } else if controller?.toolbarShown == true || model.hasPDFSelection || model.toolbar.hasBox {
            if let color { model.toolbar.setColor(color) }
            if let kind { model.toolbar.setKind(kind) }
        } else if let id = model.selectedComment?.id {
            model.setStyle(id, color: verb == "swatch" ? color : nil, kind: verb == "kind" ? kind : nil)
        }
    }

    // MARK: Keys

    /// The window keys go to: the new-comment popover while it is shown, else the main window.
    private var keyTarget: NSWindow? {
        if let w = controller?.popover?.contentViewController?.view.window, controller?.popover?.isShown == true { return w }
        if let sheet = controller?.view?.window?.attachedSheet { return sheet }  // an alert (Delete…?)
        return controller?.view?.window
    }

    private func textResponder() -> NSTextView? { keyTarget?.firstResponder as? NSTextView }

    /// `typeslow`: each character inserted as `type` inserts its text, on a timeline of the pauses from the first one (so
    /// the time an insert takes never adds up); `done` a pause after the last, with the characters a text field took and
    /// the first and last one's times.
    private func typeSlowly(_ chars: [Character], _ pauses: [Double], done: @escaping (Int, Double, Double) -> Void) {
        let t0 = DispatchTime.now()
        var at = 0.0, typed = 0, first: Double?, last: Double?
        for (k, c) in chars.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: t0 + at) { [weak self] in
                let t = ProcessInfo.processInfo.systemUptime
                if let r = self?.textResponder() {
                    r.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
                    typed += 1
                }
                first = first ?? t
                last = t
            }
            at += pauses[k]
        }
        DispatchQueue.main.asyncAfter(deadline: t0 + at) {
            let now = ProcessInfo.processInfo.systemUptime
            done(typed, first ?? now, last ?? now)
        }
    }

    /// Sends a key as the app would get it: to an editor that has focus, else through the keyboard map (§9).
    private func key(_ name: String) -> Bool {
        guard let win = keyTarget else { return false }
        var mods: NSEvent.ModifierFlags = []
        var n = ["escape": "esc", "backspace": "delete"][name] ?? name
        if n.hasPrefix("cmd-") { mods.insert(.command); n = String(n.dropFirst(4)) }
        if n.hasPrefix("shift-") { mods.insert(.shift); n = String(n.dropFirst(6)).uppercased() }
        let codes: [String: (UInt16, String)] = ["return": (36, "\r"), "esc": (53, "\u{1b}"), "delete": (51, "\u{7f}"),
                                                 "z": (6, "z"), "Z": (6, "Z"),
                                                 "up": (126, String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)),
                                                 "down": (125, String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)),
                                                 "left": (123, String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)),
                                                 "right": (124, String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))]
        let (code, chars) = codes[n] ?? (0, n)
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return false }
        if win !== controller?.view?.window {
            return win.performKeyEquivalent(with: e) || { win.sendEvent(e); return true }()
        }
        if let t = win.firstResponder as? NSTextView, !AppModel.routesKeys(firstResponder: t) {
            t.keyDown(with: e)
            return true
        }
        return model?.performKey(e) ?? false
    }

    // MARK: Mouse

    /// The pointer of `hover`, in window coordinates (nil: off the list), and whether its window counts as key: a
    /// background run's window never is, so the comment list reads this pointer instead of the real one.
    private var pointer: (at: NSPoint?, key: Bool) = (nil, true)

    /// `hover <id>|off|away|resignkey|becomekey|resignactive`, or nothing: the comment list's pointer, simulated.
    private func hover(_ arg: String, next: @escaping (Double, @escaping () -> Any?) -> Void) {
        guard let t = model?.panel.scroller.table else { return next(0) { ["error": "no comment list"] } }
        t.pointerLocation = { [weak self] in self.flatMap { $0.pointer.key ? $0.pointer.at : nil } }
        let window = controller?.view?.window
        func result(_ id: String? = nil) -> Any? {
            // `hit`: the view a click at the pointer would reach (a row's hosting view, the card's, a header's)
            let hit = pointer.at.flatMap { window?.contentView?.superview?.hitTest($0) }
            var r: [String: Any] = ["hovered": t.hoveredRows, "hit": nul(hit.map { String(describing: type(of: $0)) })]
            if let id, let look = t.look(id) { r.merge(["id": id, "dimmed": look.dimmed, "quiet": look.quiet]) { a, _ in a } }
            return r
        }
        switch arg {
        case "":
            next(0.05) { result() }
        case "off":  // it leaves the list: an exit
            pointer.at = nil
            t.pointerMoved(to: nil)
            next(0.2) { result() }
        case "away":  // it leaves the list with no exit (a window over the list, a fast move)
            pointer.at = nil
            next(0.2) { result() }
        case "resignkey", "becomekey":  // the window's notification, as AppKit posts it
            pointer.key = arg == "becomekey"
            NotificationCenter.default.post(name: pointer.key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
                                            object: window)
            next(0.2) { result() }
        case "resignactive":  // the app's notification; its window is no longer key either
            pointer.key = false
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            next(0.2) { result() }
        default:
            // onto the row's middle, scrolled into view first as a person would: a move there (the row it was on gets
            // no exit of its own); once a scroll settles the list finds the row under it itself
            guard let f = t.rowFrame(arg) else { return next(0) { ["error": "no row \(arg)"] } }
            pointer.at = NSPoint(x: f.midX, y: f.midY)
            t.pointerMoved(to: pointer.at)
            next(PanelTable.settleDelay + 0.15) { result(arg) }
        }
    }

    /// `link`: the link's words and target page, then the nav result 0.6 s after a click on its middle, as the mouse
    /// sends it (the page is scrolled to it first when it is not in view, as `click` does).
    private func link(_ spec: String, next: @escaping (Double, @escaping () -> Any?) -> Void) {
        let a = spec.split(separator: " ").compactMap { Int($0) }
        guard a.count == 2, let v = controller?.view, let page = v.document?.page(at: a[0]) else { return next(0) { "bad item: link \(spec)" } }
        let links = page.annotations.filter { ReviewPDFView.goTo($0) != nil }
        guard a[1] >= 0, a[1] < links.count, let target = ReviewPDFView.goTo(links[a[1]])?.page, let doc = v.document else {
            return next(0) { "no link \(spec)" }
        }
        let l = links[a[1]], cb = page.bounds(for: .cropBox)
        let info: [String: Any] = ["words": PDFMenus.collapsed(page.selection(for: l.bounds)?.string ?? ""), "to": doc.index(for: target)]
        mouse("click", "\(a[0]),\(l.bounds.midX - cb.minX),\(cb.maxY - l.bounds.midY)") { delay, _ in
            next(delay) { [weak self] in
                ["link": info, "nav": self?.navResult() ?? [:], "preview": self?.controller?.previewState()["preview"] ?? NSNull()] as [String: Any]
            }
        }
    }

    private func preview(_ spec: String, next: @escaping (Double, @escaping () -> Any?) -> Void) {
        guard let c = controller, let v = c.view, let win = v.window, let doc = v.document else { return next(0) { "no PDF" } }
        let a = spec.split(separator: " ").map(String.init)
        var copied = false
        let result = { [weak self] () -> Any? in
            var r = self?.controller?.previewState() ?? [:]
            r["nav"] = self?.navResult() ?? [:]
            if copied { r["clipboard"] = nul(AppModel.clipboard.string(forType: .string)) }
            return r
        }
        /// A click at a contract point, `n` the click count, as the mouse sends it.
        func click(_ page: Int, _ x: Double, _ y: Double, count n: Int) {
            guard let pg = doc.page(at: page) else { return }
            let cb = pg.bounds(for: .cropBox), w = v.convert(v.convert(CGPoint(x: cb.minX + x, y: cb.maxY - y), from: pg), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            win.contentView?.superview?.hitTest(w)?.mouseDown(with: event(.leftMouseDown))
        }
        let shown = c.shownPreview
        switch a.first ?? "" {
        case "":
            break
        case "again", "double":
            guard let p = c.previewPoint else { return next(0) { "no preview" } }
            click(p.page, p.x, p.y, count: a[0] == "double" ? 2 : 1)
        case "go":
            c.goToTarget(shown?.target ?? -1)
        case "picture":
            guard let i = a.dropFirst().first.flatMap({ Int($0) }), let e = shown?.entries, i >= 0, i < e.count else {
                return next(0) { "bad item: preview \(spec)" }
            }
            c.goToTarget(e[i].id)
        case "pin":
            c.pinPreview()
        case "drag":
            let d = a.dropFirst().compactMap { Double($0) }
            guard d.count == 2 else { return next(0) { "bad item: preview \(spec)" } }
            c.dragPreview(CGSize(width: d[0] / 2, height: d[1] / 2), ended: false)
            c.dragPreview(CGSize(width: d[0], height: d[1]), ended: true)
        case "cited":
            guard let i = a.dropFirst().first.flatMap({ Int($0) }), let pages = shown?.cited, i >= 0, i < pages.count else {
                return next(0) { "bad item: preview \(spec)" }
            }
            c.goCited(pages[i])
        case "copy":
            c.copyReference()
            copied = true
        case "scroll":
            if let clip = v.documentView?.enclosingScrollView?.contentView {
                var o = clip.bounds.origin
                o.y += clip.isFlipped ? 40 : -40
                clip.scroll(to: o)
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        default:
            let d = a.compactMap { Int($0) }
            guard d.count == 2, let t = c.links else { return next(0) { "bad item: preview \(spec)" } }
            let ls = t.onPage(d[0])
            guard d[1] >= 0, d[1] < ls.count, let r = t.links[ls.lowerBound + d[1]].rects.first else {
                return next(0) { "no link \(spec)" }
            }
            // into view first, as a person would scroll to it
            if let pg = doc.page(at: d[0]) {
                let cb = pg.bounds(for: .cropBox), at = CGRect(x: cb.minX + r[0], y: cb.maxY - r[3], width: r[2] - r[0], height: r[3] - r[1])
                if !v.bounds.insetBy(dx: 0, dy: 60).contains(v.convert(at, from: pg)) {
                    v.go(to: PDFDestination(page: pg, at: CGPoint(x: cb.minX, y: min(at.maxY + 200, cb.maxY))))
                }
            }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                click(d[0], (r[0] + r[2]) / 2, (r[1] + r[3]) / 2, count: 1)
                next(0.6, result)
            }
        }
        next(0.6, result)
    }

    private func mouse(_ verb: String, _ spec: String, next: @escaping (Double, @escaping () -> Any?) -> Void) {
        guard let c = controller, let v = c.view, let win = v.window, let doc = v.document else { return next(0) { "no PDF" } }
        let (args, title) = verb == "menu" ? Self.split(spec) : (spec, "")
        let d = args.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let need = verb == "box" || verb == "drag" ? 5 : 3  // click, optclick, menu, hover: one point
        guard d.count >= need, let page = doc.page(at: Int(d[0])) else { return next(0) { "bad item: \(verb) \(args)" } }
        let cb = page.bounds(for: .cropBox)
        let p1 = CGPoint(x: cb.minX + d[1], y: cb.maxY - d[2])
        let p2 = need == 5 ? CGPoint(x: cb.minX + d[3], y: cb.maxY - d[4]) : p1
        let clicks = verb == "drag" && d.count > 5 ? max(Int(d[5]), 1) : 1
        // Bring the point into view when it is not, as a person would scroll to it first.
        let inView = v.convert(CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y)), from: page)
        let moved = !v.bounds.insetBy(dx: 0, dy: 20).contains(inView)
        if moved { v.go(to: PDFDestination(page: page, at: CGPoint(x: cb.minX, y: min(max(p1.y, p2.y) + 60, cb.maxY)))) }
        let offset = model?.panel.scroller.dump["offset"] as? Double
        DispatchQueue.main.asyncAfter(deadline: .now() + (moved ? 0.4 : 0.05)) { [weak self] in
            let w1 = v.convert(v.convert(p1, from: page), to: nil), w2 = v.convert(v.convert(p2, from: page), to: nil)
            let mods: NSEvent.ModifierFlags = verb == "optclick" || verb == "box" ? .option : []
            func event(_ type: NSEvent.EventType, _ p: CGPoint, _ n: Int = 1) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)!
            }
            if verb == "hover" {
                v.mouseMoved(with: event(.mouseMoved, w1))
                return next(0.2) { ["tooltip": nul(v.toolTip), "cursor": NSCursor.current == NSCursor.pointingHand ? "pointingHand" : "other"] }
            }
            if verb == "menu" {
                let menu = v.menu(for: event(.rightMouseDown, w1))
                let items = menu.map(Self.describe) ?? []
                let selected = self?.selectedID, selection = v.currentSelection?.string
                // a title picks that item (in the menu or a submenu, as `cardmenu`)
                let picked = !title.isEmpty && menu.map { CardMenus.perform(title, in: $0) } == true
                return next(0.4) { [weak self] in
                    ["menu": items, "picked": picked, "selected": nul(selected), "selection": nul(selection),
                     "editor": self?.controller?.popover?.isShown == true,
                     "editorMode": nul(self?.controller?.draft.map { String(describing: $0.mode) }),
                     "after": ["selected": nul(self?.selectedID), "selection": nul(v.currentSelection?.string),
                               "page": nul(self?.controller?.shownPage), "find": nul(self?.model?.pdf.find.query),
                               "boxArmed": self?.model?.toolbar.boxArmed ?? false] as [String: Any]]
                }
            }
            // The mouse-down goes to the view under the point, found as NSWindow finds it (NSWindow.sendEvent would
            // spend it on activating the window while the app is in the background). PDFView tracks the drag inside
            // mouseDown, so the drags and the mouse-up are queued first.
            let target = win.contentView?.superview?.hitTest(w1)
            if clicks > 1 {
                for n in 1...clicks {
                    NSApp.postEvent(event(.leftMouseUp, w1, n), atStart: false)
                    target?.mouseDown(with: event(.leftMouseDown, w1, n))
                }
            } else {
                if p1 != p2 {
                    for i in 1...6 {
                        let t = CGFloat(i) / 6
                        NSApp.postEvent(event(.leftMouseDragged, CGPoint(x: w1.x + (w2.x - w1.x) * t, y: w1.y + (w2.y - w1.y) * t)),
                                        atStart: false)
                    }
                }
                NSApp.postEvent(event(.leftMouseUp, w2), atStart: false)
                target?.mouseDown(with: event(.leftMouseDown, w1))
            }
            guard let self else { return }
            let flash = self.controller?.flashing ?? false
            switch verb {
            case "click":
                let hit = self.controller?.lastClick, bar = self.controller?.lastBar
                next(0.6) { [weak self] in
                    let after = self?.model?.panel.scroller.dump["offset"] as? Double
                    var r: [String: Any] = ["click": nul(hit), "expanded": nul(self?.model?.panel.expanded), "selected": nul(self?.selectedID),
                            "tab": self?.model?.tab.rawValue ?? "", "panelScrolled": offset.map { o in after.map { abs($0 - o) > 0.5 } ?? false } ?? false,
                            "flash": flash, "bar": nul(bar)]
                    if bar != nil, let d = self?.readingResult() { r.merge(d) { a, _ in a } }
                    return r
                }
            case "optclick":
                next(0.5) { [weak self] in ["editor": self?.controller?.popover?.isShown == true] }
            case "box":
                next(0.4) { [weak self] in
                    guard let b = self?.controller?.pendingBox else { return ["box": NSNull(), "toolbar": self?.controller?.toolbarShown ?? false] }
                    return ["box": Geometry.contractRect(b.rect, cropBox: b.page.bounds(for: .cropBox)),
                            "toolbar": self?.controller?.toolbarShown ?? false]
                }
            default:
                next(0.4) { v.currentSelection?.string ?? "" }
            }
        }
    }

    /// A menu's items for `menu`: a title ("✓ " before one that is on), "—" for a separator, [title, [items]] for a
    /// submenu.
    private static func describe(_ m: NSMenu) -> [Any] {
        m.items.map { i -> Any in
            if i.isSeparatorItem { return "—" }
            let title = (i.state == .on ? "✓ " : "") + i.title
            return i.submenu.map { [title, describe($0)] as [Any] } ?? title
        }
    }

    // MARK: Output

    private var settingsWindow: NSWindow?

    /// The Settings window's tabs in a titled window ordered behind every other one, as the Settings scene shows them
    /// (a tab view controller with its tabs in the toolbar, each tab's form in a hosting view), which a test run cannot
    /// open without bringing it to the front (CLAUDE.md).
    private static func showSettings(_ model: AppModel, tab: SettingsView.Tab, close old: NSWindow?) -> NSWindow {
        old?.close()
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for t in SettingsView.Tab.allCases {
            let host = NSHostingController(rootView: SettingsView.content(t, model: model))
            host.sizingOptions = [.preferredContentSize]  // each tab's own size, as the Settings scene sizes it
            let item = NSTabViewItem(viewController: host)
            item.label = t.title
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = SettingsView.Tab.allCases.firstIndex(of: tab) ?? 0
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.title = tab.title
        w.isReleasedWhenClosed = false
        w.orderBack(nil)
        return w
    }

    /// The app icon shown now and where it shows (UX.md §26).
    private static func iconResult() -> [String: Any] {
        let icons = AppIconModel.shared
        let alert = NSAlert()
        alert.messageText = AppVariant.current.name
        alert.layout()
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let alertIcon = alert.window.contentView.map(views)?.compactMap { ($0 as? NSImageView)?.image }.first
        let shown = icons.shown
        return ["style": icons.style.rawValue, "system": icons.systemDark ? "dark" : "light",
                "resource": icons.resource, "dock": looksSame(NSApp.applicationIconImage, shown),
                "named": looksSame(NSImage(named: NSImage.applicationIconName), shown), "alert": looksSame(alertIcon, shown),
                "about": looksSame(icons.aboutOptions[.applicationIcon] as? NSImage, shown),
                "distinct": !looksSame(icons.shown(dark: !icons.dark), shown), "remembers": icons.remembers]
    }

    /// Two images drawn at 64 × 64 the same, give or take a little (AppKit keeps the Dock's image as one 1024 px
    /// snapshot, the .icns has a drawing for each size).
    private static func looksSame(_ a: NSImage?, _ b: NSImage?) -> Bool {
        guard let a, let b else { return false }
        func pixels(_ i: NSImage) -> [UInt8] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 256, bitsPerPixel: 32) else { return [] }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            i.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
            NSGraphicsContext.restoreGraphicsState()
            return rep.bitmapData.map { Array(UnsafeBufferPointer(start: $0, count: 64 * 64 * 4)) } ?? []
        }
        let x = pixels(a), y = pixels(b)
        guard !x.isEmpty, x.count == y.count else { return false }
        // the share of pixels with a channel more than 64 apart: the same icon (the Dock's snapshot) 4% or less, two
        // forms 14% or more (the mean said the dark vermilion Round and Round ¶ were the same: 7.4, a resampling's 3–8)
        let differ = stride(from: 0, to: x.count, by: 4).filter { p in (0..<4).contains { abs(Int(x[p + $0]) - Int(y[p + $0])) > 64 } }
        return Double(differ.count) / Double(x.count / 4) <= 0.08
    }

    /// What the reading keys see and did (UX.md §18); `marks`: Settings' reading marks on.
    private func readingResult() -> [String: Any] {
        guard let m = model, let c = controller else { return [:] }
        var pdf: [String: Any] = [:]
        if let v = c.view, let doc = v.document {
            pdf["page"] = v.currentPage.map { doc.index(for: $0) } ?? NSNull()
            pdf["visible"] = v.visiblePages.map { doc.index(for: $0) }
        }
        let shown = m.currentParagraph.flatMap { m.paragraph($0) }.map { c.isFullyVisible(parts: $0.parts) }
        return ["round": nul(m.round?.n), "marks": m.readingMarksOn, "tracked": m.readingTracked, "current": nul(m.currentParagraph),
                "currentFullyVisible": nul(shown),
                "unread": nul(m.unreadCount), "bars": c.readingBars.map { ([$0.block, $0.page] as [Any]) + $0.rect.map { $0 as Any } },
                "visible": c.visibleBlocks(m.paragraphs), "toast": nul(m.reading.toast), "flash": c.flashing,
                "outlineCurrent": nul(m.reading.current.block), "status": nul(m.reading.status.line?.text),
                "statusShort": nul(m.reading.status.line?.short), "statusButtons": m.reading.status.line?.actions ?? false,
                "pdf": pdf]
    }

    /// The expanded card's thread (UX.md §3): its folded line and each section's label, tags, text with [[marked]] and
    /// __changed__ words and ‸ carets, and crop; then its turns, which hold what was said.
    private func thread() -> Any {
        guard let m = model, let id = m.panel.expanded, let card = m.panel.all.first(where: { $0.id == id }) else {
            return NSNull()
        }
        func marked(_ t: BlockText) -> String {
            var out = ""
            let s = Array(t.text.unicodeScalars)
            for i in 0...s.count {
                if t.carets.contains(i) { out += "‸" }
                for r in t.changed where r.upperBound == i { out += "__" }
                for r in t.marks where r.upperBound == i { out += "]]" }
                for r in t.marks where r.lowerBound == i { out += "[[" }
                for r in t.changed where r.lowerBound == i { out += "__" }
                if i < s.count { out.unicodeScalars.append(s[i]) }
            }
            return out
        }
        return ["id": id, "status": card.status.word(open: card.open), "row": nul(card.stateWord), "fold": nul(card.fold?.label),
                "sections": card.thread.map { s -> [String: Any] in
                    ["label": "R\(s.round) · " + s.event + (s.page != nil && s.page != card.page ? " · p.\(s.page! + 1)" : ""),
                     "rounds": s.rounds, "tags": s.tags, "edits": s.edits, "uncertain": s.uncertain, "revised": s.revised,
                     "kind": "\(s.kind)", "text": marked(s.full), "trimmed": s.short != nil,
                     "crop": nul(s.crop.map { "R\($0.round) p.\($0.page + 1)" + ($0.faint ? " faint" : "") + ($0.deletion ? " deletion" : "") + ($0.look == .ink ? " ink" : "") })]
                }, "studentNote": nul(card.studentNote),
                "turns": card.turns.map { t -> [String: Any] in
                    ["label": t.label, "dot": "\(t.dot)", "date": nul(t.date), "link": nul(t.reveal),
                     "section": nul(t.section), "uncertain": t.uncertain,
                     "words": nul(t.words.map { w in w.clamp.map { $0.shown + " [+\($0.more)]" } ?? w.text }),
                     "place": nul(t.words?.place?.short ?? t.bare.map { "bare " + $0.short }),
                     "elsewhere": t.elsewhere]
                },
                "attachments": card.attachments.map { "\($0.id) \($0.kind.word) \($0.place) p.\(($0.page ?? -1) + 1)" }]
                as [String: Any]
    }

    private func dump() -> Any {
        guard let model, let c = controller else { return [:] }
        var tb: [String: Any] = ["shown": c.toolbarShown, "color": model.toolbar.color.rawValue, "kind": model.toolbar.kind.rawValue,
                                 "markBar": c.markBarShown ? nul(c.markBarID) : NSNull()]
        if let f = c.toolbarView?.frame, c.toolbarShown { tb["frame"] = [f.minX, f.minY, f.width, f.height].map(Double.init) }
        var pdf: [String: Any] = [:]
        if let v = c.view, let doc = v.document {
            pdf["page"] = v.currentPage.map { doc.index(for: $0) } ?? NSNull()
            pdf["visible"] = v.visiblePages.map { doc.index(for: $0) }
            pdf["scale"] = Double(v.scaleFactor)
            pdf["selectedMarks"] = c.selectedMarks
            pdf["status"] = nul(c.position.page)  // the status line's page (0-based)
        }
        var d: [String: Any] = [
            "selected": nul(selectedID), "expanded": nul(model.panel.expanded), "editing": nul(editing),
            "editText": model.edit.text, "escArmed": model.edit.escArmed, "saving": model.edit.saving, "tab": model.tab.rawValue,
            "draft": model.edit.draft, "drafts": model.drafts.keys.sorted(), "focusRequest": nul(model.edit.focusRequest),
            "choice": model.edit.choice.map { ["id": $0.id, "verdict": $0.verdict, "text": $0.text, "sent": $0.sent] } ?? NSNull(),
            "verdict": nul(model.selectedComment?.verdict), "verdictNote": nul(model.selectedComment?.verdictNote),
            "undo": model.history.undos.count, "redo": model.history.redos.count, "toast": nul(model.panelToast.text),
            "toastPlace": ["below": nul(model.actions.toastPlace.below.map(Double.init)), "bottom": Double(model.actions.toastPlace.bottom)],
            "toolbar": tb, "reanchor": nul(model.toolbar.reanchor), "reanchorError": nul(model.toolbar.reanchorError),
            "panel": model.panel.scroller.dump, "pdf": pdf, "popover": c.popover?.isShown == true,
            "boxArmed": model.toolbar.boxArmed, "subtitle": model.windowSubtitle, "roundLabel": model.roundLabel]
        if let b = c.pendingBox { d["pendingBox"] = Geometry.contractRect(b.rect, cropBox: b.page.bounds(for: .cropBox)) }
        if let w = c.view?.window {
            d["window"] = ["frame": [w.frame.width, w.frame.height].map(Double.init),
                           "minSize": [w.minSize.width, w.minSize.height].map(Double.init),
                           "contentMinSize": [w.contentMinSize.width, w.contentMinSize.height].map(Double.init)]
        }
        if let sv = model.panel.scroller.scrollView { d["panelWidth"] = Double(sv.frame.width) }
        d["firstResponder"] = keyTarget?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull()
        return d
    }

    private func finish() {
        let text = results.map { r -> String in
            let data = (try? JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        if let out { try? text.write(toFile: out, atomically: true, encoding: .utf8) } else { FileHandle.standardError.write(Data(text.utf8)) }
        results = []
        if quit { NSApp.terminate(nil) }
    }
}

/// A JSON value for an optional: null when nil.
private func nul(_ v: Any?) -> Any { v ?? NSNull() }
