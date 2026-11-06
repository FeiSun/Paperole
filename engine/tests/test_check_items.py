"""Check items (check_items.py; CONTRACT.md amendment "Checks to the student"): the checks that go to the student,
with ids A<n>-<seq>, states new, still and fixed, synced with the open round's checks.json, carried at ingest with
the student's "% A2-03" notes, the advisor's follow-up words, Mark as OK, and finish with and without them: final.pdf's
slate chips, highlights and margin boxes, the summary's section, To do, Key and outline, and email.txt. On the
synthetic fixture paper (tests/fixtures/paper), in temporary folders; checks.json is written by the test (its checks
are made up, their places real words of the PDF), so the rules are tested apart from checks.py's."""
import copy
import json
import os
import shutil
import subprocess
import sys

import pymupdf
import pytest

from conftest import FIXTURE, Engine, burned, quiet, select
from paperole import EngineError, api, check_items, checks, ledger, links, notes, prose, render

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
needs_tex = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")
SLATE = tuple(round(v, 2) for v in render._rgb(render.CHECK_FILL))
INK = tuple(round(v, 2) for v in render._rgb(render.CHECK_INK))


def _call(paper, method, **params):
    return api.METHODS[method](dict(params, paper=str(paper)), quiet)


@pytest.fixture(scope="module")
def built(tmp_path_factory):
    """A paper with round 1 of the fixture paper ingested, built once (each test works on a copy)."""
    paper = tmp_path_factory.mktemp("items") / "paper"
    _call(paper, "new", title="Warm pools", student="Lin Zhou")
    _call(paper, "ingest", source=str(FIXTURE / "v1"))
    return paper


@pytest.fixture
def paper(built, tmp_path):
    out = tmp_path / "paper"
    shutil.copytree(built, out)
    return out


def _pdf(paper, n):
    return str(paper / ledger.load(paper)["rounds"][n - 1]["build"]["pdf"])


def _place(paper, n, page, phrase, text=True):
    return {"page": page, "rects": select(_pdf(paper, n), page, phrase), "text": phrase if text else None}


def _check(code, text, places, ident=None, per_round=None):
    """A check as checks.json holds it; per_round: the round whose place alone knows it (its key ends in |r<n>)."""
    key = "{}|{}".format(code, ident if ident is not None else text) + ("|r{}".format(per_round) if per_round else "")
    return {"code": code, "group": checks.CODES[code], "text": text, "detail": "Found: {}.".format(text),
            "note": "Please fix: {}.".format(text), "places": places, "key": key}


def _write(paper, n, found):
    """Round n's checks.json, current, holding `found`."""
    checks.path(paper, n).write_text(json.dumps(
        {"schema": checks.SCHEMA, "version": checks.CHECKS, "parser": prose.PARSER, "links": links.LINKS,
         "table": True, "round": n, "checks": found}, ensure_ascii=False), encoding="utf-8")
    checks._load.cache_clear()


def _round1(paper):
    """Round 1's four checks: a spelling (its key the words), a doubled word and an overfull line (known by their
    places), a .bib entry without a year."""
    return [_check("spelling", "“minimise” 1× · “minimize” 1×", [_place(paper, 1, 0, "minimise the sum")],
                   ident="minimise"),
            _check("doubled_word", "“the the”", [_place(paper, 1, 0, "keep finished instances warm")], per_round=1),
            _check("no_year", "No year · [3]", [_place(paper, 1, 1, "Platforms built on OpenLambda")],
                   ident="oakes2018sock"),
            _check("overfull", "Overfull line · 3.0 pt too wide", [_place(paper, 1, 1, "Time is divided", False)],
                   per_round=1)]


def _ids(reply):
    return [(v["id"], v["state"]) for v in reply["items"]]


def _words(page):
    return " ".join(w[4] for w in page.get_text("words"))


# --- the syntax of a note, without TeX ------------------------------------------------------------------------

@pytest.mark.parametrize("comment, ids, text", [
    ("% A2-03 the journal spells it so", ["A2-03"], "the journal spells it so"),
    ("% a2-3: lower case, no leading zero", ["A2-03"], "lower case, no leading zero"),
    ("% [A1-03] in brackets", ["A1-03"], "in brackets"),
    ("% Ａ２－０３ 全角编号", ["A2-03"], "全角编号"),
    ("% R1-02, A1-03 both kinds", ["R1-02", "A1-03"], "both kinds"),
])
def test_check_ids_in_notes(comment, ids, text):
    assert notes.parse(comment[1:]) == (ids, text)


