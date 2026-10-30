"""Layouts that broke anchoring in ICLR's review mode (2026-10-14), rebuilt as small
synthetic papers: line numbers drawn in the margin when each page is shipped out, a display equation right after a
page break, a cell of a scaled table, a reference list written by BibTeX, and a click note on a blank line. Also the
text extent per page that keeps the app's drag selections out of the margin ruler (2026-10-15), and the ruler's
bounds the app places id labels beside (2026-10-24)."""
import os
import shutil
from pathlib import Path

import pymupdf
import pytest

from paperole import anchor, comments, ledger, project, state, texdiff

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

# A margin ruler drawn over every page at shipout, as the review modes of ICLR and NeurIPS do: 55 numbers in the
# left margin, 12 pt apart, that do not line up with the text lines.
RULER = r"""\usepackage{eso-pic}
\newcount\rulerline
\AddToShipoutPicture{\AtTextUpperLeft{\rulerline=0
  \loop\ifnum\rulerline<55
    \put(-25,-\the\numexpr12*\rulerline+8\relax){\makebox(0,0)[r]{\small\the\numexpr100*\value{page}+\rulerline\relax}}%
    \advance\rulerline 1
  \repeat}}
"""
PARAGRAPHS = r"""\section{Introduction}
Serverless platforms start a fresh sandbox for every cold invocation, and the
delay this adds is the main complaint of developers who run latency-sensitive
services on them. Keeping instances warm hides the delay but costs memory.

A simple keep-alive policy holds every instance for a fixed window after its
last request. It is cheap to run and easy to explain, yet it wastes memory on
functions that are called rarely and still misses many cold starts.

\section{Design}
The controller runs once per interval. It reads the recent arrival counts of
each function, updates a smoothed rate estimate, and resizes the warm pool to
the smallest size whose predicted cold-start rate is below the target.
"""


def _build(root, files, preamble=""):
    """(src, pdf) of a one-file article (files["body"]) plus other files, compiled as ingest does."""
    src = root / "src"
    src.mkdir(parents=True)
    for name, text in files.items():
        if name == "body":
            name, text = "main.tex", ("\\documentclass{article}\n" + preamble + "\\begin{document}\n" + text
                                      + "\\end{document}\n")
        (src / name).write_text(text)
    build = project.compile(src, root / "build", "main.tex", "pdflatex")
    assert build["status"] != "failed", build
    return src, Path(build["pdf"])


def _item(text, phrase, cid="R1-01", hint=""):
    """A carried comment's record on phrase (CONTRACT.md §4, the keys carry reads)."""
    s = text.index(phrase)
    a = {"file": "main.tex", "start": s, "end": s + len(phrase), "quote": phrase, "prefix": text[max(0, s - 40):s],
         "suffix": text[s + len(phrase):s + len(phrase) + 40], "text": hint}
    return {"id": cid, "anchor": a, "last": a}


def _covers(rects, r):
    x, y = (r[0] + r[2]) / 2, (r[1] + r[3]) / 2
    return any(a[0] <= x <= a[2] and a[1] <= y <= a[3] for a in rects)


def test_margin_line_numbers_are_not_text(tmp_path):
    src, pdf = _build(tmp_path, {"body": PARAGRAPHS}, RULER)
    words = pymupdf.open(pdf)[0].get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP)
    ruler = comments.margin_numbers(words)
    assert len(ruler) == 55 and {words[k][4] for k in ruler} == {str(100 + k) for k in range(55)}
    lines = {}
    for w in comments.body_words(words):
        lines.setdefault((w[5], w[6]), []).append(w)
    for line in lines.values():
        if len(line) < 3:  # a heading or the page number
            continue
        # a note clicked on a text line anchors to that line, as synctex has it at the click
        x, y = line[-1][2] - 1, (line[-1][1] + line[-1][3]) / 2
        a, method, _ = comments.locate(src, pdf, 0, [[x, y, x, y]], "")
        assert ((a["file"], a["lines"][0]), method) == (comments._synctex(pdf, 0, x, y, src), "line")
    # a drag that starts in the margin selects the text lines, not the numbers beside them
    first = next(line for line in lines.values() if line[0][4] == "Serverless")
    rect = [20, first[0][1], 500, first[0][3] + 12]
    a, method, _ = comments.locate(src, pdf, 0, [rect], "")
    assert method == "selection" and a["text"].startswith("Serverless platforms start")
    assert not any(t.isdigit() for t in a["text"].split())


