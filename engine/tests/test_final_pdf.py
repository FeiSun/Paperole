"""final.pdf in the margin style (CONTRACT amendment "Final PDF in the margin style"), on small synthetic papers:
page sizes, every located comment once in the margin (and no PDF annotation), margin items that never
overlap (also on a crowded page), Chinese glyphs in an embedded CJK font, both margins on a two-column paper, a crop
instead of garbled text for a formula in the summary, page labels and outline; "your change" lines in the words the
PDF prints. Review fixes, 2026-10-24: an overfull margin, a note longer than a page, follow-up texts in final.pdf and
the email, outline items without a page. 2026-10-30 (design/comments/PLAN.md P0.1): notes whole and in one size, a
crowded side's tallest comments in a band under the paper, the page taller."""
import os
import shutil

import pymupdf
import pytest

from conftest import burned, quiet, select
from paperole import api, comments, ledger, render

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

ZONES = ("amber basalt cedar dune ember fjord garnet harbor indigo jasper kelp lagoon meadow nectar onyx prairie "
         "quartz reef sierra tundra").split()
PARAGRAPH = ("In the {0} zone, serverless platforms start a fresh sandbox for every cold invocation. Requests in the "
             "{0} zone are short and arrive in bursts. A keep-alive policy for the {0} zone holds each instance for a "
             "fixed window after its last request.")
FORMULA = "\\begin{equation}\nH := -\\sum_{j=1}^{M} p_j \\log_2 p_j\n\\end{equation}\n"
CHINESE = "熵的定义要写清楚 log 的底。"


def _paper(root, twocolumn):
    """A paper with round 1 ingested: 20 paragraphs, a display formula after the second."""
    src = root / "src"
    src.mkdir(parents=True)
    paras = [PARAGRAPH.format(z) for z in ZONES]
    body = "\n\n".join(paras[:2]) + "\n" + FORMULA + "\n" + "\n\n".join(paras[2:])
    (src / "main.tex").write_text("\\documentclass{}{{article}}\n\\begin{{document}}\n{}\n\\end{{document}}\n".format(
        "[twocolumn]" if twocolumn else "", body))
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Cold starts", "student": "Lin Zhou"}, quiet)
    state = api.ingest({"paper": str(paper), "source": str(src)}, quiet)["state"]
    return paper, state["round"]["build"]["pdf"]


def _formula_box(pdf):
    """A box drawn around the display formula (the words level with its number, in its column), plus 6 pt."""
    words = pymupdf.open(pdf)[0].get_text("words")
    num = next(w for w in words if w[4] == "(1)")
    line = [pymupdf.Rect(w[:4]) for w in words if abs(w[1] + w[3] - num[1] - num[3]) < 12 and w[2] <= num[2]]
    box = line[0]
    for r in line[1:]:
        box |= r
    return [list(box + (-6, -6, 6, 6))]


def _comment(paper, page, rects, note, kind="highlight", color="yellow"):
    return api.comment({"paper": str(paper), "page": page, "rects": rects, "text": "", "note": note, "kind": kind,
                        "color": color}, quiet)["id"]


def _finish(paper):
    """finish, then the same render again for the margin items it placed."""
    api.finish({"paper": str(paper)}, quiet)
    out = paper / "r1" / "again.pdf"
    placed = render.final_pdf(paper, ledger.load(paper), 1, out)
    return pymupdf.open(paper / "r1" / "final.pdf"), placed


def _no_overlaps(placed):
    for i, a in enumerate(placed):
        for b in placed[i + 1:]:
            if (a["page"], a["side"]) == (b["page"], b["side"]):
                assert not a["rect"].intersects(b["rect"]), (a, b)


def _margin_words(page, x0, x1):
    """The words of a final.pdf page outside the paper, which lies between x0 and x1."""
    return [w[4] for w in page.get_text("words") if w[2] <= x0 + 0.5 or w[0] >= x1 - 0.5]


