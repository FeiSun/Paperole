"""Engine accuracy fixes from BACKLOG O3–O10, O23 and O24 (2026-10-16), each on a small synthetic paper: wrapped
source lines, paragraph splits and joins, a section dropped by commenting out its \\input, renamed files, words
drawn twice in a picture, reference entries, sentence ends, carried click notes, and read state."""
import os
import re
import shutil
from pathlib import Path

import pymupdf
import pytest

from conftest import quiet, select
from paperole import anchor, api, cards, comments, ledger, project, prose, texdiff

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

VOCAB = ("serverless platforms start fresh sandbox every cold invocation delay adds main complaint developers latency "
         "sensitive services keeping instances warm hides costs memory otherwise tenants platform raises price simple "
         "keepalive policy holds fixed window after last request whatever arrival pattern function looks practice "
         "cheap explain wastes rarely misses starts bursts experimentation characterization reconfigurability "
         "nevertheless approximately").split()


def _numbers(seed):
    """A fixed stream of pseudo-random numbers (a linear congruential generator), the same on every machine."""
    while True:
        seed = (seed * 1103515245 + 12345) % 2 ** 31
        yield seed


def _build(root, body, preamble="\\documentclass{article}\n", files=None):
    src = root / "src"
    src.mkdir(parents=True)
    (src / "main.tex").write_text(preamble + "\\begin{document}\n" + body + "\\end{document}\n")
    for name, data in (files or {}).items():
        path = src / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data) if isinstance(data, bytes) else path.write_text(data)
    build = project.compile(src, root / "build", "main.tex", "pdflatex")
    assert build["status"] != "failed", build
    return src, Path(build["pdf"])


def _wrapped_body(seed, paragraphs=10):
    """Paragraphs of one to four sentences, one sentence per source line, of 8 to 70 words: many source lines wrap
    over several PDF lines, start with a word hyphenated at the end of the line above, or end on a line of their
    own."""
    rnd = _numbers(seed)
    out = []
    for _ in range(paragraphs):
        lines = []
        for _ in range(1 + next(rnd) % 4):
            words = [VOCAB[next(rnd) % len(VOCAB)] for _ in range(8 + next(rnd) % 63)]
            lines.append(" ".join(words).capitalize() + ".")
        out.append("\n".join(lines))
    return "\n\n".join(out) + "\n"


@pytest.mark.parametrize("preamble", ["\\documentclass{article}\n", "\\documentclass[twocolumn]{article}\n"],
                         ids=["one column", "two columns"])
def test_o3_a_wrapped_source_line_is_drawn_whole(tmp_path, preamble):
    """A carried range covering a source line that TeX sets over several PDF lines gets every word of it (was: cut
    short when the line's first word was hyphenated onto the line above, or its last words sat on a PDF line that
    synctex gives to the next source line)."""
    src, pdf = _build(tmp_path, _wrapped_body(7), preamble)
    text = (src / "main.tex").read_text()
    doc = pymupdf.open(pdf)
    pages = ["".join(comments._fold(w[4]) for w in comments.body_words(page.get_text("words"))) for page in doc]
    checked, pos = 0, 0
    for line in text.split("\n"):
        start, pos = pos, pos + len(line) + 1
        if not line or line.startswith("\\") or not any(comments._fold(line) in p for p in pages):
            continue  # a line across a page break: an anchor has one page
        page, rects, words = anchor.to_pdf(src, pdf, "main.tex", start, start + len(line))
        assert comments._fold(words) == comments._fold(line), line
        checked += 1
    assert checked >= 20


def _word(text, x0, y0, block, line, width=None, height=10.0):
    return (x0, y0, x0 + (width or 6 * len(text)), y0 + height, text, block, line, 0)