@pytest.mark.parametrize("comment", ["% A100 GPUs", "% A1 is the first", "% Also see R1-03", "% A2-D2"])
def test_comments_that_name_no_check(comment):
    assert notes.parse(comment[1:]) is None  # an A id malformed is no warning: "A100" is a GPU's name


# --- matching, on a ledger without TeX --------------------------------------------------------------------------

def _item(cid, check, state="new", n=1):
    return {"id": cid, "key": check["key"], "code": check["code"], "group": check["group"], "created_round": n,
            "rounds": {str(n): {"state": state, "text": check["text"], "detail": check["detail"],
                                "note": check["note"], "places": check["places"]}}}


def test_matching_by_key_place_and_text():
    """A check known by its place matches a carried item of its code also known by its place: by the first place's
    printed words, else by its text; never an item with a key of its own; a check marked OK makes no item."""
    def place(text):
        return [{"page": 0, "rects": [[72, 100, 120, 110]], "text": text}]
    old = [_check("doubled_word", "“the the”", place("the the"), per_round=1),
           _check("overfull", "Overfull line · 3.0 pt too wide", place(None), per_round=1),
           _check("overfull", "Overfull line · 5.0 pt too wide", place(None), per_round=1),
           _check("float_unreferenced", "Figure 4 · not referenced", place("Figure 4"), ident="fig:a")]
    lg = {"rounds": [{"n": 1, "last_seq": 0, "last_check_seq": 4}, {"n": 2, "last_seq": 0}],
          "check_items": {"A1-0{}".format(k): _item("A1-0{}".format(k), c) for k, c in enumerate(old, 1)},
          "checks_ok": {"spelling|data set": 1}}
    new = [_check("doubled_word", "“a a”", place("the the"), per_round=2),  # its place's words
           _check("overfull", "Overfull line · 5.0 pt too wide", place(None), per_round=2),  # its text
           _check("float_unreferenced", "Figure 4 · not referenced", place("Figure 4"), per_round=2),  # no label now
           _check("spelling", "“data set” 1× · “dataset” 1×", place("data set"), ident="data set")]  # marked OK
    check_items.sync(lg, 2, new, checks.GROUPS)
    items = lg["check_items"]
    assert {cid: it["rounds"]["2"]["state"] for cid, it in items.items()} == {
        "A1-01": "still", "A1-02": "fixed", "A1-03": "still", "A1-04": "fixed", "A2-01": "new"}
    assert items["A1-01"]["key"] == new[0]["key"] and items["A1-03"]["key"] == new[1]["key"]
    assert items["A2-01"]["key"] == new[2]["key"] and lg["rounds"][1]["last_check_seq"] == 1
    again = copy.deepcopy(lg)
    check_items.sync(again, 2, new, checks.GROUPS)
    assert again == lg  # idempotent


def test_failed_rule_pauses_prior_findings_without_losing_ids_or_notes():
    c = _check("spelling", "Synthetic spelling difference", [], ident="synthetic")
    lg = {"rounds": [{"n": 1, "last_seq": 0, "last_check_seq": 1}, {"n": 2, "last_seq": 0}],
          "check_items": {"A1-01": _item("A1-01", c)}}
    check_items.sync(lg, 2, [c], checks.GROUPS)
    item = lg["check_items"]["A1-01"]
    item["rounds"]["2"]["advisor_note"] = "Check the venue's spelling."
    check_items.sync(lg, 2, [], checks.GROUPS, failed={"spelling"})
    assert item["rounds"]["2"] == {"state": None, "advisor_note": "Check the venue's spelling."}
    assert check_items.views(lg, 2)["items"] == []  # no empty card for an unverified, paused finding
    check_items.sync(lg, 2, [c], checks.GROUPS)
    assert item["rounds"]["2"]["state"] == "still" and "advisor_note" in item["rounds"]["2"]
    check_items.sync(lg, 2, [], checks.GROUPS)
    assert item["rounds"]["2"]["state"] == "fixed"  # only a successful later scan establishes this


