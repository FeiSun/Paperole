"""Three rounds end to end through `paperole rpc` with the real texdiff and anchor (fixtures/paper/EDITS.md).

Round 1 comments on the places v2 edits, round 2 checks the carried comments and changes and gives verdicts,
round 3 checks that only open comments were carried and that the verdict history is kept.
Set PAPEROLE_E2E_OUT to a new folder to keep the review folder (the app can open it with --paper)."""
import json
import os
import re
from pathlib import Path

import pymupdf
import pytest

from conftest import FIXTURE, TITLE, Engine, burned, history

ROUND1 = [  # id, kind, phrase in the v1 PDF, page, note, file, first line
    ("R1-01", "highlight", "simple keep-alive policy", 0, "simple 不准确，改成 static 或 fixed。", "main.tex", 41),
    ("R1-02", "highlight", "Both approaches decide when to keep a single instance alive.", 0,
     "这句不准确：Hybrid 也决定预热窗口。", "main.tex", 76),
    ("R1-03", "strikeout", "The memory footprint is two floating-point numbers per function.", 2, "多余，删掉。",
     "main.tex", 153),
    ("R1-04", "highlight", "Our simulator is event-driven", 1, "这段放到本节最后，作为局限讨论。", "main.tex", 105),
    ("R1-05", "highlight", "The expected cost of a pool of size", 1, "式 (2) 里 c_m 的单位和 τ 对不上。",
     "sections/method.tex", 27),
    ("R1-06", "highlight", "boots a minimal microVM in about 125", 0, "125 ms 出自哪里？加引用。", "main.tex", 66),
    ("R1-07", "note", "which performed best on a held-out day of the trace", 1, "只用一天调参够吗？",
     "sections/method.tex", 20)]
ROUND2_NEW = [("R2-01", "671", 2, "这个数为什么变了？重跑了还是笔误？"),
              ("R2-02", "A short-term forecast of the rate is therefore enough", 0, "enough 需要论证。"),
              ("R2-03", "Related Work", 0, "标题改成 Background and Related Work。")]
REOPEN_02, REOPEN_05, WONTFIX_07 = "还是没说清楚和 Hybrid 的区别。", "τ 应该放进 c_m 的定义，而不是式子里。", "这次先不改。"


def select(pdf, page, phrase):
    """The phrase's boxes in the PDF, one per text line, like PDFKit's selectionsByLine (EDITS.md: each phrase
    occurs once in its PDF)."""
    rects = pymupdf.open(pdf)[page].search_for(phrase)
    assert rects, phrase
    return [[round(v, 2) for v in r] for r in rects]


def by_id(state):
    return {c["id"]: c for c in state["comments"]}


def email_groups(email):
    """{group heading: [ids]} and the Closed line of an email text."""
    groups, current, closed = {}, None, None
    for line in email.splitlines():
        if re.match(r"(Follow-ups|Still open|New comments) \(\d+\)$", line):
            current = groups.setdefault(line, [])
        elif line.startswith("Closed: "):
            closed = line
        elif re.match(r"R\d+-\d+  ", line):
            current.append(line.split()[0])
    return groups, closed


def marks(pdf_path):
    """A final.pdf and {id: its entry under "Comments (k)" in the outline, e.g. "R1-02 · follow-up · p.1"}; the file has
    no annotation but the paper's links."""
    doc = pymupdf.open(pdf_path)
    assert all(a.type[1] == "Link" for page in doc for a in page.annots())
    toc = doc.get_toc()
    i = next(i for i, t in enumerate(toc) if t[1].startswith("Comments (")) + 1
    found = {}
    while i < len(toc) and toc[i][0] == 2:
        found[toc[i][1].split(" · ")[0]] = toc[i][1]
        i += 1
    return doc, found


def flat(text):
    """Text without whitespace: margin lines break inside Chinese notes."""
    return "".join(text.split())


@pytest.fixture
def paper_dir(tmp_path):
    out = os.environ.get("PAPEROLE_E2E_OUT")
    if not out:
        return tmp_path / "paper"
    if os.path.exists(out) and os.listdir(out):
        pytest.fail("PAPEROLE_E2E_OUT={} must be a new or empty folder.".format(out))
    return Path(out)


