"""Writing-analysis tags (CONTRACT.md amendment "Tags, key page and Reopen"; design/tags/TAGS.md): tag ids on a comment
in the ledger, set and cleared through `tag` and `comment`, kept with their "by" and "at", on any round (a closed one
too) and changing nothing the student receives; old ledgers read as untagged; the overview's numbers per paper and per
student (counts once in totals, the first drafts' trend words and why there is none, facts, For the next draft, Well
done), synthetic only."""
import io
import json
import shutil
from contextlib import redirect_stdout

import pytest

from conftest import Engine, quiet, select
from paperole import EngineError, api, cli, ledger, overview, state, tags

PHRASES = [(0, "simple keep-alive policy:"), (0, "Both approaches decide when to keep a single instance alive."),
           (1, "Our simulator is event-driven")]


def call(method, **params):
    return api.METHODS[method](params, quiet)


def make(paper, k, **extra):
    page, phrase = PHRASES[k]
    pdf = paper / "r1" / "build" / "main.pdf"
    return call("comment", paper=str(paper), page=page, rects=select(str(pdf), page, phrase), text=phrase,
                note="note {}".format(k), kind="highlight", **extra)


def raw(paper, cid):
    return ledger.get_comment(ledger.load(paper), cid)


def test_tags_are_set_kept_and_cleared(paper, monkeypatch):
    p = str(paper)
    r = make(paper, 0, tags=["logic", "wording", "logic"], accepted=["logic"])
    cid = r["id"]
    shown = next(c for c in r["state"]["comments"] if c["id"] == cid)
    assert shown["tags"] == ["logic", "wording"] and "env" in shown  # env: for the app's suggestions by place
    first = raw(paper, cid)["tags"]
    assert [(t["id"], t["by"]) for t in first] == [("logic", "suggestion"), ("wording", "advisor")]
    other = make(paper, 1)["id"]  # a comment without tags has no key, and reads as untagged
    assert "tags" not in raw(paper, other)
    assert next(c for c in call("state", paper=p)["state"]["comments"] if c["id"] == other)["tags"] == []

    # the whole list each time: kept ids keep when and how they came, new ones are now's; without state, just the ids
    monkeypatch.setattr(ledger, "now", lambda: "2030-01-02T03:04:05+08:00")
    assert call("tag", paper=p, id=cid, tags=["wording", "grammar", "logic", "grammar"], state=False) == \
        {"id": cid, "tags": ["wording", "grammar", "logic"]}
    held = raw(paper, cid)["tags"]
    assert held[0] == first[1] and held[2] == first[0]
    assert held[1] == {"id": "grammar", "by": "advisor", "at": "2030-01-02T03:04:05+08:00"}
    # the advisor's own tag, its name kept in the ledger (white space collapsed)
    r = call("tag", paper=p, id=cid, tags=["u-3f9c1a2b"], accepted=["u-3f9c1a2b"],
             names={"u-3f9c1a2b": "  Hedging   words "})
    assert ledger.load(paper)["tag_names"] == {"u-3f9c1a2b": "Hedging words"}
    assert raw(paper, cid)["tags"] == [{"id": "u-3f9c1a2b", "by": "suggestion", "at": "2030-01-02T03:04:05+08:00"}]
    assert next(c for c in r["state"]["comments"] if c["id"] == cid)["tags"] == ["u-3f9c1a2b"]
    # cleared: the key goes
    call("tag", paper=p, id=cid, tags=[])
    assert "tags" not in raw(paper, cid)

    before = (paper / "ledger.json").read_bytes()
    for bad, message in ((["Logic"], "is not a tag id"), (["x" * 33], "is not a tag id"), (["1x"], "is not a tag id"),
                         (["t{}".format(i) for i in range(13)], "at most 12 tags"), ("logic", "is a list"),
                         ([3], "is a list")):
        with pytest.raises(EngineError, match=message):
            call("tag", paper=p, id=cid, tags=bad)
    with pytest.raises(EngineError, match="There is no comment R9-01"):
        call("tag", paper=p, id="R9-01", tags=["logic"])
    with pytest.raises(EngineError, match="Missing parameter: tags"):
        call("tag", paper=p, id=cid)
    with pytest.raises(EngineError, match="1 to 64 characters"):
        call("tag", paper=p, id=cid, tags=["u-1"], names={"u-1": "  "})
    with pytest.raises(EngineError, match="is not a tag id"):
        make(paper, 2, tags=["Bad"])  # the comment is not written either
    assert (paper / "ledger.json").read_bytes() == before  # a refused request changes nothing


