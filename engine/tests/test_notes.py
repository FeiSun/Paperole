"""Students' notes (notes.py; CONTRACT.md amendment "Student notes"): "% R1-03 …" comment lines in the source, read at
ingest. The syntax and the rules on small synthetic trees (no TeX), then three rounds of a synthetic paper."""
import gzip
import json
import shutil

import pytest

from conftest import select
from paperole import api, ledger, notes, render, state, texdiff
from test_backlog_accuracy import _call, _paper, pytestmark as needs_tex


@pytest.mark.parametrize("comment, ids, text", [
    ("% R1-03 前面加了一段解释为什么 diversity 重要", ["R1-03"], "前面加了一段解释为什么 diversity 重要"),
    ("% R1-05 kept as is because the reviewer asked for this definition", ["R1-05"],
     "kept as is because the reviewer asked for this definition"),
    ("% r1-3: lower case, no leading zero", ["R1-03"], "lower case, no leading zero"),
    ("%[R1-03] in brackets", ["R1-03"], "in brackets"),
    ("% (R2-01) in parentheses", ["R2-01"], "in parentheses"),
    ("% R1-03：全角冒号", ["R1-03"], "全角冒号"),
    ("% R1-03前面没有空格", ["R1-03"], "前面没有空格"),
    ("% Ｒ１－０３ 全角编号", ["R1-03"], "全角编号"),
    ("% R1-03 - a hyphen", ["R1-03"], "a hyphen"),
    ("% R1-03 — an em dash", ["R1-03"], "an em dash"),
    ("% R1-03 · a dot", ["R1-03"], "a dot"),
    ("%%   R1-03   spaces   collapse  ", ["R1-03"], "spaces collapse"),
    ("% R1-03", ["R1-03"], ""),
    ("% R1-03, R1-05 both", ["R1-03", "R1-05"], "both"),
    ("% R1-03 and R1-5: both", ["R1-03", "R1-05"], "both"),
    ("% R1-03、R1-05 两条", ["R1-03", "R1-05"], "两条"),
    ("% [R1-03][R1-03] once", ["R1-03"], "once"),
    ("% R1-03, kept", ["R1-03"], "kept"),
    ("% R12-104 big numbers", ["R12-104"], "big numbers"),
])
def test_note_syntax(comment, ids, text):
    assert notes.parse(comment[1:]) == (ids, text)


@pytest.mark.parametrize("comment", ["% R1.03 a dot", "% R1_03", "% R1 - 03", "% R-03", "% R1-03a", "% R103 x"])
def test_ids_that_are_not_well_formed(comment):
    assert notes.parse(comment[1:]) == ([], comment[2:])


@pytest.mark.parametrize("comment", ["% R1: reviewer one asked", "% Remove this", "% R2-D2", "% TODO R1-03", "%"])
def test_comments_that_are_no_notes(comment):
    assert notes.parse(comment[1:]) is None


def test_only_real_comments_are_read():
    """An escaped \\%, and a % in verbatim text, \\verb, \\lstinline, \\url and \\href's address, is printed, not a
    comment; after \\\\ (a line break) it is one."""
    text = ("Accuracy rose by 5\\% R1-01 points.\n"
            "\\verb|% R1-02| and \\verb+%R1-02+ print it.\n"
            "\\lstinline{% R1-02} and \\lstinline|% R1-02| too.\n"
            "See \\url{https://example.org/%R1-02} and \\href{https://example.org/%R1-02}{the page}.\n"
            "\\begin{verbatim}\n% R1-02 printed\n\\end{verbatim}\n"
            "\\begin{lstlisting}[language=Python]\n% R1-02 printed\n\\end{lstlisting}\n"
            "\\begin{Verbatim*}\n% R1-02 printed\n\\end{Verbatim*}\n"
            "A line break\\\\% R1-03 a note\n"
            "Text. % R1-04 a note too\n")
    found = [(text.count("\n", 0, p) + 1, notes.parse(body)) for p, body in notes.comments_in(text)]
    assert found == [(14, (["R1-03"], "a note")), (15, (["R1-04"], "a note too"))]


# --- find, on two trees without builds ---------------------------------------------------------------------------

