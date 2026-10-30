"""Template robustness (BACKLOG O11, 2026-10-16): defects found by three-round reviews of synthetic papers in the
advisor's venues (ACM sigconf and acmsmall, ACL, ICLR, ICML 2026, NeurIPS 2026), rebuilt here as small papers with
the article class, fancyhdr and the installed acmart: comments on acmart's teaser, author block and keywords, the
places of paragraphs when TeX ships a page out (footers, float cells, footnotes, lineno numbers and acmart's title
block), captions next to a replaced figure or a narrower float, and the bracket that closes ICML's title block."""
import os
import re
import shutil
from pathlib import Path

import pymupdf
import pytest

from conftest import quiet, select
from paperole import api, comments, project, prose

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")
ACMART = pytest.mark.skipif(not shutil.which("kpsewhich", path=PATH) or not os.popen(
    "PATH='{}' kpsewhich acmart.cls".format(PATH)).read().strip(), reason="needs acmart")


def _call(paper, method, **params):
    return api.METHODS[method](dict(params, paper=str(paper)), quiet)


def _build(root, tex, files=None):
    src = root / "src"
    src.mkdir(parents=True)
    (src / "main.tex").write_text(tex)
    for name, data in (files or {}).items():
        (src / name).parent.mkdir(parents=True, exist_ok=True)
        (src / name).write_bytes(data) if isinstance(data, bytes) else (src / name).write_text(data)
    build = project.compile(src, root / "build", "main.tex", "pdflatex")
    assert build["status"] != "failed", build
    return src, build["pdf"]


def _picture(label, size=(300, 120)):
    doc = pymupdf.open()
    page = doc.new_page(width=size[0], height=size[1])
    page.draw_rect(pymupdf.Rect(10, 10, size[0] - 10, size[1] - 10), color=(0, 0, 0), fill=(0.8, 0.85, 1))
    page.insert_text((30, size[1] / 2), label, fontsize=14)
    return doc.tobytes()


# --- acmart's title material --------------------------------------------------------------------------------------

ACM_TOP = r"""\documentclass[sigconf]{acmart}
\settopmatter{printacmref=false}
\begin{document}
\title{Warm Pools for Serverless Functions}
\author{Lin Zhou}
\email{lin.zhou@example.edu}
\affiliation{%
  \institution{Example University}
  \city{Hangzhou}
  \country{China}}
\author{Wei Chen}
\email{wei.chen@example.com}
\affiliation{%
  \institution{Northwind Research Labs}
  \city{Zurich}
  \country{Switzerland}}
\begin{abstract}
We size the warm pool of a serverless platform from a forecast of the arrival rate of each function.
\end{abstract}
\keywords{serverless computing, cold starts, forecasting}
\begin{teaserfigure}
\centering
\includegraphics[width=0.6\textwidth]{teaser.pdf}
\caption{The controller resizes every pool once a minute from the forecast it keeps for each function.}
\Description{A pool and a controller.}
\label{fig:teaser}
\end{teaserfigure}

\maketitle

\input{intro}
\end{document}
"""
ACM_INTRO = r"""\section{Introduction}
Serverless platforms start a fresh sandbox for every cold invocation, and the delay this adds is the main
complaint of developers who run latency-sensitive services on them.
"""


@ACMART
def test_comments_on_acmart_teaser_authors_and_keywords(tmp_path):
    """acmart sets the teaser, the author block and the keywords at \\maketitle, so synctex names lines that print
    nothing: a selection there was refused with an internal error (an empty search window) or anchored to the
    \\maketitle line as a guess. Now each is its source text: the only place in the source with its letters."""
    src, pdf = _build(tmp_path, ACM_TOP, {"teaser.pdf": _picture("Pool and controller"), "intro.tex": ACM_INTRO})
    for phrase in ("resizes every pool once a minute from the forecast", "Northwind Research Labs",
                   "serverless computing, cold starts, forecasting", "Example University"):
        rects = select(pdf, 0, phrase)
        a, method, confidence = comments.locate(src, pdf, 0, rects, phrase)
        assert (method, confidence, a["file"]) == ("selection", 1.0, "main.tex"), phrase
        assert comments._fold(a["quote"]) == comments._fold(phrase), (phrase, a["quote"])


# --- paragraphs' places when TeX ships a page out -----------------------------------------------------------------

WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec "
         "romeo sierra tango uniform victor whiskey xray yankee zulu amber basalt cedar dune ember fjord garnet harbor "
         "indigo jasper").split()


