"""Checks (checks.py; CONTRACT.md amendment "Checks"): each code fires on a synthetic defect and stays quiet on its
clean twin, on the fixture paper and on samples/promo-demo (a copy), with its text, help and note and its places;
the cache, a failing check left out alone, the RPC and the budget."""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from types import SimpleNamespace

import pymupdf
import pytest

from conftest import Engine, quiet
from paperole import api, checks, disk, ledger, links, prose

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

# Five pages: p.1 the introduction, p.2 the model (Figure 2 and Table 1), p.3 the evaluation, p.4 filler, p.5 the
# discussion (Figures 3 and 4 in the defect paper). Each slot holds a defect (DEFECT) or its clean twin (CLEAN).
SOURCE = r"""\documentclass[anonymous]{article}
\usepackage{graphicx}
\usepackage{xcolor}
\usepackage{amsmath}
\usepackage{url}
\usepackage{todonotes}
%(hyperref)s
\title{Warm Pools for Serverless Functions}
\author{%(author)s}
\date{}
\begin{document}
\maketitle

\section{Introduction}\label{sec:intro}
Serverless platforms start a fresh sandbox for each request that finds no idle instance, and %(the)s cold start adds
hundreds of milliseconds to the response.\footnote{The trace is public.} We study a %(dataset)s of two weeks of
requests and the pools of Figure~\ref{fig:pool}, following earlier work \cite{wang2026%(cites)s} and
\cite{devlin2019,chen2025,ito2024}.%(intro)s

\begin{figure}[h]
\centering
\rule{4cm}{1.5cm}
\caption{A warm pool of four sandboxes.}\label{fig:pool}
\end{figure}

The cost of a pool of size $k$ is
\begin{equation}\label{eq:cost}
C(k) = c_0 k + \lambda T .
\end{equation}
We minimise the cost in Eq.~\eqref{eq:cost} over $k$, and the cost in %(eqref)s grows linearly in $k$.%(overfull)s

\clearpage
\section{Model}\label{sec:model}
The pools of %(fig)s~\ref{fig:pool} hold warm sandboxes, and the pools of Figure~\ref{fig:far} hold cold ones. Short
pretraining comes first. Each model is trained with %(pre)s on the trace, kept short on the dataset of a
week.%(early)s

\begin{figure}[h]
\centering
\rule{4cm}{1cm}
\caption{An early pool.}\label{fig:early}
\end{figure}

\begin{table}[h]
\centering
\begin{tabular}{lr} Policy & Cost \\ Fixed & 4.1%(cell)s \\ Adaptive & 2.7 \end{tabular}
\caption{The cost of each policy.}\label{tab:cost}
\end{table}

The costs in Table~\ref{tab:cost} are low, and %(table)s~\ref{tab:cost} also gives the cost of the fixed policy.

\clearpage
\section{Evaluation}\label{%(eval)s}
Figure~\ref{fig:early} shows the early pool that the evaluation starts from, and Section~\ref{sec:model} gives its
model.%(old)s%(far_near)s

\clearpage
\section{Filler}\label{sec:filler}
This page holds text only, so that the figure of the next page is far from the reference to it on the second page.

\clearpage
\section{Discussion}\label{sec:discussion}
The pools of Figure~\ref{fig:pool} and Section~\ref{sec:intro} agree on this.%(unref)s
%(far_late)s
\begin{figure}[h]
\centering
%(fonts)s
\caption{A second view of the pools.}\label{fig:view}
\end{figure}

%(ack)s

%(bibliography)s
\end{document}
"""

DEFECT = {
    "hyperref": "\\usepackage[colorlinks]{hyperref}\n\\hypersetup{pdfauthor={Lin Zhou}}",
    "author": "Lin Zhou\\\\ University of Somewhere",
    "the": "the the",
    "dataset": "data set",
    "cites": ",wang2026b,Nobody2020",
    "intro": " A \"warm\" pool is TODO here.\\todo{Check the numbers} "
             "\\textcolor{red}{This sentence is still a draft.} See Figure~\\ref{fig:old}.",
    "eqref": "\\eqref{eq:cost}",
    "overfull": " The trace is \\mbox{averyveryverylongunbreakabletracenamethatrunsfarpastthemarginofthepage}.",
    "fig": "Fig.",
    "pre": "pre-training",
    "early": "",
    "table": "table",
    "cell": " (\\ref{tab:gone})",
    "eval": "sec:model",
    "old": " Figure~\\ref{fig:old} is not drawn.",
    "far_near": "",
    "unref": "",
    "far_late": "\\begin{figure}[h]\n\\centering\n\\rule{4cm}{1cm}\n\\caption{A cold pool.}\\label{fig:far}\n"
                "\\end{figure}",
    "fonts": "\\includegraphics{type3.pdf}\\quad\\includegraphics{helv.pdf}",
    "ack": "\\section*{Acknowledgements}\nWe thank Ann Lee. The code is at "
           "\\url{https://github.com/linzhou/warmpools}.",
    "bibliography": "\\bibliographystyle{plain}\n\\bibliography{refs}",
}

CLEAN = dict(DEFECT, **{
    "hyperref": "\\usepackage[colorlinks]{hyperref}",
    "author": "Anonymous Authors",
    "the": "the",
    "dataset": "dataset",
    "cites": "",
    "intro": " A ``warm'' pool is ready here.",
    "eqref": "Eq.~\\eqref{eq:cost}",
    "overfull": "",
    "fig": "Figure",
    "pre": "pretraining",
    "early": " Figure~\\ref{fig:early} shows an early pool.",
    "table": "Table",
    "cell": "",
    "eval": "sec:eval",
    "old": "",
    "far_near": "\n\\begin{figure}[h]\n\\centering\n\\rule{4cm}{1cm}\n\\caption{A cold pool.}\\label{fig:far}\n"
                "\\end{figure}",
    "far_late": "",
    "unref": " Figure~\\ref{fig:view} gives a second view.",
    "fonts": "\\rule{4cm}{1cm}",
    "ack": "The code is at \\url{https://anonymous.4open.science/r/warmpools}.",
})

BIB = r"""@inproceedings{wang2026, author = {A. Wang and B. Li}, title = {Cold starts in practice},
  booktitle = {Proc. X}, year = {2026}}
@inproceedings{wang2026b, author = {Wang, A. and Li, B.}, title = "Cold Starts in Practice", booktitle = {Proc. X},
  year = 2026}
@article{devlin2019, author = {J. Devlin}, title = {%(bert)s: Pre-training of deep bidirectional transformers},
  journal = {Proc. NAACL}, year = {2019}}
@article{chen2025, author = {C. Chen}, title = {Serverless in the wild}, journal = {J. Y}%(year)s}
@article{ito2024, author = {D. Ito}, title = {Pricing idle memory}, year = {2024}%(journal)s}
@misc{unused, author = {E. Fox}, title = {Cold starts in practice}}
"""

