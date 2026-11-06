"""M2a: mark colours and kinds, box comments, re-anchoring, and the card contexts (cards.py) on the fixture paper and
on small synthetic layouts."""
import json
import os
import shutil

import pymupdf
import pytest

from conftest import FIXTURE, burned, equation_rect, quiet, select
from paperole import EngineError, anchor, api, cards, comments, ledger, project, render, texdiff

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
FIGURE = [119.0, 175.0, 493.0, 362.0]  # Figure 1's picture on page 2 of the v1 PDF (and of v2)
TABLE = [150.0, 80.0, 462.0, 160.0]  # Table 1 with its caption, page 2 of the v1 PDF


def call(method, **params):
    return api.METHODS[method](params, quiet)


def comment(paper, page, rects, kind="highlight", note="", **extra):
    """(id, state comment) of a new comment."""
    r = call("comment", paper=str(paper), page=page, rects=rects, text="", note=note, kind=kind, **extra)
    return r["id"], next(c for c in r["state"]["comments"] if c["id"] == r["id"])


def marked(ctx):
    """The context's text with its marked spans in [[ ]] and the deletion point as ‸."""
    text = ctx["text"]
    for s, e in reversed(ctx["sel"]):
        text = text[:s] + "[[" + text[s:e] + "]]" + text[e:]
    if ctx["cut"] is not None:
        text = text[:ctx["cut"]] + "‸" + text[ctx["cut"]:]
    return text


def word(text, x0, y0, block, line, k=0, width=None, height=10.0):
    return (x0, y0, x0 + (width or 6.0 * len(text)), y0 + height, text, block, line, k)


def test_sentence_ends():
    for w, nxt, ends in [("results.", "The", True), ("done?", "We", True), ("2024).", "We", True),
                         ('"quoted."', "Next", True), ("end.", "the", False), ("e.g.", "Transformers", False),
                         ("al.", "(2020)", False), ("Fig.", "3", False), ("Eq.", "(2)", False), ("Sec.", "4", False),
                         ("J.", "Smith", False), ("U.S.", "Army", False), ("i.e.", "Lower", False), ("3.5", "The", False),
                         ("size", "The", False), ("k.", "The", True)]:
        assert cards._ends(w, nxt) == ends, (w, nxt)


def test_paragraphs_and_columns():
    """Two columns: a sentence flows from the bottom of the left column to the top of the right one; text in a figure
    at the top of a column, a heading after a gap, and a bullet start new paragraphs."""
    left = [word("The", 70, 700, 0, 0), word("results", 100, 700, 0, 0, 1), word("hold", 160, 700, 0, 0, 2),
            word("whenever", 200, 700, 0, 0, 3, width=90)]
    right = [word("the", 306, 72, 1, 0), word("pool", 330, 72, 1, 0, 1), word("is", 370, 72, 1, 0, 2),
             word("warm.", 400, 72, 1, 0, 3, width=126)]
    words = left + right + [word("2", 306, 100, 2, 0, width=200, height=14)]  # a heading: 18 pt below
    words += [word("•", 306, 130, 3, 0), word("First", 316, 130, 3, 0, 1)]
    ends, paras = cards._boundaries(words)
    assert paras[:8] == [0] * 8 and paras[8] == 1 and paras[9] == 2
    assert cards._sentence(ends, 1) == (0, 7)
    figure = [word("0.1", 306, 72, 1, 0), word("Temperature", 340, 72, 1, 0, 1, width=60)]  # narrower: a figure
    _, paras = cards._boundaries(left + figure)
    assert paras == [0, 0, 0, 0, 1, 1]
    superscript = [word("cost", 70, 100, 0, 0, width=30), word("2", 101, 97, 0, 1, width=4, height=7),
                   word("grows.", 110, 100, 0, 2, width=40)]
    assert cards._boundaries(superscript)[1] == [0, 0, 0]


def test_line_end_hyphens():
    """A hyphen at a line end is dropped when the next line goes on in lower case, unless the source has the word
    with it."""
    words = [word("preference-", 70, 100, 0, 0), word("aligned", 70, 112, 0, 1), word("evalu-", 70, 124, 0, 2),
             word("ation", 70, 136, 0, 3)]
    text, spans = comments.join_spans(words, "toward preference-aligned content; an evaluation")
    assert text == "preference-aligned evaluation" and spans == [[0, 11], [11, 18], [19, 24], [24, 29]]
    assert comments.join_words(words) == "preferencealigned evaluation"
    words = [word("GPT-5.6-", 70, 100, 0, 0), word("Luna", 70, 112, 0, 1), word("Table-", 70, 124, 0, 2),
             word("Wide", 70, 136, 0, 3)]
    assert comments.join_spans(words, "ten GPT-5.6-Luna responses")[0] == "GPT-5.6-Luna Table- Wide"


def test_changed_words():
    old, new = "Both approaches decide when to keep a single instance alive.", \
        "Both approaches reason about the lifetime of one instance."
    spans = cards.changed(old, new)
    assert [new[s:e] for s, e in spans] == ["reason about the lifetime of one", ""]  # and "alive" left out
    assert spans[1] == [new.index(" instance") + 9] * 2
    old, new = "It is cheap, simple and fast.", "It is cheap and fast."
    assert cards.changed(old, new) == [[11, 11]]  # ", simple" left out after "cheap"
    assert cards.changed(new, new) == []
    old, new = "Zhang. 2023. A dataset. arXiv preprint arXiv:2309.11998.", "Zhang. 2024. A dataset. In ICLR."
    assert [new[s:e] for s, e in cards.changed(old, new)] == ["2024", "In ICLR"]  # no caret after the last "."


def test_cap_long_text():
    text = " ".join("w{:04d}".format(k) for k in range(400))  # 2399 characters
    s = text.index("w0200")
    capped, sel, cut = cards._cap(text, [[s, s + 5]], None, (s, s + 5))
    assert capped.startswith("… ") and capped.endswith(" …") and len(capped) <= cards.MAX_TEXT + 4
    assert capped[sel[0][0]:sel[0][1]] == "w0200" and cut is None
    capped, sel, cut = cards._cap(text, [], len(text), (len(text), len(text)))  # a deletion point at the end
    assert capped.startswith("… ") and capped.endswith("w0399") and capped[cut - 5:cut] == "w0399"


