"""A review folder moved whole after its rounds were built, as Paperole Dev's moves when the app is renamed
(~/PaperCollab Dev Reviews to ~/Paperole Dev Reviews, the advisor's decision of 2026-10-27; mac/UX.md §34): nothing in
it is rewritten, its .synctex files still name the old place, and the paper reads and works as it did there."""
import gzip
import json
import os
import shutil

import pymupdf

from conftest import FIXTURE, quiet, select
from paperole import api, ledger, overview
from test_data_safety import needs_tex

pytestmark = needs_tex


def call(method, paper, **params):
    return api.METHODS[method](dict(params, paper=str(paper)), quiet)


def seen(paper, was=None):
    """What the app reads of a paper (each round's state, the overview, the folder's check), its own path written as
    <paper>; and the path it was built at (was), which its builds' logs name."""
    out = {"states": [call("state", paper, round=r["n"]) for r in ledger.load(paper)["rounds"]],
           "overview": overview.paper_overview(paper), "check": api.METHODS["check"]({"papers": [str(paper)]}, quiet)}
    text = json.dumps(out).replace(str(paper), "<paper>")
    return json.loads(text.replace(str(was), "<paper>") if was else text)


def phrase(pdf, page, at, k=4):
    """k words of a PDF's page from word number at, and their rects."""
    words = [w[4] for w in pymupdf.open(pdf)[page].get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP)]
    text = " ".join(words[at:at + k])
    return text, select(pdf, page, text)


def work(paper):
    """A comment of the open round placed through synctex, placed again elsewhere, and the round finished: the
    comment's record and what the student receives."""
    pdf = str(paper / "r2" / "build" / "main.pdf")
    text, rects = phrase(pdf, 0, 40)
    cid = call("comment", paper, page=0, rects=rects, text=text, note="Say which.", kind="highlight")["id"]
    placed = ledger.get_comment(ledger.load(paper), cid)["rounds"]["2"]["anchor"]
    text, rects = phrase(pdf, 1, 60)
    call("reanchor", paper, id=cid, page=1, rects=rects, text=text)
    call("finish", paper)
    record = ledger.get_comment(ledger.load(paper), cid)["rounds"]["2"]
    final = pymupdf.open(str(paper / "r2" / "final.pdf"))
    return {"placed": placed, "record": {k: v for k, v in record.items() if k != "verdict_at"},
            "email": (paper / "r2" / "email.txt").read_text(), "final": [p.get_text() for p in final]}


def test_a_review_folder_renamed_whole_works_as_before(tmp_path):
    old, new = tmp_path / "PaperCollab Dev Reviews", tmp_path / "Paperole Dev Reviews"
    paper = old / "Warm pools"
    call("new", paper, title="Warm pools", student="Lin Zhou")
    call("ingest", paper, source=str(FIXTURE / "v1"))
    pdf = str(paper / "r1" / "build" / "main.pdf")
    call("comment", paper, page=0, rects=select(pdf, 0, "simple keep-alive policy:"), text="", note="Which?",
         kind="highlight")
    call("finish", paper)
    call("ingest", paper, source=str(FIXTURE / "v2"))
    synctex = (paper / "r2" / "build" / "main.synctex.gz").read_bytes()
    assert str(paper).encode() in gzip.decompress(synctex)  # synctex names its inputs by their absolute paths
    snapshot = tmp_path / "snapshot"
    shutil.copytree(paper, snapshot)
    before, in_old_place = seen(paper), work(paper)
    # placed on its words in the source, through synctex, both times
    assert in_old_place["placed"]["file"].endswith(".tex") and in_old_place["record"]["method"] == "selection"

    shutil.rmtree(paper)  # back as it was before the work, in its first place, then the whole folder renamed
    shutil.copytree(snapshot, paper)
    lg = (paper / "ledger.json").read_bytes()
    os.rename(old, new)
    moved = new / "Warm pools"
    assert not old.exists() and (moved / "ledger.json").read_bytes() == lg
    assert (moved / "r2" / "build" / "main.synctex.gz").read_bytes() == synctex  # still names the old place
    assert seen(moved, was=paper) == before
    assert json.loads(json.dumps(work(moved)).replace(str(moved), str(paper))) == in_old_place
    assert not old.exists()  # nothing was written in the old place
