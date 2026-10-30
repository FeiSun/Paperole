"""Layouts that broke anchoring in ACL's two-column review mode (2026-10-15), rebuilt as
small synthetic papers: author-year citations in two columns, synctex naming a paragraph's last line, \\subref and
\\ref numbers, a ruler with a single number on a page of figures, a click beside a line of the other column, comment
order by column, a reference entry fixed by the student, a figure file replaced under the same name, a renamed
section file, punctuation that replaced a footnote, a missing \\input file, and a click on an empty page."""
import os
import shutil

import pymupdf
import pytest

from conftest import quiet, select
from paperole import anchor, api, cards, comments, project, state, texdiff

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

PREAMBLE = "\\documentclass[twocolumn]{article}\n\\usepackage[round]{natbib}\n"
BIB = r"""\begin{thebibliography}{9}
\bibitem[Wang et~al.(2026)]{Wang2026} A. Wang, B. Li, and C. Zhou. 2026. Cold starts in practice. In \emph{Proc. X}.
\bibitem[Chen and Li(2025)]{Chen2025} D. Chen and E. Li. 2025. Serverless in the wild. In \emph{Proc. Y}.
\bibitem[Sharma et~al.(2024)]{Sharma2024} G. Sharma, H. Ho, and I. Ito. 2024. Pricing idle memory. In \emph{Proc. W}.
\end{thebibliography}
"""
SENTENCES = [  # one sentence per source line, as in the ACL paper
    r"In the {} zone, serverless platforms start a fresh sandbox for every cold invocation~\citep{{Wang2026}}.",
    r"In the {} zone, many of these requests are short and arrive in unpredictable bursts.",
    r"In the {} zone, this waste may in turn raise the price of the service~\citep{{Sharma2024}}, as caches show.",
    r"In the {} zone, \citet{{Chen2025}} report that half of all functions are called less than once an hour.",
    r"In the {} zone, a simple keep-alive policy holds every instance for a fixed window after its last request.",
]
ZONES = "amber basalt cedar dune ember fjord garnet harbor indigo jasper".split()


def _paragraphs(zones):
    return "\n\n".join("\n".join(s.format(z) for s in SENTENCES) for z in zones)


def _write(src, body, preamble=PREAMBLE, files=None):
    src.mkdir(parents=True)
    (src / "main.tex").write_text(preamble + "\\begin{document}\n" + body + "\\end{document}\n")
    for name, data in (files or {}).items():
        path = src / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data) if isinstance(data, bytes) else path.write_text(data)
    return src


def _build(root, body, preamble=PREAMBLE, files=None):
    src = _write(root / "src", body, preamble, files)
    build = project.compile(src, root / "build", "main.tex", "pdflatex")
    assert build["status"] != "failed", build
    return src, build["pdf"]


def _figure(word):
    """A one-page PDF picture holding a word or two."""
    doc = pymupdf.open()
    page = doc.new_page(width=200, height=100)
    page.insert_text((20, 55), word, fontsize=16)
    page.draw_rect(pymupdf.Rect(5, 5, 195, 95))
    return doc.tobytes()


def _sentence_rects(pdf, page, words_wanted):
    """Rects (one per line) of the consecutive body words spelling words_wanted on a page."""
    words = comments.body_words(pymupdf.open(pdf)[page].get_text("words"))
    texts = [w[4] for w in words]
    want = words_wanted.split()
    for i in range(len(texts) - len(want) + 1):
        if texts[i:i + len(want)] == want:
            lines = {}
            for w in words[i:i + len(want)]:
                r = lines.get(w[5:7], list(w[:4]))
                lines[w[5:7]] = [min(r[0], w[0]), min(r[1], w[1]), max(r[2], w[2]), max(r[3], w[3])]
            return list(lines.values()), words[i]
    raise AssertionError("not on page {}: {}".format(page, words_wanted))


@pytest.fixture(scope="module")
def twocol(tmp_path_factory):
    root = tmp_path_factory.mktemp("twocol")
    return _build(root, "\\section{Introduction}\n" + _paragraphs(ZONES) + "\n\n" + BIB)


def test_sentences_with_author_year_citations(twocol):
    """A selection whose PDF text holds a citation is matched without what \\cite prints; its range takes in the
    \\cite command it ends or starts in (was: a fuzzy match running into the next source line)."""
    src, pdf = twocol
    lines = (src / "main.tex").read_text().split("\n")
    checked = set()
    for zone in ZONES:
        for page in range(pymupdf.open(pdf).page_count):
            for phrase, k in (("In the {} zone, serverless platforms start a fresh sandbox for every cold invocation "
                               "(Wang et al., 2026).", 0),
                              ("In the {} zone, Chen and Li (2025) report that half", 3)):
                try:
                    rects, first = _sentence_rects(pdf, page, phrase.format(zone))
                except AssertionError:
                    continue
                a, method, confidence = comments.locate(src, pdf, page, rects, phrase.format(zone))
                line = lines.index(SENTENCES[k].format(zone)) + 1
                assert (method, confidence, a["lines"]) == ("selection", 1.0, [line, line]), (zone, phrase)
                expected = SENTENCES[k].format(zone) if k == 0 else SENTENCES[k].format(zone)[:a["end"] - a["start"]]
                assert a["quote"] == expected
                checked.add("right" if first[0] > pymupdf.open(pdf)[page].rect.width / 2 else "left")
    assert checked == {"left", "right"}
    phrase = "Chen and Li (2025) report that half of all functions"  # starting with a citation: from its \citet
    rects, _ = _sentence_rects(pdf, 0, phrase)
    a, method, _ = comments.locate(src, pdf, 0, rects, phrase)
    assert (a["quote"], method) == ("\\citet{Chen2025} report that half of all functions", "selection")


