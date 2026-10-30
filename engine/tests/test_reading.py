"""Reading in the PDF view (CONTRACT.md amendment "Reading in the PDF view"): which blocks are read, their places in
the PDF (parts: one rect per column, across column and page breaks, without running heads and feet), the reading
data in state, and changes handled by reading."""
import shutil
from types import SimpleNamespace

import pymupdf
import pytest

from paperole import api, ledger, prose, state
from conftest import quiet, select


# --- running heads and feet, and parts, on synthetic synctex boxes ---------------------------------------------

def _f(page, line, rect, file="main.tex"):
    return page, (file, line), tuple(rect)


def test_running_heads_and_feet():
    head, foot = (108, 27, 504, 39), (108, 751, 504, 763)
    body = [(108, 85 + 11 * i, 504, 94 + 11 * i) for i in range(5)]
    founds = [[_f(p, 10 + i, r) for i, r in enumerate(body)] for p in (0, 1, 2)]
    founds.append([_f(0, 14, head), _f(1, 30, head), _f(0, 14, foot), _f(2, 31, foot)])
    founds.append([_f(1, 40, (108, 400, 504, 409))])  # a one-line paragraph alone mid-page: not a running foot
    founds.append([_f(2, 41, (108, 20, 504, 30))])  # alone at the top of one page only: kept
    run = prose._running(founds, [792.0] * 3)
    assert run == {(0, head), (1, head), (0, foot), (2, foot)}