def test_o9_sentence_ends_in_the_pdf():
    """Sentence ends in PDF words (cards): not after Sect. or a month, but after a footnote mark glued to the full
    stop or set as its own raised word, and not at an enumerate number, which starts an item like a bullet."""
    for w, nxt, ends in [("Sect.", "3", False), ("Aug.", "2024", False), ("Sept.", "12", False),
                         ("practice.1", "The", True), ("2024).2", "We", True), ("v1.2", "The", False)]:
        assert cards._ends(w, nxt) == ends, (w, nxt)
    mark = [_word("cost.", 70, 100, 0, 0), _word("1", 101, 97, 0, 1, width=4, height=7), _word("The", 110, 100, 0, 2),
            _word("end.", 140, 100, 0, 2)]
    ends, _ = cards._boundaries(mark)
    assert cards._sentence(ends, 0) == (0, 1) and cards._sentence(ends, 2) == (2, 3)
    mark[2] = _word("and", 110, 100, 0, 2)  # "approx.1 and": no end
    assert cards._sentence(cards._boundaries(mark)[0], 0) == (0, 3)
    items = [_word("1.", 80, 100, 0, 0), _word("Fast", 95, 100, 0, 0), _word("startup", 130, 100, 0, 0),
             _word("2.", 80, 112, 1, 0), _word("Low", 95, 112, 1, 0), _word("cost", 130, 112, 1, 0)]
    ends, paras = cards._boundaries(items)
    assert paras == [0, 0, 0, 1, 1, 1] and cards._sentence(ends, 1) == (0, 2)


def test_o9_sentence_ends_in_the_source():
    """Sentence ends in the source (texdiff.sentence, the reach of a comment's changes): not after et al., Sect. or
    an initial; after a full stop before a footnote; and at each \\item."""
    text = ("Lee et al. found that pools help, see Sect. 3 of J. Smith.\nThe pool is cheap.\\footnote{See the "
            "appendix.} Next sentence here.\n\\begin{itemize}\n\\item First item without a stop\n\\item[b] Second "
            "item.\n\\end{itemize}\n")
    for phrase, sentence in [("found", "Lee et al. found that pools help, see Sect. 3 of J. Smith."),
                             ("cheap", "The pool is cheap."), ("Next", "Next sentence here."),
                             ("First", "First item without a stop"), ("Second", "Second item.")]:
        s = text.index(phrase)
        assert text[slice(*texdiff.sentence(text, s, s + len(phrase)))] == sentence, phrase


def test_o9_cards_show_the_whole_sentence(tmp_path):
    """On a typeset page: a card's sentence runs past Sect.~2 and Aug., ends after a footnote mark, and an
    enumerate item is shown whole, with its number, not with the next item's number."""
    body = ("Pools cost memory in practice.\\footnote{See the appendix for the numbers.} The controller resizes the "
            "pool once per interval, as Sect.~2 explains in more detail.\nThe trace was collected in Aug. 2024 at a "
            "large provider. It covers two weeks of traffic.\n\nThe method has three parts:\n\\begin{enumerate}\n"
            "\\item The forecaster predicts the arrival rate\n\\item The sizer turns the rate into a pool size\n"
            "\\end{enumerate}\nAfter the list comes a closing paragraph.\n")
    src, pdf = _build(tmp_path, body)
    for phrase, sentence in [
            ("in", "Pools cost memory in practice.1"),
            ("controller resizes", "The controller resizes the pool once per interval, as Sect. 2 explains in more "
                                   "detail."),
            ("trace was", "The trace was collected in Aug. 2024 at a large provider."),
            ("arrival", "1. The forecaster predicts the arrival rate")]:
        a, _, _ = comments.locate(src, pdf, 0, select(pdf, 0, phrase), phrase)
        assert cards.page_context(src, pdf, a, "highlight", False)["text"] == sentence, phrase


def _call(paper, method, **params):
    return api.METHODS[method](dict(params, paper=str(paper)), quiet)


def _paper(tmp_path, versions, preamble="\\documentclass{article}\n", files=None):
    """(a new review folder, [a source folder per body in versions, with files[k] beside its main.tex])."""
    paper, sources = tmp_path / "paper", []
    _call(paper, "new", title="T", student="S")
    for k, body in enumerate(versions, 1):
        src = tmp_path / "v{}".format(k)
        src.mkdir()
        (src / "main.tex").write_text(preamble + "\\begin{document}\n" + body + "\\end{document}\n")
        for name, data in ((files or [{}] * len(versions))[k - 1]).items():
            (src / name).parent.mkdir(parents=True, exist_ok=True)
            (src / name).write_text(data)
        sources.append(src)
    return paper, sources


PARAGRAPHS = ("Serverless platforms start a fresh sandbox for every cold invocation, and the delay this adds is the\n"
              "main complaint of developers who run latency-sensitive services on them. Keeping instances warm\n"
              "hides the delay but costs memory.\n\n"
              "A simple keep-alive policy holds every instance for a fixed window after its last request. It is\n"
              "cheap to run and easy to explain, yet it wastes memory on functions that are called rarely and\n"
              "still misses many cold starts. Our controller sizes the pool from a forecast instead.\n\n"
              "The controller runs once per interval and resizes the warm pool to the smallest size whose\n"
              "predicted cold-start rate is below the target.\n")