def _shipout_body(n=39):
    """Paragraphs of 2 to 12 sentences that each name their token pi<i>x and end in \\par (TeX ships pages out while
    it reads one of their lines); every fourth has a footnote longer than a short paragraph (token fn<i>x), and tables
    float to the tops of pages (cells cell<i>x, with the paragraphs' words)."""
    out = []
    for i in range(1, n + 1):
        s = " ".join("Paragraph pi{}x keeps the pools warm.".format(i) for _ in range(2 * (1 if i % 5 == 0 else 2 + i % 5)))
        if i % 4 == 0:
            s += "\\footnote{{Footnote fn{}x says {}.}}".format(i, " ".join(WORDS[(i * 7 + j * 3) % len(WORDS)]
                                                                       for j in range(24)))
        out.append(s + "\\par")
        if i % 7 == 3:
            rows = "\n".join("cell{}x keeps the pools warm & aa & bb \\\\".format(i) for _ in range(5))
            out.append("\\begin{table}[t]\\centering\\begin{tabular}{lcc}\\hline\nName & A & B \\\\\\hline\n" + rows +
                       "\n\\hline\\end{tabular}\\caption{Caption cap" + str(i) + "x of a table.}\\end{table}")
    return "\n\n".join(out)


def _check_parts(paper, title_tokens=()):
    """Every paragraph's parts hold all of its own tokens, no other block's token, no page number, and no margin
    line number."""
    data = prose.load(paper, 1)
    doc = pymupdf.open(paper / "r1" / "build" / "main.pdf")
    words = [page.get_text("words") for page in doc]
    seen = 0
    for k, b in enumerate(data["blocks"]):
        m = re.search(r"pi\d+x", b["text"])
        if not m or not prose.readable(b):
            continue
        own, notes = m.group(), set(re.findall(r"fn\d+x", b["text"]))
        for page, r in b["parts"]:
            foot = max(words[page], key=lambda w: w[3])  # the page number
            held = [w for w in words[page] if r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1
                    and r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1]
            other = [w[4] for w in held if re.fullmatch(r"(pi|fn|cell|cap)\d+x[.,]?", w[4])
                     and w[4].rstrip(".,") not in {own} | notes or w[4] in title_tokens]
            assert held and not other and foot not in held, (k, own, page, r, other)
            assert not [w for w in held if w[4].isdigit()], (k, own, page, r)  # line numbers, page numbers
        mine = [(p, w) for p, ws in enumerate(words) for w in ws if w[4].rstrip(".,") == own]
        lost = [(p, w[:4]) for p, w in mine if not any(q == p and r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1
                                                       and r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1
                                                       for q, r in b["parts"])]
        assert not lost, (k, own, lost[:3], b["parts"])
        seen += 1
    return seen


def test_paragraph_places_leave_out_what_a_shipout_gives_the_line_read(tmp_path):
    """synctex gives the line TeX reads when it ships a page out the boxes its output routine sets: a float's cells,
    the page's foot and the last lines of footnotes. They were taken as parts of that line's paragraph (a bar beside
    a table, or a paragraph read only where its long footnote is); now a part prints its own paragraph's text, and
    boxes of the blocks before it (a float's cells, even when they repeat the paragraph's words) are left out."""
    tex = ("\\documentclass{article}\n\\usepackage{fancyhdr}\n\\pagestyle{fancy}\n"
           "\\fancyhead[C]{Runninghead of the test paper}\n\\fancyfoot[C]{\\rule{0pt}{18pt}\\thepage}\n"
           "\\begin{document}\n\\section{One}\n" + _shipout_body() + "\n\\end{document}\n")
    (tmp_path / "v1").mkdir()
    (tmp_path / "v1" / "main.tex").write_text(tex)
    paper = tmp_path / "paper"
    _call(paper, "new", title="T", student="S")
    _call(paper, "ingest", source=str(tmp_path / "v1"))
    assert _check_parts(paper) == 39


@ACMART
def test_paragraph_places_in_acmart_review_mode(tmp_path):
    """In acmart's review mode (lineno) the line read at the first page's shipout was given the page's title block,
    abstract and every line number: its paragraph had a part as high as the page across both columns."""
    tex = ("\\documentclass[sigconf,review]{acmart}\n\\settopmatter{printacmref=false}\n\\begin{document}\n"
           "\\title{Title words tt1x tt2x}\n\\author{Author au1x}\n\\affiliation{\\institution{Inst in1x}"
           "\\country{Land}}\n\\begin{abstract}\nAbstract ab1x words of the abstract.\n\\end{abstract}\n\\maketitle\n"
           + _shipout_body() + "\n\\end{document}\n")
    (tmp_path / "v1").mkdir()
    (tmp_path / "v1" / "main.tex").write_text(tex)
    paper = tmp_path / "paper"
    _call(paper, "new", title="T", student="S")
    _call(paper, "ingest", source=str(tmp_path / "v1"))
    assert _check_parts(paper, {"tt1x", "tt2x", "au1x", "in1x", "ab1x"}) == 39


