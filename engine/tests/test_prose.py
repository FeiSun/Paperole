"""The paragraphs read in the PDF and read state (CONTRACT.md amendments "Prose view and reading" and "Reading in the
PDF view"): block splitting, display text, the map back to the source, hashes, diff marks, places in the PDF (parts),
read state, and state."""
import json
import shutil
import time
from pathlib import Path

import pymupdf
import pytest

from paperole import EngineError, analysis, api, ledger, prose, state, texdiff
from conftest import FIXTURE, quiet, select

PROSE = Path(__file__).resolve().parent / "fixtures" / "prose"


def read_blocks(src, build=PROSE / "build"):
    """The blocks of a source folder (no PDF: no boxes), with sections."""
    blocks = prose._Reader(src, build, "main.tex").read(prose._context)
    prose._sections(blocks)
    return blocks


def texts(blocks, kind=None):
    return [b["text"] for b in blocks if kind is None or b["kind"] == kind]


def marked(b, kind):
    return [b["text"][m[0]:m[1]] for m in b["marks"] if m[2] == kind]


@pytest.fixture(scope="module")
def fixture_blocks():
    return read_blocks(PROSE / "src")


# --- splitting and display text (no TeX) -------------------------------------------------------------------------

def test_blocks_in_reading_order(fixture_blocks):
    b = fixture_blocks
    kinds = [x["kind"] for x in b]
    assert kinds == ["title", "paragraph", "heading", "paragraph", "paragraph", "heading", "heading", "paragraph",
                     "math", "paragraph", "math", "math", "heading", "paragraph", "item", "item", "item", "item",
                     "heading", "figure", "table", "code", "picture", "picture", "paragraph", "missing", "heading",
                     "paragraph", "heading", "bibitem", "bibitem"]
    assert b[0]["text"] == "A Synthetic Prose Paper" and b[0]["section"] == -1  # \title from the preamble, first
    assert b[1]["section"] == -1
    # fields only the prose view read are gone: a block's role, an item's depth and label, a formula's number
    assert not any(k in x for x in b for k in ("role", "depth", "label", "since")) and b[8]["number"] is None
    # \input{sections/method} is read where it stands; the preamble, \iffalse and comment give no block
    assert [x["file"] for x in b[5:25]] == ["sections/method.tex"] * 20
    assert not any("Hidden" in t for t in texts(b))
    assert b[25]["text"] == "sections/missing.tex" and b[25]["hash"] is None
    # headings: numbers counted, starred ones null, \paragraph level 4, letters after \appendix
    heads = [(x["text"], x["level"], x["number"]) for x in b if x["kind"] == "heading"]
    assert heads == [("Introduction", 1, "1"), ("Method", 1, "2"), ("Model", 2, "2.1"), ("Lists.", 4, None),
                     ("Floats", 2, None), ("Extra", 1, "A"), ("References", 1, None)]
    assert b[28]["hash"] is None  # the References heading
    assert [x["section"] for x in b[5:9]] == [5, 6, 6, 6]  # subsections are sections; \paragraph is not
    # lists: an item a block, nested ones too
    assert texts(b, "item") == ["First step.", "Second, with", "a nested one;", "and another."]
    # one block whatever it holds
    assert b[8]["text"] == "L(\\theta) = \\sum_i \\ell_i(\\theta)"
    assert b[10]["text"] == "a = b"
    assert b[11]["text"] == "\\begin{align*}x &= 1 \\\\ y &= 2\\end{align*}"  # \nonumber dropped
    assert b[19]["text"] == "Figure 1: Cold starts by frequency." and marked(b[19], "em") == ["frequency"]
    assert b[20]["text"] == "Table 1: Main results."
    assert b[21]["text"] == "for x in y: % not a comment"  # verbatim, as written
    assert b[22]["text"] == b[23]["text"] == ""  # a wrapper that prints no text, and a tikzpicture
    # the reference list from the .bbl TeX read
    assert [x["file"] for x in b[29:]] == ["main.bbl", "main.bbl"]
    assert b[29]["text"] == "J.\u00a0Lee and S.\u00a0Kim. Pools at scale. In Proc. ATC, 2024. https://x.org/a%20b."


def test_display_text(fixture_blocks):
    b = fixture_blocks
    assert b[1]["text"] == "We test the prose view. It reads “quoted” text – and dashes — well."
    cites = b[3]
    assert cites["text"] == ("The WarmCast controller sizes pools\u00a0(Wang et\u00a0al., 2026) as Lee and Kim (2024) "
                             "showed. Prior work\u00a0(see Wang et\u00a0al., 2026; Lee and Kim, 2024, p.\u00a03) and [?] "
                             "differ.")
    assert [m[3] for m in cites["marks"] if m[2] == "cite"] == ["wang2026", "lee2024", "wang2026,lee2024", "nokey"]
    refs = b[4]
    assert refs["text"].startswith("See Figure 1, Tables 1 and 2, Section 1, Eq.\u00a0(1) and ??. ")
    assert marked(refs, "ref") == ["Figure 1", "Tables 1 and 2", "Section 1", "(1)", "??"]
    # macros with arguments and defaults; math is kept as TeX under a math mark; unknown commands are chips
    assert "A pair (a, b), low–high, mid–high, x \\in \\R, \\loopy and \\unknowncmd." in refs["text"]
    assert marked(refs, "math") == ["x \\in \\R"]
    assert marked(refs, "tex") == ["\\loopy", "\\unknowncmd"]  # \loopy expands into itself: the depth limit
    assert "Accents: nai\u0308ve, e\u0301te\u0301, c\u0327a; a footnote" in refs["text"]  # combining marks
    assert marked(refs, "fn") == ["Said here."] and marked(refs, "em") == ["here"]
    url = next(m for m in refs["marks"] if m[2] == "url")
    assert refs["text"][url[0]:url[1]] == url[3] == "https://x.org/a_b"
    url = next(m for m in b[29]["marks"] if m[2] == "url")  # a % in a URL is no comment
    assert b[29]["text"][url[0]:url[1]] == url[3] == "https://x.org/a%20b"


