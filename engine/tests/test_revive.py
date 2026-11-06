"""Reopen: a comment closed in an earlier round that the student later broke comes back into the open round as To
check (CONTRACT.md amendment "Tags, key page and Reopen"; design/tags/TAGS.md §9 with the critique's fixes). The
engine calls it `revive`, since the verdict `reopened` is Follow up. Synthetic paper only: placement from the round it
was closed in, the changes attached, the hint on edits near closed comments, undo, refusals, the email's and
final.pdf's words, the overview, and carrying it on afterwards."""
import json
import os
import random
import shutil

import pymupdf
import pytest

from conftest import quiet, select
from paperole import EngineError, api, ledger, overview, render

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

VOCAB = ("reef shrimp snap chorus dawn dusk hydrophone station night moon tide coral sand depth band pulse level "
         "season colony burrow echo signal noise survey record peak").split()


def sentence(tag, i, word=None):
    rng = random.Random("{}-{}".format(tag, i))
    words = [rng.choice(VOCAB) for _ in range(12)]
    if word:
        words[3] = word
    return " ".join(words) + "."


def para(tag, edit=None):
    """Three sentences of its own, starting with its tag; edit: {sentence index: a word put in at word 4}."""
    edit = edit or {}
    return tag.capitalize() + " " + " ".join(sentence(tag, i, edit.get(i)) for i in range(3))


def source(root, paras, notes=None):
    """main.tex with three sections of the given paragraphs ({tag: edit}; a tag left out is deleted), and the student's
    note lines after paragraphs ({tag: "% R1-01 …"})."""
    notes = notes or {}
    root.mkdir(parents=True)
    secs = [("Introduction", ["opening", "context"]), ("Methods", ["sampling", "hydro"]),
            ("Results", ["chorus", "timing"])]

    def text(g):
        return para(g, paras[g]) + ("\n" + notes[g] if g in notes else "")
    body = "".join("\\section{{{}}}\n\n{}\n\n".format(t, "\n\n".join(text(g) for g in tags if g in paras))
                   for t, tags in secs)
    (root / "main.tex").write_text("\\documentclass{article}\n\\hyphenpenalty=10000\n\\sloppy\n\\begin{document}\n"
                                   + body + "\\end{document}\n")
    return root


def first_words(tag, k=4):
    return " ".join(para(tag).split()[:k])


def call(method, **params):
    return api.METHODS[method](params, quiet)


def comment(paper, phrase, note):
    n = ledger.open_round(ledger.load(paper))["n"]
    pdf = paper / "r{}".format(n) / "build" / "main.pdf"
    doc = pymupdf.open(str(pdf))
    for page in range(doc.page_count):
        try:
            rects = select(str(pdf), page, phrase)
        except AssertionError:
            continue
        return call("comment", paper=str(paper), page=page, rects=rects, text=phrase, note=note,
                    kind="highlight")["id"]
    raise AssertionError(phrase)


ALL = {"opening": None, "context": None, "sampling": None, "hydro": None, "chorus": None, "timing": None}


@pytest.fixture(scope="module")
def reef_template(tmp_path_factory):
    """Round 1: A on Sampling's first sentence, B on Chorus's, C on Opening's. Round 2: the student fixes A's sentence;
    the advisor resolves A, keeps B as is, leaves C open. Round 3 (open): the student edits A's sentence again and
    deletes Chorus (B's paragraph); C is untouched. Copy it before changing it."""
    root = tmp_path_factory.mktemp("reef")
    paper = root / "paper"
    v1 = source(root / "v1", ALL)
    v2 = source(root / "v2", dict(ALL, sampling={0: "fixed"}))
    v3 = source(root / "v3", dict({k: v for k, v in ALL.items() if k != "chorus"}, sampling={0: "broken"}),
                {"sampling": "% R1-01 I made it shorter."})
    call("new", paper=str(paper), title="Reef choruses", student="Mei Lin")
    call("ingest", paper=str(paper), source=str(v1))
    ids = {"A": comment(paper, first_words("sampling"), "Too long."),
           "B": comment(paper, first_words("chorus"), "Which station?"),
           "C": comment(paper, first_words("opening"), "Start with the question.")}
    call("finish", paper=str(paper))
    call("ingest", paper=str(paper), source=str(v2))
    call("verdict", paper=str(paper), id=ids["A"], verdict="verified", note="Good.")
    call("verdict", paper=str(paper), id=ids["B"], verdict="wontfix")
    call("finish", paper=str(paper))
    call("ingest", paper=str(paper), source=str(v3))
    return paper, ids, v3


