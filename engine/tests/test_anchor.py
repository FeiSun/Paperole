"""comments.locate, anchor.to_pdf and anchor.carry on the fixture paper's three versions (fixtures/paper/EDITS.md).

Each version is copied to a temp dir and built there with latexmk and synctex, as project.compile does.
Comment records are made by hand in the contract's format (CONTRACT.md §4)."""
import os
import shutil
import subprocess
from pathlib import Path

import pymupdf
import pytest

from paperole import EngineError, anchor, comments, texdiff

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "paper"
TEXBIN = "/Library/TeX/texbin"
PATH = TEXBIN + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

ROUND1 = [("R1-01", "simple keep-alive policy", 0, "main.tex", 41, 41),
          ("R1-02", "Both approaches decide when to keep a single instance alive.", 0, "main.tex", 76, 77),
          ("R1-03", "The memory footprint is two floating-point numbers per function.", 2, "main.tex", 153, 154),
          ("R1-04", "Our simulator is event-driven", 1, "main.tex", 105, 105),
          ("R1-05", "The expected cost of a pool of size", 1, "sections/method.tex", 27, 27),
          ("R1-06", "boots a minimal microVM in about 125", 0, "main.tex", 66, 66),
          ("R1-07", "which performed best on a held-out day of the trace", 1, "sections/method.tex", 20, 20)]
ROUND2_NEW = [("R2-01", "671", 2), ("R2-02", "A short-term forecast of the rate is therefore enough", 0),
              ("R2-03", "Related Work", 0)]


def _chars(s):
    return "".join(c.lower() for c in s if c.isalnum())


def _squash(s):
    return " ".join(s.split())


def _centre(r):
    return (r[0] + r[2]) / 2, (r[1] + r[3]) / 2


def _covers(rects, r):
    x, y = _centre(r)
    return any(a[0] <= x <= a[2] and a[1] <= y <= a[3] for a in rects)


@pytest.fixture(scope="module")
def builds(tmp_path_factory):
    """{version: (src, pdf)} for v1, v2, v3, built like project.compile (cwd=src, -outdir=build)."""
    out = {}
    root = tmp_path_factory.mktemp("anchor")
    for v in ("v1", "v2", "v3"):
        src, build = root / v / "src", root / v / "build"
        shutil.copytree(FIXTURE / v, src)
        for d in [p for p in src.rglob("*") if p.is_dir()]:
            (build / d.relative_to(src)).mkdir(parents=True, exist_ok=True)
        subprocess.run(["latexmk", "-norc", "-pdf", "-f", "-synctex=1", "-interaction=nonstopmode", "-file-line-error",
                        "-no-shell-escape", "-outdir=" + str(build), "main.tex"], cwd=src, capture_output=True,
                       env=dict(os.environ, PATH=PATH), timeout=300)
        assert (build / "main.pdf").is_file(), v
        out[v] = (src, build / "main.pdf")
    return out


def _select(builds, v, phrase, page):
    rects = pymupdf.open(builds[v][1])[page].search_for(phrase)
    assert rects, phrase
    return [list(r) for r in rects]


def _locate(builds, v, cid, phrase, page):
    src, pdf = builds[v]
    a, method, confidence = comments.locate(src, pdf, page, _select(builds, v, phrase, page), phrase)
    return {"id": cid, "anchor": a, "last": a}, method, confidence


@pytest.fixture(scope="module")
def round1(builds):
    return {cid: _locate(builds, "v1", cid, phrase, page) for cid, phrase, page, *_ in ROUND1}


@pytest.fixture(scope="module")
def round2(builds, round1):
    diff = texdiff.diff_trees(builds["v1"][0], builds["v2"][0])
    return anchor.carry(builds["v1"][0], builds["v2"][0], builds["v2"][1], diff, [round1[cid][0] for cid, *_ in ROUND1])


@pytest.fixture(scope="module")
def round3(builds, round2):
    records, _ = round2
    items = [{"id": cid, "anchor": records[cid]["anchor"], "last": records[cid]["anchor"]}
             for cid in ("R1-02", "R1-05", "R1-06")]
    items += [_locate(builds, "v2", cid, phrase, page)[0] for cid, phrase, page in ROUND2_NEW]
    diff = texdiff.diff_trees(builds["v2"][0], builds["v3"][0])
    return anchor.carry(builds["v2"][0], builds["v3"][0], builds["v3"][1], diff, items)