DOC = ("\\section{Introduction}\n"                                                              # 1
       "Serverless platforms start a fresh sandbox for every cold invocation.\n"                # 2
       "Keeping instances warm hides the delay but costs memory.\n"                             # 3
       "\n"                                                                                     # 4
       "A simple keep-alive policy holds every instance for a fixed window after its last request.\n"  # 5
       "It is cheap to run and easy to explain.\n"                                              # 6
       "\n"                                                                                     # 7
       "\\section{Method}\n"                                                                    # 8
       "Our controller sizes the warm pool from a short-term forecast.\n"                       # 9
       "It runs once per interval and needs no changes to the platform.\n"                      # 10
       "\n"                                                                                     # 11
       "\\section{Conclusion}\n"                                                                # 12
       "Predictive pools cut cold starts at a small memory cost.\n")                            # 13


def _tree(root, files):
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return root


def _ledger(n=2, closed=None):
    """A ledger whose comments R1-01 … R1-05 were made in round 1 and carried to round n, but those in `closed`
    ({id: (round, verdict)}), closed there."""
    out = []
    for k in range(1, 6):
        cid = "R1-{:02d}".format(k)
        last, verdict = (closed or {}).get(cid, (n - 1, None))
        out.append({"id": cid, "created_round": 1,
                    "rounds": {str(j): {"verdict": verdict if j == last else None} for j in range(1, last + 1)}})
    return {"rounds": [], "comments": out}


def _synctex(build, src, read):
    """A build folder whose synctex file lists the files of src it read."""
    build.mkdir()
    with gzip.open(build / "main.synctex.gz", "wb") as f:
        f.write("".join("Input:{}:{}/./{}\n".format(k, src, name) for k, name in enumerate(read, 1)).encode("utf-8"))
    return build


def _find(tmp_path, old, new, lg=None, n=2, read=None, old_read=None, carry=None):
    """notes.find between two trees ({file: text}); `read` and `old_read`: the files the new and the old build read
    (a synctex file listing them), else all; `carry`: {change index: [comment ids]} attached before the notes."""
    old_src, new_src = _tree(tmp_path / "old", old), _tree(tmp_path / "new", new)
    build = _synctex(tmp_path / "build", new_src, read) if read is not None else None
    old_build = _synctex(tmp_path / "old_build", old_src, old_read) if old_read is not None else None
    diff = texdiff.diff_trees(old_src, new_src, old_build, build)
    changes = [{"id": "c{:02d}".format(k), "attached_to": list((carry or {}).get(k, [])),
                "unrequested": not (carry or {}).get(k)} for k, _ in enumerate(diff.hunks, 1)]
    found, warnings = notes.find(diff, lg or _ledger(n), n, changes)
    return found, warnings, changes


def _lines(text, edits):
    """text with lines replaced ({line number: new line}, "" deletes a line, a list inserts lines before it)."""
    rows = text.split("\n")
    for k in sorted(edits, reverse=True):
        e = edits[k]
        rows[k - 1:k] = e + [rows[k - 1]] if isinstance(e, list) else ([e] if e != "" else [])
    return "\n".join(rows)


def test_a_note_above_an_inserted_paragraph_attaches_it(tmp_path):
    """A note on the first line of a new paragraph attaches the paragraph to its comment, not the edit in the
    Conclusion; that change stays unrequested."""
    new = _lines(DOC, {11: ["", "% R1-03 加了一段定义 forecast", "The forecast is a moving average of arrivals."],
                       13: "Predictive pools cut cold starts at a modest memory cost."})
    found, warnings, changes = _find(tmp_path, {"main.tex": DOC}, {"main.tex": new})
    assert found == {"R1-03": {"text": "加了一段定义 forecast", "file": "main.tex", "line": 12, "changes": ["c01"],
                               "elsewhere": ["c01"], "lines": [{"file": "main.tex", "line": 12, "changes": ["c01"]}]}}
    assert warnings == []
    assert changes == [{"id": "c01", "attached_to": ["R1-03"], "unrequested": False, "student_notes": ["R1-03"]},
                       {"id": "c02", "attached_to": [], "unrequested": True}]


def test_a_note_alone_between_paragraphs_takes_the_nearest_change_below(tmp_path):
    """A note on a line of its own between blank lines attaches the nearest change within NEAR lines, the one below
    it when one above is as near."""
    new = _lines(DOC, {6: "It is cheap to run and simple to explain.",
                       8: ["% R1-03 the new paragraph below", "", "The forecast is a moving average of arrivals.",
                           ""]})
    found, _, changes = _find(tmp_path, {"main.tex": DOC}, {"main.tex": new})
    assert found["R1-03"]["changes"] == ["c02"]
    assert [ch["attached_to"] for ch in changes] == [[], ["R1-03"]]