def test_tags_on_a_closed_round_change_nothing_the_student_gets(paper):
    p = str(paper)
    cid = make(paper, 0)["id"]
    call("finish", paper=p)
    outputs = {f: (paper / "r1" / f).read_bytes() for f in ("final.pdf", "email.txt")}
    with pytest.raises(EngineError, match="no open round"):
        call("edit_comment", paper=p, id=cid, note="x")  # the round is closed for everything else
    r = call("tag", paper=p, id=cid, tags=["clarity", "praise"], round=1)
    assert r["state"]["round"]["n"] == 1 and r["state"]["round"]["closed"]
    assert next(c for c in r["state"]["comments"] if c["id"] == cid)["tags"] == ["clarity", "praise"]
    assert {f: (paper / "r1" / f).read_bytes() for f in outputs} == outputs
    assert "clarity" not in outputs["email.txt"].decode() and "Clarity" not in outputs["email.txt"].decode()


def test_contexts_are_keyed_without_tags():
    """A comment's cached contexts (rN/contexts.json) are keyed by its JSON without its tags, so tagging a comment of
    an older round does not make the engine work its contexts out again; an untagged one keys as it always did."""
    c = {"id": "R1-01", "note": "n", "rounds": {"1": {"anchor": None}}}
    assert state._json(c) == json.dumps(c, sort_keys=True)
    assert state._json(dict(c, tags=[{"id": "logic", "by": "advisor", "at": "x"}])) == state._json(c)


def test_cli_and_rpc(paper):
    p = str(paper)
    pdf = str(paper / "r1" / "build" / "main.pdf")
    rects = ";".join(",".join(str(v) for v in r) for r in select(pdf, 0, "simple keep-alive policy:"))
    out = io.StringIO()
    with redirect_stdout(out):
        assert cli.main(["comment", p, "--page", "0", "--rects", rects, "--note", "Say which.", "--tags",
                         "logic,u-77aa0b1c", "--accepted", "logic", "--name", "u-77aa0b1c=Hedging"]) == 0
    cid = json.loads(out.getvalue())["id"]
    assert tags.ids(raw(paper, cid)) == ["logic", "u-77aa0b1c"]
    assert ledger.load(paper)["tag_names"] == {"u-77aa0b1c": "Hedging"}
    out = io.StringIO()
    with redirect_stdout(out):
        assert cli.main(["tag", p, cid, "grammar", "--no-state"]) == 0
    assert json.loads(out.getvalue()) == {"id": cid, "tags": ["grammar"]}
    with redirect_stdout(io.StringIO()):
        assert cli.main(["tag", p, cid, "--clear"]) == 0
    assert tags.ids(raw(paper, cid)) == []
    engine = Engine()
    try:
        r = engine.call("tag", paper=p, id=cid, tags=["figures", "math"])
        assert next(c for c in r["state"]["comments"] if c["id"] == cid)["tags"] == ["figures", "math"]
        assert "is not a tag id" in engine.error("tag", paper=p, id=cid, tags=["Figures"])
    finally:
        assert engine.close()[0] == 0