@pytest.mark.parametrize("cid, phrase, page, file, first, last", ROUND1)
def test_locate_round1_selections(round1, cid, phrase, page, file, first, last):
    item, method, confidence = round1[cid]
    a = item["anchor"]
    assert (method, confidence) == ("selection", 1.0)
    assert (a["file"], a["lines"], a["page"]) == (file, [first, last], page)
    assert _chars(a["quote"]) == _chars(phrase)
    assert _chars(a["text"]).startswith(_chars(phrase))


def test_locate_display_math_anchors_to_the_environment(builds):
    src, pdf = builds["v1"]
    page = pymupdf.open(pdf)[1]
    rect = next(r for r in page.search_for("C(k)") if r.y0 > 340)  # Eq. (2), not the inline C(k) below it
    a, method, confidence = comments.locate(src, pdf, 1, [list(rect)], "C(k)")
    assert (a["file"], a["lines"], method, confidence) == ("sections/method.tex", [28, 31], "selection", 1.0)
    assert a["quote"].startswith("\\begin{equation}") and a["quote"].endswith("\\end{equation}")
    number = page.search_for("(2)")[0]  # only symbols and the equation number: still the whole formula
    a, method, confidence = comments.locate(src, pdf, 1, [list(number)], "(2)")
    assert (a["lines"], method, a["env"]) == ([28, 31], "selection", "equation")


def test_a_selection_of_only_a_citation_is_its_cite_command(builds):
    """(Was: the synctex line at 0.5.) The words around the selection meet at the \\cite command."""
    src, pdf = builds["v1"]
    a, method, confidence = comments.locate(src, pdf, 0, _select(builds, "v1", "[10, 8].", 0), "[10, 8].")
    assert (method, confidence, a["file"], a["lines"]) == ("selection", 1.0, "main.tex", [38, 38])
    assert a["quote"] == "\\cite{wang2018peeking,oakes2018sock}"


def test_locate_falls_back_to_the_synctex_line(builds, monkeypatch):
    src, pdf = builds["v1"]
    monkeypatch.setattr(comments, "_between_cites", lambda *args: None)
    a, method, confidence = comments.locate(src, pdf, 0, _select(builds, "v1", "[10, 8].", 0), "[10, 8].")
    assert (method, confidence, a["file"], a["lines"]) == ("line", 0.5, "main.tex", [38, 38])
    assert a["quote"].startswith("seconds~\\cite{wang2018peeking,oakes2018sock}")


def test_to_pdf_finds_a_multiline_caption(builds):
    src, pdf = builds["v3"]
    text = (src / "main.tex").read_text()
    start = text.index("Cold-start rate by invocation")  # \caption{...} spans lines; synctex knows only its last
    page, rects, words = anchor.to_pdf(src, pdf, "main.tex", start, start + len("Cold-start rate by invocation"))
    assert (page, words) == (2, "Cold-start rate by invocation")


def test_round2_states_match_edits(round2):
    records, _ = round2
    expected = {"R1-01": ("changed", 0), "R1-02": ("changed", 0), "R1-03": ("gone", 2), "R1-04": ("moved", 2),
                "R1-05": ("changed", 1), "R1-06": ("unchanged", 0), "R1-07": ("unchanged", 1)}
    assert {cid: (r["anchor_state"], r["anchor"]["page"]) for cid, r in records.items()} == expected
    assert all(r["method"] == "diff" for r in records.values())
    conf = {cid: r["confidence"] for cid, r in records.items()}
    assert min(conf["R1-01"], conf["R1-02"], conf["R1-03"]) >= 0.75
    assert conf["R1-04"] == conf["R1-05"] == conf["R1-06"] == conf["R1-07"] == 1.0
    assert _chars(records["R1-01"]["anchor"]["quote"]) == _chars("static keep-alive policy")
    assert "reason about the lifetime" in _squash(records["R1-02"]["anchor"]["quote"])