def test_an_end_of_line_note_takes_the_change_on_its_line(tmp_path):
    """A note at the end of an edited line attaches that edit, not a farther one in the same paragraph."""
    new = _lines(DOC, {5: "A static keep-alive policy holds every instance for a fixed window after its last "
                          "request. % R1-02: simple → static",
                       6: "It is cheap to run and simple to explain."})
    found, _, changes = _find(tmp_path, {"main.tex": DOC}, {"main.tex": new})
    assert found["R1-02"] == {"text": "simple → static", "file": "main.tex", "line": 5, "changes": ["c01"],
                              "elsewhere": ["c01"], "lines": [{"file": "main.tex", "line": 5, "changes": ["c01"]}]}
    assert [ch["attached_to"] for ch in changes] == [["R1-02"], []]


def test_a_note_without_a_change_next_to_it_attaches_none(tmp_path):
    """A "kept as is" note in a paragraph without edits attaches no change, not even one two lines away in the
    paragraph before (a note in a paragraph looks only there)."""
    new = _lines(DOC, {3: "Keeping instances warm hides the delay but costs a lot of memory.",
                       5: "A simple keep-alive policy holds every instance for a fixed window after its last "
                          "request. % R1-02 kept as is: the reviewers use this term"})
    found, _, changes = _find(tmp_path, {"main.tex": DOC}, {"main.tex": new})
    assert found == {"R1-02": {"text": "kept as is: the reviewers use this term", "file": "main.tex", "line": 5,
                               "changes": [], "elsewhere": [], "lines": [{"file": "main.tex", "line": 5, "changes": []}]}}
    assert changes == [{"id": "c01", "attached_to": [], "unrequested": True}]


def test_several_ids_and_lines_are_joined_in_source_order(tmp_path):
    """A line naming two ids is a note of each; lines of one id are joined in source order (files by path), by a
    space when next to each other and by a line break when not."""
    main = _lines(DOC, {9: ["% R1-03, R1-05 two comments, one note",
                            "% R1-03 that goes on here"],
                        13: "Predictive pools cut cold starts at a modest memory cost. % R1-03：结论也改了"})
    found, _, _ = _find(tmp_path, {"main.tex": DOC, "sections/b.tex": "Text.\n"},
                        {"main.tex": main, "sections/b.tex": "Text.\n% R1-03 and in another file\n"})
    assert found["R1-03"]["text"] == "two comments, one note that goes on here\n结论也改了\nand in another file"
    assert (found["R1-03"]["file"], found["R1-03"]["line"]) == ("main.tex", 9)
    assert found["R1-03"]["changes"] == ["c01"] and found["R1-05"]["changes"] == []
    assert found["R1-05"]["text"] == "two comments, one note"


def test_unchanged_notes_are_not_repeated_and_edited_ones_count(tmp_path):
    """Notes left as they were in the previous round (white space aside) are not this round's, nor are their
    problems repeated; an edited note is this round's, as is a line added to a note."""
    old = _lines(DOC, {5: ["% R1-01 kept as is", "% R1-02 first try", "% R1.03 bad id", "% R1-09 unknown",
                           "% R1-04 one line"]})
    new = _lines(DOC, {5: ["%   R1-01    kept   as is", "% R1-02 second try", "% R1.03 bad id", "% R1-09 unknown",
                           "% R1-04 one line", "% R1-04 and another"]})
    found, warnings, _ = _find(tmp_path, {"main.tex": old}, {"main.tex": new})
    assert {cid: n["text"] for cid, n in found.items()} == {"R1-02": "second try", "R1-04": "and another"}
    assert warnings == []


