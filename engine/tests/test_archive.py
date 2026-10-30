"""Export files and Import (design/data/DATA.md §3, §5.2, §5.4; CONTRACT.md amendment "Export and import files"):
round trips of everything, one student and one paper (every file byte for byte, each round's state and the
overview the same); each status Import can find; the refusals at the boundary (a link, "..", an absolute name, NUL,
names a Mac takes for one, a zip bomb, a lying size, a damaged byte, a missing and an extra file, a damaged list of
checksums, a large ledger, a file for reading, a newer one); a schema-1 backup, a review folder zipped in Finder, a
review folder and a folder searched three levels down; swap_in and its rollback; cancel and low free space leaving
nothing; RPC (cancel) and CLI. Synthetic papers in temporary folders only: hand-made ledgers without TeX, the
fixture paper and the four-round kelp paper of test_overview."""
import hashlib
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

from conftest import quiet
from paperole import EngineError, api, archive, cli, disk, ledger
from test_data_safety import PATH, call, handmade
from test_overview import kelp  # noqa: F401  (the four-round paper)

needs_tex = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")


def files(root):
    """Every file under root but .lock: {relative path: (bytes' SHA-256, permission bits)}."""
    out = {}
    for p in sorted(Path(root).rglob("*")):
        if p.is_file() and p.name != ".lock":
            out[p.relative_to(root).as_posix()] = (hashlib.sha256(p.read_bytes()).hexdigest(),
                                                  stat.S_IMODE(p.stat().st_mode))
    return out


def views(papers):
    """What the app shows of papers: each round's state and the overview."""
    out = {}
    for p in papers:
        lg = ledger.load(p)
        out[str(p)] = [call("state", paper=str(p), round=r["n"]) for r in lg["rounds"]] or [call("state", paper=str(p))]
    out["overview"] = call("overview", papers=[str(p) for p in papers])
    return out


def listed(*papers):
    return [{"path": str(p), "id": ledger.paper_id(p, ledger.load(p))} for p in papers]


def statuses(result):
    return {Path(p["folder"]).name if p["in_place"] else p["folder"].rsplit("/", 1)[-1]: p["status"]
            for p in result["papers"]}


def rebuild(src, out, drop=(), add=(), change=None):
    """A copy of a .zip without the entries named in drop, with add's (name, bytes) entries, and change(name, data)
    applied to each entry's bytes."""
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            if info.filename in drop:
                continue
            data = zin.read(info)
            zout.writestr(info, change(info.filename, data) if change else data)
        for name, data in add:
            zout.writestr(name, data)
    return out