def test_round2_changes_and_attribution(round2):
    _, changes = round2
    assert [c["id"] for c in changes] == ["c{:02d}".format(k) for k in range(1, 8)]
    assert [(c["kind"], c["file"], c["line"], c["attached_to"]) for c in changes] == [
        ("replace", "main.tex", 41, ["R1-01"]),  # E1
        ("replace", "main.tex", 77, ["R1-02"]),  # E2
        ("replace", "main.tex", 118, []),  # E7, unrequested
        ("delete", "main.tex", 150, ["R1-03"]),  # E3
        ("move", "main.tex", 153, ["R1-04"]),  # E4
        ("insert", "main.tex", 162, []),  # E5, unrequested
        ("insert", "sections/method.tex", 29, ["R1-05"])]  # E6: in the same sentence as R1-05
    assert [c["unrequested"] for c in changes] == [False, False, True, False, False, True, False]
    assert all(c["page"] is not None and c["rects"] for c in changes)
    assert changes[0]["old_text"] == "simple" and changes[0]["new_text"] == "static"


def test_round2_rects(builds, round2):
    records, changes = round2
    doc = pymupdf.open(builds["v2"][1])
    for cid, phrase, page, *_ in ROUND1:
        if cid in ("R1-06", "R1-07"):  # untouched text: the rects hold exactly the quote's words
            a = records[cid]["anchor"]
            assert all(_covers(a["rects"], r) for r in doc[page].search_for(phrase))
            assert _chars(a["text"]) == _chars(phrase) or _chars(a["text"]) == _chars(phrase + ".")
    moved = records["R1-04"]["anchor"]
    target = doc[2].search_for("Our simulator is event-driven")[0]
    assert any(pymupdf.Rect(r).intersects(target) for r in moved["rects"])
    gone = records["R1-03"]["anchor"]
    assert (gone["start"] == gone["end"], gone["quote"], len(gone["rects"])) == (True, "", 1)
    interval = doc[2].search_for("per interval.")[0]  # the word before the deletion point
    rect = gone["rects"][0]
    assert abs(rect[0] - interval.x1) < 1 and rect[2] - rect[0] == pytest.approx(2.0)
    assert abs(rect[1] - interval.y0) < 1 and abs(rect[3] - interval.y1) < 1
    assert _covers(changes[0]["rects"], doc[0].search_for("static")[0])
    equation = next(r for r in doc[1].search_for("C(k)") if r.y0 > 340)
    assert _covers(changes[6]["rects"], equation)  # E6 marks the whole display


def test_round3_reanchors_from_round2(round3):
    records, changes = round3
    expected = {"R1-02": ("unchanged", 0), "R1-05": ("unchanged", 1), "R1-06": ("unchanged", 0),
                "R2-01": ("unchanged", 1), "R2-02": ("changed", 0), "R2-03": ("changed", 0)}
    assert {cid: (r["anchor_state"], r["anchor"]["page"]) for cid, r in records.items()} == expected
    assert "reason about the lifetime" in _squash(records["R1-02"]["anchor"]["quote"])  # round 2's position
    assert records["R2-01"]["anchor"]["text"] == "671"
    assert records["R2-02"]["confidence"] < 0.75  # the heavy rewrite: never a confident wrong place
    assert _chars(records["R2-03"]["anchor"]["quote"]) == _chars("Background and Related Work")
    attached = {cid for c in changes for cid in c["attached_to"]}
    assert attached == {"R2-02", "R2-03"}
    f1 = [c for c in changes if c["file"] == "main.tex" and c["line"] < 59]
    assert len(f1) == 2 and f1[0]["attached_to"] == ["R2-02"] and f1[1]["unrequested"]
    f2 = next(c for c in changes if c["line"] == 59)
    f3 = next(c for c in changes if c["file"] == "sections/method.tex")
    assert (f2["kind"], f2["attached_to"], f3["unrequested"]) == ("insert", ["R2-03"], True)


