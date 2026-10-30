"""Resume Round N (CONTRACT.md amendment "Resume a finished round"): the latest round, finished, open again as it was
before Finish, the files that Finish wrote kept in rN/earlier/; the refusals; Finish again; the next round; Reopen and
re-placing in a resumed round; a killed or failed Resume; Put Back; check, export and import; the ledger's history;
the overview and the papers list; CLI and RPC. Synthetic papers in temporary folders only: hand-made ledgers without
TeX and a small generated paper."""
import datetime
import json
import random
import shutil
import types
import zipfile
from pathlib import Path

import pymupdf
import pytest

from conftest import Engine, select
from paperole import EngineError, analysis, archive, check, cli, disk, history, ledger, prose, render
from test_data_safety import PATH, age, call, handmade

needs_tex = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

EARLY = "2026-10-21T15:30:12+08:00"  # when the first Finish ran (finish_at)
KEPT = {"final.pdf": "final 2026-10-21 1530.pdf", "email.txt": "email 2026-10-21 1530.txt",
        disk.MANIFEST: "manifest-sha256 2026-10-21 1530.txt"}
VOCAB = ("reef shrimp snap chorus dawn dusk hydrophone station night moon tide coral sand depth band pulse level "
         "season colony burrow echo signal noise survey record peak").split()


def para(tag, edit=None):
    """Three sentences of its own, starting with its tag; edit: {sentence index: a word put in at word 4}."""
    out = []
    for i in range(3):
        rng = random.Random("{}-{}".format(tag, i))
        words = [rng.choice(VOCAB) for _ in range(12)]
        if (edit or {}).get(i):
            words[3] = edit[i]
        out.append(" ".join(words) + ".")
    return tag.capitalize() + " " + " ".join(out)


def source(root, edits=None):
    """main.tex: three sections of two paragraphs each ({tag: edit} changes some)."""
    edits = edits or {}
    root.mkdir(parents=True)
    secs = [("Introduction", ["opening", "context"]), ("Methods", ["sampling", "hydro"]),
            ("Results", ["chorus", "timing"])]
    body = "".join("\\section{{{}}}\n\n{}\n\n".format(t, "\n\n".join(para(g, edits.get(g)) for g in tags))
                   for t, tags in secs)
    (root / "main.tex").write_text("\\documentclass{article}\n\\hyphenpenalty=10000\n\\sloppy\n\\begin{document}\n"
                                   + body + "\\end{document}\n")
    return root


def first_words(tag):
    return " ".join(para(tag).split()[:4])


def comment(paper, phrase, note):
    pdf = paper / "r{}".format(ledger.latest_round(ledger.load(paper))["n"]) / "build" / "main.pdf"
    for page in range(pymupdf.open(str(pdf)).page_count):
        try:
            rects = select(str(pdf), page, phrase)
        except AssertionError:
            continue
        return call("comment", paper=str(paper), page=page, rects=rects, text=phrase, note=note,
                    kind="highlight")["id"]
    raise AssertionError(phrase)


def finish_at(paper, when):
    """Finish as if at `when` (ISO 8601): the round's closed_at and final.pdf's date."""
    day = datetime.date.fromisoformat(when[:10])
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(ledger, "now", lambda: when)
        mp.setattr(render, "datetime", types.SimpleNamespace(date=types.SimpleNamespace(today=lambda: day),
                                                             datetime=datetime.datetime))
        return call("finish", paper=str(paper))["state"]


def pdf_text(path):
    return "".join(page.get_text() for page in pymupdf.open(str(path)))


@pytest.fixture(scope="module")
def reef_template(tmp_path_factory):
    """Round 1 (finished): A on Sampling's first words, B on Chorus's, C on Opening's. Round 2 (open): the student
    changed A's sentence and one in Timing. Copy it before changing it."""
    root = tmp_path_factory.mktemp("reef")
    paper = root / "paper"
    call("new", paper=str(paper), title="Reef choruses", student="Mei Lin")
    call("ingest", paper=str(paper), source=str(source(root / "v1")))
    ids = {"A": comment(paper, first_words("sampling"), "Too long."),
           "B": comment(paper, first_words("chorus"), "Which station?"),
           "C": comment(paper, first_words("opening"), "Start with the question.")}
    call("finish", paper=str(paper))
    call("ingest", paper=str(paper), source=str(source(root / "v2", {"sampling": {0: "fixed"},
                                                                     "timing": {1: "late"}})))
    return paper, ids, root


