"""Importing an annotated copy of the round's build PDF."""
import pymupdf
import pytest

from conftest import quiet, select
from paperole import EngineError, api, ledger


def annotate(pdf, out):
    doc = pymupdf.open(pdf)
    pages = list(doc)  # an annotation needs its page object alive
    a = pages[0].add_highlight_annot(select(pdf, 0, "simple keep-alive policy:"))
    a.set_info(content="simple 不准确")
    a.update()
    a = pages[0].add_underline_annot(select(pdf, 0, "Both approaches decide when to keep a single instance alive."))
    a.set_info(content="这句不准确")
    a.update()
    pages[1].add_text_annot((560, 330), "A note in the margin")
    a = pages[2].add_strikeout_annot(select(pdf, 2, "The memory footprint is two floating-point numbers per function."))
    a.set_info(content="多余，删掉。")
    a.update()
    a = pages[2].add_rect_annot((119, 175, 493, 362))  # around Figure 1
    a.set_info(content="图太小")
    a.set_colors(stroke=(0.1, 0.3, 0.9))
    a.update()
    doc.save(out)


def test_import(paper, tmp_path):
    pdf = paper / "r1" / "build" / "main.pdf"
    annotated = tmp_path / "annotated.pdf"
    annotate(pdf, annotated)

    result = api.import_({"paper": str(paper), "pdf": str(annotated)}, quiet)
    assert result["ids"] == ["R1-01", "R1-02", "R1-03", "R1-04", "R1-05"] and result["skipped"] == []
    got = {c["id"]: c for c in result["state"]["comments"]}
    assert [(got[i]["kind"], got[i]["page"], got[i]["source"], got[i]["method"]) for i in result["ids"]] == [
        ("highlight", 0, "import", "import"), ("underline", 0, "import", "import"),
        ("note", 1, "import", "line"), ("box", 2, "import", "import"), ("strikeout", 2, "import", "import")]
    # PyMuPDF's default colours: yellow highlight, green underline (nearest: teal), yellow note, red strikeout
    # (nearest: orange)
    assert [got[i]["color"] for i in result["ids"]] == ["yellow", "teal", "yellow", "blue", "orange"]
    assert got["R1-04"]["text"].startswith("Cold-start rate") and got["R1-04"]["context"]["display"] == "image"
    assert got["R1-02"]["new_quote"] == "Both approaches decide when to keep a\nsingle instance alive."
    assert got["R1-05"]["new_quote"] == "The memory footprint is two floating-point numbers\nper function."
    assert got["R1-01"]["note"] == "simple 不准确" and got["R1-03"]["note"] == "A note in the margin"
    for cid, page, phrase in (("R1-01", 0, "simple keep-alive policy:"),
                              ("R1-05", 2, "The memory footprint is two floating-point numbers per function.")):
        for r, s in zip(got[cid]["rects"], select(pdf, page, phrase)):
            assert all(abs(u - v) < 0.5 for u, v in zip(r, s))
    assert ledger.get_comment(ledger.load(paper), "R1-03")["rounds"]["1"]["anchor"]["position_guessed"]

    again = api.import_({"paper": str(paper), "pdf": str(annotated)}, quiet)
    assert again["ids"] == [] and [s["reason"] for s in again["skipped"]] == [
        "duplicate of R1-01", "duplicate of R1-02", "duplicate of R1-03", "duplicate of R1-04", "duplicate of R1-05"]


def test_import_refuses_other_pdfs(paper, tmp_path):
    size = pymupdf.open(paper / "r1" / "build" / "main.pdf")[0].rect
    for pages, (w, h), message in ((3, (size.width, size.height), "it has 3 pages, the build has 4"),
                                   (4, (595, 842), "page 1 has a different size"),
                                   (4, (size.width, size.height), "the text of page 1 differs")):
        doc = pymupdf.open()
        for _ in range(pages):
            doc.new_page(width=w, height=h).insert_text((72, 72), "Some other paper")
        doc.save(tmp_path / "other.pdf")
        with pytest.raises(EngineError, match="This PDF is not round 1's build PDF: " + message):
            api.import_({"paper": str(paper), "pdf": str(tmp_path / "other.pdf")}, quiet)
    assert ledger.load(paper)["comments"] == []
