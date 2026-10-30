"""Rounds 2 and 3 through the engine core: carrying, verdict rules, finish groups, final.pdf and email.

texdiff and anchor are replaced by a stand-in with the contract's interface (§5), so these tests check
the core's wiring and rules, not engine B's diff and re-anchoring."""
import json
import types
import unicodedata

import pymupdf
import pytest

from conftest import FIXTURE, TITLE, burned, history, quiet, select
from paperole import EngineError, api, ledger, render
from paperole import comments as comments_mod  # "comments" names the state comments below


def call(method, **params):
    return api.METHODS[method](params, quiet)


@pytest.fixture
def standin(monkeypatch):
    """texdiff/anchor stand-ins: R1-04 becomes an orphan, R1-03 gone, the rest unchanged; two changes."""
    calls = []

    def carry(old_src, src, pdf, diff, items, old_pdf=None):
        calls.append({"old_src": old_src, "src": src, "pdf": pdf, "diff": diff, "items": items})
        records = {}
        for item in items:
            rec = {"anchor": dict(item["last"]), "anchor_state": "unchanged", "confidence": 1.0, "method": "diff"}
            if item["id"] == "R1-04":
                rec = {"anchor": None, "anchor_state": "orphan", "confidence": 0.0, "method": "none"}
            elif item["id"] == "R1-03":
                x, y = item["last"]["rects"][0][:2]
                rec["anchor"].update(end=rec["anchor"]["start"], quote="", text="", rects=[[x, y, x + 2, y + 10]])
                rec.update(anchor_state="gone", confidence=0.87)
            records[item["id"]] = rec
        changes = [{"id": "c01", "kind": "replace", "file": "main.tex", "line": 41, "old_text": "simple",
                    "new_text": "static", "page": 0, "rects": [[181.7, 391.0, 209.4, 401.0]],
                    "attached_to": ["R1-01"] if any(i["id"] == "R1-01" for i in items) else []},
                   {"id": "c02", "kind": "insert", "file": "main.tex", "line": 162, "old_text": "",
                    "new_text": "Because the controller\n  needs no changes", "page": 3,
                    "rects": [[72.0, 100.0, 300.0, 110.0]], "attached_to": []}]
        return records, changes

    texdiff = types.ModuleType("paperole.texdiff")
    texdiff.diff_trees = lambda old_src, new_src, old_build=None, new_build=None: ("diff", str(old_src), str(new_src))
    anchor = types.ModuleType("paperole.anchor")
    anchor.carry = carry
    for name, module in (("texdiff", texdiff), ("anchor", anchor)):  # as the core (api) calls them
        monkeypatch.setattr(api, name, module)
    # the changes' PDF contexts need the real diff, as do the student's notes
    monkeypatch.setattr(api.cards, "change_details",
                        lambda *args: [c.update(section=None, context=None) for c in args[-1]])
    monkeypatch.setattr(api.notes, "find", lambda diff, lg, n, changes: ({}, []))
    return calls