def test_a_gone_comment_carried_again_keeps_its_point(builds, round2):
    records, _ = round2
    diff = texdiff.diff_trees(builds["v2"][0], builds["v3"][0])
    gone = records["R1-03"]["anchor"]  # reopened in round 2, so carried into round 3
    new, _ = anchor.carry(builds["v2"][0], builds["v3"][0], builds["v3"][1], diff,
                          [{"id": "R1-03", "anchor": gone, "last": gone}])
    a = new["R1-03"]["anchor"]  # still gone, not "unchanged": nothing was put back at its point
    assert (new["R1-03"]["anchor_state"], a["start"] == a["end"], a["quote"], a["page"]) == ("gone", True, "", 2)
    assert a["prefix"].endswith("per interval.")


def test_locate_without_synctex_searches_every_file(builds, tmp_path):
    src, pdf = builds["v1"]
    bare = tmp_path / "main.pdf"  # the build PDF without its main.synctex.gz
    shutil.copy(pdf, bare)
    a, method, _ = comments.locate(src, bare, 1, _select(builds, "v1", "The expected cost of a pool of size", 1), "")
    assert (a["file"], a["lines"], method) == ("sections/method.tex", [27, 27], "selection")
    a, method, _ = comments.locate(src, bare, 0, _select(builds, "v1", "[10, 8].", 0), "[10, 8].")
    assert (a["quote"], method) == ("\\cite{wang2018peeking,oakes2018sock}", "selection")  # by the words around it
    with pytest.raises(EngineError, match="No LaTeX source"):  # generated text is in no source file
        comments.locate(src, bare, 0, _select(builds, "v1", "Abstract", 0), "Abstract")


def test_carry_falls_back_to_the_last_quote(builds, round1):
    src1, src2, pdf2 = builds["v1"][0], builds["v2"][0], builds["v2"][1]
    diff = texdiff.diff_trees(src1, src2)
    r106 = round1["R1-06"][0]["anchor"]
    reworded = dict(r106, quote="A function called once per hour holds memory for ten minutes")
    missing = dict(r106, quote="This sentence was never in any version of the paper at all.")
    deleted = round1["R1-03"][0]["anchor"]
    items = [{"id": "R1-08", "anchor": None, "last": r106}, {"id": "R1-09", "anchor": None, "last": reworded},
             {"id": "R1-10", "anchor": None, "last": missing}, {"id": "R1-11", "anchor": None, "last": deleted},
             {"id": "R1-12", "anchor": None, "last": None},
             {"id": "R1-13", "anchor": None, "last": dict(r106, quote="the cold-start rate", prefix="", suffix="")},
             {"id": "R1-14", "anchor": None, "last": dict(r106, quote="the cold-start rate", prefix="breaks ",
                                                           suffix=" down by how")}]
    records, changes = anchor.carry(src1, src2, pdf2, diff, items)
    exact = records["R1-08"]
    assert (exact["anchor_state"], exact["method"], exact["confidence"], exact["anchor"]["page"]) == ("moved", "exact", 0.9, 0)
    assert _chars(exact["anchor"]["quote"]) == _chars(r106["quote"])
    fuzzy = records["R1-09"]
    assert (fuzzy["anchor_state"], fuzzy["method"]) == ("changed", "fuzzy") and 0.75 <= fuzzy["confidence"] < 1
    assert "invoked once per hour" in _squash(fuzzy["anchor"]["quote"])
    unique = records["R1-14"]  # prefix and suffix pick one of the quote's four places
    assert (unique["anchor_state"], unique["method"], unique["anchor"]["page"]) == ("moved", "exact", 1)
    assert _squash(unique["anchor"]["suffix"]).startswith("down by how")
    for cid in ("R1-10", "R1-11", "R1-12", "R1-13"):  # R1-13: several equally likely places
        assert records[cid] == {"anchor": None, "anchor_state": "orphan", "confidence": 0.0, "method": "none"}
    assert all(c["attached_to"] == [] for c in changes)  # comments without a previous range attach to nothing


