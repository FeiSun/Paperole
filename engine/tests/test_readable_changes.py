"""Changes in words and margin leaders (BACKLOG O14, O15, O16, O18; 2026-10-16), on small synthetic papers: an
\\input line renamed or commented out reads as what happened to its file (with a crop of a removed figure), an edit
that prints the same text reads "Formatting only", a change in a table names it ("Table 2"), the summary pages have
the paper's own page size, and leaders cross a margin ruler between its numbers."""
import json
import os
import shutil

import pymupdf
import pytest

from conftest import quiet, select
from paperole import api, ledger, render, state

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

MAIN = r"""\documentclass{article}
\usepackage{graphicx}
\begin{document}
\section{Introduction}
Serverless platforms start a fresh sandbox for every cold invocation, and the delay this adds is the main complaint
of developers who run latency-sensitive services on them.
\begin{table}[h]\centering
\caption{Cold starts per hour in the first study of the pools.}\label{tab:first}
\begin{tabular}{lr} Pool & Size \\ alpha & 11 \\ beta & 7 \\ \end{tabular}
\end{table}
\input{sections/setup}
\input{figs/plot}
\input{tables/results}
\input{sections/old_name}
\end{document}
"""
SETUP = r"""\section{Method}
\subsection{Setup}
\textbf{Setup.} We run every policy on the same trace of requests for a full week of traffic, and we repeat each run
three times with different seeds so that the numbers below are averages.
"""
FIGURE = r"""\begin{figure}[h]\centering
\includegraphics[width=5cm]{figs/plot.pdf}
\caption{Cold starts per hour under each policy.}\label{fig:plot}
\end{figure}
"""
TABLE = r"""\begin{table}[h]\centering
\caption{Cold starts per hour for each of the policies.}\label{tab:results}
\begin{tabular}{lr} Policy & Cold starts \\ keep-alive & 4.25 \\ predictive & 1.75 \\ \end{tabular}
\end{table}
"""
CONCLUSION = r"""\section{Conclusion}
A predictive pool removes most cold starts at a small cost in memory, and the policy is cheap to run.
"""


def _picture():
    doc = pymupdf.open()
    page = doc.new_page(width=200, height=100)
    page.draw_rect(pymupdf.Rect(5, 5, 195, 95), color=(0, 0, 0), fill=(0.8, 0.9, 1.0))
    page.insert_text((20, 55), "Plot", fontsize=16)
    return doc.tobytes()


def _write(root, files):
    root.mkdir(parents=True)
    for name, data in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data) if isinstance(data, bytes) else path.write_text(data)
    return root


@pytest.fixture(scope="module")
def two_rounds(tmp_path_factory):
    """Round 2 of a paper whose student renamed a section file (and its \\input), commented out the \\input of a
    figure, put \\noindent before a run-in heading, and changed a number in each of two tables; round 2 finished."""
    root = tmp_path_factory.mktemp("readable")
    v1 = {"main.tex": MAIN, "sections/setup.tex": SETUP, "figs/plot.tex": FIGURE, "figs/plot.pdf": _picture(),
          "tables/results.tex": TABLE, "sections/old_name.tex": CONCLUSION}
    v2 = dict(v1, **{"main.tex": MAIN.replace("\\input{figs/plot}", "% \\input{figs/plot}")
                     .replace("{sections/old_name}", "{sections/new_name}").replace("alpha & 11", "alpha & 12"),
                     "sections/setup.tex": SETUP.replace("\\textbf{Setup.}", "\\noindent\\textbf{Setup.}"),
                     "tables/results.tex": TABLE.replace("1.75", "1.80"), "sections/new_name.tex": CONCLUSION})
    del v2["sections/old_name.tex"]
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Warm pools", "student": "Lin Zhou"}, quiet)
    for k, files in ((1, v1), (2, v2)):
        api.ingest({"paper": str(paper), "source": str(_write(root / "v{}".format(k), files))}, quiet)
        if k == 1:
            api.finish({"paper": str(paper)}, quiet)
    st = api.state_({"paper": str(paper)}, quiet)["state"]
    api.finish({"paper": str(paper)}, quiet)
    return paper, st


def _by_text(st):
    return {(ch.get("about") or {}).get("text") or ch["old_text"] + " -> " + ch["new_text"]: ch for ch in st["changes"]}