def test_o10_a_carried_click_note_stays_a_point(tmp_path):
    """A note clicked in the margin beside a line is a point in the next round too, beside the same line where the
    text moved, and its Now block marks no words (was: the line's words, so the whole sentence was marked)."""
    insert = "An opening sentence pushes every line of the paper down by a few lines of text on the page.\n\n"
    paper, (v1, v2) = _paper(tmp_path, [PARAGRAPHS, insert + PARAGRAPHS])
    _call(paper, "ingest", source=str(v1))
    pdf1 = paper / "r1" / "build" / "main.pdf"
    line = pymupdf.open(pdf1)[0].search_for("cheap to run and easy to explain")[0]
    y = (line.y0 + line.y1) / 2
    _call(paper, "comment", page=0, rects=[[540, y, 540, y]], text="", note="Cite this.", kind="note")
    _call(paper, "finish")
    [c] = _call(paper, "ingest", source=str(v2))["state"]["comments"]
    [r] = c["rects"]
    pdf2 = paper / "r2" / "build" / "main.pdf"
    now = pymupdf.open(pdf2)[0].search_for("cheap to run and easy to explain")[0]
    assert r[0] == r[2] == 540 and r[1] == r[3] and now.y0 <= r[1] <= now.y1 and now.y0 > line.y0 + 10
    ctx = c["context"]
    assert ctx["sel"] == [] and ctx["text"].startswith("It is cheap to run and easy to explain")


def _carry_texts(tmp_path, old_text, new_text, phrases):
    """anchor.carry between two one-file trees, without a PDF: R1-01, R1-02, … on the phrases of old_text."""
    old, new = tmp_path / "old", tmp_path / "new"
    for root, text in ((old, old_text), (new, new_text)):
        root.mkdir()
        (root / "m.tex").write_text(text)
    items = []
    for k, phrase in enumerate(phrases, 1):
        s = old_text.index(phrase)
        a = {"file": "m.tex", "start": s, "end": s + len(phrase), "quote": phrase,
             "prefix": old_text[max(0, s - 40):s], "suffix": old_text[s + len(phrase):s + len(phrase) + 40]}
        items.append({"id": "R1-{:02d}".format(k), "anchor": a, "last": a})
    return anchor.carry(old, new, tmp_path / "no.pdf", texdiff.diff_trees(old, new), items)


A = "The controller runs once per interval and reads the recent arrival counts of each function."
B = "It then updates a smoothed rate estimate for every function that it has seen so far."
C = "Finally it resizes the warm pool to the smallest size whose predicted rate is below the target."


@pytest.mark.parametrize("old, new, across", [
    (A + " " + B + "\n" + C + "\n", A + " " + B + "\n\n" + C + "\n", "so far.\nFinally"),  # split
    (A + "\n\n" + B + " " + C + "\n", A + "\n" + B + " " + C + "\n", "function.\n\nIt then"),  # joined
    (A + "\n% a note\n" + B + " " + C + "\n", A + "\n\n% a note\n" + B + " " + C + "\n",  # split before a comment
     "function.\n% a note\nIt then")], ids=["split", "joined", "split before a comment"])
def test_o4_a_paragraph_split_or_joined_changes_no_comment(tmp_path, old, new, across):
    """Comments on the sentences beside a paragraph split or join stay unchanged and the change is not theirs (was:
    changed, and the break attached to them); one on a range across the break is attached but unchanged."""
    records, changes = _carry_texts(tmp_path, old, new, [A, B, C, across])
    assert [r["anchor_state"] for r in records.values()] == ["unchanged"] * 4
    [change] = changes
    assert change["attached_to"] == ["R1-04"]


SECTIONS = {
    "sections/intro.tex": "\\section{Introduction}\nServerless platforms start a fresh sandbox for every cold "
                          "invocation.\nKeeping instances warm hides the delay but costs memory.\n",
    "sections/related.tex": "\\section{Related Work}\nPrior work keeps every instance for a fixed window after its "
                            "last request.\nOthers predict the next request from a histogram of idle times.\n",
    "sections/method.tex": "\\section{Method}\nOur controller sizes the warm pool from a short-term forecast.\nIt runs "
                           "once per interval and needs no changes to the platform.\n"}
INPUTS = "\\input{sections/intro}\n\\input{sections/related}\n\\input{sections/method}\n"