def _carry_texts(tmp_path, old_text, new_text, phrases, guessed=()):
    """anchor.carry between two one-file trees, without a PDF: R1-01, R1-02, … on the phrases of old_text."""
    old, new = tmp_path / "old", tmp_path / "new"
    for root, text in ((old, old_text), (new, new_text)):
        root.mkdir()
        (root / "m.tex").write_text(text)
    items = []
    for k, phrase in enumerate(phrases, 1):
        s, e = old_text.index(phrase), old_text.index(phrase) + len(phrase)
        a = {"file": "m.tex", "start": s, "end": e, "quote": phrase, "prefix": old_text[max(0, s - 40):s],
             "suffix": old_text[e:e + 40]}
        items.append({"id": "R1-{:02d}".format(k), "anchor": a, "last": a, "guessed": phrase in guessed})
    return anchor.carry(old, new, tmp_path / "no.pdf", texdiff.diff_trees(old, new), items)


FILLER = "".join("Filler paragraph {} says nothing new and only takes some room in the text.\n\n".format(k)
                 for k in range(6))


def test_a_comment_in_a_moved_and_edited_paragraph_stays_in_it(tmp_path):
    sim = ("Our simulator is event-driven and models the {} of each host but not its CPU. It assumes that a warm\n"
           "instance serves a request immediately.\n\n")
    gone_and_moved = "Sentence A is gone for good now. Sentence B moves far away to the end of the text today."
    old = "Alpha paragraph.\n\n" + sim.format("memory") + gone_and_moved + "\n\n" + FILLER + "Omega paragraph.\n"
    new = "Alpha paragraph.\n\n" + FILLER + sim.format("RAM") + "Omega paragraph. " + gone_and_moved[33:] + "\n"
    records, changes = _carry_texts(tmp_path, old, new, [
        "Our simulator is event-driven and models the memory of each host", "serves a request immediately",
        "Sentence A is gone for good now. Sentence B moves far away"])
    edited, untouched, split = records["R1-01"], records["R1-02"], records["R1-03"]
    assert (edited["anchor_state"], edited["anchor"]["quote"]) == \
        ("changed", "Our simulator is event-driven and models the RAM of each host")
    assert (untouched["anchor_state"], untouched["anchor"]["quote"]) == ("moved", "serves a request immediately")
    replace = next(c for c in changes if c["kind"] == "replace")
    assert (replace["old_text"], replace["new_text"], replace["attached_to"]) == ("memory", "RAM", ["R1-01"])
    assert all("R1-01" in c["attached_to"] for c in changes if "simulator" in c["new_text"])  # both moved pieces
    # a range whose ends land far apart (one deleted, one moved) is not stretched over the text in between
    assert split["anchor"] is None or "Filler" not in split["anchor"]["quote"]


def test_a_short_moved_sentence_is_moved_not_gone(tmp_path):
    short, edited = "Our forecaster is deliberately lightweight.", "Our model is cheap."
    old = "First paragraph. " + short + " We use smoothing.\n\nSecond one. " + edited + " More.\n\nThe end.\n"
    new = "First paragraph. We use smoothing.\n\nSecond one. More.\n\nThe end. " + short + " Our model is cheap now.\n"
    records, changes = _carry_texts(tmp_path, old, new, [short, edited])
    moved, near = records["R1-01"], records["R1-02"]
    assert (moved["anchor_state"], moved["method"], moved["confidence"], moved["anchor"]["quote"]) == \
        ("moved", "exact", 0.9, short)
    assert {c["kind"] for c in changes if "R1-01" in c["attached_to"]} == {"delete", "insert"}  # nothing unrequested
    assert (near["anchor_state"], near["confidence"]) == ("gone", 0.5)  # moved and edited, maybe: a guess


def test_a_sentence_moved_next_to_an_edit_is_moved(tmp_path):
    moved = "These assumptions favour no policy in particular, since all policies share them."
    old = "The pool holds instances for too long. Then it stops.\n\nSecond paragraph is here. " + moved + " Last.\n"
    new = ("The pool holds instances for too much time. " + moved + " Then it stops.\n\n"
           "Second paragraph is here. Last.\n")
    records, changes = _carry_texts(tmp_path, old, new, [moved])
    r = records["R1-01"]
    assert (r["anchor_state"], r["method"], r["confidence"]) == ("moved", "diff", 1.0)
    assert r["anchor"]["quote"] == moved[:-1]  # difflib pairs the old "." with the one after "time"
    assert [(c["kind"], c["attached_to"]) for c in changes] == [("replace", []), ("move", ["R1-01"])]


