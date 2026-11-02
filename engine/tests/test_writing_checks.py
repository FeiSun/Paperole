"""Local writing checks: controlled page/column geometry, exclusions, and a compiled synthetic paper."""
import shutil

import pytest

from conftest import quiet
from paperole import api, checks


LOCAL = {"short_last_line", "paragraph_break", "heading_break", "split_phrase", "sentence_start"}


class Paper(checks._Paper):
    """Printed lines at known positions; keep the production geometry and line grouping."""

    def __init__(self):
        self.blocks, self.sequences, self.sources_text = [], [], {}
        self.columns = [[280, 300]] * 4
        self.links = []

    def add(self, kind, lines, source=None, **fields):
        k, seq, parts = len(self.blocks), [], {}
        for row, (page, x, y, text) in enumerate(lines):
            region = (page, x)
            parts.setdefault(region, [x, y, x, y + 10])
            for word in text.split():
                seq.append((page, len(seq), (x, y, x + 5 * len(word), y + 10, word, k, row, len(seq))))
                x += 5 * len(word) + 4
            parts[region][2] = max(parts[region][2], x)
            parts[region][3] = max(parts[region][3], y + 10)
        text = " ".join(w[4] for _, _, w in seq)
        source = text if source is None else source
        file = "part{}.tex".format(k)
        self.sources_text[file] = source
        self.blocks.append(dict(kind=kind, file=file, start=0, end=len(source), text=text, marks=[],
                                map=[[0, len(text), 0, len(source)]], parts=[[p, r] for (p, x), r in parts.items()],
                                **fields))
        self.sequences.append(seq)
        return self

    def text(self, file):
        return self.sources_text[file]

    def block_words(self, kinds, upto=None):
        return [(k, seq) for k, seq in enumerate(self.sequences[:upto]) if self.blocks[k]["kind"] in kinds and seq]

    def source_place(self, file, pos, text=None):
        k = next(k for k, b in enumerate(self.blocks) if b["file"] == file)
        return checks._line_place(self.text_lines[k][0])

    def words_in(self, page, rects, pad=1):
        return [(i, w) for seq in self.sequences for p, i, w in seq if p == page and any(
            r[0] <= (w[0] + w[2]) / 2 <= r[2] and r[1] <= (w[1] + w[3]) / 2 <= r[3] for r in rects)]


def paragraph(*texts, kind="paragraph", source=None):
    return Paper().add(kind, [(0, 72, 100 + 12 * i, text) for i, text in enumerate(texts)], source=source)


def test_short_last_line_and_deliberate_or_hyphenated_endings():
    p = paragraph("The result improves on both", "baselines.")
    c, = checks.short_last_line(p)
    assert c["places"] == [{"page": 0, "rects": [[72, 112, 122, 122]], "text": "baselines."}]
    for p in (paragraph("An entire short paragraph."), paragraph("The result improves", "on both baselines."),
              paragraph("The result improves the base-", "lines."),
              paragraph("Some words", "alone.", source=r"Some words\\alone.")):
        assert checks.short_last_line(p) == []
    for kind in ("item", "heading", "math", "code", "figure", "table", "bibitem"):
        assert checks.short_last_line(paragraph("Some words", "alone.", kind=kind)) == []


@pytest.mark.parametrize("next_page,next_x", [(1, 72), (0, 310)])
@pytest.mark.parametrize("before,after", [(1, 3), (3, 1), (1, 1), (2, 2)])
def test_paragraph_page_and_column_breaks(next_page, next_x, before, after):
    lines = [(0, 72, 650 + i * 12, "The paragraph continues here") for i in range(before)]
    lines += [(next_page, next_x, 100 + i * 12, "and continues on this side.") for i in range(after)]
    p = Paper().add("paragraph", lines)
    found = checks.paragraph_break(p)
    assert len(found) == (1 if min(before, after) == 1 else 0)
    if found:
        assert len(found[0]["places"]) == 2
        assert ("page break" if next_page else "column break") in found[0]["text"]
    # Two different paragraphs do not make a widow or orphan.
    assert checks.paragraph_break(Paper().add("paragraph", lines[:before]).add("paragraph", lines[before:])) == []


