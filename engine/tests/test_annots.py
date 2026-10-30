import hashlib
import re
from collections import Counter
from pathlib import Path

import pymupdf
import pytest

from paperole import annots

LINES = [
    "The quick brown fox jumps over the lazy dog today.",
    "Our method improves calibration on every benchmark distil-",
    "lation training reaches the same accuracy at lower cost.",
    "Reviewers asked for a clearer statement of the main result.",
    "Figures should use the same font as the body text here.",
]
SAMPLES = Path(__file__).resolve().parents[2] / "samples" / "ann_pdf"


def _quads(page, *phrases):
    return [q for p in phrases for q in page.search_for(p, quads=True)]


@pytest.fixture
def synthetic(tmp_path):
    """A two-page PDF with known text and one of each annotation form; returns (path, xrefs by name)."""
    doc = pymupdf.open()
    page = doc.new_page()
    for i, line in enumerate(LINES):
        page.insert_text((72, 100 + 16 * i), line, fontsize=11, fontname="helv")
    x = {}

    a = page.add_highlight_annot(_quads(page, "quick brown fox"))
    a.set_info(content="Too informal.\nquick brown fox", title="Advisor")
    a.set_popup(pymupdf.Rect(400, 80, 550, 140))
    a.update()
    x["copied"] = a.xref
    a = page.add_highlight_annot(_quads(page, "lazy dog"))
    a.set_info(content="Odd example.\nA calmer sentence would read better.")
    x["rewrite"] = a.xref
    a = page.add_highlight_annot(_quads(page, "calibration"))
    a.set_info(content="不适合叫calibration")  # ends in the quoted word, but is not a copy of it
    x["ends_in_quote"] = a.xref
    lazy = page.search_for("lazy")[0]  # a text box over the highlighted words
    x["over_body"] = page.add_freetext_annot(pymupdf.Rect(lazy.x0, lazy.y0, lazy.x0 + 100, lazy.y1), "BOXNOTE", fontsize=8).xref
    x["hyphen"] = page.add_highlight_annot(_quads(page, "distillation training")).xref
    x["underline"] = page.add_underline_annot(_quads(page, "clearer statement")).xref
    a = page.add_strikeout_annot(_quads(page, "same font"))
    a.set_info(content="Use another word.")
    x["strike"] = a.xref
    x["sticky"] = page.add_text_annot((520, 140), "Explain the result.").xref
    x["margin"] = page.add_freetext_annot(pymupdf.Rect(450, 156, 580, 172), "MARGINNOTE font", fontsize=8).xref
    x["rect_word"] = page.add_rect_annot(page.search_for("Figures")[0] + (-2, -2, 2, 2)).xref
    x["rect_empty"] = page.add_rect_annot(pymupdf.Rect(72, 300, 100, 320)).xref
    acc = page.search_for("accuracy")[0] + (-3, -3, 3, 3)
    x["ink"] = page.add_ink_annot([[tuple(p) for p in (acc.tl, acc.tr, acc.br, acc.bl, acc.tl)]]).xref
    tight = acc * page.transformation_matrix  # Acrobat's /Rect hugs the strokes; MuPDF pads it by 7pt
    doc.xref_set_key(x["ink"], "Rect", "[{} {} {} {}]".format(*tight))

    lower, cost = page.search_for("lower")[0], page.search_for("cost.")[0]
    a = page.add_caret_annot(lower.br)
    a.set_info(content="computational")
    mid = (lower.x1 + cost.x0) / 2  # Acrobat centres the caret on the insertion point
    a.set_rect(pymupdf.Rect(mid - 3, lower.y1 - 6, mid + 3, lower.y1))
    x["caret"] = a.xref

    a = page.add_text_annot((300, 300), "Changed it.")
    a.set_info(title="Student")
    x["reply"] = a.xref
    doc.xref_set_key(a.xref, "IRT", "{} 0 R".format(x["rewrite"]))
    doc.xref_set_key(a.xref, "RT", "/R")

    same = page.search_for("same accuracy")[0]
    a = page.add_caret_annot(same.br)
    a.set_info(content="equal accuracy")
    x["group_caret"] = a.xref
    a = page.add_strikeout_annot(_quads(page, "same accuracy"))
    x["group_strike"] = a.xref
    doc.xref_set_key(a.xref, "IRT", "{} 0 R".format(x["group_caret"]))
    doc.xref_set_key(a.xref, "RT", "/Group")

    x["stamp"] = page.add_stamp_annot(pymupdf.Rect(400, 500, 550, 550), stamp=0).xref
    page.insert_link({"kind": pymupdf.LINK_URI, "from": pymupdf.Rect(72, 400, 200, 412), "uri": "https://example.com"})
    for name, obj in (("foo", "<</Type/Annot/Subtype/Foo/Rect[72 600 140 640]/Contents(Foo note)>>"),
                      ("no_subtype", "<</Type/Annot/Rect[72 600 140 640]>>")):
        n = doc.get_new_xref()  # an unknown subtype and a missing one, which page.annot_xrefs() leaves out
        doc.update_object(n, obj)
        doc.xref_set_key(page.xref, "Annots", doc.xref_get_key(page.xref, "Annots")[1][:-1] + " {} 0 R]".format(n))
        x[name] = n

    page2 = doc.new_page()
    page2.insert_text((72, 100), "A second page with one marked phrase.", fontsize=11, fontname="helv")
    x["page2"] = page2.add_highlight_annot(_quads(page2, "marked phrase")).xref
    a = page2.add_text_annot((520, 90), "plain")
    x["rich"] = a.xref
    doc.xref_set_key(a.xref, "Contents", "()")
    doc.xref_set_key(a.xref, "RC", "(<body><p>Rich &amp; text note</p><p>second paragraph</p></body>)")

    path = tmp_path / "synthetic.pdf"
    doc.save(path)
    return path, x