def test_a_guessed_position_stays_a_guess(tmp_path):
    text = "First paragraph stays.\n\nA note was put near this line by a click.\n"
    click = "A note was put near this line by a click."
    records, _ = _carry_texts(tmp_path, text, text, [click, "First paragraph stays."], guessed=[click])
    assert [(r["anchor_state"], r["confidence"]) for r in records.values()] == [("unchanged", 0.5), ("unchanged", 1.0)]


def test_locate_tells_repeated_words_apart(builds):
    """Each occurrence of a word used several times near each other gets its own range, at word boundaries."""
    src, pdf = builds["v1"]
    doc = pymupdf.open(pdf)
    for word in ("memory", "cost", "is", "the"):
        seen = {}
        for page in range(doc.page_count):
            for w in doc[page].get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP):
                if w[4] != word:
                    continue
                a, method, _ = comments.locate(src, pdf, page, [list(w[:4])], word)
                if a["env"] in comments.MATH_ENVS:  # display math anchors to the whole formula
                    continue
                text = (src / a["file"]).read_text()
                assert (method, a["quote"].lower()) == ("selection", word)
                assert not text[a["start"] - 1].isalnum() and not text[a["end"]].isalnum()
                assert (a["file"], a["start"]) not in seen, (word, page, w[:2], seen.get((a["file"], a["start"])))
                seen[(a["file"], a["start"])] = (page, w[:2])
    title = doc[0].search_for("Serverless")[0]  # \maketitle prints \title far from synctex's lines
    a, method, _ = comments.locate(src, pdf, 0, [list(title)], "Serverless")
    assert (a["lines"], method) == ([9, 9], "selection")


def test_locate_a_reference_from_bibtex(tmp_path):
    src, build = tmp_path / "src", tmp_path / "build"
    src.mkdir()
    (src / "main.tex").write_text("\\documentclass{article}\n\\begin{document}\nServerless platforms start a "
                                  "sandbox~\\cite{agache}.\n\\bibliographystyle{plain}\n\\bibliography{refs}\n"
                                  "\\end{document}\n")
    (src / "refs.bib").write_text("@inproceedings{agache, author = {Alexandru Agache and Marc Brooker}, title = "
                                  "{Firecracker: Lightweight Virtualization for Serverless Applications}, "
                                  "booktitle = {NSDI}, year = {2020}}\n")
    from paperole import project
    pdf = project.compile(src, build, "main.tex", "pdflatex")["pdf"]
    word = pymupdf.open(pdf)[0].search_for("Lightweight")[0]
    title = "\\newblock Firecracker: Lightweight virtualization for serverless applications."
    for rects, text, quote, method, confidence in (  # words, then a point: in the .bbl that BibTeX wrote
            ([list(word)], "Lightweight", "Lightweight", "selection", 1.0),
            ([[word.x1 + 20, word.y0 + 3] * 2], "", title, "line", 0.5)):
        a, m, c = comments.locate(src, pdf, 0, rects, text)
        assert (a["file"], a["lines"], a["quote"], m, c, a["position_guessed"]) == \
            ("main.bbl", [5, 5], quote, method, confidence, not text)
    (build / "main.bbl").unlink()  # without the .bbl, the \bibliography line, as a guess
    a, method, confidence = comments.locate(src, pdf, 0, [list(word)], "Lightweight")
    assert (a["file"], a["lines"], a["quote"], method, confidence, a["position_guessed"]) == \
        ("main.tex", [5, 5], "\\bibliography{refs}", "line", 0.5, True)


