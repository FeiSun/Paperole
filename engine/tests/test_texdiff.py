"""texdiff on the fixture paper (fixtures/paper/EDITS.md) and on small synthetic trees."""
import difflib
import gzip
import random
import unicodedata
from pathlib import Path

import pytest

from paperole import texdiff

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "paper"


def _squash(s):
    return " ".join(s.split())


def _line(text, offset):
    return text.count("\n", 0, offset) + 1


def _lines_span(text, first, last):
    """Offsets of lines first..last (1-based, inclusive)."""
    starts = [0] + [i + 1 for i, c in enumerate(text) if c == "\n"]
    return starts[first - 1], starts[last] - 1


def _tree(root, files):
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return root


@pytest.fixture(scope="module")
def d12():
    return texdiff.diff_trees(FIXTURE / "v1", FIXTURE / "v2")


@pytest.fixture(scope="module")
def d23():
    return texdiff.diff_trees(FIXTURE / "v2", FIXTURE / "v3")


def test_v1_v2_gives_e1_to_e7_in_contract_order(d12):
    got = [(h["kind"], h["new_file"], _squash(h["old_text"]), _squash(h["new_text"])) for h in d12.hunks]
    moved = ("Our simulator is event-driven and models the memory of each host but not its CPU. It assumes that a "
             "warm instance serves a request immediately and that a cold start blocks the request for the full start "
             "duration. These assumptions favour no policy in particular, since all policies share them.")
    assert got == [
        ("replace", "main.tex", "simple", "static"),  # E1
        ("replace", "main.tex", "decide when to keep a single instance alive",  # E2: "Both approaches" and "." stay
         "reason about the lifetime of one instance and leave the number of concurrent instances to the autoscaler"),
        ("replace", "main.tex", "655", "671"),  # E7
        ("delete", "main.tex", "The memory footprint is two floating-point numbers per function.", ""),  # E3
        ("move", "main.tex", moved, moved),  # E4
        ("insert", "main.tex", "", "Because the controller needs no changes to the functions themselves, it can be "
                                   "deployed on existing platforms without involving developers."),  # E5
        ("insert", "sections/method.tex", "", "\\tau"),  # E6
    ]
    old, new = d12.old_texts["main.tex"], d12.new_texts["main.tex"]
    lines = [(_line(old, h["old_start"]), _line(new, h["new_start"])) for h in d12.hunks if h["new_file"] == "main.tex"]
    assert lines == [(41, 41), (76, 77), (121, 118), (153, 150), (105, 153), (161, 162)]
    for h in d12.hunks:
        if h["kind"] == "insert":
            assert h["old_start"] == h["old_end"]
        if h["kind"] == "delete":
            assert h["new_start"] == h["new_end"]


def test_rewrap_and_comment_edit_give_no_hunk(d12):
    old, new = d12.old_texts["main.tex"], d12.new_texts["main.tex"]
    for (o1, o2), (n1, n2) in [((63, 70), (63, 71)), ((98, 98), (100, 100))]:  # E8 re-wrap, E9 `%` comment
        os_, oe = _lines_span(old, o1, o2)
        ns, ne = _lines_span(new, n1, n2)
        for h in d12.hunks:
            if h["old_file"] == "main.tex":
                assert h["old_end"] < os_ or h["old_start"] > oe
                assert h["new_end"] < ns or h["new_start"] > ne


def test_v2_v3_gives_f1_to_f3(d23):
    got = [(h["kind"], h["new_file"], _line(d23.new_texts[h["new_file"]], h["new_start"])) for h in d23.hunks]
    assert got == [("replace", "main.tex", 49), ("replace", "main.tex", 53),  # F1, split by the merge rule
                   ("insert", "main.tex", 59),  # F2
                   ("replace", "sections/method.tex", 49)]  # F3
    assert _squash(d23.hunks[2]["new_text"]) == "Background and"
    assert (d23.hunks[3]["old_text"], d23.hunks[3]["new_text"]) == ("30", "20")