THEBIBLIOGRAPHY = r"""\begin{thebibliography}{9}
\bibitem{wang2026} A.~Wang and B.~Li.
\newblock Cold starts in practice.
\newblock In \emph{Proc. X}, 2026.
\bibitem{wang2026b} A.~Wang and B.~Li.
\newblock Cold Starts in Practice.
\newblock In \emph{Proc. X}, 2026.
\bibitem{devlin2019} J.~Devlin.
\newblock {BERT}: Pre-training of deep bidirectional transformers.
\newblock In \emph{Proc. NAACL}, 2019.
\bibitem{chen2025} C.~Chen.
\newblock Serverless in the wild.
\newblock \emph{J. Y}, 2025.
\bibitem{ito2024} D.~Ito.
\newblock Pricing idle memory.
\newblock \emph{J. W}, 2024.
\end{thebibliography}"""


def _type3_pdf(path):
    """A small PDF that draws "abab" in a Type 3 font (two square glyphs), as a figure with a Type 3 font."""
    glyph = b"800 0 0 0 700 700 d1\n0 0 700 700 re f\n"
    content = b"BT /F1 24 Tf 10 12 Td (abab) Tj ET\n"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 40] /Resources << /Font << /F1 4 0 R >> >> "
        b"/Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type3 /BaseFont /ABCDEF+BlockSans /FontBBox [0 0 800 700] "
        b"/FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /a 6 0 R /b 7 0 R >> "
        b"/Encoding << /Type /Encoding /Differences [97 /a /b] >> /FirstChar 97 /LastChar 98 /Widths [800 800] "
        b"/Resources << >> >>",
        b"<< /Length %d >>\nstream\n" % len(content) + content + b"endstream",
        b"<< /Length %d >>\nstream\n" % len(glyph) + glyph + b"endstream",
        b"<< /Length %d >>\nstream\n" % len(glyph) + glyph + b"endstream",
    ]
    out, offsets = b"%PDF-1.4\n", []
    for k, body in enumerate(objects):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % (k + 1) + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    path.write_bytes(out)


def _helv_pdf(path):
    """A small PDF whose text is in Helvetica, not embedded (PyMuPDF's base-14 "helv")."""
    doc = pymupdf.open()
    page = doc.new_page(width=120, height=40)
    page.insert_text((10, 25), "Pool size", fontname="helv", fontsize=12)
    doc.save(str(path))
    doc.close()


def _paper(root, slots, bib=None):
    src = root / "src"
    src.mkdir(parents=True)
    (src / "main.tex").write_text(SOURCE % slots)
    if bib is not None:
        (src / "refs.bib").write_text(bib)
    _type3_pdf(src / "type3.pdf")
    _helv_pdf(src / "helv.pdf")
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Warm pools", "student": "Lin Zhou"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    assert not checks.path(paper, 1).exists()  # built only on request (the checks RPC), never at ingest
    return paper


@pytest.fixture(scope="module")
def defect(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("defect"), DEFECT, BIB % {"bert": "BERT", "year": "", "journal": ""})


@pytest.fixture(scope="module")
def plain(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("plain"), dict(DEFECT, hyperref="", bibliography=THEBIBLIOGRAPHY))


@pytest.fixture(scope="module")
def clean(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("clean"), CLEAN,
                  BIB % {"bert": "{BERT}", "year": ", year = {2025}", "journal": ", journal = {J. W}"})


@pytest.fixture
def copy(tmp_path):
    def make(paper):
        dest = tmp_path / "copy"
        shutil.copytree(paper, dest)
        return dest
    return make


def _checks(paper, n=None):
    return api.checks_({"paper": str(paper), "round": n}, quiet)["checks"]


def _by_code(found):
    out = {}
    for c in found:
        out.setdefault(c["code"], []).append(c)
    return out


def _words(paper, place, n=1):
    """The PDF words whose centre lies in a place's rects, joined."""
    words = pymupdf.open(str(paper / "r{}/build/main.pdf".format(n)))[place["page"]].get_text("words")
    return " ".join(w[4] for w in words if any(r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1 and
                                                r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1 for r in place["rects"]))


def _line(slots, needle, nth=0):
    """The 1-based line of the nth occurrence of needle in the source made with slots."""
    text, pos = SOURCE % slots, -1
    for _ in range(nth + 1):
        pos = text.index(needle, pos + 1)
    return text.count("\n", 0, pos) + 1


# the references' format and look-up checks are tests/test_refs.py's: five entries are too few to compare, and the
# defect paper has no look-ups' results
REFS = {"venue_forms", "venue_style", "author_names", "author_case", "title_case", "etal_by_hand", "leftovers",
        "field_mix", "page_dash", "arxiv_forms", "published_preprint", "no_record", "record_differs"}
ALL = set(checks.CODES) - REFS
NO_BIB = {"lowered_caps", "no_year", "no_venue", "pdf_author"}  # need a .bib (or hyperref's pdfauthor)


def test_each_check_has_the_contract_shape(defect):
    found = _checks(defect)
    # each key names its slip alone: by its \label, .bib key or word where its words hold a number; for its round
    # alone where only its place knows it
    keys = {c["code"]: c["key"] for c in found}
    assert len({c["key"] for c in found}) == len(found)
    assert keys["draft_marker"].endswith("|r1") and keys["overfull"].endswith("|r1")
    assert keys["doubled_word"].endswith("|r1") and keys["straight_quotes"].endswith("|r1")
    assert keys["no_year"] == "no_year|chen2025" and "[" not in keys["lowered_caps"]
    assert keys["label_twice"] == "label_twice|sec:model"
    assert keys["spelling"] == "spelling|pretraining"  # the word, not its counts
    assert all(c["key"] == "undefined_ref|" + c["text"] for c in found if c["code"] == "undefined_ref")
    assert set(_by_code(found)) == ALL
    for c in found:
        assert set(c) == {"code", "group", "text", "detail", "note", "places", "key", "ok"}  # key, ok: the reply's
        assert c["key"].startswith(c["code"] + "|") and c["ok"] is False
        assert c["group"] == checks.CODES[c["code"]] and c["text"] and "p." not in c["text"].split("·")[0]
        assert c["detail"] and c["note"], c["code"]
        for p in c["places"]:
            assert set(p) == {"page", "rects", "text"} and isinstance(p["page"], int)
            assert all(len(r) == 4 and r[0] < r[2] and r[1] < r[3] for r in p["rects"])
    # groups in order, then by the first place's page and top; checks without places last in their group
    keys = [(checks.GROUPS.index(c["group"]), not c["places"], c["places"][0]["page"] if c["places"] else 0,
             min(r[1] for r in c["places"][0]["rects"]) if c["places"] else 0) for c in found]
    assert keys == sorted(keys)
    assert found[-1]["code"] == "pdf_author" and found[-1]["places"] == []