def test_contexts_of_new_comments(paper):
    pdf = str(paper / "r1" / "build" / "main.pdf")
    cid, c = comment(paper, 0, select(pdf, 0, "boots a minimal microVM in about 125"))
    assert c["color"] == "yellow" and c["context"]["display"] == "text" and c["context"]["page"] == 0
    assert marked(c["context"]) == ("On the first front, SOCK [8] caches imported packages in a zygote process, "
                                    "Firecracker [1] [[boots a minimal microVM in about 125]] ms, and Catalyzer [3] "
                                    "restores an initialised instance from a checkpoint.")
    assert ledger.get_comment(ledger.load(paper), cid)["rounds"]["1"]["context"] == c["context"]  # stored

    hybrid, c = comment(paper, 1, select(pdf, 1, "(Hybrid)."), kind="underline", color="teal")
    assert (c["kind"], c["color"]) == ("underline", "teal")
    assert marked(c["context"]) == ("We compare WarmCast with three policies: a fixed keep-alive of 10 minutes (KA-10), "
                                    "the same policy with a 60-minute window (KA-60), and the hybrid histogram policy "
                                    "of Shahrad et al. [[(Hybrid).]]")  # "et al." does not end the sentence

    _, c = comment(paper, 2, select(pdf, 2, "Cold-start rate by invocation frequency."))
    assert marked(c["context"]).startswith("Figure 1: [[Cold-start rate by invocation frequency.]] Each group")
    assert c["context"]["text"].endswith("falls in the given range.")  # a caption is taken whole

    _, c = comment(paper, 0, select(pdf, 0, "Related Work"))  # a heading is not run into its paragraph
    assert marked(c["context"]) == "2 [[Related Work]]"

    _, c = comment(paper, 1, [[300.0, 160.0, 300.0, 160.0]], kind="note")  # a note at a point
    assert c["context"]["display"] == "text" and c["context"]["sel"] == [] and c["context"]["text"].endswith(".")

    for page, rects in ((2, select(pdf, 2, "1240")), (1, [equation_rect(pdf, 1, "C(k)")])):  # table cell, formula
        _, c = comment(paper, page, rects)
        ctx = c["context"]
        assert (ctx["display"], ctx["sel"], ctx["rects"]) == ("image", [], c["rects"])
        x0, y0, x1, y1 = ctx["clip"]  # the formula's crop leaves out the body text around it: under 48 pt high
        assert x1 - x0 >= 200 and all(x0 <= r[0] and r[2] <= x1 and y0 <= r[1] and r[3] <= y1 for r in rects)
        assert _cut(ctx["clip"], pymupdf.open(pdf)[page].get_text("words")) == []
    with pytest.raises(EngineError, match="Unknown colour 'red'"):
        comment(paper, 0, select(pdf, 0, "simple keep-alive policy:"), color="red")
    with pytest.raises(EngineError, match="Unknown colour 'green'"):  # green is kept for changes and "verified"
        comment(paper, 0, select(pdf, 0, "simple keep-alive policy:"), color="green")
    with ledger.edit(paper) as lg:  # an M2a ledger's "green" reads as teal
        ledger.get_comment(lg, hybrid)["color"] = "green"
    assert next(c for c in call("state", paper=str(paper))["state"]["comments"] if c["id"] == hybrid)["color"] == "teal"


def test_box_comments(paper):
    pdf = str(paper / "r1" / "build" / "main.pdf")
    words = pymupdf.open(pdf)[2].search_for("Cold-start rate by invocation frequency.")[0]
    cid, c = comment(paper, 2, [FIGURE], kind="box", color="purple")
    a = ledger.get_comment(ledger.load(paper), cid)["rounds"]["1"]["anchor"]
    assert (c["kind"], c["method"], c["confidence"], c["rects"]) == ("box", "selection", 1.0, [FIGURE])
    assert (a["env"], a["label"], a["quote"][:14], a["quote"][-12:]) == ("figure", "fig:coldstart", "\\begin{figure}",
                                                                          "\\end{figure}")
    assert c["text"].startswith("Cold-start rate by invocation frequency.")  # the caption's words
    assert abs(a["ref"][1] - words.y0) < 1 and a["ref"][1] > FIGURE[3]  # the caption, below the picture
    assert (c["context"]["display"], c["context"]["clip"]) == ("image", [113.0, 169.0, 499.0, 368.0])

    _, c = comment(paper, 2, [TABLE], kind="box")
    a = ledger.get_comment(ledger.load(paper), c["id"])["rounds"]["1"]["anchor"]
    assert (a["env"], a["label"], c["text"][:22]) == ("table", "tab:main", "Results on days 2–14 o")
    _, c = comment(paper, 1, [equation_rect(pdf, 1, "C(k)")], kind="box")
    a = ledger.get_comment(ledger.load(paper), c["id"])["rounds"]["1"]["anchor"]
    assert (a["env"], a["label"], a["file"]) == ("equation", "eq:cost", "sections/method.tex")

    para = select(pdf, 0, "Most platforms use a simple keep-alive policy:")[0]  # a box on words of a paragraph
    _, c = comment(paper, 0, [[para[0] - 2, para[1] - 2, para[2] + 2, para[3] + 2]], kind="box")
    a = ledger.get_comment(ledger.load(paper), c["id"])["rounds"]["1"]["anchor"]
    assert (c["method"], a["quote"], a["label"]) == ("selection", "Most platforms use a simple keep-alive policy:", None)
    with pytest.raises(EngineError, match="exactly one rect"):
        comment(paper, 2, [FIGURE, TABLE], kind="box")