def _versions(tmp_path, bodies):
    """[(src, pdf)] of one build per (body, files) pair, as ingest compiles them."""
    return [_build(tmp_path / "v{}".format(k), body, files=files) for k, (body, files) in enumerate(bodies, 1)]


def _carry(old, new, items):
    """anchor.carry from build old to build new ((src, pdf) each), with the diff of their trees and builds."""
    (old_src, old_pdf), (new_src, new_pdf) = old, new
    diff = texdiff.diff_trees(old_src, new_src, old_pdf.parent, new_pdf.parent)
    return anchor.carry(old_src, new_src, new_pdf, diff, items, old_pdf=old_pdf)


def _item(src, file, phrase, cid="R1-01"):
    text = (src / file).read_text()
    s = text.index(phrase)
    a = {"file": file, "start": s, "end": s + len(phrase), "quote": phrase, "prefix": text[max(0, s - 40):s],
         "suffix": text[s + len(phrase):s + len(phrase) + 40], "text": phrase, "page": 0, "rects": []}
    return {"id": cid, "anchor": a, "last": a}


@pytest.mark.parametrize("how", ["commented out", "file deleted"])
def test_o5_a_section_whose_input_is_dropped_is_gone(tmp_path, how):
    """A comment in a section the student drops, by commenting out its \\input or deleting the file and the line, is
    gone at the place where the section was, with a page, and the dropped \\input is its change (was: unchanged and
    without a page, or an orphan)."""
    files = dict(SECTIONS)
    if how == "commented out":
        body = INPUTS.replace("\\input{sections/related}", "% \\input{sections/related}")
    else:
        body = INPUTS.replace("\\input{sections/related}\n", "")
        del files["sections/related.tex"]
    old, new = _versions(tmp_path, [(INPUTS, SECTIONS), (body, files)])
    items = [_item(old[0], "sections/related.tex", "Prior work keeps every instance", "R1-01"),
             _item(old[0], "sections/intro.tex", "Keeping instances warm", "R1-02")]
    records, changes = _carry(old, new, items)
    gone, kept = records["R1-01"], records["R1-02"]
    assert (gone["anchor_state"], gone["anchor"]["file"], gone["confidence"]) == ("gone", "main.tex", 1.0)
    [point] = gone["anchor"]["rects"]
    heading = pymupdf.open(new[1])[0].search_for("Method")[0]
    assert gone["anchor"]["page"] == 0 and abs(point[1] - heading.y0) < 5  # where the Method section starts now
    assert point[2] - point[0] == anchor.POINT_WIDTH
    assert kept["anchor_state"] == "unchanged"
    dropped = next(c for c in changes if c["file"] == "main.tex")
    assert dropped["kind"] == "delete" and "R1-01" in dropped["attached_to"]


def test_o5_a_section_left_out_by_the_build_with_its_input_in_place_is_not_gone(tmp_path):
    """A section the build does not read while its \\include is still in the source (\\includeonly here; a build
    that stopped early is the same) is not taken for one the student dropped: it is not gone."""
    body, pre = INPUTS.replace("\\input", "\\include"), "\\documentclass{article}\n"
    old = _build(tmp_path / "v1", body, pre, SECTIONS)
    new = _build(tmp_path / "v2", body, pre + "\\includeonly{sections/intro,sections/method}\n", SECTIONS)
    assert texdiff.read_files(new[0], new[1].parent) >= {"main.tex", "sections/intro.tex"}
    assert "sections/related.tex" not in texdiff.read_files(new[0], new[1].parent)
    records, _ = _carry(old, new, [_item(old[0], "sections/related.tex", "Prior work keeps every instance")])
    assert records["R1-01"]["anchor_state"] == "unchanged"