def test_geometry_joins_inline_math_spans_and_does_not_confuse_columns():
    p = paragraph("We use x in this sentence.", "It has another complete line.")
    # PDF line ids often change at an inline formula without a visual line break.
    p.sequences[0] = [(page, i, w[:5] + (i, i, 0)) for page, i, w in p.sequences[0]]
    assert len(p.text_lines[0]) == 2
    assert checks.paragraph_break(p) == [] and checks.short_last_line(p) == []
    p = Paper().add("paragraph", [(0, 72, 100, "A first line"), (0, 310, 100, "in another column.")])
    assert len(p.text_lines[0]) == 2 and len(checks.paragraph_break(p)) == 1
    # Full-width text on a page with two columns remains one visual line, even across the gutter.
    p = paragraph("A complete full width line with enough words to cross the nominal column boundary.",
                  "This is another complete line.")
    assert len(p.text_lines[0]) == 2 and checks.paragraph_break(p) == []


def test_indentation_changes_are_not_column_breaks():
    p = Paper().add("paragraph", [(0, 72, 100, "Short start"), (0, 210, 112, "Indented continuation.")])
    assert checks.paragraph_break(p) == []
    p = Paper().add("heading", [(0, 72, 100, "Results")], level=1)
    p.add("paragraph", [(0, 210, 120, "Indented body text.")])
    assert checks.heading_break(p) == []


@pytest.mark.parametrize("next_page,next_x", [(1, 72), (0, 310)])
@pytest.mark.parametrize("following", [0, 1, 2])
def test_heading_with_zero_one_or_two_following_lines(next_page, next_x, following):
    p = Paper().add("heading", [(0, 72, 600, "Results")], level=1)
    lines = [(0, 72, 620 + i * 12, "The result is described here") for i in range(following)]
    lines += [(next_page, next_x, 100, "and continues in another place.")]
    p.add("paragraph", lines)
    found = checks.heading_break(p)
    assert len(found) == (1 if following < 2 else 0)
    if found:
        assert found[0]["places"][0]["text"] == "Results"
    p.blocks[0]["level"] = 4
    assert checks.heading_break(p) == []


def test_run_in_heading_and_a_heading_followed_by_a_figure():
    p = Paper().add("heading", [(0, 72, 100, "Results.")], level=3)
    p.add("paragraph", [(0, 120, 100, "The first line"), (1, 72, 100, "continues here.")])
    assert checks.heading_break(p) == []
    p = Paper().add("heading", [(0, 72, 100, "Results")], level=1)
    p.add("figure", [(1, 72, 100, "Figure 1: Results.")])
    assert checks.heading_break(p) == []


def test_heading_followed_by_a_complete_single_line_paragraph():
    p = Paper().add("heading", [(0, 72, 600, "Results")], level=1)
    p.add("paragraph", [(0, 72, 620, "One short paragraph.")])
    p.add("paragraph", [(1, 72, 100, "Another paragraph follows.")])
    assert len(checks.heading_break(p)) == 1


@pytest.mark.parametrize("left,right", [("See Figure", "3 for the result."), ("The cost is 10", "GB per run."),
                                        ("We use 1.5", "ms per query."), ("See Sec.", "2 for details.")])
def test_split_reference_and_unit_pairs(left, right):
    p = paragraph(left, right)
    c, = checks.split_phrase(p)
    assert [place["text"] for place in c["places"]] == [left.split()[-1], right.split()[0]]
    assert checks.split_phrase(paragraph(left + " " + right)) == []
    assert checks.split_phrase(paragraph(left, right, kind="table")) == []


def test_split_pairs_across_pages_and_non_units():
    p = Paper().add("paragraph", [(0, 72, 700, "See Figure"), (1, 72, 100, "3 for details.")])
    assert [x["page"] for x in checks.split_phrase(p)[0]["places"]] == [0, 1]
    assert checks.split_phrase(paragraph("We ran 10", "experiments.")) == []
    assert checks.split_phrase(paragraph("The next Figure", "shows the method.")) == []


def test_additional_printed_placeholders_and_exclusions():
    p = paragraph("See [Ref], [??] and [citation", "needed]. TODO remains.")
    found = checks.draft_marker(p)
    assert {c["text"] for c in found} == {"“[Ref]” left in", "“[??]” left in", "“[citation needed]” left in",
                                         "“TODO” left in"}
    citation = next(c for c in found if "citation needed" in c["text"])
    assert len(citation["places"][0]["rects"]) == 2
    assert checks.draft_marker(paragraph("The printed text is finished.", source="Finished. % [Ref] [??]")) == []
    for kind in ("code", "math", "bibitem"):
        assert checks.draft_marker(paragraph("[Ref] [??] [citation needed]", kind=kind)) == []
    # A real citation label happens to spell Ref; it is not a literal placeholder.
    p = paragraph("[Ref] gives the result.")
    p.links = [{"page": 0, "rects": [list(p.sequences[0][0][2][:4])]}]
    assert checks.draft_marker(p) == []