def test_map_offset(d12):
    old, new = d12.old_texts["main.tex"], d12.new_texts["main.tex"]
    equal = old.index("boots a minimal")
    assert d12.map_offset("main.tex", equal) == ("main.tex", new.index("boots a minimal"))
    moved = old.index("Our simulator")
    assert d12.map_offset("main.tex", moved + 4) == ("main.tex", new.index("Our simulator") + 4)
    gone = old.index("memory footprint")  # inside the E3 delete: the deletion point, after "per interval."
    point = new.index("per interval.") + len("per interval.")
    assert d12.map_offset("main.tex", gone, "left") == d12.map_offset("main.tex", gone, "right") == ("main.tex", point)
    e1 = old.index("simple keep")  # inside the E1 replace
    assert d12.map_offset("main.tex", e1 + 2, "left") == ("main.tex", new.index("static keep"))
    assert d12.map_offset("main.tex", e1 + 2, "right") == ("main.tex", new.index("static keep") + len("static"))
    assert d12.map_offset("main.tex", old.index("\n\n\\section{Introduction}") + 1) == \
        ("main.tex", new.index("\\section{Introduction}"))  # whitespace maps to the next token (left bias)
    assert d12.map_offset("nope.tex", 0) is None


@pytest.mark.parametrize("pair, file, phrase, expected", [
    ("12", "main.tex", "simple keep-alive", 0.989), ("12", "main.tex", "Both approaches decide", 0.913),
    ("12", "main.tex", "The memory footprint", 0.872), ("12", "sections/method.tex", "The expected cost", 1.0),
    ("12", "main.tex", "Our simulator", 1.0), ("23", "main.tex", "A short-term forecast", 0.145)])
def test_kept_ratio_of_paragraphs(d12, d23, pair, file, phrase, expected):
    d = d12 if pair == "12" else d23
    text = d.old_texts[file]
    start = text.index(phrase)
    assert d.kept_ratio(file, *texdiff.paragraph(text, start, start + len(phrase))) == pytest.approx(expected, abs=0.002)


def test_tokens_ignore_wrapping_and_comments():
    assert texdiff.Tokens("a b\nc d.").texts == texdiff.Tokens("a\n  b c\td.").texts
    assert texdiff.Tokens("50\\% of % the rest\nall").texts == ["50", "\\%", "of", "all"]
    assert texdiff.Tokens("a line\\\\% comment\nnext").texts == ["a", "line", "\\\\", "next"]
    # A line holding only a comment is not a blank line (as in TeX), so it does not break the paragraph.
    assert texdiff.Tokens("one\n% note\ntwo").texts == ["one", "two"]
    assert texdiff.Tokens("one\n\n% note\ntwo").texts == ["one", texdiff.PAR, "two"]
    assert texdiff.Tokens("one %\n\ntwo").texts == ["one", texdiff.PAR, "two"]


def test_sentence_and_paragraph():
    text = "Intro line.\n\nFirst one. Second, see e.g.~[1], is here! Third\nrow \\\\ next % a. b\nend.\n\nLast."
    s = text.index("see")
    assert text[slice(*texdiff.sentence(text, s, s + 3))] == "Second, see e.g.~[1], is here!"
    s = text.index("Third")
    assert text[slice(*texdiff.sentence(text, s, s + 5))] == "Third\nrow \\\\"
    s = text.index("next")
    assert text[slice(*texdiff.sentence(text, s, s + 4))] == "next % a. b\nend."  # `.` in a comment does not count
    assert text[slice(*texdiff.paragraph(text, s, s + 4))] == text[text.index("First"):text.index("end.") + 4]
    assert texdiff.paragraph(text, 0, 5) == (0, len("Intro line."))
    s = text.index("Last")
    assert texdiff.sentence(text, s, s) == (s, len(text))


