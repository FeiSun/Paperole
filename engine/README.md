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