def test_rounds_2_and_3(paper, standin):
    p = str(paper)
    pdf1 = str(paper / "r1" / "build" / "main.pdf")
    for page, phrase, note, kind in [
            (0, "simple keep-alive policy:", "simple 不准确，改成 static 或 fixed。", "highlight"),
            (0, "Both approaches decide when to keep a single instance alive.", "这句不准确：Hybrid 也决定预热窗口。", "highlight"),
            (2, "The memory footprint is two floating-point numbers per function.", "多余，删掉。", "strikeout"),
            (1, "Our simulator is event-driven", "这段放到本节最后。", "highlight"),
            (1, "which performed best on a held-out day of the trace.", "只用一天调参够吗？", "note")]:
        call("comment", paper=p, page=page, rects=select(pdf1, page, phrase), text="", note=note, kind=kind)
    nothing = {"to_judge": 0, "to_check": 0, "closed_at": None, "resumable": False}
    assert call("state", paper=p)["state"]["summary"] == dict(nothing, round=1, closed=False, status="ok")
    round1_state = call("finish", paper=p)["state"]
    assert round1_state["summary"] == dict(nothing, round=1, closed=True, status="ok", resumable=True,
                                           closed_at=round1_state["round"]["closed_at"])
    round1 = {c["id"]: c["rounds"]["1"]["anchor"] for c in ledger.load(paper)["comments"]}

    # Round 2: every comment is carried, with the records the re-anchoring returned.
    state = call("ingest", paper=p, source=str(FIXTURE / "v2"))["state"]
    [run] = standin
    assert [i["id"] for i in run["items"]] == ["R1-01", "R1-02", "R1-03", "R1-04", "R1-05"]
    assert all(i["anchor"] == i["last"] == round1[i["id"]] for i in run["items"])
    assert run["diff"] == ("diff", str(paper / "r1" / "src"), str(paper / "r2" / "src"))
    assert (run["src"], run["pdf"]) == (paper / "r2" / "src", paper / "r2" / "build" / "main.pdf")
    assert json.loads((paper / "r2" / "analysis.json").read_text())["schema"] == 1

    assert state["round"]["n"] == 2 and state["round"]["build"]["status"] == "ok"
    comments = {c["id"]: c for c in state["comments"]}
    assert [c["id"] for c in state["comments"]][-1] == "R1-04"  # no page: listed last
    assert all(c["carried"] and c["verdict"] is None for c in comments.values())
    c = comments["R1-02"]
    assert c["old_quote"] == c["new_quote"] == "Both approaches decide when to keep a\nsingle instance alive."
    assert history(c) == [{"round": 1, "anchor_state": "new", "verdict": None, "verdict_note": ""}]
    orphan = comments["R1-04"]
    assert (orphan["anchor_state"], orphan["page"], orphan["rects"], orphan["text"], orphan["new_quote"],
            orphan["file"], orphan["line"]) == ("orphan", None, [], "", None, None, None)
    assert orphan["old_quote"] == "Our simulator is event-driven"
    assert (comments["R1-03"]["anchor_state"], comments["R1-03"]["new_quote"]) == ("gone", "")
    assert comments["R1-01"]["changes"] == ["c01"] and comments["R1-02"]["changes"] == []
    assert [(ch["id"], ch["unrequested"]) for ch in state["changes"]] == [("c01", False), ("c02", True)]
    assert state["changes"][1]["new_text"] == "Because the controller needs no changes"
    # the papers list: 5 comments to judge and c02 to check
    assert state["summary"] == {"round": 2, "closed": False, "status": "ok", "to_judge": 5, "to_check": 1,
                                "closed_at": None, "resumable": False}

    # Edit and delete are for this round's comments, verdicts for the carried ones.
    with pytest.raises(EngineError, match="Give it a verdict"):
        call("edit_comment", paper=p, id="R1-01", note="x")
    with pytest.raises(EngineError, match="Give it a verdict"):
        call("delete_comment", paper=p, id="R1-01")
    pdf2 = str(paper / "r2" / "build" / "main.pdf")
    new = call("comment", paper=p, page=0, rects=select(pdf2, 0, "A short-term forecast of the rate is therefore enough"),
               text="", note="enough 需要论证。", kind="highlight", color="blue")
    assert new["id"] == "R2-01"
    with pytest.raises(EngineError, match="earlier rounds"):
        call("verdict", paper=p, id="R2-01", verdict="verified")
    call("verdict", paper=p, id="R1-01", verdict="verified")
    call("verdict", paper=p, id="R1-02", verdict="reopened", note="还是没说清楚和 Hybrid 的区别。")
    call("verdict", paper=p, id="R1-03", verdict="wontfix", note="typo")
    state = call("verdict", paper=p, id="R1-03", verdict=None, note="ignored")["state"]  # cleared
    c = next(c for c in state["comments"] if c["id"] == "R1-03")
    assert (c["verdict"], c["verdict_note"]) == (None, "")
    call("verdict", paper=p, id="R1-03", verdict="verified")
    state = call("verdict", paper=p, id="R1-05", verdict="wontfix", note="这次先不改。")["state"]
    assert {c["id"]: c["verdict"] for c in state["comments"]} == {
        "R1-01": "verified", "R1-02": "reopened", "R1-03": "verified", "R1-04": None, "R1-05": "wontfix", "R2-01": None}
    assert (state["summary"]["to_judge"], state["summary"]["to_check"]) == (1, 1)
    state = call("check_change", paper=p, id="c02")["state"]
    assert (state["summary"]["to_judge"], state["summary"]["to_check"]) == (1, 0)
    call("check_change", paper=p, id="c02", checked=False)
    with pytest.raises(EngineError, match="Finish it"):
        call("ingest", paper=p, source=str(FIXTURE / "v3"))

    state = round2_state = call("finish", paper=p)["state"]
    assert state["round"]["email"] == (
        "Round 2 review: {}\n\n{}\n\n"
        "Follow-ups (1)\n"
        'R1-02  p.1  "Both approaches decide when to keep a single instance alive."\n'
        "  这句不准确：Hybrid 也决定预热窗口。\n"
        "  Round 2: 还是没说清楚和 Hybrid 的区别。\n\n"
        "Still open (1)\n"
        'R1-04  location not found  "Our simulator is event-driven"\n'
        "  这段放到本节最后。\n\n"
        "New comments (1)\n"
        'R2-01  p.1  "A short-term forecast of the rate is therefore enough"\n'
        "  enough 需要论证。\n\n"
        "Closed: R1-01, R1-03 (resolved); R1-05 (no change needed)\n"
        "  R1-05 (no change needed): 这次先不改。\n").format(TITLE, render.REPLY_RULE)  # a closing note, in full

    final = pymupdf.open(state["round"]["final_pdf"])
    assert final.page_count == 5
    summary = unicodedata.normalize("NFKC", final[0].get_text())  # MuPDF keeps the "ﬁ" ligature
    for expected in ("Review of Round 2", "To do for Round 3 (3)\nR1-02\nR1-04\n+ R2-01", "Follow-ups (1)",
                     "Still open (1)", "Resolved (2)\nR1-01\nR1-03", "No change\nneeded (1)",
                     "这次先不改。\nRound 1: 只用一天调参够吗?", "Your changes no comment asked for (1)"):
        assert expected in summary
    assert "(location not found in Round 2)" in " ".join(summary.split())  # wrapped at the paper's page width
    # no annotation but the paper's links: the outline lists the comments, and the marks are burned in, each in the
    # comment's colour (a highlight in its fill, other kinds in its ink)
    assert all(a.type[1] == "Link" for p in final for a in p.annots())
    assert sorted(t[1] for t in final.get_toc() if t[0] == 2 and t[1][:2] in ("R1", "R2")) == [
        "R1-01 · resolved · p.1", "R1-02 · follow-up · p.1", "R1-03 · resolved · p.3",
        "R1-05 · no change needed · p.2", "R2-01 · new · p.1"]  # the orphan R1-04 has no page: only on the summary
    fill, ink = ({k: tuple(round(v, 2) for v in render._rgb(c[i])) for k, c in comments_mod.PALETTE.items()}
                 for i in (0, 1))
    cs = {c["id"]: c for c in state["comments"]}
    drawn = {cid: burned(final[cs[cid]["page"] + 1], cs[cid]["rects"])
             for cid in ("R1-01", "R1-02", "R1-03", "R1-05", "R2-01")}
    assert ("highlight", fill["yellow"]) in drawn["R1-01"] & drawn["R1-02"]
    assert ("cross", ink["yellow"]) in drawn["R1-03"]  # gone
    assert ("note", ink["yellow"]) in drawn["R1-05"] and ("highlight", fill["blue"]) in drawn["R2-01"]
    margin = "".join(final[1].get_text().split())
    assert "还是没说清楚和Hybrid的区别。Round1:这句不准确：Hybrid也决定预热窗口。" in margin  # reopen note, then the original

    # Round 3: only the reopened, still open and new comments are carried.
    state = call("ingest", paper=p, source=str(FIXTURE / "v3"))["state"]
    items = standin[1]["items"]
    assert [i["id"] for i in items] == ["R1-02", "R1-04", "R2-01"]
    orphan = items[1]
    assert orphan["anchor"] is None and orphan["last"] == round1["R1-04"]
    assert [c["id"] for c in state["comments"]] == ["R2-01", "R1-02", "R1-04"]
    c = next(c for c in state["comments"] if c["id"] == "R1-02")
    assert c["verdict"] is None and [h["verdict"] for h in c["history"]] == [None, "reopened"]
    assert c["history"][1]["verdict_note"] == "还是没说清楚和 Hybrid 的区别。"
    assert next(c for c in state["comments"] if c["id"] == "R1-04")["old_quote"] == "Our simulator is event-driven"
    assert state["rounds"][1]["closed"] and not state["rounds"][2]["closed"]
    # An earlier round is shown as it was left: its comments, verdicts, changes and outputs; only the list of rounds and
    # the paper's next step are today's.
    assert call("state", paper=p, round=3) == call("state", paper=p) == {"state": state}
    now = {k: state[k] for k in ("rounds", "summary")}

    def left(s):  # what comes from the paragraphs' cache (built later for round 2) and the read set as it is now, and
        # whether a comment can be reopened in the open round or the round resumed (today's, as the rounds and the
        # next step)
        return dict(s, reading=None, comments=[dict(c, paragraph=None, revivable=None) for c in s["comments"]],
                    changes=[dict(c, blocks=None, read=None) for c in s["changes"]],
                    round=dict(s["round"], resumable=None))
    assert left(call("state", paper=p, round=2)["state"]) == left(dict(round2_state, **now))
    assert left(call("state", paper=p, round=1)["state"]) == left(dict(round1_state, **now))
    with pytest.raises(EngineError, match="There is no round 4"):
        call("state", paper=p, round=4)
    nope = str(paper / "nope")
    assert call("summaries", papers=[p, nope]) == {"papers": [
        {"path": p, "summary": state["summary"], "paper": {"title": state["paper"]["title"], "student": state["paper"]["student"],
                                                            "id": state["paper"]["id"], "finished": None}},
        {"path": nope, "error": "{} is not a Paperole paper folder (no ledger.json).".format(nope)}]}
    # R1-02, reopened in round 2 and still open, keeps telling the student why
    email = call("finish", paper=p)["state"]["round"]["email"]
    assert "  这句不准确：Hybrid 也决定预热窗口。\n  Round 2 (follow-up): 还是没说清楚和 Hybrid 的区别。\n" in email
    assert email.index("Still open (3)") < email.index("Round 2 (follow-up)")