def test_moves_across_files_and_whole_file_changes(tmp_path):
    para = "This paragraph moves from one chapter to the other without any change at all.\n"
    old = _tree(tmp_path / "old", {"a.tex": "Alpha stays here.\n\n" + para + "\nOmega stays too.\n",
                                    "chap/b.tex": "Beta text.\n", "gone.tex": "Removed file text.\n"})
    new = _tree(tmp_path / "new", {"a.tex": "Alpha stays here.\n\nOmega stays too.\n",
                                    "chap/b.tex": "Beta text.\n\n" + para, "added.tex": "Brand new file.\n"})
    d = texdiff.diff_trees(old, new)
    kinds = {(h["kind"], h["old_file"], h["new_file"]) for h in d.hunks}
    assert kinds == {("insert", None, "added.tex"), ("move", "a.tex", "chap/b.tex"), ("delete", "gone.tex", None)}
    move = next(h for h in d.hunks if h["kind"] == "move")
    assert _squash(move["new_text"]) == _squash(para)
    assert d.map_offset("a.tex", d.old_texts["a.tex"].index("moves")) == \
        ("chap/b.tex", d.new_texts["chap/b.tex"].index("moves"))
    assert d.map_offset("gone.tex", 3) is None
    assert d.hunks[-1]["kind"] == "delete" and d.hunks[-1]["new_start"] is None  # a deleted file sorts last


def test_comment_pointers_and_rewrapping_are_no_change(tmp_path):
    old = _tree(tmp_path / "old", {"main.tex": "We keep a single instance\nalive. Then we stop.\n\nNext paragraph.\n"})
    new = _tree(tmp_path / "new", {"main.tex": "We keep a single instance alive. % R1-03 fixed\n% R1-04: see below\n"
                                               "Then we\nstop.\n\n% R1-05\nNext paragraph.\n"})
    assert texdiff.diff_trees(old, new).hunks == []


def test_the_reference_list_bibtex_typeset_is_compared(tmp_path):
    entry = "\\bibitem{agache}\nAlexandru Agache.\n\\newblock Firecracker: Lightweight WORD for serverless.\n"
    data = "\\entry{agache}{inproceedings}{}\n  \\field{title}{Firecracker WORD}\n\\endentry\n"  # biblatex's .bbl
    old = _tree(tmp_path / "old", {"main.tex": "Text.\n", "shipped.bbl": entry.replace("WORD", "virtualization")})
    new = _tree(tmp_path / "new", {"main.tex": "Text.\n", "shipped.bbl": entry.replace("WORD", "virtual machines")})
    builds = [_tree(tmp_path / root, {"main.bbl": entry.replace("WORD", word), "data.bbl": data.replace("WORD", word),
                                      "shipped.bbl": "\\bibitem{x} Not read: TeX reads the one in src.\n"})
              for root, word in (("old_build", "virtualization"), ("new_build", "VMs"))]
    d = texdiff.diff_trees(old, new, *builds)
    assert set(d.new_texts) == {"main.tex", "main.bbl", "shipped.bbl"}
    assert [(h["new_file"], h["old_text"], h["new_text"]) for h in d.hunks] == \
        [("main.bbl", "virtualization", "VMs"), ("shipped.bbl", "virtualization", "virtual machines")]
    assert set(texdiff.diff_trees(old, new).new_texts) == {"main.tex", "shipped.bbl"}


def test_pure_insert_or_delete_starts_at_a_word(tmp_path):
    old = _tree(tmp_path / "old", {"m.tex": "It runs fast. It is cheap. It scales.\n"})
    new = _tree(tmp_path / "new", {"m.tex": "It runs fast. It scales.\n"})
    (h,) = texdiff.diff_trees(old, new).hunks
    assert (h["kind"], h["old_text"]) == ("delete", "It is cheap.")


SIM = ("Our simulator is event-driven and models the {} of each host but not its CPU. It assumes that a warm\n"
       "instance serves a request immediately.\n")