def test_edit_style(paper):
    pdf = str(paper / "r1" / "build" / "main.pdf")
    cid, _ = comment(paper, 0, select(pdf, 0, "simple keep-alive policy:"), note="n")
    state = call("edit_comment", paper=str(paper), id=cid, color="pink")["state"]
    c = next(c for c in state["comments"] if c["id"] == cid)
    assert (c["note"], c["kind"], c["color"]) == ("n", "highlight", "pink")  # only what was given changes
    state = call("edit_comment", paper=str(paper), id=cid, kind="strikeout", note="m")["state"]
    c = next(c for c in state["comments"] if c["id"] == cid)
    assert (c["note"], c["kind"], c["color"]) == ("m", "strikeout", "pink")
    for params, message in (({"kind": "box"}, "is a strikeout; re-anchor it to change its kind"),
                            ({}, "Nothing to change"),
                            ({"color": "green"}, "Unknown colour"), ({"kind": "circle"}, "Unknown comment kind")):
        with pytest.raises(EngineError, match=message):
            call("edit_comment", paper=str(paper), id=cid, **params)
    point, _ = comment(paper, 1, [[300.0, 160.0, 300.0, 160.0]], kind="note")
    with pytest.raises(EngineError, match="is a note at a point"):
        call("edit_comment", paper=str(paper), id=point, kind="highlight")
    box, _ = comment(paper, 2, [FIGURE], kind="box")
    with pytest.raises(EngineError, match="is a box"):
        call("edit_comment", paper=str(paper), id=box, kind="underline")


def test_reanchor_a_new_comment(paper):
    pdf = str(paper / "r1" / "build" / "main.pdf")
    cid, _ = comment(paper, 0, select(pdf, 0, "simple keep-alive policy:"), kind="underline", note="n")
    state = call("reanchor", paper=str(paper), id=cid, page=2, rects=[FIGURE], kind="box")["state"]
    c = next(c for c in state["comments"] if c["id"] == cid)
    assert (c["kind"], c["page"], c["rects"], c["method"], c["anchor_state"], c["note"]) == \
        ("box", 2, [FIGURE], "selection", "new", "n")
    assert c["context"]["display"] == "image"
    state = call("reanchor", paper=str(paper), id=cid, page=0, rects=select(pdf, 0, "Both approaches decide"))["state"]
    c = next(c for c in state["comments"] if c["id"] == cid)
    assert (c["kind"], c["new_quote"], c["context"]["display"]) == ("highlight", "Both approaches decide", "text")


def test_two_rounds(paper):
    """Boxes carried by their environments, re-anchoring a carried comment, recolouring it, final.pdf kinds."""
    p = str(paper)
    pdf1 = str(paper / "r1" / "build" / "main.pdf")
    fig, _ = comment(paper, 2, [FIGURE], kind="box", color="purple")
    tab, _ = comment(paper, 2, [TABLE], kind="box")
    r103, _ = comment(paper, 2, select(pdf1, 2, "The memory footprint is two floating-point numbers per function."),
                      kind="strikeout")
    r104, _ = comment(paper, 0, select(pdf1, 0, "Both approaches decide when to keep a single instance alive."))
    comment(paper, 0, select(pdf1, 0, "simple keep-alive policy:"), kind="underline", color="blue")
    click, c = comment(paper, 2, [[300.0, 640.0, 300.0, 640.0]], kind="note")  # placed by a synctex line: a guess
    assert (c["method"], c["confidence"]) == ("line", 0.5)
    call("finish", paper=p)
    final = pymupdf.open(paper / "r1" / "final.pdf")
    assert all(a.type[1] == "Link" for page in final for a in page.annots())  # the marks are burned in
    ink = {k: tuple(round(v, 2) for v in render._rgb(c[1])) for k, c in comments.PALETTE.items()}
    off = final.page_count - pymupdf.open(pdf1).page_count  # the summary pages
    assert ("box", ink["purple"]) in burned(final[2 + off], [FIGURE])
    assert ("underline", ink["blue"]) in burned(final[off], select(pdf1, 0, "simple keep-alive policy:"))
    assert ("strikeout", ink["yellow"]) in burned(
        final[2 + off], select(pdf1, 2, "The memory footprint is two floating-point numbers per function."))

    state = call("ingest", paper=p, source=str(FIXTURE / "v2"))["state"]
    pdf2 = state["round"]["build"]["pdf"]
    cs = {c["id"]: c for c in state["comments"]}
    assert [r["pdf"] for r in state["rounds"]] == [pdf1, pdf2]
    # The figure did not change: its box stays where the caption keeps it. Table 1's 655 became 671 (E7).
    assert (cs[fig]["anchor_state"], cs[fig]["page"], cs[fig]["rects"]) == ("unchanged", 2, [FIGURE])
    assert (cs[tab]["anchor_state"], cs[tab]["changes"]) == ("changed", ["c03"])
    assert cs[tab]["context"]["display"] == "image" and cs[tab]["history"][0]["context"]["display"] == "image"
    lg = ledger.load(paper)
    assert ledger.get_comment(lg, tab)["rounds"]["2"]["anchor"]["label"] == "tab:main"
    # R1-03's sentence was deleted (E3): the card shows the text around the deletion point
    gone = cs[r103]["context"]
    assert cs[r103]["anchor_state"] == "gone" and gone["sel"] == [] and gone["changed"] == []
    assert gone["text"][gone["cut"] - 1] == "." and "within 0.2 s per interval." in gone["text"]
    assert cs[r103]["history"][0]["page"] == 2
    # R1-04's sentence was rewritten (E2): Now has the changed words against round 1
    now = cs[r104]["context"]
    assert (now["against"], [now["text"][s:e] for s, e in now["changed"]]) == \
        (1, ["reason about the lifetime of one instance and leave the number of concurrent instances",
             "the autoscaler"])

    # Re-anchor the carried R1-04 onto the next sentence: method advisor, its own changes, later rounds carry from it
    target = select(pdf2, 0, "WarmCast instead decides how many instances to keep,")
    with pytest.raises(EngineError, match="can be edited or deleted"):
        call("edit_comment", paper=p, id=r104, note="x")
    call("verdict", paper=p, id=r104, verdict="reopened", note="a")
    state = call("verdict", paper=p, id=r104, verdict="reopened", note="b")["state"]  # the same verdict: a new note
    assert next((c["verdict"], c["verdict_note"]) for c in state["comments"] if c["id"] == r104) == ("reopened", "b")
    state = call("edit_comment", paper=p, id=r104, color="orange")["state"]
    state = call("reanchor", paper=p, id=r104, page=0, rects=target)["state"]
    c = next(c for c in state["comments"] if c["id"] == r104)
    assert (c["method"], c["confidence"], c["anchor_state"], c["color"]) == ("advisor", 1.0, "changed", "orange")
    assert marked(c["context"]).startswith("[[WarmCast instead decides how many instances to keep,]]")
    assert c["changes"] == []  # c02 (E2) was in its old sentence, not in this one
    assert next(ch for ch in state["changes"] if ch["id"] == "c02")["unrequested"]
    analysis = json.loads((paper / "r2" / "analysis.json").read_text(encoding="utf-8"))
    assert all(r104 not in ch["attached_to"] for ch in analysis["changes"])

    # The \label finds a box's environment when its source is not found (anchor.carry, method "label")
    diff = texdiff.diff_trees(paper / "r1" / "src", paper / "r2" / "src")
    last = dict(ledger.get_comment(lg, fig)["rounds"]["1"]["anchor"], quote="nothing like this is in the source")
    records, _ = anchor.carry(paper / "r1" / "src", paper / "r2" / "src", pdf2, diff,
                              [{"id": fig, "anchor": None, "last": last, "box": True}])
    rec = records[fig]
    assert (rec["anchor_state"], rec["method"], rec["confidence"], rec["anchor"]["label"]) == \
        ("changed", "label", anchor.LABEL_CONFIDENCE, "fig:coldstart")
    assert rec["anchor"]["quote"].startswith("\\begin{figure}") and rec["anchor"]["rects"] == [FIGURE]

    state = call("reanchor", paper=p, id=click, page=0, rects=select(pdf2, 0, "Our forecaster is deliberately"))["state"]
    assert next(c for c in state["comments"] if c["id"] == click)["confidence"] == 1.0
    # Redrawn around the same table or figure, a box keeps its state and changes (was: "moved", which hid the edit)
    for cid, rect, kept in ((tab, TABLE, "changed"), (fig, FIGURE, "unchanged")):
        state = call("reanchor", paper=p, id=cid, page=2, rects=[rect], kind="box")["state"]
        c = next(c for c in state["comments"] if c["id"] == cid)
        assert (c["anchor_state"], c["method"]) == (kept, "advisor")
    assert next(c for c in state["comments"] if c["id"] == tab)["changes"] == ["c03"]
    call("finish", paper=p)
    state = call("ingest", paper=p, source=str(FIXTURE / "v3"))["state"]
    c = next(c for c in state["comments"] if c["id"] == click)  # the advisor placed it: no longer a guess
    assert (c["anchor_state"], c["confidence"]) == ("unchanged", 1.0)
    c = next(c for c in state["comments"] if c["id"] == r104)
    assert (c["anchor_state"], c["method"], c["new_quote"].split()[:3]) == ("unchanged", "diff",
                                                                            ["WarmCast", "instead", "decides"])
    assert [h["round"] for h in c["history"]] == [1, 2] and c["history"][1]["context"]["page"] == 0
    # Each earlier round names the changes attached to the comment then, as its analysis.json has them now (the app's
    # thread: a round with an attached change is a section of its own); re-anchoring R1-04 dropped c02 from it.
    assert [h["changes"] for h in c["history"]] == [[], []]
    assert [h["changes"] for h in next(c for c in state["comments"] if c["id"] == tab)["history"]] == [[], ["c03"]]