def test_problems_are_warnings_with_file_and_line(tmp_path):
    """An unknown id, a closed comment's id and an id not well formed are listed, each with where it is; a line naming
    an open and an unknown comment counts for the open one."""
    lg = _ledger(3, closed={"R1-04": (1, "verified"), "R1-05": (2, "wontfix")})
    new = _lines(DOC, {5: ["% R1-09 unknown", "% R1-04 closed", "% R1-05 kept as is too", "% R1.03 malformed",
                           "% R1-03, R1-10 one open, one unknown"]})
    found, warnings, _ = _find(tmp_path, {"main.tex": DOC}, {"main.tex": new}, lg=lg, n=3)
    assert list(found) == ["R1-03"]
    assert warnings == [
        {"kind": "unknown", "ids": ["R1-09"], "file": "main.tex", "line": 5, "text": "% R1-09 unknown",
         "message": "There is no comment R1-09, so this note is ignored."},
        {"kind": "closed", "ids": ["R1-04"], "file": "main.tex", "line": 6, "text": "% R1-04 closed",
         "message": "R1-04 was closed in Round 1 (resolved), so this note is ignored."},
        {"kind": "closed", "ids": ["R1-05"], "file": "main.tex", "line": 7, "text": "% R1-05 kept as is too",
         "message": "R1-05 was closed in Round 2 (kept as is), so this note is ignored."},
        {"kind": "malformed", "ids": [], "file": "main.tex", "line": 8, "text": "% R1.03 malformed",
         "message": "This note's ID is not in the form R1-03, so it is ignored."},
        {"kind": "unknown", "ids": ["R1-10"], "file": "main.tex", "line": 9,
         "text": "% R1-03, R1-10 one open, one unknown", "message": "There is no comment R1-10, so this note is ignored."}]


def test_notes_in_files_the_build_does_not_read(tmp_path):
    """A note in a .tex file the build does not read is a warning, not a note; one in a file it reads counts."""
    files = {"main.tex": "\\input{sections/a}\n", "sections/a.tex": DOC, "sections/old.tex": "Old text.\n"}
    new = dict(files, **{"sections/a.tex": DOC + "% R1-01 here\n", "sections/old.tex": "Old text.\n% R1-02 there\n"})
    found, warnings, _ = _find(tmp_path, files, new, read=["main.tex", "sections/a.tex"])
    assert list(found) == ["R1-01"]
    assert warnings == [{"kind": "unread", "ids": ["R1-02"], "file": "sections/old.tex", "line": 2,
                         "text": "% R1-02 there", "message": "The paper does not use sections/old.tex (the build does "
                                                             "not read it), so this note is ignored."}]


def test_a_note_in_a_file_read_by_another_spelling_of_its_name_counts(tmp_path):
    """\\input{Sections/A} reads sections/a.tex on macOS, and synctex keeps the \\input's spelling: a note there
    counts (was: "The paper does not use sections/a.tex")."""
    files = {"main.tex": "\\input{Sections/A}\n", "sections/a.tex": DOC}
    new = dict(files, **{"sections/a.tex": _lines(DOC, {6: EDIT6 + " % R1-01 reworded"})})
    read = ["main.tex", "Sections/A.tex"]
    found, warnings, _ = _find(tmp_path, files, new, read=read, old_read=read)
    assert warnings == [] and list(found) == ["R1-01"]
    assert (found["R1-01"]["file"], found["R1-01"]["changes"]) == ("sections/a.tex", ["c01"])


EDIT6 = "It is cheap to run and simple to explain."
EDIT9 = "Our controller sizes the warm pool from a one-minute forecast."
LONG = ("\\section{Method}\n" + "".join("Line {} of the long paragraph.\n".format(k) for k in range(1, 8)) + "\n"
        "\\section{Results}\nResult one.\nResult two.\n")  # lines 2-8 one paragraph, \section{Results} on line 10


def test_a_note_takes_only_a_change_close_to_it(tmp_path):
    """A note never takes an edit far from it, which would hide that edit from the advisor: a note on a line of its
    own takes one within NEAR lines, not past a sectioning command, not above it when it is alone between paragraphs;
    a note after text takes only the edits in the sentences on its line."""
    note = "% R1-02 kept as is: the reviewers asked for this term"
    joined = LONG.replace(".\n\n\\section", ".\n\\section")  # no blank line before \section{Results} (line 9)
    cases = [  # (old text, new text, the changes R1-02's note takes)
        (LONG, _lines(LONG, {2: [note], 8: "Line 7 of the long paragraph, with a new claim."}), []),  # 7 lines down
        (LONG, _lines(LONG, {2: [note], 3: "Line 2 of the long paragraph, with a new claim."}), ["c01"]),  # 2 down
        (LONG, _lines(LONG, {4: "Line 3 of the long paragraph. " + note,
                             5: "Line 4 of the long paragraph, with a new claim."}), []),  # after text: its sentence
        (joined, _lines(joined, {9: [note], 10: "Result one, with a new claim."}), []),  # past \section{Results}
        (DOC, _lines(DOC, {3: "Keeping instances warm hides the delay but costs a lot of memory.", 4: ["", note]}),
         []),  # alone between paragraphs: not the one above it
    ]
    for k, (old, new, taken) in enumerate(cases):
        found, _, changes = _find(tmp_path / str(k), {"main.tex": old}, {"main.tex": new})
        assert len(changes) == 1 and found["R1-02"]["changes"] == taken, k
        assert changes[0]["unrequested"] == (not taken), k