def test_o6_a_renamed_section_that_grew_or_was_left_behind(tmp_path):
    """A section file renamed with its \\input and grown by a new paragraph is still compared as one file (was: a
    delete and an insert, its comments "moved"); so is one copied to a new name with the old file left in the tree,
    unread (was: the comment stayed in the old file, unchanged and without a page)."""
    grown = SECTIONS["sections/related.tex"].replace("\nOthers", "\n\nA third line of work reuses idle instances "
                                                     "across functions of one tenant, which saves memory but leaks "
                                                     "timing information between functions and needs care.\n\nOthers")
    renamed = dict(SECTIONS, **{"sections/background.tex": grown})
    del renamed["sections/related.tex"]
    left = dict(SECTIONS, **{"sections/background.tex": SECTIONS["sections/related.tex"]})  # related.tex stays
    body = INPUTS.replace("sections/related", "sections/background")
    v1, v2, v3 = _versions(tmp_path, [(INPUTS, SECTIONS), (body, renamed), (body, left)])
    for new in (v2, v3):
        diff = texdiff.diff_trees(v1[0], new[0], v1[1].parent, new[1].parent)
        assert diff.renamed == {"sections/related.tex": "sections/background.tex"}
        assert all(h["kind"] != "move" for h in diff.hunks)
        records, _ = _carry(v1, new, [_item(v1[0], "sections/related.tex", "a histogram of idle times")])
        r = records["R1-01"]
        assert (r["anchor_state"], r["anchor"]["file"], r["anchor"]["page"]) == \
            ("unchanged", "sections/background.tex", 0)
        assert r["anchor"]["text"] == "a histogram of idle times."


def _two_plots(label, width=400, height=150):
    """A picture of two plots side by side, each with the same axis label (one PDF image)."""
    doc = pymupdf.open()
    page = doc.new_page(width=width, height=height)
    for x0 in (10, width / 2 + 10):
        page.draw_rect(pymupdf.Rect(x0 + 30, 10, x0 + width / 2 - 30, height - 30))
        page.insert_text((x0 + 60, height - 10), label, fontsize=12)
    return doc.tobytes()


def test_o7_a_word_drawn_twice_in_a_picture_keeps_its_place(tmp_path):
    """A comment on the left one of two equal axis labels in one picture stays on the left label in the next round,
    with the figure moved down the page (was: the label nearest the picture's centre, the right one)."""
    figure = ("\\begin{figure}[h]\\centering\n\\includegraphics[width=0.9\\linewidth]{figs/plots}\n"
              "\\caption{Two plots with the same axis label.}\n\\end{figure}\n")
    pre = "\\documentclass{article}\n\\usepackage{graphicx}\n"
    files = {"figs/plots.pdf": _two_plots("Accuracy")}
    old = _build(tmp_path / "v1", "Some text before the figure.\n\n" + figure, pre, files)
    new = _build(tmp_path / "v2", "Some text before the figure.\n\nA new paragraph pushes the figure down the page "
                 "by a line or two of text.\n\n" + figure, pre, files)
    left, right = sorted(pymupdf.open(old[1])[0].search_for("Accuracy"), key=lambda r: r.x0)
    a, method, _ = comments.locate(old[0], old[1], 0, [list(left)], "Accuracy")
    assert method == "selection" and a["quote"].startswith("\\includegraphics")
    records, _ = _carry(old, new, [{"id": "R1-01", "anchor": a, "last": a}])
    [r] = records["R1-01"]["anchor"]["rects"]
    now_left, now_right = sorted(pymupdf.open(new[1])[0].search_for("Accuracy"), key=lambda r: r.x0)
    assert now_left.y0 > left.y0 + 5
    assert pymupdf.Rect(r).intersects(now_left) and not pymupdf.Rect(r).intersects(now_right)


BIB_ENTRY = ("@inproceedings{{k{k}, author = {{Alexandru Agache and Marc Brooker}}, "
             "title = {{Firecracker number {k}}}, booktitle = {{{venue}}}, pages = {{419--434}}, year = {{{year}}}}}\n")
VENUE = "Symposium on Networked Systems Design and Implementation of Large Scale Cloud Platforms for Everyone".split()


def _bibliography(tmp_path, name, style, year=2020, entries=30):
    """(src, pdf) of a paper citing `entries` references, typeset by BibTeX with `style`; the venues grow by a word
    and a letter from entry to entry, so the entries' last lines hold from one word to a whole line."""
    bib = "".join(BIB_ENTRY.format(k=k, year=year, venue=" ".join(VENUE[:3 + k % 14]) + " " + "x" * (k % 9 + 1))
                  for k in range(entries))
    natbib = "\\usepackage[round]{natbib}\n" if style == "plainnat" else ""
    return _build(tmp_path / name, "Text \\cite{" + ",".join("k{}".format(k) for k in range(entries)) + "}.\n"
                  "\\bibliographystyle{" + style + "}\n\\bibliography{refs}\n",
                  "\\documentclass{article}\n" + natbib, {"refs.bib": bib})