def test_change_contexts_and_checked(paper):
    """Round 2's changes (EDITS.md E1-E7) read as the sentences both PDFs print, with the change's own words marked;
    the advisor marks changes checked, per round, in the ledger. A state of an analysis.json written before change
    contexts were stored works them out once."""
    p = str(paper)
    call("finish", paper=p)
    state = call("ingest", paper=p, source=str(FIXTURE / "v2"))["state"]
    ch = {c["id"]: c for c in state["changes"]}

    def side(cid, name):
        ctx = ch[cid]["context"][name]
        return ctx and (ctx["display"], ctx["page"], marked(ctx))
    # E1, a word, and E2, a rewrite: the same sentence on both sides
    assert side("c01", "before") == ("text", 0, "Most platforms use a [[simple]] keep-alive policy: after an instance "
                                     "finishes a request, it stays in memory for a fixed period, typically ten minutes, "
                                     "in case another request arrives [9].")
    assert side("c01", "now")[2].startswith("Most platforms use a [[static]] keep-alive policy:")
    assert (side("c02", "before"), side("c02", "now")) == (
        ("text", 0, "Both approaches [[decide when to keep a single instance alive.]]"),
        ("text", 0, "Both approaches [[reason about the lifetime of one instance and leave the number of concurrent "
                    "instances to the autoscaler.]]"))
    # E7, a number in Table 1: crops of both PDFs
    assert (side("c03", "before")[:2], side("c03", "now")[:2]) == (("image", 2), ("image", 2))
    assert (ch["c03"]["context"]["before"]["text"], ch["c03"]["context"]["now"]["text"]) == ("655", "671")
    # E3, a deleted sentence: marked before, a deletion point now
    assert "[[The memory footprint is two floating-point numbers per function.]]" in side("c04", "before")[2]
    assert "within 0.2 s per interval.‸ We did not observe" in side("c04", "now")[2]
    # E4, a moved paragraph: marked on both sides, at its old and new place
    assert side("c05", "before")[2].startswith("[[Our simulator is event-driven")
    assert side("c05", "now")[2].startswith("[[Our simulator is event-driven")
    assert side("c05", "before")[1] == 1 and side("c05", "now")[1] == 2
    # E5, an inserted sentence: where it went before, marked now
    assert "forecast of its arrival rate.‸ The pool size follows" in side("c06", "before")[2]
    assert side("c06", "now") == ("text", 2, "[[Because the controller needs no changes to the functions themselves, it "
                                  "can be deployed on existing platforms without involving developers.]]")
    assert [ch[k]["section"] for k in sorted(ch)] == ["Introduction", "Related Work", "Evaluation", "Evaluation",
                                                       "Evaluation", "Conclusion", "Method"]
    # E6, inside Eq. (2): crops
    assert [ch["c07"]["context"][k]["display"] for k in ("before", "now")] == ["image", "image"]
    assert all(not c["checked"] for c in state["changes"])

    state = call("check_change", paper=p, id="c06")["state"]
    state = call("check_change", paper=p, id="c03", checked=True)["state"]
    assert [c["id"] for c in state["changes"] if c["checked"]] == ["c03", "c06"]
    state = call("check_change", paper=p, id="c03", checked=False)["state"]
    assert [c["id"] for c in state["changes"] if c["checked"]] == ["c06"]
    assert next(r for r in ledger.load(paper)["rounds"] if r["n"] == 2)["checked"] == ["c06"]
    with pytest.raises(EngineError, match="no change c99"):
        call("check_change", paper=p, id="c99")

    # an analysis.json without contexts (ingested before they were stored): worked out by state, the same
    stored = json.loads((paper / "r2" / "analysis.json").read_text(encoding="utf-8"))
    for c in stored["changes"]:
        del c["context"], c["section"]
    (paper / "r2" / "analysis.json").write_text(json.dumps(stored), encoding="utf-8")
    again = {c["id"]: c for c in call("state", paper=p)["state"]["changes"]}
    assert all(again[k]["context"] == ch[k]["context"] and again[k]["section"] == ch[k]["section"] for k in ch)

    call("finish", paper=p)
    with pytest.raises(EngineError, match="no open round"):
        call("check_change", paper=p, id="c06")


