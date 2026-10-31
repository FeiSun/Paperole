"""Round 1 end to end through the command line, on fixtures/paper/v1."""
import json
import os
import re
import stat
import subprocess
import sys

import pymupdf

from conftest import FIXTURE, TITLE, burned, equation_rect, select
from paperole import comments, ledger, render


def run(*args, ok=True):
    proc = subprocess.run([sys.executable, "-m", "paperole"] + [str(a) for a in args],
                          capture_output=True, text=True, timeout=600)
    assert (proc.returncode == 0) == ok, proc.stderr
    return json.loads(proc.stdout) if ok else proc.stderr


def rects_arg(rects):
    return ";".join(",".join(str(v) for v in r) for r in rects)


def tree(folder):
    return sorted((str(p.relative_to(folder)), p.stat().st_mtime, p.stat().st_size) for p in folder.rglob("*"))


def test_round1_cli(tmp_path):
    paper = tmp_path / "paper"
    before = tree(FIXTURE / "v1")

    # new
    state = run("new", paper, "--title", TITLE, "--student", "Lin Zhou")["state"]
    pid = state["paper"]["id"]  # random at new (design/data/DATA.md §2.3)
    assert re.fullmatch(r"p-[0-9a-f]{16}", pid)
    assert state == {"schema": 1, "paper": {"path": str(paper), "title": TITLE, "student": "Lin Zhou",
                                            "main": None, "engine": None, "id": pid},
                     "rounds": [], "round": None, "comments": [], "changes": [], "note_warnings": [],
                     "summary": {"round": None, "closed": False, "status": None, "to_judge": 0, "to_check": 0,
                                 "answered": 0, "handled": 0, "closed_at": None, "resumable": False},
                     "reading": None, "tag_names": {}}
    assert "already has a ledger" in run("new", paper, "--title", "x", "--student", "y", ok=False)

    # ingest
    state = run("ingest", paper, FIXTURE / "v1")["state"]
    assert state["paper"]["main"] == "main.tex" and state["paper"]["engine"] == "pdflatex"
    rnd = state["round"]
    assert rnd["n"] == 1 and not rnd["closed"] and rnd["final_pdf"] is None and rnd["email"] is None
    assert rnd["build"]["status"] == "ok" and rnd["build"]["pages"] == 4 and rnd["build"]["errors"] == []
    pdf = rnd["build"]["pdf"]
    assert pdf == str(paper / "r1" / "build" / "main.pdf") and os.path.exists(pdf)
    assert state["rounds"] == [{"n": 1, "created": rnd["created"], "source": str(FIXTURE / "v1"), "closed": False,
                                "closed_at": None, "status": "ok", "pdf": pdf}]
    src = paper / "r1" / "src"
    assert {p.relative_to(src).as_posix() for p in src.rglob("*") if p.is_file()} == \
        {"main.tex", "sections/method.tex", "figures/coldstart.png"}
    assert all(stat.S_IMODE(p.stat().st_mode) == 0o444 for p in src.rglob("*") if p.is_file())
    assert tree(FIXTURE / "v1") == before  # the student's folder is never written

    # comments on real word boxes of the compiled PDF
    def comment(page, rects, note, kind="highlight", text=""):
        out = run("comment", paper, "--page", page, "--rects", rects_arg(rects), "--note", note, "--kind", kind,
                  "--text", text)
        return out["id"], next(c for c in out["state"]["comments"] if c["id"] == out["id"])

    cid, c = comment(0, select(pdf, 0, "a controller that forecasts the arrival rate of each function"), "abstract")
    assert cid == "R1-01"
    assert (c["file"], c["line"]) == ("main.tex", 22)
    assert c["new_quote"] == "a controller that forecasts the arrival rate of each function"
    assert (c["method"], c["confidence"], c["anchor_state"], c["carried"]) == ("selection", 1.0, "new", False)
    assert c["text"] == "a controller that forecasts the arrival rate of each function"

    cid, c = comment(1, select(pdf, 1, "The expected cost of a pool of size"), "式 (2) 里 c_m 的单位和 τ 对不上。")
    assert (c["file"], c["line"], c["new_quote"]) == ("sections/method.tex", 27, "The expected cost of a pool of size")

    cid, c = comment(1, [equation_rect(pdf, 1, "C(k)")], "Eq. 2")
    assert c["file"] == "sections/method.tex" and c["method"] == "selection"
    assert c["new_quote"].startswith("\\begin{equation}\n  C(k) = c_m") and c["new_quote"].endswith("\\end{equation}")

    cid, c = comment(2, select(pdf, 2, "655"), "655?")
    assert (c["file"], c["line"], c["new_quote"], c["page"]) == ("main.tex", 121, "655", 2)

    cid, c = comment(0, select(pdf, 0, "Both approaches decide when to keep a single instance alive."),
                     "这句不准确：Hybrid 也决定预热窗口。")
    assert len(c["rects"]) == 2 and c["line"] == 76
    assert c["new_quote"] == "Both approaches decide when to keep a\nsingle instance alive."

    cid, c = comment(1, [[560, 340, 560, 340]], "A note in the margin", kind="note")  # a click point, no text
    assert cid == "R1-06" and c["kind"] == "note" and c["text"] == ""
    assert (c["method"], c["confidence"], c["file"], c["line"]) == ("line", 0.5, "sections/method.tex", 27)

    lg = ledger.load(paper)
    anchors = {c["id"]: c["rounds"]["1"]["anchor"] for c in lg["comments"]}
    assert (anchors["R1-01"]["section"], anchors["R1-01"]["env"]) == (None, "abstract")
    assert (anchors["R1-02"]["section"], anchors["R1-02"]["env"]) == ("Method", None)
    assert (anchors["R1-03"]["env"], anchors["R1-03"]["lines"]) == ("equation", [28, 31])
    assert (anchors["R1-04"]["section"], anchors["R1-04"]["env"]) == ("Evaluation", "tabular")
    assert anchors["R1-05"]["lines"] == [76, 77] and anchors["R1-05"]["section"] == "Related Work"
    assert anchors["R1-06"]["position_guessed"] and not anchors["R1-01"]["position_guessed"]
    for a in anchors.values():
        text = (src / a["file"]).read_text(encoding="utf-8")
        assert a["quote"] == text[a["start"]:a["end"]]
        assert a["prefix"] == text[max(0, a["start"] - 40):a["start"]] and a["suffix"] == text[a["end"]:a["end"] + 40]

    # edit, delete; deleted ids are not reused
    state = run("edit", paper, "R1-04", "--note", "这个数从哪里来？")["state"]
    assert next(c for c in state["comments"] if c["id"] == "R1-04")["note"] == "这个数从哪里来？"
    state = run("edit", paper, "R1-04", "--color", "teal", "--kind", "underline")["state"]
    c = next(c for c in state["comments"] if c["id"] == "R1-04")
    assert (c["note"], c["color"], c["kind"]) == ("这个数从哪里来？", "teal", "underline")
    state = run("reanchor", paper, "R1-04", "--page", 2, "--rects", rects_arg(select(pdf, 2, "1240")))["state"]
    c = next(c for c in state["comments"] if c["id"] == "R1-04")
    assert (c["kind"], c["new_quote"], c["context"]["display"]) == ("underline", "1240", "image")
    state = run("delete", paper, "R1-06")["state"]
    assert "R1-06" not in [c["id"] for c in state["comments"]]
    cid, _ = comment(0, select(pdf, 0, "simple keep-alive policy:"), "simple 不准确")
    assert cid == "R1-07"

    # verdicts are only for comments from earlier rounds
    assert "Verdicts are given to comments from earlier rounds" in run("verdict", paper, "R1-01", "verified", ok=False)
    assert "no comment R9-01" in run("verdict", paper, "R9-01", "verified", ok=False)

    # state: shape and order (page, then top, then left)
    state = run("state", paper)["state"]
    order = [c["id"] for c in state["comments"]]
    assert order == ["R1-01", "R1-07", "R1-05", "R1-02", "R1-03", "R1-04"]
    keys = {"id", "kind", "color", "note", "source", "created_round", "carried", "verdict", "verdict_note",
            "anchor_state", "confidence", "method", "page", "rects", "text", "old_quote", "new_quote", "file", "line",
            "changes", "student_note", "context", "history", "paragraph", "tags", "env", "revived", "revivable"}
    assert all(set(c) == keys for c in state["comments"])
    assert all(c["old_quote"] is None and c["history"] == [] and c["changes"] == [] for c in state["comments"])
    assert state["changes"] == []

    # finish
    state = run("finish", paper)["state"]
    rnd = state["round"]
    assert rnd["closed"] and rnd["closed_at"] and state["rounds"][0]["closed"]
    assert rnd["final_pdf"] == str(paper / "r1" / "final.pdf")
    email = (paper / "r1" / "email.txt").read_text(encoding="utf-8")
    assert rnd["email"] == email
    assert email.startswith("Round 1 review: {}\n\n{}\n\nNew comments (6)\n".format(TITLE, render.REPLY_RULE))
    assert 'R1-05  p.1  "Both approaches decide when to keep a single instance alive."\n' \
           "  这句不准确：Hybrid 也决定预热窗口。\n" in email
    assert "Follow-ups" not in email and "Still open" not in email and "Closed" not in email
    assert run("state", paper, "--round", 1) == {"state": state}
    assert "There is no round 2." in run("state", paper, "--round", 2, ok=False)
    assert run("summaries", paper, tmp_path) == {"papers": [
        {"path": str(paper), "summary": {"round": 1, "closed": True, "status": "ok", "to_judge": 0, "to_check": 0,
                                         "answered": 0, "handled": 0, "closed_at": rnd["closed_at"], "resumable": True},
         "paper": {"title": TITLE, "student": "Lin Zhou", "id": pid, "finished": None}},
        {"path": str(tmp_path), "error": "{} is not a Paperole paper folder (no ledger.json).".format(tmp_path)}]}

    final, build = pymupdf.open(rnd["final_pdf"]), pymupdf.open(pdf)
    assert final.page_count == 5
    summary = final[0].get_text()
    for expected in ("Review of Round 1", TITLE, "Student: Lin Zhou", "To do for Round 2",
                     "New comments in this round (6)", "这句不准确：Hybrid 也决定预热窗口。", "R1-07"):
        assert expected in summary
    # no comment annotations: the outline lists the comments, and the marks and notes are burned in
    assert all(a.type[1] == "Link" for p in final for a in p.annots())
    listed = [t[1].split(" · ")[0] for t in final.get_toc() if t[0] == 2 and t[1].startswith("R1-")]
    assert sorted(listed) == ["R1-0{}".format(i) for i in (1, 2, 3, 4, 5, 7)]
    fill, ink = ({k: tuple(round(v, 2) for v in render._rgb(c[i])) for k, c in comments.PALETTE.items()}
                 for i in (0, 1))
    assert ("underline", ink["teal"]) in burned(final[3], select(pdf, 2, "1240"))  # R1-04 after edit and re-anchor
    cost = select(pdf, 1, "The expected cost of a pool of size")  # R1-02
    assert ("highlight", fill["yellow"]) in burned(final[2], cost)
    assert "式(2)里c_m的单位和τ对不上。" in "".join(final[2].get_text().split())  # R1-02's note, in the margin
    for i in range(4):  # the paper's pages, text and links are kept; a one-column paper gets its margin on the right
        assert final[i + 1].rect == build[i].rect + (0, 0, render.MARGIN, 0)
        assert set(build[i].get_text("words")) <= set(final[i + 1].get_text("words"))
        assert len(final[i + 1].get_links()) == len(build[i].get_links())

    # a closed round is frozen
    assert "no open round" in run("comment", paper, "--page", 0, "--rects", "1,1,2,2", ok=False)
    assert "no open round" in run("finish", paper, ok=False)
