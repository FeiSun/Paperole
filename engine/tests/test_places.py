"""A comment on several places (design/comments/PLAN.md §2, §6a; engine/CONTRACT.md amendment "Comments on places,
step 2"): one note and number, each place found again every round with its own state, the changes attached at each,
the advisor's words for how they relate, and final.pdf, the summary and the email at each place. Synthetic data
only."""
import json

import pymupdf
import pytest

from paperole import EngineError, api, ledger

QUIET = lambda _: None
TEX = ("\\documentclass{article}\n\\begin{document}\n\\section{Introduction}\n"
       "Our method improves accuracy by 4.1 points on the benchmark.\n\n"
       "\\section{Method}\nWe sort the problems from easy to hard.\n\n"
       "\\section{Results}\nThe gain is 3.7 points over the baseline.\n\\end{document}\n")


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


def sel(paper, n, phrase):
    doc = pymupdf.open(paper / "r{}/build/main.pdf".format(n))
    r = doc[0].search_for(phrase)[0]
    return {"page": 0, "rects": [[r.x0, r.y0, r.x1, r.y1]], "text": phrase}


def ledger_of(paper):
    return json.loads((paper / "ledger.json").read_text())


def comment_in(state, cid):
    return next(c for c in state["comments"] if c["id"] == cid)


def test_a_second_place_makes_one_comment_on_two(paper):
    cid = call("comment", paper=str(paper), note="These two numbers disagree.",
               **sel(paper, 1, "by 4.1 points"))["id"]
    assert ledger_of(paper)["schema"] == 1
    out = call("add_place", paper=str(paper), id=cid, kind="highlight", **sel(paper, 1, "3.7 points"))
    assert out["place"] == "b"
    lg = ledger_of(paper)
    assert lg["schema"] == 2
    c = next(c for c in lg["comments"] if c["id"] == cid)
    assert c["link"] == {"text": "", "places": [{"key": "b", "kind": "highlight", "added": 1}]}
    assert c["rounds"]["1"]["places"]["b"]["anchor"]["text"] == "3.7 points"
    s = comment_in(out["state"], cid)
    assert [p["key"] for p in s["places"]] == ["b"] and s["places"][0]["anchor_state"] == "new"
    assert s["places"][0]["name"] == "§3 Results" and s["name"] == "§1 Introduction"
    assert s["relation"] == ""
    call("edit_comment", paper=str(paper), id=cid, relation="  does not   match ")
    assert next(c for c in ledger_of(paper)["comments"] if c["id"] == cid)["link"]["text"] == "does not match"
    with pytest.raises(EngineError, match="one place"):
        other = call("comment", paper=str(paper), note="x", **sel(paper, 1, "easy to hard"))["id"]
        call("edit_comment", paper=str(paper), id=other, relation="repeats")


def test_places_reach_the_student(paper):
    cid = call("comment", paper=str(paper), note="These two numbers disagree. Which one is right?",
               **sel(paper, 1, "by 4.1 points"))["id"]
    call("add_place", paper=str(paper), id=cid, kind="highlight", **sel(paper, 1, "3.7 points"))
    call("edit_comment", paper=str(paper), id=cid, relation="does not match")
    call("finish", paper=str(paper))
    final = pymupdf.open(paper / "r1/final.pdf")
    words = " ".join(w[4] for w in final[1].get_text("words"))
    assert words.count(cid) >= 3  # a chip at each place, and the headers
    text = " ".join(final[1].get_text().split())
    assert "does not match · also §3 Results (p.1)" in text
    assert "does not match · see §1 Introduction (p.1)" in text
    assert text.count("These two numbers disagree. Which one is right?") == 1, "the note whole once, at the first"
    email = (paper / "r1/email.txt").read_text()
    assert '  p.1  "by 4.1 points"' in email and '  p.1  "3.7 points"' in email
    assert "  How the places relate: does not match" in email


def test_each_place_is_carried_with_its_own_state_and_edits(paper, tmp_path):
    cid = call("comment", paper=str(paper), note="Disagree.", **sel(paper, 1, "by 4.1 points"))["id"]
    call("add_place", paper=str(paper), id=cid, kind="highlight", **sel(paper, 1, "3.7 points"))
    call("finish", paper=str(paper))
    (tmp_path / "source/main.tex").write_text(TEX.replace("3.7 points", "4.1 points"))
    out = call("ingest", paper=str(paper), source=str(tmp_path / "source"))["state"]
    c = comment_in(out, cid)
    assert c["anchor_state"] == "unchanged" and c["places"][0]["anchor_state"] == "changed"
    assert c["places"][0]["changes"] and c["places"][0]["changes"][0] in c["changes"]
    ch = next(ch for ch in out["changes"] if ch["id"] == c["places"][0]["changes"][0])
    assert ch["attached_to"] == [cid] and ch["at"] == {cid: ["b"]} and not ch["unrequested"]
    # the summary says both pages once; the comment is answered once
    call("verdict", paper=str(paper), id=cid, verdict="verified")
    call("finish", paper=str(paper))
    assert "R1-01" in pymupdf.open(paper / "r2/final.pdf")[0].get_text()


def test_a_place_is_taken_off_or_placed_anew(paper):
    cid = call("comment", paper=str(paper), note="Disagree.", **sel(paper, 1, "by 4.1 points"))["id"]
    call("add_place", paper=str(paper), id=cid, kind="highlight", **sel(paper, 1, "3.7 points"))
    call("reanchor", paper=str(paper), id=cid, place="b", **sel(paper, 1, "easy to hard"))
    c = next(c for c in ledger_of(paper)["comments"] if c["id"] == cid)
    assert c["rounds"]["1"]["places"]["b"]["anchor"]["text"].startswith("easy to hard")
    call("remove_place", paper=str(paper), id=cid, place="b")
    c = next(c for c in ledger_of(paper)["comments"] if c["id"] == cid)
    assert "link" not in c and "places" not in c["rounds"]["1"]
    assert ledger_of(paper)["schema"] == 2, "never lowered"
    with pytest.raises(EngineError, match="no place b"):
        call("remove_place", paper=str(paper), id=cid, place="b")


def test_an_overall_comment_takes_no_places(paper):
    cid = call("comment", paper=str(paper), kind="overall", note="Too long.")["id"]
    with pytest.raises(EngineError, match="whole paper"):
        call("add_place", paper=str(paper), id=cid, kind="highlight", **sel(paper, 1, "3.7 points"))


def test_place_ids_sort_after_their_comment():
    assert sorted(["R1-02", "R1-01#b", "R1-01", "R1-01#c"], key=ledger.id_key) == ["R1-01", "R1-01#b", "R1-01#c",
                                                                                     "R1-02"]