@pytest.fixture
def reef(reef_template, tmp_path):
    template, ids, _ = reef_template
    paper = tmp_path / "paper"
    shutil.copytree(template, paper)
    return paper, ids, tmp_path  # where its next sources go


def with_files(paper, n=1):
    """A hand-made closed round n given email.txt and its checksums besides its final.pdf, as Finish leaves it."""
    r = paper / "r{}".format(n)
    (r / "email.txt").write_text("Round {} review: Kelp forests\n".format(n))
    disk.write_manifest(r, "main")
    return {name: (r / name).read_bytes() for name in KEPT}


def refinish(paper, n=1):
    """Finish a hand-made round again (its build failed, so the engine cannot): new files, the round closed."""
    r = paper / "r{}".format(n)
    (r / "final.pdf").write_bytes(b"%PDF-1.4 synthetic, again")
    (r / "email.txt").write_text("Round {} review: Kelp forests, again\n".format(n))
    disk.write_manifest(r, "main")
    with ledger.edit(paper, keep="finish") as lg:
        lg["rounds"][n - 1].update(closed=True, closed_at=ledger.now())


def kept_files(paper, n=1):
    folder = paper / "r{}".format(n) / "earlier"
    return sorted(p.name for p in folder.iterdir()) if folder.is_dir() else []


# --- the round as it was before Finish (TeX) ----------------------------------------------------------------------