def test_a_word_edited_in_a_moved_paragraph_is_a_replace_at_its_new_place(tmp_path):
    first, last = "Alpha paragraph has words here. It ends now.\n", "Gamma paragraph keeps its text. Nothing else.\n"
    end = "Delta paragraph closes the section. The end.\n"
    old = _tree(tmp_path / "old", {"m.tex": "\n".join([first, SIM.format("memory"), last, end])})
    new = _tree(tmp_path / "new", {"m.tex": "\n".join([first, last, SIM.format("RAM"), end])})
    d = texdiff.diff_trees(old, new)
    assert [(h["kind"], _squash(h["old_text"])) for h in d.hunks] == [
        ("move", "Our simulator is event-driven and models the"), ("replace", "memory"),
        ("move", "of each host but not its CPU. It assumes that a warm instance serves a request immediately.")]
    first_move, edit, second_move = d.hunks
    assert edit["new_text"] == "RAM"
    assert first_move["new_end"] < edit["new_start"] < edit["new_end"] < second_move["new_start"]  # at the new place
    assert d.old_texts["m.tex"][edit["old_start"]:edit["old_end"]] == "memory"


def test_a_sentence_moved_next_to_an_edit_is_still_a_move(tmp_path):
    moved = "These assumptions favour no policy in particular, since all policies share them."
    old = _tree(tmp_path / "old", {"m.tex": "The pool holds instances for too long. Then it stops.\n\n"
                                            "Second paragraph is here. " + moved + " Last words.\n"})
    new = _tree(tmp_path / "new", {"m.tex": "The pool holds instances for too much time. " + moved
                                            + " Then it stops.\n\nSecond paragraph is here. Last words.\n"})
    d = texdiff.diff_trees(old, new)
    assert [(h["kind"], _squash(h["old_text"]), _squash(h["new_text"])) for h in d.hunks] == [
        ("replace", "long", "much time."), ("move", moved[:-1], moved[:-1])]  # difflib pairs the "." with "time"


def _synctex(build, src, read):
    """A build folder whose synctex file lists the files of src it read, spelled as given (synctex keeps the
    \\input's spelling)."""
    build.mkdir()
    with gzip.open(build / "main.synctex.gz", "wb") as f:
        f.write("".join("Input:{}:{}/./{}\n".format(k, src, name) for k, name in enumerate(read, 1)).encode("utf-8"))
    return build


NFD = unicodedata.normalize("NFD", "sections/méthode.tex")
NFC = unicodedata.normalize("NFC", "sections/méthode.tex")


def test_a_file_read_by_another_spelling_of_its_name_is_read(tmp_path):
    """\\input{Sections/Intro} reads sections/intro.tex on macOS, and an \\input in NFC a file whose name Finder wrote
    in NFD; synctex keeps the \\input's spelling. The file is read (was: unread, so its edits were no change), by the
    name it has on disk, and the \\input names it (was: no file)."""
    main = "\\documentclass{article}\n\\begin{document}\n\\input{Sections/Intro}\n\\input{sections/méthode}\n" \
           "\\end{document}\n"
    files = {"main.tex": main, "sections/intro.tex": "Intro text stays.\n", NFD: "Method text stays.\n"}
    old = _tree(tmp_path / "old", files)
    new = _tree(tmp_path / "new", dict(files, **{"sections/intro.tex": "Intro text changed.\n",
                                                 NFD: "Method text changed.\n"}))
    read = ["main.tex", "Sections/Intro.tex", NFC]
    d = texdiff.diff_trees(old, new, _synctex(tmp_path / "ob", old, read), _synctex(tmp_path / "nb", new, read))
    assert d.new_read == d.old_read == {"main.tex", "sections/intro.tex", NFD} and d.unread == set()
    assert [(h["new_file"], h["old_text"], h["new_text"]) for h in d.hunks] == \
        [("sections/intro.tex", "stays", "changed"), (NFD, "stays", "changed")]
    start = main.index("\\input{Sections")
    assert texdiff.reads(d.new_texts, "main.tex", start, start + 1) == (["sections/intro.tex"], True)
    assert texdiff._includes(d.new_texts)["main.tex"] == {"sections/intro.tex", NFD}