def test_merge_reads_each_list_from_the_ledger(paper):
    """retag (Merge Into…) changes each comment's list as the ledger has it, so a tag put on since the app last read
    the paper is kept (the code audit: whole lists sent from a stale overview overwrote newer tags); state and overview
    give the ledger's tag_names, so a tag the app's catalogue lacks still shows its name."""
    p = str(paper)
    own = "u-1a2b3c4d"
    a = make(paper, 0, tags=[own, "logic"], names={own: "Hedging"})["id"]
    b = make(paper, 1, tags=[own, "clarity"])["id"]
    c = make(paper, 2, tags=["grammar"])["id"]
    call("tag", paper=p, id=a, tags=[own, "logic", "grammar"], state=False)  # after the app read the paper
    held = raw(paper, a)["tags"]
    before = {cid: raw(paper, cid)["tags"] for cid in (b, c)}
    assert call("retag", paper=p, state=False, **{"from": own, "into": "clarity"}) == {"changed": [a, b]}
    assert tags.ids(raw(paper, a)) == ["clarity", "logic", "grammar"]
    assert raw(paper, a)["tags"][0] == dict(held[0], id="clarity")  # its "by" and "at" kept
    assert raw(paper, b)["tags"] == [before[b][1]]  # held both: its own clarity, once
    assert raw(paper, c)["tags"] == before[c]
    r = call("retag", paper=p, **{"from": "grammar", "into": None})  # taken off; the last one takes the key away
    assert r["changed"] == [a, c] and "tags" not in raw(paper, c)
    assert next(x for x in r["state"]["comments"] if x["id"] == a)["tags"] == ["clarity", "logic"]
    assert call("retag", paper=p, state=False, **{"from": "math", "into": "logic"}) == {"changed": []}
    with pytest.raises(EngineError, match="is not a tag id"):
        call("retag", paper=p, **{"from": "Math", "into": "logic"})
    with pytest.raises(EngineError, match="Missing parameter: from"):
        call("retag", paper=p, into="logic")
    assert call("state", paper=p)["state"]["tag_names"] == {own: "Hedging"}
    assert overview.overview([p])["papers"][0]["overview"]["tag_names"] == {own: "Hedging"}
    out = io.StringIO()
    with redirect_stdout(out):
        assert cli.main(["retag", p, "logic", "evidence", "--no-state"]) == 0
    assert json.loads(out.getvalue()) == {"changed": [a]}
    assert tags.ids(raw(paper, a)) == ["clarity", "evidence"]


def test_merge_and_ids_without_tex():
    """Review fixes, 2026-10-24: a comment that holds both tags of a merge keeps its own entry of the target, with its
    "by" and "at" (it kept the merged tag's: m28); a trailing line break is no part of a tag id (`$` matched before
    it: m29); a bad name is refused before anything changes, in a merge as in set_tags."""
    own, clarity = {"id": "u-1a2b3c4d", "by": "advisor", "at": "2026-10-01"}, \
        {"id": "clarity", "by": "suggestion", "at": "2026-10-02"}
    lg = {"comments": [{"id": "R1-01", "tags": [dict(own), dict(clarity)]},
                       {"id": "R1-02", "tags": [dict(own), {"id": "logic", "by": "advisor", "at": "2026-10-03"}]}]}
    assert tags.replace(lg, own["id"], "clarity") == ["R1-01", "R1-02"]
    assert lg["comments"][0]["tags"] == [clarity]  # its own, once
    assert lg["comments"][1]["tags"] == [dict(own, id="clarity"), {"id": "logic", "by": "advisor", "at": "2026-10-03"}]
    before = json.dumps(lg)
    for bad in ({"u-1": "  "}, {"u-1": "x" * 65}, ["u-1"], {"Bad": "Name"}):
        with pytest.raises(EngineError):
            tags.replace(lg, "clarity", "logic", names=bad)
        with pytest.raises(EngineError):
            tags.set_tags(lg, "R1-01", ["logic"], names=bad)
    assert json.dumps(lg) == before
    tags.set_tags(lg, "R1-01", ["clarity"], names={"u-1": " Hedging  words "})
    tags.replace(lg, "clarity", "logic", names={"u-2": "Tone"})
    assert lg["tag_names"] == {"u-1": "Hedging words", "u-2": "Tone"}
    for bad in ("logic\n", "logic\r", "u-1a2b3c4d\n"):
        with pytest.raises(EngineError, match="is not a tag id"):
            tags.check([bad])
    assert tags.ids({"tags": [{"id": "logic\n"}, {"id": "logic"}]}) == ["logic"]


