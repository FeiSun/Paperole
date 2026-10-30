"""The read-only overview (CONTRACT.md amendment "Overview"; design/overview/v2/OVERVIEW-v2.md §5) on synthetic papers:
sections matched across rounds by their paragraphs (a merge, a renamed section, a split, a moved, a removed and an
added section), spans in page units against the PDF, comments' paths (placed, gone, unplaced), edits and their words,
floats counted where they are printed, two-column places, stale, missing and failed paragraphs, round.received,
edit_paper, the students' numbers, RPC and CLI, and the time it takes."""
import datetime
import json
import os
import random
import shutil
import subprocess
import sys
import time
import zipfile

import pymupdf
import pytest

from conftest import quiet, select
from paperole import EngineError, api, cli, ledger, overview, project, prose

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

PREAMBLE = "\\documentclass{article}\n\\hyphenpenalty=10000\n\\exhyphenpenalty=10000\n\\sloppy\n"
VOCAB = ("rafts kelp carbon shelf break drift currents winter summer stations samples coast estimate survey biomass "
         "density velocity transport export depth canyon storm season mooring sensor tide wave flux sediment burial "
         "plume eddy front gradient salinity nitrate grazing holdfast frond blade canopy").split()


def para(tag, edit=None):
    """A paragraph of four sentences of its own (seeded by tag), starting with its tag; edit: (sentence, word index,
    new word) puts one word in."""
    rng = random.Random(tag)
    sentences = []
    for i in range(4):
        words = [rng.choice(VOCAB) for _ in range(rng.randint(10, 14))]
        if edit and edit[0] == i:
            words[edit[1]] = edit[2]
        sentences.append(" ".join(words) + ".")
    return tag.capitalize() + " " + " ".join(sentences)


def source(root, sections, appendix=None, edits=None):
    """A source folder: main.tex with the abstract and the sections [(title, [tags])], and the appendix sections in
    extra.tex read by \\input after \\appendix."""
    edits = edits or {}
    root.mkdir(parents=True)

    def body(secs):
        return "".join("\\section{{{}}}\n\n{}\n\n".format(t, "\n\n".join(para(g, edits.get(g)) for g in tags))
                       for t, tags in secs)
    tail = "\\appendix\n\\input{extra}\n" if appendix else ""
    (root / "main.tex").write_text(PREAMBLE + "\\title{Drifting kelp rafts}\n\\begin{document}\n\\maketitle\n"
                                   "\\begin{abstract}\n" + para("abstractum") + "\n\\end{abstract}\n\n" + body(sections)
                                   + tail + "\\end{document}\n")
    if appendix:
        (root / "extra.tex").write_text(body(appendix))
    return root


V1 = [("Introduction", ["intro", "invite"]), ("Related work", ["relate", "recall"]),
      ("Study area", ["sand", "shore", "slope", "surf"]), ("Methods", ["method", "measure", "model", "mesh", "metric"]),
      ("Results", ["xenon", "xylem", "xray", "xerus", "xeric", "xyst"]), ("Discussion", ["debate", "detail"])]
APPENDIX = [("Extra", ["extra", "excess"])]
V2 = [s for s in V1 if s[0] != "Study area"]
V2[2] = ("Methods", ["sand", "shore", "slope", "surf"] + V2[2][1])  # Study area merged into Methods
V3 = [("Materials and methods", tags) if t == "Methods" else (t, tags) for t, tags in V2]  # renamed
V3[3:4] = [("Results", ["xenon", "xylem", "xray"]), ("Analysis", ["xerus", "xeric", "xyst"])]  # split
V4 = [V3[0], V3[2], V3[3], V3[4], V3[1], V3[5], ("Conclusion", ["close"])]  # Related work moved, Conclusion added


def find(pdf, phrase):
    """(page, rects) of a phrase in a PDF."""
    doc = pymupdf.open(pdf)
    for page in range(doc.page_count):
        try:
            return page, select(pdf, page, phrase)
        except AssertionError:
            continue
    raise AssertionError("not in the PDF: " + phrase)


def comment(paper, phrase, note):
    n = ledger.open_round(ledger.load(paper))["n"]
    pdf = paper / "r{}".format(n) / "build" / "main.pdf"
    page, rects = find(pdf, phrase)
    return api.comment({"paper": str(paper), "page": page, "rects": rects, "text": phrase, "note": note,
                        "kind": "highlight"}, quiet)["id"]


def verdict(paper, cid, v, note=""):
    api.verdict({"paper": str(paper), "id": cid, "verdict": v, "note": note}, quiet)


def first_words(tag, k=4):
    return " ".join(para(tag).split()[:k])


@pytest.fixture(scope="module")
def kelp(tmp_path_factory):
    """A paper over four rounds: Study area merged into Methods (round 2), Methods renamed and Results split (round 3),
    Related work moved, the appendix removed and a Conclusion added (round 4, open); comments that follow them."""
    root = tmp_path_factory.mktemp("kelp")
    paper = root / "paper"
    src = [source(root / "v1", V1, APPENDIX),
           source(root / "v2", V2, APPENDIX, {"intro": (0, 2, "lagoon"), "debate": (1, 3, "harbor")}),
           source(root / "v3", V3, APPENDIX),
           source(root / "v4", V4)]
    api.new({"paper": str(paper), "title": "Kelp drift", "student": "Mei Lin"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src[0])}, quiet)
    ids = {"intro": comment(paper, first_words("intro"), "Shorter."),
           "shore": comment(paper, first_words("shore"), "Which beach?"),
           "xerus": comment(paper, first_words("xerus"), "Say what the trend shows."),
           "extra": comment(paper, first_words("extra"), "Needed?")}
    api.finish({"paper": str(paper)}, quiet)
    api.ingest({"paper": str(paper), "source": str(src[1])}, quiet)
    verdict(paper, ids["intro"], "verified")
    verdict(paper, ids["xerus"], "reopened", "Say more.")
    ids["mesh"] = comment(paper, first_words("mesh"), "Grid size?")
    api.finish({"paper": str(paper)}, quiet)
    api.ingest({"paper": str(paper), "source": str(src[2])}, quiet)
    verdict(paper, ids["shore"], "wontfix")
    verdict(paper, ids["xerus"], "verified")
    api.finish({"paper": str(paper)}, quiet)
    api.ingest({"paper": str(paper), "source": str(src[3])}, quiet)
    return paper, ids