def test_a_note_and_a_float(tmp_path):
    """A note just above a float reaches the change inside it; one after the float's end, or inside it, does not reach
    out of it."""
    fig = ("Text before the figure.\n\\begin{figure}[t]\n\\centering\n\\caption{Cold starts per hour.}\n"
           "\\end{figure}\nText after the figure.\n")
    new = _lines(fig, {2: ["% R1-05 the caption names the policies"],
                       4: "\\caption{Cold starts per hour under each policy.}", 6: ["% R1-04 kept as is"]})
    found, _, changes = _find(tmp_path / "above", {"main.tex": fig}, {"main.tex": new})
    assert (found["R1-05"]["changes"], found["R1-04"]["changes"]) == (["c01"], [])
    new = _lines(fig, {4: ["% R1-03 see the text below"], 6: "Text after the figure, with a new claim."})
    found, _, changes = _find(tmp_path / "inside", {"main.tex": fig}, {"main.tex": new})
    assert found["R1-03"]["changes"] == [] and changes[0]["unrequested"]


def test_a_note_where_text_was_taken_out(tmp_path):
    """A note where the student took out a paragraph (commented out, say) takes that deletion; one between paragraphs
    after a sentence taken out of the paragraph above does not."""
    new = _lines(DOC, {5: "% " + DOC.split("\n")[4], 6: "% R1-02 dropped the paragraph: see Section 2"})
    found, _, changes = _find(tmp_path / "paragraph", {"main.tex": DOC}, {"main.tex": new})
    assert found["R1-02"]["changes"] == ["c01"] and changes[0]["attached_to"] == ["R1-02"]
    new = _lines(DOC, {6: "", 8: ["% R1-03 kept as is", ""]})
    found, _, changes = _find(tmp_path / "sentence", {"main.tex": DOC}, {"main.tex": new})
    assert found["R1-03"]["changes"] == [] and changes[0]["unrequested"]


def test_a_note_written_again_at_a_new_place_counts(tmp_path):
    """A note whose words were in the previous round's tree counts when it is at a new place with a change next to it
    (written again, or moved, to another file too); one left where it was, or moved with no change next to it, does
    not, nor is it a warning again when its comment is closed."""
    r2 = _lines(DOC, {6: EDIT6 + " % R1-03"})
    for k, (old, new) in enumerate([
            (r2, _lines(_lines(DOC, {6: EDIT6}), {9: EDIT9 + " % R1-03"})),  # a bare note written again
            (r2.replace("% R1-03", "% R1-03 done"), _lines(_lines(DOC, {6: EDIT6}), {9: EDIT9 + " % R1-03 done"}))]):
        found, warnings, changes = _find(tmp_path / str(k), {"main.tex": old}, {"main.tex": new}, n=3)
        assert (found["R1-03"]["changes"], warnings, changes[0]["attached_to"]) == (["c01"], [], ["R1-03"]), k
    old = {"main.tex": "\\input{a}\n\\input{b}\n", "a.tex": _lines(DOC, {6: EDIT6 + " % R1-03 kept"}),
           "b.tex": "B text.\n"}
    new = dict(old, **{"a.tex": _lines(DOC, {6: EDIT6}), "b.tex": "B text, now longer. % R1-03 kept\n"})
    found, _, _ = _find(tmp_path / "file", old, new, n=3)
    assert found["R1-03"]["changes"] == ["c01"]
    # left where it was beside a new edit: not this round's, and the edit is still one to check
    old = _lines(DOC, {9: ["% R1-03 kept the term"]})
    found, warnings, changes = _find(tmp_path / "kept", {"main.tex": old}, {"main.tex": _lines(old, {10: EDIT9})},
                                     n=3)
    assert (found, warnings, changes[0]["unrequested"]) == ({}, [], True)
    # moved with no change next to it; moved beside a change, on a closed comment
    lg = _ledger(3, closed={"R1-04": (2, "verified")})
    old = _lines(DOC, {5: DOC.split("\n")[4] + " % R1-02 kept", 13: DOC.split("\n")[12] + " % R1-04 fixed"})
    new = _lines(DOC, {6: DOC.split("\n")[5] + " % R1-02 kept", 9: EDIT9 + " % R1-04 fixed"})
    found, warnings, _ = _find(tmp_path / "moved", {"main.tex": old}, {"main.tex": new}, lg=lg, n=3)
    assert (found, warnings) == ({}, [])