@needs_tex
def test_resume_opens_the_round_as_it_was_before_finish(reef):
    paper, ids, _ = reef
    p, r2 = str(paper), paper / "r2"
    call("verdict", paper=p, id=ids["A"], verdict="verified", note="Good.")
    d = comment(paper, first_words("hydro"), "Which hydrophone?")
    state = call("state", paper=p)["state"]
    call("check_change", paper=p, id=next(ch["id"] for ch in state["changes"] if ch["unrequested"]))
    blocks = prose.load(paper, 2)["blocks"]
    shown = [x["block"] for x in state["reading"]["paragraphs"]]
    still = next(k for k in shown if not prose.fresh(blocks[k]))  # a paragraph the student left alone
    edited = [k for k in shown if prose.fresh(blocks[k])]
    assert still in state["reading"]["read"] and len(edited) == 2
    call("read", paper=p, blocks=[still], read=False)  # marked unread by the advisor
    call("read", paper=p, blocks=[edited[0]])  # one edited paragraph read, the other not
    before, lg0 = call("state", paper=p)["state"], ledger.load(paper)
    assert still not in before["reading"]["read"] and edited[1] not in before["reading"]["read"]

    finished = finish_at(paper, EARLY)
    sent = {name: (r2 / name).read_bytes() for name in KEPT}
    assert (finished["summary"]["resumable"], finished["summary"]["closed_at"]) == (True, EARLY)
    assert finished["round"]["resumable"] and finished["round"]["finishes"] == []
    unread = sorted({blocks[still]["hash"], blocks[edited[1]]["hash"]})
    assert ledger.load(paper)["rounds"][1]["marked_read"] == unread  # what Finish marked read, for Resume
    assert {still, edited[0]} <= set(finished["reading"]["read"])  # Finish marked it read (not the edited one: n − 1)
    assert "2026-10-21" in pdf_text(r2 / "final.pdf")

    state = call("resume_round", paper=p)["state"]
    lg = ledger.load(paper)
    # as before Finish, as far as the advisor can see, but for the earlier finish it records
    assert dict(state, round=dict(state["round"], finishes=[])) == before
    assert (state["summary"]["closed"], state["summary"]["resumable"], state["round"]["resumable"]) == \
        (False, False, False)  # your move again
    assert lg["read"] == lg0["read"] and lg.get("read_through") == lg0.get("read_through")
    assert lg["comments"] == lg0["comments"]
    rec = lg["rounds"][1]
    assert {k: v for k, v in rec.items() if k != "finishes"} == lg0["rounds"][1]
    [f] = rec["finishes"]
    assert f == {"at": EARLY, "resumed": f["resumed"], "final": "r2/earlier/" + KEPT["final.pdf"],
                 "email": "r2/earlier/" + KEPT["email.txt"], "manifest": "r2/earlier/" + KEPT[disk.MANIFEST]}
    assert state["round"]["finishes"] == [{"at": EARLY, "resumed": f["resumed"],
                                           "final": str(r2 / "earlier" / KEPT["final.pdf"]),
                                           "email": str(r2 / "earlier" / KEPT["email.txt"])}]
    for name, kept in KEPT.items():  # moved, never deleted or overwritten
        assert not (r2 / name).exists() and (r2 / "earlier" / kept).read_bytes() == sent[name]
    out = call("overview", papers=[p])  # open, with the advisor, on All Students too
    ov = out["papers"][0]["overview"]
    assert (ov["rounds"][1]["closed"], ov["rounds"][1]["final_pdf"], ov["summary"]) == (False, None, state["summary"])
    assert ov["rounds"][1]["finishes"] == state["round"]["finishes"]
    assert [(t["round"], t["open"]) for t in out["students"][0]["time"]] == [(1, False), (2, True)]
    [v] = [v for v in history.versions(paper) if v["kind"] == "resume"]  # the version before, kept for good
    assert ledger.latest_round(json.loads(history.read(paper, v["name"])[0]))["closed"]
    assert check.paper(paper) == []  # an open round without checksums; the kept files intact

    # open as any round: add, edit, answer and delete
    e = comment(paper, first_words("timing"), "Late?")
    call("edit_comment", paper=p, id=d, note="Which hydrophone, and where?")
    call("verdict", paper=p, id=ids["B"], verdict="reopened", note="Still unclear.")
    call("delete_comment", paper=p, id=e)
    assert "Which hydrophone, and where?" in call("email_preview", paper=p)["text"]

    # Finish again: new files, dated today; the kept ones stay as they were
    state = call("finish", paper=p)["state"]
    today = datetime.date.today().isoformat()
    assert today in pdf_text(r2 / "final.pdf") and "2026-10-21" in pdf_text(r2 / "earlier" / KEPT["final.pdf"])
    assert today == "2026-10-21" or "2026-10-21" not in pdf_text(r2 / "final.pdf")
    assert "Which hydrophone, and where?" in (r2 / "email.txt").read_text()
    assert "Which hydrophone, and where?" not in sent["email.txt"].decode()
    for name, kept in KEPT.items():
        assert (r2 / "earlier" / kept).read_bytes() == sent[name]
    assert disk.verify_manifest(r2) == {"changed": [], "missing": [], "extra": []}
    assert check.paper(paper) == []
    assert state["round"]["final_pdf"] == str(r2 / "final.pdf") and len(state["round"]["finishes"]) == 1
    assert state["summary"]["resumable"] and state["summary"]["closed_at"] == state["round"]["closed_at"] != EARLY
    assert [e[2:] for e in ledger.load(paper)["trail"]].count(["finish"]) == 3
    assert ledger.load(paper)["rounds"][1]["marked_read"] == unread  # unread again after Resume, marked again

    # finished again in the same minute as the first time: each finish's files keep a name of their own
    call("resume_round", paper=p)
    finish_at(paper, EARLY[:17] + "50" + EARLY[19:])
    state = call("resume_round", paper=p)["state"]
    assert [f["final"] for f in ledger.load(paper)["rounds"][1]["finishes"]][2] == \
        "r2/earlier/final 2026-10-21 1530 2.pdf"
    assert len(kept_files(paper, 2)) == 9 and len(state["round"]["finishes"]) == 3
    assert check.paper(paper) == []


@needs_tex
def test_the_next_round_after_a_resumed_round(reef):
    paper, ids, root = reef
    p = str(paper)
    finish_at(paper, EARLY)
    call("resume_round", paper=p)
    f = comment(paper, first_words("context"), "Cite the survey.")
    call("finish", paper=p)
    state = call("ingest", paper=p, source=str(source(root / "v3", {"context": {2: "cited"}})))["state"]
    lg = ledger.load(paper)
    assert "marked_read" not in lg["rounds"][1]  # round 2 is final now: nothing to resume
    assert f in {c["id"] for c in state["comments"]} and state["round"]["n"] == 3
    assert state["summary"]["resumable"] is False and state["summary"]["closed"] is False
    with pytest.raises(EngineError, match="Round 3 is open already"):
        call("resume_round", paper=p)
    past = call("state", paper=p, round=2)["state"]["round"]
    assert past["resumable"] is False and past["final_pdf"] and len(past["finishes"]) == 1
    assert kept_files(paper, 2) == sorted(KEPT.values())
    assert check.paper(paper) == []
    # the overview: round 2's earlier finish, and the open round with the advisor
    ov = call("overview", papers=[p])["papers"][0]["overview"]
    assert [len(r["finishes"]) for r in ov["rounds"]] == [0, 1, 0]
    assert ov["rounds"][1]["finishes"][0]["final"] == str(paper / "r2" / "earlier" / KEPT["final.pdf"])
    assert ov["summary"] == state["summary"]