def test_a_slip_let_go_and_an_earlier_round():
    """Review 2026-11-01: a check known by its place that the advisor marked OK in round 2 (its key with |r2) is not
    sent again as new in round 3 when it is found once more (its place's words, else its text); an earlier round shows
    no Mark as OK made after it."""
    def place(text):
        return [{"page": 0, "rects": [[72, 100, 120, 110]], "text": text}]
    first = _check("doubled_word", "“the the”", place("the the"), per_round=1)
    lg = {"rounds": [{"n": 1, "last_seq": 0, "last_check_seq": 1}, {"n": 2, "last_seq": 0}, {"n": 3, "last_seq": 0}],
          "check_items": {"A1-01": _item("A1-01", first)}}
    second = _check("doubled_word", "“the the”", place("the the"), per_round=2)
    check_items.sync(lg, 2, [second], checks.GROUPS)
    assert lg["check_items"]["A1-01"]["rounds"]["2"]["state"] == "still"
    lg["checks_ok"] = {second["key"]: 2}  # the student's reason accepted in round 2
    third = _check("doubled_word", "“the the”", place("the the"), per_round=3)
    check_items.sync(lg, 3, [third], checks.GROUPS)
    assert sorted(lg["check_items"]) == ["A1-01"] and "3" not in lg["check_items"]["A1-01"]["rounds"]
    assert "last_check_seq" not in lg["rounds"][2]  # no new id
    assert check_items.view(lg, lg["check_items"]["A1-01"], 1)["ok"] is False  # marked later than round 1
    assert check_items.view(lg, lg["check_items"]["A1-01"], 2)["ok"] is True


# --- syncing round 1 ------------------------------------------------------------------------------------------

@needs_tex
def test_ids_sync_groups_and_rebuilt_checks(paper):
    with pytest.raises(EngineError, match=r"^The round's checks are not built yet\.$"):
        _call(paper, "check_items")
    found = _round1(paper)
    _write(paper, 1, found)
    reply = _call(paper, "check_items")
    assert set(reply) == {"round", "items", "closed"} and reply["round"] == 1
    # in checks' order (group, page, top), ids in the order found
    assert _ids(reply) == [("A1-03", "new"), ("A1-01", "new"), ("A1-02", "new"), ("A1-04", "new")]
    first = next(v for v in reply["items"] if v["id"] == "A1-01")
    assert first == {"id": "A1-01", "key": found[0]["key"], "code": "spelling", "group": "consistency",
                     "created_round": 1, "state": "new", "text": found[0]["text"], "detail": found[0]["detail"],
                     "note": found[0]["note"], "places": found[0]["places"], "ok": False, "carried": False,
                     "history": []}
    assert reply["closed"] == {"fixed": [], "ok": []}
    lg = ledger.load(paper)
    assert lg["rounds"][0]["last_check_seq"] == 4 and lg["rounds"][0]["check_groups"] == list(checks.GROUPS)
    assert lg["rounds"][0]["last_seq"] == 0  # comments' ids are their own
    # idempotent: the same checks write nothing
    assert _call(paper, "check_items") == reply and ledger.load(paper)["rev"] == lg["rev"]
    # a group not asked: its items made in this round go, and their ids are not given again
    reply = _call(paper, "check_items", groups=["typesetting", "bibliography"])
    assert _ids(reply) == [("A1-03", "new"), ("A1-02", "new"), ("A1-04", "new")]
    assert ledger.load(paper)["rounds"][0]["check_groups"] == ["bibliography", "typesetting"]
    assert _ids(_call(paper, "check_items"))[1] == ("A1-05", "new")  # the spelling again: a new id
    # checks built again without the overfull line (the round's paper fixed): its item goes
    _write(paper, 1, found[:3])
    assert [i for i, _ in _ids(_call(paper, "check_items"))] == ["A1-03", "A1-05", "A1-02"]
    assert sorted(ledger.load(paper)["check_items"]) == ["A1-02", "A1-03", "A1-05"]
    for bad in ("typesetting", ["layout"], [1]):
        with pytest.raises(EngineError, match=r"^groups is a list of references, bibliography, consistency, "
                                              r"typesetting, submission\.$"):
            _call(paper, "check_items", groups=bad)
    with pytest.raises(EngineError, match=r"^There is no round 4\.$"):
        _call(paper, "check_items", round=4)