def raw_zip(path, entries):
    """A .zip of (name, bytes, unix mode or None) entries, deflated."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data, mode in entries:
            info = zipfile.ZipInfo(name, (2026, 10, 22, 9, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            if mode is not None:
                info.external_attr = mode << 16
            z.writestr(info, data)
    return path


def central(raw, name):
    """The offset of name's central directory record in a .zip's bytes."""
    at = 0
    while True:
        at = raw.index(b"PK\x01\x02", at)
        n = struct.unpack("<H", raw[at + 28:at + 30])[0]
        if raw[at + 46:at + 46 + n] == name.encode():
            return at
        at += 4


def export(tmp, *papers, **kw):
    dest = tmp / kw.pop("name", "out.zip")
    return Path(archive.write([{"path": str(p)} for p in papers], dest, **kw)["path"])


# --- round trips ----------------------------------------------------------------------------------------------

def _library(tmp, kelp_paper):
    """Four papers of three students in tmp/Reviews: kelp (Mei Lin, four rounds) and a second copy of it under its
    own id and title, the fixture paper (Lin Zhou, round 1 open, one comment) and a hand-made one (Maya Chen)."""
    from conftest import FIXTURE, select
    root = tmp / "Reviews"
    root.mkdir()
    a = root / "Kelp drift"
    shutil.copytree(kelp_paper, a)
    b = root / "Kelp drift, winter"
    shutil.copytree(kelp_paper, b)
    call("fork", paper=str(b))
    call("edit_paper", paper=str(b), title="Kelp drift in winter")
    c = root / "Warm pools"
    call("new", paper=str(c), title="Warm pools", student="Lin Zhou")
    call("ingest", paper=str(c), source=str(FIXTURE / "v1"))
    pdf = str(c / "r1" / "build" / "main.pdf")
    call("comment", paper=str(c), page=0, rects=select(pdf, 0, "simple keep-alive policy:"), text="", note="Which?",
         kind="highlight")
    d = handmade(root / "hand")
    d = d.rename(root / "Kelp forests")
    return [a, b, c, d]


@needs_tex
def test_round_trips(kelp, tmp_path):  # noqa: F811
    papers = _library(tmp_path, kelp[0])
    a, b, c, d = papers
    tags = {"schema": 1, "tags": [{"id": "t-rigor", "name": "Rigor"}]}
    drafts = {str(c): {"paper": str(c), "rounds": {"1": {"R1-01": "Say which."}}}}
    for scope, chosen in (("everything", papers), ("chosen", [a, b]), ("chosen", [c])):
        before_views, before_files = views(chosen), {str(p): files(p) for p in chosen}
        ids = listed(*chosen)
        events = []
        out = archive.write([{"path": str(p), "title": "?", "student": "?"} for p in chosen], tmp_path / "out.zip",
                            scope=scope, tags=tags, drafts=drafts,
                            settings={"appearance": "dark"} if scope == "everything" else None,
                            made_by={"variant": "Paperole Dev", "install": "i-test", "app": "0.2 (5)"},
                            progress=events.append)
        assert events == ["Writing “{}” ({} of {})…".format(ledger.load(p)["paper"]["title"], i + 1, len(chosen))
                          for i, p in enumerate(chosen)] + ["Checking…"]
        backup = out["backup"]
        assert (backup["schema"], backup["kind"], backup["scope"], backup["missing"], backup["tags"]) == \
            (2, "export", scope, [], 1)
        assert backup["made_by"]["variant"] == "Paperole Dev" and backup["made_by"]["engine"] == "0.1.0"
        assert [(p["student"], p["was_at"], p["id"]) for p in backup["papers"]] == \
            [(ledger.load(p)["paper"]["student"], str(p), i["id"]) for p, i in zip(chosen, ids)]
        assert backup["papers"][0]["folder"].startswith("students/{}/".format(backup["papers"][0]["student"]))
        assert [x for x in os.listdir(tmp_path) if x.startswith(".")] == []  # no temporary file left

        for p in chosen:  # every review folder lost; the list still names them
            shutil.rmtree(p)
        result = archive.check(out["path"], ids)
        assert result["intact"] and result["checked"] and result["problems"] == []
        assert (result["tags"], result["settings"]) == (tags, {"appearance": "dark"} if scope == "everything" else None)
        assert [p["status"] for p in result["papers"]] == ["put_back"] * len(chosen)
        assert [p["listed"] for p in result["papers"]] == [str(p) for p in chosen]
        assert [p["draft"] for p in result["papers"]] == [drafts.get(str(p)) for p in chosen]
        for entry, p in zip(result["papers"], chosen):
            back = archive.unpack(out["path"], entry["folder"], p.parent)
            assert back["path"] == str(p) and back["problems"] == []
        assert {str(p): files(p) for p in chosen} == before_files
        assert views(chosen) == before_views
        os.unlink(out["path"])


def test_shasum_reads_the_checksums(tmp_path):
    paper = handmade(tmp_path / "a")
    out = export(tmp_path, paper, tags={"schema": 1, "tags": []})
    unzipped = tmp_path / "unzipped"
    with zipfile.ZipFile(out) as z:
        z.extractall(unzipped)
    (top,) = unzipped.iterdir()
    assert top.name == "out" and sorted(os.listdir(top)) == ["README.txt", "app", "backup.json", "manifest-sha256.txt",
                                                            "students"]
    run = subprocess.run(["shasum", "-a", "256", "-c", "manifest-sha256.txt"], cwd=str(top), capture_output=True,
                         text=True)
    assert run.returncode == 0 and run.stdout.count(": OK") == len(files(top)) - 2  # not itself, not backup.json
    backup = json.loads((top / "backup.json").read_text())
    assert backup["manifest"]["sha256"] == hashlib.sha256((top / "manifest-sha256.txt").read_bytes()).hexdigest()
    assert "shasum -a 256 -c manifest-sha256.txt" in (top / "README.txt").read_text()


def test_the_app_is_paperole_and_reads_what_papercollab_wrote(tmp_path):
    """The app was PaperCollab until 2026-10-27 (the advisor's decision of that day): backup.json now says "Paperole"
    and made_by the app's name; a file the app wrote before ("PaperCollab", "PaperCollab Dev") is read as ever, and
    shown under the app's new name; a file of any other app is refused."""
    paper = handmade(tmp_path / "a")
    for variant, shown in (("Paperole Dev", "Paperole Dev"), ("Paperole", "Paperole"), (None, "Paperole"),
                           ("PaperCollab Dev", "Paperole Dev")):
        out = export(tmp_path, paper, made_by={"variant": variant, "install": "i-1", "app": None})
        with zipfile.ZipFile(out) as z:
            backup = json.loads(z.read("out/backup.json"))
            readme = z.read("out/README.txt").decode("utf-8")
        assert (backup["app"], backup["made_by"]["variant"]) == ("Paperole", variant)
        assert readme.startswith("Paperole export\nMade on ") and " by {}.\n".format(shown) in readme
        assert "PaperCollab" not in readme
        assert archive.info([str(out)])["files"][0]["backup"]["app"] == "Paperole"
        os.unlink(out)
    new = export(tmp_path, paper, made_by={"variant": "Paperole Dev", "install": "i-1", "app": None})
    ids = listed(paper)
    for app, read in (("PaperCollab", True), ("Paperole", True), ("Other", False), (None, False)):
        old = rebuild(new, tmp_path / "old.zip", change=lambda n, d: json.dumps(dict(
            json.loads(d), app=app, made_by=dict(json.loads(d)["made_by"], variant="PaperCollab Dev"))).encode()
            if n.endswith("/backup.json") else d)
        if read:
            result = archive.check(str(old), ids)
            assert result["intact"] and [p["status"] for p in result["papers"]] == ["same"]
            assert archive.info([str(old)])["files"][0]["backup"]["made_by"]["variant"] == "PaperCollab Dev"
        else:
            with pytest.raises(EngineError, match="is not a Paperole export"):
                archive.check(str(old), ids)
        os.unlink(old)


def test_imports_unpack_in_a_folder_of_the_new_name(tmp_path, monkeypatch):
    """The hidden folder an import unpacks into is named .Paperole-import-… (the app sweeps it and the old
    .PaperCollab-import-… after an interrupted import)."""
    paper = handmade(tmp_path / "a")
    out = export(tmp_path, paper)
    made = []
    real = archive.tempfile.mkdtemp
    monkeypatch.setattr(archive.tempfile, "mkdtemp", lambda **kw: made.append(kw.get("prefix")) or real(**kw))
    dest = tmp_path / "back"
    dest.mkdir()
    archive.unpack(str(out), archive.check(str(out), [])["papers"][0]["folder"], dest)
    assert made == [".Paperole-import-"] and [x for x in os.listdir(dest) if x.startswith(".")] == []


def test_what_write_refuses_and_leaves_out(tmp_path):
    a, b = handmade(tmp_path / "a"), handmade(tmp_path / "b")
    (b / "ledger.json").unlink()
    out = archive.write([{"path": str(a)}, {"path": str(a)}, {"path": str(b), "title": "B", "student": "S"},
                         {"path": str(tmp_path / "gone"), "title": "Gone", "student": "S"}], tmp_path / "x.zip")
    assert [p["was_at"] for p in out["backup"]["papers"]] == [str(a)]  # the same folder once
    assert [(m["title"], m["why"]) for m in out["backup"]["missing"]] == [
        ("B", "There is no ledger.json in it."), ("Gone", "The folder is not there.")]
    for kw, message in (({"scope": "chosen", "settings": {}}, "only into an export of everything"),
                        ({"scope": "some"}, "scope is everything or chosen"), ({"kind": "reading"}, "kind is"),
                        ({"dest": a / "x.zip"}, "outside the review folders"), ({"dest": tmp_path}, "is a folder")):
        with pytest.raises(EngineError, match=message):
            archive.write([{"path": str(a)}], kw.pop("dest", tmp_path / "y.zip"), **kw)
    with pytest.raises(EngineError, match="papers is a list"):
        archive.write(["a"], tmp_path / "y.zip")
    assert sorted(os.listdir(tmp_path)) == ["a", "b", "x.zip"]


def test_write_never_into_a_review_folder_it_does_not_export(tmp_path):
    """A file saved in another paper's review folder (here in a finished round's source) would make that round
    damaged: refused like one saved in a chosen paper's, before anything is written."""
    a, other = handmade(tmp_path / "a"), handmade(tmp_path / "other")
    before = files(other)
    for dest in (other / "x.zip", other / "r1" / "src" / "x.zip"):
        with pytest.raises(EngineError, match="Save the file outside the review folders: .* is in one."):
            archive.write([{"path": str(a)}], dest)
    assert files(other) == before
    assert archive.write([{"path": str(a)}], tmp_path / "x.zip")["backup"]["papers"][0]["was_at"] == str(a)


def test_a_finished_round_with_a_ds_store_reads_back_intact(tmp_path):
    """Finder's .DS_Store in a finished round's source (and one an older list names) is no damage in a file either
    (archive._rounds, as disk.verify_manifest)."""
    a = handmade(tmp_path / "a", rounds=((1, True),))
    r1 = a / "r1"
    disk.write_manifest(r1, "main")
    with open(r1 / disk.MANIFEST, "a") as f:
        f.write(disk.manifest_line("src/sub/.DS_Store", "0" * 64))
    (r1 / "src" / ".DS_Store").write_bytes(b"Finder")
    r = archive.check(export(tmp_path, a), listed(a))
    (p,) = r["papers"]
    assert r["intact"] and (p["status"], p["problems"], p["yours_problems"]) == ("same", [], [])
    (r1 / "src" / "late.tex").write_text("added after Finish")  # a file of the round is still damage
    p = archive.check(export(tmp_path, a, name="late.zip"))["papers"][0]
    assert [(q["code"], q["files"]) for q in p["problems"]] == [("round_changed", ["r1/src/late.tex"])]


# --- statuses -------------------------------------------------------------------------------------------------

def test_each_status(tmp_path):
    a = handmade(tmp_path / "a")
    file = export(tmp_path, a, name="a.zip")
    r = archive.check(file)  # no list: new
    (p,) = r["papers"]
    assert (p["status"], p["listed"], p["yours"], p["in_place"]) == ("new", None, None, False)
    assert p["this"] == {"title": "Kelp forests", "student": "Maya Chen", "round": 2, "open": True, "comments": 0,
                         "saved": ledger.load(a)["saved"]}
    assert archive.check(file, listed(a))["papers"][0]["status"] == "same"

    # yours is newer, then damaged
    call("edit_paper", paper=str(a), title="Kelp forests in winter")
    p = archive.check(file, listed(a))["papers"][0]
    assert (p["status"], p["listed"], p["yours"]["title"], p["this"]["title"]) == \
        ("older", str(a), "Kelp forests in winter", "Kelp forests")
    (a / "r1" / "final.pdf").unlink()
    p = archive.check(file, listed(a))["papers"][0]
    assert p["status"] == "yours_damaged" and [q["code"] for q in p["yours_problems"]] == ["final_pdf_missing"]

    # this copy newer, or both changed
    b = tmp_path / "b"
    shutil.copytree(a, b)
    (b / "r1" / "final.pdf").write_bytes(b"%PDF-1.4 synthetic")
    shutil.copy(b / "r1" / "final.pdf", a / "r1" / "final.pdf")
    call("edit_paper", paper=str(b), student="Maya L. Chen")
    newer = export(tmp_path, b, name="b.zip")
    assert archive.check(newer, listed(a))["papers"][0]["status"] == "newer"
    call("edit_paper", paper=str(a), student="M. Chen")
    assert archive.check(newer, listed(a))["papers"][0]["status"] == "diverged"

    # listed, its folder gone: put back, by id, or by its place when the list gives no id
    gone = listed(a)
    shutil.rmtree(a)
    p = archive.check(newer, gone)["papers"][0]
    assert (p["status"], p["listed"], p["yours"]) == ("put_back", str(a), None)
    b = b.rename(tmp_path / "b moved")
    assert archive.check(newer, [{"path": str(tmp_path / "b")}])["papers"][0]["status"] == "put_back"  # made from b
    assert archive.check(newer, [{"path": str(a)}])["papers"][0]["status"] == "new"  # another place, no id
    (tmp_path / "via").symlink_to(tmp_path)  # one place spelt two ways (/tmp/… and /private/tmp/…)
    p = archive.check(newer, [{"path": str(tmp_path / "via" / "b")}])["papers"][0]
    assert (p["status"], p["listed"]) == ("put_back", str(tmp_path / "via" / "b"))

    # the same id, another paper; and twice in one file
    c = handmade(tmp_path / "c")
    lg = json.loads((c / "ledger.json").read_text())
    lg["paper"]["id"], lg["paper"]["created"] = ledger.load(b)["paper"]["id"], "2025-01-01T00:00:00+08:00"
    (c / "ledger.json").write_text(json.dumps(lg))
    p = archive.check(newer, listed(c))["papers"][0]
    assert (p["status"], p["listed"]) == ("different_paper", str(c))
    twice = export(tmp_path, b, c, name="twice.zip")
    assert [p["status"] for p in archive.check(twice)["papers"]] == ["new", "different_paper"]

    # can't import: an unreadable ledger, a newer one
    (c / "ledger.json").write_text("{")
    d = handmade(tmp_path / "d")
    lg = json.loads((d / "ledger.json").read_text())
    lg["schema"] = 2
    (d / "ledger.json").write_text(json.dumps(lg))
    r = archive.check(export(tmp_path, c, d, name="bad.zip"))
    assert [(p["status"], p["reason"]) for p in r["papers"]] == [
        ("cannot_import", "Its ledger cannot be read."), ("cannot_import", "Its ledger was written by a newer Paperole.")]
    assert not r["intact"]
    with pytest.raises(EngineError, match="cannot be read"):
        archive.unpack(tmp_path / "bad.zip", r["papers"][0]["folder"], tmp_path)


def test_a_copy_of_a_paper_still_where_it_was(tmp_path):
    """The list lost, or the paper removed from it: a file's copy of a paper whose folder is still where it was is
    `found` there, so Import never takes it for a paper to add over yours; not when the folder is listed, gone or
    another paper's, nor for a folder listed in place."""
    a = handmade(tmp_path / "a")
    file = export(tmp_path, a, name="a.zip")
    call("edit_paper", paper=str(a), title="Kelp forests in winter")  # yours newer than the file's
    (p,) = archive.check(file)["papers"]
    assert (p["status"], p["listed"], p["found"]) == ("new", None, str(a))
    assert archive.check(file, listed(a))["papers"][0]["found"] is None
    (p,) = archive.check(a)["papers"]
    assert (p["in_place"], p["status"], p["found"]) == (True, "new", None)
    lg = json.loads((a / "ledger.json").read_text())
    lg["paper"]["created"] = "2025-01-01T00:00:00+08:00"  # another paper there with its id
    (a / "ledger.json").write_text(json.dumps(lg))
    assert archive.check(file)["papers"][0]["found"] is None
    shutil.rmtree(a)
    assert archive.check(file)["papers"][0]["found"] is None


def test_a_listed_paper_whose_ledger_cannot_be_read(tmp_path):
    """The app gives each listed paper's id: the ledger's own wins while it reads (the app's is a copy), and the app's
    matches a moved paper whose ledger cannot be read, so the file's intact copy is offered in its place rather than
    added beside it."""
    a = handmade(tmp_path / "a")
    file = export(tmp_path, a, name="a.zip")
    pid = ledger.load(a)["paper"]["id"]
    moved = a.rename(tmp_path / "moved")
    assert archive.check(file, [{"path": str(moved), "id": "p-0000000000000000"}])["papers"][0]["status"] == "same"
    (moved / "ledger.json").write_text("{")
    assert archive.check(file, [{"path": str(moved)}])["papers"][0]["status"] == "new"
    p = archive.check(file, [{"path": str(moved), "id": pid}])["papers"][0]
    assert (p["status"], p["listed"]) == ("yours_damaged", str(moved))


def test_an_automatic_backup_never_replaces_a_file(tmp_path):
    """Two Macs backing up into one folder in the same minute: the second file gets a name of its own; an export
    still replaces the file the save panel agreed to replace."""
    a = handmade(tmp_path / "a")
    dest = tmp_path / "PaperCollab Backup 2026-10-22 1640.zip"
    dest.write_bytes(b"another Mac's backup")
    r = archive.write([{"path": str(a)}], dest, scope="everything", kind="automatic")
    assert Path(r["path"]).name == "PaperCollab Backup 2026-10-22 1640 2.zip"
    assert dest.read_bytes() == b"another Mac's backup" and archive.check(r["path"])["intact"]
    r = archive.write([{"path": str(a)}], dest)
    assert r["path"] == str(dest) and archive.check(dest)["intact"]


def test_keep_both_and_a_taken_name(tmp_path):
    a = handmade(tmp_path / "a")
    file = export(tmp_path, a)
    folder = archive.check(file)["papers"][0]["folder"]
    one = archive.unpack(file, folder, tmp_path / "a")  # "kelp" is taken
    both = archive.unpack(file, folder, tmp_path / "a", copy=True)
    fork = archive.unpack(file, folder, tmp_path / "a", fork=True)
    assert [Path(x["path"]).name for x in (one, both, fork)] == ["kelp 2", "kelp 3", "kelp 4"]
    pid = ledger.load(a)["paper"]["id"]
    assert one["id"] == pid and files(one["path"]) == files(a)
    for x, title in ((both, "Kelp forests (copy)"), (fork, "Kelp forests")):
        p = ledger.load(x["path"])["paper"]
        assert (p["id"], p["forked_from"], p["title"]) == (x["id"], pid, title) and x["id"] != pid
    assert [p["status"] for p in archive.check(file, listed(Path(both["path"])))["papers"]] == ["new"]


# --- refusals at the boundary ---------------------------------------------------------------------------------

LEDGER = json.dumps({"schema": 1, "paper": {"title": "T", "student": "S", "created": "x"}, "rounds": [],
                     "comments": []}).encode()


@pytest.mark.parametrize("entries, why", [
    ([("P/ledger.json", LEDGER, None), ("P/link", b"/etc/passwd", stat.S_IFLNK | 0o777)], "a link"),
    ([("P/ledger.json", LEDGER, None), ("P/../evil", b"x", None)], "outside its folder"),
    ([("P/ledger.json", LEDGER, None), ("/tmp/evil", b"x", None)], "outside its folder"),
    ([("P/ledger.json", LEDGER, None), ("P/..\\evil", b"x", None)], "outside its folder"),
    ([("P/ledger.json", LEDGER, None), ("P/Ledger.json", LEDGER, None)], "a Mac would take for one"),
    ([("P/ledger.json", LEDGER, None), ("P/café.tex", b"a", None), ("P/café.tex", b"b", None)],
     "a Mac would take for one"),
    ([("P/ledger.json", LEDGER, None), ("P/a", b"a", None), ("P/a/b", b"b", None)], "one name twice"),
    ([("P/ledger.json", LEDGER, None), ("P/bomb.pdf", bytes(2 << 20), None)], "compressed more than 100 times"),
    ([("P/ledger.json", LEDGER, None)] + [("P/z{}.bin".format(i), bytes(900000), None) for i in range(3)],
     "its files are compressed more than 100 times"),  # each under 1 MB, all of them together a bomb
    ([("P/ledger.json", LEDGER, None), ("P/./a", b"x", None)], "outside its folder"),
    ([("P/ledger.json", LEDGER, None), ("P//a", b"x", None)], "outside its folder"),
    ([("P/ledger.json", LEDGER, None), ("P/d/", b"", stat.S_IFLNK | 0o777)], "a link"),
])
def test_unsafe_entries_are_refused(tmp_path, entries, why):
    z = raw_zip(tmp_path / "x.zip", entries)
    for fn in (lambda: archive.check(z), lambda: archive.unpack(z, "P", tmp_path)):
        with pytest.raises(EngineError, match=why):
            fn()
    assert sorted(os.listdir(tmp_path)) == ["x.zip"]


def test_a_nul_in_a_name_and_too_many_entries(tmp_path, monkeypatch):
    z = raw_zip(tmp_path / "x.zip", [("P/ledger.json", LEDGER, None), ("P/aXb.tex", b"x", None)])
    raw = z.read_bytes()
    assert raw.count(b"P/aXb.tex") == 2  # its local header and the central directory
    z.write_bytes(raw.replace(b"P/aXb.tex", b"P/a\x00b.tex"))
    with pytest.raises(EngineError, match="NUL"):
        archive.check(z)
    monkeypatch.setattr(archive, "MAX_ENTRIES", 1)
    with pytest.raises(EngineError, match="more than 1 files"):
        archive.check(raw_zip(tmp_path / "y.zip", [("P/ledger.json", LEDGER, None), ("P/a", b"x", None)]))


def test_a_password_protected_entry(tmp_path):
    z = raw_zip(tmp_path / "x.zip", [("P/ledger.json", LEDGER, None), ("P/a.tex", b"x", None)])
    raw = bytearray(z.read_bytes())
    raw[central(raw, "P/a.tex") + 8] |= 0x1  # the central directory's "encrypted" flag
    z.write_bytes(bytes(raw))
    for fn in (lambda: archive.check(z), lambda: archive.unpack(z, "P", tmp_path)):
        with pytest.raises(EngineError, match="password-protected"):
            fn()
    assert sorted(os.listdir(tmp_path)) == ["x.zip"]


def test_what_a_file_holds_always_reads_back(tmp_path, monkeypatch):
    """A file written here passes its own checks: a file over 1 MB that deflates more than 100× (a blank picture) goes
    in stored, not deflated, so it is never taken for a zip bomb; any file name reads back from the checksums (a
    backslash before an n, a carriage return); a cache's temporary file renamed while the folder is written is left
    out, not an error."""
    paper = handmade(tmp_path / "a")
    src = paper / "r2" / "src"
    (src / "blank.bmp").write_bytes(bytes(2 << 20))
    (src / "noise.bin").write_bytes(os.urandom(2 << 20))
    (src / "fig\\new.tex").write_text("x")
    (src / "a\rb.tex").write_text("y")
    walk = archive._walk

    def listed_then_gone(real):  # a temporary file listed, then renamed before it is read
        found, empty = walk(real)
        return found + [("r2/contexts.json.x.tmp", str(Path(real, "r2", "contexts.json.x.tmp")))], empty
    monkeypatch.setattr(archive, "_walk", listed_then_gone)
    out = export(tmp_path, paper)
    monkeypatch.undo()
    with zipfile.ZipFile(out) as z:
        kinds = {Path(i.filename).name: i.compress_type for i in z.infolist()}
    assert kinds["blank.bmp"] == zipfile.ZIP_STORED and kinds["noise.bin"] == zipfile.ZIP_DEFLATED
    assert "contexts.json.x.tmp" not in kinds
    r = archive.check(out)
    assert r["intact"] and r["problems"] == [] and [p["status"] for p in r["papers"]] == ["new"]
    (tmp_path / "b").mkdir()
    back = archive.unpack(out, r["papers"][0]["folder"], tmp_path / "b")
    assert back["problems"] == [] and files(back["path"]) == files(paper)
    for inside in (paper, src):  # never into a review folder, nor a round's source (a place from a file's was_at)
        with pytest.raises(EngineError, match="outside the review folders"):
            archive.unpack(out, r["papers"][0]["folder"], inside)
    assert files(back["path"]) == files(paper)


def test_a_damaged_line_of_checksums_means_nothing_is_trusted(tmp_path):
    """A line of manifest-sha256.txt that cannot be read (here pinned by backup.json all the same) could have named a
    file now missing: no paper of the file is imported."""
    good = export(tmp_path, handmade(tmp_path / "a"), name="good.zip")
    with zipfile.ZipFile(good) as z:
        manifest = z.read("good/" + archive.MANIFEST)
        backup = json.loads(z.read("good/" + archive.BACKUP))
    manifest += b"not a line of checksums\n"
    backup["manifest"]["sha256"] = hashlib.sha256(manifest).hexdigest()
    bad = rebuild(good, tmp_path / "bad.zip", change=lambda n, d: manifest if n.endswith(archive.MANIFEST) else
                  json.dumps(backup).encode() if n.endswith(archive.BACKUP) else d)
    r = archive.check(bad)
    assert not r["intact"] and r["problems"] == [{"file": archive.MANIFEST, "problem": "damaged"}]
    assert [p["reason"] for p in r["papers"]] == ["The file's list of checksums is damaged, so nothing in it can be "
                                                  "trusted."]


def test_damage_found_by_the_checksums(tmp_path, monkeypatch):
    a, b = handmade(tmp_path / "a"), handmade(tmp_path / "b")
    good = export(tmp_path, a, b, name="good.zip")
    folder_a, folder_b = (p["folder"] for p in archive.check(good)["papers"])
    top = "good/"

    def reasons(z):
        r = archive.check(z)
        return [p["reason"] for p in r["papers"]], r["intact"], r["problems"]

    # a byte of a's final.pdf flipped inside the .zip
    raw = bytearray(good.read_bytes())
    with zipfile.ZipFile(good) as z:
        info = z.getinfo(top + folder_a + "/r1/final.pdf")
    start = info.header_offset + 30 + sum(struct.unpack("<HH", raw[info.header_offset + 26:info.header_offset + 30]))
    raw[start + info.compress_size // 2] ^= 0xFF
    flipped = tmp_path / "flipped.zip"
    flipped.write_bytes(bytes(raw))
    assert reasons(flipped) == (["A file in it is damaged: r1/final.pdf.", None], False,
                                [{"file": folder_a + "/r1/final.pdf", "problem": "damaged"}])
    with pytest.raises(EngineError, match="damaged: r1/final.pdf"):
        archive.unpack(flipped, folder_a, tmp_path)
    assert archive.unpack(flipped, folder_b, tmp_path / "b")["problems"] == []  # the other paper is intact

    # a size that lies: larger, then smaller, than the entry holds
    for delta in (5, -1):
        raw = bytearray(good.read_bytes())
        at = central(raw, top + folder_a + "/r1/src/main.tex")
        size = struct.unpack("<I", raw[at + 24:at + 28])[0]
        raw[at + 24:at + 28] = struct.pack("<I", size + delta)
        lying = tmp_path / "lying.zip"
        lying.write_bytes(bytes(raw))
        assert reasons(lying)[0][0] == "A file in it is damaged: r1/src/main.tex."

    # a file missing, a file added, a different file
    missing = rebuild(good, tmp_path / "missing.zip", drop={top + folder_b + "/r2/src/main.tex"})
    assert reasons(missing)[0] == [None, "A file of it is missing from this file: r2/src/main.tex."]
    extra = rebuild(good, tmp_path / "extra.zip", add=[(top + folder_a + "/r1/src/evil.tex", b"x")])
    assert reasons(extra)[0] == ["It holds a file that was not in it when this file was made: r1/src/evil.tex.", None]
    changed = rebuild(good, tmp_path / "changed.zip",
                      change=lambda n, d: d + b"\n" if n.endswith(folder_b + "/ledger.json") else d)
    assert reasons(changed)[0] == [None, "A file in it is damaged: ledger.json."]

    # the list of checksums itself changed: nothing can be trusted
    pinned = rebuild(good, tmp_path / "pinned.zip", change=lambda n, d: d + b"\n" if n.endswith(archive.MANIFEST) else d)
    r = archive.check(pinned)
    assert not r["intact"] and r["problems"] == [{"file": archive.MANIFEST, "problem": "damaged"}]
    assert {p["reason"] for p in r["papers"]} == {"The file's list of checksums is damaged, so nothing in it can be "
                                                  "trusted."}

    # a ledger over the limit (unknown keys are allowed: padding)
    lg = json.loads((a / "ledger.json").read_text())
    lg["padding"] = "x" * 8000
    (a / "ledger.json").write_text(json.dumps(lg))
    monkeypatch.setattr(archive, "MAX_LEDGER", 6000)
    assert reasons(export(tmp_path, a, b, name="large.zip"))[0] == ["Its ledger is larger than 32 MB.", None]


def test_files_that_are_not_imported(tmp_path):
    a = handmade(tmp_path / "a")
    good = export(tmp_path, a, name="good.zip")

    def backup(change, name):
        return rebuild(good, tmp_path / name, change=lambda n, d: json.dumps(change(json.loads(d))).encode()
                       if n.endswith("/backup.json") else d)
    for change, message in ((lambda b: dict(b, kind="reading"), "for reading; it cannot be imported"),
                            (lambda b: dict(b, schema=3), "made by a newer Paperole"),
                            (lambda b: dict(b, app="Other"), "its backup.json cannot be read"),
                            (lambda b: dict(b, schema="2"), "its backup.json cannot be read")):
        with pytest.raises(EngineError, match=message):
            archive.check(backup(change, "x.zip"))
    for path, message in ((raw_zip(tmp_path / "none.zip", [("a/b.txt", b"x", None)]), "holds no review folder"),
                          (tmp_path / "missing.zip", "There is no file"), (a / "r1" / "final.pdf", "not a .zip")):
        with pytest.raises(EngineError, match=message):
            archive.check(path)
    with pytest.raises(EngineError, match="There is no paper"):
        archive.unpack(good, "students/Maya Chen/other", tmp_path)


def test_what_files_say_they_hold(tmp_path):
    """archive_info: backup.json alone, for the app's rotation of its automatic backups; a file that is not an export,
    or not there, or unsafe, is an error of its own, never the whole reply's."""
    a = handmade(tmp_path / "a")
    auto = export(tmp_path, a, name="auto.zip", scope="everything", kind="automatic",
                  made_by={"variant": "Paperole Dev", "install": "i-1", "app": None})
    plain = export(tmp_path, a, name="plain.zip")
    folders = raw_zip(tmp_path / "folders.zip", [("kelp/ledger.json", (a / "ledger.json").read_bytes(), None)])
    link = raw_zip(tmp_path / "link.zip", [("x/b", b"/etc", stat.S_IFLNK | 0o777)])
    reading = rebuild(plain, tmp_path / "reading.zip", change=lambda n, d: json.dumps(
        dict(json.loads(d), kind="reading")).encode() if n.endswith("/backup.json") else d)
    paths = [str(p) for p in (auto, plain, folders, link, reading, tmp_path / "gone.zip", a / "ledger.json")]
    files = api.METHODS["archive_info"]({"paths": paths}, quiet)["files"]
    assert [f["path"] for f in files] == paths
    b = files[0]["backup"]
    assert (b["kind"], b["scope"], b["made_by"]["variant"], b["made_by"]["install"]) == \
        ("automatic", "everything", "Paperole Dev", "i-1")
    assert [(p["id"], p["was_at"]) for p in b["papers"]] == [(ledger.paper_id(a, ledger.load(a)), str(a))]
    assert files[1]["backup"]["kind"] == "export"
    assert files[2] == {"path": paths[2], "backup": None}
    assert "a link" in files[3]["error"]
    assert "for reading" in files[4]["error"]
    assert "There is no file" in files[5]["error"] and "not a .zip" in files[6]["error"]
    with pytest.raises(EngineError, match="paths is a list"):
        api.METHODS["archive_info"]({"paths": "x.zip"}, quiet)


# --- other ways in --------------------------------------------------------------------------------------------

def test_a_schema_1_backup(tmp_path):
    """A backup made by the app's Back Up… before schema 2 (ditto: one folder, directory entries, papers/<folder>,
    app/tags.json, app/drafts/<hash>.json)."""
    a = handmade(tmp_path / "a")
    call("edit_paper", paper=str(a), title="Kelp: a study")
    top = "PaperCollab Backup 2026-10-20/"
    ref = {"path": str(a), "title": "Kelp: a study", "student": "Maya Chen", "finished": "2026-10-01",
           "keyPage": {"round": 1, "page": 0}}
    entries = [(top, b"", stat.S_IFDIR | 0o755),
               (top + "backup.json", json.dumps({"schema": 1, "app": "PaperCollab", "created": "2026-10-20T10:00:00Z",
                                                 "papers": [{"folder": "papers/kelp", "ref": ref}], "tags": True,
                                                 "drafts": 1}).encode(), None),
               (top + "app/tags.json", b'{"schema": 1, "tags": []}', None),
               (top + "app/drafts/0a1b.json", json.dumps({"paper": str(a), "rounds": {"2": {"R1-01": "x"}}}).encode(),
                None)]
    for rel in sorted(files(a)):
        entries.append((top + "papers/kelp/" + rel, (a / rel).read_bytes(), stat.S_IFREG | stat.S_IMODE(
            (a / rel).stat().st_mode)))
    z = raw_zip(tmp_path / "old.zip", entries)
    before, ids = files(a), listed(a)
    shutil.rmtree(a)
    r = archive.check(z, ids)
    assert (r["kind"], r["schema"], r["intact"], r["checked"], r["tags"]) == ("backup", 1, True, False,
                                                                              {"schema": 1, "tags": []})
    (p,) = r["papers"]
    assert (p["folder"], p["status"], p["listed"], p["draft"]["rounds"]) == ("papers/kelp", "put_back", str(a),
                                                                              {"2": {"R1-01": "x"}})
    assert p["facts"] == {"finished": "2026-10-01", "buckets": None, "key_page": {"round": 1, "page": 0}}
    back = archive.unpack(z, "papers/kelp", a.parent)
    assert back["path"] == str(a) and files(a) == before


def test_a_review_folder_zipped_in_finder_or_on_disk(tmp_path):
    a = handmade(tmp_path / "a")
    subprocess.run(["xattr", "-w", "com.paperole.test", "1", str(a / "ledger.json")], check=True)
    z = tmp_path / "kelp.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(a), str(z)], check=True)
    with zipfile.ZipFile(z) as f:
        assert any(n.startswith("__MACOSX/") for n in f.namelist())  # as Finder's Compress leaves it
    r = archive.check(z, listed(a))
    assert (r["kind"], r["zip"], r["intact"], statuses(r)) == ("folders", True, True, {"kelp": "same"})
    back = archive.unpack(z, "kelp", tmp_path)
    assert files(back["path"]) == files(a)

    # the folder itself, listed where it is; then found in a folder up to three levels down
    r = archive.check(a, listed(a))
    (p,) = r["papers"]
    assert (r["kind"], r["zip"], p["in_place"], p["folder"], p["status"]) == ("folders", False, True, str(a), "same")
    root = tmp_path / "search"
    for where in ("one", "x/two", "x/y/three", "x/y/z/four", ".hidden/five", "Replaced by Import/six"):
        shutil.copytree(a, root / where)
    r = archive.check(root, listed(a))
    assert [Path(p["folder"]).relative_to(root).as_posix() for p in r["papers"]] == ["one", "x/two", "x/y/three"]
    assert [p["status"] for p in r["papers"]] == ["same", "different_paper", "different_paper"]
    with pytest.raises(EngineError, match="no review folder"):
        archive.check(tmp_path / "search" / "x" / "y" / "z" / "four" / "r1")
    with pytest.raises(EngineError, match="There is no file"):
        archive.unpack(root, "one", tmp_path)


def test_a_folder_on_disk_is_checked_once_and_can_be_cancelled(tmp_path, monkeypatch):
    """A review folder listed where it is: its check is the copy's and yours at once (check.paper once, not twice);
    `cancel` stops between folders."""
    a, b = handmade(tmp_path / "Reviews" / "a"), handmade(tmp_path / "Reviews" / "b")
    real, checked = archive.checks.paper, []
    monkeypatch.setattr(archive.checks, "paper", lambda p: checked.append(Path(p).parent.name) or real(p))
    r = archive.check(tmp_path / "Reviews", listed(a, b))
    assert [(p["status"], p["yours_problems"]) for p in r["papers"]] == [("same", []), ("same", [])]
    assert checked == ["a", "b"]
    asked = []
    with pytest.raises(EngineError, match="Cancelled"):
        archive.check(tmp_path / "Reviews", listed(a, b), cancelled=lambda: asked.append(1) or len(asked) > 1)
    assert checked == ["a", "b", "a"]


# --- swap_in --------------------------------------------------------------------------------------------------

def test_swap_in_and_its_rollback(tmp_path, monkeypatch):
    a = handmade(tmp_path / "Reviews")
    file = export(tmp_path, a)
    call("edit_paper", paper=str(a), title="Mine")
    mine = files(a)
    folder = archive.check(file)["papers"][0]["folder"]
    incoming = Path(archive.unpack(file, folder, a.parent)["path"])
    theirs = files(incoming)

    renames, real = [], os.rename

    def failing(src, dst):
        renames.append((src, dst))
        if len(renames) == 2:
            raise OSError(28, "No space left on device")
        real(src, dst)
    monkeypatch.setattr(archive.os, "rename", failing)
    with pytest.raises(OSError):
        archive.swap_in(incoming, a)
    monkeypatch.undo()
    assert len(renames) == 3 and files(a) == mine and files(incoming) == theirs
    assert sorted(os.listdir(a.parent)) == ["kelp", "kelp 2"]  # Replaced by Import made and removed again

    out = archive.swap_in(incoming, a)
    assert out == {"path": str(a), "replaced": str(a.parent / "Replaced by Import" / "kelp {}".format(
        __import__("datetime").date.today().isoformat()))}
    assert files(a) == theirs and files(out["replaced"]) == mine and not incoming.exists()
    again = Path(archive.unpack(file, folder, a.parent)["path"])
    assert archive.swap_in(again, a)["replaced"].endswith(" 2")
    for x, y, message in ((a, a, "two folders"), (a / "r1", a, "not a Paperole paper folder"),
                          (a, tmp_path / "gone", "There is no folder")):
        with pytest.raises(EngineError, match=message):
            archive.swap_in(x, y)


def test_use_this_copy_onto_a_folder_whose_ledger_is_gone(tmp_path):
    """Restore, or Use This Copy, is how a folder that lost its ledger.json is put right: the copy goes in its place
    and the folder as it was is kept in Replaced by Import (no unlisted "kelp 2" left beside it)."""
    a = handmade(tmp_path / "Reviews")
    file = export(tmp_path, a)
    incoming = Path(archive.unpack(file, archive.check(file)["papers"][0]["folder"], a.parent)["path"])
    theirs = files(incoming)
    (a / "ledger.json").unlink()
    mine = files(a)
    out = archive.swap_in(incoming, a)
    assert files(a) == theirs and ledger.load(a)["paper"]["title"] == "Kelp forests"
    assert files(out["replaced"]) == mine and sorted(os.listdir(a.parent)) == ["Replaced by Import", "kelp"]


def test_unpack_reads_only_its_papers_files(tmp_path, monkeypatch):
    """Restoring N papers from one file is N passes over their own files, not over the whole file each time: unpack
    hashes only the paper's entries (the list of checksums is still checked against its pin)."""
    a, b = handmade(tmp_path / "a"), handmade(tmp_path / "b")
    good = export(tmp_path, a, b, name="good.zip")
    folder_a, folder_b = (p["folder"] for p in archive.check(good)["papers"])
    read, digest = [], archive._Zip.digest
    monkeypatch.setattr(archive._Zip, "digest", lambda z, name, *args, **kw: read.append(name) or
                        digest(z, name, *args, **kw))
    (tmp_path / "out").mkdir()
    back = archive.unpack(good, folder_a, tmp_path / "out")
    assert back["problems"] == [] and files(back["path"]) == files(a)
    assert read and not any(folder_b in n for n in read) and any(n.endswith(archive.MANIFEST) for n in read)
    pinned = rebuild(good, tmp_path / "pinned.zip", change=lambda n, d: d + b"\n" if n.endswith(archive.MANIFEST) else d)
    with pytest.raises(EngineError, match="list of checksums is damaged"):
        archive.unpack(pinned, folder_a, tmp_path / "out")
    missing = rebuild(good, tmp_path / "missing.zip", drop={"good/" + folder_b + "/r2/src/main.tex"})
    assert archive.unpack(missing, folder_a, tmp_path / "out")["problems"] == []  # the other paper's damage
    with pytest.raises(EngineError, match="missing from this file: r2/src/main.tex"):
        archive.unpack(missing, folder_b, tmp_path / "out")


# --- cancel and free space ------------------------------------------------------------------------------------

def test_cancel_and_low_free_space_leave_nothing(tmp_path, monkeypatch):
    a, b = handmade(tmp_path / "a"), handmade(tmp_path / "b")
    out = tmp_path / "out"
    out.mkdir()
    asked = []
    with pytest.raises(EngineError, match="Cancelled. Nothing was written."):
        archive.write([{"path": str(a)}, {"path": str(b)}], out / "x.zip",
                      cancelled=lambda: asked.append(1) or len(asked) > 3)
    assert os.listdir(out) == []
    good = export(tmp_path, a, b, name="good.zip")
    folder = archive.check(good)["papers"][0]["folder"]
    synced, fsync = [], os.fsync
    monkeypatch.setattr(archive.os, "fsync", lambda fd: synced.append(fd) or fsync(fd))
    with pytest.raises(EngineError, match="Cancelled"):  # once the first file is on the disk
        archive.unpack(good, folder, out, cancelled=lambda: bool(synced))
    monkeypatch.undo()
    assert synced and os.listdir(out) == []

    monkeypatch.setattr(archive, "free_space", lambda folder: 5 * 10 ** 9)  # 5 GB to spare, but not the files too
    for fn in (lambda: archive.write([{"path": str(a)}], out / "x.zip"), lambda: archive.unpack(good, folder, out)):
        with pytest.raises(EngineError, match="not enough free space.*about 5.0 GB free.*5.0 GB is"):
            fn()
    left = iter([10 ** 12] + [10 ** 9] * 100)  # enough to start, then below 2 GB
    monkeypatch.setattr(archive, "free_space", lambda folder: next(left))
    with pytest.raises(EngineError, match="less than 2 GB is free"):
        archive.write([{"path": str(a)}], out / "x.zip")
    assert os.listdir(out) == []


# --- RPC and CLI ----------------------------------------------------------------------------------------------

def _messages(eng, ids):
    """Read the engine's lines until each id has its reply: ({id: reply}, [(id, progress message)])."""
    replies, events = {}, []
    while set(replies) != set(ids):
        msg = json.loads(eng.proc.stdout.readline())
        if msg.get("event") == "progress":
            events.append((msg["id"], msg["message"]))
        else:
            replies[msg["id"]] = msg
    return replies, events


@needs_tex
def test_rpc_with_cancel(paper, tmp_path):
    from conftest import FIXTURE, Engine
    a = handmade(tmp_path / "a")
    eng = Engine()
    try:
        # an ingest runs (seconds); the export waits behind it and is cancelled while it waits
        for rid, method, params in ((1, "ingest", {"paper": str(paper), "source": str(FIXTURE / "v1")}),
                                    (2, "archive_write", {"papers": [{"path": str(a)}], "dest": str(tmp_path / "x.zip")}),
                                    (3, "cancel", {"id": 2}), (4, "cancel", {"id": 99})):
            eng.send(json.dumps({"id": rid, "method": method, "params": params}))
        replies, events = _messages(eng, [1, 2, 3, 4])
        assert replies[3] == {"id": 3, "result": {"cancelling": True}}
        assert replies[4] == {"id": 4, "result": {"cancelling": False}}
        assert "state" in replies[1]["result"]
        assert replies[2] == {"id": 2, "error": {"message": "Cancelled. Nothing was written."}}
        assert not (tmp_path / "x.zip").exists() and not [x for x in os.listdir(tmp_path) if x.startswith(".")]

        eng.send(json.dumps({"id": 5, "method": "archive_write", "params": {
            "papers": [{"path": str(a)}], "dest": str(tmp_path / "x.zip"), "tags": {"schema": 1, "tags": []}}}))
        replies, events = _messages(eng, [5])
        assert replies[5]["result"]["backup"]["papers"][0]["was_at"] == str(a)
        assert events == [(5, "Writing “Kelp forests” (1 of 1)…"), (5, "Checking…")]
        eng.send(json.dumps({"id": 6, "method": "archive_check", "params": {"path": str(tmp_path / "x.zip"),
                                                                             "papers": listed(a)}}))
        assert _messages(eng, [6])[0][6]["result"]["papers"][0]["status"] == "same"
    finally:
        code, rest = eng.close()
    assert code == 0 and rest == ""


def test_cli(tmp_path, capsys):
    a = handmade(tmp_path / "a")
    assert cli.main(["archive-write", str(tmp_path / "x.zip"), str(a), "--scope", "everything"]) == 0
    assert json.loads(capsys.readouterr().out)["backup"]["scope"] == "everything"
    assert cli.main(["archive-check", str(tmp_path / "x.zip"), "--listed", str(a)]) == 0
    (p,) = json.loads(capsys.readouterr().out)["papers"]
    assert p["status"] == "same"
    dest = tmp_path / "dest"
    dest.mkdir()
    assert cli.main(["archive-unpack", str(tmp_path / "x.zip"), p["folder"], str(dest), "--copy"]) == 0
    back = json.loads(capsys.readouterr().out)["path"]
    assert ledger.load(back)["paper"]["title"] == "Kelp forests (copy)"
    assert cli.main(["swap-in", back, str(a)]) == 0
    assert ledger.load(a)["paper"]["title"] == "Kelp forests (copy)"
    capsys.readouterr()
    assert cli.main(["archive-check", str(tmp_path / "nothing.zip")]) == 1
    assert "There is no file" in capsys.readouterr().err
    assert api.METHODS["archive_check"]({"path": str(tmp_path / "x.zip")}, quiet)["papers"][0]["status"] == "new"
    with pytest.raises(EngineError, match="papers is a list"):
        api.METHODS["archive_check"]({"path": str(tmp_path / "x.zip"), "papers": ["a"]}, quiet)