def test_the_overview_counts_tags(paper):
    p = str(paper)
    a = make(paper, 0, tags=["grammar", "logic"])["id"]
    b = make(paper, 1, tags=["grammar"])["id"]
    c = make(paper, 2)["id"]
    ov = overview.overview([p])
    po = ov["papers"][0]["overview"]
    assert {x["id"]: x["tags"] for x in po["comments"]} == {a: ["grammar", "logic"], b: ["grammar"], c: []}
    t = po["tags"]
    assert (t["comments"], t["tagged"], t["open"]) == (3, 2, 3)
    assert t["rounds"] == [{"n": 1, "new": 3, "untagged": 1, "by_tag": {"grammar": 2, "logic": 1}}]
    assert (t["by_tag"]["grammar"]["comments"], t["by_tag"]["logic"]["comments"], t["untagged"]["comments"]) == \
        (2, 1, 1)
    keys = {s["key"] for s in po["sections"]}
    assert all(k in keys for row in t["by_tag"].values() for k, _ in row["written_in"])
    assert sum(n for _, n in t["by_tag"]["grammar"]["written_in"]) == 2
    s = ov["students"][0]["tags"]
    assert (s["comments"], s["tagged"]) == (3, 2)
    assert s["first_drafts"]["trend"]["grammar"] == {"word": None, "why": "two_points", "counts": []}
    assert s["first_drafts"]["skipped"] == [{"path": p, "why": "small"}]  # 3 new comments: no trend point


# --- the numbers, without TeX ------------------------------------------------------------------------------------

def step(n, answer=None, key="results", response=None):
    return [n, "placed", 0, 0.5, key, response or ("new" if answer is None else "edited"), answer]


def cm(cid, created, path, tags_=(), revived=(), note=""):
    return {"id": cid, "created_round": created, "kind": "highlight", "color": "yellow", "note": note or cid,
            "path": path, "tags": list(tags_), "revived": list(revived), "revivable": False}


def rd(n, created, closed=True, pages=10, added=None, status="ok"):
    return {"n": n, "created": created, "closed": closed, "closed_at": None, "received": None,
            "build": {"status": status, "pages": pages}, "words": {"body": 1000, "added": added or 0, "deleted": 0}}


def ov_(student, rounds, comments, sections=("intro", "results")):
    return {"paper": {"title": "T", "student": student, "created": None}, "rounds": rounds, "comments": comments,
            "sections": [{"key": k} for k in sections],
            "threads": {"comments": 0, "resolved": 0, "kept": 0, "open": 0, "followed_up": 0,
                        "untouched_after_follow_up": 0, "closed_after": {"1": 0, "2": 0, "3+": 0}}}


def test_paper_tags_count_each_comment_once_in_totals():
    comments = [cm("R1-01", 1, [step(1), step(2, "follow_up"), step(3, "resolved")], ["grammar", "logic"]),
                cm("R1-02", 1, [step(1, key="intro"), step(2, "resolved", key="intro")], ["grammar"]),
                cm("R1-03", 1, [step(1), step(2, "left_open"), step(3, "to_check")]),
                cm("R2-01", 2, [step(2), step(3, "to_check")], ["logic"], revived=[]),
                cm("R2-02", 2, [step(2, key="intro"), step(3, "kept", key="intro")], ["praise"]),
                cm("R1-04", 1, [step(1, key=None), step(2, "resolved", key=None), step(3, "to_check", key=None)],
                   ["logic"], revived=[{"round": 3, "from": 2}])]
    t = tags.paper_tags(ov_("Mei", [rd(1, "2026-09-01T10:00:00+08:00"), rd(2, "2026-09-10T10:00:00+08:00"),
                                    rd(3, "2026-09-20T10:00:00+08:00", closed=False)], comments))
    assert (t["comments"], t["tagged"], t["open"]) == (6, 5, 3)
    assert t["rounds"] == [{"n": 1, "new": 4, "untagged": 1, "by_tag": {"grammar": 2, "logic": 2}},
                           {"n": 2, "new": 2, "untagged": 0, "by_tag": {"logic": 1, "praise": 1}},
                           {"n": 3, "new": 0, "untagged": 0, "by_tag": {}}]
    g, lo = t["by_tag"]["grammar"], t["by_tag"]["logic"]
    assert g == {"comments": 2, "open": 0, "closed_after": {"1": 1, "2": 1, "3+": 0}, "followed_up": 1, "revived": 0,
                 "written_in": [["intro", 1], ["results", 1]]}  # equal counts: in the sections' order
    assert lo == {"comments": 3, "open": 2, "closed_after": {"1": 0, "2": 1, "3+": 0}, "followed_up": 1,
                  "revived": 1, "written_in": [["results", 2]]}  # R1-04 was written in no section
    assert t["untagged"] == {"comments": 1, "open": 1, "closed_after": {"1": 0, "2": 0, "3+": 0}, "followed_up": 0,
                             "revived": 0, "written_in": [["results", 1]]}
    assert t["by_tag"]["praise"]["closed_after"] == {"1": 1, "2": 0, "3+": 0}