@pytest.mark.parametrize("code", ["short_last_line", "paragraph_break", "heading_break", "split_phrase",
                                  "draft_marker", "sentence_start"])
def test_rule_switch_pauses_and_restores_the_same_item(paper, code):
    found = [_check(code, "Writing check", [_place(paper, 1, 0, "minimise the sum")])]
    _write(paper, 1, found)
    first = _call(paper, "check_items")["items"][0]
    reply = _call(paper, "check_items", disabled=[code])
    assert reply["items"] == [] and reply["closed"] == {"fixed": [], "ok": []}
    assert ledger.load(paper)["check_items"][first["id"]]["rounds"]["1"]["state"] is None
    restored = _call(paper, "check_items", disabled=[])["items"][0]
    assert restored["id"] == first["id"] and restored["state"] == "new"
    _call(paper, "finish", checks=True, disabled=[code])  # selection sent at Finish wins
    assert "Writing check" not in (paper / "r1/email.txt").read_text()
    assert _call(paper, "check_items", round=1, disabled=[])["items"] == []  # frozen as sent


def test_disabled_carried_rule_keeps_notes_and_is_not_fixed(paper):
    code = "sentence_start"
    found = [_check(code, "Writing check", [_place(paper, 1, 0, "minimise the sum")])]
    _write(paper, 1, found)
    cid = _call(paper, "check_items")["items"][0]["id"]
    _call(paper, "finish", checks=True)
    _call(paper, "ingest", source=str(FIXTURE / "v1"))
    _write(paper, 2, found)
    _call(paper, "check_items")
    _call(paper, "check_note", id=cid, text="Please keep this explanation.")
    with ledger.edit(paper) as lg:
        lg["check_items"][cid]["rounds"]["2"]["student_note"] = {"text": "This is intentional."}
    assert _call(paper, "check_items", disabled=[code])["items"] == []
    restored = _call(paper, "check_items")["items"][0]
    assert restored["id"] == cid and restored["state"] == "still"
    assert restored["advisor_note"] == "Please keep this explanation."
    assert restored["student_note"]["text"] == "This is intentional."
    # A pending scan cannot resurrect a rule just switched off at Finish.
    checks.path(paper, 2).unlink()
    _call(paper, "finish", checks=True, disabled=[code])
    lg = ledger.load(paper)
    assert lg["check_items"][cid]["rounds"]["2"]["state"] is None
    assert lg["rounds"][1]["checks_sent"] == lg["rounds"][1]["checks_fixed"] == 0
    assert "Writing check" not in (paper / "r2/email.txt").read_text()
    assert _call(paper, "check_items", round=1, disabled=[code])["items"][0]["id"] == cid


def test_check_selection_validation_and_no_groups_at_finish(paper):
    _write(paper, 1, _round1(paper))
    _call(paper, "check_items")
    for value in (None, "sentence_start", [1], ["not_a_rule"]):
        for method in ("check_items", "finish"):
            with pytest.raises(EngineError, match="disabled is a list of known check codes"):
                _call(paper, method, checks=True, disabled=value)
    assert not ledger.load(paper)["rounds"][0]["closed"]
    _call(paper, "check_items", groups=[])
    _call(paper, "finish", checks=True)
    assert ledger.load(paper)["rounds"][0]["checks_sent"] == 0


@needs_tex
def test_a_replaced_round_keeps_its_numbering(paper):
    _write(paper, 1, _round1(paper)[:2])
    assert len(_call(paper, "check_items")["items"]) == 2
    _call(paper, "ingest", source=str(FIXTURE / "v1"))  # the open round started again
    lg = ledger.load(paper)
    assert lg["check_items"] == {} and lg["rounds"][0]["last_check_seq"] == 2
    _write(paper, 1, _round1(paper)[:1])
    assert _ids(_call(paper, "check_items")) == [("A1-03", "new")]