def test_references(defect):
    by = _by_code(_checks(defect))
    old, gone = sorted(by["undefined_ref"], key=lambda c: c["text"])
    assert gone["text"] == "Undefined reference tab:gone" and old["text"] == "Undefined reference fig:old"
    assert [p["page"] for p in old["places"]] == [0, 2] and [_words(defect, p) for p in old["places"]] == ["??.", "??"]
    assert old["detail"] == "The reference to fig:old on p.1 and p.3 prints “??”: there is no \\label{fig:old} in " \
                            "this round's source."
    assert old["note"] == "This reference prints “??”: there is no \\label{fig:old}."
    # a "??" in a table cell, which only the .log knows (no hyperref link, no prose mark): its line's words
    assert [p["page"] for p in gone["places"]] == [1] and _words(defect, gone["places"][0]) == "(??)"
    cite, = by["undefined_cite"]
    assert cite["text"] == "Undefined citation Nobody2020" and len(cite["places"]) == 1
    assert "?" in _words(defect, cite["places"][0]) and cite["places"][0]["page"] == 0  # not its neighbours' [4, 5,
    twice, = by["label_twice"]
    lines = [_line(DEFECT, "\\label{sec:model}", k) for k in (0, 1)]
    assert twice["text"] == "Label sec:model defined twice"
    assert [p["text"] for p in twice["places"]] == ["main.tex:{}".format(n) for n in lines]
    assert [p["page"] for p in twice["places"]] == [1, 2]
    assert "Model" in _words(defect, twice["places"][0]) and "Evaluation" in _words(defect, twice["places"][1])
    unref, = by["float_unreferenced"]
    assert unref["text"] == "Figure 4 · not referenced" and unref["note"] == "Figure 4 is never referenced in the text."
    assert unref["places"][0]["page"] == 4 and "Figure 4:" in _words(defect, unref["places"][0])
    before, = by["float_before"]
    assert before["text"] == "Figure 2 · before its first citation"
    assert [p["page"] for p in before["places"]] == [1, 2] and "Figure 2:" in _words(defect, before["places"][0])
    far, = by["float_far"]
    assert far["text"] == "Figure 3 · 3 pages after its first citation"
    assert [p["page"] for p in far["places"]] == [4, 1] and _words(defect, far["places"][1]) == "3"


def test_bibliography(defect):
    by = _by_code(_checks(defect))
    same, = by["same_work"]
    assert re.fullmatch(r"Same work twice · \[\d\] · \[\d\]", same["text"])
    assert [p["page"] for p in same["places"]] == [4, 4]
    assert all("Cold starts in practice" in _words(defect, p) for p in same["places"])
    caps, = by["lowered_caps"]
    assert re.fullmatch(r"“BERT” prints as “Bert” · \[\d\]", caps["text"])
    assert _words(defect, caps["places"][0]) == "Bert:" and "{BERT}" in caps["note"]
    year, = by["no_year"]
    venue, = by["no_venue"]
    assert re.fullmatch(r"No year · \[\d\]", year["text"]) and "Chen" in _words(defect, year["places"][0])
    assert re.fullmatch(r"No venue · \[\d\]", venue["text"]) and "Ito" in _words(defect, venue["places"][0])
    assert venue["detail"] == "The .bib entry ito2024 is an @article without a journal."


def test_consistency(defect):
    by = _by_code(_checks(defect))
    spelt = {c["text"]: c for c in by["spelling"]}
    assert set(spelt) == {"“data set” 1× · “dataset” 1×", "“pretraining” 1× · “pre-training” 1×"}
    assert [_words(defect, p) for p in spelt["“data set” 1× · “dataset” 1×"]["places"]] == ["data set", "dataset"]
    styles = {c["text"]: c for c in by["ref_style"]}
    assert set(styles) == {"“Figure 1” · “Fig. 1”", "“Eq. (1)” · “(1)”", "“Table 1” · “table 1”"}
    figures = styles["“Figure 1” · “Fig. 1”"]
    assert "Fig. 1" in [_words(defect, p) for p in figures["places"]]
    assert "“Figure 1” (3×)" in figures["detail"]  # "Figure 2 shows", starting a sentence, left out
    assert [_words(defect, p) for p in styles["“Eq. (1)” · “(1)”"]["places"]] == ["Eq. (1)", "(1)"]


def test_typesetting(defect):
    by = _by_code(_checks(defect))
    over, = by["overfull"]
    assert re.fullmatch(r"Overfull line · \d+(\.\d)? pt too wide", over["text"])
    assert _words(defect, over["places"][0]).startswith("The trace is averyvery")  # the line the log's box prints
    assert over["places"][0]["rects"][0][2] > 477 + 40  # past the margin
    quotes, = by["straight_quotes"]
    line = _line(DEFECT, '"warm"')
    assert quotes["text"] == "Straight quotes · main.tex:{}".format(line)
    assert _words(defect, quotes["places"][0]) == "”warm”"
    doubled, = by["doubled_word"]
    assert doubled["text"] == "“the the”" and _words(defect, doubled["places"][0]) == "the the"


def test_submission(defect):
    by = _by_code(_checks(defect))
    type3, = by["type3_font"]
    assert type3["text"] == "Type 3 font · BlockSans" and [p["page"] for p in type3["places"]] == [4]
    assert _words(defect, type3["places"][0]) == "abab"
    helv, = by["unembedded_font"]
    assert helv["text"] == "Font not embedded · Helvetica" and _words(defect, helv["places"][0]) == "Pool size"
    marker, = by["draft_marker"]
    assert marker["text"] == "“TODO” left in" and _words(defect, marker["places"][0]) == "TODO"
    todo, = by["todo_note"]
    assert todo["text"] == "Todo note · “Check the numbers”"
    assert _words(defect, todo["places"][0]) == "Check the numbers"  # its margin note, not the line
    colour, = by["coloured_text"]  # one run across two lines, beside a margin note; links and the footnote mark
    assert colour["text"] == "Red text · “This sentence is still a…”"  # (colorlinks) are not draft text
    assert _words(defect, colour["places"][0]) == "This sentence is still a draft."
    author, = by["pdf_author"]
    assert author["text"] == "PDF author · Lin Zhou" and author["places"] == []
    block, = by["author_block"]
    assert block["text"] == "Author named · “Lin Zhou”"
    assert [_words(defect, p) for p in block["places"]] == ["Lin Zhou", "University of Somewhere"]
    ack, = by["acknowledgements"]
    assert _words(defect, ack["places"][0]) == "Acknowledgements"
    url, = by["personal_url"]
    assert url["text"] == "Link may name an author · github.com/linzhou"
    assert "github.com/linzhou" in _words(defect, url["places"][0])


def test_without_hyperref_and_with_thebibliography(plain):
    """The same defects without hyperref (references from the source) and a thebibliography (titles from its first
    \\newblock; nothing to say about years, venues or lowered capitals without a .bib)."""
    by = _by_code(_checks(plain))
    assert set(by) == ALL - NO_BIB
    old = next(c for c in by["undefined_ref"] if c["text"].endswith("fig:old"))
    assert [_words(plain, p) for p in old["places"]] == ["??.", "??"]
    cite, = by["undefined_cite"]
    assert len(cite["places"]) == 1 and _words(plain, cite["places"][0]) == "?]"  # not the whole "[1, 2, ?]"
    same, = by["same_work"]
    assert same["text"] == "Same work twice · [1] · [2]"
    assert [c["text"] for c in by["float_far"]] == ["Figure 3 · 3 pages after its first citation"]
    assert by["coloured_text"][0]["text"] == "Red text · “This sentence is still a…”"


def test_the_clean_twin_and_the_fixture_paper_have_no_checks(clean, paper):
    assert _checks(clean) == []
    assert _checks(paper) == []  # tests/fixtures/paper v1: not anonymous, its "% TODO" a comment


PROMO = os.path.join(os.path.dirname(__file__), "..", "..", "samples", "promo-demo", "review")


