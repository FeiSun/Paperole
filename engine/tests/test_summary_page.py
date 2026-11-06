"""final.pdf's summary as a to-do sheet (design/summary-page; engine/CONTRACT.md amendment "Summary page as a to-do
sheet"): the count of what is to do and the bar of every comment's fate, the overall comments whole, the page strip,
a row per comment or past ROWS a row per section, small fixes and Well done, the tag names the app sends; and
`final_preview`, which writes the same final.pdf elsewhere and leaves the ledger and the round as they were. Synthetic
data only."""
import hashlib
import json

import pymupdf
import pytest

from paperole import EngineError, api, render

QUIET = lambda _: None
PARA = ("Small models are cheap to serve and quick to train, so we study how to train them well on a budget that "
        "a single laboratory can afford in a week of work.")
TEX = ("\\documentclass{article}\n\\begin{document}\n\\section{Introduction}\n" + PARA + "\n\n" + PARA + "\n\n"
       "\\section{Method}\n" + PARA + "\n\n\\subsection{Data}\n" + PARA + "\n\n\\section{Results}\n" + PARA + "\n"
       "\\end{document}\n")


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


def _words(paper, n=1):
    """[(page, rects, text)] of every word of round n's PDF, in reading order."""
    doc = pymupdf.open(paper / "r{}/build/main.pdf".format(n))
    out = []
    for pno, page in enumerate(doc):
        for w in page.get_text("words"):
            if w[4].isalpha() and len(w[4]) > 3:
                out.append((pno, [[w[0], w[1], w[2], w[3]]], w[4]))
    return out


def _comment(paper, place, note, tags=()):
    page, rects, text = place
    return call("comment", paper=str(paper), page=page, rects=rects, text=text, note=note, tags=list(tags))["id"]


def _summary(paper, path=None):
    final = pymupdf.open(path or paper / "r1/final.pdf")
    pages = [p for p in final if p.get_label().startswith("Summary")]
    return final, pages, " ".join(" ".join(p.get_text() for p in pages).split())


def test_a_short_round_a_row_each(paper):
    words = _words(paper)
    whole = call("comment", paper=str(paper), kind="overall", note="A clear draft. Tighten the method.")["id"]
    a = _comment(paper, words[0], "Say how cheap: give the cost per query.", ["clarity"])
    b = _comment(paper, words[40], "Which budget? A number, please.", ["evidence"])
    praise = _comment(paper, words[20], "Nicely put.", ["praise"])
    smalls = [_comment(paper, words[k], "Typo.", ["grammar"]) for k in (5, 6, 7)]
    call("finish", paper=str(paper), tag_names={"clarity": "Clear writing"})
    final, pages, text = _summary(paper)
    assert len(pages) == 1
    # 3 rows and the small fixes, the overall comment among them; the praise is done, not to do
    assert "6 to do of 7 comments" in text and "1 closed" in text and "6 new" in text
    assert "Overall (1)" in text and "A clear draft. Tighten the method." in text
    assert text.index("Overall (1)") < text.index("On the pages (5)")
    assert "{} new p.1 §1 Say how cheap: give the cost per query. Clear writing".format(a) in text
    assert "{} new p.1 §2".format(b) in text and "Evidence & citations" in text
    assert "Small fixes · 3" in text and all(s in text for s in smalls)
    assert "Closed (1) Well done 1 p.1 “Nicely put.”" in text and praise not in text  # its words, no chip
    assert whole in text and "Again" not in text
    # the page strip: a picture a page, each a link to its page
    assert len(pages[0].get_images()) == len(final) - 1
    links = [ln for ln in pages[0].get_links() if ln["kind"] == pymupdf.LINK_GOTO]
    assert {ln["page"] for ln in links} >= set(range(1, len(final)))


def test_past_twenty_rows_by_section(paper):
    words = _words(paper)
    ids = [_comment(paper, words[k], "Comment {} on this word.".format(k), ["clarity"]) for k in range(0, 66, 3)]
    assert len(ids) > render.ROWS
    call("finish", paper=str(paper))
    _, _, text = _summary(paper)
    assert "{} to do".format(len(ids)) in text
    # a row per section, its chips in the paper's order; no row per comment
    assert "§1 Introduction" in text and "§2 Method" in text
    assert "Comment 0 on this word." not in text
    assert text.index("§1 Introduction") < text.index("§2 Method")
    assert all(i in text for i in ids)