def view(paper, **kw):
    return overview.paper_overview(paper, **kw)


def same(ov):
    """An overview without the folder's paths."""
    return [{k: v for k, v in r.items() if k not in ("pdf", "final_pdf", "email")} for r in ov["rounds"]], \
        ov["comments"], ov["sections"], ov["threads"]


def rnd(ov, n):
    return next(r for r in ov["rounds"] if r["n"] == n)


def test_sections_are_matched_by_their_paragraphs(kelp):
    paper, _ = kelp
    ov = view(paper)
    keys = {r["n"]: [s[0] for s in r["spans"]] for r in ov["rounds"]}
    assert keys == {1: ["front", "introduction", "related-work", "study-area", "methods", "results", "discussion",
                        "extra"],
                    2: ["front", "introduction", "related-work", "methods", "results", "discussion", "extra"],
                    3: ["front", "introduction", "related-work", "methods", "results", "analysis", "discussion",
                        "extra"],
                    4: ["front", "introduction", "methods", "results", "analysis", "related-work", "discussion",
                        "conclusion"]}
    titles = {s[0]: s[1] for s in rnd(ov, 3)["spans"]}
    assert titles["methods"] == "3 Materials and methods" and titles["front"] == "Title and abstract"
    assert rnd(ov, 1)["match"] is None
    m2 = {(m[0], m[1]): m[2:] for m in rnd(ov, 2)["match"]}
    assert m2[("study-area", "methods")] == ["merged", 4, 4]  # 4 of its 4 paragraphs now sit in Methods
    assert m2[("methods", "methods")] == ["same", 5, 5]
    assert m2[("front", "front")] == ["same", 1, 1] and m2[("extra", "extra")] == ["same", 2, 2]
    m3 = {(m[0], m[1]): m[2:] for m in rnd(ov, 3)["match"]}
    assert m3[("methods", "methods")] == ["renamed", 9, 9]
    assert m3[("results", "results")] == ["split", 3, 6] and m3[("results", "analysis")] == ["split", 3, 6]
    assert sum(1 for m in rnd(ov, 3)["match"] if m[1] == "analysis") == 1  # no "added" for a split's other half
    m4 = {(m[0], m[1]): m[2:] for m in rnd(ov, 4)["match"]}
    assert m4[("related-work", "related-work")] == ["moved", 2, 2]
    assert m4[("extra", None)] == ["removed", 0, 2] and m4[(None, "conclusion")] == ["added", 0, 1]
    assert all(m4[(k, k)][0] == "same" for k in ("front", "introduction", "methods", "results", "analysis",
                                                  "discussion"))
    for r in ov["rounds"][1:]:  # every section of both rounds is in the match
        assert {m[0] for m in r["match"] if m[0]} == set(keys[r["n"] - 1])
        assert {m[1] for m in r["match"] if m[1]} == set(keys[r["n"]])
    sections = {s["key"]: s for s in ov["sections"]}
    assert (sections["study-area"]["last"], sections["study-area"]["gone"]) == (1, True)
    assert (sections["methods"]["title"], sections["methods"]["first"], sections["methods"]["gone"]) == \
        ("2 Materials and methods", 1, False)  # its latest title
    assert sections["extra"]["gone"] and sections["conclusion"]["first"] == 4
    assert {k: sections[k]["suggested_bucket"] for k in ("front", "introduction", "related-work", "study-area",
                                                          "methods", "results", "analysis", "discussion",
                                                          "conclusion", "extra")} == \
        {"front": "abstract", "introduction": "introduction", "related-work": "introduction",
         "study-area": "method", "methods": "method", "results": "results", "analysis": "results",
         "discussion": "discussion", "conclusion": "conclusion", "extra": None}  # an appendix: no suggestion


def test_spans_are_where_the_headings_are_printed(kelp):
    paper, _ = kelp
    ov = view(paper)
    for r in ov["rounds"]:
        doc = pymupdf.open(r["pdf"])
        spans = r["spans"]
        assert spans[0][2] == 0 and all(a[3] == b[2] for a, b in zip(spans, spans[1:]))  # they tile the pages
        assert all(s[2] <= s[3] for s in spans) and spans[-1][3] <= r["build"]["pages"]
        for key, title, start, end, _ in spans[1:]:
            name = title.split(" ", 1)[1]
            page = next(p for p in range(doc.page_count) if doc[p].search_for(title.split(" ", 1)[0] + " " + name)
                        or doc[p].search_for(name))
            assert int(start) == page, (r["n"], title)
        # each paragraph's comment is in the section its paragraph is in (one column, no floats here)
    path = {c["id"]: c["path"] for c in ov["comments"]}
    assert [e[4] for e in path["R1-02"]] == ["study-area", "methods", "methods"]  # merged, then renamed
    assert [e[4] for e in path["R1-03"]] == ["results", "results", "analysis"]  # split off
    assert [e[4] for e in path["R1-01"]] == ["introduction", "introduction"]
    for c in ov["comments"]:
        for n, st, page, pos, key, response, answer in c["path"]:
            if st == "placed":
                assert int(pos) == page and next(s for s in rnd(ov, n)["spans"] if s[0] == key)[2] <= pos