@needs_tex
def test_finish_without_checks_sends_none_and_changes_nothing(paper, tmp_path):
    """Without checks, finish drops the round's records (the items made in it go) and writes what it wrote before
    them: the same final.pdf, page by page, and email.txt as a copy of the paper that never had check items."""
    twin = tmp_path / "twin"
    shutil.copytree(paper, twin)
    for p in (paper, twin):
        _call(p, "comment", page=0, rects=select(_pdf(p, 1), 0, "keep finished instances warm"), text="",
              note="Say which trace.")
    _write(paper, 1, _round1(paper))
    _call(paper, "check_items")
    state = _call(paper, "finish")["state"]
    _call(twin, "finish")
    lg = ledger.load(paper)
    assert lg["check_items"] == {} and "checks_sent" not in lg["rounds"][0] and state["round"]["checks_sent"] is None
    assert (paper / "r1" / "email.txt").read_text() == (twin / "r1" / "email.txt").read_text()
    a, b = pymupdf.open(paper / "r1" / "final.pdf"), pymupdf.open(twin / "r1" / "final.pdf")
    assert len(a) == len(b) and a.get_toc() == b.get_toc()
    for pa, pb in zip(a, b):
        assert pa.get_text("words") == pb.get_text("words") and pa.rect == pb.rect
        assert [(d["rect"], d.get("fill"), d.get("color")) for d in pa.get_drawings()] == \
            [(d["rect"], d.get("fill"), d.get("color")) for d in pb.get_drawings()]
        assert pa.read_contents() == pb.read_contents()


# --- two rounds -----------------------------------------------------------------------------------------------

def _source_with_notes(tmp_path, lines):
    """The fixture's v2 with the student's note lines before \\end{document}."""
    src = tmp_path / "v2"
    shutil.copytree(FIXTURE / "v2", src)
    main = src / "main.tex"
    main.write_text(main.read_text().replace("\\end{document}", "\n".join(lines) + "\n\\end{document}"))
    return src