@pytest.mark.skipif(not os.path.isdir(PROMO), reason="needs the synthetic samples/promo-demo")
def test_the_promo_demo_rounds(tmp_path):
    """The synthetic 8-page anonymous ICLR paper (a copy): round 1's Figure 2 has matplotlib's Type 3 DejaVuSans, round
    2's has not; its "data set" and "pretraining" are spelt one way; within the 2 s budget."""
    paper = tmp_path / "review"
    shutil.copytree(PROMO, paper)
    for n in (1, 2):
        api.links_({"paper": str(paper), "round": n}, quiet)  # prose.json and links.json first
        checks.path(paper, n).unlink(missing_ok=True)
        start = time.monotonic()
        by = _by_code(_checks(paper, n))
        assert time.monotonic() - start < 2.0
        assert "spelling" not in by and "ref_style" not in by and "personal_url" not in by
        assert [c["text"] for c in by["float_far"]] == ["Algorithm 1 · 2 pages after its first citation"]  # a true fact
        # true too: two author lists cut to "and others" while austin2021 prints its eleven
        assert [c["key"] for c in by["etal_by_hand"]] == ["etal_by_hand|chen2021evaluating",
                                                          "etal_by_hand|roziere2023code"]
        if n == 1:
            type3, = by["type3_font"]
            assert type3["text"] == "Type 3 font · DejaVuSans" and [p["page"] for p in type3["places"]] == [5]
            assert type3["places"][0]["rects"] and "Q1" in _words(paper, type3["places"][0], 1)
        else:
            assert set(by) == {"float_far", "etal_by_hand"}


def test_the_cache(defect, copy, monkeypatch, capsys):
    paper = copy(defect)
    first = _checks(paper)
    data = checks.load(paper, 1)
    assert data["schema"] == checks.SCHEMA and data["version"] == checks.CHECKS and data["round"] == 1
    assert data["parser"] == prose.PARSER and data["links"] == links.LINKS
    assert [dict(c, ok=False) for c in data["checks"]] == first  # the file has no ok
    assert "checks.json" not in disk.round_files(paper / "r1", "main")  # outside the round's checksums
    assert data["table"] is True
    for stale in ({"version": checks.CHECKS - 1}, {"parser": prose.PARSER - 1}, {"links": links.LINKS - 1},
                  {"table": None}):
        checks.path(paper, 1).write_text(json.dumps(dict(data, checks=[], **stale)))
        assert checks.load(paper, 1) is None and _checks(paper) == first
    checks.path(paper, 1).write_text("{not json")
    assert _checks(paper) == first
    # a check that fails is left out alone
    checks.path(paper, 1).unlink()
    monkeypatch.setattr(checks, "RUNS", [(c, (lambda p: 1 / 0) if c == "spelling" else f) for c, f in checks.RUNS])
    found = _checks(paper)
    assert "checks: spelling failed: ZeroDivisionError" in capsys.readouterr().err
    assert {c["code"] for c in found} == ALL - {"spelling"}