@pytest.fixture
def reef(reef_template, tmp_path):
    template, ids, v3 = reef_template
    paper = tmp_path / "paper"
    shutil.copytree(template, paper)
    return paper, ids, v3


def test_edits_near_closed_comments_are_named(reef):
    paper, ids, _ = reef
    state = call("state", paper=str(paper))["state"]
    near = {ch["id"]: ch["near_closed"] for ch in state["changes"] if ch["near_closed"]}
    assert sorted(e["id"] for es in near.values() for e in es) == sorted([ids["A"], ids["B"]])
    for es in near.values():
        for e in es:
            want = {ids["A"]: "verified", ids["B"]: "wontfix"}[e["id"]]
            assert e == {"id": e["id"], "round": 2, "verdict": want, "revivable": True}
    assert all(ch["unrequested"] for ch in state["changes"] if ch["near_closed"])  # no open comment asked for them
    shadows = json.loads((paper / "r3" / "analysis.json").read_text())["shadows"]
    assert set(shadows) == {ids["A"]}  # B's words are all deleted: it is not followed further
    assert shadows[ids["A"]]["closed"] == 2 and shadows[ids["A"]]["verdict"] == "verified"
    assert shadows[ids["A"]]["anchor"]["quote"] == first_words("sampling")
    c = next(c for c in state["comments"] if c["id"] == ids["C"])
    assert c["revivable"] is False and c["revived"] is None  # open: it is in Round 3 already
    past = call("state", paper=str(paper), round=2)["state"]
    assert {c["id"]: c["revivable"] for c in past["comments"]} == {ids["A"]: True, ids["B"]: True, ids["C"]: False}


def test_edits_near_comments_closed_long_ago_in_an_older_folder(reef, tmp_path):
    """Round 3's analysis.json written before shadows: at Round 4's ingest, A (closed in Round 2) is followed from
    Round 2 by a diff of its own, C (closed in Round 3) from its Round-3 anchor; edits in both sentences name them."""
    paper, ids, _ = reef
    p = str(paper)
    call("verdict", paper=p, id=ids["C"], verdict="verified")
    call("finish", paper=p)
    analysis = paper / "r3" / "analysis.json"
    data = json.loads(analysis.read_text())
    del data["shadows"]
    analysis.write_text(json.dumps(data))
    v4 = source(tmp_path / "v4", dict({k: v for k, v in ALL.items() if k != "chorus"}, sampling={0: "again"},
                                      opening={0: "again"}))
    state = call("ingest", paper=p, source=str(v4))["state"]
    near = sorted((e["id"], e["round"]) for ch in state["changes"] for e in ch["near_closed"])
    assert near == [(ids["A"], 2), (ids["C"], 3)]
    shadows = json.loads((paper / "r4" / "analysis.json").read_text())["shadows"]
    assert {cid: s["closed"] for cid, s in shadows.items()} == {ids["A"]: 2, ids["C"]: 3}