@needs_tex
def test_two_rounds(paper, tmp_path):
    found = _round1(paper) + [_check("no_venue", "No venue · [5]", [_place(paper, 1, 1, "Platforms built on")],
                                     ident="akkus2018sand")]
    _write(paper, 1, found)
    _call(paper, "check_items")
    # Mark as OK before it is sent: it never goes out
    assert _call(paper, "check_ok", key=found[2]["key"]) == {"checks_ok": [found[2]["key"]]}
    reply = _call(paper, "check_items")
    assert next(v for v in reply["items"] if v["id"] == "A1-03")["ok"] is True
    state = _call(paper, "finish", checks=True)["state"]
    assert state["round"]["checks_sent"] == 4 and ledger.load(paper)["rounds"][0]["checks_sent"] == 4
    # A1-03 was never sent: it goes, and its key stays marked OK
    assert sorted(ledger.load(paper)["check_items"]) == ["A1-01", "A1-02", "A1-04", "A1-05"]
    _final_round1(paper, found)
    _call(paper, "check_ok", key=found[4]["key"])  # A1-05 marked OK once sent: closed (no change needed)

    # round 2: the student's notes on two checks, one closed, one never sent and one that does not exist
    src = _source_with_notes(tmp_path, ["% A1-01 minimise is the journal's spelling",
                                        "% A1-05 the venue is in the note", "% A1-03 the year is in the note",
                                        "% A1-09 what is this"])
    state = _call(paper, "ingest", source=str(src))["state"]
    lg = ledger.load(paper)
    assert lg["check_items"]["A1-01"]["rounds"]["2"] == {
        "state": None, "student_note": {"text": "minimise is the journal's spelling", "file": "main.tex",
                                        "line": lg["check_items"]["A1-01"]["rounds"]["2"]["student_note"]["line"]}}
    assert lg["check_items"]["A1-02"]["rounds"]["2"] == {"state": None}
    assert [(w["kind"], w["ids"], w["message"]) for w in state["note_warnings"]] == [
        ("closed", ["A1-05"], "A1-05 was closed in Round 1 (no change needed), so this note is ignored."),
        ("unknown", ["A1-03"], "There is no automatic check A1-03, so this note is ignored."),
        ("unknown", ["A1-09"], "There is no automatic check A1-09, so this note is ignored.")]
    assert "2" not in lg["check_items"]["A1-05"]["rounds"]  # closed: not carried
    reply = _call(paper, "check_items", round=1)  # a closed round as recorded
    assert _ids(reply) == [("A1-05", "new"), ("A1-01", "new"), ("A1-02", "new"), ("A1-04", "new")]

    # the advisor's follow-up on a carried check
    view = _call(paper, "check_note", id="A1-01", text="Use one spelling throughout.")
    assert view["advisor_note"] == "Use one spelling throughout." and view["carried"] is True
    assert view["student_note"]["text"] == "minimise is the journal's spelling"
    assert view["history"] == [{"round": 1, "state": "new"}] and view["state"] is None
    assert "advisor_note" not in _call(paper, "check_note", id="A1-02", text="  ")
    for cid in ("A1-03", "A1-05", "A1-07"):
        with pytest.raises(EngineError, match=r"^{} is not a check carried into Round 2 and open there\.$".format(cid)):
            _call(paper, "check_note", id=cid, text="x")
    with pytest.raises(EngineError, match=r"^Round 2 already has comments or verdicts\."):
        _call(paper, "ingest", source=str(src))  # the advisor's words on a check
    assert ledger.load(paper)["check_items"]["A1-01"]["rounds"]["2"]["advisor_note"]

    # round 2's checks: the spelling by its key, the doubled word by its place's words (its key names round 2), the
    # overfull line no more (fixed), the two marked OK (no item), a new check
    found2 = [_check("spelling", "“minimise” 2× · “minimize” 1×", [_place(paper, 2, 0, "minimise the sum")],
                     ident="minimise"),
              _check("doubled_word", "“the the”", [_place(paper, 2, 0, "keep finished instances warm")], per_round=2),
              _check("no_year", "No year · [3]", [_place(paper, 2, 1, "Platforms built on OpenLambda")],
                     ident="oakes2018sock"),
              _check("undefined_ref", "Undefined reference fig:old", [_place(paper, 2, 0, "minimise the sum")],
                     ident="fig:old"),
              dict(found[4], places=[_place(paper, 2, 1, "Platforms built on")])]
    _write(paper, 2, found2)
    reply = _call(paper, "check_items")
    assert _ids(reply) == [("A2-01", "new"), ("A1-01", "still"), ("A1-02", "still"), ("A1-04", "fixed")]
    a1 = reply["items"][1]
    assert a1["text"] == found2[0]["text"] and a1["carried"]
    assert a1["advisor_note"] == "Use one spelling throughout." and a1["student_note"]["text"]
    assert reply["items"][2]["key"] == found2[1]["key"]  # matched by its place: its key now round 2's
    assert reply["items"][3]["places"] == [] and reply["items"][3]["text"] == "Overfull line · 3.0 pt too wide"
    assert reply["closed"] == {"fixed": ["A1-04"], "ok": []}
    assert sorted(ledger.load(paper)["check_items"]) == ["A1-01", "A1-02", "A1-04", "A1-05", "A2-01"]
    # marked OK after it was sent: closed as no change needed
    _call(paper, "check_ok", key=found2[1]["key"])
    reply = _call(paper, "check_items")
    assert reply["closed"] == {"fixed": ["A1-04"], "ok": ["A1-02"]}
    email = _call(paper, "email_preview", checks=True)["text"]
    state = _call(paper, "finish", checks=True)["state"]
    assert state["round"]["checks_sent"] == 2
    assert (paper / "r2" / "email.txt").read_text() == email
    _final_round2(paper, email)


