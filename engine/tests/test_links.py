"""The link table for reference previews (links.py; CONTRACT.md amendment "Reference previews"): hyperref's links
and their targets as prose.json's blocks (the whole float, the formula, the heading and the lines after it, the
reference entry), \\cite{a,b}'s other keys, references found from the source without hyperref, undefined labels and
citations, footnotes and URLs, "cited on" pages, and the cache: built at ingest, rebuilt when stale or damaged,
never failing a request."""
import json
import os
import shutil

import pymupdf
import pytest

from conftest import Engine, quiet
from paperole import api, disk, ledger, links, prose

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

SOURCE = r"""\documentclass{article}
\usepackage[round]{natbib}
\usepackage{amsmath,amsthm}
%(hyperref)s
\newtheorem{theorem}{Theorem}
\begin{document}
\section{Introduction}\label{sec:intro}
Pools of warm sandboxes cut cold starts, as Figure~\ref{fig:pool} shows and Table~\ref{tab:cost} prices
\citep{Wang2026,Chen2025}. We model the cost in Equation~\eqref{eq:cost} and prove Theorem~\ref{thm:bound} in
Section~\ref{sec:model}. A stale reference to Figure~\ref{fig:old} and a missing citation \citep{Nobody2020} are
left in this sentence.\footnote{The trace is public at \url{https://example.org/trace} for everyone.}

\section{Model}\label{sec:model}
\citet{Sharma2024} price idle memory per second, so the cost of a pool of size $k$ over a day is
\begin{equation}\label{eq:cost}
C(k) = c_0 k + \lambda \int_0^T p(t)\,dt .
\end{equation}

\begin{theorem}\label{thm:bound}
The cost in \eqref{eq:cost} grows at most linearly in the pool size $k$ for every trace of requests.
\end{theorem}

\begin{figure}[h]
\centering
\rule{4cm}{2cm}
\caption{A warm pool of four sandboxes.}\label{fig:pool}
\end{figure}

\begin{table}[h]
\centering
\begin{tabular}{lr} Policy & Cost \\ Fixed & 4.1 \\ Adaptive & 2.7 \end{tabular}
\caption{The cost of each policy.}\label{tab:cost}
\end{table}

As Section~\ref{sec:intro} said, the pool in Figure~\ref{fig:pool} and the study by \citet{Wang2026} agree on this.

\begin{thebibliography}{9}
\bibitem[Wang et~al.(2026)]{Wang2026} A. Wang, B. Li, and C. Zhou. Cold starts in practice. In \emph{Proc. X}, 2026.
\bibitem[Chen and Li(2025)]{Chen2025} D. Chen and E. Li. Serverless in the wild. In \emph{Proc. Y}, 2025.
\bibitem[Sharma et~al.(2024)]{Sharma2024} G. Sharma, H. Ho, and I. Ito. Pricing idle memory. In \emph{Proc. W}, 2024.
\end{thebibliography}
\end{document}
"""


def _paper(root, hyperref):
    src = root / "src"
    src.mkdir(parents=True)
    (src / "main.tex").write_text(SOURCE % {"hyperref": "\\usepackage{hyperref}" if hyperref else ""})
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Warm pools", "student": "Lin Zhou"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    return paper


@pytest.fixture(scope="module")
def linked(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("linked"), True)


@pytest.fixture(scope="module")
def plain(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("plain"), False)


@pytest.fixture
def copy(tmp_path):
    def make(paper):
        dest = tmp_path / "copy"
        shutil.copytree(paper, dest)
        return dest
    return make


def _table(paper, n=None):
    return api.links_({"paper": str(paper), "round": n}, quiet)["table"]


def _target(table, kind, label):
    return next(i for i, t in enumerate(table["targets"]) if t["kind"] == kind and t["label"] == label)


def _links_to(table, t, first=True):
    return [e for e in table["links"] if (e["targets"][0] == t if first else t in e["targets"])]


def _blocks(paper):
    return prose.load(paper, 1)["blocks"]