def test_two_column(tmp_path):
    paper, pdf = _paper(tmp_path, twocolumn=True)
    build = pymupdf.open(pdf)
    pw, ph = build[0].rect.width, build[0].rect.height
    first = {z: select(pdf, 0, "In the {} zone,".format(z)) for z in ZONES[:12]}
    left = next(z for z, r in first.items() if r[0][2] < pw / 2)
    right = next(z for z, r in first.items() if r[0][0] > pw / 2)
    ids = {"left": _comment(paper, 0, first[left], CHINESE, color="blue"),
           "right": _comment(paper, 0, first[right], "Say which platforms.", kind="underline"),
           "strike": _comment(paper, 0, select(pdf, 0, "Requests in the {} zone".format(right)), "", kind="strikeout"),
           "click": _comment(paper, 0, [[pw - 60, first[right][0][3] + 30] * 2], "Add a summary here.", kind="note"),
           "box": _comment(paper, 0, _formula_box(pdf), "Which base is the log?", kind="box", color="purple")}
    final, placed = _finish(paper)

    # sizes: margins on both sides of each paper page; the summary at the paper's own size, so it prints at 100%
    assert final.page_count == build.page_count + 1
    assert all(final[i + 1].rect == pymupdf.Rect(0, 0, pw + 2 * render.MARGIN, ph) for i in range(build.page_count))
    assert final[0].rect == build[0].rect
    # every comment: one margin item, left-column ones in the left margin, right-column ones in the right margin
    side = {p["id"]: p for p in placed}
    assert sorted(side) == sorted(ids.values())
    assert side[ids["left"]]["side"] == "L" and side[ids["left"]]["rect"].x1 <= render.MARGIN
    assert all(side[ids[k]]["side"] == "R" and side[ids[k]]["rect"].x0 >= render.MARGIN + pw
               for k in ("right", "strike", "click"))
    _no_overlaps(placed)
    words = _margin_words(final[1], render.MARGIN, render.MARGIN + pw)
    assert all(words.count(cid) == 1 for cid in ids.values())  # each header once
    paper_words = [w[4] for w in final[1].get_text("words")]
    assert all(paper_words.count(cid) == 2 for cid in ids.values())  # the chip, and the header
    # the paper's words are where they were, moved right by the left margin
    moved = {(round(w[0] - render.MARGIN, 1), round(w[1], 1), w[4]) for w in final[1].get_text("words")}
    assert {(round(w[0], 1), round(w[1], 1), w[4]) for w in build[0].get_text("words")} <= moved
    # no PDF annotation besides the paper's links (a reader showed each note again in a popup); each mark is burned
    # in over its anchor in its colour and kind
    assert all(a.type[1] == "Link" for page in final for a in page.annots())
    fill, ink = ({k: tuple(round(v, 2) for v in render._rgb(c[i])) for k, c in comments.PALETTE.items()}
                 for i in (0, 1))
    assert ("highlight", fill["blue"]) in burned(final[1], first[left], render.MARGIN)
    assert ("box", ink["purple"]) in burned(final[1], _formula_box(pdf), render.MARGIN)
    # Chinese in an embedded CJK font, and its glyphs are drawn
    assert CHINESE in final[1].get_text() and CHINESE in final[0].get_text()
    spans = [s for b in final[1].get_text("rawdict")["blocks"] for line in b.get("lines", ()) for s in line["spans"]
             if any(ch["c"] == "熵" for ch in s["chars"])]
    assert spans and all(any(n in s["font"] for n in ("Hiragino", "Heiti", "Droid")) for s in spans)
    bbox = next(ch["bbox"] for ch in spans[0]["chars"] if ch["c"] == "熵")
    pix = final[1].get_pixmap(clip=pymupdf.Rect(bbox), matrix=pymupdf.Matrix(4, 4), colorspace=pymupdf.csGRAY)
    assert sum(1 for v in pix.samples if v < 128) > 20
    # the summary is a line per comment (design/comments/PLAN.md P0.1): no quotes of the formula, and no pictures
    # but the page strip's, one a page (design/summary-page)
    summary = final[0]
    assert len(summary.get_images()) == len(final) - 1 and "H :=" not in summary.get_text()
    assert [final[i].get_label() for i in range(3)] == ["Summary", "1", "2"]
    toc = final.get_toc()
    assert toc[0][1:] == ["Summary", 1] and toc[1][1] == "Comments (5)" and len(toc) >= 7
    assert sorted(t[1].split(" · ")[0] for t in toc[2:7]) == sorted(ids.values())  # the comments list