def _final_round1(paper, found):
    final, build = pymupdf.open(paper / "r1" / "final.pdf"), pymupdf.open(_pdf(paper, 1))
    k = len(final) - len(build)  # the summary's pages
    summary = " ".join(_words(final[j]) for j in range(k))
    summary = summary.replace("\xa0", " ")
    assert "Automatic checks (4)" in summary and "4 to do of 4 checks" in summary  # the checks are to do too
    assert "or % A1-01 for an automatic check." in summary
    assert "Paperole found these, not me, and it can be wrong." in summary
    assert "Consistency + A1-01 p.1 “minimise” 1× · “minimize” 1×" in summary
    assert "Still open" not in summary and "Fixed since" not in summary  # a first round's checks are all new
    # the paper's pages: the slate highlight over each place, a square slate chip, the margin box
    page = final[k]
    assert ("highlight", SLATE) in burned(page, found[0]["places"][0]["rects"])
    assert ("highlight", SLATE) in burned(page, found[1]["places"][0]["rects"])
    chips = [d for d in page.get_drawings() if d.get("fill") and tuple(round(v, 2) for v in d["fill"]) == INK
             and {i[0] for i in d["items"]} == {"re"} and abs(d["rect"].height - render.CHIP_H) < 0.8]
    assert len(chips) == 2  # A1-01's and A1-02's, square
    words = _words(page)
    for cid in ("A1-01", "A1-02"):
        assert "{} · new · automatic check".format(cid) in words
    assert "Please fix: “minimise” 1× · “minimize” 1×." in words  # the note, not also the detail
    assert "Found: “minimise” 1× · “minimize” 1×." not in words
    assert "Fix it, or reply" in words and "Found by Paperole" not in words  # the summary says it may be wrong
    assert "A1-03" not in " ".join(_words(p) for p in final)  # marked OK before it was sent
    toc = final.get_toc()
    assert [1, "Automatic checks (4)", 1] in toc and [2, "A1-01 · new · p.1", k + 1] in toc
    assert [2, "A1-04 · new · p.2", k + 2] in toc
    email = (paper / "r1" / "email.txt").read_text()
    assert "or % A1-01 for an automatic check." in email
    assert "\nAutomatic checks (4)\nA1-05  p.2  No venue · [5]\n  Please fix: No venue · [5].\n" \
           "A1-01  p.1  “minimise” 1× · “minimize” 1×\n  Please fix: “minimise” 1× · “minimize” 1×.\n" in email


def _final_round2(paper, email):
    final, build = pymupdf.open(paper / "r2" / "final.pdf"), pymupdf.open(_pdf(paper, 2))
    k = len(final) - len(build)
    summary = " ".join(_words(final[j]) for j in range(k)).replace("\xa0", " ")
    assert "Automatic checks (2)" in summary and "Still open (1)" in summary and "New (1)" in summary
    assert summary.index("Still open (1)") < summary.index("New (1)")
    assert "Fixed since Round 1: A1-04." in summary and "No change needed: A1-02." in summary
    words = _words(final[k])
    assert "A1-01 · still open · automatic check" in words and "Me: Use one spelling throughout." in words
    assert "A2-01 · new · automatic check" in words and "A1-02 · still" not in words
    assert "\nAutomatic checks (2)\n" in email and "  Me: Use one spelling throughout.\n" in email
    assert "\nClosed: A1-02 (no change needed); A1-04 (fixed)\n" in email


# --- the RPC and the CLI ----------------------------------------------------------------------------------------

@needs_tex
def test_rpc_and_cli(paper):
    _write(paper, 1, _round1(paper))
    eng = Engine()
    try:
        eng.send(json.dumps({"id": 1, "method": "check_items", "params": {"paper": str(paper)}}))
        reply = eng.reply(1)["result"]
        assert set(reply) == {"round", "items", "closed"} and len(reply["items"]) == 4
        eng.send(json.dumps({"id": 2, "method": "check_note", "params": {"paper": str(paper), "id": "A1-01",
                                                                          "text": "x"}}))
        assert eng.reply(2)["error"]["message"] == "A1-01 is not a check carried into Round 1 and open there."
    finally:
        assert eng.close()[0] == 0
    out = subprocess.run([sys.executable, "-m", "paperole.cli", "check-items", str(paper), "--groups", "consistency"],
                         capture_output=True, text=True, encoding="utf-8", timeout=120)
    assert out.returncode == 0 and [v["id"] for v in json.loads(out.stdout)["items"]] == ["A1-01"]
    out = subprocess.run([sys.executable, "-m", "paperole.cli", "finish", str(paper), "--checks"],
                         capture_output=True, text=True, encoding="utf-8", timeout=300)
    assert out.returncode == 0 and json.loads(out.stdout)["state"]["round"]["checks_sent"] == 1
    out = subprocess.run([sys.executable, "-m", "paperole.cli", "check-note", str(paper), "A1-01", "words"],
                         capture_output=True, text=True, encoding="utf-8", timeout=120)
    assert out.returncode == 1 and "There is no open round." in out.stderr
