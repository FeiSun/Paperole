"""The data foundations (design/data/DATA.md §2.2–§2.4 and §6.3; CONTRACT.md amendment "Data foundations"): paper
ids, versions and their trail, the three facts in the ledger, the TeX version, safe writes, analysis.json in step with
the ledger, the ledger's history and Put Back, round folders kept in .orphans, a finished round's checksums, and the
read-only check. Synthetic papers in temporary folders only: hand-made ledgers without TeX, and the fixture paper."""
import errno
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

from conftest import FIXTURE, quiet, select
from paperole import EngineError, analysis, api, check, disk, history, ledger

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
needs_tex = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")


def call(method, **params):
    return api.METHODS[method](params, quiet)


def tree(root):
    """Every file and folder under root (dot-files included) with its bytes' SHA-256 and modification time."""
    out = {}
    for p in sorted(Path(root).rglob("*")):
        st = os.lstat(str(p))
        out[p.relative_to(root).as_posix()] = (hashlib.sha256(p.read_bytes()).hexdigest(), st.st_mtime_ns) \
            if stat.S_ISREG(st.st_mode) else stat.S_IFMT(st.st_mode)
    return out


def handmade(root, rounds=((1, True), (2, False))):
    """A paper whose rounds were never built (status failed, no PDF), for the ledger's rules without TeX; round n's
    source is one file, main.tex, and a closed round has a final.pdf of a few bytes."""
    paper = Path(root) / "kelp"
    call("new", paper=str(paper), title="Kelp forests", student="Maya Chen")
    with ledger.edit(paper) as lg:
        for n, closed in rounds:
            src = paper / "r{}".format(n) / "src"
            src.mkdir(parents=True)
            (src / "main.tex").write_text("Round {}.\n".format(n))
            if closed:
                (src.parent / "final.pdf").write_bytes(b"%PDF-1.4 synthetic")
            lg["rounds"].append({"n": n, "created": ledger.now(), "source": "/synthetic/v{}".format(n),
                                 "closed": closed, "closed_at": ledger.now() if closed else None, "last_seq": 0,
                                 "build": {"status": "failed", "pdf": None, "log": None, "pages": 0, "errors": [],
                                           "warnings": []}})
    return paper


def as_older(paper):
    """The ledger as an engine before ids and versions left it."""
    lg = json.loads((paper / "ledger.json").read_text(encoding="utf-8"))
    del lg["paper"]["id"]
    for key in ("rev", "saved", "trail"):
        lg.pop(key)
    (paper / "ledger.json").write_text(json.dumps(lg, ensure_ascii=False, indent=1), encoding="utf-8")


def age(paper, seconds):
    """Make every copy in .history older by seconds (its name holds the time it was made)."""
    folder = paper / history.FOLDER
    for p in sorted(folder.iterdir()):
        m = re.match(r"(\d{8}-\d{6})(-.*)", p.name)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(history._when(m.group(1)) - seconds))
        p.rename(folder / (stamp + m.group(2)))


# --- ids and versions (no TeX) ------------------------------------------------------------------------------------

def test_paper_ids(tmp_path):
    a, b = handmade(tmp_path / "a"), handmade(tmp_path / "b")
    ida, idb = (call("state", paper=str(p))["state"]["paper"]["id"] for p in (a, b))
    assert re.fullmatch(r"p-[0-9a-f]{16}", ida) and ida != idb and ledger.load(a)["paper"]["id"] == ida

    # a ledger from before ids: derived, and viewing it writes nothing
    as_older(a)
    raw = (a / "ledger.json").read_bytes()
    derived = call("state", paper=str(a))["state"]["paper"]["id"]
    assert derived == ledger.derived_id(a, ledger.load(a)) != ida
    assert call("summaries", papers=[str(a)])["papers"][0]["paper"]["id"] == derived
    assert call("overview", papers=[str(a)])["papers"][0]["overview"]["paper"]["id"] == derived
    assert (a / "ledger.json").read_bytes() == raw
    # a byte copy shares it; the same paper made in the same second from another source does not
    shutil.copytree(a, tmp_path / "copy")
    shutil.copytree(a, tmp_path / "other")
    (tmp_path / "other" / "r1" / "src" / "main.tex").write_text("Round 1, another draft.\n")
    assert call("state", paper=str(tmp_path / "copy"))["state"]["paper"]["id"] == derived
    assert call("state", paper=str(tmp_path / "other"))["state"]["paper"]["id"] != derived
    # the first locked write stores it
    call("edit_paper", paper=str(a), title="Kelp forests in winter")
    assert ledger.load(a)["paper"]["id"] == derived

    # fork: a new id, the old one kept
    out = call("fork", paper=str(a))
    assert out["forked_from"] == derived and out["id"] != derived and out["state"]["paper"]["id"] == out["id"]
    lg = ledger.load(a)
    assert (lg["paper"]["id"], lg["paper"]["forked_from"]) == (out["id"], derived)