def test_final_preview_leaves_the_round_as_it_was(paper, tmp_path):
    words = _words(paper)
    cid = _comment(paper, words[0], "Say how cheap.", ["clarity"])
    ledger_file = paper / "ledger.json"
    before = hashlib.sha256(ledger_file.read_bytes()).hexdigest()
    out = tmp_path / "cache" / "final.pdf"
    out.parent.mkdir()
    reply = call("final_preview", paper=str(paper), out=str(out), tag_names={"clarity": "Clear writing"})
    assert reply == {"round": 1, "out": str(out)}
    assert hashlib.sha256(ledger_file.read_bytes()).hexdigest() == before
    assert not (paper / "r1/final.pdf").exists() and not json.loads(ledger_file.read_text())["rounds"][0]["closed"]
    _, _, text = _summary(paper, out)
    assert "{} new p.1 §1 Say how cheap. Clear writing".format(cid) in text
    # what Finish writes is the same page
    call("finish", paper=str(paper), tag_names={"clarity": "Clear writing"})
    assert _summary(paper)[2] == text
    # only a .pdf path of the app's own: never into the paper's folder
    for bad in ("relative.pdf", str(tmp_path / "cache" / "final.txt"), str(tmp_path / "none" / "final.pdf"),
                str(paper / "final.pdf"), str(paper / "r1" / "final.pdf")):
        with pytest.raises(EngineError):
            call("final_preview", paper=str(paper), out=bad)


def test_final_preview_needs_an_open_round_and_good_names(paper, tmp_path):
    out = str(tmp_path / "final.pdf")
    with pytest.raises(EngineError):
        call("final_preview", paper=str(paper), out=out, tag_names={"clarity": 3})
    call("finish", paper=str(paper))
    with pytest.raises(EngineError):
        call("final_preview", paper=str(paper), out=out)


def test_words_no_margin_holds_are_kept(paper, tmp_path):
    """An overall comment closed with a note, or praise on the whole paper, keeps its words on the summary (no margin
    box holds them); a comment with many tags keeps room for its note."""
    words = _words(paper)
    kept = call("comment", paper=str(paper), kind="overall", note="Shorten the abstract to 150 words.")["id"]
    call("comment", paper=str(paper), kind="overall", note="A pleasure to read throughout.", tags=["praise"])
    many = _comment(paper, words[0], "Say how cheap: give the cost per query.",
                    ["clarity", "logic", "evidence", "structure", "figures", "math"])
    call("finish", paper=str(paper))
    src = tmp_path / "source"
    call("ingest", paper=str(paper), source=str(src))
    call("verdict", paper=str(paper), id=kept, verdict="wontfix", note="Fair: the venue allows 250.")
    call("verdict", paper=str(paper), id=many, verdict="verified")
    call("finish", paper=str(paper))
    _, _, text = _summary(paper, paper / "r2/final.pdf")
    assert "No change needed 1 – {} Fair: the venue allows 250. Round 1: Shorten the abstract to 150 words.".format(
        kept) in text
    assert "Well done 1" in text and "A pleasure to read throughout." in text
    _, _, first = _summary(paper)
    assert "Say how cheap: give the cost per query. Clarity +5" in first


TWO = ("\\documentclass[twocolumn]{article}\n\\begin{document}\n\\section{Introduction}\n" + PARA * 3 + "\n\n"
       "\\section{Method}\n" + PARA * 3 + "\n\n\\section{Results}\n" + PARA * 3 + "\n\n"
       "\\section{Discussion}\n" + PARA * 3 + "\n\\end{document}\n")


def test_two_columns_name_the_right_section(tmp_path):
    src = tmp_path / "source"
    src.mkdir()
    (src / "main.tex").write_text(TWO)
    paper = tmp_path / "review"
    call("new", paper=str(paper), title="Two columns", student="Test author")
    call("ingest", paper=str(paper), source=str(src))
    doc = pymupdf.open(paper / "r1/build/main.pdf")
    page = doc[0]
    mid = page.rect.width / 2
    right = [w for w in page.get_text("words") if w[0] > mid and w[4].isalpha() and len(w[4]) > 3]
    w = right[len(right) // 2]  # a word in the right column, beside the left column's text
    heads = {h: page.search_for(h)[0] for h in ("Introduction", "Method", "Results", "Discussion")
             if page.search_for(h)}
    expect = max((r.y0, h) for h, r in heads.items() if r.x0 > mid and r.y0 < w[1])[1] if any(
        r.x0 > mid and r.y0 < w[1] for r in heads.values()) else max(
        (r.y0, h) for h, r in heads.items() if r.x0 < mid)[1]
    number = {"Introduction": "1", "Method": "2", "Results": "3", "Discussion": "4"}[expect]
    cid = _comment(paper, (0, [[w[0], w[1], w[2], w[3]]], w[4]), "A right-column note.")
    call("finish", paper=str(paper))
    _, _, text = _summary(paper)
    assert "{} new p.1 §{} A right-column note.".format(cid, number) in text


def test_a_cancelled_preview_is_dropped(paper, tmp_path):
    class Stopped:  # the RPC's progress once the app asked to cancel the request (a newer preview)
        def __call__(self, message):
            pass

        def cancelled(self):
            return True
    out = tmp_path / "final.pdf"
    with pytest.raises(EngineError, match="Cancelled"):
        api.final_preview({"paper": str(paper), "out": str(out)}, Stopped())
    assert not out.exists()