def test_ingest_builds_the_table_outside_the_round_files(linked):
    assert links.path(linked, 1).is_file()
    assert "links.json" not in disk.round_files(linked / "r1", "main")
    table = links.load(linked, 1)
    assert table["schema"] == links.SCHEMA and table["version"] == links.LINKS and table["parser"] == prose.PARSER
    assert table["round"] == 1 and table["hyperref"] is True


def test_hyperref_targets_are_whole_blocks(linked):
    table, blocks = _table(linked), _blocks(linked)
    for kind, label, block_kind in [("figure", "Figure 1", "figure"), ("table", "Table 1", "table"),
                                    ("equation", "Equation (1)", "math"), ("section", "Section 2", "heading"),
                                    ("theorem", "Theorem 1", "paragraph")]:
        t = table["targets"][_target(table, kind, label)]
        b = blocks[t["block"]]
        assert b["kind"] == block_kind, (label, b["kind"])
        page, box = b["box"] or b["parts"][0]
        assert t["page"] == page and t["parts"][0][0] == page
        if kind in ("figure", "table", "equation"):
            assert t["box"] == box  # the whole float (hyperref's point is just above the caption) or formula
        else:  # a section's heading and the lines after it; a theorem's first lines
            assert t["box"][1] == pytest.approx(box[1], abs=1.5) and t["box"][3] > box[1] + 20
        assert _links_to(table, _target(table, kind, label))
    figure = _target(table, "figure", "Figure 1")
    assert table["targets"][figure]["key"] == "fig:pool"
    assert [e["via"] for e in _links_to(table, figure)] == ["pdf", "pdf"]
    assert table["targets"][figure]["count"] == 2 and table["targets"][figure]["cited"] == \
        sorted({e["page"] for e in _links_to(table, figure)})
    eq = _target(table, "equation", "Equation (1)")
    assert [e["text"].strip(".,") for e in _links_to(table, eq)] == ["(1)", "(1)"]


def test_a_citation_of_several_keys_gives_each_link_the_others(linked):
    table, blocks = _table(linked), _blocks(linked)
    wang, chen = _target(table, "cite", "Wang et al., 2026"), _target(table, "cite", "Chen and Li, 2025")
    first = [e for e in table["links"] if e["targets"][0] == wang and chen in e["targets"]]
    assert len(first) == 1 and first[0]["targets"] == [wang, chen] and "Wang" in first[0]["text"]
    other = [e for e in table["links"] if e["targets"][0] == chen]
    assert len(other) == 1 and other[0]["targets"] == [chen, wang]
    assert len(first[0]["rects"]) >= 1 and first[0]["kind"] == "cite"
    t = table["targets"][wang]
    assert t["key"] == "Wang2026" and blocks[t["block"]]["kind"] == "bibitem"
    assert t["box"] == blocks[t["block"]]["parts"][0][1] and t["at"] is not None  # hyperref's point, for Go to
    assert t["count"] == 2  # the \citep and the \citet, not the sibling of Chen's link
    assert table["targets"][_target(table, "cite", "Sharma et al., 2024")]["count"] == 1


def test_undefined_references_footnotes_and_urls(linked):
    table = _table(linked)
    old = next(t for t in table["targets"] if t["key"] == "fig:old")
    assert old["kind"] == "missing" and old["label"] == "Undefined reference" and old["page"] is None
    assert old["note"] == "No \\label{fig:old} in this round's source."
    missing = [e for e in table["links"] if e["kind"] == "missing"]
    assert {e["text"].strip(".,()") for e in missing} == {"??", "?"} and all(e["via"] == "source" for e in missing)
    nobody = next(t for t in table["targets"] if t["key"] == "Nobody2020")
    assert nobody["kind"] == "missing" and nobody["note"] == "No \\bibitem{Nobody2020} in this round's references."
    note = next(t for t in table["targets"] if t["kind"] == "footnote")
    assert note["label"] == "Footnote 1" and note["box"] and note["box"][1] > 600  # at the foot of the page
    url = next(t for t in table["targets"] if t["kind"] == "url")
    assert url["url"] == url["label"] == "https://example.org/trace" and url["page"] is None


