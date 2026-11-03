# paperole engine

The engine: it snapshots and compiles a student's LaTeX source round by round, anchors the advisor's
comments (text marks in six colours, notes, and boxes on figures, tables and formulas) to the source, carries them into
the next round, keeps for each round the sentence(s) the PDF prints around each comment (`cards.py`, shown on the
app's cards), reads the student's `% R1-03 …` notes in the source and attaches the changes next to them (`notes.py`),
and writes the final PDF and email text.
`CONTRACT.md` defines the review folder, ledger.json, the CLI/RPC methods and the state JSON.
`paperole.annots.extract(pdf)` reads the annotations of an annotated PDF (used by `import`).

Setup (Python 3.9+, TeX Live in /Library/TeX/texbin), from this folder:

    python3 -m venv .venv && .venv/bin/pip install -e . pytest

minted, in a paper built with shell escape (CONTRACT.md amendment "Shell escape per paper"), runs Pygments'
`pygmentize`, which the engine finds beside its Python (the venv's `bin`). Pygments is one of the engine's own
dependencies (pyproject.toml, since 2026-11-01); without it minted says "You must have `pygmentize' installed" with
shell escape on.

Paperole Dev (`../mac/build_app.sh`) runs this folder's package (`paperole`, on `PYTHONPATH`, with the venv's
Python; nothing needs installing), so an edit here reaches it the next time it starts the engine. (The package was
`papercollab` until 2026-10-27; a venv made before keeps a stale `papercollab` entry, which is harmless.)
The official app (`/Applications/Paperole.app`) runs a snapshot of the package that `../mac/release.sh` copied into
the bundle, with this venv's Python: an edit here reaches it only at the next `release.sh`, and the venv (its Python
and PyMuPDF) must keep working (`../mac/README.md`, "Dev and official app").

Tests (the annots smoke test over `../samples/ann_pdf/` is skipped when those PDFs are missing):

    .venv/bin/python -m pytest       # tests this folder's package, wherever the venv is

CLI (pages are 0-based, rects are `x0,y0,x1,y1;…` in points from the top left); every command prints JSON:

    .venv/bin/python -m paperole new PAPER --title T --student S
    .venv/bin/python -m paperole ingest PAPER SOURCE_FOLDER_OR_ZIP [--main F] [--engine pdflatex|xelatex|lualatex]
    .venv/bin/python -m paperole comment PAPER --page 0 --rects "72,336,223,346" --note "…" \
        [--kind highlight|underline|strikeout|note|box] [--color yellow|teal|blue|pink|purple|orange] \
        [--tags logic,wording] [--accepted logic] [--name u-3f9c1a2b=Hedging]
    .venv/bin/python -m paperole edit PAPER R2-01 [--note "…"] [--kind K] [--color C]  |  delete PAPER R2-01
    .venv/bin/python -m paperole reanchor PAPER R1-03 --page 2 --rects "119,175,493,362" [--kind box]
    .venv/bin/python -m paperole verdict PAPER R1-03 verified|reopened|wontfix|clear [-m NOTE]   # reopened: Follow up
    .venv/bin/python -m paperole tag PAPER R1-03 logic wording [--accepted logic] [--no-state] | tag PAPER R1-03 --clear
    .venv/bin/python -m paperole retag PAPER u-1a2b3c4d clarity [--no-state]  # Merge Into…: every comment's tag, in its ledger
    .venv/bin/python -m paperole revive PAPER R1-03 [--undo]  # the advisor's Reopen: a closed comment back into the open round
    .venv/bin/python -m paperole import PAPER annotated.pdf
    .venv/bin/python -m paperole finish PAPER
    .venv/bin/python -m paperole state PAPER [--round N]      # N: an earlier round, as it was left
    .venv/bin/python -m paperole summaries PAPER [PAPER…]    # each paper's next step, title and student (no state)
    .venv/bin/python -m paperole export PAPER [PAPER…]       # every comment, round by round, for CSV or JSON (no state)
    .venv/bin/python -m paperole overview PAPER [PAPER…] [--marks] [--key-page PAPER ROUND:PAGE] [--tag-order logic,grammar]
        # rounds, sections, edits, comments' paths, tags, key page, students (no state)
    .venv/bin/python -m paperole edit-paper PAPER [--title T] [--student S]
    .venv/bin/python -m paperole prose PAPER [--round N] [--no-state]  # find a round's paragraphs (rN/prose.json) if needed
    .venv/bin/python -m paperole read PAPER 12 13 [--clear]   # mark paragraphs (block indices) of the open round read (or unread)
    .venv/bin/python -m paperole rpc          # JSON lines on stdin/stdout, for the app

The annots CLI writes `<stem>.comments.json` and `<stem>.report.md` into the output folder:

    .venv/bin/python -m paperole.annots path/to/annotated.pdf -o path/to/outdir

## Try it

Three rounds on the fixture paper (`tests/fixtures/paper`, see its `EDITS.md`), from this folder. `~/pc-demo` is
the new review folder; delete it afterwards. Every command prints the state JSON.

    .venv/bin/python -m paperole new ~/pc-demo --title "Predictive Warm Pools" --student "Lin Zhou"
    .venv/bin/python -m paperole ingest ~/pc-demo tests/fixtures/paper/v1        # snapshot and compile round 1
    .venv/bin/python -m paperole comment ~/pc-demo --page 0 --rects "184.37,391.04,288.37,401.0" \
        --text "simple keep-alive policy" --note "simple 不准确，改成 static。"   # R1-01
    .venv/bin/python -m paperole finish ~/pc-demo                                # r1/final.pdf, r1/email.txt
    .venv/bin/python -m paperole ingest ~/pc-demo tests/fixtures/paper/v2        # compare, re-anchor R1-01: changed
    .venv/bin/python -m paperole verdict ~/pc-demo R1-01 verified
    .venv/bin/python -m paperole comment ~/pc-demo --page 2 --rects "351.4,136.8,366.34,146.76" --text 671 \
        --note "这个数为什么变了？"                                         # R2-01, on an unrequested change
    .venv/bin/python -m paperole finish ~/pc-demo
    .venv/bin/python -m paperole ingest ~/pc-demo tests/fixtures/paper/v3        # R1-01 is closed, R2-01 is carried
    .venv/bin/python -m paperole state ~/pc-demo