def test_numeric_citations_and_unresolved(tmp_path):
    (tmp_path / "main.aux").write_text("\\bibcite{a}{1}\n\\bibcite{b}{2}\n\\newlabel{x}{{3.2}{4}}\n")
    ctx = prose._Ctx({}, prose._aux(tmp_path, "main"), False)
    assert ctx.cite("cite", ["a", "b"], []) == "[1, 2]"
    assert ctx.cite("citep", ["a"], ["p.~4"]) == "[1, p.\u00a04]"
    assert ctx.cite("cite", ["zz"], []) == "[?]"
    assert ctx.cite("cite", ["a", "zz"], []) == "[1, ?]"
    assert ctx.ref("ref", ["x"]) == "3.2" and ctx.ref("eqref", ["x"]) == "(3.2)" and ctx.ref("pageref", ["x"]) == "4"
    assert ctx.ref("cref", ["x"]) == "3.2"  # no cleveref type and no prefix: the number alone


def test_expansion_limit():
    text = "\\m " * 1600
    ctx = prose._Ctx({"m": (0, None, "x")}, ({}, {}, {}), False)
    c = prose._Conv(ctx, text, text)
    c.run(0, len(text))
    out, marks, _ = c.finish()
    assert out.count("x") == prose.MAX_EXPANSIONS
    assert sum(1 for m in marks if m[2] == "tex") == 1600 - prose.MAX_EXPANSIONS


# --- the map --------------------------------------------------------------------------------------------------

def test_map_round_trips(fixture_blocks):
    for b in fixture_blocks:
        raw = (PROSE / "src" / b["file"]).read_text(encoding="utf-8")
        covered = [False] * len(b["text"])
        for d, n, s, m, *atomic in b["map"]:
            assert b["start"] <= s and s + m <= b["end"] or b["kind"] in ("title", "missing")
            for i in range(d, d + n):
                covered[i] = True
            if n == m and not atomic:  # one to one: each character comes from its source character
                for i in range(n):
                    shown, src = b["text"][d + i], raw[s + i]
                    assert shown == src or (shown == " " and src.isspace()) or (shown, src) in (("\u00a0", "~"),
                                                                                                ("‘", "`"), ("’", "'"))
                    assert prose._display(b, s + i, s + i + 1) in ([[d + i, d + i + 1]], [])  # [] for a space
        assert all(covered), (b["kind"], b["text"])


def test_atomic_entries_are_taken_whole(fixture_blocks):
    b = fixture_blocks[3]
    raw = (PROSE / "src" / "main.tex").read_text(encoding="utf-8")
    s = raw.index("\\citep{wang2026}", b["start"])
    (d0, d1), = prose._display(b, s + 8, s + 10)  # two letters of a citation's key: the whole printed citation
    assert "Wang" in b["text"][d0:d1] and "2026" in b["text"][d0:d1]
    s = raw.index("\\method", b["start"])
    k = b["text"].index("WarmCast")
    assert prose._display(b, s + 1, s + 2) == [[k, k + len("WarmCast")]]


# --- hashes ---------------------------------------------------------------------------------------------------

def _variant(tmp_path, name, edit):
    src = tmp_path / name
    shutil.copytree(PROSE / "src", src)
    edit(src)
    return [(b["kind"], b["text"], b["hash"]) for b in read_blocks(src)]


def test_hash_keeps_and_changes(tmp_path):
    base = _variant(tmp_path, "base", lambda src: None)
    main = (PROSE / "src" / "main.tex").read_text(encoding="utf-8")
    para = "The \\method controller sizes pools~\\citep{wang2026} as \\citet{lee2024} showed."

    def rewrap(src):  # re-wrapped, with a % comment added
        (src / "main.tex").write_text(main.replace(para, para.replace(" as ", "\nas % note\n")), encoding="utf-8")
    assert _variant(tmp_path, "rewrap", rewrap) == base

    def move(src):  # the appendix paragraph moved before the method
        t = main.replace("Text in the appendix.\n", "").replace("\\input{sections/method}",
                                                                "Text in the appendix.\n\n\\input{sections/method}")
        (src / "main.tex").write_text(t, encoding="utf-8")
    moved = _variant(tmp_path, "move", move)
    assert sorted(moved) == sorted(base)

    def word(src):
        (src / "main.tex").write_text(main.replace("sizes pools", "sizes warm pools"), encoding="utf-8")
    edited = _variant(tmp_path, "word", word)
    assert [x[2] for x in base if x not in edited] == [base[3][2]]

    def figure(src):  # the same \includegraphics, a new picture file
        (src / "plot.png").write_bytes(b"\x89PNG\r\n\x1a\nfixture-plot-v2")
    new = _variant(tmp_path, "figure", figure)
    changed = [b[:2] for b, n in zip(base, new) if b != n]
    assert changed == [("figure", "Figure 1: Cold starts by frequency."), ("picture", "")]  # not the tikzpicture