def test_shadows_that_failed_are_derived_at_the_next_round(reef, tmp_path, monkeypatch):
    """The code audit: a failure of the hint at Round 4's ingest wrote "shadows": {}, and Round 5 took that as all
    there is, so every comment closed before lost its hint for good. Now the key is left out, and Round 5 derives them
    from the rounds they were closed in."""
    from paperole import anchor
    paper, ids, _ = reef
    p = str(paper)
    call("verdict", paper=p, id=ids["C"], verdict="verified")
    call("finish", paper=p)
    real = anchor.shadows

    def broken(*a, **k):
        raise RuntimeError("synthetic failure")
    monkeypatch.setattr(anchor, "shadows", broken)
    keep = dict({k: v for k, v in ALL.items() if k != "chorus"}, sampling={0: "broken"})
    call("ingest", paper=p, source=str(source(tmp_path / "v4", keep)))
    assert "shadows" not in json.loads((paper / "r4" / "analysis.json").read_text())
    monkeypatch.setattr(anchor, "shadows", real)
    call("finish", paper=p)
    v5 = source(tmp_path / "v5", dict(keep, sampling={0: "again"}, opening={0: "again"}))
    state = call("ingest", paper=p, source=str(v5))["state"]
    near = sorted((e["id"], e["round"]) for ch in state["changes"] for e in ch["near_closed"])
    assert near == [(ids["A"], 2), (ids["C"], 3)]
    shadows = json.loads((paper / "r5" / "analysis.json").read_text())["shadows"]
    assert {cid: s["closed"] for cid, s in shadows.items()} == {ids["A"]: 2, ids["C"]: 3}