def test_new_comments_on_changes_and_closed_notes(paper):
    """A comment written in round 2 on an edit no comment asked for is reported on the change (commented_by) and in
    final.pdf; a verified comment's note is shown whole (margin, summary, email); a closed strike-out is drawn as an
    underline; final.pdf opens on the summary."""
    p = str(paper)
    pdf1 = call("state", paper=p)["state"]["round"]["build"]["pdf"]
    struck, _ = comment(paper, 0, select(pdf1, 0, "boots a minimal microVM in about 125"), kind="strikeout",
                        note="Cite it.")
    call("finish", paper=p)
    state = call("ingest", paper=p, source=str(FIXTURE / "v2"))["state"]
    ch = {c["id"]: c for c in state["changes"]}
    assert ch["c06"]["unrequested"] and ch["c06"]["commented_by"] == []
    asking, _ = comment(paper, ch["c06"]["page"], ch["c06"]["rects"][:1], note="Is this true?")
    other, _ = comment(paper, ch["c06"]["page"], ch["c06"]["rects"][-1:])
    state = call("delete_comment", paper=p, id=other)["state"]
    by = {c["id"]: c["commented_by"] for c in state["changes"]}
    assert by["c06"] == [asking] and all(v == [] for k, v in by.items() if k != "c06")
    assert next(c for c in state["changes"] if c["id"] == "c06")["unrequested"]
    call("check_change", paper=p, id="c03")
    note = "Moved is fine, but it still needs a citation for the 125 ms figure."
    call("verdict", paper=p, id=struck, verdict="verified", note=note)
    state = call("finish", paper=p)["state"]

    final = pymupdf.open(state["round"]["final_pdf"])
    assert final.xref_get_key(final.pdf_catalog(), "OpenAction")[1].startswith("[{} 0 R".format(final[0].xref))
    summary = " ".join(final[0].get_text().split())
    # a closed comment is a chip on the summary; its note is in the margin (design/summary-page)
    assert note not in summary and struck in summary.split("Closed (")[1]
    assert "Your changes no comment asked for" in summary and "{} asks about this".format(asking) in summary
    page = final[1]  # paper page 1
    assert note in " ".join(page.get_text().split())  # in the margin, not cut
    c = next(c for c in state["comments"] if c["id"] == struck)
    drawn = burned(final[c["page"] + 1], c["rects"])
    yellow = tuple(round(v, 2) for v in render._rgb(comments.PALETTE["yellow"][1]))
    assert ("underline", yellow) in drawn and ("strikeout", yellow) not in drawn
    assert "  {} (resolved): {}".format(struck, note) in state["round"]["email"]


def test_sentence_across_a_page_break(tmp_path):
    """A sentence that a page break cuts is shown whole: its end is found on the next page."""
    if not shutil.which("latexmk", path=PATH):
        pytest.skip("needs latexmk and synctex")
    src = tmp_path / "src"
    src.mkdir()
    body = " ".join("Sentence {} of this paragraph talks about item {} and then goes on with several more plain "
                    "words.".format(k, k + 1000) for k in range(1, 90))
    (src / "main.tex").write_text("\\documentclass{article}\n\\begin{document}\n" + body + "\n\\end{document}\n")
    build = project.compile(src, tmp_path / "build", "main.tex", "pdflatex")
    pdf = build["pdf"]
    words = comments.body_words(pymupdf.open(pdf)[0].get_text("words"))
    words = [w for w in words if w[4] != "1"]  # the page number
    last = [w for w in words if w[5:7] == words[-1][5:7]]
    rect = [min(w[0] for w in last), min(w[1] for w in last), max(w[2] for w in last), max(w[3] for w in last)]
    a, _, _ = comments.locate(src, pdf, 0, [rect], "")
    ctx = cards.page_context(src, pdf, a, "highlight", False)
    k = ctx["text"].split()[1]
    assert ctx["text"] == next(s + "." for s in body.split(". ") if s.startswith("Sentence {} ".format(k)))
    assert ctx["text"][ctx["sel"][0][0]:ctx["sel"][-1][1]] == comments.join_words(last)


def _page(tmp_path, lines, tex):
    """(src, pdf) of a one-page PDF with text lines [(x, y_baseline, text, size)] and a source main.tex."""
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    for x, y, text, size in lines:
        page.insert_text((x, y), text, fontsize=size)
    pdf = tmp_path / "page.pdf"
    doc.save(pdf)
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text(tex)
    return src, pdf


def _anchor(pdf, tex, phrases, quote):
    """An anchor on the PDF lines holding each phrase (one rect per phrase), with quote's range in tex."""
    page = pymupdf.open(pdf)[0]
    rects = [list(page.search_for(p)[0]) for p in phrases]
    s = tex.index(quote)
    return {"file": "main.tex", "start": s, "end": s + len(quote), "page": 0, "rects": rects, "text": ""}