def test_a_reopened_gone_comment_and_a_click_note_over_three_rounds(paper):
    from conftest import quiet, select
    from paperole import api
    p = str(paper)
    pdf = str(paper / "r1" / "build" / "main.pdf")

    def call(method, **params):
        return api.METHODS[method](dict(params, paper=p), quiet)

    sentence = "The memory footprint is two floating-point numbers per function."
    call("comment", page=2, rects=select(pdf, 2, sentence), text=sentence, note="多余，删掉。", kind="strikeout")
    y = sum(select(pdf, 0, "boots a minimal microVM in about 125")[0][1::2]) / 2
    note = call("comment", page=0, rects=[[560, y, 560, y]], text="", note="这里加引用。", kind="note")["state"]
    assert [(c["id"], c["method"], c["confidence"]) for c in note["comments"]] == \
        [("R1-02", "line", 0.5), ("R1-01", "selection", 1.0)]
    call("finish")
    for n, version in ((2, "v2"), (3, "v3")):
        cs = {c["id"]: c for c in call("ingest", source=str(FIXTURE / version))["state"]["comments"]}
        gone, guessed = cs["R1-01"], cs["R1-02"]
        assert gone["anchor_state"] == "gone" and gone["new_quote"] == ""
        assert _squash(gone["old_quote"]) == sentence  # round 3: round 2's quote is "", so round 1's is shown
        assert guessed["confidence"] == 0.5 and "microVM" in guessed["text"]  # still needs attention
        call("verdict", id="R1-01", verdict="reopened", note="还是在。")
        call("verdict", id="R1-02", verdict="reopened")
        call("finish")


def _tree(root, files):
    for name, text in files.items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text(text, encoding="utf-8")
    return root


def test_an_anchor_kept_in_synctex_spelling_is_carried(tmp_path):
    """Older ledgers keep synctex's spelling of a file name, the \\input's ("Sections/Intro.tex" for
    sections/intro.tex): carry and shadows find it in the tree as on disk (was: not found)."""
    text = "Intro paragraph stays as it is.\n\nThe second sentence is edited here. It ends.\n"
    old = _tree(tmp_path / "old", {"main.tex": "\\input{Sections/Intro}\n", "sections/intro.tex": text})
    new = _tree(tmp_path / "new", {"main.tex": "\\input{Sections/Intro}\n",
                                   "sections/intro.tex": text.replace("is edited", "was edited")})
    diff = texdiff.diff_trees(old, new)
    items = []
    for k, phrase in enumerate(["Intro paragraph stays", "The second sentence is edited here."], 1):
        s = text.index(phrase)
        a = {"file": "Sections/Intro.tex", "start": s, "end": s + len(phrase), "quote": phrase,
             "prefix": text[max(0, s - 40):s], "suffix": text[s + len(phrase):s + len(phrase) + 40]}
        items.append({"id": "R1-{:02d}".format(k), "anchor": a, "last": a})
    records, changes = anchor.carry(old, new, tmp_path / "no.pdf", diff, items)
    assert [(r["anchor_state"], r["method"], r["anchor"]["file"]) for r in records.values()] == \
        [("unchanged", "diff", "sections/intro.tex"), ("changed", "diff", "sections/intro.tex")]
    assert [(c["file"], c["attached_to"]) for c in changes] == [("sections/intro.tex", ["R1-02"])]
    placed, near = anchor.shadows(diff, items)
    assert {cid: p["file"] for cid, p in placed.items()} == {"R1-01": "sections/intro.tex",
                                                              "R1-02": "sections/intro.tex"}
    assert near == [["R1-02"]]


def test_inputs_are_named_as_on_disk(tmp_path):
    """synctex's input names are keyed by the file's name on disk; an anchor in synctex's spelling finds its input."""
    import gzip
    src = _tree(tmp_path / "src", {"main.tex": "", "sections/intro.tex": ""})
    pdf = tmp_path / "build" / "main.pdf"
    pdf.parent.mkdir()
    pdf.touch()
    names = ["{}/./main.tex".format(src), "{}/./Sections/Intro.tex".format(src)]
    with gzip.open(pdf.with_suffix(".synctex.gz"), "wb") as f:
        f.write("".join("Input:{}:{}\n".format(k, n) for k, n in enumerate(names, 1)).encode())
    stamp = anchor._stamp(pdf)
    assert anchor._inputs(stamp, str(src)) == {"main.tex": names[0], "sections/intro.tex": names[1]}
    assert anchor._input_name(stamp, src, "Sections/Intro.tex") == anchor._input_name(stamp, src,
                                                                                       "sections/intro.tex") == names[1]
    assert anchor._input_name(stamp, src, "other.tex") is None