def test_crowded_page(tmp_path):
    """Many long comments on one page of a one-column paper: every note whole in the margin's one size, never
    overlapping; those the margin cannot hold in the band under the paper, and that page taller."""
    paper, pdf = _paper(tmp_path, twocolumn=False)
    build = pymupdf.open(pdf)
    pw, ph = build[0].rect.width, build[0].rect.height
    zones = [z for z in ZONES if pymupdf.open(pdf)[0].search_for("In the {} zone,".format(z))]
    note = "这一句太长，拆成两句。 " + "The claim needs a number and a citation, or soften it. " * 3
    ids = [_comment(paper, 0, select(pdf, 0, "In the {} zone,".format(z)), note) for z in zones]
    ids += [_comment(paper, 0, select(pdf, 0, "Requests in the {} zone".format(z)), note, kind="underline")
            for z in zones]
    assert len(ids) >= 12
    final, placed = _finish(paper)
    first = final.page_count - build.page_count  # a line per comment: one summary page holds them all
    assert first == 1 and [final[i].get_label() for i in range(first + 1)] == ["Summary", "1"]
    page = final[first]
    assert page.rect.width == pw + render.MARGIN and page.rect.height > ph  # taller, never wider
    assert final[first + 1].rect == pymupdf.Rect(0, 0, pw + render.MARGIN, ph)  # a page that fits keeps its size
    assert all(final[k].rect == build[0].rect for k in range(first))  # the paper's own size: printed at 100%
    assert sorted(p["id"] for p in placed) == sorted(ids) and {p["side"] for p in placed} == {"R", "B"}
    _no_overlaps(placed)
    assert all(40 <= p["rect"].y0 and p["rect"].y1 <= ph - 20 for p in placed if p["side"] == "R")
    assert all(ph < p["rect"].y0 and p["rect"].y1 <= page.rect.height - 20 for p in placed if p["side"] == "B")
    assert all(p["leader"] is None for p in placed if p["side"] == "B")
    words = [w[4] for w in page.get_text("words") if w[2] <= 0.5 or w[0] >= pw - 0.5 or w[1] >= ph]  # margin, band
    assert {cid: words.count(cid) for cid in ids} == {cid: 1 for cid in ids}
    text = page.get_text()
    assert text.count("soften") == 3 * len(ids) and "Continued from the margin" in text  # whole, every one
    lg = ledger.load(paper)  # the outline's comments land at their words on the grown page (set_toc assumed y0 0)
    want = {c["id"]: max(0, render._target(c, 1)[1] - 60) for c in lg["comments"]}
    got = {t[1].split(" · ")[0]: t[3]["to"].y for t in final.get_toc(simple=False) if t[2] == first + 1}
    assert got and all(abs(got[cid] - want[cid]) < 1 for cid in got)
    for p in placed:  # a band item's chip has its pointer down
        if p["side"] == "B":
            assert any(d["fill"] and abs(d["rect"].y1 - p["chip"].y1 - 1.7) < 0.2 and p["chip"].x0 < d["rect"].x0
                       and d["rect"].x1 < p["chip"].x1 for d in page.get_drawings())


def _ctx(text, sel=None, display="text"):
    return {"text": text, "sel": sel if sel is not None else [[0, len(text)]], "display": display, "cut": None}


