"""The export of a paper's comments, round by round (export.py; CONTRACT.md amendment "Export"), on the synthetic kelp
paper of test_overview (four rounds, sections merged, renamed and removed): each comment once, each round it is in, its
section as that round prints it, page, place, the student's response and the answer, the ledger's verdicts and their
notes, the student's note, tags and their names; a folder that cannot be read; RPC and CLI; nothing written."""
import hashlib
import json
import shutil

from conftest import quiet
from paperole import api, cli
from test_overview import kelp, pytestmark  # noqa: F401  (the four-round paper; skipped without latexmk)


def _digest(folder):
    """A hash of every file's path and bytes under folder: the export writes nothing."""
    h = hashlib.sha256()
    for p in sorted(folder.rglob("*")):
        if p.is_file():
            h.update(str(p.relative_to(folder)).encode())
            h.update(p.read_bytes())
    return h.hexdigest()


def test_every_comment_round_by_round(kelp):
    paper, ids = kelp
    before = _digest(paper)
    out = api.export_comments({"papers": [str(paper)]}, quiet)
    assert _digest(paper) == before and "state" not in out
    (entry,) = out["papers"]
    assert entry["path"] == str(paper) and entry["paper"] == {"title": "Kelp drift", "student": "Mei Lin"}
    rows = {c["id"]: c for c in entry["comments"]}
    assert list(rows) == sorted(rows) and set(rows) == set(ids.values())
    shore = rows[ids["shore"]]
    assert (shore["created_round"], shore["kind"], shore["note"], shore["tags"]) == (1, "highlight", "Which beach?", [])
    assert [(r["round"], r["place"], r["response"], r["answer"], r["verdict"]) for r in shore["rounds"]] == [
        (1, "placed", "new", None, None), (2, "placed", "untouched", "left_open", None),
        (3, "placed", "waiting", "kept", "wontfix")]
    xerus = rows[ids["xerus"]]
    assert [(r["verdict"], r["verdict_note"]) for r in xerus["rounds"]] == [
        (None, ""), ("reopened", "Say more."), ("verified", "")]
    for c in rows.values():
        for r in c["rounds"]:
            assert r["state"] in ("new", "unchanged", "changed", "moved", "gone", "orphan")
            assert r["student_note"] is None
            if r["place"] == "placed":
                assert isinstance(r["page"], int) and r["section"] and r["text"]
    # the section as each round prints it: R2-01 was written under "Methods", renamed in round 3
    mesh = rows[ids["mesh"]]["rounds"]
    assert "Methods" in mesh[0]["section"] and mesh[0]["section"] != mesh[1]["section"]
    # the appendix's comment, gone in round 4
    assert rows[ids["extra"]]["rounds"][-1]["place"] == "gone"


def test_tags_student_notes_errors_and_cli(kelp, tmp_path, capsys):
    paper, ids = kelp
    copy = tmp_path / "copy"
    shutil.copytree(paper, copy)
    api.tag({"paper": str(copy), "id": ids["intro"], "tags": ["grammar", "u-0a1b2c3d"],
             "names": {"u-0a1b2c3d": "Tone"}}, quiet)
    lg = json.loads((copy / "ledger.json").read_text(encoding="utf-8"))
    c = next(c for c in lg["comments"] if c["id"] == ids["intro"])
    c["rounds"]["2"]["student_note"] = {"text": "Cut to one sentence.", "file": "main.tex", "line": 9}
    (copy / "ledger.json").write_text(json.dumps(lg, ensure_ascii=False), encoding="utf-8")
    out = api.export_comments({"papers": [str(copy), str(tmp_path / "missing")]}, quiet)
    good, bad = out["papers"]
    intro = next(c for c in good["comments"] if c["id"] == ids["intro"])
    assert intro["tags"] == ["grammar", "u-0a1b2c3d"] and good["tag_names"] == {"u-0a1b2c3d": "Tone"}
    assert [r["student_note"] for r in intro["rounds"]] == [None, "Cut to one sentence."]
    assert bad["path"] == str(tmp_path / "missing") and bad["error"] and "comments" not in bad
    try:
        api.export_comments({"papers": "nope"}, quiet)
        raise AssertionError("refused")
    except api.EngineError as e:
        assert "list of paper folders" in str(e)
    assert cli.main(["export", str(copy)]) == 0
    printed = json.loads(capsys.readouterr().out)
    assert printed["papers"][0]["comments"] == good["comments"]