def test_a_round_finished_now_uses_the_students_words(paper, standin):
    """UI v2 (CONTRACT amendment "Student-facing words"): email.txt and final.pdf of a round finished now say
    follow-up, resolved and no change needed (groups, Closed line, margin, key, summary, outline), open comments in
    black and closed ones in grey; a round finished before keeps the email.txt and final.pdf it wrote."""
    p = str(paper)
    pdf1 = str(paper / "r1" / "build" / "main.pdf")
    for page, phrase in [(0, "simple keep-alive policy:"),
                         (0, "Both approaches decide when to keep a single instance alive."),
                         (2, "The memory footprint is two floating-point numbers per function.")]:  # R1-03: gone
        call("comment", paper=p, page=page, rects=select(pdf1, page, phrase), text="", note="Fix it.", kind="highlight")
    call("finish", paper=p)
    call("ingest", paper=p, source=str(FIXTURE / "v2"))
    pdf2 = str(paper / "r2" / "build" / "main.pdf")
    call("comment", paper=p, page=0, rects=select(pdf2, 0, "A short-term forecast of the rate is therefore enough"),
         text="", note="Why?", kind="highlight")
    for cid, verdict, note in [("R1-01", "verified", "Reads well now."), ("R1-02", "reopened", "Say which window."),
                               ("R1-03", "wontfix", "Fine as it is.")]:
        state = call("verdict", paper=p, id=cid, verdict=verdict, note=note)["state"]
    state = call("finish", paper=p)["state"]

    email = (paper / "r2" / "email.txt").read_text(encoding="utf-8")
    assert state["round"]["email"] == email
    lines = email.splitlines()
    for line in ("Follow-ups (1)", "New comments (1)", "Closed: R1-01 (resolved); R1-03 (no change needed)",
                 "  R1-01 (resolved): Reads well now.", "  R1-03 (no change needed): Fine as it is."):
        assert line in lines
    final = pymupdf.open(paper / "r2" / "final.pdf")
    text = " ".join(" ".join(page.get_text() for page in final).split())
    assert not [w for w in ("reopened", "verified", "won't fix") if w in (email + text).lower()]
    summary = " ".join(final[0].get_text().split())
    key = summary[summary.index("Key "):summary.index("Earlier comments")]
    assert key.index("follow-up") < key.index("new comment") < key.index("– no change needed") < key.index("resolved")
    assert summary.index("Follow-ups (1)") < summary.index("No change needed (1)") < summary.index("Resolved (1)")
    labels = [s["bbox"] for b in final[0].get_text("dict")["blocks"] for line in b.get("lines", [])
              for s in line["spans"] if s["text"] in ("No change", "needed (1)")]  # on two lines, clear of the chip
    assert len(labels) == 2 and max(r[2] for r in labels) < min(r.x0 for r in final[0].search_for("R1-03"))
    assert sorted(t[1] for t in final.get_toc() if t[0] == 2) == [
        "R1-01 · resolved · p.1", "R1-02 · follow-up · p.1", "R1-03 · no change needed · p.3", "R2-01 · new · p.1"]

    def rgb(hex_colour):
        return tuple(round(v, 2) for v in render._rgb(hex_colour))
    black, grey = ("#1F1F1F", "#FFFFFF", "#1F1F1F"), ("#A0A0A0", "#F2F2F2", "#5C5C5C")  # (mark, fill, text)
    cs = {c["id"]: c for c in state["comments"]}
    for cid, head, colours in [("R1-01", "R1-01 · resolved", grey), ("R1-02", "R1-02 · follow-up", black),
                               ("R1-03", "R1-03 · no change needed", grey), ("R2-01", "R2-01 · new", black)]:
        page = final[cs[cid]["page"] + 1]
        spans = [s for b in page.get_text("dict")["blocks"] for line in b.get("lines", []) for s in line["spans"]]
        # the margin heading (after its sign) in the status's text colour
        assert {rgb("#{:06X}".format(s["color"])) for s in spans if s["text"].endswith(head)} == {rgb(colours[2])}
        # the ID chip beside the anchor (and an open comment's margin box): black on white, or grey on grey
        hits = [(h.tl + h.br) / 2 for h in page.search_for(cid)]
        boxes = {(tuple(round(v, 2) for v in d["color"]), tuple(round(v, 2) for v in d["fill"]))
                 for d in page.get_drawings() if d["type"] == "fs" and any(d["rect"].contains(h) for h in hits)}
        assert boxes == {(rgb(colours[0]), rgb(colours[1]))}

    # a round finished before keeps what it wrote (here an older engine's words); round 3 writes the new ones
    old = email.replace("Follow-ups", "Reopened").replace("(resolved)", "(verified)")
    (paper / "r2" / "email.txt").write_text(old, encoding="utf-8")
    pdf = (paper / "r2" / "final.pdf").read_bytes()
    call("ingest", paper=p, source=str(FIXTURE / "v3"))
    assert "  Round 2 (follow-up): Say which window.\n" in call("finish", paper=p)["state"]["round"]["email"]
    assert call("state", paper=p, round=2)["state"]["round"]["email"] == old
    assert (paper / "r2" / "final.pdf").read_bytes() == pdf