def test_parts_across_columns_and_pages():
    cols = [[300.0, 396.0], [300.0, 396.0], None, None]
    left = [_f(0, 10 + i // 2, (70, 700 + 13 * i, 290, 709 + 13 * i)) for i in range(5)]  # lines 10-12
    right = [_f(0, 12 + i // 2, (310, 74 + 13 * i, 530, 83 + 13 * i)) for i in range(3)]  # lines 12-13
    note = [_f(0, 11, (70, 790, 290, 796))]  # a footnote well below the main run: no part
    far = [_f(3, 13, (70, 300, 290, 309))]  # two pages on: no part
    parts = prose._parts(left + right + note + far, cols)
    assert parts == [[0, [70, 700, 290, 761]], [0, [310, 74, 530, 109]]]
    # one column: the end of a paragraph at the top of the next page (below a float there) is a part
    main = [_f(2, 5 + i // 3, (108, 650 + 11 * i, 504, 659 + 11 * i)) for i in range(7)]  # lines 5-7
    after = [_f(3, 7, (108, 302, 504, 311)), _f(3, 8, (108, 313, 504, 322))]
    before = [_f(1, 9, (108, 700, 504, 709))]  # on the page before, but its lines come after the main run's: no part
    assert prose._parts(main + after + before, cols) == [[2, [108, 650, 504, 725]], [3, [108, 302, 504, 322]]]
    # the start of a paragraph at the bottom of the page before its main run is a part, listed first
    start = [_f(1, 4, (108, 712, 504, 721)), _f(1, 5, (108, 723, 504, 732))]
    assert prose._parts(start + main, cols)[0] == [1, [108, 712, 504, 732]]
    assert prose._parts([], cols) == []


def test_parts_go_on_with_the_text_not_its_footnote():
    """m20: a paragraph at the foot of the left column goes on at the top of the right one, at whose foot its longer
    footnote is set: the part in the right column is the paragraph's text."""
    cols = [[300.0, 396.0]]
    main = [_f(0, 10 + i // 2, (70, 640 + 13 * i, 290, 649 + 13 * i)) for i in range(6)]  # lines 10-12
    cont = [_f(0, 12 + i, (310, 74 + 13 * i, 530, 83 + 13 * i)) for i in range(2)]  # lines 12-13
    note = [_f(0, 11 + i, (310, 700 + 9 * i, 530, 707 + 9 * i)) for i in range(4)]  # lines 11-14
    def own(run):  # _own_text's score: 1 for the run holding only the footnote's text
        return 1 if run[0][1][1] >= 700 else 2
    assert prose._parts(main + cont + note, cols, own) == [[0, [70, 640, 290, 714]], [0, [310, 74, 530, 96]]]


def test_item_parts_leave_out_the_item_before_and_the_ruler(monkeypatch):
    """synctex gives an item's \\item line the last lines of the item before, and (in ACL's review mode) the margin
    numbers of those lines: they are not the item's."""
    def rows(y0, n):
        return [(108.0, y0 + 12 * i, 504.0, y0 + 9 + 12 * i) for i in range(n)]
    a, b = rows(100, 3), rows(140, 2)
    ruler = [(560.0, r[1], 570.0, r[3]) for r in a]
    boxes = {("main.tex", 1): [(0, r) for r in a], ("main.tex", 2): [(0, r) for r in a[1:] + b + ruler]}
    monkeypatch.setattr(prose.anchor, "line_boxes", lambda pdf: boxes)
    monkeypatch.setattr(prose.anchor, "_stamp", lambda pdf: None)
    monkeypatch.setattr(prose.anchor, "_doc", lambda stamp: [SimpleNamespace(rect=SimpleNamespace(height=792.0))])
    monkeypatch.setattr(prose.anchor, "_words", lambda stamp, page: [])  # no words: every box is kept (_own_text)
    blocks = [{"kind": "item", "_ranges": [("main.tex", 1, 1)]}, {"kind": "item", "_ranges": [("main.tex", 2, 2)]}]
    prose._places(blocks, "main.pdf", [None], [[108.0, 504.0]])
    assert [b["parts"] for b in blocks] == [[[0, [108.0, 100.0, 504.0, 133.0]]], [[0, [108.0, 140.0, 504.0, 161.0]]]]


# --- a typeset two-column paper with a running head ------------------------------------------------------------

def _paragraph(i, n=9):
    """n sentences, one a line; the last ends with \\par, so TeX ships pages out while it reads a line of a paragraph
    (as at a heading or a display formula): synctex then gives that line the running head and foot and the columns."""
    return "\n".join("Paragraph pi{}x keeps sentence {} about warm pools of functions and their cold starts in a "
                     "cluster.".format(i, j) for j in range(n)) + "\\par"


TWOCOL = (r"""\documentclass[twocolumn]{article}
\usepackage{fancyhdr}
\pagestyle{fancy}
\fancyhead[C]{Runninghead of the test paper}
\fancyfoot[C]{\thepage}
\begin{document}
\title{Parts}
\author{A. Author}
\maketitle
\thispagestyle{fancy}
\begin{abstract}
""" + _paragraph(0, 3) + r"""
\end{abstract}
\section{One}
""" + "\n\n".join(_paragraph(i) for i in range(1, 25)) + r"""
\end{document}
""")


@pytest.fixture(scope="module")
def twocol(tmp_path_factory):
    root = tmp_path_factory.mktemp("twocol")
    (root / "src").mkdir()
    (root / "src" / "main.tex").write_text(TWOCOL)
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Parts", "student": "S"}, quiet)
    api.ingest({"paper": str(paper), "source": str(root / "src")}, quiet)
    return paper


def test_parts_in_a_typeset_paper(twocol):
    data, s = prose.load(twocol, 1), state.build(twocol)
    doc = pymupdf.open(twocol / "r1" / "build" / "main.pdf")
    words = [page.get_text("words") for page in doc]
    bands = []  # the running head's and foot's lines
    for p, ws in enumerate(words):
        foot = max(ws, key=lambda w: w[3])
        assert foot[4] == str(p + 1)  # the page number, lowest on the page
        bands += [(p, w[1], w[3]) for w in ws if w[4] == "Runninghead" or w is foot]
    assert len(bands) == 2 * len(doc)
    by_block = {p["block"]: p["parts"] for p in s["reading"]["paragraphs"]}
    pages, columns = set(), set()
    for k, b in enumerate(data["blocks"]):
        token = next((t for t in b["text"].split() if t.startswith("pi") and t.endswith("x")), None)
        if not token:
            continue
        parts = by_block[k]
        mine = [(p, w) for p, ws in enumerate(words) for w in ws if w[4] == token]
        def inside(p, w):
            return any(q == p and r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1 and r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1
                       for q, r in parts)
        assert mine and all(inside(p, w) for p, w in mine), (k, token, parts)  # all of its words, and no other's
        assert not [w for p, ws in enumerate(words) for w in ws if w[4].startswith("pi") and w[4].endswith("x")
                    and w[4] != token and inside(p, w)], (k, token, parts)
        assert not any(q == p and r[1] < y1 and y0 < r[3] for q, r in parts for p, y0, y1 in bands), (k, parts)
        if len(parts) > 1:
            (pages if parts[0][0] != parts[1][0] else columns).add(k)
    assert pages and columns  # paragraphs across a page break and across the column break


def test_reading_data_in_state(twocol):
    data, s = prose.load(twocol, 1), state.build(twocol)
    kinds = {b["kind"] for k, b in enumerate(data["blocks"]) if k in {p["block"] for p in s["reading"]["paragraphs"]}}
    assert kinds == {"paragraph"}  # no title, no heading
    abstract = next(k for k, b in enumerate(data["blocks"]) if "pi0x" in b["text"])
    first = s["reading"]["paragraphs"][0]
    assert first["block"] == abstract and first["section"] == -1 and first["parts"][0][0] == 0
    assert s["reading"]["headings"] == [{"block": next(k for k, b in enumerate(data["blocks"]) if b["kind"] == "heading"),
                                         "level": 1, "title": "1 One", "parts": s["reading"]["headings"][0]["parts"]}]
    assert s["reading"]["headings"][0]["parts"][0][0] == 0
    assert s["reading"]["count"] == 25 and s["reading"]["unread"] == 25


def test_change_read_counts_readable_blocks_only():
    heading = {"kind": "heading", "hash": "h1", "parts": [[0, [1, 2, 3, 4]]], "ins": [[0, 3, "c01"]], "del": [],
               "added": None, "before": None}
    para = {"kind": "paragraph", "hash": "p1", "parts": [[0, [1, 5, 3, 9]]], "ins": [[0, 3, "c01"]], "del": [],
            "added": None, "before": None}
    nowhere = dict(para, hash="p2", parts=[])  # a paragraph with no place in the PDF
    data = {"blocks": [heading, para, nowhere], "changes": {"c01": [0, 1], "c02": [0], "c03": [2]}}
    assert [prose.readable(b) for b in data["blocks"]] == [False, True, False]
    assert prose.change_hashes(data, {"id": "c01"}) == [("p1", True)]
    read = {"p1": 2}
    assert prose.change_read({"kind": "replace"}, prose.change_hashes(data, {"id": "c01"}), read, 2)
    assert not prose.change_read({"kind": "replace"}, prose.change_hashes(data, {"id": "c02"}), read, 2)  # a heading
    assert not prose.change_read({"kind": "replace"}, prose.change_hashes(data, {"id": "c03"}), read, 2)


def test_comment_paragraph_in_state(twocol):
    p = str(twocol)
    pdf = str(twocol / "r1" / "build" / "main.pdf")
    out = api.comment({"paper": p, "page": 0, "rects": select(pdf, 0, "about warm pools"),
                       "text": "about warm pools", "note": "x"}, quiet)
    c = next(c for c in out["state"]["comments"] if c["id"] == out["id"])
    data = prose.load(twocol, 1)
    assert data["blocks"][c["paragraph"]]["kind"] == "paragraph"
    api.delete_comment({"paper": p, "id": out["id"]}, quiet)


# --- list items, margin line numbers and a float set below later paragraphs ------------------------------------

def _item(i, n=2):
    return r"\item " + " ".join("Item pi{}x states claim {} about warm pools of functions and their cold starts in a "
                                 "cluster.".format(i, j) for j in range(n))


ITEMS = (r"""\documentclass{article}
\usepackage{lineno}
\begin{document}
\linenumbers
\section{One}
Paragraph pl0x leads into the list of items below, and it runs on for a while so that it ends inside its second
line of the page:
\begin{itemize}
""" + "\n".join([_item(1), _item(2), _item(3, 1), _item(4, 3), _item(5)]) + r"""
\end{itemize}

""" + _paragraph(6, 3) + r"""
\begin{figure}[b]
\centering
\fbox{\parbox{4cm}{Float body pf7x.}}
\caption{Caption pc7x of the float set at the foot of the page.}
\end{figure}

""" + "\n\n".join(_paragraph(i, 3) for i in range(8, 11)) + r"""
\end{document}
""")


@pytest.fixture(scope="module")
def items(tmp_path_factory):
    root = tmp_path_factory.mktemp("items")
    (root / "src").mkdir()
    (root / "src" / "main.tex").write_text(ITEMS)
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Items", "student": "S"}, quiet)
    api.ingest({"paper": str(paper), "source": str(root / "src")}, quiet)
    return paper


def _token(text):
    return next((t for t in text.split() if t[:2] in ("pi", "pl", "pf") and t.endswith("x")), None)


def test_parts_of_list_items(items):
    """TeX ends an item (or the paragraph leading into the list) while it reads the next \\item line, so synctex
    gives that line the earlier block's last lines, and lineno's numbers of them: an item's parts hold its own words
    only, and no part reaches the margin numbers."""
    data, s = prose.load(items, 1), state.build(items)
    page = pymupdf.open(items / "r1" / "build" / "main.pdf")[0]
    words = page.get_text("words")
    numbers = [w for w in words if w[4].isdigit() and w[2] < 130]  # the text starts at x 133.8
    assert len(numbers) >= 20  # lineno's numbers in the left margin
    by_block = {p["block"]: p["parts"] for p in s["reading"]["paragraphs"]}
    checked = 0
    for k, b in enumerate(data["blocks"]):
        token = _token(b["text"]) if b["kind"] in ("item", "paragraph") else None
        if not token:
            continue
        parts = by_block[k]
        def inside(w):
            return any(q == 0 and r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1 and r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1
                       for q, r in parts)
        assert all(inside(w) for w in words if w[4].strip(",.:") == token), (k, token, parts)
        others = [w[4] for w in words if _token(w[4]) and w[4].strip(",.:") != token and inside(w)]
        assert not others, (k, token, parts, others)
        assert not [w for w in numbers if inside(w)], (k, token, parts)
        checked += b["kind"] == "item"
    assert checked == 5


def test_paragraphs_in_printed_order(items):
    """reading.paragraphs are in the order they are printed: the float set at the foot of the page comes after the
    paragraphs that follow it in the source."""
    data, s = prose.load(items, 1), state.build(items)
    ps = s["reading"]["paragraphs"]
    places = [(p["parts"][0][0], p["parts"][0][1][1]) for p in ps]
    assert places == sorted(places)
    fig = next(k for k, b in enumerate(data["blocks"]) if b["kind"] == "figure")
    order = [p["block"] for p in ps]
    assert order.index(fig) == len(order) - 1 and fig < max(order)  # printed last, though not last in the source


def test_comment_in_a_float_is_in_its_block(items):
    """A float's display text is its caption only; a comment on other text in it (a table cell) is still in it."""
    p, pdf = str(items), str(items / "r1" / "build" / "main.pdf")
    out = api.comment({"paper": p, "page": 0, "rects": select(pdf, 0, "Float body pf7x."), "text": "Float body pf7x.",
                       "note": "x"}, quiet)
    c = next(c for c in out["state"]["comments"] if c["id"] == out["id"])
    assert prose.load(items, 1)["blocks"][c["paragraph"]]["kind"] == "figure"
    api.delete_comment({"paper": p, "id": out["id"]}, quiet)


# --- last lines holding a single word ----------------------------------------------------------------------------

def _words(n):
    words = "warm pools of functions keep their cold starts short in a busy cluster while forecasts".split()
    return " ".join(words[j % len(words)] for j in range(n))


# Times, as in ICLR: a last line holding only a year has no kern or glue of its own source line, so synctex gives
# its box to the line that ends the paragraph (the blank line after it, the next \item, \end{itemize})
TAILS = (r"""\documentclass{article}
\usepackage{times}
\begin{document}
\section{One}
""" + "\n\n".join("Paragraph pv{}x says {} in {}.".format(i, _words(30 + i), 2000 + i) for i in range(16)) + r"""

\begin{itemize}
""" + "\n".join("\\item Item pv{}x says {} in {}.".format(i, _words(i - 6), 2000 + i) for i in range(20, 32)) + r"""
\end{itemize}
\end{document}
""")


def test_last_lines_of_one_word(tmp_path):
    """A paragraph's or item's last line holding a single word is in its own block's parts (the bar was a line short,
    and the next item's began a line early)."""
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "main.tex").write_text(TAILS)
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "Tails", "student": "S"}, quiet)
    api.ingest({"paper": str(paper), "source": str(tmp_path / "src")}, quiet)
    data = prose.load(paper, 1)
    doc = pymupdf.open(paper / "r1" / "build" / "main.pdf")
    alone, checked = set(), 0
    for k, b in enumerate(data["blocks"]):
        if b["kind"] not in ("paragraph", "item"):
            continue
        year = str(2000 + int(b["text"].split()[1][2:-1])) + "."
        for p, page in enumerate(doc):
            words = page.get_text("words")
            for w in (w for w in words if w[4] == year):
                if len([v for v in words if abs(v[1] - w[1]) < 1]) == 1:
                    alone.add(b["kind"])
                holders = [j for j, c in enumerate(data["blocks"]) if any(
                    q == p and r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1 and r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1
                    for q, r in c["parts"])]
                assert holders == [k], (k, year, holders, b["parts"])
                checked += 1
    assert checked == 28 and alone == {"paragraph", "item"}


# --- a .bbl in a moved review folder ---------------------------------------------------------------------------

BIB = r"""\documentclass{article}
\begin{document}
Warm pools help \cite{lee2024}, and so do forecasts \cite{kim2025}.
\bibliographystyle{plain}
\bibliography{refs}
\end{document}
"""
REFS = r"""@inproceedings{lee2024, author={A. Lee}, title={Pools at scale}, booktitle={Proc. ATC}, year={2024}}
@article{kim2025, author={B. Kim}, title={Forecasting arrivals}, journal={J. Sys.}, year={2025}}
"""


def test_references_of_a_moved_folder(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "main.tex").write_text(BIB)
    (tmp_path / "src" / "refs.bib").write_text(REFS)
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "Bib", "student": "S"}, quiet)
    api.ingest({"paper": str(paper), "source": str(tmp_path / "src")}, quiet)
    moved = tmp_path / "elsewhere" / "paper"
    shutil.copytree(paper, moved)
    shutil.rmtree(paper)  # synctex still names the old folder's .bbl
    (moved / "r1" / "prose.json").unlink()
    api.prose_({"paper": str(moved)}, quiet)
    items = [b for b in prose.load(moved, 1)["blocks"] if b["kind"] == "bibitem"]
    assert len(items) == 2 and all(prose.readable(b) for b in items)
    assert ledger.load(moved)["rounds"][0]["build"]["pdf"]