def test_change_lines_use_printed_words():
    """'your change' lines quote what the PDF prints (the change contexts of amendment "Changes tab"), and the LaTeX
    source when the context has no words of the change's own: formatting, a formula's glyphs, a footnote mark's whole
    sentence, or the same words on both sides."""
    def line(kind, old, new, before, now):
        return render._change_text({"kind": kind, "old_text": old, "new_text": new,
                                    "context": {"before": before, "now": now}}, 90)
    assert line("replace", "34.7", "35.2", _ctx("34.7%"), _ctx("35.2%")) == "“34.7%” → “35.2%”"
    assert line("replace", "011", "021", _ctx("9,011", [], "image"), _ctx("9,021", [], "image")) == \
        "“9,011” → “9,021”"
    assert line("delete", "Mem0 & -1.24 & -1.12 \\\\", "", _ctx("Mem0 -1.24 -1.12", [], "image"), None) == \
        "deleted “Mem0 -1.24 -1.12”"
    assert line("insert", "", "\\subsection{Prompting} \\label{app:p}", _ctx("", []),
                _ctx("C.2 Prompting", [[4, 13]])) == "added “Prompting”"
    assert line("replace", "\\sum_{j=1}^{M} p_j", "\\sum_{j=1}^{N} p_j", _ctx("H := – M X j=1 pj", [], "image"),
                _ctx("H := – N X j=1 pj", [], "image")) == \
        "“\\sum_{j=1}^{M} p_j” → “\\sum_{j=1}^{N} p_j”"  # a formula's glyphs
    sentence = "Each query gets five responses from an LLM, grouped by a judge into classes. 1See §4.2 for details."
    assert line("replace", "\\footnote{See", "(", _ctx(sentence), _ctx("", [])) == "“\\footnote{See” → “(”"
    assert line("replace", "effort", "Effort", _ctx("effort"), _ctx("effort")) == "“effort” → “Effort”"
    assert line("move", "\\textbf{Setup.} We run", "\\textbf{Setup.} We run", _ctx("Setup. We run"),
                _ctx("Setup. We run")) == "moved “Setup. We run”"
    assert render._change_text({"kind": "insert", "old_text": "", "new_text": "x"}) == "added “x”"  # no context
    # in a table: named after it; an \input line or formatting: what it did, in words (cards.describe)
    assert render._change_text({"kind": "replace", "old_text": "011", "new_text": "021", "float": "Table 2",
                                "context": {"before": _ctx("9,011", [], "image"), "now": _ctx("9,021", [], "image")}}) \
        == "Table 2: “9,011” → “9,021”"
    assert render._change_text({"kind": "delete", "old_text": "\\input{figs/plot}", "new_text": "", "float": None,
                                "about": {"kind": "file", "text": "Figure 'plot' removed"}}) == "Figure 'plot' removed"


def _synthetic(cid, y, note):
    """A comment of round 1 on page 0 at height y, as the ledger holds it (no TeX)."""
    return {"id": cid, "kind": "highlight", "color": "yellow", "created_round": 1, "note": note,
            "rounds": {"1": {"anchor": {"page": 0, "rects": [[100, y, 300, y + 10]], "text": "the words"},
                             "anchor_state": "exact", "verdict": None, "verdict_note": ""}}}