def first_drafts(counts, pages=(10, 10, 10), extra=None):
    """Three (or len(counts)) papers of one student, each a closed Round 1 with counts[i] = {tag: k} new comments, and
    `extra` untagged ones (a list per paper)."""
    group = []
    for i, cs in enumerate(counts):
        path = "/p{}".format(i)
        comments, k = [], 0
        for t, n in cs.items():
            for _ in range(n):
                k += 1
                comments.append(cm("R1-{:02d}".format(k), 1, [step(1)], [t] if t else []))
        for _ in range((extra or [0] * len(counts))[i]):
            k += 1
            comments.append(cm("R1-{:02d}".format(k), 1, [step(1)]))
        group.append((path, ov_("Mei", [rd(1, "2026-0{}-01T10:00:00+08:00".format(i + 1), pages=pages[i])],
                                comments, sections=()), {}))
    return group


def trend(group, tag):
    return tags.student_tags(group)["first_drafts"]["trend"][tag]


def test_trend_words_need_three_like_first_drafts():
    def g(*ks, pages=None):  # grammar counts per first draft, with Logic comments so every draft has 5 or more
        return first_drafts([{"grammar": k, "logic": max(2, 5 - k)} for k in ks], pages=pages or (10,) * len(ks))
    assert trend(g(8, 4, 2), "grammar") == {"word": "fewer", "why": None, "counts": [8, 4, 2]}
    assert trend(g(1, 3, 6), "grammar")["word"] == "more"
    assert trend(g(3, 2, 1), "grammar")["word"] == "mixed"  # steady but small: noise, no clear trend
    assert trend(g(8, 5, 6), "grammar")["word"] == "mixed"
    assert trend(g(5, 4, 5), "grammar")["word"] == "same"
    assert trend(g(8, 5, 4), "grammar")["word"] == "fewer"
    assert trend(g(8, 5, 5), "grammar")["word"] == "mixed"  # not every step goes down
    assert trend(g(8, 4, 2, 1), "grammar")["word"] == "fewer"  # all usable drafts, in time order
    assert trend(g(8, 4), "grammar") == {"word": None, "why": "two_points", "counts": [8, 4]}
    assert trend(g(8, 4, 2, pages=(8, 10, 14)), "grammar") == {"word": None, "why": "lengths_differ",
                                                               "counts": [8, 4, 2]}
    small = first_drafts([{"grammar": 6}, {"grammar": 5}, {"grammar": 4}])
    t = tags.student_tags(small)
    assert t["first_drafts"]["skipped"] == [{"path": "/p2", "why": "small"}]
    assert t["first_drafts"]["points"] == ["/p0", "/p1"]
    assert t["first_drafts"]["trend"]["grammar"] == {"word": None, "why": "small", "counts": [6, 5]}
    untagged = first_drafts([{"grammar": 6}, {"grammar": 5}, {"grammar": 3}], extra=[0, 0, 2])  # 3 of 5 tagged
    assert trend(untagged, "grammar")["why"] == "untagged"