def test_a_note_moved_into_a_file_the_build_reads_counts(tmp_path):
    """A note in a file the build did not read was never used: moved into one it reads, it counts; left where it was,
    it is not listed again."""
    old = {"main.tex": "\\input{a}\n", "a.tex": DOC, "old.tex": "Old.\n% R1-02 shortened the intro\n"}
    read = ["main.tex", "a.tex"]
    new = dict(old, **{"a.tex": _lines(DOC, {6: EDIT6 + " % R1-02 shortened the intro"}), "old.tex": "Old.\n"})
    found, warnings, _ = _find(tmp_path / "moved", old, new, read=read, old_read=read)
    assert (found["R1-02"]["changes"], warnings) == (["c01"], [])
    found, warnings, _ = _find(tmp_path / "left", old, dict(old, **{"a.tex": _lines(DOC, {6: EDIT6})}), read=read,
                               old_read=read)
    assert (found, warnings) == ({}, [])


def test_notes_in_other_files_are_warnings(tmp_path):
    """Notes are read only in .tex files: one added in a .bib, .sty or .cls file is a warning, not left unsaid."""
    bib = "% R1-04 fixed the year\n@misc{a, title={A}, year={2024}}\n"
    old = {"main.tex": DOC, "refs.bib": bib}
    new = {"main.tex": DOC, "refs.bib": bib + "% R1-05 added a reference\n", "my.sty": "\\newcommand{\\x}{y} % R1-03 x\n",
           "paper.cls": "% R1-09: and here\n"}
    found, warnings, _ = _find(tmp_path, old, new)
    assert found == {}
    assert [(w["kind"], w["file"], w["line"], w["ids"]) for w in warnings] == [
        ("not_tex", "my.sty", 1, ["R1-03"]), ("not_tex", "paper.cls", 1, ["R1-09"]),
        ("not_tex", "refs.bib", 3, ["R1-05"])]
    assert warnings[0]["message"] == "Notes are read only in .tex files, so this note in my.sty is ignored."


def test_each_line_of_a_note_names_its_changes(tmp_path):
    """A note copied to several places says its words once; each line names the changes next to it, and `elsewhere`
    the changes carry had not attached to the comment (not in its sentence)."""
    new = _lines(DOC, {6: EDIT6 + " % R1-03 simpler words", 9: EDIT9 + " % R1-03 simpler words",
                       13: "Predictive pools cut cold starts at a modest memory cost. % R1-03 simpler words"})
    found, _, changes = _find(tmp_path, {"main.tex": DOC}, {"main.tex": new}, carry={2: ["R1-03"]})
    assert found["R1-03"] == {
        "text": "simpler words", "file": "main.tex", "line": 6, "changes": ["c01", "c02", "c03"],
        "elsewhere": ["c01", "c03"], "lines": [{"file": "main.tex", "line": 6, "changes": ["c01"]},
                                                {"file": "main.tex", "line": 9, "changes": ["c02"]},
                                                {"file": "main.tex", "line": 13, "changes": ["c03"]}]}
    assert all(ch["attached_to"] == ["R1-03"] for ch in changes)


def test_an_id_made_after_the_source_was_read():
    """An ID unknown at ingest that a comment made later in the round has now reads so in the state."""
    w = {"kind": "unknown", "ids": ["R2-01"], "file": "main.tex", "line": 6, "text": "% R2-01 fixed",
         "message": "There is no comment R2-01, so this note is ignored."}
    rnd = {"note_warnings": [w, dict(w, ids=["R2-09"], message="There is no comment R2-09, so this note is ignored.")]}
    lg = {"comments": [{"id": "R2-01"}]}
    assert [x["message"] for x in state.note_warnings(lg, rnd)] == [
        "There was no comment R2-01 yet when this source was read, so this note is ignored.",
        "There is no comment R2-09, so this note is ignored."]
    assert rnd["note_warnings"][0] is w and w["message"].startswith("There is no"), "the ledger keeps what was read"


