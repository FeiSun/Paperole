"""Overall comments and the ledger's schema 2 (engine/CONTRACT.md amendment "Comments on places, step 1"): a comment
on the whole paper has no place in any round, is carried as itself (never Not found), reaches the student at the top of
final.pdf's summary and in email.txt, and its first use makes the ledger schema 2, which an engine reading only
schema 1 refuses. Synthetic data only."""
import json

import pymupdf
import pytest

from paperole import EngineError, api, check, comments, ledger, render

QUIET = lambda _: None
TEX = ("\\documentclass{article}\n\\begin{document}\n\\section{Introduction}\n"
       "Small models are cheap to serve. We study how to train them well.\n\n"
       "\\section{Method}\nWe sort the problems from easy to hard.\n\\end{document}\n")


def call(method, **params):
    return getattr(api, method)(params, QUIET)


@pytest.fixture
def paper(tmp_path):
    src = tmp_path / "source"
    src.mkdir()
    (src / "main.tex").write_text(TEX)
    paper = tmp_path / "review"
    call("new", paper=str(paper), title="Synthetic draft", student="Test author")
    call("ingest", paper=str(paper), source=str(src))
    return paper


def _words(paper, n, phrase):
    """(page, rects, text) of a phrase in round n's PDF."""
    doc = pymupdf.open(paper / "r{}/build/main.pdf".format(n))
    rect = doc[0].search_for(phrase)[0]
    return 0, [[rect.x0, rect.y0, rect.x1, rect.y1]], phrase


def _ledger(paper):
    return json.loads((paper / "ledger.json").read_text())


def test_a_new_ledger_stays_schema_1_until_an_overall_comment(paper):
    page, rects, text = _words(paper, 1, "cheap to serve")
    call("comment", paper=str(paper), page=page, rects=rects, text=text, note="Say how cheap.")
    assert _ledger(paper)["schema"] == 1, "placed comments need nothing new"
    out = call("comment", paper=str(paper), kind="overall", note="The method needs a running example.",
               color="blue")
    c = next(c for c in out["state"]["comments"] if c["id"] == out["id"])
    assert c["kind"] == "overall"
    lg = _ledger(paper)
    assert lg["schema"] == 2
    rec = next(c for c in lg["comments"] if c["kind"] == "overall")["rounds"]["1"]
    assert (rec["anchor"], rec["anchor_state"], rec["method"]) == (None, "new", "overall")
    # deleted again, the ledger stays schema 2: a copy is never lowered
    call("delete_comment", paper=str(paper), id=out["id"])
    assert _ledger(paper)["schema"] == 2


def test_an_engine_reading_schema_1_refuses_a_schema_2_ledger(paper, monkeypatch):
    call("comment", paper=str(paper), kind="overall", note="Tighten the abstract.")
    assert ledger.load(paper)["schema"] == 2
    monkeypatch.setattr(ledger, "SCHEMA", 1)  # the official app's frozen engine
    with pytest.raises(EngineError, match="schema 2"):
        ledger.load(paper)
    assert [p["code"] for p in check.paper(paper)] == ["ledger_too_new"]
    monkeypatch.setattr(ledger, "SCHEMA", 2)
    assert ledger.load(paper)["schema"] == 2
    lg = ledger.load(paper)
    lg["schema"] = 3
    (paper / "ledger.json").write_text(json.dumps(lg))
    with pytest.raises(EngineError, match="schema 3"):
        ledger.load(paper)


def test_an_overall_comment_has_no_place_to_change(paper):
    cid = call("comment", paper=str(paper), kind="overall", note="Too long overall.")["id"]
    with pytest.raises(EngineError, match="whole paper"):
        call("edit_comment", paper=str(paper), id=cid, kind="highlight")
    page, rects, text = _words(paper, 1, "cheap to serve")
    with pytest.raises(EngineError, match="no place"):
        call("reanchor", paper=str(paper), id=cid, page=page, rects=rects, text=text)
    call("edit_comment", paper=str(paper), id=cid, note="Too long: cut a page.", color="pink")
    c = next(c for c in _ledger(paper)["comments"] if c["id"] == cid)
    assert (c["note"], c["color"], c["kind"]) == ("Too long: cut a page.", "pink", "overall")
    with pytest.raises(EngineError, match="on a place"):
        placed = call("comment", paper=str(paper), page=page, rects=rects, text=text, note="x")["id"]
        call("edit_comment", paper=str(paper), id=placed, kind="overall")