def test_an_overfull_margin_keeps_every_item_on_the_page():
    """Review fixes, 2026-10-24 (M4), as of 2026-10-30 (P0.1): items may stand closer together (GAP / 2); when even
    that overflows a side, that side's changes no comment asked for go (the summary lists them), then its tallest
    comments, the lowest of equals first, to the band under the paper, whole, in the margin's one size; the page grows
    by the band. No item goes above the margin's header (y 44), past the paper's foot, or off the page: they went to
    y = -178 with 56 changes on a page."""
    def review(cs, changes):
        page = pymupdf.open().new_page(width=612, height=792)
        placed = render._review_page(page, 0, 1, cs, changes, (False, (72, 540), None), "Round 1 review, final", {})
        assert all(44 <= p["rect"].y0 and p["rect"].y1 <= 792 - 24 + 0.01 for p in placed if p["side"] != "B")
        assert all(792 < p["rect"].y0 and p["rect"].y1 <= page.rect.height - 24 + 0.01
                   for p in placed if p["side"] == "B")
        _no_overlaps(placed)
        return page, placed

    note = "The claim needs a number and a citation, or soften it. " * 4
    changes = [{"id": "c{}".format(k), "page": 0, "rects": [[100, 60 + 12 * k, 200, 69 + 12 * k]], "attached_to": [],
                "kind": "insert", "old_text": "", "new_text": "the new words {}".format(k)} for k in range(56)]
    few = [_synthetic("R1-{:02d}".format(k + 1), 100 + 120 * k, note) for k in range(5)]
    page, placed = review(few, changes)  # without the changes the comments fit, in full
    assert sorted(p["id"] for p in placed) == [c["id"] for c in few] and page.rect.height == 792
    assert page.get_text().count("soften") == 5 * 4 and "your change" not in page.get_text()
    page, placed = review(few, changes[:10])  # a side that fits keeps its changes
    assert len(placed) == 15 and page.get_text().count("your change") == 10
    for count in (12, 22, 36):
        cs = [_synthetic("R1-{:02d}".format(k + 1), 60 + 700 * k // count, note) for k in range(count)]
        page, placed = review(cs, changes)
        assert sorted(p["id"] for p in placed) == [c["id"] for c in cs]
        text = page.get_text()
        assert all(text.count("{} · new".format(c["id"])) == 1 for c in cs) and text.count("soften") == 4 * count
        side = sorted((p for p in placed if p["side"] == "R"), key=lambda p: p["id"])
        band = [p for p in placed if p["side"] == "B"]
        assert band and page.rect.height > 792 and "your change" not in text
        assert [p["id"] for p in side] == [c["id"] for c in cs[:len(side)]]  # equals: the lowest went below
        gaps = [b["rect"].y0 - a["rect"].y1 for a, b in zip(side, side[1:])]
        assert min(gaps) >= render.GAP / 2 - 0.01
        assert {round(p["rect"].x0) for p in band} <= {round(812 - 188 - k * (612 / 3)) for k in range(4)}

    # the tallest goes first, wherever it stands: a long note at the top, short ones below it
    cs = [_synthetic("R1-01", 80, note * 6)] + [_synthetic("R1-{:02d}".format(k + 2), 160 + 50 * k, "Typo.")
                                               for k in range(12)]
    page, placed = review(cs, [])
    assert [p["id"] for p in placed if p["side"] == "B"] == ["R1-01"]

    # a two-column page: both margins overfull; the band in reading order, the left column first, on the 5-slot grid
    page = pymupdf.open().new_page(width=612, height=792)
    left = [_synthetic("R1-{:02d}".format(k + 1), 60 + 40 * k, note) for k in range(18)]
    right = [dict(_synthetic("R1-{:02d}".format(k + 31), 60 + 40 * k, note)) for k in range(18)]
    for c in right:
        c["rounds"]["1"]["anchor"]["rects"] = [[340, r[1], 540, r[3]] for r in c["rounds"]["1"]["anchor"]["rects"]]
    placed = render._review_page(page, 0, 1, left + right, [], (True, (54, 558), 306), "Round 1 review, final", {})
    _no_overlaps(placed)
    band = sorted((p for p in placed if p["side"] == "B"), key=lambda p: (round(p["rect"].y0), p["rect"].x0))
    assert {p["id"] < "R1-31" for p in band} == {True, False} and page.rect.width == 1012
    order = [p["id"] for p in band]
    assert order == sorted(order)  # across, row by row: the left column's comments, then the right's
    assert {round(p["rect"].x0) for p in band} == {round(824 - k * 203) for k in range(5)}  # every column used

    # fewer items than columns stand in the band's middle (they stood at its right, the left of it empty)
    cs = [_synthetic("R1-01", 80, note * 6), _synthetic("R1-02", 90, note * 6)] + \
        [_synthetic("R1-{:02d}".format(k + 3), 160 + 50 * k, "Typo.") for k in range(12)]
    page = pymupdf.open().new_page(width=612, height=792)
    placed = render._review_page(page, 0, 1, cs, [], (False, (72, 540), None), "Round 1 review, final", {})
    band = sorted((p["rect"] for p in placed if p["side"] == "B"), key=lambda r: r.x0)
    assert len(band) == 2 and abs((band[0].x0 + band[-1].x1) / 2 - (12 + 624 + 176) / 2) < 0.5

    # a page 504 pt wide (7 x 10 in): the band's columns never overlap (a rounded-up grid put them 168 pt apart)
    page = pymupdf.open().new_page(width=504, height=720)
    cs = [_synthetic("R1-{:02d}".format(k + 1), 60 + 600 * k // 40, note) for k in range(40)]
    placed = render._review_page(page, 0, 1, cs, [], (False, (54, 450), None), "Round 1 review, final", {})
    _no_overlaps(placed)
    assert len({round(p["rect"].x0) for p in placed if p["side"] == "B"}) >= 2


def test_a_note_longer_than_a_page(tmp_path):
    """Review fixes, 2026-10-24 (m3): a long note never runs past the summary page's bottom edge. The email keeps the
    whole note. 2026-10-30 (P0.1): taller than the margin, the note goes whole to the band under the paper, and the page
    grows to hold it; 2026-11-05 (P0.1, the summary half): its summary row is its first line, cut with "…"."""
    paper, pdf = _paper(tmp_path, twocolumn=False)
    note = " ".join("Sentence {} of a long note about the amber zone.".format(k) for k in range(60))
    assert len(note) > 2400
    _comment(paper, 0, select(pdf, 0, "In the amber zone,"), note)
    final, placed = _finish(paper)
    first = final.page_count - pymupdf.open(pdf).page_count
    for k in range(first):
        assert all(w[3] <= final[k].rect.height - 36 for w in final[k].get_text("words"))
    summary = " ".join(" ".join(w[4] for w in final[k].get_text("words")) for k in range(first))
    assert "Sentence 0 of" in summary and "Sentence 3 of" not in summary and "(full text in the email)" not in summary
    assert "…" in summary  # its first line, cut: the margin's box (the band here) holds it whole
    assert "  " + note + "\n" in (paper / "r1" / "email.txt").read_text(encoding="utf-8")
    assert len(placed) == 1 and placed[0]["side"] == "B" and placed[0]["rect"].y1 <= final[first].rect.height - 24 + 0.01
    words = " ".join(w[4] for w in final[first].get_text("words"))
    assert "Sentence 0 of" in words and "Sentence 59 of" in words


def test_follow_up_notes_in_the_summary_and_the_email():
    """Review fixes, 2026-10-24: a follow-up without a note of its own keeps the earlier follow-up's reason in
    final.pdf, as the email does (m26); in the email each line of a multi-line follow-up is indented under its id,
    as the note's own lines are (m27)."""
    def rec(verdict=None, note="", **extra):
        return dict({"anchor": None, "anchor_state": "orphan", "verdict": verdict, "verdict_note": note}, **extra)
    c = {"id": "R1-01", "created_round": 1, "note": "Say which platforms.\nAnd cite them.",
         "rounds": {"1": rec(), "2": rec("reopened", "Still vague.\n\nName two."), "3": rec("reopened")}}
    assert render._texts(c, 2) == ("Still vague.\n\nName two.", "Round 1: " + c["note"])
    assert render._texts(c, 3) == (c["note"], "Round 2 (follow-up): Still vague.\n\nName two.")
    back = {"id": "R1-02", "created_round": 1, "note": "Define H.",
            "rounds": {"1": rec(), "2": rec("verified"),
                       "3": rec(None, "Back again.\nSee eq. 1.", revived={"from": 2})}}
    lg = {"paper": {"title": "Cold starts"}, "comments": [c, back]}
    for n in (2, 3):
        email = render.email_text(lg, n)
        entries = email.split("\n\n")[2:]  # after the title and the rule: the groups
        assert entries and all(line.startswith("  ") for e in entries for line in e.splitlines()[2:]), email
    assert "  Round 2: Still vague.\n  Name two.\n" in render.email_text(lg, 2)
    assert "  Round 2 (follow-up): Still vague.\n  Name two.\n" in render.email_text(lg, 3)
    assert "R1-02  location not found\n  Define H.\n  Closed in Round 2 (resolved), reopened in Round 3.\n" \
           "  Round 3: Back again.\n  See eq. 1.\n" in render.email_text(lg, 3)


def test_outline_items_without_a_page():
    """Review fixes, 2026-10-24 (m5): the paper's outline items without a page (web links) are left out and their
    children move up, so the outline stays valid: a level 3 after a level 1 made set_toc refuse, and Finish fail."""
    doc = pymupdf.open()
    for _ in range(4):
        doc.new_page()
    web = {"kind": pymupdf.LINK_URI, "uri": "https://example.com"}
    doc.set_toc([[1, "Links", -1, web], [2, "Code", 2], [1, "Intro", 2], [1, "More", -1, web], [2, "Site", -1, web],
                 [3, "Setup", 3], [1, "End", 4]])
    render._outline(doc, 1, [], 1)
    assert doc.get_toc() == [[1, "Summary", 1], [1, "Code", 2], [1, "Intro", 2], [2, "Setup", 3], [1, "End", 4]]