def test_a_column_of_numbers_in_a_table_is_text():
    """A page with only a table whose first column holds years, left of every other word: no margin ruler."""
    words = [(200, 300 + 12 * k, 220, 308 + 12 * k, str(2019 + k), 0, k, 0) for k in range(6)]
    words += [(260, 300 + 12 * k, 280, 308 + 12 * k, "{}.5".format(k), 0, k, 1) for k in range(6)]
    words += [(240, 380, 330, 388, "Table", 1, 0, 0), (303, 700, 308, 708, "7", 2, 0, 0)]
    assert comments.margin_numbers(words) == set()
    ruler = [(80, 100 + 12 * k, 90, 108 + 12 * k, str(k), 3, k, 0) for k in range(50)]  # beside them, down the page
    assert comments.margin_numbers(ruler + words) == set(range(50))


def test_a_short_ruler_beside_a_float():
    """ACL review mode numbers only the text lines of a column: on a page whose column starts with a float, its ruler
    is short, but it counts up by one. Fewer than RULER_RUN numbers that are not half the page high stay text."""
    body = [(306, 60 + 13.6 * k, 526, 70 + 13.6 * k, "text", k, 0, 0) for k in range(52)]
    ruler = [(566, 420 + 13.6 * k, 580, 430 + 13.6 * k, "{:03d}".format(68 + k), 100 + k, 0, 0) for k in range(26)]
    assert comments.margin_numbers(ruler + body) == set(range(26))
    assert comments.margin_numbers(ruler[:comments.RULER_RUN - 1] + body) == set()
    skipped = ruler[:5] + ruler[6:]  # not counting up by one
    assert comments.margin_numbers(skipped + body) == set()


def test_text_x_is_the_body_text_without_the_ruler(tmp_path):
    """A page with a margin ruler, a running head, two columns of text and a page number; then a blank page."""
    doc = pymupdf.open()
    page = doc.new_page(width=612, height=792)
    for k in range(55):
        page.insert_text((73, 80 + 12 * k), "{:03d}".format(k), fontsize=8)
    page.insert_text((108, 40), "Preprint", fontsize=10)
    for k in range(50):
        page.insert_text((108, 90 + 12 * k), "words of the left column", fontsize=10)
        page.insert_text((318, 90 + 12 * k), "words of the right column, a little longer", fontsize=10)
    page.insert_text((303, 760), "1", fontsize=10)
    doc.new_page(width=612, height=792)
    pdf = tmp_path / "two-column.pdf"
    doc.save(pdf)

    words = pymupdf.open(pdf)[0].get_text("words")
    assert len(comments.margin_numbers(words)) == 55
    [(x0, x1), blank] = comments.text_x(pdf)
    assert x0 == pytest.approx(108, abs=0.5)  # not the ruler's 73
    assert x1 == round(max(w[2] for w in words if w[0] >= 318), 2) and x1 > 450  # the right column's edge
    assert blank is None


def test_rulers_are_the_margin_numbers_beside_text_x(tmp_path):
    """Per page the bounds of the line numbers left and right of text_x, so the app places id labels without reading
    the page's text (A2-10): a ruler on the left, one on the right, one on each side, and a blank page."""
    pages = (((73,), [True, False]), ((530,), [False, True]), ((40, 540), [True, True]))
    doc = pymupdf.open()
    for sides, _ in pages:
        page = doc.new_page(width=612, height=792)
        page.insert_text((108, 40), "Preprint", fontsize=10)
        for k in range(50):
            page.insert_text((108, 90 + 12 * k), "words of a line of the text", fontsize=10)
            for x in sides:
                page.insert_text((x, 92 + 12 * k), "{:03d}".format(k + 1), fontsize=8)
    doc.new_page(width=612, height=792)
    pdf = tmp_path / "rulers.pdf"
    doc.save(pdf)

    def bounds(ws):
        return [round(f(w[k] for w in ws), 2) for k, f in ((0, min), (1, min), (2, max), (3, max))] if ws else None
    lay = comments.layout(pdf)
    for i, (sides, has) in enumerate(pages):
        words = pymupdf.open(pdf)[i].get_text("words")
        ruler = comments.margin_numbers(words)
        nums, body = [words[k] for k in ruler], [w for k, w in enumerate(words) if k not in ruler]
        assert len(nums) == 50 * len(sides)
        tx = lay["text_x"][i]
        assert tx == bounds(body)[::2] and tx[0] == 108
        left, right = lay["rulers"][i]
        assert [left is not None, right is not None] == has
        assert [left, right] == [bounds([w for w in nums if w[2] < tx[0]]), bounds([w for w in nums if w[0] > tx[1]])]
        # with text_x they span all of the page's words, as PDFPane took them from PDFKit
        xs = tx + [x for r in (left, right) if r for x in r[::2]]
        assert [min(xs), max(xs)] == bounds(words)[::2]
    assert lay["text_x"][3] is None and lay["rulers"][3] is None