# --- captions -----------------------------------------------------------------------------------------------------

CAPTION_DOC = r"""\documentclass{article}
\usepackage{graphicx}
\usepackage{wrapfig}
\begin{document}
The controller runs once per interval and resizes the warm pool to the smallest size whose expected cost is
lowest, as the figure below shows for one function of the trace.
\begin{figure}[h]
\centering
\includegraphics[width=0.5\textwidth]{pool.pdf}
\caption{The warm pool of one function over a day of the trace. The controller follows the forecast closely.}
\label{fig:pool}
\end{figure}
\begin{wrapfigure}{r}{WIDTH\textwidth}
\centering
\includegraphics[width=0.9\linewidth]{side.pdf}
\caption{Forecast error by hour of the day.}
\end{wrapfigure}
The forecaster predicts the arrival rate of each function from the counts of the last hour, and the controller
turns the forecast into a pool size by weighing the memory cost against the expected cost of cold starts. A pool
that is too large wastes memory on instances that stay idle, while a pool that is too small sends requests to cold
sandboxes and adds their start-up delay to the response time of the function.
\end{document}
"""


def test_a_caption_comment_is_not_changed_by_its_picture_or_float_width(tmp_path):
    """A caption is a sentence of its own: a comment on it stays unchanged when the student replaces the picture
    (same file name) or narrows a wrapped figure, while a box on the figure is changed by the new picture (was: the
    caption's sentence ran back over \\includegraphics and the float's width)."""
    v1 = tmp_path / "v1"
    v2 = tmp_path / "v2"
    for v, label, width in ((v1, "pool size by hour", "0.42"), (v2, "pool size by minute", "0.38")):
        v.mkdir()
        (v / "main.tex").write_text(CAPTION_DOC.replace("WIDTH", width))
        (v / "pool.pdf").write_bytes(_picture(label))
        (v / "side.pdf").write_bytes(_picture("error", (200, 150)))
    paper = tmp_path / "paper"
    _call(paper, "new", title="T", student="S")
    s = _call(paper, "ingest", source=str(v1))["state"]
    pdf = s["round"]["build"]["pdf"]
    ids = {}
    for name, phrase in (("caption", "The controller follows the forecast closely."),
                         ("wrapped", "Forecast error by hour of the day."),
                         ("before", "as the figure below shows for one function of the trace.")):
        ids[name] = _call(paper, "comment", page=0, rects=select(pdf, 0, phrase), text=phrase, note="n",
                          kind="highlight")["id"]
    figure = pymupdf.open(pdf)[0].get_drawings()
    box = max((d["rect"] for d in figure), key=lambda r: r.width * r.height)
    ids["box"] = _call(paper, "comment", page=0, rects=[[box.x0 - 4, box.y0 - 4, box.x1 + 4, box.y1 + 4]], text="",
                       note="n", kind="box")["id"]
    _call(paper, "finish")
    s = _call(paper, "ingest", source=str(v2))["state"]
    states = {name: next(c["anchor_state"] for c in s["comments"] if c["id"] == cid) for name, cid in ids.items()}
    assert states == {"caption": "unchanged", "wrapped": "unchanged", "before": "unchanged", "box": "changed"}


# --- ICML's title block -------------------------------------------------------------------------------------------

def test_the_bracket_that_closes_a_two_column_title_block_is_not_read(tmp_path):
    """ICML sets its title and authors in \\twocolumn[…]; the closing bracket was a paragraph to read, placed on the
    author line that synctex gives its line. A paragraph without a letter or digit is not read."""
    tex = ("\\documentclass{article}\n\\begin{document}\n\\twocolumn[\n{\\centering\\Large Warm Pools for Functions"
           "\\par}\n\n{\\centering Lin Zhou and Wei Chen\\par}\n\n\\vskip 2em\n]\n\n"
           "Serverless platforms start a fresh sandbox for every cold invocation, and the delay this adds is the main "
           "complaint of developers who run latency-sensitive services on them.\n\\end{document}\n")
    (tmp_path / "v1").mkdir()
    (tmp_path / "v1" / "main.tex").write_text(tex)
    paper = tmp_path / "paper"
    _call(paper, "new", title="T", student="S")
    s = _call(paper, "ingest", source=str(tmp_path / "v1"))["state"]
    data = prose.load(paper, 1)
    texts = [data["blocks"][p["block"]]["text"] for p in s["reading"]["paragraphs"]]
    assert any(t.startswith("Serverless platforms") for t in texts)
    assert all(any(ch.isalnum() for ch in t) for t in texts), texts