def test_a_selection_of_only_a_citation_is_the_cite_command(twocol):
    src, pdf = twocol
    rects, _ = _sentence_rects(pdf, 0, "(Sharma et al., 2024),")
    a, method, _ = comments.locate(src, pdf, 0, rects, "(Sharma et al., 2024),")
    assert (a["quote"], method) == ("\\citep{Sharma2024}", "selection")


def test_synctex_naming_the_paragraph_last_line(twocol, monkeypatch):
    """synctex often gives a two-column paragraph's last line for all of its lines: the selection is searched for in
    the whole paragraph (was: the last line, at 0.5)."""
    src, pdf = twocol
    text = (src / "main.tex").read_text()
    lines = text.split("\n")
    first, last = (lines.index(SENTENCES[k].format("cedar")) + 1 for k in (0, len(SENTENCES) - 1))
    monkeypatch.setattr(comments, "_synctex", lambda *args: ("main.tex", last))
    page = next(p for p in range(pymupdf.open(pdf).page_count) if "cedar" in pymupdf.open(pdf)[p].get_text())
    phrase = "In the cedar zone, serverless platforms start a fresh sandbox for every cold invocation (Wang et al., 2026)."
    rects, _ = _sentence_rects(pdf, page, phrase)
    a, method, confidence = comments.locate(src, pdf, page, rects, phrase)
    assert (a["lines"], method, confidence) == ([first, first], "selection", 1.0)


def test_subref_and_reference_numbers(tmp_path):
    body = ("\\section{Results}\\label{sec:res}\n"
            "\\begin{figure}[h]\\centering\n\\begin{subfigure}{0.4\\linewidth}\\centering\\fbox{A}"
            "\\caption{Low}\\label{fig:low}\\end{subfigure}\n\\caption{Pool size.}\\label{fig:t}\\end{figure}\n"
            "Figure~\\ref{fig:t}(\\subref{fig:low}) shows similarly short waits at small pool sizes, as "
            "Section~\\ref{sec:res} says.\n\nThe second paragraph ends here.\n")
    src, pdf = _build(tmp_path, body, "\\documentclass{article}\n\\usepackage{subcaption}\n")
    phrase = "Figure 1(a) shows similarly short waits at small pool sizes, as Section 1 says."
    a, method, _ = comments.locate(src, pdf, 0, select(pdf, 0, phrase), phrase)
    assert method == "selection"
    assert a["quote"].startswith("Figure~\\ref{fig:t}(\\subref{fig:low}) shows") and a["quote"].endswith("says.")


def test_what_cite_and_ref_print():
    for text, expected in [
            ("diversity (Wang et al., 2026).", ("diversity .", False, True)),
            ("(e.g., Smith et al., 2020; Lee, 2021)", ("", True, True)),
            ("For example, Chen and Li (2025) report", ("For example, report", False, False)),
            ("Zhang et al. (2025a) to the system prompt", ("to the system prompt", True, False)),
            ("We use DeepSeek-V4-Flash (DeepSeek-AI et al.,", ("We use DeepSeek-V4-Flash", False, True)),
            ("2024b). Next one", (". Next one", True, False)),
            ("pay only for the time they run [7, 9].", ("pay only for the time they run .", False, True)),
            ("Figure 7(a) shows, as Section 2.2, Table 3, Eq. (4) and §4.2 say.",
             ("Figure shows, as Section , Table , Eq. and say.", False, False)),
            ("Appendix B.4 lists 34.7% in 2025 (34.7%, 2025).", ("Appendix lists 34.7% in 2025 (34.7%, 2025).", False,
                                                                 False)),
            ("1See Section 1 for details; 3D models stay", ("See Section for details; 3D models stay", False, False))]:
        assert comments.printed(text) == expected, text


def test_a_footnote_starting_with_its_mark(tmp_path):
    src, pdf = _build(tmp_path, "\\section{Metrics}\\label{sec:m}\nThe entropy\\footnote{See Section~\\ref{sec:m} "
                      "for metric details.} is computed per class.\n", "\\documentclass{article}\n")
    phrase = "1See Section 1 for metric details."  # the mark is glued to the footnote's first word
    a, method, _ = comments.locate(src, pdf, 0, select(pdf, 0, phrase), phrase)
    assert (a["quote"], method) == ("See Section~\\ref{sec:m} for metric details.", "selection")


def _ruler_pdf(path):
    """Page 1: two columns of text beside an ACL-like ruler (numbers right-aligned at x 25.5 in the left margin);
    page 2: a page of figures with one numbered line, its number alone in the margin."""
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    for k in range(40):
        page.insert_text((25.5 - pymupdf.get_text_length("{:03d}".format(k), fontsize=8), 100 + 14 * k),
                         "{:03d}".format(k), fontsize=8)
        page.insert_text((70, 100 + 14 * k), "words of the left column here", fontsize=10)
        page.insert_text((306, 100 + 14 * k), "words of the right column here", fontsize=10)
    page = doc.new_page(width=595, height=842)
    page.insert_text((25.5 - pymupdf.get_text_length("040", fontsize=8), 700), "040", fontsize=8)
    page.insert_text((70, 700), "A single numbered line under the figures", fontsize=10)
    page.insert_text((200, 300), "plot label", fontsize=10)
    doc.save(path)
    return path


def test_a_ruler_number_alone_on_a_page_of_figures(tmp_path):
    """The ruler's edge, learnt from the PDF's other pages, also takes a single number (was: a word, and text_x ran
    into the margin)."""
    pdf = _ruler_pdf(tmp_path / "ruler.pdf")
    words = pymupdf.open(pdf)[1].get_text("words")
    assert comments.margin_numbers(words) == set()  # one number is no ruler by itself
    assert {words[k][4] for k in comments.margin_numbers(words, comments.ruler_edges(pdf))} == {"040"}
    first, second = comments.text_x(pdf)
    assert first[0] == pytest.approx(70, abs=0.5) and second[0] == pytest.approx(70, abs=0.5)
    assert comments.columns(pdf)[0][0] == pytest.approx(pymupdf.get_text_length("words of the left column here",
                                                                                fontsize=10) / 2 + 70 + 118, abs=1)
    assert comments.columns(pdf)[1] is None