def test_a_quote_across_a_blank_line_is_found_as_it_is(tmp_path):
    """A last quote that spans a paragraph break is found verbatim (was: never, so a comment in a dropped file, a
    restored one or a shadow was lost)."""
    text = "Alpha one two three.\n\nBeta four five six. Gamma.\n"
    new = _tree(tmp_path / "new", {"m.tex": "Before.\n\n" + text})
    diff = texdiff.diff_trees(_tree(tmp_path / "old", {"m.tex": text}), new)
    quote = "two three.\n\nBeta four"
    found = anchor._search(diff, {"quote": quote, "prefix": "Alpha one ", "suffix": " five"}, fuzzy=False)
    start = diff.new_texts["m.tex"].index(quote)
    assert found == ("moved", "m.tex", start, start + len(quote), "exact", anchor.EXACT_CONFIDENCE)


def test_a_comment_in_a_section_whose_import_was_taken_out_is_gone_there(tmp_path):
    """\\import{folder}{name} reads a file as \\input does: when the student takes it out, the file's comments are
    gone where it was (was: "unchanged", with no page), and the command prints no letters of its own."""
    main = "\\documentclass{article}\n\\begin{document}\nIntro.\n\n\\import{sections/}{method}\n\nEnd.\n" \
           "\\end{document}\n"
    files = {"main.tex": main, "sections/method.tex": "The method is described here.\n"}
    old = _tree(tmp_path / "old", files)
    new = _tree(tmp_path / "new", dict(files, **{"main.tex": main.replace("\\import{sections/}{method}\n\n", "")}))
    diff = texdiff.diff_trees(old, new)
    gone = anchor._dropped(diff, "sections/method.tex")
    assert gone[:3] == ("gone", "main.tex", diff.new_texts["main.tex"].index("Intro.") + len("Intro."))
    assert [h["kind"] for h in gone[6:]] == ["delete"]
    start = main.index("\\import")
    assert anchor._src_chars(main, start, main.index("\n", start)) == []


def test_two_rounds_of_a_file_input_in_another_case(tmp_path):
    """\\input{Sections/Intro} for sections/intro.tex (it builds on macOS): the comment is anchored by the file's name
    on disk, and in the next round the edit is a change attached to it, the comment changed, and the student's note
    on it a note (was: no change, the comment not found, and "The paper does not use sections/intro.tex")."""
    from conftest import quiet, select
    from paperole import api, ledger, prose

    def call(method, **params):
        return api.METHODS[method](dict(params, paper=str(paper)), quiet)
    intro = "Serverless platforms start a fresh sandbox for every cold invocation of a function.\n"
    main = "\\documentclass{article}\n\\begin{document}\n\\input{Sections/Intro}\n\\end{document}\n"
    v1 = _tree(tmp_path / "v1", {"main.tex": main, "sections/intro.tex": intro})
    v2 = _tree(tmp_path / "v2", {"main.tex": main, "sections/intro.tex": intro.replace(
        "fresh sandbox", "new sandbox").rstrip() + " % R1-01 changed the word\n"})
    paper = tmp_path / "paper"
    call("new", title="T", student="S")
    call("ingest", source=str(v1))
    pdf = str(paper / "r1" / "build" / "main.pdf")
    phrase = "start a fresh sandbox"
    state = call("comment", page=0, rects=select(pdf, 0, phrase), text=phrase, note="Which sandbox?",
                 kind="highlight")["state"]
    assert ledger.load(paper)["comments"][0]["rounds"]["1"]["anchor"]["file"] == "sections/intro.tex"
    assert state["comments"][0]["paragraph"] is not None  # the paragraphs name the file as on disk too
    call("finish")
    state = call("ingest", source=str(v2))["state"]
    (c,) = state["comments"]
    assert (c["anchor_state"], c["file"]) == ("changed", "sections/intro.tex") and c["paragraph"] is not None
    assert list(prose.load(paper, 2)["changes"]) == ["c01"]  # the edit marks its paragraph
    assert [(ch["file"], ch["old_text"], ch["new_text"], ch["attached_to"]) for ch in state["changes"]] == \
        [("sections/intro.tex", "fresh", "new", ["R1-01"])]
    assert state["note_warnings"] == [] and c["student_note"]["text"] == "changed the word"