def test_three_rounds(paper_dir):
    paper = str(paper_dir)
    eng = Engine()
    try:
        eng.call("new", paper=paper, title=TITLE, student="Lin Zhou")

        # Round 1: comments on the places that v2 edits, from real word boxes (one rect per line).
        state = eng.call("ingest", paper=paper, source=str(FIXTURE / "v1"))["state"]
        pdf1 = state["round"]["build"]["pdf"]
        for cid, kind, phrase, page, note, _, _ in ROUND1:
            r = eng.call("comment", paper=paper, page=page, rects=select(pdf1, page, phrase), text=phrase,
                         note=note, kind=kind)
            assert r["id"] == cid
        cs = by_id(r["state"])
        for cid, kind, _, page, note, file, line in ROUND1:
            c = cs[cid]
            assert (c["kind"], c["page"], c["file"], c["line"], c["method"], c["confidence"], c["note"]) == \
                (kind, page, file, line, "selection", 1.0, note), cid
        state = eng.call("finish", paper=paper)["state"]
        assert email_groups(state["round"]["email"]) == ({"New comments (7)": [c[0] for c in ROUND1]}, None)

        # Round 2: every comment is carried and re-anchored; E5 and E7 are the unrequested changes.
        eng.events.clear()
        state = eng.call("ingest", paper=paper, source=str(FIXTURE / "v2"))["state"]
        assert "Comparing with round 1…" in eng.events
        assert (state["round"]["n"], state["round"]["build"]["status"]) == (2, "ok")
        pdf2 = state["round"]["build"]["pdf"]
        assert [(ch["id"], ch["kind"], ch["file"], ch["line"], ch["unrequested"]) for ch in state["changes"]] == [
            ("c01", "replace", "main.tex", 41, False),  # E1
            ("c02", "replace", "main.tex", 77, False),  # E2
            ("c03", "replace", "main.tex", 118, True),  # E7: 655 -> 671
            ("c04", "delete", "main.tex", 150, False),  # E3
            ("c05", "move", "main.tex", 153, False),  # E4
            ("c06", "insert", "main.tex", 162, True),  # E5: the new sentence
            ("c07", "insert", "sections/method.tex", 29, False)]  # E6
        assert all(ch["page"] is not None and ch["rects"] for ch in state["changes"])
        cs = by_id(state)
        expected = {"R1-01": ("changed", 0, ["c01"]), "R1-02": ("changed", 0, ["c02"]),
                    "R1-03": ("gone", 2, ["c04"]), "R1-04": ("moved", 2, ["c05"]),
                    "R1-05": ("changed", 1, ["c07"]), "R1-06": ("unchanged", 0, []),
                    "R1-07": ("unchanged", 1, [])}
        assert {cid: (c["anchor_state"], c["page"], c["changes"]) for cid, c in cs.items()} == expected
        assert all(c["carried"] and c["verdict"] is None and c["method"] == "diff" and c["confidence"] >= 0.75
                   for c in cs.values())
        assert all(history(c) == [{"round": 1, "anchor_state": "new", "verdict": None, "verdict_note": ""}]
                   for c in cs.values())
        assert "static" in cs["R1-01"]["new_quote"] and "simple" in cs["R1-01"]["old_quote"]
        assert (cs["R1-03"]["new_quote"], cs["R1-03"]["old_quote"].split()[:3]) == ("", ["The", "memory", "footprint"])
        moved_to = pymupdf.open(pdf2)[2].search_for("Our simulator is event-driven")[0]
        assert any(pymupdf.Rect(r).intersects(moved_to) for r in cs["R1-04"]["rects"])

        for cid, verdict, note in [("R1-01", "verified", ""), ("R1-02", "reopened", REOPEN_02),
                                   ("R1-03", "verified", ""), ("R1-04", "verified", ""),
                                   ("R1-05", "reopened", REOPEN_05), ("R1-06", "verified", ""),
                                   ("R1-06", None, ""),  # pressing V again clears it
                                   ("R1-07", "wontfix", WONTFIX_07)]:
            state = eng.call("verdict", paper=paper, id=cid, verdict=verdict, note=note)["state"]
        assert "can be edited or deleted" in eng.error("edit_comment", paper=paper, id="R1-01", note="x")
        for cid, phrase, page, note in ROUND2_NEW:
            r = eng.call("comment", paper=paper, page=page, rects=select(pdf2, page, phrase), text=phrase,
                         note=note, kind="highlight")
            assert r["id"] == cid
        assert "earlier rounds" in eng.error("verdict", paper=paper, id="R2-01", verdict="verified")
        cs = by_id(r["state"])
        assert {cid: (c["verdict"], c["verdict_note"]) for cid, c in cs.items() if c["carried"]} == {
            "R1-01": ("verified", ""), "R1-02": ("reopened", REOPEN_02), "R1-03": ("verified", ""),
            "R1-04": ("verified", ""), "R1-05": ("reopened", REOPEN_05), "R1-06": (None, ""),
            "R1-07": ("wontfix", WONTFIX_07)}
        assert [(cs[cid]["page"], cs[cid]["text"]) for cid in ("R2-01", "R2-03")] == [(2, "671"), (0, "Related Work")]

        state = eng.call("finish", paper=paper)["state"]
        final, found = marks(state["round"]["final_pdf"])
        assert (final.page_count, sorted(found)) == (5, sorted(cs))
        # a deletion is a cross and a note a dot, each on its page (the summary is page 0)
        assert {cid for cid in cs if {k for k, _ in burned(final[cs[cid]["page"] + 1], cs[cid]["rects"])}
                & {"cross", "note"}} == {"R1-03", "R1-07"}
        text = flat("".join(page.get_text() for page in final))
        assert flat("R2-01 · new 这个数为什么变了？重跑了还是笔误？") in text
        assert found["R1-02"] == "R1-02 · follow-up · p.{}".format(cs["R1-02"]["page"] + 1)
        assert flat(REOPEN_02) + flat("Round 1: " + ROUND1[1][4]) in text  # the reopen note, then the original
        assert found["R1-06"].startswith("R1-06 · still open")
        assert email_groups(state["round"]["email"]) == (
            {"Follow-ups (2)": ["R1-02", "R1-05"], "Still open (1)": ["R1-06"],
             "New comments (3)": ["R2-01", "R2-02", "R2-03"]},
            "Closed: R1-01, R1-03, R1-04 (resolved); R1-07 (no change needed)")

        # Round 3: only the open comments are carried, from their round-2 places.
        state = eng.call("ingest", paper=paper, source=str(FIXTURE / "v3"))["state"]
        cs = by_id(state)
        assert {cid: (c["anchor_state"], c["page"]) for cid, c in cs.items()} == {
            "R1-02": ("unchanged", 0), "R1-05": ("unchanged", 1), "R1-06": ("unchanged", 0),
            "R2-01": ("unchanged", 1), "R2-02": ("changed", 0), "R2-03": ("changed", 0)}
        assert all(c["carried"] and c["verdict"] is None for c in cs.values())
        assert cs["R2-02"]["confidence"] < 0.75  # heavy rewrite: needs attention
        # the card compares this round's text with the round it was reopened in, else with its creation round
        assert {cid: cs[cid]["context"]["against"] for cid in ("R1-02", "R1-06", "R2-02")} == \
            {"R1-02": 2, "R1-06": 1, "R2-02": 2}
        assert cs["R1-02"]["context"]["changed"] == [] and cs["R2-02"]["context"]["changed"]
        assert "reason about the lifetime" in " ".join(cs["R1-02"]["old_quote"].split())
        changes = {ch["id"]: ch for ch in state["changes"]}
        f1 = [ch for ch in state["changes"] if ch["file"] == "main.tex" and ch["line"] < 59]
        f2 = next(ch for ch in state["changes"] if ch["file"] == "main.tex" and ch["line"] == 59)
        f3 = next(ch for ch in state["changes"] if ch["file"] == "sections/method.tex")
        assert len(changes) == 4 and len(f1) == 2
        assert (f1[0]["attached_to"], f1[1]["unrequested"], f2["kind"], f2["attached_to"], f3["unrequested"]) == \
            (["R2-02"], True, "insert", ["R2-03"], True)
        assert {cid: c["changes"] for cid, c in cs.items()} == {
            "R1-02": [], "R1-05": [], "R1-06": [], "R2-01": [], "R2-02": [f1[0]["id"]], "R2-03": [f2["id"]]}
        assert history(cs["R1-02"]) == [{"round": 1, "anchor_state": "new", "verdict": None, "verdict_note": ""},
                                          {"round": 2, "anchor_state": "changed", "verdict": "reopened",
                                           "verdict_note": REOPEN_02}]
        assert [h["verdict"] for h in cs["R1-05"]["history"]] == [None, "reopened"]
        assert [h["verdict"] for h in cs["R1-06"]["history"]] == [None, None]
        assert history(cs["R2-01"]) == [{"round": 2, "anchor_state": "new", "verdict": None, "verdict_note": ""}]
        assert "was closed before round 3" in eng.error("verdict", paper=paper, id="R1-01", verdict="reopened")
        lg = json.loads((paper_dir / "ledger.json").read_text(encoding="utf-8"))
        rounds = {c["id"]: c["rounds"] for c in lg["comments"]}
        assert {cid for cid, r in rounds.items() if "3" in r} == set(cs)
        assert (rounds["R1-01"]["2"]["verdict"], rounds["R1-07"]["2"]["verdict_note"]) == ("verified", WONTFIX_07)
        assert rounds["R1-01"]["2"]["verdict_at"]

        eng.call("verdict", paper=paper, id="R2-03", verdict="verified")
        state = eng.call("verdict", paper=paper, id="R2-02", verdict="reopened", note="enough 还是没有论证。")["state"]
        state = eng.call("finish", paper=paper)["state"]
        assert state["round"]["closed"] and [r["closed"] for r in state["rounds"]] == [True, True, True]
        final, found = marks(state["round"]["final_pdf"])
        assert (final.page_count, sorted(found)) == (5, sorted(cs))
        assert email_groups(state["round"]["email"]) == (
            {"Follow-ups (1)": ["R2-02"], "Still open (4)": ["R1-02", "R1-05", "R1-06", "R2-01"]},
            "Closed: R2-03 (resolved)")
    finally:
        code, rest = eng.close()
    assert code == 0 and rest == ""