def student(papers):
    """[(path, ov, latest)] of one student from {path: (rounds, comments, latest)}."""
    return [(path, ov_("Mei", rs, cs), latest) for path, (rs, cs, latest) in papers.items()]


def test_facts_are_single_facts_picked_in_the_advisors_order():
    shrimp = ([rd(1, "2026-03-01T10:00:00+08:00"), rd(2, "2026-03-20T10:00:00+08:00"),
               rd(3, "2026-04-10T10:00:00+08:00")],
              [cm("R1-01", 1, [step(1), step(2, "resolved")], ["grammar"]),
               cm("R1-02", 1, [step(1), step(2, "resolved")], ["grammar"]),
               cm("R1-03", 1, [step(1), step(2, "follow_up"), step(3, "resolved")], ["logic"])], {})
    reef = ([rd(1, "2026-05-01T10:00:00+08:00"), rd(2, "2026-05-20T10:00:00+08:00"),
             rd(3, "2026-06-10T10:00:00+08:00", closed=False)],
            [cm("R1-01", 1, [step(1), step(2, "follow_up"), step(3, "resolved")], ["grammar"]),
             cm("R1-02", 1, [step(1), step(2, "follow_up"), step(3, "kept")], ["logic"]),
             cm("R1-03", 1, [step(1), step(2, "follow_up"), step(3, "resolved")], ["logic"]),
             cm("R1-04", 1, [step(1), step(2, "resolved")], ["praise"])], {})
    t = tags.student_tags(student({"/shrimp": shrimp, "/reef": reef}))
    # Grammar's last comment was in Reef's Round 1, and only one closed round came since (Round 3 is open): no fact;
    # all three Logic comments took two answered rounds
    assert t["facts"] == [{"tag": "logic", "kind": "slow", "n": 3, "of": 3}]
    # one more closed round with neither: none since Reef's Round 2 (the first fact that holds, for each tag)
    reef[0][2]["closed"] = True
    t = tags.student_tags(student({"/shrimp": shrimp, "/reef": reef}))
    assert t["facts"] == [{"tag": "grammar", "kind": "none_since", "path": "/reef", "round": 2},
                          {"tag": "logic", "kind": "none_since", "path": "/reef", "round": 2}]
    assert all(set(f) <= {"tag", "kind", "path", "round", "n", "of", "words"} for f in t["facts"])
    # the advisor's order, and only their visible tags: Logic first; Grammar hidden is never picked
    t = tags.student_tags(student({"/shrimp": shrimp, "/reef": reef}), ["logic", "praise", "wording"])
    assert [f["tag"] for f in t["facts"]] == ["logic"]
    t = tags.student_tags(student({"/shrimp": shrimp, "/reef": reef}), ["praise", "logic", "grammar"])
    assert [f["tag"] for f in t["facts"]] == ["logic", "grammar"]  # Well done is never a fact


def test_a_single_paper_gets_facts_against_the_words_put_in():
    rounds = [rd(1, "2026-03-01T10:00:00+08:00"), rd(2, "2026-03-20T10:00:00+08:00"),
              rd(3, "2026-04-10T10:00:00+08:00", added=380)]
    comments = [cm("R1-0{}".format(k), 1, [step(1), step(2, "resolved")], ["grammar"]) for k in range(1, 4)] + \
        [cm("R2-01", 2, [step(2), step(3, "resolved")], ["grammar"]), cm("R3-01", 3, [step(3)], ["logic"])]
    t = tags.student_tags(student({"/reef": (rounds, comments, {})}))
    assert t["facts"] == [{"tag": "grammar", "kind": "new_words", "path": "/reef", "round": 3, "n": 0,
                           "words": 380}]
    assert [r["added"] for r in t["rounds"]] == [0, 0, 380]