def test_versions_and_the_trail(tmp_path):
    paper = handmade(tmp_path)
    v0 = ledger.load(paper)
    call("edit_paper", paper=str(paper), title="Kelp forests in winter")
    v1 = ledger.load(paper)
    assert v1["rev"] == v0["rev"] + 1 and v1["trail"][-1] == ledger.version(v1) and v1["saved"]
    assert [ledger.compare(v0, v1), ledger.compare(v1, v0), ledger.compare(v1, json.loads(json.dumps(v1)))] \
        == ["older", "newer", "same"]
    # a call that changes nothing writes no version
    raw = (paper / "ledger.json").read_bytes()
    call("edit_paper", paper=str(paper), title="Kelp forests in winter")
    assert (paper / "ledger.json").read_bytes() == raw

    # two copies changed since they parted
    copy = tmp_path / "copy"
    shutil.copytree(paper, copy)
    call("edit_paper", paper=str(paper), student="Maya C. Chen")
    call("edit_paper", paper=str(copy), title="Giant kelp")
    assert ledger.compare(ledger.load(paper), ledger.load(copy)) == "diverged"

    # an older engine's write keeps rev: against a copy that went on without it, diverged (the safe side); the next
    # write of this engine puts it on the trail, so it reads as older then
    older = ledger.load(paper)
    older["paper"]["title"] = "Written by an older engine"
    (paper / "ledger.json").write_text(json.dumps(older, ensure_ascii=False, indent=1), encoding="utf-8")
    assert older["rev"] == ledger.load(paper)["rev"]
    assert ledger.compare(older, ledger.load(copy)) == "diverged"
    call("edit_paper", paper=str(paper), student="Maya Chen")
    assert ledger.compare(older, ledger.load(paper)) == "older"
    # a ledger from before versions: rev 0, never "same" as another
    as_older(copy)
    assert ledger.version(ledger.load(copy))[0] == 0
    assert ledger.compare(ledger.load(copy), ledger.load(paper)) == "diverged"

    # the trail keeps the last 300 versions and every Finish
    lg = ledger.load(paper)
    lg["trail"] = [[i, "{:016x}".format(i)] + (["finish"] if i == 10 else []) for i in range(1, 401)]
    lg["rev"] = 400
    with ledger.locked(paper):
        ledger.save(paper, lg)
    trail = ledger.load(paper)["trail"]
    assert len(trail) == ledger.TRAIL + 1 and trail[0] == [10, "{:016x}".format(10), "finish"]
    assert trail[-1][0] == 401


# --- the three facts (no TeX) ---------------------------------------------------------------------------------

def test_the_three_facts_through_edit_paper_and_adopt(tmp_path):
    paper = handmade(tmp_path)
    p = str(paper)
    ov = call("overview", papers=[p], buckets={p: {"methods": "method"}}, key_pages={p: {"round": 1, "page": 0}})
    facts = ov["papers"][0]["overview"]["paper"]  # the ledger lacks them: the app's values
    assert (facts["finished"], facts["buckets"], facts["key_page"]) == (None, {"methods": "method"},
                                                                         {"round": 1, "page": 0})

    # the app moves its values in, once: a fact the ledger has (even null) is never overwritten
    rev = ledger.load(paper)["rev"]
    out = call("adopt_facts", paper=p, finished="2026-10-20", buckets={}, key_page={"round": 2, "page": 3})
    assert out["adopted"] == ["finished", "key_page"] and "state" not in out
    assert out["paper"] == {"id": ledger.load(paper)["paper"]["id"], "finished": "2026-10-20", "buckets": None,
                            "key_page": {"round": 2, "page": 3}}
    assert ledger.load(paper)["rev"] == rev + 1 and "buckets" not in ledger.load(paper)["paper"]
    again = call("adopt_facts", paper=p, finished="2026-10-21", key_page={"round": 1, "page": 0})
    assert again["adopted"] == [] and ledger.load(paper)["rev"] == rev + 1  # nothing written
    assert again["paper"]["finished"] == "2026-10-20"

    # edit_paper sets and clears them; "" in buckets is a column of the section's own name (null)
    call("edit_paper", paper=p, finished=None, buckets={"methods": "results", "appendix-a": ""})
    lg = ledger.load(paper)["paper"]
    assert (lg["finished"], lg["buckets"]) == (None, {"methods": "results", "appendix-a": None})
    assert call("adopt_facts", paper=p, finished="2026-10-22")["adopted"] == []  # null is the ledger's value
    ov = call("overview", papers=[p], buckets={p: {"methods": "method"}}, key_pages={p: {"round": 1, "page": 0}})
    facts = ov["papers"][0]["overview"]["paper"]  # the ledger's win
    assert (facts["finished"], facts["buckets"], facts["key_page"]) == (None, {"methods": "results",
                                                                               "appendix-a": None},
                                                                         {"round": 2, "page": 3})
    assert call("summaries", papers=[p])["papers"][0]["paper"]["finished"] is None
    call("edit_paper", paper=p, finished="2026-10-22", key_page=None)
    assert call("summaries", papers=[p])["papers"][0]["paper"]["finished"] == "2026-10-22"
    assert ledger.load(paper)["paper"]["key_page"] is None

    raw = (paper / "ledger.json").read_bytes()
    for bad, message in [({"finished": "yesterday"}, "finished is a day"),
                         ({"finished": "2026-02-30"}, "finished is a day"),
                         ({"buckets": {"methods": 3}}, "buckets maps"), ({"buckets": ["methods"]}, "buckets maps"),
                         ({"key_page": {"round": 0, "page": 0}}, "key_page is"),
                         ({"key_page": {"round": 1, "page": True}}, "key_page is"),
                         ({}, "Give the paper's title")]:
        with pytest.raises(EngineError, match=message):
            call("edit_paper", paper=p, **bad)
        if bad:
            with pytest.raises(EngineError, match=message):
                call("adopt_facts", paper=p, **bad)
    assert (paper / "ledger.json").read_bytes() == raw


# --- safe writes (no TeX) --------------------------------------------------------------------------------------

def test_atomic_write_on_a_full_disk(tmp_path, monkeypatch):
    target = tmp_path / "email.txt"
    target.write_text("as before")
    os.chmod(target, 0o640)
    ops = []
    real = disk.fcntl.fcntl
    monkeypatch.setattr(disk.fcntl, "fcntl", lambda fd, op, *a: ops.append(op) or real(fd, op, *a))
    disk.atomic_write(target, "Round 2 review: Kelp forests\n")
    assert target.read_text() == "Round 2 review: Kelp forests\n" and stat.S_IMODE(target.stat().st_mode) == 0o640
    if hasattr(disk.fcntl, "F_FULLFSYNC"):
        assert disk.fcntl.F_FULLFSYNC in ops  # the drive's cache flushed, not only the system's

    def full(fd):
        raise OSError(errno.ENOSPC, "No space left on device")
    monkeypatch.setattr(disk, "_sync", full)
    with pytest.raises(OSError):
        disk.atomic_write(target, "half")
    assert target.read_text() == "Round 2 review: Kelp forests\n" and sorted(os.listdir(tmp_path)) == ["email.txt"]

    # a ledger write that fails leaves the ledger as it was, and no temporary file
    monkeypatch.undo()
    paper = handmade(tmp_path)
    raw = (paper / "ledger.json").read_bytes()
    monkeypatch.setattr(disk, "_sync", full)
    with pytest.raises(OSError):
        call("edit_paper", paper=str(paper), title="Never saved")
    assert (paper / "ledger.json").read_bytes() == raw and not list(paper.glob("*.tmp")) \
        and not list(paper.glob(".*.tmp"))