@needs_tex
def test_reopen_and_replace_in_a_resumed_round(reef):
    paper, ids, root = reef
    p = str(paper)
    call("verdict", paper=p, id=ids["A"], verdict="verified")
    call("finish", paper=p)
    call("ingest", paper=p, source=str(source(root / "v3", {"sampling": {0: "broken"}})))
    call("finish", paper=p)
    call("resume_round", paper=p)
    a = next(c for c in call("state", paper=p, round=2)["state"]["comments"] if c["id"] == ids["A"])
    assert a["revivable"] is True  # closed in Round 2: it may come back into the resumed Round 3
    state = call("revive", paper=p, id=ids["A"])["state"]
    a = next(c for c in state["comments"] if c["id"] == ids["A"])
    assert a["revived"]["from"] == 2 and a["verdict"] is None
    pdf = str(paper / "r3" / "build" / "main.pdf")
    rects = select(pdf, 0, first_words("context"))
    state = call("reanchor", paper=p, id=ids["C"], page=0, rects=rects, text=first_words("context"))["state"]
    c = next(c for c in state["comments"] if c["id"] == ids["C"])
    assert c["method"] == "advisor" and c["text"] == first_words("context")
    state = call("finish", paper=p)["state"]
    assert "reopened in Round 3" in state["round"]["email"]
    assert check.paper(paper) == []


# --- refusals, a killed Resume, Put Back (no TeX) ----------------------------------------------------------------

def test_what_resume_refuses(tmp_path):
    empty = tmp_path / "empty"
    call("new", paper=str(empty), title="Kelp forests", student="Maya Chen")
    with pytest.raises(EngineError, match="There is no round yet"):
        call("resume_round", paper=str(empty))
    two = handmade(tmp_path / "two")  # round 1 finished, round 2 open: round 1 stays finished for good
    raw = (two / "ledger.json").read_bytes()
    with pytest.raises(EngineError, match="Round 2 is open already: only a finished round can be resumed"):
        call("resume_round", paper=str(two))
    assert (two / "ledger.json").read_bytes() == raw and kept_files(two) == []

    one = handmade(tmp_path / "one", rounds=((1, True),))  # only final.pdf: email and checksums null
    state = call("resume_round", paper=str(one))["state"]
    [f] = ledger.load(one)["rounds"][0]["finishes"]
    assert f["final"].startswith("r1/earlier/final ") and (f["email"], f["manifest"]) == (None, None)
    assert state["round"]["finishes"][0]["email"] is None
    with pytest.raises(EngineError, match="Round 1 is open already"):
        call("resume_round", paper=str(one))
    v2 = tmp_path / "v2"
    v2.mkdir()
    (v2 / "main.tex").write_text("Round 2.\n")
    raw = (one / "ledger.json").read_bytes()
    with pytest.raises(EngineError, match="Round 1 was finished before and resumed. Finish it again"):
        call("ingest", paper=str(one), source=str(v2))  # it would replace the round, and its earlier files
    assert (one / "ledger.json").read_bytes() == raw and len(kept_files(one)) == 1


def test_a_killed_or_failed_resume_leaves_the_round_finished(tmp_path, monkeypatch):
    paper = handmade(tmp_path, rounds=((1, True),))
    p, r1 = str(paper), paper / "r1"
    sent = with_files(paper)
    raw = (paper / "ledger.json").read_bytes()

    class Killed(BaseException):
        pass

    def killed(*args, **kw):
        raise Killed()
    monkeypatch.setattr(ledger, "save", killed)  # killed before the ledger was saved: the files moved already
    with pytest.raises(Killed):
        call("resume_round", paper=p)
    monkeypatch.undo()
    assert (paper / "ledger.json").read_bytes() == raw and len(kept_files(paper)) == 3
    assert not (r1 / "final.pdf").exists()
    state = call("state", paper=p)["state"]  # puts them back, the round finished as the ledger says
    assert state["round"]["closed"] and state["round"]["final_pdf"] == str(r1 / "final.pdf")
    assert {name: (r1 / name).read_bytes() for name in KEPT} == sent and kept_files(paper) == []
    assert check.paper(paper) == []

    moves = []

    def flaky(src, dest, real=disk.move):
        moves.append(src)
        if len(moves) == 2:
            raise OSError(28, "No space left on device")
        real(src, dest)
    monkeypatch.setattr(disk, "move", flaky)  # a move that fails: those made are put back at once
    with pytest.raises(OSError):
        call("resume_round", paper=p)
    monkeypatch.undo()
    assert {name: (r1 / name).read_bytes() for name in KEPT} == sent and kept_files(paper) == []
    assert ledger.latest_round(ledger.load(paper))["closed"] and check.paper(paper) == []

    call("resume_round", paper=p)  # and then it works
    assert len(kept_files(paper)) == 3 and not ledger.latest_round(ledger.load(paper))["closed"]