def test_email_preview_is_the_email_finish_writes(paper, standin):
    """UI v2 Finish sheet (CONTRACT amendment "Email preview"): email_preview returns the email.txt that finish would
    write for the open round now, follows every answer, writes nothing, has no state, and is refused without an open
    round."""
    p = str(paper)
    pdf1 = str(paper / "r1" / "build" / "main.pdf")
    for page, phrase in [(0, "simple keep-alive policy:"),
                         (0, "Both approaches decide when to keep a single instance alive."),
                         (2, "The memory footprint is two floating-point numbers per function.")]:
        call("comment", paper=p, page=page, rects=select(pdf1, page, phrase), text="", note="Fix it.", kind="highlight")
    preview = call("email_preview", paper=p)
    assert set(preview) == {"round", "text"} and preview["round"] == 1
    call("finish", paper=p)
    assert (paper / "r1" / "email.txt").read_text(encoding="utf-8") == preview["text"]
    with pytest.raises(EngineError, match="There is no open round"):
        call("email_preview", paper=p)

    call("ingest", paper=p, source=str(FIXTURE / "v2"))
    pdf2 = str(paper / "r2" / "build" / "main.pdf")
    call("comment", paper=p, page=0, rects=select(pdf2, 0, "A short-term forecast of the rate is therefore enough"),
         text="", note="Why?", kind="highlight")
    before = call("email_preview", paper=p)["text"]
    assert "Still open (3)" in before and "Follow-ups" not in before
    call("verdict", paper=p, id="R1-02", verdict="reopened", note="Say which window.")
    call("verdict", paper=p, id="R1-01", verdict="verified", note="Reads well now.")
    ledger_bytes = (paper / "ledger.json").read_bytes()
    files = sorted(str(f) for f in paper.rglob("*"))
    text = call("email_preview", paper=p)["text"]
    assert "Follow-ups (1)\nR1-02" in text and "  Round 2: Say which window.\n" in text
    assert "Closed: R1-01 (resolved)\n  R1-01 (resolved): Reads well now.\n" in text
    assert (paper / "ledger.json").read_bytes() == ledger_bytes and sorted(str(f) for f in paper.rglob("*")) == files
    assert call("finish", paper=p)["state"]["round"]["email"] == text