def test_o8_a_reference_entry_is_drawn_to_its_last_line(tmp_path):
    """Every entry of a reference list is drawn to its last line (was: a last line that synctex gives to the next
    source line was left out)."""
    src, pdf = _bibliography(tmp_path, "v1", "plain")
    bbl = (pdf.parent / "main.bbl").read_text()
    entries = [texdiff.bibitem(bbl, m.start(), m.start() + 1) for m in re.finditer(r"\\bibitem", bbl)]
    assert len(entries) == 30
    for s, e in entries:
        page, rects, words = anchor.to_pdf(src, pdf, "main.bbl", s, e)
        assert words.startswith("Alexandru Agache") and words.endswith("2020."), words


def test_o8_a_year_changed_in_a_reference_is_one_change_on_the_year(tmp_path):
    """A year fixed in the .bib changes both the entry's label (natbib's \\bibitem[Agache and Brooker(2019)]) and its
    text: one change, drawn on the year where the list prints it (was: a second change drawn over the entry's first
    line)."""
    old = _bibliography(tmp_path, "v1", "plainnat", entries=1)
    new = _bibliography(tmp_path, "v2", "plainnat", year=2019, entries=1)
    _, [change] = _carry(old, new, [])
    assert (change["old_text"], change["new_text"]) == ("2020", "2019")
    page = pymupdf.open(new[1])[0]
    [year] = [r for r in page.search_for("2019.") if r.y0 > page.search_for("References")[0].y0]
    [r] = change["rects"]
    assert pymupdf.Rect(r).intersects(year) and r[2] - r[0] < 3 * year.width


RESTORED = ("A third line of work reuses idle instances across the functions of one tenant, which saves memory but\n"
            "leaks timing information between functions.\n")


def _ingest_and_finish(paper, sources):
    for src in sources:
        _call(paper, "ingest", source=str(src))
        _call(paper, "finish")


def _unread(s):
    return {p["block"] for p in s["reading"]["paragraphs"]} - set(s["reading"]["read"])


def test_o23_a_paragraph_restored_through_an_input_is_unread(tmp_path):
    """A section file whose \\input was removed in round 2 (the file left in the tree) and put back in round 3 reads
    as read in round 1, yet it is new text in round 3: it gets a bar and its change is not read (was: neither)."""
    paper, (v1, v2, v3) = _paper(tmp_path, [PARAGRAPHS + "\n\\input{extra}\n", PARAGRAPHS,
                                            PARAGRAPHS + "\n\\input{extra}\n"],
                                 files=[{"extra.tex": RESTORED}] * 3)
    _ingest_and_finish(paper, [v1, v2])
    s = _call(paper, "ingest", source=str(v3))["state"]
    data = prose.load(paper, 3)
    [k] = [k for k, b in enumerate(data["blocks"]) if b["file"] == "extra.tex"]
    assert _unread(s) == {k}
    [change] = s["changes"]
    assert change["blocks"] == [k] and not change["read"] and s["summary"]["to_check"] == 1


def test_o24_a_round_closed_without_its_paragraphs_does_not_count_as_read(tmp_path, monkeypatch):
    """When the paragraphs cannot be found at Finish, closing the round marks nothing read and leaves read_through
    below it; the next round counts the round's paragraphs read once they are found, so only the edited paragraph
    has a bar (was: read_through set anyway, and every paragraph had a bar)."""
    edited = PARAGRAPHS.replace("easy to explain", "simple to explain")
    paper, (v1, v2) = _paper(tmp_path, [PARAGRAPHS, edited])
    _call(paper, "ingest", source=str(v1))
    (paper / "r1" / "prose.json").unlink()
    build = prose.build

    def failing(*args, **kwargs):
        raise RuntimeError("no paragraphs")
    monkeypatch.setattr(prose, "build", failing)
    _call(paper, "finish")
    assert ledger.load(paper)["read_through"] == 0
    monkeypatch.setattr(prose, "build", build)
    s = _call(paper, "ingest", source=str(v2))["state"]
    data = prose.load(paper, 2)
    assert [data["blocks"][k]["text"][:9] for k in _unread(s)] == ["A simple "]
    hashes = prose.round_hashes
    monkeypatch.setattr(prose, "round_hashes", failing)  # still not found: the state is made without them
    assert len(_unread(_call(paper, "state")["state"])) == s["reading"]["count"]
    monkeypatch.setattr(prose, "round_hashes", hashes)
    assert _call(paper, "read", blocks=sorted(_unread(s)))["state"]["reading"]["unread"] == 0
    assert ledger.load(paper)["read_through"] == 1