def test_analysis_in_step_with_the_ledger(tmp_path):
    paper = handmade(tmp_path)
    a = paper / "r2" / "analysis.json"
    change = {"id": "c01", "kind": "replace", "file": "main.tex", "line": 1, "old_text": "Round", "new_text": "Draft",
              "page": None, "rects": [], "attached_to": []}
    first, second = {"schema": 1, "changes": [change]}, {"schema": 1, "changes": [dict(change, attached_to=["R1-01"])]}
    with ledger.edit(paper) as lg:
        analysis.write(paper, lg["rounds"][1], first)
    assert ledger.load(paper)["rounds"][1]["analysis_sha256"] == disk.sha256(a)

    class Killed(Exception):
        pass
    # killed before the ledger was saved: the staged file goes, analysis.json stays the one the ledger names
    with pytest.raises(Killed):
        with ledger.edit(paper) as lg:
            analysis.stage(paper, lg["rounds"][1], second)
            raise Killed
    assert (paper / "r2" / "analysis.json.new").exists()
    call("state", paper=str(paper))  # the next call puts it right
    assert not (paper / "r2" / "analysis.json.new").exists() and json.loads(a.read_text()) == first
    # killed after the ledger was saved, before the swap: the next call finishes it
    with ledger.edit(paper) as lg:  # no `after`: nothing swaps it in
        analysis.stage(paper, lg["rounds"][1], second)
    assert json.loads(a.read_text()) == first and ledger.load(paper)["rounds"][1]["analysis_sha256"] == \
        disk.sha256(paper / "r2" / "analysis.json.new")
    assert check.paper(paper) == []  # a staged file of a call that may be running is not a problem yet
    call("state", paper=str(paper))
    assert json.loads(a.read_text()) == second and not (paper / "r2" / "analysis.json.new").exists()
    # a call that fails takes back what it staged at once
    with pytest.raises(EngineError):
        with api._edit(paper) as lg:
            analysis.stage(paper, lg["rounds"][1], first)
            raise EngineError("Refused.")
    assert json.loads(a.read_text()) == second and not (paper / "r2" / "analysis.json.new").exists()

    # what viewing works out goes to the cache, only for the analysis.json it was worked out from
    raw = a.read_bytes()
    analysis.store_cache(paper, 2, {"c01": {"section": "Methods"}})
    assert analysis.changes(paper, 2)[0]["section"] == "Methods" and a.read_bytes() == raw
    with ledger.edit(paper) as lg:
        analysis.write(paper, lg["rounds"][1], first)
    assert "section" not in analysis.changes(paper, 2)[0]


# --- history and Put Back (no TeX) ------------------------------------------------------------------------------

def test_history_copies_and_pruning(tmp_path):
    paper = handmade(tmp_path, rounds=((1, False),))
    names = [v["name"] for v in history.versions(paper)]
    assert len(names) == 1 and names[0].endswith("-edit.json")  # before handmade's write: the first edit
    call("edit_paper", paper=str(paper), title="Kelp forests in winter")
    assert len(history.versions(paper)) == 1  # the newest copy is under 10 minutes old
    age(paper, 11 * 60)
    rev = ledger.load(paper)["rev"]
    call("edit_paper", paper=str(paper), title="Kelp forests in spring")
    newest = history.versions(paper)[0]
    assert (newest["kind"], newest["rev"], newest["rounds"], newest["comments"]) == ("edit", rev, 1, 0)
    assert json.loads(history.read(paper, newest["name"])[0])["paper"]["title"] == "Kelp forests in winter"

    # the limits: 30 from the last day, the newest of each day for 30 days, every Finish copy and replaced ledger
    shutil.rmtree(paper / history.FOLDER)
    folder = paper / history.FOLDER
    folder.mkdir()
    # 23:00 local today, so the 17.5 hours of copies below stay within one local day whatever the time of the run
    now = time.mktime(time.localtime()[:3] + (23, 0, 0, 0, 0, -1))

    def made(hours_ago, rev, kind):
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now - hours_ago * 3600))
        name = "{}-{}-{}.json".format(stamp, rev, kind)
        (folder / name).write_text("{}")
        (folder / "{}.r1-analysis.json".format(name[:-5])).write_text("{}")
        return name
    today = [made(i * 0.5, 100 - i, "edit") for i in range(35)]  # 17.5 hours
    older = [made(24 * d + 1 + h, 60 - d * 3 - h, "edit") for d in range(1, 4) for h in range(2)]
    gone = made(24 * 40, 1, "edit")
    kept = [made(24 * 60, 2, "finish"), made(24 * 50, 3, "replaced")]
    history.prune(paper, now)
    left = set(os.listdir(folder))
    assert set(today[:30]) <= left and not set(today[30:]) & left
    per_day = [n for n in older if n in left]
    assert len(per_day) == len({time.strftime("%Y%m%d", time.localtime(history._when(n[:15]))) for n in older})
    assert gone not in left and set(kept) <= left
    assert all(n[:-5] + ".r1-analysis.json" in left for n in left if n.endswith("-edit.json") or n in kept)
    assert not any(n.startswith(gone[:-5]) for n in left)


def test_pruning_keeps_the_newest_of_a_day_under_a_day_old(tmp_path):
    """A busy morning (30 or more copies) after an evening of edits: the evening's newest copy is under a day old but
    not among the 30 newest, and it is still kept as its day's newest (it used to go, and with it the whole day)."""
    paper = handmade(tmp_path, rounds=((1, False),))
    folder = paper / history.FOLDER
    shutil.rmtree(folder)
    folder.mkdir()
    now = time.mktime((2026, 10, 20, 10, 0, 0, 0, 0, -1))  # 10:00 local

    def made(minutes_ago, rev):
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now - minutes_ago * 60))
        name = "{}-{}-edit.json".format(stamp, rev)
        (folder / name).write_text("{}")
        return name
    morning = [made(i, 100 - i) for i in range(35)]  # 9:26 to 10:00
    evening = [made(20 * 60 + i, 50 - i) for i in range(5)]  # 13:56 to 14:00 the day before
    history.prune(paper, now)
    left = set(os.listdir(folder))
    assert set(morning[:30]) <= left and not set(morning[30:]) & left
    assert evening[0] in left and not set(evening[1:]) & left