def test_comment_paths_and_counts(kelp):
    paper, ids = kelp
    ov = view(paper)
    path = {c["id"]: [e[:2] + e[5:] for e in c["path"]] for c in ov["comments"]}
    assert path[ids["intro"]] == [[1, "placed", "new", None], [2, "placed", "edited", "resolved"]]
    assert path[ids["shore"]] == [[1, "placed", "new", None], [2, "placed", "untouched", "left_open"],
                                  [3, "placed", "waiting", "kept"]]
    assert path[ids["xerus"]] == [[1, "placed", "new", None], [2, "placed", "untouched", "follow_up"],
                                  [3, "placed", "untouched", "resolved"]]
    assert path[ids["extra"]][-1] == [4, "gone", "edited", "to_check"]  # its appendix was taken out
    assert path[ids["mesh"]] == [[2, "placed", "new", None], [3, "placed", "untouched", "left_open"],
                                 [4, "placed", "waiting", "to_check"]]
    gone = next(c for c in ov["comments"] if c["id"] == ids["extra"])["path"][-1]
    assert gone[2] is not None and gone[3] is not None and gone[4] in ("discussion", "conclusion")
    c = {r["n"]: r["comments"] for r in ov["rounds"]}
    assert (c[2]["new"], c[2]["carried"], c[2]["edited"], c[2]["untouched"], c[2]["waiting"]) == (1, 4, 1, 3, 0)
    assert (c[2]["resolved"], c[2]["follow_up"], c[2]["left_open"], c[2]["open_after"]) == (1, 1, 2, 4)
    assert (c[3]["carried"], c[3]["waiting"], c[3]["untouched"], c[3]["resolved"], c[3]["kept"]) == (4, 2, 2, 1, 1)
    assert (c[4]["carried"], c[4]["edited"], c[4]["waiting"], c[4]["to_check"]) == (2, 1, 1, 2)
    for r, prev in zip(ov["rounds"][1:], ov["rounds"]):
        k = r["comments"]
        assert k["carried"] == prev["comments"]["open_after"]
        assert k["edited"] + k["note_only"] + k["untouched"] + k["waiting"] == k["carried"]
    for r in ov["rounds"]:
        assert sum(h[1] + h[2] for h in r["heat"]) + r["unplaced"] == r["comments"]["new"] + r["comments"]["carried"]
        assert sum(h[3] for h in r["heat"]) == r["comments"]["to_check"]
    heat4 = {h[0]: h for h in rnd(ov, 4)["heat"]}
    assert heat4["methods"][1:4] == [0, 1, 1]  # R2-01, carried and to check
    assert ov["threads"] == {"comments": 5, "resolved": 2, "kept": 1, "open": 2, "followed_up": 1,
                             "untouched_after_follow_up": 1, "revived": 0, "closed_after": {"1": 2, "2": 1, "3+": 0}}
    assert ov["summary"]["round"] == 4 and ov["paper"]["student"] == "Mei Lin" and ov["pending"] == []
    assert sorted(s["key"] for s in ov["sections"] if s["written"]) == ["extra", "introduction", "methods",
                                                                        "results", "study-area"]
    assert {s["key"]: s["comments"] for s in ov["sections"]}["methods"] == 2  # R1-02 and R2-01, once each
    # where each was written, under the heading it had then: R2-01 under "Methods", renamed in Round 3
    written_as = {s["key"]: s["written_as"] for s in ov["sections"]}
    assert written_as["methods"] == [{"name": "Methods", "number": "3", "written": 1}]
    assert all(sum(w["written"] for w in s["written_as"]) == s["written"] for s in ov["sections"])


def test_edits_and_words(kelp):
    paper, ids = kelp
    ov = view(paper, marks=True)
    r2 = rnd(ov, 2)
    by = {e[0]: e for e in r2["edits"]}
    asked = [e for e in r2["edits"] if e[4] == [ids["intro"]]]
    assert len(asked) == 1 and asked[0][3] == "introduction" and asked[0][5] is False
    assert (asked[0][8], asked[0][9]) == (1, 1)  # one word for one
    unasked = [e for e in r2["edits"] if e[5] and e[3] == "discussion"]
    assert len(unasked) == 1 and (unasked[0][8], unasked[0][9]) == (1, 1) and unasked[0][6] is False  # closed round
    assert r2["words"]["added"] == sum(e[8] for e in r2["edits"]) and r2["words"]["deleted"] >= 2
    assert all(isinstance(r2["excerpts"][cid], str) and r2["excerpts"][cid] for cid in by)
    assert r2["changes"]["total"] == len(r2["edits"]) and r2["changes"]["requested"] == 1
    r4 = rnd(ov, 4)
    moves = [e for e in r4["edits"] if e[7]]
    assert moves and all(e[8] == e[9] == 0 for e in moves)  # a move prints no words
    assert any(e[6] for e in moves) and r4["changes"]["to_check"] == sum(1 for e in r4["edits"] if e[6])
    assert r4["changes"]["to_check"] == ov["summary"]["to_check"]
    added = [e for e in r4["edits"] if e[3] == "conclusion"]
    assert added and sum(e[8] for e in added) >= 40  # the new Conclusion's words
    assert {h[0]: h for h in r4["heat"]}["conclusion"][4:6] == [len(added), sum(e[8] for e in added)]
    assert r4["marks"] and {m[1] for m in r4["marks"]} == {"comment", "change"}
    # each mark names its comment or change (the app colours and follows the marks on its thumbnails)
    placed = {c["id"] for c in ov["comments"] if any(s[0] == 4 and s[1] == "placed" for s in c["path"])}
    gone = {c["id"] for c in ov["comments"] if any(s[0] == 4 and s[1] == "gone" for s in c["path"])}
    assert placed <= {m[6] for m in r4["marks"] if m[1] == "comment"} <= placed | gone  # gone: at its deletion point
    assert {m[6] for m in r4["marks"] if m[1] == "change"} <= {e[0] for e in r4["edits"]}
    assert r4["pages"][0]["comments"] + r4["pages"][0]["changes"] >= \
        max(p["comments"] + p["changes"] for p in r4["pages"])


def test_an_excerpt_from_source_text_has_no_latex():
    # an edit that prints no words falls back to its source text: its words, without commands, braces or comments
    ex = overview._excerpt
    assert ex({"new_text": r"\noindent \textbf{Warm-up Strategy.} We adopt two warm-up strategies"}) == \
        "Warm-up Strategy. We adopt two warm-up strategies"
    assert ex({"new_text": r"\section{Conclusion} Close holdfast~drift"}) == "Conclusion Close holdfast drift"
    assert ex({"old_text": "50\\% of the data % a note to self\n\\begin{table}[t] \\caption{Rates}"}) == "50% of the data Rates"
    assert ex({"new_text": r"\begin{figure*}[h!]"}) == r"\begin{figure*}[h!]"  # no words at all: as written
    assert ex({"about": {"text": r"added \input{appendix}"}, "new_text": r"\input{appendix}"}) == r"added \input{appendix}"
    assert len(ex({"new_text": "word " * 40})) == 60