def test_put_back_and_resume(tmp_path):
    paper = handmade(tmp_path, rounds=((1, True),))
    p, r1 = str(paper), paper / "r1"
    sent = with_files(paper)
    call("resume_round", paper=p)
    call("edit_paper", paper=p, title="Kelp forests, resumed")
    # the version before the Resume, put back while the round is open again: the round's files come back
    [before] = [v for v in history.versions(paper) if v["kind"] == "resume"]
    state = call("put_back_ledger", paper=p, version=before["name"])["state"]
    assert state["round"]["closed"] and state["paper"]["title"] == "Kelp forests"
    assert {name: (r1 / name).read_bytes() for name in KEPT} == sent and kept_files(paper) == []
    assert check.paper(paper) == []

    # resumed and finished again since: neither a version from before that Resume nor one from while it was open
    # matches the round's files
    call("resume_round", paper=p)
    age(paper, 11 * 60)
    call("edit_paper", paper=p, title="Kelp forests, again")  # the version before it, open, is copied
    while_open = history.versions(paper)[0]
    assert while_open["kind"] == "edit"
    refinish(paper)
    raw = (paper / "ledger.json").read_bytes()
    resumes = [v["name"] for v in history.versions(paper) if v["kind"] == "resume"]
    assert len(resumes) == 2
    for name in resumes:
        with pytest.raises(EngineError, match="This version is from before Round 1 was resumed"):
            call("put_back_ledger", paper=p, version=name)
    with pytest.raises(EngineError, match="Round 1 is still open, but it has been finished since"):
        call("put_back_ledger", paper=p, version=while_open["name"])
    assert (paper / "ledger.json").read_bytes() == raw and len(kept_files(paper)) == 3


def test_put_back_brings_back_the_list_of_changes_as_finished(tmp_path):
    """In a resumed round a re-placed or reopened comment writes a new analysis.json (api._reattach): the version
    from before the Resume, put back, brings the round's analysis.json back as it was finished, so the round matches
    its checksums again; a version that cannot (a Finish copy keeps none) is refused."""
    paper = handmade(tmp_path, rounds=((1, True),))
    p, r1 = str(paper), paper / "r1"
    first = b'{"changes": [], "finished": 1}'
    with ledger.edit(paper) as lg:  # a list of changes, recorded, before the round's checksums
        (r1 / "analysis.json").write_bytes(first)
        lg["rounds"][0]["analysis_sha256"] = disk.sha256(r1 / "analysis.json")
    with_files(paper)

    def restage(data):  # what reanchor and revive do in the open round
        with ledger.edit(paper, after=analysis.settle) as lg:
            analysis.stage(paper, lg["rounds"][0], data)

    call("resume_round", paper=p)
    restage(b'{"changes": [], "resumed": 1}')
    [before] = [v for v in history.versions(paper) if v["kind"] == "resume"]
    state = call("put_back_ledger", paper=p, version=before["name"])["state"]
    assert state["round"]["closed"] and (r1 / "analysis.json").read_bytes() == first
    assert not (r1 / "analysis.json.new").exists() and kept_files(paper) == []
    assert check.paper(paper) == []

    # resumed, changed and finished again, then resumed and changed once more
    call("resume_round", paper=p)
    second = b'{"changes": [], "resumed": 2}'
    restage(second)
    refinish(paper)
    finished = history.versions(paper)[0]["name"]
    assert finished.endswith("-finish.json")
    call("resume_round", paper=p)
    restage(b'{"changes": [], "resumed": 3}')
    raw = (paper / "ledger.json").read_bytes()
    with pytest.raises(EngineError, match="This version is from before Round 1 was resumed"):
        call("put_back_ledger", paper=p, version=finished)  # no analysis.json of the round kept with it
    assert (paper / "ledger.json").read_bytes() == raw and len(kept_files(paper)) == 6
    latest = next(v for v in history.versions(paper) if v["kind"] == "resume")["name"]
    call("put_back_ledger", paper=p, version=latest)
    assert (r1 / "analysis.json").read_bytes() == second and len(kept_files(paper)) == 3
    assert check.paper(paper) == []


