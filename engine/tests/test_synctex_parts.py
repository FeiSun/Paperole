"""Engine speed (BACKLOG O12): a synctex query reads only the part of the .synctex.gz it needs and answers as on the
whole file, and state stores what it works out for review folders from before contexts were stored, so a later engine
process reads it instead of working it out again."""
import gzip
import json
import subprocess
from pathlib import Path

from conftest import FIXTURE, quiet, select
from paperole import analysis, anchor, api, cards, ledger, project, state

MAIN = r"""\documentclass{article}
\usepackage{amsmath}
\begin{document}
\section{Opening}
\input{sections/a}
A sentence of the main file runs on, and then \input{sections/b} the rest of its paragraph follows on this line.

\clearpage
\input{sections/c}
\clearpage
\section{Drawn once}
\setbox0=\hbox{A sentence set in a form.}\pdfxform0 \pdfrefxform\pdflastxform
\input{sections/d}
\clearpage
\input{sections/c}
\end{document}
"""
A = r"""Warm pools keep a few instances of each function ready, so a request rarely waits for a cold start.\footnote{A
cold start boots a sandbox and loads the runtime.}
The pool size follows the arrival rate
\begin{equation}
  k = \lceil \lambda \, t \rceil ,
\end{equation}
where $t$ is the keep-alive window.

A second paragraph explains why a fixed window wastes memory on functions that are called once a day and starves
the ones that are called every second, which is the case the predictor is built for.
"""
B = "words that the second file adds"
C = r"""\section{Repeated}
This file is read twice, so the synctex file names it under two input tags.

It holds two paragraphs; the second one is a little longer than the first and wraps onto a second line of the page.
"""
D = r"""\begin{itemize}
  \item The first item.
  \item The second item, which is long enough to wrap onto another line of the page in this narrow column.
\end{itemize}
\begin{tabular}{lr}
  Pool & 12 \\
  Window & 30 \\
\end{tabular}
"""


def _whole_file(pdf, name, line):
    """The boxes `synctex view` gives on the whole .synctex.gz (as anchor._line_boxes reads them)."""
    out = subprocess.run(["synctex", "view", "-i", "{}:0:{}".format(line, name), "-o", str(pdf)],
                         capture_output=True, text=True, env=project.tex_env(), timeout=60).stdout
    boxes = []
    for p, h, v, w, ht in anchor.VIEW.findall(out):
        h, v, w, ht = map(float, (h, v, w, ht))
        if w > 0 and ht > 0:
            boxes.append((int(p) - 1, (h, v - ht, h + w, v)))
    return boxes


def test_line_boxes_from_part_of_the_synctex_file(tmp_path, monkeypatch):
    """Every line of every input gives the same boxes, in the same order, from a part holding only the pages that
    name its file (and the page drawing a form), as `synctex view` gives on the whole file: a file read twice (two
    input tags of one name), one opened in the middle of a paragraph, a footnote, display math, a list and a table."""
    read, real = [], anchor._synctex
    monkeypatch.setattr(anchor, "_synctex", lambda args: read.append(args[args.index("-o") + 1]) or real(args))
    anchor._line_boxes.cache_clear()
    src = tmp_path / "src"
    for name, text in {"main.tex": MAIN, "sections/a.tex": A, "sections/b.tex": B, "sections/c.tex": C,
                       "sections/d.tex": D}.items():
        (src / name).parent.mkdir(parents=True, exist_ok=True)
        (src / name).write_text(text)
    pdf = Path(project.compile(src, tmp_path / "build", "main.tex", "pdflatex")["pdf"])
    stamp = anchor._stamp(pdf)
    names = anchor._inputs(stamp, str(src))
    assert {"main.tex", "sections/a.tex", "sections/b.tex", "sections/c.tex", "sections/d.tex"} <= set(names)
    whole = len(gzip.decompress(pdf.with_suffix(".synctex.gz").read_bytes()))
    parts = 0
    for rel in sorted(names):
        target = anchor._view_target(stamp, names[rel])
        if target != str(pdf):
            parts += 1
            assert Path(target).with_suffix(".synctex").stat().st_size < whole
        for line in range(1, (src / rel).read_text().count("\n") + 4):
            assert anchor._line_boxes(stamp, names[rel], line) == _whole_file(pdf, names[rel], line), (rel, line)
    assert parts >= 3  # (the main file names every page)
    assert sum(target != str(pdf) for target in read) > len(read) / 2  # the queries read parts
    # a part the system cleared from the temporary folder is written again
    target = anchor._view_target(stamp, names["sections/c.tex"])
    Path(target).with_suffix(".synctex").unlink()
    anchor._line_boxes.cache_clear()
    assert anchor._line_boxes(stamp, names["sections/c.tex"], 2) == _whole_file(pdf, names["sections/c.tex"], 2) != []