def test_for_the_next_draft_and_well_done():
    latest = {"R1-01": {"round": 3, "page": 6, "text": "These  results prove the drive.", "created": "2026-03-01T10:00:00+08:00"},
              "R2-01": {"round": 3, "page": 7, "text": "Snapping " * 40, "created": "2026-03-20T10:00:00+08:00"},
              "R1-05": {"round": 1, "page": 2, "text": "Nice.", "created": "2026-03-01T11:00:00+08:00"}}
    rounds = [rd(1, "2026-03-01T10:00:00+08:00"), rd(2, "2026-03-20T10:00:00+08:00"),
              rd(3, "2026-04-10T10:00:00+08:00", closed=False)]
    comments = [cm("R1-01", 1, [step(1), step(2, "follow_up"), step(3, "to_check")], ["logic"], note="“prove” 太强"),
                cm("R1-02", 1, [step(1), step(2, "resolved")], ["logic"]),
                cm("R1-03", 1, [step(1), step(2, "resolved")], ["grammar"]),
                cm("R1-04", 1, [step(1), step(2, "resolved")], ["grammar"]),
                cm("R2-01", 2, [step(2), step(3, "to_check")], ["logic"], note="Which shrimp?"),
                cm("R2-02", 2, [step(2), step(3, "resolved")], ["grammar"]),
                cm("R1-05", 1, [step(1), step(2, "resolved")], ["praise"], note="很好"),
                cm("R1-06", 1, [step(1), step(2, "resolved")], ["praise"]),
                cm("R1-07", 1, [step(1), step(2, "resolved")], ["praise"]),
                cm("R3-01", 3, [step(3)], ["clarity"]), cm("R3-02", 3, [step(3)], ["clarity"])]
    t = tags.student_tags(student({"/reef": (rounds, comments, latest)}))
    # Logic: 3 comments, 2 open + 1 followed up = 3; Grammar: 3, all closed, none in the latest round: 0; Clarity: 2
    # comments (too few); Well done never
    assert [(f["tag"], f["score"]) for f in t["focus"]] == [("logic", 3)]
    ex = t["focus"][0]["example"]
    assert ex == {"path": "/reef", "id": "R2-01", "round": 3, "page": 7, "note": "Which shrimp?",
                  "text": ("Snapping " * 40).strip()[:tags.EXAMPLE_MAX - 1] + "…"}  # the latest open one
    assert t["praise"] == {"comments": 3, "latest": {"path": "/reef", "id": "R1-05", "round": 1, "page": 2,
                                                     "note": "很好"}}  # the latest written
    assert t["by_tag"]["logic"]["papers"] == {"/reef": 3} and t["untagged"]["comments"] == 0
    # the advisor's order breaks a tie; a tag outside it is never picked
    comments += [cm("R2-0{}".format(k), 2, [step(2), step(3, "to_check")], ["wording"]) for k in (3, 4, 5)]
    t = tags.student_tags(student({"/reef": (rounds, comments, latest)}), ["wording", "logic", "grammar"])
    assert [(f["tag"], f["score"]) for f in t["focus"]] == [("wording", 3), ("logic", 3)]
    t = tags.student_tags(student({"/reef": (rounds, comments, latest)}), ["grammar", "logic"])
    assert [f["tag"] for f in t["focus"]] == ["logic"]


def test_students_get_their_writing_profile():
    """overview._students adds `tags` to each student, from every paper of theirs (the Student page)."""
    group = first_drafts([{"grammar": 8, "logic": 2}, {"grammar": 4, "logic": 2}, {"grammar": 2, "logic": 3}])
    items = [(path, ov) for path, ov, _ in group]
    [s] = overview._students(items, {}, __import__("datetime").date(2026, 10, 12))
    assert s["tags"]["first_drafts"]["trend"]["grammar"]["word"] == "fewer"
    assert s["tags"]["first_drafts"]["trend"]["logic"]["word"] == "same"
    assert [r["path"] for r in s["tags"]["rounds"]] == ["/p0", "/p1", "/p2"]
    assert s["tags"]["rounds"][0] == {"path": "/p0", "n": 1, "date": "2026-01-01", "pages": 10, "first": True,
                                      "closed": True, "added": 0, "new": 10, "untagged": 0,
                                      "by_tag": {"grammar": 8, "logic": 2}}