def test_put_back_an_earlier_ledger(tmp_path):
    paper = handmade(tmp_path)
    p = str(paper)
    with ledger.edit(paper) as lg:
        analysis.write(paper, lg["rounds"][1], {"schema": 1, "changes": [], "note": "first"})
    age(paper, 11 * 60)
    call("edit_paper", paper=p, title="Kelp forests, changed by mistake")  # the version before it is copied
    early = history.versions(paper)[0]
    assert early["kind"] == "edit" and early["name"].endswith("-edit.json")
    with ledger.edit(paper) as lg:  # and analysis.json changed since
        analysis.write(paper, lg["rounds"][1], {"schema": 1, "changes": [], "note": "second"})
    replaced = ledger.load(paper)

    state = call("put_back_ledger", paper=p, version=early["name"])["state"]
    lg = ledger.load(paper)
    assert state["paper"]["title"] == "Kelp forests" and lg["rev"] == replaced["rev"] + 1
    assert lg["paper"]["id"] == replaced["paper"]["id"]
    assert ledger.compare(replaced, lg) == "older"  # so an older export never looks newer
    assert json.loads((paper / "r2" / "analysis.json").read_text())["note"] == "first"  # back with it, in step
    assert lg["rounds"][1]["analysis_sha256"] == disk.sha256(paper / "r2" / "analysis.json")
    kept = history.versions(paper)[0]
    assert kept["kind"] == "replaced" and kept["rev"] == replaced["rev"]
    assert json.loads(history.read(paper, kept["name"])[0])["paper"]["title"] == "Kelp forests, changed by mistake"

    # refused: a version without a round on disk, one showing open a round closed since, an unknown name
    with ledger.edit(paper) as lg:
        lg["rounds"][1].update(closed=True, closed_at=ledger.now())
    raw = (paper / "ledger.json").read_bytes()
    with pytest.raises(EngineError, match="Round 2 is still open, but it has been finished since"):
        call("put_back_ledger", paper=p, version=early["name"])
    assert (paper / "ledger.json").read_bytes() == raw
    (paper / "r3" / "src").mkdir(parents=True)
    with ledger.edit(paper) as lg:  # a round ingested since the version
        lg["rounds"].append(dict(lg["rounds"][1], n=3, created=ledger.now(), closed=False, closed_at=None))
    raw = (paper / "ledger.json").read_bytes()
    with pytest.raises(EngineError, match="does not have Round 3, which is on disk"):
        call("put_back_ledger", paper=p, version=early["name"])
    for bad in ("../ledger.json", "ledger.json", early["name"][:-5] + ".r2-analysis.json", 7):
        with pytest.raises(EngineError, match="There is no saved version"):
            call("put_back_ledger", paper=p, version=bad)
    assert (paper / "ledger.json").read_bytes() == raw

    # an unreadable ledger: its versions are listed, one is put back (what is closed comes from the rounds'
    # checksums then: this paper has none), and the damaged one is kept as it was
    shutil.rmtree(paper / "r3")
    mistake = next(v for v in history.versions(paper) if v["kind"] == "replaced")
    (paper / "ledger.json").write_bytes(b'{"schema": 1, "paper": ')
    versions = call("history", paper=p)["versions"]
    assert versions and all(set(v) == {"name", "time", "rev", "kind", "comments", "rounds"} for v in versions)
    call("put_back_ledger", paper=p, version=mistake["name"])
    assert ledger.load(paper)["paper"]["title"] == "Kelp forests, changed by mistake"
    damaged = next(v for v in history.versions(paper) if v["kind"] == "replaced" and v["rev"] == 0)
    assert damaged["comments"] is None
    assert history.read(paper, damaged["name"])[0] == b'{"schema": 1, "paper": '

    # a ledger deleted (the app shows the folder as missing, and still offers Put Back): its versions are there
    (paper / "ledger.json").unlink()
    assert call("history", paper=p)["versions"]
    call("put_back_ledger", paper=p, version=mistake["name"])
    assert ledger.load(paper)["paper"]["title"] == "Kelp forests, changed by mistake"


def test_rounds_the_ledger_does_not_name_are_kept(tmp_path):
    paper = handmade(tmp_path, rounds=((1, True),))
    (paper / "r3.old" / "src").mkdir(parents=True)  # a crashed re-ingest of a round the ledger no longer names
    (paper / "r3.old" / "src" / "main.tex").write_text("Round 3.\n")
    (paper / "r1.old" / "src").mkdir(parents=True)  # and one of round 1, which it does: it comes back
    (paper / "r1.old" / "src" / "main.tex").write_text("Round 1, as the ledger has it.\n")
    (paper / "r1.old" / "final.pdf").write_bytes(b"%PDF-1.4 synthetic")
    call("edit_paper", paper=str(paper), title="Kelp forests in winter")
    kept = sorted(p.name for p in (paper / ".orphans").iterdir())
    assert len(kept) == 2 and re.fullmatch(r"r1-\d{8}-\d{6}", kept[0]) and re.fullmatch(r"r3-\d{8}-\d{6}", kept[1])
    assert (paper / ".orphans" / kept[1] / "src" / "main.tex").read_text() == "Round 3.\n"
    assert (paper / ".orphans" / kept[0] / "src" / "main.tex").read_text() == "Round 1.\n"  # the half-built one
    assert (paper / "r1" / "src" / "main.tex").read_text() == "Round 1, as the ledger has it.\n"
    assert not list(paper.glob("r*.old"))
    assert [p["code"] for p in check.paper(paper)] == ["orphans"]