def test_revive_brings_a_closed_comment_back_to_check_and_on(reef):
    paper, ids, v3 = reef
    p, a, b, c = str(paper), ids["A"], ids["B"], ids["C"]
    with pytest.raises(EngineError, match="R1-03 is still open; it is in Round 3 already"):
        call("revive", paper=p, id=c)
    with pytest.raises(EngineError, match="There is no comment R9-01"):
        call("revive", paper=p, id="R9-01")
    [w] = call("state", paper=p)["state"]["note_warnings"]
    assert (w["kind"], w["ids"], w["message"]) == ("closed", [a], "R1-01 was closed in Round 2 (resolved), so this note "
                                                                 "is ignored.")
    state = call("revive", paper=p, id=a)["state"]
    assert state["note_warnings"][0]["message"] == ("R1-01 was closed when this source was read, so this note was not "
                                                    "attached to it; you reopened it later.")
    with pytest.raises(EngineError, match="R1-01 is already in Round 3"):
        call("revive", paper=p, id=a)
    with pytest.raises(EngineError, match="Round 3 already has comments or verdicts"):
        call("ingest", paper=p, source=str(v3))  # a reopened comment is the advisor's work in the round
    got = next(x for x in state["comments"] if x["id"] == a)
    assert got["revived"]["from"] == 2 and got["verdict"] is None and got["revivable"] is False
    assert got["anchor_state"] == "changed"  # since Round 2, where it was closed: its sentence was edited
    assert [h["round"] for h in got["history"]] == [1, 2] and got["history"][1]["verdict"] == "verified"
    assert got["context"]["against"] == 2
    assert got["old_quote"] == got["new_quote"] == first_words("sampling")
    edit = next(ch for ch in state["changes"] if a in ch["attached_to"])
    assert not edit["unrequested"] and edit["near_closed"] == [] and got["changes"] == [edit["id"]]
    assert "broken" in edit["new_text"]
    assert state["summary"]["to_judge"] == 2  # A and C to check
    assert set(ledger.get_comment(ledger.load(paper), a)["rounds"]["3"]["revived"]) == {"from", "at"}

    # B's paragraph was deleted: it comes back gone; undo takes it out again, and the edit is nobody's again
    state = call("revive", paper=p, id=b)["state"]
    got = next(x for x in state["comments"] if x["id"] == b)
    assert got["anchor_state"] == "gone" and got["revived"]["from"] == 2
    state = call("revive", paper=p, id=b, undo=True)["state"]
    assert b not in {x["id"] for x in state["comments"]}
    assert all(b not in ch["attached_to"] for ch in state["changes"])
    assert any(b in [e["id"] for e in ch["near_closed"]] and ch["unrequested"] for ch in state["changes"])
    with pytest.raises(EngineError, match="R1-03 was not reopened in Round 3"):
        call("revive", paper=p, id=c, undo=True)

    # the email: Reopened first, where it was closed, then the follow-up once written; never among the follow-ups
    lg = ledger.load(paper)
    assert render._groups(lg, 3)[0] == [ledger.get_comment(lg, a)] and render._groups(lg, 3)[1] == []
    text = call("email_preview", paper=p)["text"]
    assert text.index("Reopened (1)") < text.index("Still open (1)") and "Follow-ups" not in text
    assert "  Too long.\n  Closed in Round 2 (resolved), reopened in Round 3.\n" in text
    call("verdict", paper=p, id=a, verdict="reopened", note="Shorter again, please.")
    assert render._groups(ledger.load(paper), 3)[1] == []  # followed up, it stays Reopened
    text = call("email_preview", paper=p)["text"]
    assert "Closed in Round 2 (resolved), reopened in Round 3.\n  Round 3: Shorter again, please.\n" in text
    assert "Follow-ups" not in text
    # reopened and resolved again in the same round: closed as any
    call("revive", paper=p, id=b)
    call("verdict", paper=p, id=b, verdict="verified")
    text = call("email_preview", paper=p)["text"]
    assert "Closed: {} (resolved)".format(b) in text and "Reopened (1)" in text

    ov = overview.paper_overview(paper)
    r2, r3 = (next(r for r in ov["rounds"] if r["n"] == n) for n in (2, 3))
    assert r3["comments"]["revived"] == 2 and r3["comments"]["carried"] == r2["comments"]["open_after"] + 2
    cs = {x["id"]: x for x in ov["comments"]}
    assert cs[a]["revived"] == [{"round": 3, "from": 2}] and [s[0] for s in cs[a]["path"]] == [1, 2, 3]
    assert cs[a]["path"][-1][5:] == ["edited", "follow_up"]
    assert cs[c]["revived"] == [] and not cs[c]["revivable"] and not cs[a]["revivable"]
    assert ov["threads"]["revived"] == 2 and ov["threads"]["open"] == 2  # A (open again) and C
    assert ov["tags"]["by_tag"] == {} and ov["tags"]["untagged"]["revived"] == 2

    # finish: the student's words, and no circular arrow
    state = call("finish", paper=p)["state"]
    assert state["round"]["email"] == text
    doc = pymupdf.open(str(paper / "r3" / "final.pdf"))
    assert "reopened" in doc[0].get_text().split("\n")  # its row's status word
    assert "{} · reopened".format(a) in "".join(page.get_text() for page in doc)
    page = cs[a]["path"][-1][2]
    assert [3 - 1, "{} · reopened · p.{}".format(a, page + 1)] in [t[:2] for t in doc.get_toc()]

    # Round 4: carried as any comment, its reopening in its history
    state = call("ingest", paper=p, source=str(v3))["state"]
    got = next(x for x in state["comments"] if x["id"] == a)
    assert got["revived"] is None and got["verdict"] is None and got["anchor_state"] == "unchanged"
    assert [h["round"] for h in got["history"]] == [1, 2, 3] and got["history"][2]["revived"]["from"] == 2
    assert got["context"]["against"] == 3  # its follow-up's round
    text = call("email_preview", paper=p)["text"]
    assert "Reopened" not in text and "Still open (2)" in text
    assert "Round 3 (follow-up): Shorter again, please." in text
    ov = overview.paper_overview(paper)
    assert next(x for x in ov["comments"] if x["id"] == a)["path"][-1][5] == "untouched"
    assert next(r for r in ov["rounds"] if r["n"] == 4)["comments"]["revived"] == 0


