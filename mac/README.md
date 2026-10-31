# Paperole Mac app

The review app (SwiftUI, macOS 14+; M1 plus the M2a review screen of `UX.md`). It shows the round's build PDF with comment and change marks, lets you
comment on selected text and give verdicts, and finishes rounds. All work is done by the engine in `../engine`,
which the app starts as `python -m paperole.cli rpc` and talks to over JSON lines (`../engine/CONTRACT.md`).
The app never writes a PDF or `ledger.json` itself.

## Build

Needs Xcode 16 (Swift 6 toolchain) and the engine's virtualenv (see `../engine/README.md`).

    ./build_app.sh        # Paperole Dev: optimised build, wrapped and ad-hoc signed as "build/Paperole Dev.app"
    ./release.sh          # the official Paperole, installed as /Applications/Paperole.app (below)
    swift test            # unit tests (geometry, selection, state decoding, card threads, word diff, mark hits,
                          # scroll decisions, key routing, answers and drafts, groups, the Finish sheet, palette);
                          # a fixture run keeps its drafts in a temporary folder

## Dev and official app

Two apps from the same code (`UX.md` §29). Which one runs is decided by the bundle id alone: only
`com.paperole.app` is the official app; `swift test`, `swift run` and any other bundle are Dev.
The app was called PaperCollab until 2026-10-27 (ids `com.papercollab.app[.dev]`, folders `PaperCollab[ Dev]`,
`~/PaperCollab Dev Reviews`). Each app's first real launch under the new name moves its data to the places below
(`Sources/Paperole/Migration.swift`, `UX.md` §34): only `/Applications/Paperole.app` and the main checkout's
`build/Paperole Dev.app`, opened without arguments, never a test run or another bundle. The old bundles
(`build/PaperCollab Dev.app`, `/Applications/PaperCollab.app`) are never removed by the scripts.

| | Paperole Dev | Paperole |
|---|---|---|
| For | tests and experiments | real reviews |
| Made by | `./build_app.sh` | `./release.sh` only |
| Bundle | `build/Paperole Dev.app` | `/Applications/Paperole.app` |
| Bundle id, defaults domain | `com.paperole.app.dev` | `com.paperole.app` |
| Data (papers.json, tags.json, drafts) | `~/Library/Application Support/Paperole Dev/` | `~/Library/Application Support/Paperole/` |
| Caches (page thumbnails) | `~/Library/Caches/Paperole Dev/` | `~/Library/Caches/Paperole/` |
| New review folders (default) | `~/Paperole Dev Reviews` | `~/Reviews` |
| Executable | `Contents/MacOS/PaperoleDev` | `Contents/MacOS/Paperole` |
| Engine | the checkout's `../engine` (on `PYTHONPATH`) | a snapshot in `Contents/Resources/engine/paperole` |

- Paperole Dev says so: its name in the menu bar, About and alerts, and its window title while no paper or page
  is open (a paper's or a page's own title otherwise, as in Paperole) is "Paperole Dev", its icon has a small DEV capsule, and
  Settings › General has a line saying its papers, tags and settings are separate.
- `./build_app.sh` makes Dev (`VARIANT=dev`, the default); `VARIANT=release` makes the official bundle, which
  `release.sh` uses, and only into `APP_OUT` (without it the script stops), so it never lands in `build/`.
  `APP_OUT=/path/X.app ./build_app.sh` builds a bundle elsewhere (a test bundle; Dev unless `VARIANT=release`), not
  registered with Launch Services. Quote the paths: the Dev bundle's name has a space.