def test_a_float_counts_where_it_is_printed_and_two_columns(tmp_path):
    """A figure* written in Alpha is printed at the top of page 2, inside Beta: a comment on its caption counts in
    Beta. Beta's heading is in the right column of page 1, so its span starts in the second half of page 0."""
    body = ("\\section{Alpha}\n\n" + para("alpha") + "\n\n\\begin{figure*}\\centering\\fbox{\\rule{0pt}{3cm}"
            "\\rule{8cm}{0pt}}\\caption{Wide figure of drifting rafts.}\\end{figure*}\n\n" +
            "\n\n".join(para(t) for t in ("amber", "agate", "aster", "azure", "acorn", "adobe", "aloe", "alder")) +
            "\n\n\\section{Beta}\n\n" +
            "\n\n".join(para(t) for t in ("basalt", "beryl", "birch", "bison", "blaze", "bloom", "bluff", "brine",
                                          "brook", "brush", "bugle", "burro")))
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text("\\documentclass[twocolumn]{article}\n\\hyphenpenalty=10000\n\\sloppy\n"
                                  "\\begin{document}\n" + body + "\n\\end{document}\n")
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "Two columns", "student": "Ana Sousa"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    pdf = paper / "r1" / "build" / "main.pdf"
    cap = comment(paper, "Wide figure of drifting rafts.", "Units?")
    right = comment(paper, first_words("brook"), "Which brook?")
    ov = view(paper)
    r = rnd(ov, 1)
    doc = pymupdf.open(pdf)
    beta_page = next(p for p in range(doc.page_count) if doc[p].search_for("2 Beta"))
    beta = doc[beta_page].search_for("2 Beta")[0]
    gap = ledger.load(paper)["rounds"][0]["build"]["columns"][beta_page]
    assert gap and beta.x0 > gap[0]  # the heading is in the right column
    spans = {s[0]: s for s in r["spans"]}
    assert beta_page <= spans["beta"][2] < beta_page + 1 and spans["beta"][2] - beta_page >= 0.5
    path = {c["id"]: c["path"][0] for c in ov["comments"]}
    page, pos, key = path[cap][2:5]
    assert page > beta_page and key == "beta"  # printed in Beta, written in Alpha
    data = prose.load(paper, 1)
    k = prose.block_of(data, ledger.get_comment(ledger.load(paper), cap)["rounds"]["1"]["anchor"])
    assert data["blocks"][k]["kind"] == "figure" and data["blocks"][data["blocks"][k]["section"]]["text"] == "Alpha"
    assert pos - page < 0.5  # across both columns at the top of the page: the left half
    rpage, rpos = path[right][2:4]
    rr = ledger.get_comment(ledger.load(paper), right)["rounds"]["1"]["anchor"]["rects"][0]
    gap = ledger.load(paper)["rounds"][0]["build"]["columns"][rpage]
    assert (rpos - rpage >= 0.5) == (rr[0] >= gap[0] - 3)  # the right column is the second half of its page
    assert overview.suggested_bucket("Beta") is None and spans["alpha"][3] == spans["beta"][2]


def test_unplaced_and_gone_without_a_place(kelp, tmp_path):
    paper = tmp_path / "paper"
    shutil.copytree(kelp[0], paper)
    with ledger.edit(paper) as lg:  # as carry leaves a comment it cannot find (anchor.carry: orphan)
        rec = ledger.get_comment(lg, "R2-01")["rounds"]["4"]
        rec.update(anchor=None, anchor_state="orphan", method="none", confidence=0)
        gone = ledger.get_comment(lg, "R1-04")["rounds"]["4"]
        gone["anchor"].update(page=None, rects=[])  # a deletion point the PDF does not show
    a4 = json.loads((paper / "r4" / "analysis.json").read_text())
    for ch in a4["changes"]:
        if "R1-04" in ch["attached_to"]:
            ch["page"], ch["rects"] = None, []
    (paper / "r4" / "analysis.json").write_text(json.dumps(a4))
    ov = view(paper)
    r4 = rnd(ov, 4)
    path = {c["id"]: c["path"][-1] for c in ov["comments"]}
    assert path["R2-01"] == [4, "unplaced", None, None, None, "waiting", "to_check"]
    assert r4["unplaced"] == 1 and r4["comments"]["not_found"] == 1
    assert sum(h[1] + h[2] for h in r4["heat"]) + 1 == r4["comments"]["carried"]
    # no place for the deletion point: the end of the nearest section before its own (the appendix, gone) still
    # there
    st, page, pos, key = path["R1-04"][1:5]
    span = next(s for s in r4["spans"] if s[0] == key)
    assert (st, page, key) == ("gone", None, "discussion") and span[2] <= pos < span[3]


def test_stale_missing_and_failed_paragraphs(kelp, tmp_path):
    paper = tmp_path / "paper"
    shutil.copytree(kelp[0], paper)
    p3 = prose.path(paper, 3)
    data = json.loads(p3.read_text())
    data["parser"] = prose.PARSER - 1
    p3.write_text(json.dumps(data))
    (prose.path(paper, 4)).unlink()
    ov = view(paper)
    assert ov["pending"] == [3, 4] and [r["prose"] for r in ov["rounds"]] == ["ok", "ok", "pending", "pending"]
    r3 = rnd(ov, 3)
    assert r3["spans"] is r3["match"] is r3["heat"] is r3["words"] is None
    assert all(e[3] is None and e[8] is None for e in r3["edits"])
    placed = [e for c in ov["comments"] for e in c["path"] if e[0] == 3]
    assert placed and all(e[2] is not None and e[3] is not None and e[4] is None for e in placed)  # pages only
    assert r3["comments"]["carried"] == 4  # the numbers come from the ledger
    # the second engine process fills them in (closed rounds), without a state
    out = api.prose_({"paper": str(paper), "round": 3, "state": False}, quiet)
    assert set(out) == {"path"} and prose.load(paper, 3) is not None
    ov = view(paper)
    assert ov["pending"] == [4] and rnd(ov, 3)["match"] is not None
    api.prose_({"paper": str(paper), "round": 4, "state": False}, quiet)
    assert view(paper)["pending"] == [] and same(view(paper)) == same(view(kelp[0]))
    # finding the paragraphs failed: "unavailable" until a build succeeds
    prose.path(paper, 4).unlink()
    main = paper / "r4" / "src" / "main.tex"
    os.chmod(main, 0o644)
    text = main.read_text()
    main.unlink()
    with pytest.raises(Exception):
        api.prose_({"paper": str(paper), "round": 4, "state": False}, quiet)
    assert prose.failed(paper, 4) and rnd(view(paper), 4)["prose"] == "unavailable" and view(paper)["pending"] == []
    main.write_text(text)
    api.prose_({"paper": str(paper), "round": 4, "state": False}, quiet)
    assert not prose.failure_path(paper, 4).exists() and rnd(view(paper), 4)["prose"] == "ok"
    with ledger.edit(paper) as lg:  # a failed build has no paragraphs to find
        lg["rounds"][3]["build"].update(status="failed", pdf=None)
    assert rnd(view(paper), 4)["prose"] == "unavailable"