@pytest.mark.parametrize("key", ["text_x", "rulers"])
def test_text_x_and_rulers_are_stored_at_ingest_and_given_in_state(paper, key):
    b = ledger.load(paper)["rounds"][0]["build"]
    assert len(b[key]) == b["pages"] and b[key] == comments.layout(paper / b["pdf"])[key]
    assert state.build(paper)["round"]["build"][key] == b[key]
    with ledger.edit(paper) as lg:  # a round ingested before it was stored
        del lg["rounds"][0]["build"][key]
    assert state.build(paper)["round"]["build"][key] == b[key]


def test_a_click_note_takes_the_line_in_its_own_column(tmp_path):
    src, pdf = _build(tmp_path, {"body": "\\twocolumn\n" + PARAGRAPHS * 3})
    page = pymupdf.open(pdf)[0]
    right = {}
    for w in page.get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP):
        if w[0] > page.rect.width / 2:
            right.setdefault((w[5], w[6]), []).append(w)
    lines = [line for line in right.values() if len(line) >= 3]
    assert len(lines) >= 10
    for line in lines:  # each beside a line of the left column at the same height
        x, y = line[-1][2] - 1, (line[-1][1] + line[-1][3]) / 2
        a, _, _ = comments.locate(src, pdf, 0, [[x, y, x, y]], "")
        assert (a["file"], a["lines"][0]) == comments._synctex(pdf, 0, x, y, src)


def test_an_equation_after_a_page_break_stays_on_its_page(tmp_path):
    filler = "".join("Filler sentence number {} says nothing new and only takes some room in the text of this page.\n"
                     .format(k) for k in range(40))
    body = ("\\section{Model}\n" + filler + "Starting from the cold starts before the change, the final number of "
            "cold starts is then\n\\begin{equation}\nN_{\\mathrm{after}}\n=\nN_{\\mathrm{before}}\n-\nN_{\\mathrm{fixed}}.\n"
            "\\label{eq:main}\n\\end{equation}\nAfter the equation the text goes on for a while.\n")
    src, pdf = _build(tmp_path, {"body": body}, RULER)
    text = (src / "main.tex").read_text()
    doc = pymupdf.open(pdf)
    [(page, equation)] = [(p, r) for p in range(doc.page_count) for r in doc[p].search_for("Nafter")[:1]]
    # the page before the equation was shipped out while TeX read the equation, so synctex gives these lines
    # that page's margin ruler too (boxes from the page's corner)
    stamp = anchor._stamp(pdf)
    name = anchor._inputs(stamp, str(src))["main.tex"]
    begin = text[:text.index("\\begin{equation}")].count("\n") + 1
    boxes = [pb for ln in range(begin, begin + 4) for pb in anchor._line_boxes(stamp, name, ln)]
    assert any(p != page and b[0] <= 0 for p, b in boxes)

    phrase = text[text.index("\\begin{equation}"):text.index("\\end{equation}") + len("\\end{equation}")]
    records, _ = anchor.carry(src, src, pdf, texdiff.diff_trees(src, src), [_item(text, phrase)])
    r = records["R1-01"]
    a = r["anchor"]
    assert (r["anchor_state"], a["page"], len(a["rects"])) == ("unchanged", page, 1)
    rect = a["rects"][0]
    assert _covers([rect], equation) and rect[3] - rect[1] < 20 and rect[0] > 100  # the equation's line only
    assert a["text"] == "Nafter = Nbefore −Nfixed. (1)"


def test_a_cell_of_a_scaled_table(tmp_path):
    def body(cell):  # 25 rows over 3 lines each: the table's paragraph is longer than 60 lines
        rows = "".join("Policy variant {}\n  & {}.{:02d} & 30.75 & 29.84\n  & 33.12 & 32.40 & 31.95 & {} \\\\\n"
                       .format(k, 20 + k, k, {20: cell, 5: "\\ref{tab:main}"}.get(k, "31.{:02d}".format(k)))
                       for k in range(25))
        return ("\\section{Results}\n\\begin{table}[h]\n\\centering\n\\caption{Cold-start rate of each policy.}"
                "\\label{tab:main}\n\\begin{adjustbox}{max width=\\textwidth}\n\\begin{tabular}{lccccccc}\n"
                "Policy & Azure trace of day one & Azure trace of day two & Azure trace of day three\n  & Huawei trace "
                "of day one & Huawei trace of day two & Huawei trace of day three & Average \\\\\n" + rows
                + "\\end{tabular}\n\\end{adjustbox}\n"
                "\\end{table}\nThe predictive pools have the lowest rate on every trace.\n")
    old, old_pdf = _build(tmp_path / "v1", {"body": body("12.92")}, "\\usepackage{adjustbox}\n")
    new, new_pdf = _build(tmp_path / "v2", {"body": body("12.95")}, "\\usepackage{adjustbox}\n")
    cell = pymupdf.open(new_pdf)[0].search_for("12.95")[0]
    width = pymupdf.open(new_pdf)[0].rect.width

    text = (old / "main.tex").read_text()
    records, changes = anchor.carry(old, new, new_pdf, texdiff.diff_trees(old, new),
                                    [_item(text, "12.92"), _item(text, "\\ref{tab:main}", "R1-02")])
    a = records["R1-01"]["anchor"]
    assert (records["R1-01"]["anchor_state"], a["quote"], a["page"], a["text"]) == ("changed", "12.95", 0, "12.95")
    [change] = changes
    for rects in (a["rects"], change["rects"]):  # on the cell, not on the row's unscaled box past the page edge
        assert len(rects) == 1 and _covers(rects, cell) and rects[0][2] - rects[0][0] < 20 and rects[0][2] <= width
    # a cell that prints nothing of its own gets its row's unscaled box, clipped to the page
    rects = records["R1-02"]["anchor"]["rects"]
    assert rects and all(0 <= r[0] and r[2] <= width for r in rects)