def test_contexts_of_older_records_are_worked_out_once(paper, monkeypatch):
    """A record from before contexts were stored gets its context worked out by the first state and kept in
    rN/contexts.json: a new engine process reads it there; an edited comment's is worked out again (and the old
    entry dropped). The ledger is not written."""
    pdf = paper / "r1" / "build" / "main.pdf"
    cid = api.comment({"paper": str(paper), "page": 0, "rects": select(pdf, 0, "boots a minimal microVM in about 125"),
                       "text": "", "note": "Source?", "kind": "highlight"}, quiet)["id"]
    with ledger.edit(paper) as lg:  # as a ledger from before contexts were stored has it
        stored = lg["comments"][0]["rounds"]["1"].pop("context")
    before = (paper / "ledger.json").read_text()
    worked, real = [], cards.record_context
    monkeypatch.setattr(cards, "record_context", lambda *a, **k: worked.append(a[3]) or real(*a, **k))
    state._CONTEXTS.clear()
    assert json.loads(json.dumps(state.build(paper)["comments"][0]["context"])) == stored and worked == [1]
    saved = paper / "r1" / "contexts.json"
    assert len(json.loads(saved.read_text())["contexts"]) == 1
    assert (paper / "ledger.json").read_text() == before
    state._CONTEXTS.clear()  # a new engine process
    assert json.loads(json.dumps(state.build(paper)["comments"][0]["context"])) == stored and worked == [1]
    api.edit_comment({"paper": str(paper), "id": cid, "note": "Which source?"}, quiet)  # returns a state
    assert worked == [1, 1] and len(json.loads(saved.read_text())["contexts"]) == 1


def test_change_details_of_an_older_analysis_are_stored(paper, monkeypatch):
    """The section and context of the changes of an analysis.json from before they were stored are worked out by the
    first state and written into analysis.cache.json (never into analysis.json, which is primary: design/data/DATA.md
    §2.4), so a new engine process reads them; not while another process holds the ledger's lock, nor when
    analysis.json changed since state read it."""
    api.finish({"paper": str(paper)}, quiet)
    api.ingest({"paper": str(paper), "source": str(FIXTURE / "v2")}, quiet)
    path = paper / "r2" / "analysis.json"
    data = json.loads(path.read_text())
    for ch in data["changes"]:
        del ch["section"], ch["context"]
    path.write_text(json.dumps(data))
    older = path.read_text()
    changes = json.loads(older)["changes"]
    lg = ledger.load(paper)
    state._CHANGES.clear()
    details = state._change_details(paper, lg, 2, changes)
    with ledger.locked(paper):  # another writer holds the lock: left for a later state
        state._store_details(paper, 2, changes, details)
    assert not any("context" in ch for ch in analysis.changes(paper, 2))
    state._store_details(paper, 2, changes[1:], details[1:])  # not the changes the file holds now
    assert not any("context" in ch for ch in analysis.changes(paper, 2))

    first = state.build(paper)["changes"]
    assert path.read_text() == older  # viewing never rewrites analysis.json
    stored = analysis.changes(paper, 2)
    assert state._change_details(paper, lg, 2, stored) == [{} for _ in stored]  # nothing left to work out
    assert all(ch["context"] for ch in stored)

    def fail(*args, **kwargs):
        raise AssertionError("worked out again")
    monkeypatch.setattr(cards, "change_details", fail)
    monkeypatch.setattr(cards, "describe", fail, raising=False)
    state._CHANGES.clear()  # a new engine process
    assert json.loads(json.dumps(state.build(paper)["changes"])) == json.loads(json.dumps(first))