def test_a_sentence_across_columns_with_a_figure_between(tmp_path):
    """Selected as two runs, from the bottom of the left column to the top of the right one under a figure: the card
    shows the sentence without the figure's words (they were in the middle of it)."""
    lines = [(70, 700 + 12 * k, "filler words of the left column go on here", 10) for k in range(5)]
    lines[-1] = (70, 748, "and in the end the results in Figure 7 show that", 10)
    lines += [(320, 80, "0.1 0.5 1.0 Temperature", 8), (306, 100, "Figure 7: Effects of the temperature.", 9),
              (306, 130, "the pool stays small at low load. Then more text", 10)]
    tex = ("filler words of the left column go on here and in the end the results in Figure~\\ref{f} show that the "
           "pool stays small at low load. Then more text\n\\begin{figure}\\caption{Effects of the temperature.}"
           "\\end{figure}\n")
    src, pdf = _page(tmp_path, lines, tex)
    a = _anchor(pdf, tex, ["the results in Figure 7 show that", "the pool stays small at low load."],
                "the results in Figure~\\ref{f} show that the pool stays small at low load.")
    ctx = cards.page_context(src, pdf, a, "highlight", False)
    assert "Temperature" not in ctx["text"] and "Effects" not in ctx["text"]
    assert ctx["text"][ctx["sel"][0][0]:ctx["sel"][-1][1]] == \
        "the results in Figure 7 show that the pool stays small at low load."


def test_a_footnote_and_a_heading_are_paragraphs_of_their_own():
    """In ACL a heading and a footnote sit only about half a line below the text before them (GAP)."""
    body = [word("Overview", 306, 700, 0, 0, height=11), word("Our", 306, 717.6, 1, 0, height=11),
            word("dataset", 330, 717.6, 1, 0, 1, height=11), word("contains", 306, 731.1, 1, 1, height=11)]
    footnote = [word("1See", 318, 748.1, 2, 0, height=10.5), word("details.", 345, 748.1, 2, 0, 1, height=10.5)]
    ends, paras = cards._boundaries(body + footnote)
    assert paras == [0, 1, 1, 1, 2, 2]


def test_a_box_of_text_does_not_run_into_the_next_paragraph():
    """The source between two parts must not end a paragraph or an environment (a tcolorbox's text, then the
    paragraph after it), or they are not one sentence."""
    tex = ("\\begin{tcolorbox}You are a careful assistant, and you give each user one short and direct answer "
           "to their question\\end{tcolorbox}\nFor Rewrite, we use the template below.")
    before = [word("their", 70, 100, 0, 0), word("question", 100, 100, 0, 0, 1)]
    after = [word("For", 70, 130, 1, 0), word("Rewrite,", 90, 130, 1, 0, 1)]
    assert not cards._follows(cards._letters(tex), before, after)
    assert cards._follows(cards._letters(tex.replace("\\end{tcolorbox}\n", " ")), before, after)


def test_a_sentence_deleted_after_a_heading(tmp_path):
    """A gone comment whose deletion point ends a heading shows what follows it now (was: the heading alone)."""
    lines = [(70, 100, "Limitations", 12), (70, 125, "We leave a detailed investigation for future work.", 10)]
    tex = "\\section*{Limitations}\n\nWe leave a detailed investigation for future work.\n"
    src, pdf = _page(tmp_path, lines, tex)
    heading = pymupdf.open(pdf)[0].search_for("Limitations")[0]
    s = tex.index("}") + 1
    a = {"file": "main.tex", "start": s, "end": s, "page": 0, "text": "",
         "rects": [[heading.x1, heading.y0, heading.x1 + 2, heading.y1]]}
    ctx = cards.page_context(src, pdf, a, "highlight", True)
    assert marked(ctx) == "Limitations‸ We leave a detailed investigation for future work."


def test_a_small_clip_stays_inside_the_text():
    """A table cell at the right edge of the text: its 200 pt wide crop ends at the text's edge, not in the margin."""
    clip = cards._clip([[470, 100, 500, 110]], pymupdf.Rect(100, 0, 512, 792), False)
    assert clip == [312.0, 81.0, 512.0, 129.0]
    assert cards._clip([[90, 100, 600, 110]], pymupdf.Rect(0, 0, 612, 792), True) == [84.0, 94.0, 606.0, 116.0]


def test_an_image_crop_keeps_to_its_column_and_a_deleted_row_shows_the_row(tmp_path):
    """On a two-column page a figure's crop stays in the anchor's column (synctex's box of a picture can be wider than
    the column); a deletion point at the end of a table row is shown with the whole row."""
    lines = [(60, 100 + 14 * k, "words of the left column of the page", 10) for k in range(12)]
    lines += [(330, 100 + 14 * k, "words of the right column of the page", 10) for k in range(12)]
    lines += [(330, 400, "Mem0 -1.39 -1.24 -1.15 -0.98 -0.54 -0.33 -0.21 -0.07", 10)]
    tex = ("\\begin{figure}\\includegraphics{plot}\\caption{Plot.}\\end{figure}\n"
           "\\begin{tabular}{lrrrrr}\nMem0 & -1.39 & -1.24 & -1.15 & -0.98 & -0.54 \\\\\n\\end{tabular}\n")
    src, pdf = _page(tmp_path, lines, tex)
    gap = comments.columns(pdf)[0][0]
    s = tex.index("\\includegraphics")
    a = {"file": "main.tex", "start": s, "end": tex.index("}", s) + 1, "page": 0, "text": "label",
         "rects": [[200, 230, 225, 240]]}
    clip = cards.page_context(src, pdf, a, "highlight", False)["clip"]
    assert clip[2] <= gap + cards.PAD and clip[2] - clip[0] >= 150
    row = pymupdf.open(pdf)[0].search_for("Mem0")[0]
    s = tex.index("\\\\\n") + 2  # after the row
    end = pymupdf.open(pdf)[0].search_for("-0.07")[0].x1
    a = {"file": "main.tex", "start": s, "end": s, "page": 0, "text": "", "rects": [[end, row.y0, end + 2, row.y1]]}
    ctx = cards.page_context(src, pdf, a, "highlight", True)
    assert ctx["display"] == "image" and ctx["clip"][0] <= row.x0