def test_input_lines_and_formatting_in_words(two_rounds):
    paper, st = two_rounds
    changes = _by_text(st)
    renamed = changes["Section file sections/old_name.tex renamed to sections/new_name.tex"]
    assert renamed["about"]["kind"] == "file" and renamed["kind"] == "replace"
    removed = changes["Figure 'plot' removed"]
    assert removed["kind"] == "delete"
    before = removed["context"]["before"]  # a crop of the figure as round 1 printed it: picture and caption
    assert before["display"] == "image" and before["page"] is not None
    page = pymupdf.open(paper / "r1/build/main.pdf")[before["page"]]
    caption = page.search_for("Cold starts per hour under")[0]
    picture = max((pymupdf.Rect(r) for kind, r in page.get_bboxlog() if kind.endswith("path")), key=lambda r: r.width)
    assert picture.width > 100 and picture.contains(page.search_for("Plot")[0])  # the picture's frame
    assert pymupdf.Rect(before["clip"]).contains(caption) and pymupdf.Rect(before["clip"]).contains(picture)
    formatting = changes["Formatting only: no printed text changed in §2.1"]
    assert formatting["about"]["kind"] == "formatting" and formatting["file"] == "sections/setup.tex"
    # a change in a table is named after it, from its caption in this round's PDF (the \input file's table is 2;
    # both captions start "Cold starts per hour")
    tables = {ch["new_text"]: ch["float"] for ch in st["changes"] if ch["file"] != "sections/setup.tex"
              and not ch.get("about")}
    assert tables == {"12": "Table 1", "80": "Table 2"}
    assert all(ch["float"] is None for ch in st["changes"] if ch.get("about"))


def test_summary_and_margin_say_it_without_latex(two_rounds):
    paper, _ = two_rounds
    final, build = pymupdf.open(paper / "r2/final.pdf"), pymupdf.open(paper / "r2/build/main.pdf")
    offset = final.page_count - build.page_count
    summary = " ".join(" ".join(final[k].get_text() for k in range(offset)).split())
    for said in ("Section file sections/old_name.tex renamed to sections/new_name.tex", "Figure 'plot' removed",
                 "Formatting only: no printed text changed in §2.1", "Table 1: “11” → “12”",
                 "Table 2: “1.75” → “1.80”"):
        assert said in summary, said
    assert "\\input" not in summary and "\\noindent" not in summary and "old_name”" not in summary
    # the summary has the paper's own page size, so it prints at 100% (the paper pages are widened)
    assert all(final[k].rect == build[0].rect for k in range(offset))
    assert final[offset].rect.width == build[0].rect.width + render.MARGIN
    # each margin line of a change no comment asked for says the same
    margin = " ".join(" ".join(final[k].get_text() for k in range(offset, final.page_count)).split())
    assert "your change · Table 2: “1.75” → “1.80”" in margin and "your change · Formatting only" in margin


def test_older_analysis_gets_its_words(two_rounds):
    """An analysis.json written before "about" and "float" were stored: state works them out (once per process)."""
    paper, st = two_rounds
    path = paper / "r2/analysis.json"
    data = json.loads(path.read_text())
    for ch in data["changes"]:
        ch.pop("about"), ch.pop("float")
    path.write_text(json.dumps(data))
    state._CHANGES.clear()
    again = state.build(paper, 2)
    assert [(ch["about"], ch["float"]) for ch in again["changes"]] == [(ch["about"], ch["float"]) for ch in st["changes"]]
    assert [ch["context"] for ch in again["changes"]] == [ch["context"] for ch in st["changes"]]


# A review ruler on both sides of a two-column page, as ACL's review mode prints: numbers 12 pt apart, about level
# with the text lines, 40 pt out in the left margin beside the left column and in the right margin beside the
# right one (an ID chip fits between them and the text).
RULER = r"""\usepackage{eso-pic}
\newcount\rulerline
\AddToShipoutPicture{\AtTextUpperLeft{\rulerline=0
  \loop\ifnum\rulerline<55
    \put(-40,-\the\numexpr12*\rulerline+8\relax){\makebox(0,0)[r]{\scriptsize\the\numexpr100+\rulerline\relax}}%
    \put(\the\numexpr\textwidth/65536+40\relax,-\the\numexpr12*\rulerline+8\relax){\makebox(0,0)[l]{%
      \scriptsize\the\numexpr200+\rulerline\relax}}%
    \advance\rulerline 1
  \repeat}}
"""
ZONE = ("In the {0} zone, serverless platforms start a fresh sandbox for every cold invocation. Requests in the {0} "
        "zone are short and arrive in bursts. A keep-alive policy for the {0} zone holds each instance for a fixed "
        "window after its last request.")