def test_a_reference_list_comment_follows_the_bbl(tmp_path):
    body = ("Serverless platforms start a sandbox for each cold call~\\cite{agache}, and keeping instances warm "
            "costs memory~\\cite{shahrad}.\n\n\\bibliographystyle{plain}\n\\bibliography{refs}\n")
    bib = ("@inproceedings{agache, author = {Alexandru Agache and Marc Brooker}, title = {Firecracker: Lightweight "
           "Virtualization for Serverless Applications}, booktitle = {NSDI}, year = {2020}}\n"
           "@inproceedings{shahrad, author = {Mohammad Shahrad and Rodrigo Fonseca}, title = {{Serverless in the "
           "Wild}: Characterizing and Optimizing the Serverless Workload}, booktitle = {USENIX ATC}, year = {2020}}\n")
    old, old_pdf = _build(tmp_path / "v1", {"body": body, "refs.bib": bib})
    new, new_pdf = _build(tmp_path / "v2", {"body": body,
                                            "refs.bib": bib.replace("Virtualization", "Virtual Machines")})
    phrase = "Lightweight virtualization for serverless applications."
    a, method, _ = comments.locate(old, old_pdf, 0, [list(r) for r in pymupdf.open(old_pdf)[0].search_for(phrase)],
                                   phrase)
    assert (a["file"], a["quote"], method) == ("main.bbl", phrase, "selection")

    # a comment from before .bbl files were anchored to: its \bibliography line prints nothing of its own
    tex = (old / "main.tex").read_text()
    other = "Characterizing and optimizing the serverless workload."
    items = [{"id": "R1-01", "anchor": a, "last": a}, _item(tex, "\\bibliography{refs}", "R1-02", other)]
    diff = texdiff.diff_trees(old, new, old.parent / "build", new.parent / "build")
    records, changes = anchor.carry(old, new, new_pdf, diff, items)
    page = pymupdf.open(new_pdf)[0]
    r = records["R1-01"]
    assert (r["anchor_state"], r["anchor"]["file"], r["anchor"]["quote"]) == \
        ("changed", "main.bbl", "Lightweight virtual machines for serverless applications.")
    assert _covers(r["anchor"]["rects"], page.search_for("virtual machines")[0])
    [change] = changes  # the student's .bib edit, as BibTeX printed it
    assert (change["file"], change["kind"], change["old_text"], change["new_text"], change["attached_to"]) == \
        ("main.bbl", "replace", "virtualization", "virtual machines", ["R1-01"])
    assert change["page"] == 0 and _covers(change["rects"], page.search_for("machines")[0])
    r = records["R1-02"]  # found by its last known text, not drawn on the line boxes of \bibliography
    assert (r["anchor_state"], r["anchor"]["text"]) == ("unchanged", other)
    assert _covers(r["anchor"]["rects"], page.search_for("workload.")[0])


def test_a_click_note_on_a_blank_line_is_never_a_point(paper, monkeypatch):
    src, pdf = paper / "r1" / "src", paper / "r1" / "build" / "main.pdf"
    text = (src / "main.tex").read_text()
    rows = text.split("\n")
    blank = next(k for k in range(2, len(rows)) if not rows[k - 1].strip() and rows[k - 2].strip()
                 and not rows[k - 2].lstrip().startswith(("%", "\\")))
    monkeypatch.setattr(comments, "_synctex", lambda *args: ("main.tex", blank))  # where a paragraph ended
    a, method, confidence = comments.locate(src, pdf, 0, [[300, 500, 300, 500]], "")
    assert (a["lines"], a["quote"], method, confidence) == ([blank - 1] * 2, rows[blank - 2].strip(), "line", 0.5)
    monkeypatch.undo()
    records, _ = anchor.carry(src, src, pdf, texdiff.diff_trees(src, src), [{"id": "R1-01", "anchor": a, "last": a}])
    assert records["R1-01"]["anchor_state"] == "unchanged"  # not "gone": nothing was deleted