def _pages(tmp_path, pages, tex):
    """(src, pdf) of a PDF with one page per list of text lines [(x, y_baseline, text, size)], and main.tex."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    doc = pymupdf.open()
    for lines in pages:
        page = doc.new_page(width=595, height=842)
        for x, y, text, size in lines:
            page.insert_text((x, y), text, fontsize=size)
    pdf = tmp_path / "pages.pdf"
    doc.save(pdf)
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text(tex)
    return src, pdf


FILLER = "Filler words of the page go on and on here, saying little."


def test_a_sentence_across_a_page_break_after_the_page_number(tmp_path):
    """The other half of a sentence cut by a page break is the text before the break, not the page number, a
    figure's tick labels or a legend word that equals the word before the break (found in a review: a page number, a
    figure's tick labels and a legend word, each taken for the text before the break)."""
    first = [(70, 100 + 14 * k, FILLER, 10) for k in range(10)]
    first += [(70, 240, "and for the second time the experiment in the Rewrite", 10), (297, 800, "1", 10)]
    second = [(120, 80, "0.5 1.0 1.5 20", 8), (120, 92, "Baseline Pooled Rewrite", 8),
              (70, 110, "Figure 3: Mean wait of the calls.", 9),
              (70, 140, "setting, a small model shortens the request before it is served.", 10)]
    tex = (" ".join([FILLER] * 10) + " and for the second time the experiment in the \\textsc{Rewrite} setting, a "
           "small model shortens the request before it is served.\n\\begin{figure}\\caption{Mean wait of the calls.}"
           "\\end{figure}\n")
    src, pdf = _pages(tmp_path, [first, second], tex)
    s = tex.index("setting,")
    rect = list(pymupdf.open(pdf)[1].search_for("setting, a small model shortens")[0])
    a = {"file": "main.tex", "start": s, "end": s + len("setting, a small model shortens"), "page": 1, "rects": [rect],
         "text": ""}
    ctx = cards.page_context(src, pdf, a, "highlight", False)
    assert ctx["text"].endswith("in the Rewrite setting, a small model shortens the request before it is served.")
    assert "Pooled" not in ctx["text"] and not ctx["text"].startswith(("1 ", "20 "))


@pytest.mark.parametrize("furniture", ["page number", "running foot", "running head"])
def test_a_point_after_the_last_sentence_of_a_page_leaves_out_its_furniture(tmp_path, furniture):
    """A point after a page's last sentence (an insert's place in the round before) shows that sentence, not the
    page number, running foot or running head that the page's text goes on with (demo round 4, c05: "… across all
    tested pool sizes. 7"). A foot line on one page only (a footnote) is text."""
    last = "The gap stays clear across all of the tested pool sizes."
    body = [(70, 100 + 14 * k, FILLER, 10) for k in range(5)]
    extra = {"page number": lambda n: [(297, 800, str(n), 10)],
             "running foot": lambda n: [(250, 805, "Preprint. Under review.", 9)],
             "running head": lambda n: [(200, 40, "Under review as a conference paper.", 9)]}[furniture]
    pages = [body + [(70, 170, last, 10)] + extra(7),
             body + [(70, 170, "Overall, the next page starts.", 10)] + extra(8)]
    tex = " ".join([FILLER] * 5) + " " + last + "\n\nOverall, the next page starts.\n"
    src, pdf = _pages(tmp_path, pages, tex)
    word = list(pymupdf.open(pdf)[0].search_for("sizes.")[0])
    s = tex.index("\n\nOverall")
    a = {"file": "main.tex", "start": s, "end": s, "page": 0, "rects": [[word[2], word[1], word[2] + 2, word[3]]],
         "text": ""}
    ctx = cards.page_context(src, pdf, a, "highlight", True)
    assert marked(ctx) == last + "‸"
    if furniture == "running foot":  # on one page only: a footnote, which is text
        src, pdf = _pages(tmp_path / "once", [pages[0], pages[1][:-1]], tex)
        assert cards.page_context(src, pdf, a, "highlight", True)["text"].endswith(last + " Preprint.")


def test_a_sentence_across_a_break_with_a_citation_or_reference_at_it(tmp_path):
    """The letters on each side of a break are compared without what \\cite and \\ref print (the
    head ends with "(Chen et al., 2025),"; or "Figure 7(a) shows" at the end of a page)."""
    first = [(70, 100 + 14 * k, FILLER, 10) for k in range(10)]
    first += [(70, 240, "Such pools waste the idle memory noted by (Chen et al., 2025),", 10)]
    second = [(70, 100, "but also miss the bursts in ways that cost the provider.", 10)]
    tex = (" ".join([FILLER] * 10) + " Such pools waste the idle memory noted by~\\citep{Chen2025}, but also "
           "miss the bursts in ways that cost the provider.\n")
    src, pdf = _pages(tmp_path, [first, second], tex)
    s = tex.index("but also")
    a = {"file": "main.tex", "start": s, "end": s + len("but also miss"), "page": 1, "text": "",
         "rects": [list(pymupdf.open(pdf)[1].search_for("but also miss")[0])]}
    assert cards.page_context(src, pdf, a, "highlight", False)["text"] == (
        "Such pools waste the idle memory noted by (Chen et al., 2025), but also miss the bursts in ways "
        "that cost the provider.")
    first = [(70, 100 + 14 * k, FILLER, 10) for k in range(10)]
    first += [(70, 240, FILLER, 10), (70, 254, "Figure 7(a) shows", 10)]
    second = [(70, 100, "1.0 2.0 3.0", 8), (70, 112, "12.50 3.25 40.75", 8),
              (70, 140, "consistently short waits at small pool sizes. More text.", 10)]
    tex = (" ".join([FILLER] * 11) + " Figure~\\ref{fig:t}(\\subref{fig:low}) shows consistently short waits at small "
           "pool sizes. More text.\n")
    src, pdf = _pages(tmp_path / "b", [first, second], tex)
    s = tex.index("Figure~")
    a = {"file": "main.tex", "start": s, "end": tex.index(" shows") + 6, "page": 0, "text": "",
         "rects": [list(pymupdf.open(pdf)[0].search_for("Figure 7(a) shows")[0])]}
    assert cards.page_context(src, pdf, a, "highlight", False)["text"] == (
        "Figure 7(a) shows consistently short waits at small pool sizes.")