@pytest.mark.parametrize("text,needle,kind,want", [
    ("x is the input.", "x", "math", True),
    ("The input x is given.", "x", "math", False),
    ("We finish. x is next.", "x", "math", True),
    ("See Eq. x for details.", "x", "math", False),
    ("For example, e.g. x is given.", "x", "math", False),
    ("Following J. x is given.", "x", "math", False),
    ("In the U.S. x is given.", "x", "math", False),
    ("x.", "x", "math", False),
    ("[12] shows the result.", "[12]", "cite", True),
    ("We follow [12] here.", "[12]", "cite", False),
    ("Smith [12] shows the result.", "Smith [12]", "cite", False),
    ("Smith (2024) shows the result.", "Smith (2024)", "cite", False),
    ("[?] shows the result.", "[?]", "cite", False),
])
def test_sentence_starts_and_clear_boundaries(text, needle, kind, want):
    p = paragraph(text)
    at = text.index(needle)
    p.blocks[0]["marks"] = [[at, at + len(needle), kind]]
    found = checks.sentence_start(p)
    assert len(found) == int(want)
    if found:
        assert found[0]["places"][0]["text"] == text


def test_sentence_continuing_after_display_math_and_unmapped_text():
    p = Paper().add("math", [(0, 72, 100, "f(x) = x")]).add("paragraph", [(0, 72, 120, "x is the input.")])
    p.blocks[1]["marks"] = [[0, 1, "math"]]
    assert checks.sentence_start(p) == []
    p = paragraph("x is the input.")
    p.blocks[0]["marks"], p.blocks[0]["map"] = [[0, 1, "math"]], []
    assert checks.sentence_start(p) == []


@pytest.mark.skipif(not shutil.which("/Library/TeX/texbin/latexmk"), reason="needs latexmk and synctex")
@pytest.mark.parametrize("two_columns", [False, True])
def test_compiled_writing_checks_and_round_items(tmp_path, two_columns):
    src, paper = tmp_path / "src", tmp_path / "paper"
    src.mkdir()
    source = r"""\documentclass{article}
\usepackage{hyperref}
\setlength{\textwidth}{180pt}
\begin{document}
\section{Method}
$X$ is the input matrix. We follow earlier work. \cite{work} shows the result.

The citation is [Ref] and [citation needed]. % [??] is only a source comment

\noindent\mbox{The final result is described by this text} ending.

\noindent\mbox{Details are given in Figure}\\1 and the cost is 10\\GB per run.

\section{Separated heading}
\newpage
This paragraph explains the synthetic result in enough detail to occupy more than one line of text.

This paragraph begins here. \newpage
It continues after the break with enough words to occupy more than one line of text in this document.

\begin{thebibliography}{9}
\bibitem{work} A. Writer. A synthetic reference. 2024.
\end{thebibliography}
\end{document}
"""
    if two_columns:
        source = source.replace(r"\documentclass{article}", r"\documentclass[twocolumn]{article}")
        source = source.replace(r"\setlength{\textwidth}{180pt}", r"\setlength{\textwidth}{380pt}")
    (src / "main.tex").write_text(source)
    api.new({"paper": str(paper), "title": "Writing checks", "student": "Test"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    found = api.checks_({"paper": str(paper)}, quiet)["checks"]
    own = [c for c in found if c["code"] in LOCAL or c["code"] == "draft_marker"]
    assert {c["code"] for c in own} == LOCAL | {"draft_marker"}
    assert len([c for c in own if c["code"] == "sentence_start"]) == 2
    assert {c["text"] for c in own if c["code"] == "draft_marker"} == {
        "“[Ref]” left in", "“[citation needed]” left in"}
    for c in own:
        assert c["detail"] and c["note"] and c["places"] and "|r1" in c["key"]
        assert all(p["rects"] for p in c["places"])
    items = api.check_items_({"paper": str(paper)}, quiet)["items"]
    assert {c["key"] for c in own} <= {it["key"] for it in items}
    assert all(it["id"].startswith("A1-") for it in items)
    api.finish({"paper": str(paper), "checks": True}, quiet)
    email = (paper / "r1/email.txt").read_text()
    assert all(c["text"] in email for c in own)
    # A second, clean round closes the same items, through the existing lifecycle.
    (src / "main.tex").write_text(r"""\documentclass{article}
\begin{document}
The input matrix is given in words. This paragraph has a complete ending.
\end{document}
""")
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    api.checks_({"paper": str(paper)}, quiet)
    items = api.check_items_({"paper": str(paper)}, quiet)["items"]
    assert {c["key"] for c in own} <= {it["key"] for it in items if it["state"] == "fixed"}