# --- three rounds through ingest ---------------------------------------------------------------------------------

def _students_v2():
    return _lines(DOC, {3: "Keeping instances warm hides the delay but costs about 2 GB of memory per node. "
                           "% R1-01 gave the number",
                        5: "A simple keep-alive policy holds every instance for a fixed window after its last "
                           "request. % R1-02 kept as is: the reviewers use this term",
                        11: ["", "% R1-03：新加一段定义 forecast",
                             "The forecast is an exponentially weighted moving average of each arrival rate.", "",
                             "% R1-09 typo fixed", "% R1.03 see also the appendix"],
                        13: "Predictive pools cut cold starts at a modest memory cost."})


@needs_tex
def test_notes_through_three_rounds(tmp_path):
    """Round 2: the student's notes reach their comments (a change on the note's line, a new paragraph below one, and
    none for "kept as is"), the problems are warnings, and the other edit is still the one to check. Round 3: the
    notes left as they were are not shown again, an edited one is, a note on a comment closed in round 2 is a
    warning, and round 2's notes are in the history. A re-anchor keeps a note's change attached; a ledger from before
    notes reads as without any."""
    old_file = "Old text kept in the folder.\n"
    v3 = _lines(_students_v2(), {5: "A simple keep-alive policy holds every instance for a fixed window after its "
                                    "last request. % R1-02 kept as is: the reviewers and the venue use this term",
                                 6: "It is cheap to run and easy to explain. % R1-01 also here"})
    paper, sources = _paper(tmp_path, [DOC, _students_v2(), v3],
                            files=[{"old.tex": old_file}, {"old.tex": old_file + "% R1-02 not read\n"},
                                   {"old.tex": old_file + "% R1-02 not read\n"}])
    _call(paper, "ingest", source=str(sources[0]))
    pdf = paper / "r1" / "build" / "main.pdf"
    for phrase, note in [("Keeping instances warm hides the delay but costs memory.", "How much memory?"),
                         ("A simple keep-alive policy", "simple → static?"),
                         ("Our controller sizes the warm pool from a short-term forecast.", "Define the forecast.")]:
        _call(paper, "comment", page=0, rects=select(pdf, 0, phrase), text=phrase, note=note, kind="highlight")
    _call(paper, "finish")

    s2 = _call(paper, "ingest", source=str(sources[1]))["state"]
    line = 3 + 2  # main.tex starts with \documentclass and \begin{document}
    by_id = {c["id"]: c for c in s2["comments"]}
    [number] = [ch for ch in s2["changes"] if "2 GB" in ch["new_text"]]
    [paragraph] = [ch for ch in s2["changes"] if "moving average" in ch["new_text"]]
    [other] = [ch for ch in s2["changes"] if "modest" in ch["new_text"]]
    # R1-01's edit is in its sentence (carry attached it too); R1-03's new paragraph is elsewhere
    assert by_id["R1-01"]["student_note"] == {"text": "gave the number", "file": "main.tex", "line": line,
                                              "changes": [number["id"]], "elsewhere": [],
                                              "lines": [{"file": "main.tex", "line": line, "changes": [number["id"]]}]}
    assert by_id["R1-02"]["student_note"] == {"text": "kept as is: the reviewers use this term", "file": "main.tex",
                                              "line": line + 2, "changes": [], "elsewhere": [],
                                              "lines": [{"file": "main.tex", "line": line + 2, "changes": []}]}
    assert by_id["R1-03"]["student_note"] == {"text": "新加一段定义 forecast", "file": "main.tex", "line": line + 9,
                                              "changes": [paragraph["id"]], "elsewhere": [paragraph["id"]],
                                              "lines": [{"file": "main.tex", "line": line + 9,
                                                         "changes": [paragraph["id"]]}]}
    assert (paragraph["attached_to"], paragraph["student_notes"], paragraph["unrequested"]) == (["R1-03"], ["R1-03"],
                                                                                                False)
    assert number["attached_to"] == ["R1-01"] and number["student_notes"] == ["R1-01"]
    assert (other["attached_to"], other["student_notes"], other["unrequested"]) == ([], [], True)
    assert paragraph["id"] in by_id["R1-03"]["changes"]
    assert s2["summary"]["to_check"] == 1  # only the edit no comment asked for
    assert [(w["kind"], w["file"], w["line"]) for w in s2["note_warnings"]] == [
        ("unknown", "main.tex", line + 12), ("malformed", "main.tex", line + 13), ("unread", "old.tex", 2)]
    lg = ledger.load(paper)
    assert lg["rounds"][1]["note_warnings"] == s2["note_warnings"]
    assert {c["id"]: c["rounds"]["2"].get("student_note") for c in lg["comments"]} == \
        {cid: by_id[cid]["student_note"] for cid in by_id}
    assert all(not c["history"][0]["student_note"] for c in s2["comments"])
    analysis = {ch["id"]: ch for ch in json.loads((paper / "r2" / "analysis.json").read_text())["changes"]}
    assert analysis[paragraph["id"]]["student_notes"] == ["R1-03"] and "student_notes" not in analysis[other["id"]]

    # R1-03 placed anew on part of its sentence: the changes are attached again, and the paragraph its note names
    # stays attached
    phrase = "sizes the warm pool"
    s2 = _call(paper, "reanchor", id="R1-03", page=0, rects=select(paper / "r2" / "build" / "main.pdf", 0, phrase),
               text=phrase)["state"]
    [after] = [ch for ch in s2["changes"] if ch["id"] == paragraph["id"]]
    assert (after["attached_to"], after["unrequested"]) == (["R1-03"], False)
    assert {c["id"]: c["changes"] for c in s2["comments"]}["R1-03"] == [paragraph["id"]]
    assert {c["id"]: c["student_note"] for c in s2["comments"]}["R1-03"]["elsewhere"] == [paragraph["id"]]

    _call(paper, "verdict", id="R1-01", verdict="verified")
    _call(paper, "verdict", id="R1-02", verdict="reopened", note="Please give the reason in the text.")
    _call(paper, "verdict", id="R1-03", verdict="verified")
    s2 = _call(paper, "finish")["state"]
    email = (paper / "r2" / "email.txt").read_text(encoding="utf-8")
    assert email.split("\n")[2] == render.REPLY_RULE == (
        "No need to list what you fixed. To explain a change, or why you left something as it is, add a comment line "
        "next to it in the .tex: % R1-03 your note.")

    s3 = _call(paper, "ingest", source=str(sources[2]))["state"]
    [c3] = s3["comments"]
    assert c3["id"] == "R1-02"
    assert c3["student_note"] == {"text": "kept as is: the reviewers and the venue use this term", "file": "main.tex",
                                  "line": line + 2, "changes": [], "elsewhere": [],
                                  "lines": [{"file": "main.tex", "line": line + 2, "changes": []}]}
    assert [h["student_note"] for h in c3["history"]] == [None, by_id["R1-02"]["student_note"]]
    assert [(w["kind"], w["ids"], w["line"]) for w in s3["note_warnings"]] == [("closed", ["R1-01"], line + 3)]
    assert s3["note_warnings"][0]["message"] == "R1-01 was closed in Round 2 (resolved), so this note is ignored."
    old = _call(paper, "state", round=2)["state"]
    assert {c["id"]: c["student_note"]["text"] for c in old["comments"]} == \
        {"R1-01": "gave the number", "R1-02": "kept as is: the reviewers use this term",
         "R1-03": "新加一段定义 forecast"}
    assert len(old["note_warnings"]) == 3

    # a review folder from before notes: no note, no warning, no change named by one
    before = tmp_path / "before"
    shutil.copytree(paper, before)
    lg = json.loads((before / "ledger.json").read_text(encoding="utf-8"))
    for r in lg["rounds"]:
        r.pop("note_warnings", None)
    for c in lg["comments"]:
        for rec in c["rounds"].values():
            rec.pop("student_note", None)
    (before / "ledger.json").write_text(json.dumps(lg, ensure_ascii=False), encoding="utf-8")
    for k in (2, 3):
        path = before / "r{}".format(k) / "analysis.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        for ch in data["changes"]:
            ch.pop("student_notes", None)
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    for k in (2, 3):
        s = _call(before, "state", round=k)["state"]
        assert s["note_warnings"] == [] and all(ch["student_notes"] == [] for ch in s["changes"])
        assert all(c["student_note"] is None and all(h["student_note"] is None for h in c["history"])
                   for c in s["comments"])