The rects are the phrase's boxes in that round's PDF. To find them for another phrase:

    .venv/bin/python -c "import pymupdf; print(pymupdf.open('$HOME/pc-demo/r1/build/main.pdf')[0].search_for('simple keep-alive policy'))"

The same folder opens in Paperole Dev with `open -n "../mac/build/Paperole Dev.app" --args --paper ~/pc-demo`.
`tests/test_e2e_rounds.py` runs the full EDITS.md scenario over RPC; with `PAPEROLE_E2E_OUT=<new folder>` it
keeps the review folder.

## Local writing checks (2026-11-02)

The existing Checks pipeline also covers A1–A4, A6 and A7 from the writing-check shortlist:

- `short_last_line`: a multi-line paragraph ending in one word/symbol. Explicit line breaks and a hyphenated
  word's continuation are excluded.
- `paragraph_break`: a single paragraph line on either side of a page or column break.
- `heading_break`: a standalone heading with no following text, or only one line, before a page/column break.
  Run-in headings and headings followed by a figure or table are excluded.
- `split_phrase`: a reference name and number, or a number and a recognised time/frequency/storage unit, printed
  on different lines. It checks the PDF, not whether the source uses `~`.
- `draft_marker` (extended): literal `[Ref]`, `[??]` and `[citation needed]` in the PDF, including across lines.
  Real citation/link labels and these placeholders inside code/math are excluded; existing TODO checks remain.
- `sentence_start`: parser-marked inline math or a numeric citation at a clear sentence start, suggested as a
  writing change. Textual author citations, ambiguous abbreviations and continuations after display math are skipped.

Layout and sentence-start checks use mapped body text before the bibliography; layout checks exclude list items,
except that `split_phrase` also checks them. Paragraph parts distinguish columns and full-width text. A7 uses the
existing source-line-to-PDF mapping, so its mark can cover a line rather than just the symbol/citation. There is no
AI, network request, new dependency or new finding group. The five new codes use Typesetting; placeholders
stay in Submission. The checks version invalidates older caches. The existing A-id, Mark as OK, export and round lifecycle
are reused. Tests: `tests/test_writing_checks.py` (geometry/exclusions and compiled one/two-column papers through
export and a clean next round), plus the existing check regressions. Local development notes are in the repository's
git-ignored `implementation-notes.md`.

Settings > Reading > Writing checks has six individual checkboxes, enabled by default under the existing master
and category switches. Draft markers controls the whole `draft_marker` rule, including TODO/TBD; `todo_note` is
unchanged. Choices persist and travel with an export of settings. The raw checks cache stays shared; choices select
the findings shown and sent, rather than changing that cache.

Float placement (2026-11-03): figures, tables and algorithms on the same page as their first citation, or one page
before/after it, produce no distance warning. Both directions now require a page-number difference of at least 2.
The existing first-page teaser and appendix exemptions remain. Findings say how many pages before/after and suggest
moving closer, without requiring a float to follow its citation. `CHECKS = 7` invalidates the old cache; unchanged
`float_before`/`float_far` codes and label-based keys preserve IDs and Mark as OK. Open rounds are rechecked; finished
rounds keep their recorded findings. Dev loads this engine from the checkout on restart; no native rebuild is needed.

The `check_items` and `finish` RPCs accept optional `disabled: [check_code, ...]` (omitted: all enabled for
`check_items`; the round's saved choice for `finish`). Unknown codes/types are refused. `finish` also accepts
`groups`, so an immediate Finish honours the latest settings even while a scan is pending. The round stores
`check_disabled` alongside `check_groups`. Disabled items pause, keep their notes and are not marked fixed; switching
a pending item back on keeps its id. Finished rounds show their recorded selection. No ledger schema change is needed.

Bibliography highlight geometry (2026-11-03): whole-entry findings now carry one rectangle per text line, rather
than a filled paragraph box. Hanging first words are recovered on the same PDF line and column; continuation parts
on other pages/columns are included. Existing word-specific findings remain precise. With no selectable words, the
location is page-only. Both the app and final.pdf already render these rectangles as text highlights. CHECKS 8
invalidates old caches; open rounds refresh their marks without changing IDs, while finished-round records remain
as sent. No detector decisions, colours, reference metadata or native rendering code change.

### Check execution records (2026-11-03)

`checks` now returns a `report` beside the findings: scan start/completion timestamps and one entry per rule, including
zero-finding rules. Each entry names the rule, its group, finding count, execution outcome and conservative coverage.
Outcomes distinguish completed, not applicable, unavailable inputs, partial coverage and failure. `groups` and
`disabled` exclude rules in the returned report without changing the cached scan; closed rounds use their recorded
selection. These are scan outcomes, not assertions that a paper is correct. An execution failure cannot mark a
previously reported finding fixed. CHECKS 9 invalidates older caches; no ledger schema migration.

`references` also returns saved lookup `attempts`. `ref_results` accepts optional attempts by reference key, with a
known outcome and timezone-qualified ISO timestamp. An unavailable response, stopped queue, missing search input or
daily limit is recorded separately from a bibliographic result, never as `found: false`. Records survive entry refresh.
Both caches retain the latest outcome, not an unbounded history. The engine makes no network requests.