def _by_xref(result):
    return {c["xref"]: c for c in result["comments"]}


def test_quotes_and_notes(synthetic):
    path, x = synthetic
    page = pymupdf.open(path)[0]
    assert "BOXNOTE" in page.get_text() and "MARGINNOTE" in page.get_text()  # the pitfall is present
    c = _by_xref(annots.extract(path))

    assert all("BOXNOTE" not in v["quote"] + v["prefix"] + v["suffix"] for v in c.values())
    assert all("MARGINNOTE" not in v["quote"] + v["prefix"] + v["suffix"] for v in c.values())
    assert c[x["copied"]]["quote"] == "quick brown fox"
    assert c[x["copied"]]["note"] == "Too informal."
    assert c[x["copied"]]["author"] == "Advisor"
    assert c[x["copied"]]["prefix"] == "The"
    assert c[x["copied"]]["suffix"].startswith("jumps over the lazy dog")
    assert c[x["rewrite"]]["quote"] == "lazy dog"
    assert c[x["rewrite"]]["note"] == "Odd example.\nA calmer sentence would read better."
    assert c[x["ends_in_quote"]]["quote"] == "calibration"
    assert c[x["ends_in_quote"]]["note"] == "不适合叫calibration"
    assert c[x["hyphen"]]["quote"] == "distillation training"
    assert c[x["strike"]]["quote"] == "same font"
    assert c[x["strike"]]["note"] == "Use another word."
    assert c[x["rect_word"]]["quote"] == "Figures"
    assert c[x["ink"]]["quote"] == "accuracy"
    assert c[x["caret"]]["quote"] == "lower cost."
    assert c[x["caret"]]["note"] == "computational"
    assert c[x["sticky"]]["quote"] == LINES[3]
    assert c[x["margin"]]["quote"] == LINES[4]
    assert c[x["margin"]]["note"] == "MARGINNOTE font"
    assert c[x["over_body"]]["quote"] == "The quick brown fox jumps over the lazy dog today."
    assert c[x["rect_empty"]]["quote"] == LINES[4]
    assert c[x["rich"]]["note"] == "Rich & text note\nsecond paragraph"
    assert c[x["copied"]]["rect"][1] < c[x["copied"]]["rect"][3]  # PDF coordinates: y grows upwards
    assert c[x["copied"]]["rect"][3] > 700


def test_flags(synthetic):
    path, x = synthetic
    c = _by_xref(annots.extract(path))
    guessed = {k for k, v in x.items() if v in c and c[v]["flags"]["position_guessed"]}
    mark_only = {k for k, v in x.items() if v in c and c[v]["flags"]["mark_only"]}
    assert guessed == {"over_body", "sticky", "margin", "rect_empty", "rich"}
    assert mark_only == {"hyphen", "underline", "rect_word", "rect_empty", "ink", "page2"}


def test_replies_groups_and_ignored(synthetic):
    path, x = synthetic
    result = annots.extract(path)
    c = _by_xref(result)
    assert x["reply"] not in c and x["group_strike"] not in c
    assert c[x["rewrite"]]["thread"] == [
        {"author": "Student", "text": "Changed it.", "date": c[x["rewrite"]]["thread"][0]["date"]}]
    group = c[x["group_caret"]]
    assert group["merged"] == [x["group_strike"]]
    assert group["quote"] == "same accuracy" and group["note"] == "equal accuracy"
    assert Counter(a["annot_type"] for a in result["ignored"]) == Counter({"Stamp": 1, "Link": 1, "Foo": 1, "(none)": 1})
    assert {a["page"] for a in result["ignored"]} == {1}
    assert {x["stamp"], x["foo"], x["no_subtype"]} < {a["xref"] for a in result["ignored"]}
    assert _accounted(result) == _non_popup(path)