def test_an_overall_comment_is_carried_answered_and_sent(paper, tmp_path):
    cid = call("comment", paper=str(paper), kind="overall", note="The method needs a running example.")["id"]
    page, rects, text = _words(paper, 1, "cheap to serve")
    placed = call("comment", paper=str(paper), page=page, rects=rects, text=text, note="Say how cheap.")["id"]
    call("finish", paper=str(paper))
    summary = pymupdf.open(paper / "r1/final.pdf")[0].get_text()
    assert "Overall" in summary and "The method needs a running example." in summary
    assert summary.index("Overall") < summary.index("How to reply"), "first, before How to reply"
    toc = pymupdf.open(paper / "r1/final.pdf").get_toc()
    assert [t[1] for t in toc[:3]] == ["Summary", "Overall (1)", "{} · new".format(cid)]
    email = (paper / "r1/email.txt").read_text()
    assert "The method needs a running example." in email and email.index(cid) < email.index(placed)

    # round 2: the student answers with a note in the source; the comment is carried as itself
    (tmp_path / "source/main.tex").write_text(TEX.replace(
        "We sort the problems from easy to hard.",
        "We sort the problems from easy to hard, as in this example. % {} added a running example".format(cid)))
    out = call("ingest", paper=str(paper), source=str(tmp_path / "source"))["state"]
    c = next(c for c in out["comments"] if c["id"] == cid)
    lg = _ledger(paper)
    rec = next(c for c in lg["comments"] if c["id"] == cid)["rounds"]["2"]
    assert (rec["anchor"], rec["anchor_state"], rec["method"], rec["verdict"]) == (None, "overall", "overall", None)
    assert rec.get("student_note", {}).get("text") == "added a running example"
    assert c["kind"] == "overall"
    call("verdict", paper=str(paper), id=cid, verdict="reopened", note="Use it in Section 3 too.")
    call("finish", paper=str(paper))
    first = pymupdf.open(paper / "r2/final.pdf")[0].get_text()
    assert "Use it in Section 3 too." in first and first.index("Overall") < first.index("How to reply")
    assert cid in (paper / "r2/email.txt").read_text()

    # round 3: resolved, then reopened as any comment
    call("ingest", paper=str(paper), source=str(tmp_path / "source"))
    call("verdict", paper=str(paper), id=cid, verdict="verified")
    call("finish", paper=str(paper))
    call("ingest", paper=str(paper), source=str(tmp_path / "source"))
    call("revive", paper=str(paper), id=cid)
    rec = next(c for c in _ledger(paper)["comments"] if c["id"] == cid)["rounds"]["4"]
    assert (rec["anchor"], rec["anchor_state"], rec["revived"]["from"]) == (None, "overall", 3)


def test_the_summary_without_overall_comments_has_no_overall_block(paper):
    page, rects, text = _words(paper, 1, "cheap to serve")
    call("comment", paper=str(paper), page=page, rects=rects, text=text, note="Say how cheap.")
    call("finish", paper=str(paper))
    assert "Overall" not in pymupdf.open(paper / "r1/final.pdf")[0].get_text()


def test_overall_kind_constant_is_not_a_place_kind():
    assert comments.OVERALL not in comments.KINDS and comments.OVERALL in ledger.V2_KINDS
    assert render.LABELS["new"] == "new"


def test_an_overall_note_longer_than_a_page_goes_on_over_the_next(paper):
    note = " ".join("Sentence {} of a long overall note.".format(k) for k in range(220))
    call("comment", paper=str(paper), kind="overall", note=note)
    call("finish", paper=str(paper))
    final = pymupdf.open(paper / "r1/final.pdf")
    first = final.page_count - pymupdf.open(paper / "r1/build/main.pdf").page_count
    assert first >= 2 and [final[k].get_label() for k in range(first)] == \
        ["Summary {}".format(k + 1) for k in range(first)]
    words = " ".join(" ".join(w[4] for w in final[k].get_text("words")) for k in range(first))
    assert "Sentence 0 of" in words and "Sentence 219 of" in words, "never cut"
    for k in range(first):
        assert all(w[3] <= final[k].rect.height - 30 for w in final[k].get_text("words"))


def test_the_overview_says_whole_not_unplaced(paper):
    cid = call("comment", paper=str(paper), kind="overall", note="Too long.")["id"]
    out = api.overview_({"papers": [str(paper)]}, QUIET)
    text = json.dumps(out)
    assert '"whole"' in text, "an overall comment's place in the overview"
    entry = out["papers"][0] if isinstance(out.get("papers"), list) else out
    assert entry.get("unplaced", 0) == 0 or '"unplaced": 0' in text, cid