def test_a_click_beside_two_columns_takes_its_own_column():
    """Lines of the two columns are rarely at exactly the same height: within LEVEL points they are level, and the
    nearer column wins (was: the other column, 0.3 pt higher)."""
    left = [(70, 590.0, 290, 599.33, "left", 0, 0, 0)]
    right = [(306, 590.3, 526, 599.0, "right", 1, 0, 0)]
    assert comments._nearest_line(left + right, 545, 600) == (306, 590.3, 526, 599.0)
    assert comments._nearest_line(left + right, 40, 600) == (70, 590.0, 290, 599.33)


def test_a_click_in_the_column_gap_or_the_margin_anchors_to_its_line(twocol, monkeypatch):
    """A note clicked 4 pt left or right of a line, in the column gap or the margin, anchors to a source line of that
    line's words (was: synctex at the line's exact edge, which named another line for 41 of these 206 clicks, and for
    about a third of the clicks on a real two-column paper). A synctex line past the end of its file is no hit (was:
    IndexError, which reached the app as "Internal error")."""
    src, pdf = twocol
    doc = pymupdf.open(pdf)
    clicks = 0
    for page in range(doc.page_count):
        lines = {}
        for w in comments.body_words(doc[page].get_text("words")):
            lines.setdefault(w[5:7], []).append(w)
        for ws in lines.values():
            b = (min(w[0] for w in ws), min(w[1] for w in ws), max(w[2] for w in ws), max(w[3] for w in ws))
            if b[2] - b[0] < 150:  # full lines
                continue
            y = (b[1] + b[3]) / 2
            own = [comments._synctex(pdf, page, (w[0] + w[2]) / 2, (w[1] + w[3]) / 2, src)[1]
                   for w in (ws[0], ws[len(ws) // 2], ws[-1])]  # the source lines this line's words come from
            for x in (b[0] - 4, b[2] + 4):
                a, method, _ = comments.locate(src, pdf, page, [[x, y, x, y]], "")
                assert (a["file"], method) == ("main.tex", "line"), (page, x, y)
                assert a["lines"][0] <= max(own) and a["lines"][1] >= min(own), (page, x, y, a["lines"], own)
                clicks += 1
    assert clicks >= 150

    class Out:
        stdout = "Input:{}\nLine:999\n".format(src / "main.tex")
    monkeypatch.setattr(comments.subprocess, "run", lambda *args, **kwargs: Out())
    assert comments._synctex(pdf, 0, 100, 100, src) is None
    with pytest.raises(comments.EngineError, match="No LaTeX source"):
        comments.locate(src, pdf, 0, [[60, 100, 60, 100]], "")


def test_comments_are_listed_column_by_column(tmp_path):
    src = _write(tmp_path / "student", "\\section{Introduction}\n" + _paragraphs(ZONES) + "\n\n" + BIB)
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "T", "student": "S"}, quiet)
    st = api.ingest({"paper": str(paper), "source": str(src)}, quiet)["state"]
    assert st["round"]["build"]["status"] == "ok"
    pdf = st["round"]["build"]["pdf"]
    width = pymupdf.open(pdf)[0].rect.width
    picks = {}
    for zone in ZONES:  # a sentence at the top of the right column and one at the bottom of the left column
        try:
            rects, first = _sentence_rects(pdf, 0, "In the {} zone, many of these requests are short".format(zone))
        except AssertionError:
            continue
        side = "right" if first[0] > width / 2 else "left"
        if side == "right" and "right" not in picks or side == "left":
            picks[side] = rects
    ids = {}
    for side in ("right", "left"):
        r = api.comment({"paper": str(paper), "page": 0, "rects": picks[side], "text": "", "note": side}, quiet)
        ids[side] = r["id"]
    order = [c["id"] for c in state.build(paper)["comments"]]
    assert picks["right"][0][1] < picks["left"][0][1]  # the right one is higher on the page
    assert order == [ids["left"], ids["right"]]
    b = state.build(paper)["round"]["build"]
    assert b["columns"][0][0] == pytest.approx(width / 2, abs=10) and b["text_x"][0]
    with api.ledger.edit(paper) as lg:  # a round ingested before columns were stored: worked out from the PDF
        assert lg["rounds"][0]["build"].pop("columns") == b["columns"]
    assert state.build(paper)["round"]["build"]["columns"] == b["columns"]
    assert [c["id"] for c in state.build(paper)["comments"]] == [ids["left"], ids["right"]]


def test_a_reference_entry_is_one_sentence(tmp_path):
    """A comment on a reference's title is changed when the student fixes its venue or year (was: unchanged, and the
    fix unrequested); its card shows the whole entry."""
    body = "Pools cost memory~\\citep{Chen2025}.\n\n" + BIB
    old, old_pdf = _build(tmp_path / "v1", body)
    new, new_pdf = _build(tmp_path / "v2", body.replace("In \\emph{Proc. Y}", "In \\emph{Proceedings of the "
                                                         "Twelfth Symposium on Cloud Computing, held "
                                                         "in Seattle}"))
    text = (old / "main.tex").read_text()
    s = text.index("Serverless in the wild")
    assert texdiff.sentence(text, s, s + 5) == (text.index("\\bibitem[Chen"),
                                                text.index("\\bibitem[Sharma") - 1)
    phrase = "Serverless in the wild."
    a, method, _ = comments.locate(old, old_pdf, 0, select(old_pdf, 0, phrase), phrase)
    assert (a["quote"], method) == ("Serverless in the wild.", "selection")
    records, changes = anchor.carry(old, new, new_pdf, texdiff.diff_trees(old, new),
                                    [{"id": "R1-01", "anchor": a, "last": a}])
    assert records["R1-01"]["anchor_state"] == "changed"
    assert [c["attached_to"] for c in changes] == [["R1-01"]]
    ctx = cards.page_context(new, new_pdf, records["R1-01"]["anchor"], "highlight", False)
    assert ctx["text"].startswith("D. Chen and E. Li. 2025.") and ctx["text"].endswith("held in Seattle.")


def test_a_figure_replaced_under_the_same_name(tmp_path):
    body = ("Some text before the figure.\n\n\\begin{figure}[h]\\centering\n\\includegraphics[width=4cm]{figs/plot}\n"
            "\\caption{The plot of the pool size.}\\label{fig:plot}\n\\end{figure}\n\nA paragraph after the figure "
            "talks about something else entirely.\n")
    pre = "\\documentclass{article}\n\\usepackage{graphicx}\n"
    old, old_pdf = _build(tmp_path / "v1", body, pre, {"figs/plot.pdf": _figure("Alpha")})
    new, new_pdf = _build(tmp_path / "v2", body, pre, {"figs/plot.pdf": _figure("Beta")})
    diff = texdiff.diff_trees(old, new)
    [h] = diff.hunks
    assert (h["kind"], h["figure"], h["new_text"]) == ("replace", "figs/plot.pdf",
                                                         "\\includegraphics[width=4cm]{figs/plot}")
    page = pymupdf.open(old_pdf)[0]
    box = [page.search_for("Alpha")[0].x0 - 40, page.search_for("Alpha")[0].y0 - 20,
           page.search_for("Alpha")[0].x1 + 40, page.search_for("Alpha")[0].y1 + 20]
    a, _, _ = comments.locate_box(old, old_pdf, 0, box, "")
    text_anchor, _, _ = comments.locate(old, old_pdf, 0, select(old_pdf, 0, "talks about something else"), "")
    records, changes = anchor.carry(old, new, new_pdf, diff, [
        {"id": "R1-01", "anchor": a, "last": a, "box": True},
        {"id": "R1-02", "anchor": text_anchor, "last": text_anchor}])
    assert records["R1-01"]["anchor_state"] == "changed" and records["R1-02"]["anchor_state"] == "unchanged"
    [c] = changes
    assert (c["figure"], c["attached_to"], c["page"]) == ("figs/plot.pdf", ["R1-01"], 0)
    words = pymupdf.open(new_pdf)[0].get_text("words")  # synctex's box of the scaled picture, kept to the text
    assert all(min(w[0] for w in words) - 1.5 <= r[0] and r[2] <= max(w[2] for w in words) + 1.5 for r in c["rects"])
    assert diff.hunks == texdiff.diff_trees(old, old).hunks + [h]  # the same files: no change


def test_the_history_names_a_replaced_picture(tmp_path):
    """Each earlier round of a comment names the attached changes that replaced a picture file (history[].figures),
    so the app's thread says "new image file" for that round and "revised" for one whose attached edit was text, and
    the page each attached change is on (history[].change_pages)."""
    body = ("Some text before the figure.\n\n\\begin{figure}[h]\\centering\n\\includegraphics[width=4cm]{figs/plot}\n"
            "\\caption{The plot of the pool size.}\\label{fig:plot}\n\\end{figure}\n\nA paragraph after the figure "
            "talks about something else entirely.\n")
    pre = "\\documentclass{article}\n\\usepackage{graphicx}\n"
    edited = body.replace("something else entirely", "something else, the cost")
    sources = [_write(tmp_path / "v{}".format(k), text, pre, {"figs/plot.pdf": _figure(word)})
               for k, (text, word) in enumerate([(body, "Alpha"), (edited, "Beta"), (edited + "Done.\n", "Beta")], 1)]
    paper = tmp_path / "paper"

    def call(method, **params):
        return api.METHODS[method](dict(params, paper=str(paper)), quiet)
    call("new", title="T", student="S")
    call("ingest", source=str(sources[0]))
    pdf = paper / "r1" / "build" / "main.pdf"
    a = pymupdf.open(pdf)[0].search_for("Alpha")[0]
    fig = call("comment", page=0, rects=[[a.x0 - 40, a.y0 - 20, a.x1 + 40, a.y1 + 20]], text="", note="Larger?",
               kind="box")["state"]["comments"][0]["id"]
    phrase = "talks about something else entirely."
    text = call("comment", page=0, rects=select(pdf, 0, phrase), text=phrase, note="Which?")["state"]
    text = next(c["id"] for c in text["comments"] if c["id"] != fig)
    call("finish")
    s2 = call("ingest", source=str(sources[1]))["state"]
    [picture] = [ch["id"] for ch in s2["changes"] if ch.get("figure")]
    for cid in (fig, text):
        call("verdict", id=cid, verdict="reopened", note="Again.")
    call("finish")
    s3 = call("ingest", source=str(sources[2]))["state"]
    history = {c["id"]: c["history"] for c in s3["comments"]}
    assert [h["figures"] for h in history[fig]] == [[], [picture]]
    assert [h["figures"] for h in history[text]] == [[], []] and history[text][1]["changes"]
    # the page each attached change of that round is on (the app's "· 1 edit on p.1" for an earlier round)
    assert [h["change_pages"] for h in history[fig]] == [{}, {picture: 0}]
    assert history[text][1]["change_pages"] == {i: 0 for i in history[text][1]["changes"]}


def test_a_renamed_section_file(tmp_path):
    section = ("\\section{Conclusion}\nWe find that memory narrows the answers across models and tasks.\n"
               "Future work will look at other kinds of memory and at longer conversations with many users.\n")
    old, old_pdf = _build(tmp_path / "v1", "Intro text here.\n\n\\input{sections/07_conclusion}\n",
                          "\\documentclass{article}\n", {"sections/07_conclusion.tex": section})
    new, new_pdf = _build(tmp_path / "v2", "Intro text here.\n\n\\input{sections/08_conclusion}\n",
                          "\\documentclass{article}\n", {"sections/08_conclusion.tex": section.replace(
                              "across models and tasks", "across models on open-ended tasks")})
    diff = texdiff.diff_trees(old, new)
    assert diff.renamed == {"sections/07_conclusion.tex": "sections/08_conclusion.tex"}
    assert [(h["kind"], h["old_file"], h["new_file"]) for h in diff.hunks] == [
        ("replace", "main.tex", "main.tex"),
        ("replace", "sections/07_conclusion.tex", "sections/08_conclusion.tex")]
    text = (old / "sections/07_conclusion.tex").read_text()
    s = text.index("We find")
    a = {"file": "sections/07_conclusion.tex", "start": s, "end": text.index("tasks.") + 6,
         "quote": text[s:text.index("tasks.") + 6], "prefix": "", "suffix": "", "text": ""}
    records, changes = anchor.carry(old, new, new_pdf, diff, [{"id": "R1-01", "anchor": a, "last": a}])
    assert (records["R1-01"]["anchor_state"], records["R1-01"]["anchor"]["file"]) == \
        ("changed", "sections/08_conclusion.tex")
    main, conclusion = changes
    assert main["attached_to"] == [] and conclusion["attached_to"] == ["R1-01"]
    [point] = main["rects"]  # the \input's new name: a point where the section starts, not its line boxes
    heading = pymupdf.open(new_pdf)[0].search_for("Conclusion")[0]
    assert point[2] - point[0] == anchor.POINT_WIDTH and abs(point[0] - heading.x0) < 30 \
        and abs(point[1] - heading.y0) < 5


def test_punctuation_that_replaced_a_footnote_is_a_point(tmp_path):
    src, pdf = _build(tmp_path, "The entropy (see the appendix) is computed per class.\n", "\\documentclass{article}\n")
    text = (src / "main.tex").read_text()
    s = text.index("(see")
    page, [rect], _ = anchor.to_pdf(src, pdf, "main.tex", s, s + 1)
    word = pymupdf.open(pdf)[0].search_for("entropy")[0]
    assert rect[2] - rect[0] == anchor.POINT_WIDTH and abs(rect[0] - word.x1) < 1


def test_a_missing_input_file(tmp_path):
    src = _write(tmp_path / "src", "See Table~\\ref{tab:x} and \\citet{Nobody}.\n\\input{tables/missing}\n",
                 "\\documentclass{article}\n\\usepackage{natbib}\n")
    build = project.compile(src, tmp_path / "build", "main.tex", "pdflatex")
    assert build["status"] == "failed"
    [err] = build["errors"]
    line = (src / "main.tex").read_text().split("\n").index("\\input{tables/missing}") + 1
    assert (err["file"], err["line"]) == ("main.tex", line) and "tables/missing" in err["message"]
    assert not any("undefined" in w for w in build["warnings"])


def test_a_click_on_an_empty_page(tmp_path):
    """A note clicked on a page that prints only its number is not a note on the page number, and keeps its point
    in the next round (was: text "2", then the footer's line box)."""
    body = "First page text.\n\\clearpage\n\\null\n\\clearpage\nLast page text.\n"
    old, old_pdf = _build(tmp_path / "v1", body, "\\documentclass{article}\n")
    new, new_pdf = _build(tmp_path / "v2", body.replace("Last page", "Final page"), "\\documentclass{article}\n")
    a, method, confidence = comments.locate(old, old_pdf, 1, [[300, 400, 300, 400]], "")
    assert (a["text"], method, confidence) == ("", "line", 0.5)
    ctx = cards.page_context(old, old_pdf, a, "note", False)
    assert ctx["text"] == ""
    records, _ = anchor.carry(old, new, new_pdf, texdiff.diff_trees(old, new),
                              [{"id": "R1-01", "anchor": a, "last": a, "point": True}])
    r = records["R1-01"]["anchor"]
    assert (r["page"], r["rects"], r["text"]) == (1, [[300, 400, 300, 400]], "")


def test_words_drawn_in_a_picture(tmp_path):
    """An axis label inside a plot anchors to the plot's \\includegraphics, not to a caption with the same words, and
    its card is an image; the subcaption itself still anchors to the subcaption, not to the main caption that says
    "(a) request rate" too (the match nearest synctex's lines comes first)."""
    body = ("\\begin{figure}[h]\\centering\n\\begin{subfigure}{0.6\\linewidth}\\centering\n"
            "\\includegraphics[width=\\linewidth]{figs/rate}\n\\caption{Request rate}\n\\end{subfigure}\n"
            "\\caption{Effects of pool settings: (a) request rate for the large pool.}\n\\end{figure}\n")
    src, pdf = _build(tmp_path, body, "\\documentclass{article}\n\\usepackage{graphicx}\n\\usepackage{subcaption}\n",
                      {"figs/rate.pdf": _figure("Request rate")})
    page = pymupdf.open(pdf)[0]
    label, subcaption, _ = sorted(page.search_for("Request rate"), key=lambda r: r.y0)  # picture, subcaption,
    # and the main caption's "(a) request rate"
    text = (src / "main.tex").read_text()
    line = text[:text.index("\\includegraphics")].count("\n") + 1
    a, method, _ = comments.locate(src, pdf, 0, [list(label)], "Request rate")
    assert (a["quote"], method, a["text"]) == ("\\includegraphics[width=\\linewidth]{figs/rate}", "selection",
                                               "Request rate")
    assert cards.page_context(src, pdf, a, "highlight", False)["display"] == "image"
    a, method, _ = comments.locate(src, pdf, 0, [list(subcaption)], "")
    assert (a["lines"], a["quote"]) == ([line + 1, line + 1], "Request rate")
    # and back: a range in the subcaption (an edit of its case, say) is drawn on the subcaption, not on the plot's
    # label (synctex gives the subcaption's line the subfigure's box too)
    s = text.index("{Request rate}") + len("{Request ")
    page_no, rects, words = anchor.to_pdf(src, pdf, "main.tex", s, s + len("rate"))
    assert words == "rate" and pymupdf.Rect(rects[0]).intersects(subcaption)


def test_to_pdf_takes_in_what_a_citation_prints(twocol):
    """A carried range that ends with \\citep{…} is drawn over the citation's words too (was: up to the word before)."""
    src, pdf = twocol
    text = (src / "main.tex").read_text()
    line = SENTENCES[0].format("amber")
    s = text.index(line)
    page, rects, words = anchor.to_pdf(src, pdf, "main.tex", s, s + len(line))
    assert words.endswith("cold invocation (Wang et al., 2026).")
    s = text.index(SENTENCES[3].format("amber"))  # one that starts with \citet{…}
    e = text.index(" report", s)
    page, rects, words = anchor.to_pdf(src, pdf, "main.tex", text.index("\\citet", s), e)
    assert words == "Chen and Li (2025)"
    page, rects, words = anchor.to_pdf(src, pdf, "main.tex", text.index("\\citet", s), e + len(" report that half"))
    assert words == "Chen and Li (2025) report that half"


def test_a_range_that_prints_only_a_reference_number(tmp_path):
    """(\\S\\ref{…}) that replaced a footnote is drawn on the "(§1)" it prints (was: the whole line's box); a range
    that prints nothing a word can hold is a point after the word before it."""
    src, pdf = _build(tmp_path, "\\section{Metrics}\\label{sec:m}\nThe class entropy (\\S\\ref{sec:m}) is computed per "
                      "class~\\vspace{0pt}.\n", "\\documentclass{article}\n")
    text = (src / "main.tex").read_text()
    s = text.index("(\\S")
    page, rects, words = anchor.to_pdf(src, pdf, "main.tex", s, text.index(")", s) + 1)
    assert words == "(§1)" and len(rects) == 1
    s = text.index("~\\vspace")
    page, [rect], _ = anchor.to_pdf(src, pdf, "main.tex", s, text.index("}", s) + 1)
    word = pymupdf.open(pdf)[0].search_for("per class")[0]
    assert rect[2] - rect[0] == anchor.POINT_WIDTH and abs(rect[0] - word.x1) < 1


def test_a_sentence_inserted_at_the_start_of_a_paragraph(tmp_path):
    """The student adds the motivation the advisor asked for before the commented sentence, at the start of its
    paragraph: the comment is changed and the insert is attached (was: unchanged, the insert unrequested). A new
    paragraph before it does not touch it."""
    body = "The first paragraph ends here.\n\nIn this paper we focus on warm pools.\nMore text follows it.\n"
    pre = "\\documentclass{article}\n"
    old, _ = _build(tmp_path / "v1", body, pre)
    text = (old / "main.tex").read_text()
    s = text.index("In this paper")
    a = {"file": "main.tex", "start": s, "end": s + len("In this paper we focus on warm pools."),
         "quote": "In this paper we focus on warm pools.", "prefix": "", "suffix": "", "text": ""}
    for k, (new_body, state) in enumerate([
            (body.replace("\n\nIn this", "\n\nCold starts matter to users.\nIn this"), "changed"),
            (body.replace("\n\nIn this", "\n\nA new paragraph says why.\n\nIn this"), "unchanged")]):
        new, new_pdf = _build(tmp_path / "v{}".format(k + 2), new_body, pre)
        records, changes = anchor.carry(old, new, new_pdf, texdiff.diff_trees(old, new),
                                        [{"id": "R1-01", "anchor": a, "last": a}])
        assert records["R1-01"]["anchor_state"] == state
        [c] = changes
        assert c["attached_to"] == (["R1-01"] if state == "changed" else [])
        if state == "changed":  # the card shows the inserted sentence too, with the attached change's rects
            ctx = cards.page_context(new, new_pdf, records["R1-01"]["anchor"], "highlight", False, c["rects"])
            assert ctx["text"] == "Cold starts matter to users. In this paper we focus on warm pools."


def test_a_picture_is_its_own_sentence(tmp_path):
    """A comment on words drawn in a plot (anchored to its \\\\includegraphics) is not changed by an edit of the
    caption under it, only by a new picture file."""
    body = ("\\begin{figure}[h]\\centering\n\\includegraphics[width=4cm]{figs/plot}\n\\caption{Request rate}\n"
            "\\end{figure}\n")
    pre = "\\documentclass{article}\n\\usepackage{graphicx}\n"
    old, old_pdf = _build(tmp_path / "v1", body, pre, {"figs/plot.pdf": _figure("Alpha")})
    new, new_pdf = _build(tmp_path / "v2", body.replace("rate}", "Rate}"), pre, {"figs/plot.pdf": _figure("Alpha")})
    label = pymupdf.open(old_pdf)[0].search_for("Alpha")[0]
    a, _, _ = comments.locate(old, old_pdf, 0, [list(label)], "Alpha")
    assert a["quote"] == "\\includegraphics[width=4cm]{figs/plot}"
    records, changes = anchor.carry(old, new, new_pdf, texdiff.diff_trees(old, new),
                                    [{"id": "R1-01", "anchor": a, "last": a}])
    assert records["R1-01"]["anchor_state"] == "unchanged" and [c["attached_to"] for c in changes] == [[]]


def test_a_quote_does_not_start_inside_a_group(tmp_path):
    src, pdf = _build(tmp_path, "In this setting \\textit{Prewarm} alone has little effect.\n", "\\documentclass{article}\n")
    phrase = "Prewarm alone has little effect."
    a, _, _ = comments.locate(src, pdf, 0, select(pdf, 0, phrase), phrase)
    assert a["quote"] == "\\textit{Prewarm} alone has little effect."  # was "Prewarm} alone …"


def test_changes_inside_a_citation_key_or_a_footnote(tmp_path):
    """A corrected citation key is drawn on the words the \\cite prints (was: every line of the sentence); an edit in
    a footnote is drawn in the footnote, not on the paragraph around its mark, so a card does not take in the
    paragraph's other sentences as changed (found in a review)."""
    body = ("The pool is warm for most calls in practice. We therefore perform a check of the logs~\\citep{Chen2025}. "
            "The check covers two aspects of the data.\\footnote{See the details of the metric in the appendix of "
            "this paper.} More text follows here so that the paragraph runs over several lines of the page.\n\n" + BIB)
    old, old_pdf = _build(tmp_path / "v1", body.replace("logs~\\citep{Chen2025}", "logs~\\citep{Sharma2024}").replace(
        "details of the metric", "metric details"), "\\documentclass{article}\n\\usepackage[round]{natbib}\n")
    new, new_pdf = _build(tmp_path / "v2", body, "\\documentclass{article}\n\\usepackage[round]{natbib}\n")
    diff = texdiff.diff_trees(old, new)
    text = (new / "main.tex").read_text()
    page = pymupdf.open(new_pdf)[0]
    hunks = {h["new_text"].strip(): h for h in diff.hunks}
    key = next(h for t, h in hunks.items() if t == "Chen2025")
    _, rects, words = anchor.to_pdf(new, new_pdf, "main.tex", key["new_start"], key["new_end"])
    assert words == "(Chen and Li, 2025)." and len(rects) == 1
    note = next(h for t, h in hunks.items() if "details" in t)
    _, rects, words = anchor.to_pdf(new, new_pdf, "main.tex", note["new_start"], note["new_end"])
    mark = page.search_for("appendix of")[0]  # in the footnote, under the paragraph
    assert rects and all(r[1] >= mark.y0 - 12 for r in rects) and "details" in words
    assert text[note["new_start"]:note["new_end"]].strip() and "\\footnote" not in text[note["new_start"]:note["new_end"]]


def test_whole_input_lines_added_deleted_or_moved(tmp_path):
    """Whole \\input commands added, deleted or moved in main.tex are drawn where the file they read starts (insert)
    or where the next one starts (delete, with nothing between), else not at all (was: an unrelated line of
    main.tex)."""
    files = {"sections/{}.tex".format(k): "\\section{{{0}}}\n{0} text is here and goes on for a while.\n".format(name)
             for k, name in (("a", "Alpha"), ("b", "Bravo"), ("c", "Charlie"))}
    pre = "\\documentclass{article}\n"
    v1 = "Intro text here.\n\\input{sections/a}\n\\input{sections/c}\nMain text in the middle.\n\\input{sections/b}\n"
    old, _ = _build(tmp_path / "v1", v1, pre, files)
    for k, (body, expected) in enumerate([
            (v1.replace("\\input{sections/c}\n", "") + "\\input{sections/c}\n", {"insert": "Charlie", "none": ["delete"]}),
            (v1.replace("\\input{sections/a}\n", ""), {"delete": "Charlie"})]):
        new, new_pdf = _build(tmp_path / "v{}".format(k + 2), body, pre, files)
        _, changes = anchor.carry(old, new, new_pdf, texdiff.diff_trees(old, new), [])
        page = pymupdf.open(new_pdf)[0]
        starts = {name: page.search_for(name)[0] for name in ("Bravo", "Charlie")}
        drawn = {}
        for c in changes:
            assert c["file"] == "main.tex"
            if c["rects"]:
                [r] = c["rects"]
                assert r[2] - r[0] == anchor.POINT_WIDTH
                drawn[c["kind"]] = next(n for n, s in starts.items() if abs(r[1] - s.y0) < 5 and abs(r[0] - s.x0) < 30)
            else:
                drawn.setdefault("none", []).append(c["kind"])
        assert drawn == expected, changes


def _picture(word, height):
    """A one-page PDF picture 200 pt wide holding a word, framed."""
    doc = pymupdf.open()
    page = doc.new_page(width=200, height=height)
    page.insert_text((20, height / 2), word, fontsize=16)
    page.draw_rect(pymupdf.Rect(5, 5, 195, height - 5))
    return doc.tobytes()


def test_a_carried_box_follows_a_resized_picture(tmp_path):
    """A box drawn around a figure is drawn around the new picture when the student replaces it with a taller one,
    and back when it is shorter again; a box moved off the page is kept inside the page's text (found in a
    review: the bottom 40% of the new plot, then a box from the page's top edge)."""
    body = ("\\begin{figure}[t]\\centering\n\\includegraphics[width=5cm]{figs/plot}\n\\caption{The plot of the pool "
            "size over the day.}\\label{fig:plot}\n\\end{figure}\nA paragraph after the figure talks about something "
            "else entirely, and it goes on for a while so that the page has some text on it.\n")
    pre = "\\documentclass{article}\n\\usepackage{graphicx}\n"
    old, old_pdf = _build(tmp_path / "v1", body, pre, {"figs/plot.pdf": _picture("Alpha", 100)})
    new, new_pdf = _build(tmp_path / "v2", body, pre, {"figs/plot.pdf": _picture("Beta", 250)})

    def frame(pdf):
        return [r for kind, r in pymupdf.open(pdf)[0].get_bboxlog() if kind == "stroke-path"][0]
    f = frame(old_pdf)
    box = [f[0] - 4, f[1] - 4, f[2] + 4, f[3] + 4]
    a, _, _ = comments.locate_box(old, old_pdf, 0, box, "")
    item = {"id": "R1-01", "anchor": a, "last": a, "box": True}
    records, _ = anchor.carry(old, new, new_pdf, texdiff.diff_trees(old, new), [item], old_pdf=old_pdf)
    g = frame(new_pdf)
    assert records["R1-01"]["anchor"]["rects"] == [[round(v, 2) for v in (g[0] - 4, g[1] - 4, g[2] + 4, g[3] + 4)]]
    b = records["R1-01"]["anchor"]
    back, _ = anchor.carry(new, old, old_pdf, texdiff.diff_trees(new, old), [dict(item, anchor=b, last=b)],
                           old_pdf=new_pdf)
    assert back["R1-01"]["anchor"]["rects"] == [[round(v, 2) for v in box]]
    back, _ = anchor.carry(new, old, old_pdf, texdiff.diff_trees(new, old), [dict(item, anchor=b, last=b)])
    # without the old PDF the box keeps its size, but not past the picture and the page's text (was: the page's edge)
    assert back["R1-01"]["anchor"]["rects"][0][1] == round(f[1] - anchor.BOX_PAD, 2)


def _plot(word, background, k=1.0):
    """A PDF plot 480 x 210 pt (times k: 1, more than a column wide), a word and an inset frame, on a white
    background (a matplotlib figure) or not."""
    doc = pymupdf.open()
    page = doc.new_page(width=480 * k, height=210 * k)
    if background:
        page.draw_rect(page.rect, color=None, fill=(1, 1, 1))
    page.insert_text((40 * k, 110 * k), word, fontsize=40 * k)
    page.draw_rect(pymupdf.Rect(20 * k, 20 * k, 460 * k, 190 * k))
    return doc.tobytes()


def test_a_replaced_picture_is_drawn_where_it_is_printed(tmp_path):
    """synctex gives a picture scaled to \\linewidth its natural size from its bottom-left corner: a replaced picture
    in a one-column figure on a two-column page was a change across both columns, its card's crop and text took in
    the other column (demo round 4, c01: [70.87, 242.59, 527.32, 451.39] for a picture at x 70.9-289.1), and one in
    a figure* on a page of floats was cut to the caption's words. Each is now the picture as drawn: its background,
    or within its column (the text's width for figure*) just around its drawings; a small picture scaled up is its
    printed size (synctex gives its natural size too)."""
    figure = ("\\begin{{{env}}}[t]\\centering\n\\includegraphics[width=\\linewidth]{{figs/{name}}}\n"
              "\\caption{{The {name} of the pool size.}}\n\\end{{{env}}}\n\n")
    body = ("\\section{Introduction}\n" + _paragraphs(ZONES[:2]) + "\n\n" + figure.format(env="figure", name="plot")
            + _paragraphs(ZONES[2:4]) + "\n\n" + figure.format(env="figure", name="bare") + _paragraphs(ZONES[4:6])
            + "\n\n" + figure.format(env="figure*", name="wide") + _paragraphs(ZONES[6:8]) + "\n\n"
            + figure.format(env="figure", name="small") + _paragraphs(ZONES[8:]) + "\n")
    pre = PREAMBLE + "\\usepackage{graphicx}\n"
    words = {"plot": ("Alpha", "Beta"), "bare": ("Gamma", "Delta"), "wide": ("Kappa", "Omega"),
             "small": ("Iota", "Sigma")}
    old, old_pdf = _build(tmp_path / "v1", body, pre, {"figs/{}.pdf".format(k): _plot(w[0], k != "bare",
                                                                                      0.25 if k == "small" else 1)
                                                       for k, w in words.items()})
    new, new_pdf = _build(tmp_path / "v2", body, pre, {"figs/{}.pdf".format(k): _plot(w[1], k != "bare",
                                                                                      0.25 if k == "small" else 1)
                                                       for k, w in words.items()})
    diff = texdiff.diff_trees(old, new)
    _, changes = anchor.carry(old, new, new_pdf, diff, [])
    cards.change_details(old, old_pdf, new, new_pdf, diff, changes)
    assert sorted(c["figure"] for c in changes) == ["figs/bare.pdf", "figs/plot.pdf", "figs/small.pdf",
                                                     "figs/wide.pdf"]
    for c in changes:
        name = c["figure"][5:-4]
        [r] = c["rects"]
        stamp = anchor._stamp(new_pdf)
        gap = anchor._gap(anchor._layout(stamp), c["page"])
        assert gap is not None and abs((r[3] - r[1]) / (r[2] - r[0]) - 210 / 480) < 0.02, (name, r)
        word = pymupdf.open(new_pdf)[c["page"]].search_for(words[name][1])[0]
        assert r[0] <= word.x0 and r[1] <= word.y0 and word.x1 <= r[2] and word.y1 <= r[3], (name, r)
        drawn = [g for g in anchor._graphics(stamp, c["page"]) if abs(g[0] - r[0]) < 1 and abs(g[3] - r[3]) < 1
                 and g[2] - g[0] > 100]
        if name == "wide":
            assert r[0] < gap - 100 and r[2] > gap + 100 and r == [round(v, 2) for v in drawn[0]]
        else:
            assert (r[2] <= gap if r[0] < gap else r[0] >= gap), (name, r)  # in its column
            assert name != "plot" or r[2] <= gap and r == [round(v, 2) for v in drawn[0]]  # its background
            assert name != "small" or r == [round(v, 2) for v in drawn[0]] and r[2] - r[0] > 200
        clip = c["context"]["now"]["clip"]
        assert c["context"]["now"]["text"] == words[name][1] and c["context"]["before"]["text"] == words[name][0]
        assert name == "wide" or (clip[2] <= gap + cards.PAD if r[0] < gap else clip[0] >= gap - cards.PAD)