def test_identical_blocks_share_a_hash(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text("\\begin{document}\nSame words.\n\nSame   words.\n\nOther.\n\\end{document}\n")
    blocks = read_blocks(src, tmp_path)
    assert blocks[0]["hash"] == blocks[1]["hash"] != blocks[2]["hash"]


def _blocks_of(tmp_path, name, body):
    (tmp_path / name).mkdir()
    (tmp_path / name / "main.tex").write_text("\\begin{document}\n" + body + "\\end{document}\n")
    return read_blocks(tmp_path / name, tmp_path)


def test_end_on_a_text_line(tmp_path):
    # an environment closed at the end of a text line ends the paragraph there and is closed
    blocks = _blocks_of(tmp_path, "src", "\\begin{abstract}\nWe probe a line.\\end{abstract}\n\\section{One}\nBody text.\n"
                        "\\begin{itemize}\n\\item First.\n\\item Two.\\end{itemize}\nBetween lists.\n\n"
                        "\\begin{itemize}\n\\item Later.\n\\end{itemize}\n\\begin{center}\nCentred.\\end{center}\nAfter.\n")
    assert [(b["kind"], b["text"]) for b in blocks] == [
        ("paragraph", "We probe a line."), ("heading", "One"), ("paragraph", "Body text."), ("item", "First."),
        ("item", "Two."), ("paragraph", "Between lists."), ("item", "Later."), ("paragraph", "Centred."),
        ("paragraph", "After.")]


def test_commands_that_print_nothing(tmp_path):
    # \noindent, \vspace, \label and \hfill on a line of their own or joined to the text: one paragraph each (as
    # TeX sets it), with the same hash; a word edit still changes it
    own = _blocks_of(tmp_path, "own", "\\noindent\nAlpha beta gamma.\n\n\\vspace{2pt}\nDelta epsilon\n\\label{par:x}\n"
                     "zeta eta.\n\n\\hfill\nTheta iota.\n")
    joined = _blocks_of(tmp_path, "joined", "\\noindent Alpha beta gamma.\n\n\\vspace{4pt} Delta epsilon \\label{par:y} "
                        "zeta eta.\n\n\\hfill Theta iota.\n")
    edited = _blocks_of(tmp_path, "edited", "\\noindent Alpha beta gamma.\n\nDelta epsilon zeta eta.\n\nTheta kappa.\n")
    assert [b["text"] for b in own] == ["Alpha beta gamma.", "Delta epsilon zeta eta.", "Theta iota."]
    assert [b["hash"] for b in own] == [b["hash"] for b in joined]
    assert [b["hash"] for b in edited[:2]] == [b["hash"] for b in own[:2]] and edited[2]["hash"] != own[2]["hash"]


def test_percent_in_a_listing(tmp_path):
    # `%` is printed in a listing: an edit after it is a change and a new hash
    listing = "\\begin{verbatim}\nanswer at 50%% of %s\n\\end{verbatim}\n"
    old = _blocks_of(tmp_path, "old", listing % "them")
    new = _blocks_of(tmp_path, "new", listing % "all of them")
    assert old[0]["hash"] != new[0]["hash"]
    assert [h["kind"] for h in texdiff.diff_trees(tmp_path / "old", tmp_path / "new").hunks] == ["insert"]


def test_line_break_and_verb_open_no_display(tmp_path):
    # M7: the \[ of a \\[2pt] line break or of \verb|\[| is no display formula, which ran on to the next \]
    blocks = _blocks_of(tmp_path, "src", "\\begin{center}\nTitle line\\\\[2pt]\nSecond line\n\\end{center}\n\n"
                        "A paragraph.\n\nUse \\verb|\\[| to open.\nStill here.\n\n\\[ x = 1 \\]\n\nAfter.\n")
    assert [(b["kind"], b["text"]) for b in blocks] == [
        ("paragraph", "Title line Second line"), ("paragraph", "A paragraph."),
        ("paragraph", "Use \\[ to open. Still here."), ("math", "x = 1"), ("paragraph", "After.")]


def test_one_line_commands_that_print_text(tmp_path):
    # a line holding only a command that may print text (a package's \gls, \nolinkurl) goes on with the paragraph;
    # \par and \newpage alone on a line end it
    blocks = _blocks_of(tmp_path, "src", "Alpha beta\n\\gls{llm}\nare great.\n\nNext\n\\nolinkurl{a/b}\nmore.\n\n"
                        "\\path{c/d}\nstarts one.\n\nEnd\n\\par\nX.\n\\newpage\nY.\n")
    assert texts(blocks) == ["Alpha beta llm are great.", "Next a/b more.", "c/d starts one.", "End", "X.", "Y."]


def test_icml_front_matter_is_not_read(tmp_path):
    # D4: ICML's title, author list, affiliations and notice are not paragraphs to read; the abstract is
    blocks = _blocks_of(tmp_path, "src", "\\twocolumn[\n\\icmltitle{A Title}\n\\icmlsetsymbol{equal}{*}\n"
                        "\\begin{icmlauthorlist}\n\\icmlauthor{Ann Lee}{equal,uni}\n\\end{icmlauthorlist}\n"
                        "\\icmlaffiliation{uni}{Dept, Uni}\n\\icmlcorrespondingauthor{Ann Lee}{a@b.c}\n"
                        "\\icmlkeywords{ML}\n\\vskip 0.3in\n]\n"
                        "\\printAffiliationsAndNotice{\\icmlEqualContribution}\n\n\\begin{abstract}\nWe read this.\n"
                        "\\end{abstract}\n")
    assert [t for t in texts(blocks) if any(ch.isalnum() for ch in t)] == ["We read this."]


def test_chapters_and_parts(tmp_path):
    # in a thesis, chapters are level 1 and sections level 2, numbered within their chapter; a part is level 1,
    # unnumbered (its Roman numeral would read as an appendix's letter), and numbers nothing else
    blocks = _blocks_of(tmp_path, "thesis", "\\part{Background}\n\\chapter{Introduction}\nText.\n"
                        "\\section{Scope}\nMore.\n\\subsection{Detail}\nS.\n\\subsubsection{Fine}\nF.\n"
                        "\\paragraph{Run-in.} P.\n\n\\part{Work}\n\\chapter{Method}\n\\section{Model}\nT.\n\n"
                        "\\appendix\n\\chapter{Proofs}\n\\section{Lemma}\nL.\n")
    assert [(b["text"], b["level"], b["number"]) for b in blocks if b["kind"] == "heading"] == [
        ("Background", 1, None), ("Introduction", 1, "1"), ("Scope", 2, "1.1"), ("Detail", 3, "1.1.1"),
        ("Fine", 4, None), ("Run-in.", 5, None), ("Work", 1, None), ("Method", 1, "2"), ("Model", 2, "2.1"),
        ("Proofs", 1, "A"), ("Lemma", 2, "A.1")]
    assert [(b["text"], blocks[b["section"]]["text"]) for b in blocks if b["kind"] == "paragraph"] == [
        ("Text.", "Introduction"), ("More.", "Scope"), ("S.", "Scope"), ("F.", "Scope"), ("P.", "Scope"),
        ("T.", "Model"), ("L.", "Lemma")]
    article = _blocks_of(tmp_path, "article", "\\part{One}\n\\section{A}\nx.\n\\subsection{B}\ny.\n")
    assert [(b["text"], b["level"], b["number"]) for b in article if b["kind"] == "heading"] == [
        ("One", 1, None), ("A", 1, "1"), ("B", 2, "1.1")]


def test_comment_in_a_file_a_float_inputs(tmp_path):
    # m19: a comment in a file \input inside a float (its tabular) is in the float's block
    src = tmp_path / "src"
    (src / "tables").mkdir(parents=True)
    tab = "\\begin{tabular}{lr}\nMem0 & 1.24 \\\\\n\\end{tabular}\n"
    (src / "tables" / "t1.tex").write_text(tab)
    (src / "main.tex").write_text("\\begin{document}\nText.\n\n\\begin{table}\n\\input{tables/t1}\n"
                                  "\\caption{Results.}\n\\end{table}\n\\end{document}\n")
    blocks = read_blocks(src, tmp_path)
    at = tab.index("Mem0")
    k = prose.block_of({"blocks": blocks}, {"file": "tables/t1.tex", "start": at, "end": at + 4})
    assert blocks[k]["kind"] == "table" and blocks[k]["inputs"] == ["tables/t1.tex"]
    assert "inputs" not in blocks[0]
    assert prose.block_of({"blocks": blocks}, {"file": "other.tex", "start": 0, "end": 4}) is None


def test_a_file_input_in_another_case_is_named_as_on_disk(tmp_path):
    # \input{Sections/Intro} reads sections/intro.tex on macOS: its blocks name the file as on disk, as texdiff's
    # changes and new anchors do, and an older ledger's anchor in synctex's spelling (the \input's) is in them too
    src = tmp_path / "src"
    (src / "sections").mkdir(parents=True)
    (src / "sections" / "intro.tex").write_text("Intro text.\n")
    (src / "main.tex").write_text("\\begin{document}\n\\input{Sections/Intro}\n\\end{document}\n")
    blocks = read_blocks(src, tmp_path)
    (k,) = [k for k, b in enumerate(blocks) if b["text"] == "Intro text."]
    assert blocks[k]["file"] == "sections/intro.tex"
    for name in ("sections/intro.tex", "Sections/Intro.tex"):
        assert prose.block_of({"blocks": blocks}, {"file": name, "start": 0, "end": 5}) == k


def test_line_numbers():
    t = "one\ntwo\n\nfour" * 3
    assert [prose._line(t, k) for k in range(len(t) + 2)] == [t.count("\n", 0, k) + 1 for k in range(len(t) + 2)]


# --- diff marks -----------------------------------------------------------------------------------------------

SAME = ["Plain paragraph number {} stays exactly the same in both rounds of the paper.".format(w)
        for w in ("one", "two", "three", "four", "five")]
MOVED = "A paragraph that the student moves to an earlier place unchanged in every word."
OLD = "\\begin{document}\n\\section{Intro}\n\n" + "\n\n".join([
    SAME[0], "Alpha beta gamma delta epsilon zeta eta theta iota kappa.", SAME[1],
    "This whole paragraph is going to be deleted by the student.", SAME[2],
    "Lambda mu nu xi omicron pi rho sigma tau upsilon phi chi.", SAME[3], MOVED,
    "The quick brown fox jumps over the lazy dog near the old river bank today.", SAME[4]]) + "\n\\end{document}\n"
NEW = "\\begin{document}\n\\section{Intro}\n\n" + "\n\n".join([
    MOVED, SAME[0], "Alpha beta gamma delta NEW WORDS epsilon zeta eta theta iota kappa.", SAME[1], SAME[2],
    "Lambda mu nu xi pi rho sigma tau upsilon phi chi.", SAME[3],
    "The quick red fox leaps over the lazy dog near the old river bank today.", SAME[4]]) + "\n\\end{document}\n"


def test_diff_marks(tmp_path):
    for name, text in (("old", OLD), ("new", NEW)):
        (tmp_path / name).mkdir()
        (tmp_path / name / "main.tex").write_text(text)
    old, new = read_blocks(tmp_path / "old", tmp_path), read_blocks(tmp_path / "new", tmp_path)
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    ids = ["c{:02d}".format(i + 1) for i in range(len(diff.hunks))]
    by_kind = {h["kind"]: cid for h, cid in zip(diff.hunks, ids)}
    blocks, changes = prose._diff_marks(new, old, diff, ids, 2)
    prose._sections(blocks)
    text = {b["text"]: b for b in blocks}

    a = text["Alpha beta gamma delta NEW WORDS epsilon zeta eta theta iota kappa."]  # an insert
    assert [a["text"][s:e] for s, e, _ in a["ins"]] == ["NEW WORDS"] and a["del"] == []
    lam = text["Lambda mu nu xi pi rho sigma tau upsilon phi chi."]  # a delete inside a block
    assert lam["ins"] == [] and [(lam["text"][:d[0]], d[1]) for d in lam["del"]] == [("Lambda mu nu xi ", "omicron")]
    fox = text["The quick red fox leaps over the lazy dog near the old river bank today."]  # refined replace
    assert [fox["text"][s:e] for s, e, _ in fox["ins"]] == ["red", "leaps"]
    assert [d[1] for d in fox["del"]] == ["brown", "jumps"]
    gone = text["This whole paragraph is going to be deleted by the student."]  # a deleted block, where it was
    assert gone["kind"] == "deleted" and gone["round"] == 1 and gone["was"] == "paragraph"
    assert gone["hash"] == "d" + next(b["hash"] for b in old if b["text"] == gone["text"])
    assert blocks.index(gone) == blocks.index(text[SAME[1]]) + 1
    moved = text[MOVED]
    assert moved["moved"] == by_kind["move"] and moved["ins"] == [] and blocks.index(moved) == 1
    assert changes[by_kind["move"]] == [blocks.index(moved)]
    assert sorted(k for ks in changes.values() for k in ks) == sorted(
        blocks.index(b) for b in (a, lam, fox, gone, moved))
    assert all(b["section"] == 0 for b in blocks[1:])


def test_swapped_paragraphs_are_moved(tmp_path):
    # two run-in paragraphs swapped, one gaining \noindent; the moves leave out the \textbf{ lead-in
    # and the final period, and the blocks read "Moved" rather than as inserted words with the other one struck out
    first = ("\\textbf{Pool conditions.}\nWe evaluate four representative warm pool policies on every "
             "trace of the benchmark and report each one separately")
    second = ("\\textbf{Trace Collection.}\nWe replay four public traces from different providers and "
              "sample ten runs for each trace at load one")
    for name, text in (("old", first + ".\n\n\\noindent " + second + ".\n"),
                       ("new", "\\noindent " + second + ".\n\n\\noindent" + first + ".\n")):
        (tmp_path / name).mkdir()
        (tmp_path / name / "main.tex").write_text("\\begin{document}\n" + text + "\\end{document}\n")
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    ids = ["c{:02d}".format(i + 1) for i in range(len(diff.hunks))]
    blocks, changes = prose._diff_marks(read_blocks(tmp_path / "new", tmp_path),
                                        read_blocks(tmp_path / "old", tmp_path), diff, ids, 2)
    assert "move" in [h["kind"] for h in diff.hunks]
    assert [(b["text"][:16], bool(b["moved"]), b["ins"], b["del"]) for b in blocks] == [
        ("Trace Collection", True, [], []), ("Pool conditions.", True, [], [])]


def test_deleted_table_row(tmp_path):
    # a row deleted from a table; the deletion is a point in the new table, which the change touches
    rows = ["Mem0 & 1.24 \\\\", "MemoryOS & 0.93 \\\\", "A-MEM & 1.05 \\\\"]
    table = "\\begin{table}\n\\caption{Changes.}\n\\begin{tabular}{lr}\n%s\n\\end{tabular}\n\\end{table}\n"
    for name, kept in (("old", rows), ("new", rows[1:])):
        (tmp_path / name).mkdir()
        (tmp_path / name / "main.tex").write_text("\\begin{document}\nText.\n\n" + table % "\n".join(kept)
                                                  + "\\end{document}\n")
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    assert [h["kind"] for h in diff.hunks] == ["delete"]
    blocks, changes = prose._diff_marks(read_blocks(tmp_path / "new", tmp_path),
                                        read_blocks(tmp_path / "old", tmp_path), diff, ["c01"], 2)
    assert [b["kind"] for b in blocks] == ["paragraph", "table"] and changes == {"c01": [1]}


def test_removed_input(tmp_path):
    # the \\input of a figure's file deleted; its blocks are shown as deleted where it was
    fig = "\\begin{figure}\n\\caption{Drop in diversity.}\n\\end{figure}\n"
    for name, body in (("old", "One.\n\n\\input{figs/drop}\n\nTwo.\n"), ("new", "One.\n\nTwo.\n")):
        (tmp_path / name / "figs").mkdir(parents=True)
        (tmp_path / name / "figs" / "drop.tex").write_text(fig)
        (tmp_path / name / "main.tex").write_text("\\begin{document}\n" + body + "\\end{document}\n")
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    blocks, changes = prose._diff_marks(read_blocks(tmp_path / "new", tmp_path),
                                        read_blocks(tmp_path / "old", tmp_path), diff, ["c01"], 2)
    assert [(b["kind"], b.get("was"), b["text"]) for b in blocks] == [
        ("paragraph", None, "One."), ("deleted", "figure", "Figure 1: Drop in diversity."), ("paragraph", None, "Two.")]
    assert changes == {"c01": [1]}


def test_split_and_joined_paragraphs(tmp_path):
    # a paragraph split in two and two joined: the blocks at the break, with no marks (no struck-through copy)
    old = ("First sentence of a long paragraph stays here. Second sentence starts the new paragraph later on.\n\n"
           "Another paragraph one. Merged tail words follow.\n\nAnother paragraph two goes on here.\n")
    new = ("First sentence of a long paragraph stays here.\n\nSecond sentence starts the new paragraph later on.\n\n"
           "Another paragraph one. Merged tail words follow.\nAnother paragraph two goes on here.\n")
    o, n_ = _blocks_of(tmp_path, "old", old), _blocks_of(tmp_path, "new", new)
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    ids = ["c{:02d}".format(i + 1) for i in range(len(diff.hunks))]
    blocks, changes = prose._diff_marks(n_, o, diff, ids, 2)
    assert [(b["ins"], b["del"], b["moved"]) for b in blocks] == [([], [], None)] * 3
    assert sorted({k for ks in changes.values() for k in ks}) == [0, 1, 2]


def test_text_read_before_needs_reading_when_edited(tmp_path):
    # a new heading worded as one already read is unread until read in its round
    o = _blocks_of(tmp_path, "old", "\\section{Results}\nOne.\n\n\\section{Method}\nTwo.\n")
    n_ = _blocks_of(tmp_path, "new", "\\section{Results}\nOne.\n\n\\section{Method}\nTwo.\n\n\\section{Results}\n"
                    "Three.\n")
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    blocks, changes = prose._diff_marks(n_, o, diff, ["c01"], 2)
    read = {b["hash"]: 1 for b in o}
    first, added = blocks[0], blocks[4]
    assert first["hash"] == added["hash"] and added["added"] == "c01" and prose.fresh(added)
    assert prose.is_read(first["hash"], prose.fresh(first), read, 2)
    assert not prose.is_read(added["hash"], prose.fresh(added), read, 2)
    items = [(blocks[k]["hash"], prose.fresh(blocks[k])) for k in changes["c01"]]
    assert not prose.change_read({"kind": "insert"}, items, read, 2)
    read.update({h: 2 for h, _ in items})  # read in round 2: both headings, and the change is handled
    assert prose.is_read(added["hash"], True, read, 2) and prose.change_read({"kind": "insert"}, items, read, 2)


def test_added_block(tmp_path):
    for name, text in (("old", "\\begin{document}\nOne.\n\nThree.\n\\end{document}\n"),
                       ("new", "\\begin{document}\nOne.\n\nA new paragraph in between.\n\nThree.\n\\end{document}\n")):
        (tmp_path / name).mkdir()
        (tmp_path / name / "main.tex").write_text(text)
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    blocks, changes = prose._diff_marks(read_blocks(tmp_path / "new", tmp_path),
                                        read_blocks(tmp_path / "old", tmp_path), diff, ["c01"], 2)
    assert [(b["text"], b["added"], b["ins"]) for b in blocks] == [
        ("One.", None, []), ("A new paragraph in between.", "c01", []), ("Three.", None, [])]
    assert changes == {"c01": [1]}


# --- the fixture paper: build, read state, comments in prose, state --------------------------------------------

@pytest.fixture(scope="module")
def round2(round1_template, tmp_path_factory):
    """The fixture paper: R1-01 on "simple keep-alive", round 1 finished (every paragraph read), v2 ingested."""
    paper = tmp_path_factory.mktemp("prose") / "paper"
    shutil.copytree(round1_template, paper)
    pdf = str(paper / "r1" / "build" / "main.pdf")
    api.comment({"paper": str(paper), "page": 0, "rects": select(pdf, 0, "simple keep-alive"),
                 "text": "simple keep-alive", "note": "static?"}, quiet)
    api.finish({"paper": str(paper)}, quiet)
    api.ingest({"paper": str(paper), "source": str(FIXTURE / "v2")}, quiet)
    return paper


@pytest.fixture
def paper2(round2, tmp_path):
    dest = tmp_path / "paper"
    shutil.copytree(round2, dest)
    return dest


def by_text(data, start):
    return next(k for k, b in enumerate(data["blocks"]) if b["text"].startswith(start) and b["kind"] != "deleted")


def test_round1_ingest_and_finish(round1_template, tmp_path):
    paper = tmp_path / "paper"
    shutil.copytree(round1_template, paper)
    s = api.state_({"paper": str(paper)}, quiet)["state"]
    data = prose.load(paper, 1)
    assert data["round"] == 1 and data["against"] is None and "prose" not in s["round"]
    counted = [k for k, b in enumerate(data["blocks"]) if prose.readable(b)]
    assert s["reading"]["read"] == [] and s["reading"]["count"] == s["reading"]["unread"] == len(counted)  # all unread
    assert sorted(p["block"] for p in s["reading"]["paragraphs"]) == counted  # as printed: Table 1 after the text above it
    text = [b for b in data["blocks"] if b["kind"] in ("paragraph", "heading", "bibitem")]
    assert all(b["parts"] and b["box"] is None for b in text)  # a text block is read in its parts, it has no box
    assert all(b["box"] and b["clip"] for b in data["blocks"] if b["kind"] in ("figure", "table", "math"))
    assert (paper / "r1" / "prose.json").stat().st_size < 1_000_000
    with pytest.raises(EngineError, match="Round 1 has no paragraph 999."):
        api.read({"paper": str(paper), "blocks": [999]}, quiet)
    a, b = counted[:2]
    s = api.read({"paper": str(paper), "blocks": [a, b]}, quiet)["state"]
    assert s["reading"]["read"] == [a, b]
    s = api.read({"paper": str(paper), "blocks": [b], "read": False}, quiet)["state"]
    assert s["reading"]["read"] == [a]
    s = api.finish({"paper": str(paper)}, quiet)["state"]
    lg = ledger.load(paper)
    assert set(lg["read"]) == {b["hash"] for b in data["blocks"] if b["hash"]} and set(lg["read"].values()) == {1}
    assert lg["read_through"] == 1
    assert s["reading"]["unread"] == 0
    with pytest.raises(EngineError, match="Round 1 is closed."):
        api.read({"paper": str(paper), "blocks": [2]}, quiet)


def test_round2_marks_and_state(round2):
    data = prose.load(round2, 2)
    s = state.build(round2)
    assert data["against"] == 1
    ch = {c["id"]: c for c in s["changes"]}
    blocks = data["blocks"]
    simple = blocks[by_text(data, "Most platforms use a static")]
    assert [simple["text"][a:b] for a, b, _ in simple["ins"]] == ["static"] and simple["del"][0][1] == "simple"
    assert ch["c01"]["blocks"] == [blocks.index(simple)] and ch["c01"]["attached_to"] == ["R1-01"]
    moved = blocks[by_text(data, "Our simulator is event-driven")]
    assert moved["moved"] == "c05" and ch["c05"]["blocks"] == [blocks.index(moved)] and ch["c05"]["read"] is False
    footprint = blocks[by_text(data, "The controller adds little overhead")]
    assert [d[1] for d in footprint["del"]] == ["The memory footprint is two floating-point numbers per function."]
    table = blocks[by_text(data, "Table 1:")]
    assert ch["c03"]["blocks"] == [blocks.index(table)] and table["before"]["page"] == 2
    eq = next(b for b in blocks if b["kind"] == "math" and "\\tau \\, k" in b["text"])
    assert eq["before"] and ch["c07"]["blocks"] == [blocks.index(eq)]
    # the changed paragraphs are unread; the moved one keeps its hash and stays read
    unread = {k for k, b in enumerate(blocks) if prose.readable(b)} - set(s["reading"]["read"])
    assert unread == {k for c in ch.values() if c["kind"] != "move" for k in c["blocks"] if prose.readable(blocks[k])}
    assert s["reading"]["unread"] == len(unread) and all(not c["read"] for c in ch.values())
    # R1-01 is in the paragraph whose word replaced it
    assert next(c for c in s["comments"] if c["id"] == "R1-01")["paragraph"] == blocks.index(simple)
    stored = analysis.changes(round2, 2)  # the blocks each change touches, in analysis.cache.json
    assert all(c["hashes"] == [blocks[k]["hash"] for k in ch[c["id"]]["blocks"] if prose.readable(blocks[k])]
               for c in stored)
    assert "hashes" not in json.loads((round2 / "r2" / "analysis.json").read_text())["changes"][0]


def test_reading_counts_as_checking(paper2):
    p = str(paper2)
    s = api.state_({"paper": p}, quiet)["state"]
    c06 = next(c for c in s["changes"] if c["id"] == "c06")
    assert c06["unrequested"] and not c06["read"]
    before, handled = s["summary"]["to_check"], s["summary"]["handled"]
    s = api.read({"paper": p, "blocks": c06["blocks"]}, quiet)["state"]
    assert next(c for c in s["changes"] if c["id"] == "c06")["read"]
    assert s["summary"]["to_check"] == before - 1 and s["summary"]["handled"] == handled + 1  # UI v4's ring fill
    assert api.summaries({"papers": [p]}, quiet)["papers"][0]["summary"]["to_check"] == before - 1
    s = api.read({"paper": p, "blocks": c06["blocks"], "read": False}, quiet)["state"]  # computed, not stored
    assert not next(c for c in s["changes"] if c["id"] == "c06")["read"] and s["summary"]["to_check"] == before
    c05 = next(c for c in s["changes"] if c["id"] == "c05")  # a move stays to check, its block was read
    s = api.read({"paper": p, "blocks": c05["blocks"]}, quiet)["state"]
    assert not next(c for c in s["changes"] if c["id"] == "c05")["read"]
    # final.pdf counts a read change as read
    api.read({"paper": p, "blocks": c06["blocks"]}, quiet)
    api.finish({"paper": p}, quiet)
    final = pymupdf.open(paper2 / "r2" / "final.pdf")
    summary = "".join(page.get_text() for page in final if page.get_label().startswith("Summary"))
    assert "Your changes no comment asked for (6)" in summary and summary.split("\n").count("read") == 1  # its row


def test_edits_left_unread_are_read_next_round(paper2):
    # round 2's edits left unread are read in round 3 (closing round 2 marked them read: BACKLOG D5)
    p = str(paper2)
    data = prose.load(paper2, 2)
    assert prose.fresh(data["blocks"][by_text(data, "Most platforms use a static")])
    assert not prose.fresh(data["blocks"][by_text(data, "Function-as-a-Service")])
    api.finish({"paper": p}, quiet)
    api.ingest({"paper": p, "source": str(FIXTURE / "v3")}, quiet)
    d3, s = prose.load(paper2, 3), state.build(paper2)
    k = by_text(d3, "Most platforms use a static")
    assert not prose.fresh(d3["blocks"][k]) and d3["blocks"][k]["ins"] == [] and k in s["reading"]["read"]
    assert not any("since" in b for b in d3["blocks"])  # the round a block's text is from: only the prose view read it


def _unread(s, data):
    return {p["block"] for p in s["reading"]["paragraphs"]} - set(s["reading"]["read"])


def test_closing_a_round_marks_every_paragraph_read(paper2):
    """BACKLOG D5: closing any round marks its paragraphs read, so the next round's bars are exactly the paragraphs
    changed since; the closed round, viewed later, keeps the bars it was closed with (and its final.pdf)."""
    p = str(paper2)
    d2, s = prose.load(paper2, 2), state.build(paper2)
    left = sorted(_unread(s, d2))
    assert len(left) >= 3
    done, kept = left[0], left[1:]
    api.read({"paper": p, "blocks": [done]}, quiet)
    api.finish({"paper": p}, quiet)
    lg = ledger.load(paper2)
    assert lg["read_through"] == 2 and lg["read"][d2["blocks"][done]["hash"]] == 2
    assert all(lg["read"][d2["blocks"][k]["hash"]] == 1 for k in kept)  # read as of round 1: not confirmed in 2
    assert {b["hash"] for b in d2["blocks"] if b["hash"] and b["kind"] != "deleted"} <= set(lg["read"])
    s2 = state.build(paper2, 2)  # round 2 viewed later: the bars it was closed with
    assert _unread(s2, d2) == set(kept)
    assert not next(c for c in s2["changes"] if set(c["blocks"]) & set(kept))["read"]
    api.ingest({"paper": p, "source": str(FIXTURE / "v3")}, quiet)
    d3, s3 = prose.load(paper2, 3), state.build(paper2)
    unread = _unread(s3, d3)
    assert unread and all(prose.fresh(d3["blocks"][k]) for k in unread)  # changed since round 2, nothing older
    assert all(k not in unread for k, b in enumerate(d3["blocks"]) if prose.readable(b) and not prose.fresh(b))
    # un-reading a paragraph the student left alone (as edited in round 2) sticks
    edited = {b["hash"] for b in d2["blocks"] if prose.fresh(b)}
    k = next(k for k, b in enumerate(d3["blocks"]) if prose.readable(b) and not prose.fresh(b) and b["hash"] in edited)
    s3 = api.read({"paper": p, "blocks": [k], "read": False}, quiet)["state"]
    assert k in _unread(s3, d3) and k in _unread(state.build(paper2), d3)


def test_ledger_closed_before_rounds_marked_read(paper2):
    """A ledger whose round 2 was closed before closing marked paragraphs read (no read_through): in the open round 3
    the paragraphs left unread in round 2 are read as of round 2, without the ledger written; the first write stores
    them, so un-reading one sticks. Round 2 viewed later keeps its bars."""
    p = str(paper2)
    d2 = prose.load(paper2, 2)
    kept = sorted(_unread(state.build(paper2), d2))
    api.finish({"paper": p}, quiet)
    round1 = set(prose.round_hashes(paper2, ledger.load(paper2), 1))
    with ledger.edit(paper2) as lg:  # as the engine left it before: round 1's marks only
        lg["read"] = {h: v for h, v in lg["read"].items() if h in round1}
        del lg["read_through"]
    api.ingest({"paper": p, "source": str(FIXTURE / "v3")}, quiet)
    before = ledger.load(paper2)
    d3, s3 = prose.load(paper2, 3), state.build(paper2)
    unread = _unread(s3, d3)
    assert unread and all(prose.fresh(d3["blocks"][k]) for k in unread)
    edited = {b["hash"] for b in d2["blocks"] if prose.fresh(b)}
    leftover = next(k for k, b in enumerate(d3["blocks"]) if prose.readable(b) and not prose.fresh(b)
                    and b["hash"] in edited and b["hash"] not in before["read"])
    assert leftover in s3["reading"]["read"]
    assert ledger.load(paper2) == before  # state wrote nothing
    assert _unread(state.build(paper2, 2), d2) == set(kept)
    assert api.summaries({"papers": [p]}, quiet)["papers"][0]["summary"]["to_check"] == s3["summary"]["to_check"]
    s3 = api.read({"paper": p, "blocks": [leftover], "read": False}, quiet)["state"]
    lg = ledger.load(paper2)
    assert lg["read_through"] == 2 and leftover in _unread(s3, d3)
    assert all(lg["read"].get(d2["blocks"][k]["hash"]) == 1 for k in kept if d2["blocks"][k]["hash"] !=
               d3["blocks"][leftover]["hash"])
    assert _unread(state.build(paper2, 2), d2) == set(kept)


def test_older_ledger_without_read(paper2):
    with ledger.edit(paper2) as lg:
        del lg["read"]
    lg = ledger.load(paper2)
    round1 = prose.round_hashes(paper2, lg, 1)
    assert prose.read_map(paper2, lg) == {h: 1 for h in round1}  # closed rounds count as read
    s = state.build(paper2)
    assert s["reading"]["unread"] == sum(1 for b in prose.load(paper2, 2)["blocks"]
                                         if b["hash"] and b["hash"] not in round1)
    blocks = prose.load(paper2, 2)["blocks"]
    k = next(k for k, b in enumerate(blocks) if b["hash"] and b["hash"] not in round1)
    api.read({"paper": str(paper2), "blocks": [k]}, quiet)  # the first write stores the map
    stored = ledger.load(paper2)["read"]
    assert set(round1) <= set(stored) and all(stored[h] == 1 for h in round1) and stored[blocks[k]["hash"]] == 2


def test_prose_rpc_and_cli(paper2, capsys):
    from paperole import cli
    (paper2 / "r2" / "prose.json").unlink()
    events = []
    out = api.prose_({"paper": str(paper2)}, events.append)
    assert out["path"] == str(paper2 / "r2" / "prose.json") and out["state"]["reading"]["count"] > 0
    assert events == ["Finding the paragraphs…"]
    assert api.prose_({"paper": str(paper2), "round": 1}, quiet)["state"]["round"]["n"] == 1
    with pytest.raises(EngineError, match="There is no round 9."):
        api.prose_({"paper": str(paper2), "round": 9}, quiet)
    with ledger.edit(paper2) as lg:  # a round whose build failed
        lg["rounds"][1]["build"]["pdf"] = None
    with pytest.raises(EngineError, match="Round 2 has no build PDF."):
        (paper2 / "r2" / "prose.json").unlink()
        api.prose_({"paper": str(paper2)}, quiet)
    assert cli.main(["read", str(paper2), "1", "2"]) == 1  # no PDF: refused
    assert "Round 2 has no PDF" in capsys.readouterr().err


def test_stale_prose_is_rebuilt(paper2):
    path = paper2 / "r2" / "prose.json"
    data = json.loads(path.read_text())
    data["parser"] = prose.PARSER - 1
    path.write_text(json.dumps(data))
    assert prose.load(paper2, 2) is None and state.build(paper2)["reading"] is None
    api.prose_({"paper": str(paper2)}, quiet)
    assert prose.load(paper2, 2)["parser"] == prose.PARSER


def test_placeholder_ids_when_the_diff_differs(paper2):
    # m22: a rebuild whose diff does not give analysis.json's changes marks the edits under placeholder ids (was: None,
    # so a wholly added block was not fresh and a moved one not moved); no change is said to touch a block
    path = paper2 / "r2" / "analysis.json"
    data = json.loads(path.read_text())
    data["changes"] = data["changes"][1:]
    path.write_text(json.dumps(data))
    out = prose.build(paper2, ledger.load(paper2), 2)
    assert out["changes"] == {} and out["against"] == 1
    assert out["blocks"][by_text(out, "Our simulator is event-driven")]["moved"] == "?05"
    simple = out["blocks"][by_text(out, "Most platforms use a static")]
    assert [m[2] for m in simple["ins"]] == ["?01"] and prose.fresh(simple)


def test_round_before_that_fails(paper2):
    # m23: when round 1's paragraphs cannot be found, that is noted, and round 2 is built without diff marks (so a
    # later round does not fail too, and is not tried again on every call)
    (paper2 / "r1" / "prose.json").unlink()
    (paper2 / "r1" / "src" / "main.tex").unlink()
    out = prose.build(paper2, ledger.load(paper2), 2)
    assert out["against"] is None and out["changes"] == {} and not any(prose.fresh(b) for b in out["blocks"])
    assert prose.failed(paper2, 1) and not prose.failed(paper2, 2) and prose.load(paper2, 2) == out


def test_restaging_analysis_keeps_the_cache(paper2):
    # M8: a re-anchor stages a new analysis.json (attached_to, unrequested); the blocks each change touches, which
    # only building prose.json writes into analysis.cache.json, are kept for it
    c06 = next(c for c in state.build(paper2)["changes"] if c["id"] == "c06")
    api.read({"paper": str(paper2), "blocks": c06["blocks"]}, quiet)  # handled by reading: not to check
    before = {c["id"]: (c["hashes"], c["fresh"]) for c in analysis.changes(paper2, 2)}
    raw = (paper2 / "r2" / "analysis.json").read_bytes()
    pdf = str(paper2 / "r2" / "build" / "main.pdf")
    target = "WarmCast instead decides how many instances to keep,"
    s = api.reanchor({"paper": str(paper2), "id": "R1-01", "page": 0, "rects": select(pdf, 0, target),
                      "text": target}, quiet)["state"]
    assert (paper2 / "r2" / "analysis.json").read_bytes() != raw
    assert {c["id"]: (c.get("hashes"), c.get("fresh")) for c in analysis.changes(paper2, 2)} == before
    assert api.summaries({"papers": [str(paper2)]}, quiet)["papers"][0]["summary"]["to_check"] == \
        s["summary"]["to_check"]


PRINTED = r"""\documentclass[twocolumn]{article}
\usepackage[round]{natbib}
\usepackage{amsmath}
\newcommand{\method}{WarmCast}
\begin{document}
\section{Pools}\label{sec:pools}
Prior work by \citet{lee2024} keeps one instance warm, and \method{} keeps a pool of them, as
Section~\ref{sec:pools} explains for every function of the trace.
We estimate the arrival rate with exponential smoothing over the last few intervals of the trace,
\begin{equation}
\lambda_t = \alpha x_t + (1-\alpha)\lambda_{t-1}.
\end{equation}
The rate then sets the size of the pool for the next interval of the trace.
\begin{thebibliography}{1}
\bibitem[Lee et~al.(2024)]{lee2024} A. Lee, B. Kim, and C. Park. 2024. Pools at scale. In \emph{Proc. ATC}.
\end{thebibliography}
\end{document}
"""


@pytest.fixture(scope="module")
def printed(tmp_path_factory):
    """A two-column paper with \\citet, a macro, a \\ref and a formula after a lead-in, round 1 ingested."""
    root = tmp_path_factory.mktemp("printed")
    (root / "src").mkdir()
    (root / "src" / "main.tex").write_text(PRINTED)
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Printed", "student": "S"}, quiet)
    api.ingest({"paper": str(paper), "source": str(root / "src")}, quiet)
    return paper


def _words_in(pdf, page, rects):
    words = pymupdf.open(pdf)[page].get_text("words")
    return [w[4] for w in words if any(r[0] <= (w[0] + w[2]) / 2 <= r[2] and r[1] <= (w[1] + w[3]) / 2 <= r[3]
                                       for r in rects)]


def test_formula_crop_and_box_hold_only_the_formula(printed):
    # synctex gives the lead-in's lines (broken when the display starts) the display's first line
    data = prose.load(printed, 1)
    m = next(b for b in data["blocks"] if b["kind"] == "math")
    pdf = str(printed / "r1" / "build" / "main.pdf")
    for place in (m["box"], m["clip"]):
        words = _words_in(pdf, place[0], [place[1]])
        assert words and not {"smoothing", "intervals", "trace,"} & set(words), words


def test_state_timing(round2):
    state.build(round2)
    t = time.perf_counter()
    for _ in range(5):
        state.build(round2)
    assert (time.perf_counter() - t) / 5 < 0.15