ZONES = "amber basalt cedar dune ember fjord garnet harbor indigo jasper kelp lagoon meadow nectar".split()


def _crosses(points, rect):
    """Whether a polyline comes inside rect (sampled every 0.2 pt)."""
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        steps = max(1, int(max(abs(x1 - x0), abs(y1 - y0)) / 0.2))
        if any(rect.contains(pymupdf.Point(x0 + (x1 - x0) * k / steps, y0 + (y1 - y0) * k / steps))
               for k in range(steps + 1)):
            return True
    return False


def test_leaders_pass_between_ruler_numbers(tmp_path):
    src = _write(tmp_path / "src", {"main.tex": "\\documentclass[twocolumn]{article}\n" + RULER
                                    + "\\begin{document}\n" + "\n\n".join(ZONE.format(z) for z in ZONES)
                                    + "\n\\end{document}\n"})
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "Ruler", "student": "Lin Zhou"}, quiet)
    pdf = api.ingest({"paper": str(paper), "source": str(src)}, quiet)["state"]["round"]["build"]["pdf"]
    build = pymupdf.open(pdf)[0]
    numbers = [w for w in build.get_text("words") if w[4].isdigit() and len(w[4]) == 3]
    assert len(numbers) > 80  # both rulers
    ids = []
    for z in ZONES:  # a highlight on a sentence of each zone on page 1, and a note clicked below its last line
        try:
            rects = select(pdf, 0, "Requests in the {} zone".format(z))
        except AssertionError:  # on page 2, or hyphenated
            continue
        ids.append(api.comment({"paper": str(paper), "page": 0, "rects": rects, "text": "", "note": "Shorter.",
                                "kind": "highlight"}, quiet)["id"])
        x, y = rects[-1][2], rects[-1][3] + 0.5
        ids.append(api.comment({"paper": str(paper), "page": 0, "rects": [[x, y, x, y]], "text": "",
                                "note": "Add a number.", "kind": "note"}, quiet)["id"])
    assert len(ids) >= 16
    placed = [p for p in render.final_pdf(paper, ledger.load(paper), 1, tmp_path / "final.pdf") if p["page"] == 0]
    assert {p["side"] for p in placed} == {"L", "R"} and len(placed) == len(ids)
    dx = render.MARGIN
    boxes = [pymupdf.Rect(w[:4]) + (dx - 1, -1, dx + 1, 1) for w in numbers]  # 1 pt clear of every number
    gap = (build.rect.width / 2) + dx
    for p in placed:
        pts, chip = p["leader"], p["chip"]
        assert not any(_crosses(pts, b) for b in boxes), (p["id"], pts)
        # it starts at its chip's side, and stays out of the text (beside its column)
        x0, y0 = pts[0]
        assert abs(x0 - (chip.x1 + 0.5 if p["side"] == "R" else chip.x0 - 0.5)) < 0.01 and chip.y0 < y0 < chip.y1
        assert all(x >= chip.x1 for x, _ in pts) if p["side"] == "R" else all(x <= chip.x0 for x, _ in pts)
        assert (chip.x0 > gap) == (p["side"] == "R")


def test_gap_between_numbers():
    boxes = [(100, 108), (112.5, 120.5), (124, 132), (140, 141)]
    assert render._gap(boxes, 109) == 110.25  # a narrow gap: its middle
    assert render._gap(boxes, 130) == 135  # never inside a box: the nearest place 3 pt clear in the gap below
    assert render._gap(boxes, 134) == 135  # a wide gap: 3 pt from the box above
    assert render._gap(boxes, 99) == 97  # above them all: 3 pt clear
    assert render._gap([(100, 108), (109, 117)], 109) == 120  # under 2 pt: not used