def _start_again(paper, tmp_path, monkeypatch, kills=()):
    """Re-ingest paper's open round 2 with a round built without TeX; kills: the moments ("building", "deleting") at
    which to copy the folder as a kill there would leave it (no handler runs), into tmp_path/killed-<moment>."""
    old = ledger.load(paper)["rounds"][1]

    def kill(moment):
        if moment in kills:
            shutil.copytree(paper, tmp_path / ("killed-" + moment))

    def built(paper, lg, n, source, main, engine, last_seq, progress):
        (paper / "r2" / "src").mkdir(parents=True)
        (paper / "r2" / "src" / "main.tex").write_text("Round 2, sent again.\n")
        kill("building")  # the ledger not saved yet
        lg["rounds"].append(dict(old, created="2026-10-22T12:00:00+08:00", source=source))
    rmtree = shutil.rmtree

    def deleting(path, *args, **kwargs):  # the ledger saved, the replaced round half deleted
        if ".old-" in str(path) and "deleting" in kills:
            (Path(path) / "src" / "main.tex").unlink()
            kill("deleting")
        return rmtree(path, *args, **kwargs)
    monkeypatch.setattr(api, "_new_round", built)
    monkeypatch.setattr(api.shutil, "rmtree", deleting)
    call("ingest", paper=str(paper), source="/synthetic/v2b")
    monkeypatch.undo()


def test_a_killed_replace_never_brings_back_half_a_round(tmp_path, monkeypatch):
    """Re-ingesting an open round sets the round it replaces aside, named for its record in the ledger, until the
    ledger names the new one. Killed before that save, the next call puts the old round back (the half-built one to
    .orphans); killed after it, while the old round was being deleted, the next call deletes the rest: half a round
    never comes back as the one the ledger describes."""
    paper = handmade(tmp_path)
    (paper / "r2" / "src" / "fig.pdf").write_bytes(b"%PDF-1.4 a figure of round 2")
    before = ledger.load(paper)["rounds"][1]
    _start_again(paper, tmp_path, monkeypatch, kills=("building", "deleting"))
    assert (paper / "r2" / "src" / "main.tex").read_text() == "Round 2, sent again.\n"
    assert sorted(os.listdir(paper)) == [".history", ".lock", "ledger.json", "r1", "r2"]

    building, deleting = tmp_path / "killed-building", tmp_path / "killed-deleting"
    assert [p.name[:7] for p in building.glob("r2.old*")] == ["r2.old-"]
    assert check.paper(building) == []  # a call that may still be running: not a problem yet
    call("state", paper=str(building))
    assert ledger.load(building)["rounds"][1] == before
    assert sorted(os.listdir(building / "r2" / "src")) == ["fig.pdf", "main.tex"]
    assert (building / "r2" / "src" / "main.tex").read_text() == "Round 2.\n"
    (half,) = (building / ".orphans").iterdir()
    assert re.fullmatch(r"r2-\d{8}-\d{6}", half.name) and not list(building.glob("r2.old*"))

    assert ledger.load(deleting)["rounds"][1]["created"] == "2026-10-22T12:00:00+08:00"
    call("state", paper=str(deleting))
    assert sorted(os.listdir(deleting)) == [".history", ".lock", "ledger.json", "r1", "r2"]
    assert (deleting / "r2" / "src" / "main.tex").read_text() == "Round 2, sent again.\n"
    assert check.paper(deleting) == []


def test_put_back_refuses_a_round_started_again(tmp_path, monkeypatch):
    """A version from before an open round was re-ingested describes another round under its number: refused."""
    paper = handmade(tmp_path)
    age(paper, 11 * 60)
    call("edit_paper", paper=str(paper), title="Kelp forests in winter")  # the version before it is copied
    early = history.versions(paper)[0]
    assert early["kind"] == "edit" and early["rounds"] == 2
    _start_again(paper, tmp_path, monkeypatch)
    raw = (paper / "ledger.json").read_bytes()
    with pytest.raises(EngineError, match="from before Round 2 was started again with a new source"):
        call("put_back_ledger", paper=str(paper), version=early["name"])
    assert (paper / "ledger.json").read_bytes() == raw


def test_a_round_left_by_an_ingest_stopped_hard_goes_to_orphans(tmp_path):
    """An ingest killed while it built round 3 leaves r3, which the ledger does not name: the next state (or any
    call) moves it to .orphans, where check reports it, so Put Back is not refused for it."""
    paper = handmade(tmp_path)
    age(paper, 11 * 60)
    call("edit_paper", paper=str(paper), title="Kelp forests in winter")  # the version before it is copied
    early = history.versions(paper)[0]
    (paper / "r3" / "src").mkdir(parents=True)
    (paper / "r3" / "src" / "main.tex").write_text("Round 3, half copied.\n")
    (paper / "r12").write_text("a file, not a round's folder")
    call("state", paper=str(paper))
    (kept,) = (paper / ".orphans").iterdir()
    assert re.fullmatch(r"r3-\d{8}-\d{6}", kept.name) and (kept / "src" / "main.tex").is_file()
    assert not (paper / "r3").exists() and (paper / "r12").is_file()
    assert [p["code"] for p in check.paper(paper)] == ["orphans"]
    call("put_back_ledger", paper=str(paper), version=early["name"])
    assert ledger.load(paper)["paper"]["title"] == "Kelp forests"

    (paper / "r3").mkdir()  # and any call that edits the ledger does the same
    call("edit_paper", paper=str(paper), title="Kelp forests in spring")
    assert not (paper / "r3").exists() and len(list((paper / ".orphans").iterdir())) == 2


def test_put_back_keeps_the_ids_given_out_since(tmp_path):
    """Comment ids given out since the version (R2-01 … R2-04, deleted or not) stay used: each round keeps the larger
    last_seq (CONTRACT §4)."""
    paper = handmade(tmp_path)
    age(paper, 11 * 60)
    call("edit_paper", paper=str(paper), title="Kelp forests in winter")
    early = history.versions(paper)[0]
    with ledger.edit(paper) as lg:
        lg["rounds"][1]["last_seq"] = 4
    call("put_back_ledger", paper=str(paper), version=early["name"])
    lg = ledger.load(paper)
    assert lg["paper"]["title"] == "Kelp forests" and [r["last_seq"] for r in lg["rounds"]] == [0, 4]
    with ledger.edit(paper) as lg:
        assert ledger.new_id(lg, 2) == "R2-05"