def _cut(clip, words):
    """The words that a clip's edges pass through (more than a fifth into them)."""
    x0, y0, x1, y1 = clip
    out = []
    for w in words:
        h, wd = w[3] - w[1], w[2] - w[0]
        if w[2] > x0 and w[0] < x1 and any(w[1] + 0.2 * h < e < w[3] - 0.2 * h for e in (y0, y1)) \
                or w[3] > y0 and w[1] < y1 and any(w[0] + 0.2 * wd < e < w[2] - 0.2 * wd for e in (x0, x1)):
            out.append(w[4])
    return out


def test_a_crop_of_a_tightly_set_table_cuts_no_letters(tmp_path):
    """In a table set at 10 pt per row in 9 pt Times (as in an appendix table), the rows' text boxes overlap: an edge
    put at either box showed the next row's descenders or capitals as a sliver (UX review). The
    edge goes midway between the rows' ink: the crop's first and last pixel rows are blank."""
    rows = ["Warm-up period   30 s   30 s", "Pool-size cap   8   8", "Forecast window   Ten minutes   Ten",
            "Decay factor   0.001   0.001", "Burst threshold   0   0", "Logging / probing   Every 50",
            "Used Forecast   The last   The last"]
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    for k, row in enumerate(rows):
        page.insert_text((108, 300 + 10 * k), row, fontsize=9, fontname="tiro")
    pdf = tmp_path / "table.pdf"
    doc.save(pdf)
    (tmp_path / "src").mkdir()
    tex = "\\begin{tabular}{lll}Decay factor & 0.001 & 0.001\\\\\\end{tabular}\n"
    (tmp_path / "src" / "main.tex").write_text(tex)
    s = tex.index("0.001")
    for cell in pymupdf.open(pdf)[0].search_for("0.001")[:1] + pymupdf.open(pdf)[0].search_for("Pool-size")[:1]:
        ctx = cards.page_context(tmp_path / "src", pdf, {"file": "main.tex", "start": s, "end": s + 5, "page": 0,
                                                         "text": "", "rects": [list(cell)]}, "highlight", False)
        pix = pymupdf.open(pdf)[0].get_pixmap(clip=pymupdf.Rect(ctx["clip"]), dpi=288)
        ink = [sum(1 for x in range(pix.width) if pix.pixel(x, y)[0] < 160) for y in (0, pix.height - 1)]
        assert ctx["display"] == "image" and ink == [0, 0], (ctx["clip"], ink)


def test_image_crops_cut_no_text(tmp_path):
    """A crop's edges go between lines and words (UX review: half lines of body text around a formula, a table's
    third column cut, text wrapped beside a table): a formula's crop leaves out the wider body text around it, a
    table cell's crop is as wide as the table's rules, and text beside a table is left out."""
    body = "body text of the paragraph runs across the whole width of the page, line after line here"
    lines = [(70, 100 + 12 * k, body, 10) for k in range(5)] + [(250, 170, "H = sum of p log p (5)", 10)]
    lines += [(70, 186 + 12 * k, body, 10) for k in range(4)]
    rows = ["Forecast window   Ten minutes   Ten minutes", "Decay factor   0.001   0.001",
            "Logging interval   Every 10 minutes   Every 5 minutes"]
    lines += [(270, 400 + 12 * k, rows[k], 10) for k in range(3)]
    lines += [(70, 400 + 12 * k, "wrapped words on the left", 10) for k in range(3)]
    doc_lines = lines
    tex = ("text \\begin{equation}H = \\sum p \\log p\\end{equation} more text\n"
           "\\begin{wraptable}\\begin{tabular}{lll}Decay factor & 0.001 & 0.001\\\\\\end{tabular}\\end{wraptable}\n")
    src, pdf = _page(tmp_path, doc_lines, tex)
    doc = pymupdf.open(pdf)
    page = doc[0]
    for y in (388, 438):  # the table's rules
        page.draw_line((265, y), (530, y))
    doc.saveIncr()
    words = pymupdf.open(pdf)[0].get_text("words")
    s = tex.index("H =")
    eq = list(pymupdf.open(pdf)[0].search_for("H = sum of p log p (5)")[0])
    ctx = cards.page_context(src, pdf, {"file": "main.tex", "start": s, "end": s + 3, "page": 0, "text": "",
                                        "rects": [eq]}, "highlight", False)
    assert ctx["display"] == "image" and _cut(ctx["clip"], words) == []
    assert not [w for w in words if w[4] == "body" and anchor._inside(w, [ctx["clip"]])]
    s = tex.index("0.001")
    cell = list(pymupdf.open(pdf)[0].search_for("0.001")[1])
    ctx = cards.page_context(src, pdf, {"file": "main.tex", "start": s, "end": s + 5, "page": 0, "text": "",
                                        "rects": [cell]}, "highlight", False)
    assert ctx["display"] == "image" and _cut(ctx["clip"], words) == []
    assert ctx["clip"][0] > 250 and ctx["clip"][2] >= 530  # beside: no wrapped words; across: the rules' width


def test_a_change_side_that_prints_no_word_is_a_point(tmp_path):
    """A side of a change whose rects hold no word (a "(" that replaced "\\footnote{See", placed by to_pdf as a
    2 pt point after the word before) shows that word's sentence with the point, not a crop of nothing."""
    lines = [(70, 100, "The controller computes the pool size (Sec. 4) over the day.", 10)]
    tex = "The controller computes the pool size (Sec.~\\ref{s}) over the day.\n"
    src, pdf = _page(tmp_path, lines, tex)
    word = list(pymupdf.open(pdf)[0].search_for("size")[0])
    point = [word[2], word[1], word[2] + 2, word[3]]
    s = tex.index("(")
    h = {"kind": "replace", "new_file": "main.tex", "new_start": s, "new_end": s + 1}
    ctx = cards._change_side(src, pdf, h, "new", 0, [point], False)
    assert (ctx["display"], marked(ctx)) == ("text", "The controller computes the pool size‸ (Sec. 4) over the day.")