def test_round_received(tmp_path):
    src = source(tmp_path / "src", [("Introduction", ["intro"])])
    when = datetime.datetime(2026, 10, 1, 12, 30, 0).timestamp()
    os.utime(src / "main.tex", (when, when))
    for name in ("main.log", ".DS_Store"):  # a build product and a dot-file are not the student's text
        (src / name).write_text("x")
    assert project.received(src) == datetime.datetime.fromtimestamp(when).astimezone().isoformat(timespec="seconds")
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "T", "student": "S"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    expected = datetime.datetime.fromtimestamp(when).astimezone().isoformat(timespec="seconds")
    assert ledger.load(paper)["rounds"][0]["received"] == expected
    assert rnd(view(paper), 1)["received"] == expected
    zpath = tmp_path / "src.zip"
    with zipfile.ZipFile(zpath, "w") as z:
        z.writestr(zipfile.ZipInfo("paper/main.tex", (2026, 9, 30, 8, 15, 0)), "x")
        z.writestr(zipfile.ZipInfo("paper/main.aux", (2026, 10, 9, 8, 15, 0)), "x")
    assert project.received(zpath) == datetime.datetime(2026, 9, 30, 8, 15).astimezone().isoformat(timespec="seconds")
    assert project.received(tmp_path / "nothing") is None
    with ledger.edit(paper) as lg:  # a round ingested before received was recorded
        del lg["rounds"][0]["received"]
    assert rnd(view(paper), 1)["received"] is None


def test_edit_paper_and_students(kelp, tmp_path, capsys):
    a, b = tmp_path / "a", tmp_path / "b"
    shutil.copytree(kelp[0], a)
    shutil.copytree(kelp[0], b)
    st = api.edit_paper({"paper": str(b), "student": "  mei   LIN ", "title": "Kelp  drift,\nagain"}, quiet)["state"]
    assert (st["paper"]["student"], st["paper"]["title"]) == ("mei LIN", "Kelp drift, again")
    out = overview.overview([str(a), str(b), str(tmp_path / "missing")], buckets={str(b): {"discussion": None}},
                            today=datetime.date(2026, 12, 1))
    assert "error" in out["papers"][2] and [p["overview"]["paper"]["title"] for p in out["papers"][:2]] == \
        ["Kelp drift", "Kelp drift, again"]
    [mei] = out["students"]  # one student, written two ways
    assert mei["student"] == "Mei Lin" and mei["papers"] == [str(a), str(b)] and mei["comments"] == 10
    land = mei["land"]
    assert [c["bucket"] for c in land["columns"]][:6] == ["abstract", "introduction", "method", "results",
                                                         "discussion", "conclusion"]
    assert land["columns"][2]["title"] == "Methods"
    assert land["columns"][-1] == {"bucket": None, "title": "Extra"}  # an appendix keeps its own name
    row = dict(zip([c["title"] for c in land["columns"]], land["papers"][0]["counts"]))
    assert (row["Introduction"], row["Methods"], row["Results"], row["Extra"]) == (1, 2, 1, 1)
    assert land["total"] == [x + y for x, y in zip(land["papers"][0]["counts"], land["papers"][1]["counts"])]
    assert mei["closed"]["total"] == {"1": 4, "2": 2, "3+": 0, "open": 4, "followed_up": 2,
                                      "untouched_after_follow_up": 2, "revived": 0}
    trips = [t for t in mei["time"] if t["path"] == str(a)]
    assert [(t["round"], t["next"], t["open"]) for t in trips] == [(1, 2, False), (2, 3, False), (3, 3 + 1, False),
                                                                  (4, None, True)]
    assert all(t["you"] >= 0 and (t["open"] or t["student"] >= 0) for t in trips)
    assert trips[-1]["you"] == (datetime.date(2026, 12, 1) -
                                datetime.datetime.fromisoformat(rnd(view(a), 4)["created"]).date()).days
    api.edit_paper({"paper": str(b), "student": "Ana Sousa"}, quiet)
    assert [s["student"] for s in overview.overview([str(a), str(b)])["students"]] == ["Mei Lin", "Ana Sousa"]
    # the sidebar groups the papers by student from summaries, which name each paper's title and student
    assert [(p["paper"]["title"], p["paper"]["student"]) for p in api.summaries({"papers": [str(a), str(b)]},
                                                                                quiet)["papers"]] == \
        [("Kelp drift", "Mei Lin"), ("Kelp drift, again", "Ana Sousa")]
    with pytest.raises(EngineError, match="cannot be empty"):
        api.edit_paper({"paper": str(b), "student": "  "}, quiet)
    with pytest.raises(EngineError, match="Give the paper's title or the student's name."):
        api.edit_paper({"paper": str(b)}, quiet)
    assert cli.main(["edit-paper", str(b), "--title", "Kelp, third"]) == 0
    assert json.loads(capsys.readouterr().out)["state"]["paper"]["title"] == "Kelp, third"
    assert cli.main(["overview", str(a)]) == 0
    printed = json.loads(capsys.readouterr().out)
    assert printed["papers"][0]["overview"]["rounds"][3]["n"] == 4 and "state" not in printed