def test_put_back_refuses_a_version_whose_rounds_cannot_be_read(tmp_path):
    """A saved version is read as check reads a ledger (check.read_ledger): a round that is not an object with a
    number is refused in plain words, the ledger left as it was."""
    paper = handmade(tmp_path)
    lg = ledger.load(paper)
    name = "20261020-080000-{}-edit.json".format(lg["rev"])
    (paper / history.FOLDER / name).write_text(json.dumps(dict(lg, rounds=[1, {"n": "2"}])))
    raw = (paper / "ledger.json").read_bytes()
    with pytest.raises(EngineError, match="This saved version cannot be read, so it cannot be put back."):
        call("put_back_ledger", paper=str(paper), version=name)
    assert (paper / "ledger.json").read_bytes() == raw


def test_an_ingest_keeps_the_snapshot_warnings_and_clears_finished(tmp_path, monkeypatch):
    """A link skipped by the snapshot (a symlinked refs.bib) is kept in the round's build warnings, so later undefined
    citations have their reason; a new round clears the paper's Finished mark, which would otherwise show again once
    the round is closed. No TeX: the build is replaced by a failed one."""
    paper = handmade(tmp_path, rounds=((1, True),))
    call("edit_paper", paper=str(paper), finished="2026-10-20")
    source = tmp_path / "v2"
    source.mkdir()
    (source / "main.tex").write_text("Round 2.\n")
    (source / "refs.bib").symlink_to(tmp_path / "elsewhere.bib")
    seen = []
    monkeypatch.setattr(api.project, "compile", lambda *args: {
        "status": "failed", "pdf": None, "log": None, "pages": 0, "errors": [], "warnings": ["LaTeX Warning: x"],
        "tex": None})
    state = api.ingest({"paper": str(paper), "source": str(source)}, seen.append)["state"]
    assert "Skipped the symbolic link refs.bib" in seen
    lg = ledger.load(paper)
    assert lg["rounds"][1]["build"]["warnings"] == ["Skipped the symbolic link refs.bib", "LaTeX Warning: x"]
    assert state["round"]["build"]["warnings"] == lg["rounds"][1]["build"]["warnings"]
    assert lg["paper"]["finished"] is None
    assert call("summaries", papers=[str(paper)])["papers"][0]["paper"]["finished"] is None
    assert call("adopt_facts", paper=str(paper), finished="2026-10-20")["adopted"] == []  # the app's copy is stale


def test_round_checksums_of_any_file_name(tmp_path):
    """Names with a backslash before an n, a carriage return, a form feed or a Unicode line separator are read back
    as written (shasum's format: only a backslash and a line break are escaped, only \\n ends a line)."""
    rdir = tmp_path / "r1"
    names = ["fig\\new.tex", "back\\\\slash.tex", "a\rb.tex", "f\x0cg.tex", "u v.tex", "line\nbreak.tex"]
    (rdir / "src").mkdir(parents=True)
    for name in names:
        (rdir / "src" / name).write_text(name)
    disk.write_manifest(rdir, "main")
    entries, damaged = disk.parse_manifest((rdir / disk.MANIFEST).read_bytes().decode("utf-8"))
    assert not damaged and sorted(n for n, _ in entries) == sorted("src/" + n for n in names)
    assert disk.verify_manifest(rdir) == {"changed": [], "missing": [], "extra": []}
    if shutil.which("shasum"):
        assert subprocess.run(["shasum", "-a", "256", "-c", disk.MANIFEST], cwd=str(rdir), capture_output=True,
                              text=True).returncode == 0


def test_a_finished_round_looked_at_in_finder_is_intact(tmp_path):
    """Finder leaves a .DS_Store in rN/src when the advisor opens it (Show in Finder): the snapshot never copies a
    hidden file, so one is none of the round's files, neither at Finish nor after it, also when a list written before
    names one."""
    paper = handmade(tmp_path, rounds=((1, True),))
    r1 = paper / "r1"
    (r1 / "src" / ".DS_Store").write_bytes(b"Finder, at Finish")
    disk.write_manifest(r1, "main")
    assert disk.round_files(r1, "main") == ["final.pdf", "src/main.tex"]
    (r1 / "src" / ".DS_Store").write_bytes(b"Finder, later")
    (r1 / "src" / "sub" / ".hidden").mkdir(parents=True)
    (r1 / "src" / "sub" / ".hidden" / "x").write_text("x")
    assert disk.verify_manifest(r1) == {"changed": [], "missing": [], "extra": []}
    assert check.paper(paper) == []

    # a list written before names it (with whatever it held then), and Finder has rewritten it or it is gone
    with open(r1 / disk.MANIFEST, "a") as f:
        f.write(disk.manifest_line("src/.DS_Store", "0" * 64))
    assert disk.verify_manifest(r1) == {"changed": [], "missing": [], "extra": []}
    (r1 / "src" / ".DS_Store").unlink()
    assert disk.verify_manifest(r1) == {"changed": [], "missing": [], "extra": []}
    assert check.paper(paper) == []
    (r1 / "src" / "extra.tex").write_text("a file added to a finished round")  # still damage
    assert [(p["code"], p["files"]) for p in check.paper(paper)] == [("round_changed", ["r1/src/extra.tex"])]


# --- the fixture paper (TeX) -----------------------------------------------------------------------------------

@pytest.fixture(scope="module")
def finished(round1_template, tmp_path_factory):
    """The fixture paper with one comment and round 1 finished. Copy it before changing it."""
    paper = tmp_path_factory.mktemp("finished") / "paper"
    shutil.copytree(round1_template, paper)
    pdf = str(paper / "r1" / "build" / "main.pdf")
    call("comment", paper=str(paper), page=0, rects=select(pdf, 0, "simple keep-alive policy:"), text="",
         note="Say which policy.", kind="highlight")
    call("finish", paper=str(paper))
    return paper


@pytest.fixture
def done(finished, tmp_path):
    paper = tmp_path / "paper"
    shutil.copytree(finished, paper)
    return paper