def test_without_hyperref_references_come_from_the_source(plain):
    table, blocks = _table(plain), _blocks(plain)
    assert table["hyperref"] is False and table["links"]
    assert {e["via"] for e in table["links"]} == {"source"}
    figure = _target(table, "figure", "Figure 1")
    assert blocks[table["targets"][figure]["block"]]["kind"] == "figure"
    assert [e["text"].strip(".,") for e in _links_to(table, figure)] == ["1", "1"]
    eq = _target(table, "equation", "Equation (1)")
    assert len(_links_to(table, eq)) == 2
    for kind, label in [("table", "Table 1"), ("section", "Section 2"), ("section", "Section 1"),
                        ("theorem", "Theorem 1")]:
        assert _links_to(table, _target(table, kind, label)), label
    wang, chen = _target(table, "cite", "Wang et al., 2026"), _target(table, "cite", "Chen and Li, 2025")
    both = [e for e in table["links"] if e["targets"] == [wang, chen]]
    assert len(both) == 1 and "Wang" in both[0]["text"] and "Chen" in both[0]["text"]
    assert table["targets"][wang]["count"] == 2 and table["targets"][chen]["count"] == 1
    assert {t["key"] for t in table["targets"] if t["kind"] == "missing"} == {"fig:old", "Nobody2020"}
    # the link's rects hold its printed words
    e = _links_to(table, figure)[0]
    words = pymupdf.open(str(plain / "r1/build/main.pdf"))[e["page"]].get_text("words")
    inside = [w[4] for w in words if any(r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1 and
                                         r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1 for r in e["rects"])]
    assert [w.strip(".,") for w in inside] == ["1"]


def test_a_damaged_or_stale_table_is_built_again(linked, copy):
    paper = copy(linked)
    first = _table(paper)
    links.path(paper, 1).write_text("{not json")
    assert links.load(paper, 1) is None
    assert _table(paper) == first
    stale = dict(first, version=links.LINKS - 1)
    links.path(paper, 1).write_text(json.dumps(stale))
    assert links.load(paper, 1) is None and _table(paper) == first
    links.path(paper, 1).write_text(json.dumps(dict(first, parser=prose.PARSER - 1)))
    assert _table(paper) == first
    links.path(paper, 1).write_text(json.dumps({"schema": 1, "version": links.LINKS, "parser": prose.PARSER}))
    assert _table(paper) == first  # current numbers but no lists: damaged


def test_without_aux_or_bbl_the_table_is_still_built(linked, copy):
    paper = copy(linked)
    for name in ("main.aux", "main.bbl"):
        (paper / "r1/build" / name).unlink(missing_ok=True)
    links.path(paper, 1).unlink()
    table = links.build(paper, ledger.load(paper), 1, prose.load(paper, 1))
    assert table["links"] and table["hyperref"]
    figure = next(t for t in table["targets"] if t["kind"] == "figure")  # by its destination's place alone
    assert _blocks(paper)[figure["block"]]["kind"] == "figure"