def test_failures_give_no_checks_and_never_an_error(defect, copy, monkeypatch, capsys):
    paper = copy(defect)
    checks.path(paper, 1).unlink(missing_ok=True)
    runs = []

    def broken(self, *args):
        runs.append(1)
        raise ValueError("a PDF PyMuPDF cannot read")
    monkeypatch.setattr(checks._Paper, "__init__", broken)
    assert api.checks_({"paper": str(paper)}, quiet) == {"round": 1, "path": None, "checks": None}
    assert "a PDF PyMuPDF cannot read" in capsys.readouterr().err
    assert _checks(paper) is None and len(runs) == 1  # not built again
    os.utime(prose.path(paper, 1), ns=(1, 1))  # until the round's prose.json (or PDF, or links.json) changes
    assert _checks(paper) is None and len(runs) == 2
    monkeypatch.undo()
    prose.path(paper, 1).unlink()  # the paragraphs cannot be found: still no error
    monkeypatch.setattr(prose, "build", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no paragraphs")))
    assert api.checks_({"paper": str(paper)}, quiet) == {"round": 1, "path": None, "checks": None}
    # without a link table the checks that need none still run
    monkeypatch.undo()
    (paper / "r1/prose.failed").unlink()
    links.path(paper, 1).unlink()
    monkeypatch.setattr(links, "build_quietly", lambda *a: None)
    found = _by_code(_checks(paper))
    assert "doubled_word" in found and "float_before" not in found


def test_checks_built_without_the_table_are_built_again_with_it(defect, copy, monkeypatch):
    """A checks.json built while the link table could not be built is stale once the round has one, and the checks
    RPC tries the table again (once a process when it fails)."""
    paper = copy(defect)
    checks.path(paper, 1).unlink(missing_ok=True)
    links.path(paper, 1).unlink()
    monkeypatch.setattr(links, "build_quietly", lambda *a: None)
    found = _by_code(_checks(paper))
    assert "float_far" not in found and checks.load(paper, 1)["table"] is False
    assert _by_code(_checks(paper)) == found  # current while the round has no table
    monkeypatch.undo()
    found = _by_code(_checks(paper))
    assert "float_far" in found and "float_before" in found
    assert checks.load(paper, 1)["table"] is True and links.load(paper, 1) is not None


def test_rpc_cli_and_refusals(defect, tmp_path):
    eng = Engine()
    try:
        eng.send(json.dumps({"id": 1, "method": "checks", "params": {"paper": str(defect), "round": 1}}))
        reply = eng.reply(1)
        assert set(reply["result"]) == {"round", "path", "checks"}
        assert reply["result"]["checks"] == _checks(defect) and reply["result"]["path"] == str(checks.path(defect, 1))
        # each check's key and whether it is marked OK; check_ok marks it in the ledger, for every round after
        first = reply["result"]["checks"][0]
        assert first["key"] == "{}|{}".format(first["code"], first["text"]) and first["ok"] is False
        eng.send(json.dumps({"id": 10, "method": "check_ok", "params": {"paper": str(defect), "key": first["key"]}}))
        assert eng.reply(10)["result"] == {"checks_ok": [first["key"]]}
        assert ledger.load(defect)["checks_ok"] == {first["key"]: 1}
        assert [c["ok"] for c in _checks(defect)] == [True] + [False] * (len(_checks(defect)) - 1)
        eng.send(json.dumps({"id": 11, "method": "check_ok", "params": {"paper": str(defect), "key": first["key"],
                                                                         "ok": False}}))
        assert eng.reply(11)["result"] == {"checks_ok": []} and not any(c["ok"] for c in _checks(defect))
        eng.send(json.dumps({"id": 12, "method": "check_ok", "params": {"paper": str(defect), "key": ""}}))
        assert eng.reply(12)["error"]["message"] == "key is a check's key, ok true or false."
        assert checks.load(defect, 1)["checks"][0].keys() == {"code", "group", "text", "detail", "note", "places", "key"}
        eng.send(json.dumps({"id": 2, "method": "checks", "params": {"paper": str(defect), "round": 5}}))
        assert eng.reply(2)["error"]["message"] == "There is no round 5."
        api.new({"paper": str(tmp_path / "empty"), "title": "Warm pools", "student": "Lin Zhou"}, quiet)
        eng.send(json.dumps({"id": 3, "method": "checks", "params": {"paper": str(tmp_path / "empty")}}))
        assert eng.reply(3)["error"]["message"] == "There is no round yet. Ingest the student's source first."
    finally:
        assert eng.close()[0] == 0
    out = subprocess.run([sys.executable, "-m", "paperole.cli", "checks", str(defect), "--round", "1"],
                         capture_output=True, text=True, encoding="utf-8", timeout=120)
    assert out.returncode == 0 and json.loads(out.stdout)["checks"] == _checks(defect)
    out = subprocess.run([sys.executable, "-m", "paperole.cli", "check-ok", str(defect), "x|y"],
                         capture_output=True, text=True, encoding="utf-8", timeout=120)
    assert out.returncode == 0 and json.loads(out.stdout)["checks_ok"] == ["x|y"]
    subprocess.run([sys.executable, "-m", "paperole.cli", "check-ok", str(defect), "x|y", "--clear"], timeout=120)
    assert ledger.load(defect)["checks_ok"] == {}


# --- the rules alone, without TeX ---------------------------------------------------------------------------------

class _Stub:
    """What spelling and ref_style read of a paper: the text's words (one block of this kind), the link table and
    the places' order (by page, top and left)."""

    def __init__(self, text, links=(), targets=(), kind="paragraph"):
        words, x = [], 72.0
        for line, row in enumerate(text.split("\n")):
            x = 72.0
            for k, w in enumerate(row.split()):
                words.append((0, len(words), (x, 100 + 12 * line, x + 6 * len(w), 110 + 12 * line, w, 0, line, k)))
                x += 6 * len(w) + 4
        self.body_words = [(0, words)]
        self.blocks = [{"kind": kind}]
        self.links, self.targets = list(links), list(targets)

    @staticmethod
    def reading_key(place):
        return place["page"], place["rects"][0][1], place["rects"][0][0]


def test_spelling_rules():
    assert checks.spelling(_Stub("a time-step and a time step here")) == []  # never a hyphen against a space
    assert checks.spelling(_Stub("we pre-\ntrain and pretrain")) == []  # a hyphen at a line's end is unknown
    assert checks.spelling(_Stub("we set up the setup")) == []  # a stopword
    assert checks.spelling(_Stub("the e-mail and the email")) == []  # a one-letter part
    found = checks.spelling(_Stub("the datasets and a data set and Modelling and modeling we optimise optimize"))
    assert sorted(c["text"] for c in found) == ["“datasets” 1× · “data set” 1×", "“modelling” 1× · “modeling” 1×",
                                                "“optimise” 1× · “optimize” 1×"]
    found, = checks.spelling(_Stub("a time-step, a time step and a timestep"))
    assert found["text"] == "“time-step” 1× · “time step” 1× · “timestep” 1×"
    assert [p["text"] for p in found["places"]] == ["time-step,", "time step", "timestep"]


def test_ref_style_rules():
    # IEEE: "Figure 3" starts a sentence, "Fig. 3" in mid-sentence; cleveref's "fig." and "Fig." likewise
    assert checks.ref_style(_Stub("Figure 3 shows it. As in Fig. 2 we see. Figure 4 too.")) == []
    assert checks.ref_style(_Stub("as fig. 2 shows. Fig. 3 shows more, and fig. 4 also")) == []
    found, = checks.ref_style(_Stub("as Figure 2 shows, and figure 3 also"))
    assert found["text"] == "“Figure 2” · “figure 3”"
    # a bare "(2)" only from a link to a formula, and not after "Eqs." in a list
    eq = [{"page": 0, "rects": [[0, 0, 600, 800]], "text": "(2)", "kind": "equation", "targets": [0], "via": "pdf"}]
    target = [{"kind": "equation", "block": None}]
    assert checks.ref_style(_Stub("in Eq. (2) and in (3) we")) == []  # raw text: no link
    assert checks.ref_style(_Stub("in Eqs. (2) and (3) we", eq, target)) == []
    found, = checks.ref_style(_Stub("by Eq. (2) and by (3) we", eq, target))
    assert found["text"] == "“Eq. (2)” · “(3)”"
    # an item's first word after its label starts a sentence ("• Figure 1 shows", "1) Figure 1 shows")
    for label in ("•", "1)", "(a)", "–"):
        assert checks.ref_style(_Stub(label + " Figure 1 shows it, as in Fig. 2 we see", kind="item")) == []
    found, = checks.ref_style(_Stub("so Figure 1 shows it, as in Fig. 2 we see", kind="item"))
    assert found["text"] == "“Figure 1” · “Fig. 2”"


def test_source_and_bib_rules():
    t = r'a "b" \verb|"x"| $"$ \url{a"b} \"o \texttt{"q"} \href{u"v}{"w"} \begin{verbatim}"\end{verbatim} c"'
    assert [t[i - 1:i + 2] for i in checks._quotes(t, 0)] == [' "b', 'b" ', '{"w', 'w"}', 'c"']
    bib = checks._bib_entries('@string{j = "J"} @article{k1, title = {A {BERT} Model}, journal = j # " X",\n'
                              'year = 2020} @misc(k2, title = "GPT-2 {Is} Here")')
    assert bib == {"k1": ("article", {"title": "A {BERT} Model", "journal": "j X", "year": "2020"}),
                   "k2": ("misc", {"title": "GPT-2 {Is} Here"})}
    assert checks._lowered("A {BERT} Model of ImageNet and GPUs") == ["ImageNet", "GPUs"]
    assert checks._account("https://github.com/linzhou/warmpools") == "github.com/linzhou"
    assert checks._account("https://github.com/facebookresearch/x") is None
    assert checks._account("https://huggingface.co/datasets/linzhou/trace") == "huggingface.co/linzhou"
    assert checks._account("https://linzhou.github.io/") == "linzhou.github.io"
    assert checks._account("https://cs.example.edu/~lin/pools") == "cs.example.edu/~lin"
    assert checks._account("https://anonymous.4open.science/r/warmpools") is None
    assert checks._account("https://github.com/Hendrycks/test") == "github.com/hendrycks"  # names ignore case
    assert checks._account("https://Rajpurkar.github.io/") == "rajpurkar.github.io"
    assert checks._account("https://github.com/LinZhou/x") == checks._account("github.com/linzhou/y")
    assert checks._account("https://www.cs.cmu.edu/~./enron/") == "cs.cmu.edu/~enron"  # CMU's "~./"
    assert checks._account("https://www.cs.toronto.edu/~kriz.") == "cs.toronto.edu/~kriz"
    assert checks._account("https://huggingface.co/datasets/rajpurkar/squad") == "huggingface.co/rajpurkar"
    # the hosts' own pages and other hosts name no one; an owner after users/, groups/, organizations/, collections/
    for url in ("https://docs.github.com/en/actions", "https://api.github.com/repos/linzhou/x", "help.github.com/articles/x",
                "docs.gitlab.com/ee/ci", "discuss.huggingface.co/t/x", "notgithub.com/linzhou", "mygitlab.com/linzhou",
                "https://huggingface.co/datasets/squad/viewer", "huggingface.co/datasets/glue/blob/main/README.md",
                "gitlab.com/users/sign_in", "https://github.com/trending", "huggingface.co/learn/nlp-course"):
        assert checks._account(url) is None, url
    assert checks._account("https://gist.github.com/linzhou/abc") == "github.com/linzhou"
    assert checks._account("(github.com/linzhou)") == "github.com/linzhou"
    assert checks._account("github.com/users/LinZhou") == "github.com/linzhou"
    assert checks._account("gitlab.com/groups/linzhou") == "gitlab.com/linzhou"
    assert checks._account("huggingface.co/collections/linzhou/x") == "huggingface.co/linzhou"
    assert checks._account("https://github.com/nyu-") is None  # a name cut at a line's end
    # a Hugging Face dataset or model without an owner, and placeholders, name no one
    assert checks._account("https://huggingface.co/datasets/squad") is None
    assert checks._account("https://huggingface.co/models/bert-base-uncased") is None
    assert checks._account("https://huggingface.co/linzhou/pools-7b") == "huggingface.co/linzhou"
    for url in ("https://github.com/XXX", "github.com/XXX/pools", "https://github.com/anonymous-author/pools",
                "https://github.com/username/pools", "https://xxxx.github.io/", "https://example.edu/~anonymous"):
        assert checks._account(url) is None, url
    # \Verb (fancyvrb) and minted's code are verbatim; the parts TeX skips are blanked before (_Paper.text)
    t = r'\Verb|"a"| \Verb[fontsize=\small]|"b"| \mintinline{python}{"c"} \mintinline{python}|"d"| ' \
        r'\inputminted{python}{"e".py} "f'
    assert [t[i:i + 2] for i in checks._quotes(t, 0)] == ['"f']
    # by hand: a range of numbers holds the ones between ("Figures 2–4", "Tables 1 to 3")
    blocks = [{"kind": "paragraph", "text": "Figures 2–4 and Tables 1 to 3 as in Fig. 7 and Figs. A1-A2."}]
    assert checks._by_hand(SimpleNamespace(blocks=blocks)) == {
        ("Figure", "2"), ("Figure", "3"), ("Figure", "4"), ("Table", "1"), ("Table", "2"), ("Table", "3"),
        ("Figure", "7"), ("Figure", "A1"), ("Figure", "A2")}


def test_keys():
    """_keys: the code and ident (else the words), "|r<n>" for a slip known by its place, "#2"… for repeats."""
    def c(code, text, ident=None, per_round=False):
        return checks._check(code, text, ident=ident, per_round=per_round)
    found = [c("draft_marker", "“TODO” left in", per_round=True), c("draft_marker", "“TODO” left in", per_round=True),
             c("no_year", "No year · [4]", ident="smith2019"), c("coloured_text", "Red text · “A”"),
             c("coloured_text", "Red text · “A”")]
    checks._keys(found, 3)
    assert [x["key"] for x in found] == ["draft_marker|“TODO” left in|r3", "draft_marker|“TODO” left in|r3#2",
                                         "no_year|smith2019", "coloured_text|Red text · “A”",
                                         "coloured_text|Red text · “A”#2"]
    assert all("_round" not in x for x in found)


def test_todo_rules():
    """What a \\todo's note is looked for as, and where (review 2026-10-31): the words without a command, accent or
    math; joined across a hyphenated line and a dash; a margin note only outside the text column, an inline one only on
    its line; a command defined to print nothing is hidden."""
    assert checks._todo_words(r"see Sec.~\ref{sec:x} now") == "see Sec."
    assert checks._todo_words(r"G\"odel caf\'e is wrong") == "is wrong"
    assert checks._todo_words(r"Check this -- maybe drop it") == "Check this maybe drop"
    assert checks._todo_words(r"\cite{x}") == "" and checks._todo_words("") == ""
    hidden = r"\newcommand{\todo}[1]{} \renewcommand\missingfigure[2][]{ } \def\todo#1{}"
    assert {m.group(1) or m.group(2) for m in checks.TODO_HIDDEN.finditer(hidden)} == {"todo", "missingfigure"}
    for d in (r"\renewcommand{\todo}[2][]{\relax}", r"\providecommand{\todo}[1]{}", r"\newcommand*{\todo}[1]{\ignorespaces}",
              r"\newcommand{\todo}[1]{{}}", r"\def \todo#1{\iffalse#1\fi}", r"\DeclareRobustCommand{\todo}[1]{}"):
        assert checks.TODO_HIDDEN.search(d), d  # prints nothing
    for d in (r"\newcommand{\todo}{}", r"\newcommand{\todo}[1][]{}", r"\def\todo{}",
              r"\newcommand{\todo}[1]{\textcolor{red}{#1}}", r"\newcommand{\todos}[1]{}"):
        assert not checks.TODO_HIDDEN.search(d), d  # its argument is still typeset, or it is another command
    assert checks.TODO_DEFINED.search(r"\newcommand{\todo}[1]{\textcolor{red}{#1}}").group(1) == "todo"
    assert checks.TODO_DEFINED.search(r"\providecommand{\todo}[1]{\textcolor{red}{#1}}").group(1) == "todo"
    assert checks.TODO_DEFINED.search(r"\def \todo#1{#1}").group(2) == "todo"
    # the text inside conditionals, nested, blanked with its offsets; \newif opens none; \ifthenelse{…} has no \fi
    t = r"\newif\ifdraft\drafttrue\ifdraft A\else\ifx\a\b B\fi C\fi D\ifthenelse{x}{E}{F} G"
    u = checks._unconditional(t)
    assert len(u) == len(t) and "A" not in u and "B" not in u and "C" not in u and all(x in u for x in "DEFG")
    assert "\\newif" in u
    assert checks.TODO_INLINE.search(r"\setuptodonotes{color=red, inline}")
    assert checks.TODO_INLINE.search(r"\presetkeys{todonotes}{inline}{}")
    assert not checks.TODO_INLINE.search(r"\setuptodonotes{noinline}")
    # a page: the body's "We train on ImageNet." in the column (72-540), a margin note "Re-" "compute – the numbers"
    words = [(72, 100, 100, 110, "We"), (102, 100, 130, 110, "train"), (132, 100, 150, 110, "on"),
             (152, 100, 200, 110, "ImageNet."), (550, 100, 570, 110, "Re-"), (550, 112, 590, 122, "compute"),
             (592, 112, 596, 122, "–"), (550, 124, 570, 134, "the"), (572, 124, 600, 134, "numbers")]
    norms = [checks._norm(w[4]) for w in words]
    p = SimpleNamespace(words=lambda page: words, norms=lambda page: (norms, {}))
    margin = lambda page, w: not 70 <= (w[0] + w[2]) / 2 <= 542
    assert checks._find_words(p, "ImageNet", [0], set(), margin) is None, "a body word is no margin note"
    assert checks._find_words(p, "ImageNet", [0], set())["text"] == "ImageNet."
    found = checks._find_words(p, "Recompute the numbers", [0], set(), margin)
    assert found["page"] == 0 and len(found["rects"]) == 3
    assert checks._find_words(p, "Recompute", [], set()) is None, "no page from synctex: not looked for everywhere"
    # a run's words are used: a later note of its last words is not placed inside it; past `skip` runs; a glued prefix
    used = set()
    assert checks._find_words(p, "Recompute the numbers", [0], used, margin) is not None
    assert checks._find_words(p, "the numbers", [0], used, margin) is None
    assert checks._find_words(p, "ImageNet", [0], set(), None, skip=1) is None, "its one run skipped: the line's own"
    glued = [(72, 100, 140, 110, "[TODO:Check"), (142, 100, 160, 110, "the"), (162, 100, 210, 110, "numbers]")]
    q = SimpleNamespace(words=lambda page: glued, norms=lambda page: ([checks._norm(w[4]) for w in glued], {}))
    assert checks._find_words(q, "Check the numbers", [0], set())["text"] == "[TODO:Check the numbers]"


def test_anonymity_rules():
    """review makes a paper anonymous only for the venues whose style means it (ACL, CVPR, ICCV, ECCV, WACV); acmart
    only by anonymous; elsarticle, llncs and IEEEtran never by an option; page 1's "Anonymous Authors" always."""
    def anonymous(preamble, words=()):
        p = SimpleNamespace(pages=1, preamble=preamble, words=lambda page: [(0, 0, 1, 1, w) for w in words])
        return checks._Paper.anonymous.func(p)
    assert not anonymous(r"\documentclass[sigconf,review]{acmart}")
    assert anonymous(r"\documentclass[sigconf,review,anonymous]{acmart}")
    assert not anonymous(r"\documentclass[sigconf,anonymous=false]{acmart}")
    assert not anonymous(r"\documentclass[review]{elsarticle}")
    for cls in ("llncs", "IEEEtran"):
        assert not anonymous(r"\documentclass[anonymous,review]{%s}" % cls)
    assert not anonymous(r"\documentclass[review]{article}")
    assert anonymous(r"\documentclass[anonymous]{article}")
    for style in ("acl", "cvpr", "iccv", "eccv", "wacv"):
        assert anonymous("\\documentclass{article}\n\\usepackage[review]{%s}" % style)
    assert not anonymous("\\documentclass{article}\n\\usepackage[final]{acl}")
    assert anonymous(r"\documentclass{llncs}", ["Anonymous", "Authors"])


# --- biblatex, two columns, what TeX skips; natbib and a long paper ------------------------------------------------

# Two columns: "data set" low in the left column, "dataset" at the top of the right one. biblatex (biber) with three
# keys of one title, an entry without a year, a thesis without a school and an undefined key; a list item opening with
# "Figure 1" beside "Fig. 1"; ranges of references (\Crefrange, \ref--\ref) over the middle figures; \label{sec:model}
# three times; a \todo and straight quotes only in a comment environment, \iffalse and \Verb; an overfull paragraph
# ending sec/one.tex, which has no blank line at its end, before main.tex's \section.
COLUMNS = r"""\documentclass[twocolumn]{article}
\usepackage{comment}
\usepackage{fancyvrb}
\usepackage{todonotes}
\usepackage[style=authoryear,backend=biber]{biblatex}
\usepackage{hyperref}
\usepackage{cleveref}
\addbibresource{refs.bib}
\begin{document}
\section{Introduction}\label{sec:intro}
Serverless platforms start a fresh sandbox for each request that finds no idle instance, and the cold start adds
hundreds of milliseconds to the response. Pools of warm sandboxes hide that delay at the price of idle memory, and
the size of a pool trades one against the other. This paper studies that trade on a trace of two weeks of requests
to a public platform, and it asks how large a pool must be to hide most cold starts at a small cost in memory.

We collect a new data set here, as \cite{smith2019}, \cite{smith2019b} and \cite{smith2019c} did, with
\cite{noyear}, \cite{thesis} and \cite{smith2019,nobody2020}.
\begin{itemize}
\item Figure~\ref{fig:a} shows the architecture of the pools.
\end{itemize}
As shown in Fig.~\ref{fig:a}, the pools are warm. \Crefrange{fig:p}{fig:r} show the curves, and
Figs.~\ref{fig:b}--\ref{fig:d} the costs. We call the tool with \Verb|run --mode "fast"| on every node.
\begin{comment}
Old text: \todo{rewrite this} and "slow".
\end{comment}
\iffalse
We used to say \todo{remove} and "fast".
\fi

\section{Model}\label{sec:model}
The model is small.
\subsection{Size}\label{sec:model}
The size is small.
\subsection{Cost}\label{sec:model}
The cost is small.
\newpage
The dataset is public.

\section{One}
\input{sec/one}
\section{Two}
The pools close the paper.

\begin{figure}[h]\centering\rule{2cm}{4mm}\caption{The architecture.}\label{fig:a}\end{figure}
\begin{figure}[h]\centering\rule{2cm}{4mm}\caption{Curve one.}\label{fig:p}\end{figure}
\begin{figure}[h]\centering\rule{2cm}{4mm}\caption{Curve two.}\label{fig:q}\end{figure}
\begin{figure}[h]\centering\rule{2cm}{4mm}\caption{Curve three.}\label{fig:r}\end{figure}
\begin{figure}[h]\centering\rule{2cm}{4mm}\caption{Cost one.}\label{fig:b}\end{figure}
\begin{figure}[h]\centering\rule{2cm}{4mm}\caption{Cost two.}\label{fig:c}\end{figure}
\begin{figure}[h]\centering\rule{2cm}{4mm}\caption{Cost three.}\label{fig:d}\end{figure}

\printbibliography
\end{document}
"""
SEC_ONE = "The pools hold sandboxes that wait for requests, and the last one\n" \
          "\\mbox{averyveryverylongunbreakabletracenamethatrunsfarpastthemargin} is long."  # no newline at its end
BIBLATEX = r"""@article{smith2019, author={Smith, John}, title={A Study of Warm Pools}, journaltitle={J. X}, date={2019}}
@article{smith2019b, author={Smith, John}, title={A study of warm pools}, journal={J. X}, year={2019}}
@article{smith2019c, author={Smith, Jon}, title={A Study of {Warm} Pools}, journal={J. Z}, year={2019}}
@article{noyear, author={Lee, Ann}, title={No Year Here}, journal={J. Y}}
@phdthesis{thesis, author={Kim, Bo}, title={A Thesis}, year={2020}}
"""

# natbib without hyperref: two undefined keys on one line, then 110 pages of \todo notes that print nothing
LONG = r"""\documentclass{article}
\usepackage[round]{natbib}
\newcommand{\todo}[1]{}
\begin{document}
\section{Intro}
As shown by \citet{nobody2020}, pools help \citep{devlin2019,missing2021}.

%s\bibliographystyle{plainnat}
\bibliography{refs}
\end{document}
""" % "".join("\\clearpage\nPage %d holds a short paragraph about the pools.\\todo{Recompute the numbers %d}\n"
              "A second note is here.\\todo{Check the cost %d}\n\n" % (k, k, k) for k in range(110))


# todonotes: a margin note that starts with a reference, an empty one, an inline one with a dash, \missingfigure{}
TODOS = r"""\documentclass{article}
\usepackage{todonotes}
\begin{document}
\section{Intro}\label{sec:intro}
We train on ImageNet and measure the cost of the pools.\todo{see Sec.~\ref{sec:intro} again}

The second paragraph says little.\todo{}

\missingfigure{}

\todo[inline]{Check this -- maybe drop it}

The last paragraph ends here.

%s\end{document}
""" % "".join("Paragraph %d of the filler text runs on for a while about the warm pools and their cost.%s\n\n"
              % (k, "\\todo{Note number %s fix}" % "ABCD"[k // 3] if k % 3 == 0 else "") for k in range(12))

# a draft switch whose other branch disables todonotes and hides \todo; todonotes' notes inline by default; a note of
# commands only
TODOS_DRAFT = r"""\documentclass{article}
\newif\ifdraft\drafttrue
\ifdraft\usepackage{todonotes}\else\usepackage[disable]{todonotes}\fi
\ifdraft\else\renewcommand{\todo}[2][]{}\fi
\setuptodonotes{inline}
\begin{document}
We check it here.\todo{Check the numbers}

The method is new.\todo{\textcolor{blue}{Revise}}

The end.
\end{document}
"""


def _compile(root, files):
    src = root / "src"
    for name, text in files.items():
        (src / name).parent.mkdir(parents=True, exist_ok=True)
        (src / name).write_text(text)
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Warm pools", "student": "Lin Zhou"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    return paper


@pytest.fixture(scope="module")
def columns(tmp_path_factory):
    if not shutil.which("biber", path=PATH):
        pytest.skip("needs biber")
    return _compile(tmp_path_factory.mktemp("columns"), {"main.tex": COLUMNS, "sec/one.tex": SEC_ONE,
                                                         "refs.bib": BIBLATEX})


@pytest.fixture(scope="module")
def long(tmp_path_factory):
    return _compile(tmp_path_factory.mktemp("long"), {"main.tex": LONG, "refs.bib": "@article{devlin2019, author = "
                                                      "{J. Devlin}, title = {Bert}, journal = {Proc. NAACL}, year = 2019}"})


@pytest.fixture(scope="module")
def todos(tmp_path_factory):
    return _compile(tmp_path_factory.mktemp("todos"), {"main.tex": TODOS})


def test_printed_todo_notes(todos):
    """Each note todonotes prints, at its words: one starting with a reference (its words before it), an empty one (at
    its line), \\missingfigure{} ("Missing figure"), an inline one with a dash (review 2026-10-31)."""
    notes = _by_code(_checks(todos))["todo_note"]
    texts = [c["text"] for c in notes]
    assert texts == ["Todo note · “see Sec. sec:intro again”", "Todo note · main.tex:7", "Missing figure · main.tex:9",
                     "Todo note · “Check this -- maybe drop…”"] + \
        ["Todo note · “Note number {} fix”".format(x) for x in "ABCD"], texts  # four margin notes, each found
    assert [_words(todos, c["places"][0]).replace("- ", "") for c in notes[4:]] == \
        ["Note number {} fix".format(x) for x in "ABCD"]  # hyphenated in the margin: "num- ber"
    assert _words(todos, notes[0]["places"][0]).startswith("see Sec.")
    assert "Missing figure" in _words(todos, notes[2]["places"][0])
    assert _words(todos, notes[3]["places"][0]).startswith("Check this")


def test_a_draft_switch_and_inline_notes(tmp_path):
    """The draft switch's other branch neither disables todonotes nor hides \\todo; \\setuptodonotes{inline} puts the
    notes in the column; a note of commands only is placed at its line (review 2026-10-31)."""
    paper = _compile(tmp_path, {"main.tex": TODOS_DRAFT})
    notes = _by_code(_checks(paper))["todo_note"]
    assert [c["text"] for c in notes] == ["Todo note · “Check the numbers”", "Todo note · “blue Revise”"]
    assert _words(paper, notes[0]["places"][0]) == "Check the numbers"
    assert notes[1]["places"][0]["page"] == 0


def test_biblatex_two_columns_and_what_tex_skips(columns):
    by = _by_code(_checks(columns))
    assert set(by) == {"undefined_cite", "label_twice", "same_work", "no_year", "no_venue", "spelling", "overfull",
                       "title_case", "leftovers"}
    # biblatex prints the titles as written (3 in title case, smith2019b's in sentence case) and noyear's empty date "()"
    assert [c["text"] for c in by["title_case"]] == ["Titles: 3 in title case, 1 in sentence case"]
    assert [c["key"] for c in by["leftovers"]] == ["leftovers|noyear|()"]
    # biblatex: the .aux's \abx@aux@cite and \addbibresource's .bib; an undefined key prints itself, in bold
    cite, = by["undefined_cite"]
    assert cite["text"] == "Undefined citation nobody2020" and [p["text"] for p in cite["places"]] == ["nobody2020"]
    assert "nobody2020" in _words(columns, cite["places"][0])
    assert cite["note"] == "This citation prints “nobody2020”: no entry in the references has the key nobody2020."
    same, = by["same_work"]
    assert same["text"] == "Same work 3× · smith2019 · smith2019b · smith2019c" and "one work 3 times" in same["detail"]
    assert [c["text"] for c in by["no_year"]] == ["No year · noyear"]
    assert [c["detail"] for c in by["no_venue"]] == ["The .bib entry thesis is an @phdthesis without a school."]
    twice, = by["label_twice"]
    assert twice["text"] == "Label sec:model defined 3×" and len(twice["places"]) == 3
    assert twice["note"] == "The label sec:model is defined 3 times, so references to it may print the wrong number."
    # reading order: the left column's "data set" first, though lower than the right column's "dataset"
    spelt, = by["spelling"]
    assert spelt["text"] == "“data set” 1× · “dataset” 1×"
    assert [_words(columns, p) for p in spelt["places"]] == ["data set", "dataset"]
    assert spelt["places"][0]["rects"][0][1] > spelt["places"][1]["rects"][0][1]
    # no ref_style: the item's "Figure 1" follows its bullet; no float_unreferenced: the ranges cover Figures 3 and 6;
    # no todo_note or straight_quotes from the comment environment, \iffalse or \Verb
    over, = by["overfull"]
    end = COLUMNS[:COLUMNS.index("\\section{Two}")].count("\n") + 1
    assert over["detail"].endswith("(sec/one.tex line 1 to main.tex line {}).".format(end))
    assert "averyveryverylong" in _words(columns, over["places"][0])


def test_natbib_citations_and_many_todo_notes(long, monkeypatch):
    by = _by_code(_checks(long))
    assert set(by) == {"undefined_cite"}  # the \todo notes print nothing: no slip a reader sees
    # one "?" each: the .log's warning of a key the table placed takes none
    cites = sorted(by["undefined_cite"], key=lambda c: c["places"][0]["rects"][0][0])
    assert [c["text"] for c in cites] == ["Undefined citation nobody2020", "Undefined citation missing2021"]
    assert [[p["text"] for p in c["places"]] for c in cites] == [["?"], ["?"]]
    assert all(c["note"].startswith("This citation prints “?”") for c in cites)
    # 220 notes that print nothing on 111 pages: none reported, the PDF's words searched only on their lines' pages, in
    # budget
    p = checks._Paper(long, ledger.load(long), 1, prose.load(long, 1), links.load(long, 1))
    for page in range(p.pages):
        p.words(page)
    start = time.monotonic()
    assert checks.todo_note(p) == []
    assert time.monotonic() - start < 0.5
    # as if the paper's \todo were not seen to print nothing: each note looked for on its own line only, none found
    # (its words are not printed there), in budget
    monkeypatch.setattr(checks, "TODO_HIDDEN", re.compile(r"(?!)()()"))
    start = time.monotonic()
    assert checks.todo_note(p) == []
    assert time.monotonic() - start < 0.5