def test_a_round_snapshotted_with_nfd_names_is_compared_with_one_in_nfc(tmp_path):
    """Rounds snapshotted before names were made NFC keep Finder's NFD names; the next round's file of the same name
    in NFC is the same file (was: a deleted and an added file)."""
    old = _tree(tmp_path / "old", {"main.tex": "\\input{sections/méthode}\n", NFD: "One. Two words. Three.\n"})
    new = _tree(tmp_path / "new", {"main.tex": "\\input{sections/méthode}\n",
                                   NFC: "One. Two other words, rewritten at length by the student. Three.\n"})
    d = texdiff.diff_trees(old, new)
    assert d.renamed == {NFD: NFC}
    assert [(h["kind"], h["old_file"], h["new_file"], h["new_text"]) for h in d.hunks] == \
        [("replace", NFD, NFC, "other words, rewritten at length by the student")]


def test_text_moved_to_or_from_a_file_the_build_does_not_read_is_no_move(tmp_path):
    """A paragraph cut from the paper into a scrap file the build does not read is deleted (was: a move into the scrap
    file, listed as no change), and one pasted from a scrap file into the paper is inserted (was: a move)."""
    kept = "This paragraph goes to the scrap file and is no longer printed in the paper at all.\n"
    back = "This paragraph comes back from the scrap file into the paper and is printed again.\n"
    old = _tree(tmp_path / "old", {"main.tex": "\\input{a}\n", "a.tex": "First.\n\n" + kept + "\nLast.\n",
                                    "old.tex": back})
    new = _tree(tmp_path / "new", {"main.tex": "\\input{a}\n", "a.tex": "First.\n\n" + back + "\nLast.\n",
                                    "old.tex": kept})
    read = ["main.tex", "a.tex"]
    d = texdiff.diff_trees(old, new, _synctex(tmp_path / "ob", old, read), _synctex(tmp_path / "nb", new, read))
    assert [(h["kind"], h["old_file"], h["new_file"]) for h in d.hunks] == [("replace", "a.tex", "a.tex")]
    assert "goes to the scrap file" in d.hunks[0]["old_text"] and "comes back" in d.hunks[0]["new_text"]
    # without builds every file prints: the two paragraphs moved
    assert {h["kind"] for h in texdiff.diff_trees(old, new).hunks} == {"move"}


def test_deleting_a_file_the_old_build_did_not_read_is_no_change(tmp_path):
    old = _tree(tmp_path / "old", {"main.tex": "\\input{a}\n", "a.tex": "Printed.\n", "draft.tex": "A scrap.\n"})
    new = _tree(tmp_path / "new", {"main.tex": "\\input{a}\n", "a.tex": "Printed.\n"})
    builds = [_synctex(tmp_path / b, root, ["main.tex", "a.tex"]) for b, root in (("ob", old), ("nb", new))]
    assert texdiff.diff_trees(old, new, *builds).hunks == []
    (h,) = texdiff.diff_trees(old, new).hunks  # not known what the build read: a change
    assert (h["kind"], h["old_file"]) == ("delete", "draft.tex")