def test_failures_give_no_table_and_never_an_error(linked, copy, monkeypatch, capsys):
    paper = copy(linked)
    links.path(paper, 1).unlink()
    runs = []

    def broken(self):
        runs.append(1)
        raise ValueError("a link PyMuPDF cannot read")
    monkeypatch.setattr(links._Table, "run", broken)
    out = api.links_({"paper": str(paper)}, quiet)
    assert out == {"round": 1, "path": None, "table": None}
    assert "a link PyMuPDF cannot read" in capsys.readouterr().err
    assert api.links_({"paper": str(paper)}, quiet)["table"] is None and len(runs) == 1  # not built again
    os.utime(prose.path(paper, 1), ns=(1, 1))  # until the round's prose.json (or PDF) changes
    assert api.links_({"paper": str(paper)}, quiet)["table"] is None and len(runs) == 2
    monkeypatch.undo()
    prose.path(paper, 1).unlink()  # the paragraphs cannot be found either: still no error
    monkeypatch.setattr(prose, "build", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no paragraphs")))
    assert api.links_({"paper": str(paper)}, quiet)["table"] is None
    assert prose.failed(paper, 1)
    assert api.links_({"paper": str(paper)}, quiet)["table"] is None  # and not tried again with this PARSER
    # a link that fails is left out, the others kept, and the source finds what it printed
    monkeypatch.undo()
    (paper / "r1/prose.failed").unlink()
    real = links._Table.dest_target

    def flaky(self, name, point, text):
        if name.startswith("figure."):
            raise KeyError(name)
        return real(self, name, point, text)
    monkeypatch.setattr(links._Table, "dest_target", flaky)
    table = api.links_({"paper": str(paper)}, quiet)["table"]
    figure = _target(table, "figure", "Figure 1")
    assert {e["via"] for e in _links_to(table, figure)} == {"source"} and len(_links_to(table, figure)) == 2
    assert {e["via"] for e in table["links"] if e["kind"] == "table"} == {"pdf"}


def test_ingest_never_fails_on_the_table(tmp_path, monkeypatch):
    monkeypatch.setattr(links._Table, "run", lambda self: 1 / 0)
    paper = _paper(tmp_path, True)
    assert not links.path(paper, 1).exists() and prose.load(paper, 1) is not None
    assert ledger.load(paper)["rounds"][0]["build"]["status"] == "ok"


def test_rpc_and_cli(linked):
    eng = Engine()
    try:
        eng.send(json.dumps({"id": 1, "method": "links", "params": {"paper": str(linked), "round": 1}}))
        reply = eng.reply(1)
        assert set(reply["result"]) == {"round", "path", "table"}
        assert reply["result"]["table"] == _table(linked) and reply["result"]["path"] == str(links.path(linked, 1))
        eng.send(json.dumps({"id": 2, "method": "links", "params": {"paper": str(linked), "round": 5}}))
        assert eng.reply(2)["error"]["message"] == "There is no round 5."
    finally:
        assert eng.close()[0] == 0


NUMERIC = r"""\documentclass{article}
\usepackage[numbers]{natbib}
\usepackage{cleveref}
\begin{document}
\section{Method}\label{sec:method}
Our pools follow earlier work \citep{Wang2026,Chen2025}, as \cref{fig:pool,tab:cost} show, and \Cref{sec:method}
gives the details; \cref{fig:pool} is drawn to scale.

\begin{figure}[h]
\centering
\rule{4cm}{1cm}
\caption{A warm pool.}\label{fig:pool}
\end{figure}

\begin{table}[h]
\centering
\begin{tabular}{lr} Fixed & 4.1 \end{tabular}
\caption{The cost.}\label{tab:cost}
\end{table}

\begin{thebibliography}{9}
\bibitem[Wang et~al.(2026)]{Wang2026} A. Wang. Cold starts in practice. In \emph{Proc. X}, 2026.
\bibitem[Chen and Li(2025)]{Chen2025} D. Chen and E. Li. Serverless in the wild. In \emph{Proc. Y}, 2025.
\end{thebibliography}
\end{document}
"""


def test_cleveref_and_numeric_citations_without_hyperref(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text(NUMERIC)
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "Warm pools", "student": "Lin Zhou"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    table = _table(paper)
    assert table["hyperref"] is False
    by_text = {e["text"].strip(".,;"): e for e in table["links"]}
    both = by_text["[1, 2]"]  # \citep{a,b}, numeric: one run, both entries
    assert [table["targets"][t]["key"] for t in both["targets"]] == ["Wang2026", "Chen2025"]
    pair = next(e for e in table["links"] if len(e["targets"]) == 2 and e["kind"] == "figure")
    assert [table["targets"][t]["label"] for t in pair["targets"]] == ["Figure 1", "Table 1"]
    assert pair["text"].lower().startswith("fig")  # cleveref prints "fig. 1 and table 1" (prose: "Figure 1 and …")
    section = _target(table, "section", "Section 1")
    assert _links_to(table, section)
    assert len(_links_to(table, _target(table, "figure", "Figure 1"))) == 2


SHARED = r"""\documentclass{article}
\usepackage{amsmath,amsthm}
\usepackage{subcaption}
\usepackage{hyperref}
\usepackage{cleveref}
\newtheorem{theorem}{Theorem}
\newtheorem{lemma}[theorem]{Lemma}
\begin{document}
\section{Pools}\label{sec:pools}
Warm pools cut cold starts.\footnote{Measured on the public trace.} The pools of \cref{fig:pools} have four
sizes, and \cref{fig:pool-b} shows the largest.\footnote{Its cost is in the second table.} By \cref{thm:bound}
and Lemma~\ref{lem:idle} the cost is bounded; a figure labelled too early gives Figure~\ref{fig:early}.
The data is at \href{https://example.org/trace}{the trace site}, write to \href{mailto:lab@example.org}{the lab},
or run \href{javascript:app.alert(1)}{this script}. The cost of a pool is
\begin{equation}\label{eq:cost} C(k) = c_0 k . \end{equation}
The pools of every size obey \eqref{eq:cost} for the whole of the day, so we use \eqref{eq:cost}\\
and then again \eqref{eq:cost} on the next line, for the night.
\begin{theorem}\label{thm:bound} The cost grows at most linearly in the pool size. \end{theorem}
\begin{lemma}\label{lem:idle} Idle memory is paid per second. \end{lemma}
\begin{figure}[h]\centering
\begin{subfigure}{0.4\textwidth}\centering\rule{3cm}{1cm}\caption{Small.}\label{fig:pool-a}\end{subfigure}
\begin{subfigure}{0.4\textwidth}\centering\rule{3cm}{1cm}\caption{Large.}\label{fig:pool-b}\end{subfigure}
\caption{Two pools.}\label{fig:pools}
\end{figure}
\begin{figure}[h]\centering\label{fig:early}\rule{3cm}{1cm}\caption{A label before its caption.}\end{figure}
\end{document}
"""


@pytest.fixture(scope="module")
def shared(tmp_path_factory):
    root = tmp_path_factory.mktemp("shared")
    (root / "src").mkdir()
    (root / "src/main.tex").write_text(SHARED)
    api.new({"paper": str(root / "paper"), "title": "Warm pools", "student": "Lin Zhou"}, quiet)
    api.ingest({"paper": str(root / "paper"), "source": str(root / "src")}, quiet)
    return root / "paper"


def test_subfigures_lemmas_and_labels_before_captions(shared):
    """subcaption's figure and subfigures share one anchor (the printed number picks the label); a lemma on the
    theorem counter (anchor theorem.2) is a Lemma; the caption package's "??" for a \\label before \\caption."""
    table = _table(shared)
    whole, sub = _target(table, "figure", "Figure 1"), _target(table, "figure", "Figure 1b")
    assert table["targets"][whole]["key"] == "fig:pools" and table["targets"][sub]["key"] == "fig:pool-b"
    assert [e["text"] for e in _links_to(table, whole)] == ["1"]
    assert [e["text"] for e in _links_to(table, sub)] == ["1b"]
    assert table["targets"][whole]["count"] == table["targets"][sub]["count"] == 1
    lemma = table["targets"][_target(table, "theorem", "Lemma 2")]
    assert lemma["key"] == "lem:idle" and table["targets"][_target(table, "theorem", "Theorem 1")]["key"] == "thm:bound"
    early = next(t for t in table["targets"] if t["key"] == "fig:early")
    assert early["kind"] == "missing" and early["page"] is None
    assert early["note"] == "\\label{fig:early} comes before \\caption, so it names no number."


def test_footnotes_end_where_the_next_begins(shared, copy, monkeypatch):
    """Two footnotes on a page: the second's lines start at its own point (not the first's last line), and the
    first's end at the second's destination even when no link reaches it."""
    table = _table(shared)
    first, second = sorted((t for t in table["targets"] if t["kind"] == "footnote"), key=lambda t: t["at"][1])
    assert first["label"] == "Footnote 1" and second["label"] == "Footnote 2"
    assert first["box"][1] >= first["at"][1] and second["box"][1] >= second["at"][1]
    assert first["box"][3] < second["box"][1]  # the point lies a little above the line it starts
    paper = copy(shared)
    real = links._Table._destination

    def dropped(self, link):  # the second footnote's link cannot be read
        return (None, None) if link.get("nameddest") == "Hfootnote.2" else real(self, link)
    monkeypatch.setattr(links._Table, "_destination", dropped)
    table = links.build(paper, ledger.load(paper), 1, prose.load(paper, 1))
    only = [t for t in table["targets"] if t["kind"] == "footnote"]
    assert len(only) == 1 and only[0]["box"] == first["box"]


def test_links_on_consecutive_lines_and_url_schemes(shared):
    """A reference broken across lines is one link ("the lab"); two references to one target on consecutive lines
    stay two; only http, https and mailto URLs are targets."""
    table = _table(shared)
    eq = _target(table, "equation", "Equation (1)")
    assert [e["text"].strip(".,") for e in _links_to(table, eq)] == ["(1)", "(1)", "(1)"]
    assert all(len(e["rects"]) == 1 for e in _links_to(table, eq)) and table["targets"][eq]["count"] == 3
    lab = next(e for e in table["links"] if table["targets"][e["targets"][0]]["url"] == "mailto:lab@example.org")
    assert len(lab["rects"]) == 2 and lab["rects"][1][1] > lab["rects"][0][1] and lab["text"].startswith("the lab")
    assert sorted(t["url"] for t in table["targets"] if t["kind"] == "url") == \
        ["https://example.org/trace", "mailto:lab@example.org"]
    assert not any("script" in e["text"] for e in table["links"])


PROMO = os.path.join(os.path.dirname(__file__), "..", "..", "samples", "promo-demo", "review")


@pytest.mark.skipif(not os.path.isdir(PROMO), reason="needs the synthetic samples/promo-demo")
def test_the_promo_demo_rounds(tmp_path):
    """The synthetic 8-page paper with hyperref (a copy): every named link has a target in a block of its kind."""
    paper = tmp_path / "review"
    shutil.copytree(PROMO, paper)
    for n in (1, 2):
        links.path(paper, n).unlink(missing_ok=True)
        table = _table(paper, n)
        blocks = prose.load(paper, n)["blocks"]
        assert table["hyperref"] and len(table["links"]) > 40
        assert all(e["via"] == "pdf" for e in table["links"])  # every reference is linked: no source duplicates
        kinds = {"figure": "figure", "table": "table", "equation": "math", "section": "heading", "cite": "bibitem",
                 "appendix": "heading", "algorithm": "code"}
        for t in table["targets"]:
            assert t["box"] and blocks[t["block"]]["kind"] == kinds[t["kind"]], t
        assert any(len(t["cited"]) > 1 for t in table["targets"])
        multi = [e for e in table["links"] if len(e["targets"]) > 1]
        assert multi and all(table["targets"][t]["kind"] == "cite" for e in multi for t in e["targets"])


def test_a_page_link_finds_the_block_at_its_point(plain, copy):
    """A link to a page and point (LINK_GOTO, top-left as PyMuPDF gives it), as in a PDF without named destinations:
    the block there, and its kind."""
    paper = copy(plain)
    pdf = paper / "r1/build/main.pdf"
    figure = next(b for b in _blocks(paper) if b["kind"] == "figure")
    page, box = figure["box"]
    doc = pymupdf.open(str(pdf))
    doc[0].insert_link({"kind": pymupdf.LINK_GOTO, "from": pymupdf.Rect(72, 72, 90, 80), "page": page,
                        "to": pymupdf.Point(box[0] + 5, box[1] + 5)})
    doc.save(str(pdf) + ".new")
    doc.close()
    os.replace(str(pdf) + ".new", str(pdf))
    table = links.build(paper, ledger.load(paper), 1, prose.load(paper, 1))
    e = next(e for e in table["links"] if e["via"] == "pdf")
    t = table["targets"][e["targets"][0]]
    assert t["kind"] == "figure" and t["label"] == "Figure 1" and t["box"] == box
    assert t["at"] == [box[0] + 5, box[1] + 5]