def test_revive_needs_an_open_round_with_a_pdf(tmp_path):
    paper = tmp_path / "paper"
    v1 = source(tmp_path / "v1", ALL)
    call("new", paper=str(paper), title="T", student="S")
    with pytest.raises(EngineError, match="There is no round yet"):
        call("revive", paper=str(paper), id="R1-01")
    call("ingest", paper=str(paper), source=str(v1))
    a = comment(paper, first_words("sampling"), "x")
    with pytest.raises(EngineError, match="R1-01 was written in Round 1"):
        call("revive", paper=str(paper), id=a)
    call("finish", paper=str(paper))
    with pytest.raises(EngineError, match="Round 1 is closed: import the next draft first"):
        call("revive", paper=str(paper), id=a)
    broken = tmp_path / "v2"
    broken.mkdir()
    (broken / "main.tex").write_text("\\documentclass{article}\n\\begin{document}\n\\textbf{\n")
    call("ingest", paper=str(paper), source=str(broken))
    assert ledger.latest_round(ledger.load(paper))["build"]["pdf"] is None
    with pytest.raises(EngineError, match="Round 2 has no PDF \\(the build failed\\): there is nothing to place R1-01"):
        call("revive", paper=str(paper), id=a)


def test_a_closing_remark_is_not_repeated_under_an_open_comment():
    """render._verdict_note without TeX: a comment resolved with a remark in Round 2, reopened in Round 4 and left
    without a word, is still open in Round 5: its email entry does not say "Round 2 (resolved): …"; an earlier
    follow-up still is said."""
    def rec(verdict=None, note="", **extra):
        return dict({"anchor": None, "verdict": verdict, "verdict_note": note}, **extra)
    c = {"id": "R1-05", "created_round": 1, "note": "Too strong.",
         "rounds": {"1": rec(), "2": rec("verified", "Good."), "4": rec(revived={"from": 2, "at": "x"}), "5": rec()}}
    assert render._verdict_note(c, 5) == ""
    c["rounds"]["4"] = rec("reopened", "Again.", revived={"from": 2, "at": "x"})
    assert render._verdict_note(c, 5) == "Round 4 (follow-up): Again."
    assert render._status(c, 4) == "revived" and render._status(c, 5) is None


def test_revivable_and_require_revivable_state_one_rule():
    """comments.revivable (the app's Reopen buttons) is true exactly when comments.require_revivable (the revive
    call) gives no reason, over the rounds and records a comment can have."""
    from paperole import comments

    def rec(verdict=None, **extra):
        return dict({"anchor": None, "verdict": verdict, "verdict_note": ""}, **extra)
    rounds = {"none": [], "open": [{"n": 1, "closed": True, "build": {"pdf": "p"}},
                                   {"n": 2, "closed": False, "build": {"pdf": "p"}}]}
    rounds["closed"] = [dict(r, closed=True) for r in rounds["open"]]
    rounds["no pdf"] = [rounds["open"][0], dict(rounds["open"][1], build={"pdf": None})]
    records = {"closed in 1": (1, {"1": rec("verified")}), "kept in 1": (1, {"1": rec("wontfix")}),
               "follow-up in 1": (1, {"1": rec("reopened")}), "open in 1": (1, {"1": rec()}),
               "carried": (1, {"1": rec(), "2": rec()}), "revived": (1, {"1": rec("verified"), "2": rec(revived={})}),
               "written in 2": (2, {"2": rec()})}
    seen = set()
    for rname, rs in rounds.items():
        for cname, (created, recs) in records.items():
            c = {"id": "R{}-01".format(created), "created_round": created, "rounds": recs}
            lg = {"rounds": rs, "comments": [c]}
            try:
                comments.require_revivable(lg, c["id"])
                why = None
            except EngineError as e:
                why = str(e)
            assert comments.revivable(lg, c) is (why is None), (rname, cname, why)
            seen.add(why is None)
    assert seen == {True, False}