def test_a_percent_in_a_url_or_listing_is_no_comment(tmp_path):
    """A % in \\url, \\href's address or \\lstinline is printed (was: a comment, hiding the rest of its line)."""
    assert texdiff.Tokens("See \\url{x.org/%7Ea} now.").texts[-2:] == ["now", "."]
    assert texdiff.Tokens("\\href{x.org/%20}{the page} and \\lstinline|a % b| here.").texts[-2:] == ["here", "."]
    assert texdiff.Tokens("Text. % a real comment\nNext.").texts == ["Text", ".", "Next", "."]
    old = _tree(tmp_path / "old", {"m.tex": "See \\url{https://x.org/%7Euser} for the data.\n"})
    new = _tree(tmp_path / "new", {"m.tex": "See \\url{https://x.org/%7Euser} for the code.\n"})
    assert [(h["old_text"], h["new_text"]) for h in texdiff.diff_trees(old, new).hunks] == [("data", "code")]


def test_import_and_subimport_read_files(tmp_path):
    """\\import{folder}{name} and \\subimport{folder}{name} read folder/name, as \\input does (was: nothing)."""
    text = "\\import{sections/}{intro}\n\\subimport{./chapters}{two.tex}\n\\input{three}\n"
    files = {"main.tex": text, "sections/intro.tex": "", "chapters/two.tex": "", "three.tex": ""}
    assert [texdiff.include_file(m, files) for m in texdiff.INCLUDE.finditer(text)] == \
        ["sections/intro.tex", "chapters/two.tex", "three.tex"]
    assert texdiff.reads(files, "main.tex", 0, len(text)) == (["sections/intro.tex", "chapters/two.tex", "three.tex"],
                                                              True)


def test_a_byte_order_mark_is_no_change(tmp_path):
    old = _tree(tmp_path / "old", {"m.tex": "Text of the paper.\n\nMore text.\n"})
    new = _tree(tmp_path / "new", {"m.tex": "\ufeffText of the paper.\n\n\ufeffMore text.\n"})
    assert texdiff.diff_trees(old, new).hunks == []


def _difflib_longest(a, b, runs, index):
    """The matcher _find_moves used before _longest: difflib's find_longest_match."""
    m = difflib.SequenceMatcher(None, a, b, autojunk=False).find_longest_match(0, len(a), 0, len(b))
    return m.a, m.b, m.size


def test_longest_shared_run_is_difflibs():
    rng = random.Random(7)
    for _ in range(300):
        a = [rng.choice("ab.,c") for _ in range(rng.randint(0, 60))]
        b = [rng.choice("ab.,c") for _ in range(rng.randint(0, 60))]
        if rng.random() < 0.5 and a:  # a long shared run somewhere
            k = rng.randint(0, len(a) - 1)
            b[rng.randint(0, len(b)):0] = a[k:k + rng.randint(8, 30)]
        got = texdiff._longest(a, b, texdiff._runs(a), texdiff._run_index(b))
        want = _difflib_longest(a, b, None, None)
        assert got == (want if want[2] >= texdiff.MOVE_MIN else (0, 0, 0)), (a, b)


@pytest.mark.parametrize("seed", range(4))
def test_moves_on_reordered_sections_are_difflibs(tmp_path, seed, monkeypatch):
    """Moves are found as before (difflib's find_longest_match, seconds on long pieces of reordered sections)."""
    rng = random.Random(seed)
    words = "the of a model data we results method table shows each loss test set is and to in".split()
    sections = ["\\section{S%d}\n\n" % k + "\n\n".join(" ".join(rng.choice(words) for _ in range(rng.randint(30, 90)))
                                                     + "." for _ in range(rng.randint(2, 6))) for k in range(8)]
    order = list(range(8))
    rng.shuffle(order)
    edited = [s.replace(" the ", " a ", 1) if rng.random() < 0.5 else s for s in sections]
    old = _tree(tmp_path / "old", {"m.tex": "\n\n".join(sections) + "\n"})
    new = _tree(tmp_path / "new", {"m.tex": "\n\n".join(edited[k] for k in order) + "\n"})
    got = texdiff.diff_trees(old, new).hunks
    monkeypatch.setattr(texdiff, "_longest", _difflib_longest)
    assert got == texdiff.diff_trees(old, new).hunks
    assert any(h["kind"] == "move" for h in got)