def test_rpc_and_time(kelp):
    """overview over RPC: no state, and well within a second for a four-round paper in a new engine process."""
    paper, _ = kelp
    proc = subprocess.Popen([sys.executable, "-m", "paperole.cli", "rpc"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
    proc.stdin.write(json.dumps({"id": -1, "method": "summaries", "params": {"papers": [str(paper)]}}) + "\n")
    proc.stdin.flush()
    json.loads(proc.stdout.readline())  # the engine has started
    times = []
    for i in range(2):
        start = time.perf_counter()
        proc.stdin.write(json.dumps({"id": i, "method": "overview", "params": {"papers": [str(paper)]}}) + "\n")
        proc.stdin.flush()
        reply = json.loads(proc.stdout.readline())
        times.append(time.perf_counter() - start)
        assert set(reply["result"]) == {"papers", "students"} and "state" not in reply["result"]
    proc.stdin.write(json.dumps({"id": 9, "method": "overview", "params": {"papers": "x"}}) + "\n")
    proc.stdin.flush()
    assert json.loads(proc.stdout.readline())["error"]["message"] == "papers is a list of paper folders."
    proc.stdin.close()
    assert proc.wait(timeout=30) == 0
    print("overview of a 4-round paper: {:.3f} s first, {:.3f} s again".format(*times))
    assert times[0] < 1.0 and times[1] < 0.1
    start = time.perf_counter()
    for _ in range(10):
        view(paper)
    assert (time.perf_counter() - start) / 10 < 0.05  # in a running process, per paper


def test_previous_maps_each_block_of_the_round_before(tmp_path):
    """prose._previous (no TeX): a paragraph too short for texdiff to see it move is found by its hash, two paragraphs
    with the same text by the diff (each where it is), an edited one by the diff, a deleted one nowhere; deleted
    blocks of the round before map to nothing."""
    from test_prose import read_blocks
    from paperole import texdiff
    short = "Kelp floats."
    twin = "Twin text that appears twice in the paper, word for word."
    old = ("\\begin{document}\n\\section{One}\n\n" + short + "\n\n" + twin + "\n\n" + para("edited") + "\n\n"
           + para("doomed") + "\n\n\\section{Two}\n\n" + twin + "\n\n" + para("stay") + "\n\\end{document}\n")
    new = ("\\begin{document}\n\\section{One}\n\n" + twin + "\n\n" + para("edited", (1, 2, "lagoon")) + "\n\n"
           "\\section{Two}\n\n" + twin + "\n\n" + para("stay") + "\n\n" + short + "\n\\end{document}\n")
    for name, text in (("old", old), ("new", new)):
        (tmp_path / name).mkdir()
        (tmp_path / name / "main.tex").write_text(text)
    o, n_ = read_blocks(tmp_path / "old", tmp_path), read_blocks(tmp_path / "new", tmp_path)
    diff = texdiff.diff_trees(tmp_path / "old", tmp_path / "new")
    blocks, _ = prose._diff_marks(n_, o, diff, [None] * len(diff.hunks), 2)
    prose._sections(blocks)
    prev = prose._previous(blocks, o, diff)
    where = {o[j]["text"][:12]: (blocks[k]["text"][:12] if k is not None else None) for j, k in enumerate(prev)}
    assert where[short] == short  # moved into Two, found by its hash
    assert [blocks[prev[j]]["section"] for j, b in enumerate(o) if b["text"] == twin] == \
        [blocks.index(next(b for b in blocks if b["text"] == "One")), blocks.index(next(b for b in blocks if
                                                                                         b["text"] == "Two"))]
    assert where[para("edited")[:12]] == para("edited")[:12] and where[para("doomed")[:12]] is None
    assert where["One"] == "One" and where["Two"] == "Two"
    deleted = [k for k, b in enumerate(blocks) if b["kind"] == "deleted"]
    assert deleted and prose._previous(blocks, blocks, diff)[deleted[0]] is None  # a deleted block maps nowhere


def test_a_listing_that_runs_on_ends_the_row(tmp_path):
    """A listing's place is the box on its first page: the pages it runs on to still belong to its section, the last
    one (an ICLR paper's appendix prompt, on the copies)."""
    lines = "\n".join("step {} of the prompt: read the draft and list each claim".format(k) for k in range(130))
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text(PREAMBLE + "\\begin{document}\n\\section{Intro}\n\n" + para("intro") +
                                  "\n\n\\section{Prompt}\n\n" + para("prompt") + "\n\n\\begin{verbatim}\n" + lines +
                                  "\n\\end{verbatim}\n\\end{document}\n")
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "T", "student": "S"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    r = rnd(view(paper), 1)
    data = prose.load(paper, 1)
    code = next(b for b in data["blocks"] if b["kind"] == "code")
    assert r["build"]["pages"] >= 3 and code["parts"][-1][0] < r["build"]["pages"] - 1
    assert r["spans"][-1][:1] == ["prompt"] and r["spans"][-1][3] == r["build"]["pages"]


def test_a_section_whose_paragraphs_are_all_gone_is_removed_not_merged():
    """_match without TeX (review 2026-10-19): Discussion's paragraphs were all rewritten and its heading became a
    subheading of Results, which continues Results: removed (OVERVIEW-v2 §5.3), not "merged with 0 kept". A heading-only
    section that goes there is still merged, and one whose heading continues it alone still follows it."""
    def sec(block, name, content):
        return {"block": block, "name": name, "content": content}
    # Round 1: Results (r1), Discussion (d1, d2), Notes (a heading only), Summary (s1)
    old = {"sections": [sec(-1, "Title and abstract", []), sec(0, "Results", [1]), sec(2, "Discussion", [3, 4]),
                        sec(5, "Notes", []), sec(6, "Summary", [7])], "nblocks": 8}
    # Round 2: Results holds r1 and both headings, Discussion's paragraphs are new; Summary keeps its heading, its
    # paragraph rewritten
    new = {"sections": [sec(-1, "Title and abstract", []), sec(0, "Results", [1, 3, 4]), sec(5, "Summary", [6])],
           "sec_of": [1, 1, 1, 1, 1, 2, 2], "previous": [0, 1, 2, None, None, 2, 5, None]}
    entries, primary = overview._match(old, new, lambda i, j: 0)
    kinds = {e[0]: (e[1], e[2], e[3], e[4]) for e in entries if e[0] is not None}
    assert kinds[1] == (1, "same", 1, 1)
    assert kinds[2] == (None, "removed", 0, 2)
    assert kinds[3] == (1, "merged", 0, 0)
    assert kinds[4] == (2, "same", 0, 1)  # followed by its heading, alone in its section
    assert primary == {0: 0, 1: 1, 2: 4}


def _ov(student, sections, rounds, threads=None):
    """A PaperOverview with what _students reads."""
    t = threads or {"comments": 0, "resolved": 0, "kept": 0, "open": 0, "followed_up": 0,
                    "untouched_after_follow_up": 0, "closed_after": {"1": 0, "2": 0, "3+": 0}}
    return {"paper": {"title": "T", "student": student, "created": None}, "sections": sections, "rounds": rounds,
            "threads": t}


def _round(n, created, closed_at=None, status="ok", received=None):
    return {"n": n, "created": created, "closed": closed_at is not None, "closed_at": closed_at, "received": received,
            "build": {"status": status, "pages": 0 if status == "failed" else 4}}


def test_students_land_where_written_and_a_failed_last_round():
    """_students without TeX (review 2026-10-19): a comment lands under the heading it was written under, though the
    section was renamed later ("Discussion" → "Interpretation") or continues under another heading; the advisor's Map
    Headings answer still holds for the whole section; a paper without rounds has no row; a closed round before a
    failed one gets its trip, and the failed one an open row."""
    def section(key, name, written_as, bucket=None):
        return {"key": key, "title": name, "name": name, "suggested_bucket": bucket,
                "written": sum(w[2] for w in written_as),
                "written_as": [{"name": a, "number": b, "written": k} for a, b, k in written_as]}
    a = _ov("Ana Sousa", [section("front", "Title and abstract", [("Title and abstract", None, 1)], "abstract"),
                          section("discussion", "Interpretation", [("Discussion", "4", 3), ("Interpretation", "4", 1)]),
                          section("results", "Results and discussion", [("Results", "3", 2)], "discussion")],
            [_round(1, "2026-10-01T10:00:00+02:00", "2026-10-03T10:00:00+02:00"),
             _round(2, "2026-10-10T10:00:00+02:00", status="failed")])
    b = _ov("ana sousa", [section("intro", "Introduction", [("Introduction", "1", 2)], "introduction")],
            [_round(1, "2026-10-05T10:00:00+02:00")])
    empty = _ov("Ana  Sousa", [], [])
    [s] = overview._students([("/a", a), ("/b", b), ("/e", empty)], {}, datetime.date(2026, 10, 12))
    titles = [c["title"] for c in s["land"]["columns"]]
    assert titles == ["Abstract", "Introduction", "Results", "Discussion", "Interpretation"]
    assert [p["path"] for p in s["land"]["papers"]] == ["/a", "/b"]  # no row for the paper without rounds
    assert dict(zip(titles, s["land"]["papers"][0]["counts"])) == \
        {"Abstract": 1, "Introduction": 0, "Results": 2, "Discussion": 3, "Interpretation": 1}
    assert [p["path"] for p in s["closed"]["papers"]] == ["/a", "/b"]
    # the advisor put the renamed section in Discussion: all of its comments go there
    [s] = overview._students([("/a", a)], {"/a": {"discussion": "discussion"}}, datetime.date(2026, 10, 12))
    assert dict(zip([c["title"] for c in s["land"]["columns"]], s["land"]["total"]))["Discussion"] == 4
    trips = [(t["round"], t["next"], t["open"], t["you"], t["student"], t.get("failed")) for t in s["time"]]
    assert trips == [(1, 2, False, 2, 7, None), (2, None, True, 2, None, True)]


def test_digests_are_kept_per_file(tmp_path, monkeypatch):
    """More rounds than an LRU of fixed size held made every hierarchy request read every prose.json again (review
    2026-10-19); the digests are kept per file, and read again only when the file changes."""
    made = []
    real = overview._digest
    monkeypatch.setattr(overview, "_digest", lambda data, gaps: made.append(1) or real(data, gaps))
    monkeypatch.setattr(overview, "_DIGESTS", {})
    files = []
    for k in range(300):
        p = tmp_path / "p{}.json".format(k)
        p.write_text(json.dumps({"parser": prose.PARSER, "schema": prose.SCHEMA, "blocks": []}))
        files.append(p)
    for _ in range(2):
        for p in files:
            st = p.stat()
            assert overview._digest_file(str(p), st.st_mtime_ns, st.st_size, ()) is not None
    assert len(made) == 300
    files[0].write_text(json.dumps({"parser": prose.PARSER, "schema": prose.SCHEMA, "blocks": [], "x": 1}))
    st = files[0].stat()
    overview._digest_file(str(files[0]), st.st_mtime_ns, st.st_size, ())
    assert len(made) == 301


def test_key_page_and_parts(kelp, capsys):
    """The key page (TAGS.md §7): the busiest page of the latest round without a choice; the advisor's page of the
    latest round as chosen; a page of an earlier round followed through the paragraphs (Round 1's second page starts
    with Sand, which Round 4 prints on its first); spans and sections name their part (VISUAL.md §5.1)."""
    paper, _ = kelp
    ov = view(paper)
    r4 = rnd(ov, 4)
    assert ov["key_page"] == {"round": 4, "page": r4["pages"][0]["page"], "chosen": False, "followed": None}
    assert view(paper, key_page={"round": 4, "page": 1})["key_page"] == \
        {"round": 4, "page": 1, "chosen": True, "followed": None}
    assert view(paper, key_page={"round": 4, "page": 99})["key_page"]["page"] == r4["build"]["pages"] - 1
    assert find(paper / "r1" / "build" / "main.pdf", first_words("sand"))[0] == 1
    assert find(paper / "r4" / "build" / "main.pdf", first_words("sand"))[0] == 0
    assert view(paper, key_page={"round": 1, "page": 1})["key_page"] == \
        {"round": 4, "page": 0, "chosen": True, "followed": "block"}
    assert view(paper, key_page={"round": 9, "page": 2})["key_page"] == \
        {"round": 4, "page": 2, "chosen": True, "followed": "page"}
    # parts: Round 1's lettered Extra is the appendix; Round 4 has none
    assert [s[4] for s in rnd(ov, 1)["spans"]] == ["front"] + ["body"] * 6 + ["appendix"]
    assert {s[4] for s in r4["spans"][1:]} == {"body"}
    assert {s["key"]: s["part"] for s in ov["sections"]}["extra"] == "appendix"
    # RPC and CLI take the advisor's pages and tag order
    out = api.overview_({"papers": [str(paper)], "key_pages": {str(paper): {"round": 1, "page": 1}},
                         "tag_order": ["logic", "grammar"]}, quiet)
    assert out["papers"][0]["overview"]["key_page"]["followed"] == "block"
    with pytest.raises(EngineError, match="key_pages maps"):
        api.overview_({"papers": [str(paper)], "key_pages": {str(paper): {"round": "1", "page": 1}}}, quiet)
    with pytest.raises(EngineError, match="is not a tag id"):
        api.overview_({"papers": [str(paper)], "tag_order": ["Logic"]}, quiet)
    assert cli.main(["overview", str(paper), "--key-page", str(paper), "1:1", "--tag-order", "logic,grammar"]) == 0
    assert json.loads(capsys.readouterr().out)["papers"][0]["overview"]["key_page"]["page"] == 0


def test_the_key_block_is_followed_through_the_rounds():
    """_key_page without TeX: the largest figure or table on the page, else its first paragraph, followed through
    `previous`; the same page number when the block is gone, the chain is broken or the page has no block."""
    d1 = {"blocks": [("heading", 0, {}), ("paragraph", 0, {}), ("figure", 1, {1: 5000.0}), ("paragraph", 1, {}),
                     ("table", 1, {1: 8000.0}), ("paragraph", 2, {})], "nblocks": 6, "previous": None, "against": None}
    d2 = {"blocks": [("heading", 0, {}), ("table", 0, {0: 8000.0}), ("paragraph", 1, {}), ("figure", 2, {2: 5.0}),
                     ("paragraph", 2, {})], "nblocks": 5, "previous": [0, 2, 3, 4, 1, None], "against": 1}
    info = {1: {"digest": d1}, 2: {"digest": d2}}

    def r(n, pages=3, busy=(), status="ok"):
        return {"n": n, "pdf": "/x.pdf", "build": {"status": status, "pages": pages},
                "pages": [{"page": p, "comments": 1, "changes": 0} for p in busy]}
    rounds = [r(1), r(2, busy=[2, 0])]

    def key(n, page, rs=rounds):
        return overview._key_page(info, rs, {"round": n, "page": page})
    assert overview._key_page(info, rounds, None) == {"round": 2, "page": 2, "chosen": False, "followed": None}
    assert key(1, 1) == {"round": 2, "page": 0, "chosen": True, "followed": "block"}  # the table, not the figure
    assert key(1, 0) == {"round": 2, "page": 1, "chosen": True, "followed": "block"}  # its first paragraph
    assert key(1, 2) == {"round": 2, "page": 2, "chosen": True, "followed": "page"}  # its paragraph is gone
    assert key(1, 7) == {"round": 2, "page": 2, "chosen": True, "followed": "page"}  # no block: the page, kept in
    assert key(2, 1)["followed"] is None
    broken = {1: {"digest": d1}, 2: {"digest": dict(d2, against=None)}}
    assert overview._key_page(broken, rounds, {"round": 1, "page": 1})["followed"] == "page"
    # a latest round that failed: the latest that built
    assert key(1, 1, rounds + [r(3, pages=0, status="failed")])["round"] == 2
    assert overview._key_page(info, [r(1, status="failed")], None) is None


def test_parts_of_a_paper():
    def sec(name, number, content=()):
        return {"name": name, "number": number, "content": list(content)}
    blocks = [{"kind": "paragraph"}, {"kind": "bibitem"}]
    secs = [sec("Title and abstract", None), sec("Introduction", "1"), sec("Acknowledgments", None),
            sec("Bibliography", None, [1]), sec("Proofs", "A"), sec("More results", None), sec("References", None),
            sec("Extra", "B", [0])]
    overview._parts(secs, blocks)
    assert [s["part"] for s in secs] == ["front", "body", "body", "references", "appendix", "appendix", "references",
                                         "appendix"]
    secs = [sec("Title and abstract", None), sec("Results", "1"), sec("Appendix", None), sec("Data", None)]
    overview._parts(secs, blocks)
    assert [s["part"] for s in secs] == ["front", "body", "appendix", "appendix"]


def test_follow_maps_a_block_across_rounds(tmp_path):
    """prose.follow without TeX (design/pdf-reader/PLAN.md P1.1): forward through `previous`, backward to the first
    block it continues, over two rounds; None for a gone or new block, a broken chain or a missing prose.json."""
    paper = tmp_path / "paper"

    def write(n, nblocks, previous, against):
        (paper / "r{}".format(n)).mkdir(parents=True)
        data = {"schema": prose.SCHEMA, "parser": prose.PARSER, "round": n, "against": against,
                "blocks": [{"kind": "paragraph", "parts": [[0, [0, k, 1, k + 1]]]} for k in range(nblocks)],
                "changes": {}, "previous": previous}
        prose.path(paper, n).write_text(json.dumps(data))
    write(1, 4, None, None)
    write(2, 4, [0, 2, None, 1], 1)  # block 2 of round 1 is gone; block 3 of round 2 is new
    write(3, 3, [0, 1, 2, None], 2)
    assert [prose.follow(paper, 1, b, 2) for b in range(4)] == [0, 2, None, 1]
    assert [prose.follow(paper, 2, b, 1) for b in range(4)] == [0, 3, 1, None]
    assert prose.follow(paper, 1, 3, 3) == 1 and prose.follow(paper, 3, 1, 1) == 3
    assert prose.follow(paper, 1, 9, 2) is None
    prose.path(paper, 2).write_text(json.dumps(dict(json.loads(prose.path(paper, 2).read_text()), against=None)))
    assert prose.follow(paper, 1, 0, 2) is None and prose.follow(paper, 1, 0, 3) is None  # the chain is broken
    prose.path(paper, 3).unlink()
    assert prose.follow(paper, 2, 0, 3) is None


def test_follow_rpc(kelp):
    """follow over the kelp rounds: Sand's paragraph from Round 1 to Round 4 (page 1 there, page 0 here) and back;
    the Conclusion, new in Round 4, goes to the nearest block before it that Round 3 has (exact false); the same
    round is the block itself; bad numbers are refused."""
    paper, _ = kelp

    def block(n, words):
        return next(k for k, b in enumerate(prose.load(paper, n)["blocks"]) if b.get("text", "").startswith(words))
    s1, s4 = block(1, first_words("sand")), block(4, first_words("sand"))
    out = api.follow({"paper": str(paper), "round": 1, "block": s1, "to": 4}, quiet)
    assert out["round"] == 4 and out["block"] == s4 and out["exact"] and out["parts"][0][0] == 0
    assert api.follow({"paper": str(paper), "round": 4, "block": s4, "to": 1}, quiet)["block"] == s1
    new = next(k for k, b in enumerate(prose.load(paper, 4)["blocks"]) if b["kind"] == "heading" and b.get("text") == "Conclusion")
    back = api.follow({"paper": str(paper), "round": 4, "block": new, "to": 3}, quiet)
    assert back["block"] is not None and not back["exact"] and back["parts"]
    assert api.follow({"paper": str(paper), "round": 2, "block": 3, "to": 2}, quiet)["block"] == 3
    with pytest.raises(EngineError, match="no round 9"):
        api.follow({"paper": str(paper), "round": 9, "block": 0, "to": 1}, quiet)
    with pytest.raises(EngineError, match="are numbers"):
        api.follow({"paper": str(paper), "round": 1, "block": "0", "to": 2}, quiet)