- `./release.sh` builds the official app in a temporary folder and installs it as `/Applications/Paperole.app`,
  removing the old one only once the new one is in place. It refuses while Paperole runs ("Quit Paperole (or the old
  PaperCollab) first"; Paperole Dev may run; any process named exactly `Paperole` or `PaperCollab` counts, a
  `swift run` or `.build/*/Paperole` binary too, as does any app of either bundle id), needs no sudo, never touches
  either app's data or defaults, and prints the installed path and where the engine snapshot came from. It never
  removes the old `/Applications/PaperCollab.app` (the app's name until 2026-10-27): the new app moves its data at its
  first launch, after which the old one shows an empty list, and the advisor moves it to the Trash. Engine changes
  reach the official app only at the next `./release.sh`.
- `./build_app.sh` without `APP_OUT` refuses while Paperole Dev or the old PaperCollab Dev runs.
- Both use the venv's Python; to give one app another, `defaults write <bundle id> enginePython /path/to/python`
  (Engine path, below).

## Launch

    open "build/Paperole Dev.app"      # the Dev app; the official one is /Applications/Paperole.app

- **New paper…** asks for a title, the student and an empty review folder. The folder holds the ledger, the
  round snapshots and the outputs; it is never the student's source folder.
- **Start Round 1… / New Round…** (shown while no round is open) asks for the student's LaTeX source folder (or a .zip). The engine copies it,
  compiles it and, from round 2 on, compares it with the previous round and re-anchors the open comments.
- The interaction design is `UX.md` (M2a). In short:
  - Comments are grouped by whose move it is: **To check**, **For the student** (follow-ups and new comments, what
    the email asks for) and **Closed this round** (folded; Show lists one 30 pt line each). The Comments tab counts
    the cards to check. A card stays in its group while selected and moves when you leave it.
  - Comments: one card is expanded, the selected one; the others are 44 pt rows. A card reads as a conversation in
    turns (`UX.md` §3, design/ui-v2.2 CARD.md option C): the note as its title, never cut, then one turn per round and
    actor, its label saying who did what ("R1 · you commented on", "R2–R3 · unchanged", "R3 · you followed up",
    "R4 · Mei Lin revised · 1 edit"): the sentence(s) as that round's PDF printed them, the mark tinted, the words changed
    since the text above underlined in green (View › Underline Changed Words turns that off); the student's `% R1-03`
    note in a grey bubble before the evidence, with its line in the source; an edit the note linked elsewhere shown as
    the Changes tab shows it. Earlier rounds' long bubbles show whole sentences with Show all, past five turns the middle
    ones fold into one line, and Focus shows everything. Figures, tables, equations and boxes show crops of each
    round's PDF (`UX.md` §3, §4).
  - Click a mark or its id label in the PDF to select its comment (repeat clicks cycle through overlapping marks).
    An id label is in its mark's colour (yellow, teal, blue, pink, purple, orange) with the status before the id:
    `+` New, `○` To check, `↩` Follow-up, `✓` Resolved, `–` Kept as is. Green is kept for changes.
    J/K, a click on a mark and a new comment centre the card; a click on a row scrolls the least.
  - Select text: a toolbar appears with colours (1–6), kinds (H/U/S) and Comment (Return). On a two-column page a
    drag from one column to the other selects the two runs of text, not a figure or table between them. ⌥-drag (or B, then drag)
    draws a box around a figure, table or equation; ⌥-click (or right-click › Add note here) places a note. The
    editor's style row starts from the last style used. A typed note is never dropped silently.
  - Click a new comment's note to edit it in place (⌘↩ saves, Esc twice discards, clicking elsewhere saves).
    Colour, kind, source and edits, Re-anchor…, Copy ID and Delete… are in the card's ⋯ menu; 1–6 recolour the
    selected comment; Delete deletes a new one after a confirmation.
  - A carried comment is answered with **✓ Resolve** (V), **↩ Follow up** (R) or **Keep as is** (W); the same key
    again clears it. Its follow-up field is always on the card but takes the cursor only from R, Return or a click:
    write, then ⌘↩ sends the follow-up (Return is a new line, Esc leaves the text as an unsent draft, kept on this
    Mac in `drafts` in the app's data folder, above). V or W on text asks whether it closes the comment
    as a closing remark. An answer, from a key or a click, moves on to the next card to check (not in Focus, below).
    A toast says what was done, with Undo; ⌘Z / ⇧⌘Z undo and redo answers (`UX.md` §8).
  - Re-anchor (from … or the attention line): select the new text or ⌥-drag a box, then Return or Place.
  - The Changes tab lists the edits no comment asked for (to check: V marks one checked, Return comments on it), then
    those that answer comments, each led by the comment's chip; the selected one reads as a thread, before and after.
  - **Focus** (the toolbar's page button, F, View › Focus) is for reading the paper: the sidebar goes, the page grows,
    and the panel shows only the card of the comment whose mark you click (or J/K), as in Review: answer it or write a
    follow-up there; answering leaves the PDF and the selection where they are; with reading marks on, a click on a
    bar marks its paragraph read (`UX.md` §20).
  - Group headers (To check, For the student, Closed this round) carry a sign, a count for the folded ones, and fold
    with a click anywhere on them; rows dim while a card is expanded. While the engine works, an answer says "Still
    loading…" and does nothing (`UX.md` §1, §11).
  - **Jump to…** (the sidebar's field, or ⌘K) finds a comment by its id, your words or the words it is on, an edit,
    a section, a round or a command; its last row finds the query in the paper (Edit › Find Next in Paper, ⌘G).
- The toolbar shows the paper, "student · 7 comments and 2 edits to check" (the panel's two counts) and the round
  menu; Comment and Box are in the **Comment** menu (and the floating toolbar, Return, ⌥-drag, B). The build is one
  line under the PDF, with the page shown.
- **Finish Round…** shows one sheet: what goes to the student, what is still to check, each unsent draft (Send as
  follow-up or Discard), what else is left, and the email as the engine will write it. **Finish and copy email**
  writes `rN/final.pdf` and the email text, closes the round and copies the email. **Email…** shows the text again,
  and **final.pdf** opens the round's final PDF.
- The round menu in the toolbar (`Round 3`) lists all rounds: an earlier round is shown as it was left (its PDF,
  marks, verdicts and changes), read only, under a "Round 1 · closed Oct 15 · read only" banner with **Back to Round 3**.
- The papers list says whose move it is under each title: `To check · Mei Lin` with an amber count, `Ready to finish`,
  `Round 1 in progress`, `Waiting for student`, `Build failed` (`UX.md` §17).
- The papers list is kept in `papers.json` in the app's data folder (Dev and official app, above). **Add Existing…** adds a
  review folder made with the CLI, and **Remove from list** only forgets the path.

Debug launch arguments (not saved to the papers list):

    open -n "build/Paperole Dev.app" --args --paper /path/to/review-folder [--select R1-02|c03] [--tab changes]
    open -n "build/Paperole Dev.app" --args --paper /path/a --paper /path/b    # more papers in the list; the first is selected
    open -n "build/Paperole Dev.app" --args --paper /path/to/review-folder --debug-open-comment "phrase in the PDF"
    open -n "build/Paperole Dev.app" --args --paper /path/to/review-folder --debug-open-comment "phrase" --debug-note "note"
    open -n "build/Paperole Dev.app" --args --paper /path/to/folder-a --debug-switch-to /path/to/folder-b
    open -n "build/Paperole Dev.app" --args --fixture Fixtures/state-m2a.json   # no engine; nothing is saved

`--debug-open-comment` selects the phrase's first occurrence in an open round's PDF and opens the new-comment
popover. With `--debug-note` it also types the note, tries to close the popover as a click elsewhere would (a typed
note keeps it open), and presses Save; the popover closes only when the engine has saved the comment.
`--debug-switch-to` selects a second paper while the first one's request is still running.

    open -n "build/Paperole Dev.app" --args --paper /path/to/review-folder \
        --debug-script "1,130,231,250,259;key 3;return;type note;key cmd-return;dump" --debug-out /tmp/out.jsonl [--debug-quit]

`--debug-script` (M1's `--debug-drag` is an alias) runs `;`-separated items once the PDF is shown and writes one
JSON value per item to `--debug-out` (or stderr); pages are 0-based and points are contract points (top left). Items:
`page,x1,y1,x2,y2[,clicks]` (drag, or click `clicks` times), `clear`, `return`, `menu page,x,y`, `click page,x,y`,
`optclick page,x,y`, `box page,x1,y1,x2,y2`, `key <j k v r w b h u s 1-6 return cmd-return esc delete>`,
`type <text>`, `typeslow <cps> <text>` (one character at a time, seeded jitter), `card <id>`, `note <id>`, `cardclick <x>,<y>` (a click in the expanded card), `rowclick <id>` (a click on a row), `button <resolve|followup|keep|discard|gotit>` and `field` (the card's buttons and follow-up field), `toastclick` (the toast's Undo or Redo), `toolbarclick` (the floating toolbar's Comment), `editorclick save|cancel` (the comment editor's buttons), `cardmenu <id> <title>`, `swatch <colour>`, `kind <kind>`, `dump`,
`thread` (the expanded card's sections), `groups` (the comment list's groups), `fold` / `foldclick` (the shown tab's folded group), `showall`, `window <w>,<h>`, `round <n>` (the round menu), `papers` (the papers list's next steps), `paper <path>` (select a paper, as a click in the list), `finishsheet [send|discard|undo|show <id>|left <comments|edits|paragraphs>|cancel|finish]` (the Finish sheet; send and discard as their clicks, guarded), `doneclick` (the done card's Finish Round…), `nopaper [all]` (no paper open), `panelscroll <dy>`, `wait <s>`, `quit`
(details in `Sources/Paperole/DebugScript.swift` and UX.md §13).
Mouse events are in-process NSEvents and keys go through the app's routing, so no Accessibility permission is needed.
`--debug-marks off` shows the PDF without marks. `--background` runs the app out of the user's way (below).

Reading (`UX.md` §18): optional, off by default (Settings…, ⌘,: "Mark changed paragraphs to read"; the Changes tab
lists every edit either way). With it on, from round 2 on, every paragraph the advisor has not confirmed read has a bar
in the PDF's margin; N goes to the next one, C confirms it (or the paragraph under the selection), Shift-C its section; the menu bar's
Reading menu lists them, and the status line under the PDF counts them down with Next and Mark Read; a click on a bar
marks its paragraph read. The sidebar has "Jump to…", Papers (folding) and Contents (each section's number, an olive dot
when it has changed paragraphs, its open comments, the section the PDF is in on a light fill).
Debug items: `key n|c|shift-c`, `reading`, `outline`, `outlineclick <block>`, `contentsclick <block>`,
`barclick <block>`, `barhover <block>`, `statusclick next|read`, `sidebar`, `papersfold`, `menu page,x,y <title>`,
`menubar [<menu>/<item>]`, `setting reading on|off`, `settings` (the Settings view, behind every window). `--reading on|off`
sets it for a test run, which never saves it (without the flag a `--background` or `--fixture` run has it off).
Focus and Jump (`UX.md` §20): `focus [on|off]`, `jump [<text>]`, `jumpclick <n>`, and `key up|down`; `--focus` starts
in Focus once the PDF is shown (for `--debug-scroll-perf keys` in Focus). `busy on|off` holds the engine busy;
`headerclick <group>` clicks a group header's name; `cardclick x,y,up` clicks the card's buttons.
The overview and the hierarchy (`UX.md` §21, §22, §40): `--level overview|review` (where `--paper` opens),
`--hub all|move|student:<name>` (open at that page), `--all-view board|students` (never saved); items `nav`, `ovtext` (the
paper page in words and numbers: header, strip, map rows, Key, Topics), `ovclick <item>` / `ovopen <item>`, `ovkey <left|right|up|down|return>`,
`ovkeypop open|close` (the Key), `ovtable on|off` (Map | Table), `reducemotion on|off|system`, `hub all|move|student <name>`,
`allview board|students`, `boardearlier`, `studentpage`, `help [<topic>]` (the Help window, behind every window),
`tips [reset|seen]` and `button gotit` (the tip shown).
`--fixture Fixtures/state-reading.json` shows round 2 of the engine's fixture paper with its paragraphs.

    open -n "build/Paperole Dev.app" --args --fixture Fixtures/state-many.json --debug-scroll-perf scroll|keys \
        --debug-out /tmp/perf.json --debug-quit

`--debug-scroll-perf` measures the comment panel with a display link: `scroll` moves it 24 pt a frame to the bottom
and back, `pdf` does the same to the PDF (at most 400 frames each way), `keys` presses J through every card and K back
every 150 ms. It writes frame intervals (p50, p95, max, frames over 50 ms) and view body counts (rows, expanded card,
list, sidebar, papers, Contents rows), per step for `keys`, with each step's `key_ms` (the run loop turn that handled
the key: the new card laid out and drawn; `key_p50_ms`/`key_p90_ms` overall), which needs no awake display. With the
display asleep the scrolling modes step on a 60 Hz timer and time each step instead (`timer`, `work_p50_ms`,
`work_p95_ms`).

Fixtures (no advisor data): `state-round2.json` (M1 state, no contexts), `state-m2a.json` (round 2 of the engine's
synthetic test paper with colours, kinds, boxes and per-round contexts; `round1/` and `round2/` hold the build PDFs
its crops come from), `state-many.json` (80 synthetic comments, for `--debug-scroll-perf`), `state-reading.json`
(round 2 of the engine's fixture paper with its paragraphs, headings and read set).
`tools/shot.sh --pid <pid> out.png [--all]` captures only that process's windows, by window id (below).

## Test runs without disturbing the user

The advisor works on this Mac while agents test, and may have Paperole or Paperole Dev open. Tests use
Paperole Dev only (the project's `CLAUDE.md`), and test instances run in the background:

    APP="build/Paperole Dev.app/Contents/MacOS/PaperoleDev"
    "$APP" --background --no-list --paper /path/to/copy-of-review-folder --tab changes > run.log 2>&1 &
    pid=$!
    tools/shot.sh --pid "$pid" shot.png          # that instance's window only
    kill -TERM "$pid"                              # that instance only; its engine exits with it

- `--background`: the app is never activated (the user's app keeps the keyboard), has no Dock icon or menu bar
  (accessory), and its window is created behind every other window, transparent until it is there, so it never
  flashes in front. Debug scripts work as usual: their mouse and key events go to the app's own window. It saves
  nothing to the user's defaults: view choices (Papers folded, mark style, changed words, reading marks) start from the defaults
  and are not remembered, and the window frame and column widths are neither read nor saved (from the start of the
  run, naming them for autosave does nothing: `BackgroundRun` in `App.swift`). Unsent drafts go to
  `--drafts <folder>` (a relaunch with the same folder finds them), else to a temporary folder of the run, never to
  Application Support; it never asks before quitting.
- `open -g -n "build/Paperole Dev.app" --args --background …` works too; its PID is then
  `pgrep -n -f 'Paperole Dev.app/Contents/MacOS/PaperoleDev --background'`.
- Capture with `tools/shot.sh --pid`: it finds the window even behind others or in another Space (the user in a
  full-screen app) and `screencapture -l` captures its content whole. Never capture the whole screen.
- Quit only your PID (`kill -TERM`, or `--debug-quit`). Never `tell application "Paperole" to quit`, `pkill` or
  `killall`: they would close the user's own window too.
- Run on a copy of a review folder in your scratch space; `--paper` entries are never saved to the papers list.

## Engine path

Both apps run `<repo>/engine/.venv/bin/python -m paperole.cli rpc`, and start it
again on the next action if it exits. To use another Python for one app (it needs the engine's dependencies, such as
PyMuPDF):

    defaults write com.paperole.app.dev enginePython /path/to/python    # Paperole Dev
    defaults write com.paperole.app enginePython /path/to/python        # Paperole
    defaults delete <bundle id> enginePython                            # back to the default

The engine runs in the temporary folder with the engine's folder first on `PYTHONPATH`; nothing is installed in the
venv for it. Paperole Dev, `swift test` and `swift run` use the checkout's `engine/` (found from
`Sources/Paperole/EngineClient.swift`'s path at build time, so a worktree's build runs the worktree's engine).
Paperole uses its snapshot (`Contents/Resources/engine/paperole`) and sets `PYTHONDONTWRITEBYTECODE=1`, so nothing is
written into the installed bundle. It still needs the repo's venv (its
Python and PyMuPDF): keep `engine/.venv` working. TeX Live is
expected in `/Library/TeX/texbin`; the engine adds it to PATH itself.