@needs_tex
def test_a_round_records_its_tex_and_source_name_and_history(done):
    lg = ledger.load(done)
    r1 = lg["rounds"][0]
    assert r1["source_name"] == "v1" and re.match(r"pdfTeX, Version \S+ \(TeX Live \d{4}\)", r1["build"]["tex"])
    kinds = [v["kind"] for v in history.versions(done)]
    assert kinds[0] == "finish" and "ingest" in kinds
    assert lg["trail"][-1][2:] == ["finish"]
    assert [p["code"] for p in check.paper(done)] == []


@needs_tex
def test_finish_writes_the_rounds_checksums(done):
    r1 = done / "r1"
    listed = [line.split("  ", 1)[1] for line in (r1 / disk.MANIFEST).read_text().splitlines()]
    assert listed == sorted(listed) and {"build/main.pdf", "build/main.synctex.gz", "build/main.log",
                                         "final.pdf", "email.txt", "src/main.tex",
                                         "src/sections/method.tex"} <= set(listed)
    assert not {"prose.json", "contexts.json", "analysis.cache.json", "build/main.aux"} & set(listed)
    if shutil.which("shasum"):  # macOS's own tool reads it without the app
        assert subprocess.run(["shasum", "-a", "256", "-c", disk.MANIFEST], cwd=str(r1), capture_output=True,
                              text=True).returncode == 0
    # viewing a finished round changes none of its files (the caches are elsewhere)
    before = tree(r1)
    call("state", paper=str(done), round=1)
    call("prose", paper=str(done), round=1, state=False)
    assert disk.verify_manifest(r1) == {"changed": [], "missing": [], "extra": []}
    assert {k: v for k, v in tree(r1).items() if k in listed} == {k: v for k, v in before.items() if k in listed}
    # nor does the next round, which reads it throughout
    call("ingest", paper=str(done), source=str(FIXTURE / "v2"))
    assert disk.verify_manifest(r1) == {"changed": [], "missing": [], "extra": []}
    r2 = ledger.load(done)["rounds"][1]
    assert r2["analysis_sha256"] == disk.sha256(done / "r2" / "analysis.json")
    assert check.paper(done) == []


@needs_tex
def test_an_unnamed_round_folder_at_ingest_goes_to_orphans(tmp_path):
    paper = tmp_path / "paper"
    call("new", paper=str(paper), title="Predictive warm pools", student="Leo Park")
    (paper / "r1").mkdir()
    (paper / "r1" / "left.txt").write_text("from a crashed ingest")
    call("ingest", paper=str(paper), source=str(FIXTURE / "v1"))
    kept = list((paper / ".orphans").iterdir())
    assert len(kept) == 1 and (kept[0] / "left.txt").read_text() == "from a crashed ingest"
    assert (paper / "r1" / "src" / "main.tex").is_file() and not (paper / "r1" / "left.txt").exists()


@needs_tex
def test_check_finds_each_problem_and_changes_no_byte(done, tmp_path):
    def found(paper):
        before = tree(paper)
        problems = check.paper(paper)
        assert tree(paper) == before  # read only: not a byte, not a time, no .lock
        return {p["code"]: p for p in problems}

    def variant(name, change):
        paper = tmp_path / name
        shutil.copytree(done, paper)
        for p in paper.rglob("*"):  # rN/src is read-only
            os.chmod(p, os.lstat(p).st_mode | stat.S_IWUSR)
        change(paper)
        return found(paper)

    def edit(paper, fn):
        lg = json.loads((paper / "ledger.json").read_text())
        fn(lg)
        (paper / "ledger.json").write_text(json.dumps(lg))

    assert found(done) == {}
    os.unlink(done / ".lock")
    assert found(done) == {} and not (done / ".lock").exists()

    def flip(paper):
        f = paper / "r1" / "src" / "main.tex"
        data = bytearray(f.read_bytes())
        data[10] ^= 1
        f.write_bytes(bytes(data))
        (paper / "r1" / "email.txt").unlink()
        (paper / "r1" / "src" / "extra.tex").write_text("% added later\n")
    p = variant("changed", flip)
    assert p["round_changed"]["files"] == ["r1/src/main.tex", "r1/email.txt", "r1/src/extra.tex"]
    assert p["round_changed"]["round"] == 1

    p = variant("pdfs", lambda paper: ((paper / "r1" / "final.pdf").unlink(),
                                       edit(paper, lambda lg: lg["rounds"][0]["build"].update(pages=9))))
    assert {"final_pdf_missing", "page_count", "round_changed"} <= set(p)
    assert p["page_count"]["message"] == "Round 1's PDF has 4 pages, not 9."
    p = variant("damaged", lambda paper: (paper / "r1" / "build" / "main.pdf").write_bytes(b"%PDF-1.5 not a pdf"))
    assert "build_pdf_damaged" in p
    p = variant("nopdf", lambda paper: ((paper / "r1" / "build" / "main.pdf").unlink(),
                                        shutil.rmtree(paper / "r1" / "src"), (paper / "r1" / "src").mkdir()))
    assert {"build_pdf_missing", "source_missing"} <= set(p)

    def ids(lg):
        lg["comments"].append(dict(lg["comments"][0]))
        lg["comments"].append(dict(lg["comments"][0], id="R1-09"))
        lg["comments"][0]["rounds"]["1"]["anchor"]["file"] = "../../etc/passwd"
        lg["rounds"][0]["build"]["log"] = "../elsewhere/main.log"
    p = variant("ids", lambda paper: edit(paper, ids))
    assert p["duplicate_ids"]["message"] == "Comment ids are used twice: R1-01."
    assert p["ids_beyond_last_seq"]["message"] == "Comment ids were never given out: R1-09."
    outside = [q for q in check.paper(tmp_path / "ids") if q["code"] == "path_outside_round"]
    assert [q["files"] for q in outside] == [["../elsewhere/main.log"], ["ledger.json"]]
    assert "R1-01 (round 1): ../../etc/passwd" in outside[1]["message"]

    def leftovers(paper):
        hour_ago = time.time() - 3600
        for name in (".ledger.json.abc123.tmp", "r1/final.pdf.tmp"):
            (paper / name).write_text("half")
            os.utime(paper / name, (hour_ago, hour_ago))
        (paper / ".ledger.json.def456.tmp").write_text("a call still running")  # too new to be left over
        (paper / ".orphans" / "r2-20261021-101500").mkdir(parents=True)
        (paper / "ledger 2.json").write_text("{}")
        (paper / "r1" / "src" / ".notes.tex.icloud").write_text("")
    p = variant("leftovers", leftovers)
    assert p["leftovers"]["files"] == [".ledger.json.abc123.tmp", "r1/final.pdf.tmp"]
    assert p["orphans"]["files"] == [".orphans/r2-20261021-101500"]
    assert p["conflict_copies"]["files"] == ["ledger 2.json"]
    assert p["evicted"]["files"] == ["r1/src/notes.tex"]
    assert "round_changed" not in p  # an evicted round is not read

    assert set(variant("unreadable", lambda paper: (paper / "ledger.json").write_text("{\"schema\": 1,"))) \
        == {"ledger_unreadable"}
    assert set(variant("newer", lambda paper: edit(paper, lambda lg: lg.update(schema=2)))) == {"ledger_too_new"}
    assert set(variant("none", lambda paper: (paper / "ledger.json").unlink())) == {"no_ledger"}
    assert [q["code"] for q in check.paper(tmp_path / "nowhere")] == ["missing_folder"]

    # the RPC and the command line
    out = call("check", papers=[str(done), str(tmp_path / "unreadable")])
    assert [(e["path"], [q["code"] for q in e["problems"]]) for e in out["papers"]] == \
        [(str(done), []), (str(tmp_path / "unreadable"), ["ledger_unreadable"])]
    with pytest.raises(EngineError, match="papers is a list"):
        call("check", papers=str(done))
    run = subprocess.run([sys.executable, "-m", "paperole.cli", "check-folder", str(tmp_path / "newer")],
                         capture_output=True, text=True)
    assert json.loads(run.stdout)["papers"][0]["problems"][0]["code"] == "ledger_too_new"