def test_reading_order_and_ids(synthetic):
    path, x = synthetic
    comments = annots.extract(path)["comments"]
    tops = [(c["page"], round(-c["rect"][3]), c["rect"][0]) for c in comments]
    assert tops == sorted(tops)
    page1 = [c for c in comments if c["page"] == 1]
    assert [c["id"] for c in page1] == ["P1-{:02d}".format(i) for i in range(1, len(page1) + 1)]
    assert [c["id"] for c in comments if c["page"] == 2] == ["P2-01", "P2-02"]
    assert page1[-1]["xref"] == x["rect_empty"]


def test_input_unchanged_and_cli(synthetic, tmp_path):
    path, _ = synthetic
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    annots.main([str(path), "-o", str(tmp_path / "out")])
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before
    report = (tmp_path / "out" / "synthetic.report.md").read_text(encoding="utf-8")
    assert "| P1-01 |" in report and "- Stamp: 1 (pages 1)" in report
    assert (tmp_path / "out" / "synthetic.comments.json").exists()


def test_two_column_page(tmp_path):
    """Notes in the right margin or on the right column stay with the right column, even where a
    left-column line is level with them and the right column's lines are half a line off."""
    doc = pymupdf.open()
    page = doc.new_page()
    for x, top, word in ((50, 100, "Left"), (320, 107, "Right")):  # pdflatex writes one column, then the next
        for k in range(8):
            page.insert_text((x, top + 14 * k), "{} column line {} text.".format(word, k), fontsize=10, fontname="helv")
    y = (page.search_for("Right column line 3")[0].y1 + page.search_for("Right column line 4")[0].y0) / 2
    assert page.search_for("Left column line 4")[0].y0 < y < page.search_for("Left column line 4")[0].y1
    page.add_freetext_annot(pymupdf.Rect(560, y - 6, 590, y + 10), "box", fontsize=8)
    page.add_text_annot((0, 0), "sticky").set_rect(pymupdf.Rect(400, y - 6, 418, y + 12))
    path = tmp_path / "two.pdf"
    doc.save(path)
    for c in annots.extract(path)["comments"]:
        assert c["quote"].startswith("Right column line"), c["note"]
        assert c["flags"]["position_guessed"]


def test_unusual_pages(tmp_path):
    """A rotated page whose CropBox does not start at (0, 0), indirect /QuadPoints and /Contents,
    and a caret on a page without text."""
    doc = pymupdf.open()
    page = doc.new_page()
    for i, line in enumerate(LINES[:3]):
        page.insert_text((72, 100 + 16 * i), line, fontsize=11, fontname="helv")
    page.set_cropbox(pymupdf.Rect(40, 50, 560, 700))
    page.set_rotation(90)
    doc.new_page().add_caret_annot((150, 300)).set_info(content="insert")
    doc = pymupdf.open("pdf", doc.tobytes())
    xref = doc[0].add_highlight_annot(_quads(doc[0], "lazy dog")).xref
    for key, value in (("QuadPoints", doc.xref_get_key(xref, "QuadPoints")[1]), ("Contents", "<FEFF4E0D90025408>")):
        n = doc.get_new_xref()
        doc.update_object(n, value)
        doc.xref_set_key(xref, key, "{} 0 R".format(n))
    path = tmp_path / "unusual.pdf"
    doc.save(path)
    highlight, caret = annots.extract(path)["comments"]
    assert highlight["quote"] == "lazy dog" and highlight["note"] == "不适合"
    assert not highlight["flags"]["position_guessed"]
    assert caret["quote"] == "" and caret["flags"]["position_guessed"]


def _non_popup(path):
    """Entries of the pages' /Annots arrays that are not Popups (page.annot_xrefs() would miss unknown subtypes)."""
    doc = pymupdf.open(path)
    xrefs = [int(n) for page in doc for n in re.findall(r"(\d+) 0 R", doc.xref_get_key(page.xref, "Annots")[1])]
    return sum(1 for xref in xrefs if doc.xref_get_key(xref, "Subtype")[1] != "/Popup")


def _accounted(result):
    return (len(result["comments"]) + len(result["ignored"])
            + sum(len(c["thread"]) + len(c["merged"]) for c in result["comments"]))


@pytest.mark.parametrize("name, types, noted_highlights", [
    ("real-annotated-1.pdf", {"FreeText": 14, "Highlight": 13, "Square": 2, "Ink": 1}, 4),
    ("real-annotated-2.pdf", {"FreeText": 3, "Highlight": 2, "StrikeOut": 1}, 0),
])
def test_real_pdfs(name, types, noted_highlights):
    path = SAMPLES / name
    if not path.exists():
        pytest.skip("sample PDF not present")
    result = annots.extract(path)
    assert Counter(c["annot_type"] for c in result["comments"]) == Counter(types)
    assert sum(1 for c in result["comments"] if c["kind"] == "highlight" and c["note"]) == noted_highlights
    assert {a["annot_type"] for a in result["ignored"]} == {"Link"}
    assert _accounted(result) == _non_popup(path)
    quotes = "".join(c["quote"] + c["prefix"] + c["suffix"] for c in result["comments"])
    assert not any("一" <= ch <= "鿿" for ch in quotes)  # no Chinese note text leaks into quotes