def test_history_keeps_the_copy_before_a_resume_for_good(tmp_path):
    paper = handmade(tmp_path, rounds=((1, True),))
    call("resume_round", paper=str(paper))
    age(paper, 40 * 24 * 3600)
    history.prune(paper)
    assert [v["kind"] for v in history.versions(paper)] == ["resume"]
    assert call("history", paper=str(paper))["versions"][0]["kind"] == "resume"


# --- check, export and import (no TeX) ----------------------------------------------------------------------------

def test_check_export_and_import_keep_the_earlier_files(tmp_path):
    paper = handmade(tmp_path / "a", rounds=((1, True),))
    p, r1 = str(paper), paper / "r1"
    with_files(paper)
    call("resume_round", paper=p)
    assert check.paper(paper) == []  # an open round, its files kept, no checksums of its own
    refinish(paper)
    assert check.paper(paper) == []
    [f] = ledger.load(paper)["rounds"][0]["finishes"]

    final = paper / f["final"]
    good = final.read_bytes()
    final.write_bytes(good + b" changed")
    assert [(q["code"], q["round"], q["files"]) for q in check.paper(paper)] == \
        [("earlier_changed", 1, [f["final"]])]
    final.write_bytes(good)
    email = paper / f["email"]
    text = email.read_bytes()
    email.unlink()
    assert [(q["code"], q["files"]) for q in check.paper(paper)] == [("earlier_changed", [f["email"]])]
    email.write_bytes(text)
    with ledger.edit(paper) as lg:  # a name outside the round's earlier/ is reported, never read
        lg["rounds"][0]["finishes"].append({"at": None, "final": "../../outside.pdf", "email": None, "manifest": None})
    assert [(q["code"], q["files"]) for q in check.paper(paper)] == [("earlier_changed", ["../../outside.pdf"])]
    with ledger.edit(paper) as lg:
        lg["rounds"][0]["finishes"].pop()
    assert check.paper(paper) == []

    # an export holds them, checked; one imported has them, byte for byte
    out = archive.write([{"path": p}], tmp_path / "out.zip")["path"]
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
    assert sum(1 for n in names if "/r1/earlier/" in n) == 3
    listed = [{"path": p, "id": ledger.paper_id(paper, ledger.load(paper))}]
    (entry,) = archive.check(out, listed)["papers"]
    assert (entry["status"], entry["problems"]) == ("same", [])
    shutil.rmtree(paper)
    back = Path(archive.unpack(out, entry["folder"], tmp_path / "a")["path"])
    assert check.paper(back) == [] and len(kept_files(back)) == 3 and (back / f["final"]).read_bytes() == good

    (back / f["final"]).write_bytes(good + b" changed")  # changed before an export: the copy inside says so
    out = archive.write([{"path": str(back)}], tmp_path / "late.zip")["path"]
    (entry,) = archive.check(out)["papers"]
    assert [(q["code"], q["files"]) for q in entry["problems"]] == [("earlier_changed", [f["final"]])]


# --- CLI and RPC (no TeX) ----------------------------------------------------------------------------------------

def test_cli_and_rpc(tmp_path, capsys):
    a = handmade(tmp_path / "a", rounds=((1, True),))
    assert cli.main(["resume-round", str(a)]) == 0
    state = json.loads(capsys.readouterr().out)["state"]
    assert state["round"]["closed"] is False and len(state["round"]["finishes"]) == 1
    assert cli.main(["resume-round", str(a)]) == 1
    assert "Round 1 is open already" in capsys.readouterr().err
    assert cli.main(["summaries", str(a)]) == 0
    assert json.loads(capsys.readouterr().out)["papers"][0]["summary"]["resumable"] is False

    b = handmade(tmp_path / "b", rounds=((1, True),))
    eng = Engine()
    try:
        assert eng.call("state", paper=str(b))["state"]["summary"]["resumable"] is True
        state = eng.call("resume_round", paper=str(b))["state"]
        assert state["round"]["closed"] is False and state["round"]["finishes"][0]["final"]
        assert "only a finished round can be resumed" in eng.error("resume_round", paper=str(b))
    finally:
        assert eng.close()[0] == 0