def test_check_analysis_out_of_step(tmp_path):
    paper = handmade(tmp_path)
    with ledger.edit(paper) as lg:
        analysis.write(paper, lg["rounds"][1], {"schema": 1, "changes": []})
    assert check.paper(paper) == []
    (paper / "r2" / "analysis.json").write_text('{"schema": 1, "changes": [], "edited": "by hand"}')
    assert [(p["code"], p["round"]) for p in check.paper(paper)] == [("analysis_out_of_step", 2)]


def test_check_reports_a_comment_it_cannot_read(tmp_path, monkeypatch):
    """A comment whose rounds are not an object (a hand edit, a half-merged sync copy that is still JSON) is damage,
    reported with the other checks; and a folder whose check fails all the same gets its error, not the reply's."""
    a, b = handmade(tmp_path / "a"), handmade(tmp_path / "b")
    lg = json.loads((a / "ledger.json").read_text())
    lg["rounds"][1]["last_seq"] = 2
    lg["comments"] = [{"id": "R2-01", "rounds": ["2"]}, {"id": "R2-02", "rounds": "2"}]
    (a / "ledger.json").write_text(json.dumps(lg))
    problems = check.paper(a)
    assert [(p["code"], p["message"], p["files"]) for p in problems] == [
        ("ledger_unreadable", "The ledger cannot be read: the rounds of R2-01, R2-02 are damaged.", ["ledger.json"])]

    real = check.paper
    monkeypatch.setattr(check, "paper", lambda p: real(p) if p != str(b) else {}["no such key"])
    out = call("check", papers=[str(a), str(b)])["papers"]
    assert [q["code"] for q in out[0]["problems"]] == ["ledger_unreadable"]
    assert out[1] == {"path": str(b), "error": "'no such key'"}


@needs_tex
def test_the_facts_steer_the_overview(done):
    p = str(done)
    ov = call("overview", papers=[p], key_pages={p: {"round": 1, "page": 2}})
    assert ov["papers"][0]["overview"]["key_page"] == {"round": 1, "page": 2, "chosen": True, "followed": None}
    call("edit_paper", paper=p, key_page={"round": 1, "page": 1})
    ov = call("overview", papers=[p], key_pages={p: {"round": 1, "page": 2}})  # the ledger's choice wins
    assert ov["papers"][0]["overview"]["key_page"] == {"round": 1, "page": 1, "chosen": True, "followed": None}

    key = next(s["key"] for s in ov["papers"][0]["overview"]["sections"] if s["written"])  # where R1-01 is

    def land(app):
        out = call("overview", papers=[p], buckets={p: {key: app}})["students"][0]["land"]
        return dict(zip((c["bucket"] for c in out["columns"]), out["total"]))
    assert land("discussion")["discussion"] == 1  # the app's answer while the ledger has none
    call("edit_paper", paper=p, buckets={key: "results"})
    assert "discussion" not in land("discussion") and land("discussion")["results"] >= 1  # the ledger's wins


@needs_tex
def test_cli_edit_paper_facts_history_and_put_back(done):
    def run(*args):
        out = subprocess.run([sys.executable, "-m", "paperole.cli"] + [str(a) for a in args], capture_output=True,
                             text=True)
        assert out.returncode == 0, out.stderr
        return json.loads(out.stdout)
    run("edit-paper", done, "--finished", "2026-10-22", "--key-page", "1:0", "--buckets", '{"methods": "method"}')
    lg = ledger.load(done)["paper"]
    assert (lg["finished"], lg["key_page"], lg["buckets"]) == ("2026-10-22", {"round": 1, "page": 0},
                                                              {"methods": "method"})
    run("edit-paper", done, "--finished", "none")
    assert ledger.load(done)["paper"]["finished"] is None and ledger.load(done)["paper"]["buckets"]
    versions = run("history", done)["versions"]
    finish = next(v for v in versions if v["kind"] == "finish")
    state = run("put-back", done, finish["name"])["state"]
    assert "finished" not in ledger.load(done)["paper"] and state["round"]["closed"]
    pid = ledger.load(done)["paper"]["id"]
    assert run("fork", done)["forked_from"] == pid
