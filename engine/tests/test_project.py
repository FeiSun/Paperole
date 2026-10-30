"""Snapshot, main/engine detection, build status, and replacing an open round."""
import datetime
import os
import shutil
import stat
import subprocess
import unicodedata
import zipfile

import pymupdf
import pytest

from conftest import FIXTURE, quiet, select
from paperole import EngineError, api, project

DOC = "\\documentclass{{article}}\n\\begin{{document}}\n{}\n\\end{{document}}\n"


def files(folder):
    return {p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file()}


def nfc(name):
    return unicodedata.normalize("NFC", name)


def nfd(name):
    return unicodedata.normalize("NFD", name)


def test_snapshot_zip(tmp_path):
    archive = tmp_path / "sub.zip"
    with zipfile.ZipFile(archive, "w") as z:
        for name in ("paper/main.tex", "paper/sections/a.tex", "paper/refs.bbl", "paper/fig.pdf", "paper/main.aux",
                     "paper/main.synctex.gz", "paper/.git/config", "paper/.DS_Store", "__MACOSX/paper/._main.tex"):
            z.writestr(name, "x")
    assert project.snapshot(archive, tmp_path / "src") == []
    assert files(tmp_path / "src") == {"main.tex", "sections/a.tex", "refs.bbl", "fig.pdf"}
    assert all(stat.S_IMODE(p.stat().st_mode) == 0o444 for p in (tmp_path / "src").rglob("*") if p.is_file())

    for bad in ("../evil.tex", "/etc/evil.tex"):
        with zipfile.ZipFile(tmp_path / "bad.zip", "w") as z:
            z.writestr("main.tex", "x")
            z.writestr(bad, "x")
        with pytest.raises(EngineError, match="unsafe path"):
            project.snapshot(tmp_path / "bad.zip", tmp_path / "bad")
        assert not (tmp_path / "bad").exists()


def test_snapshot_folder(tmp_path):
    src = tmp_path / "student"
    (src / "figs").mkdir(parents=True)
    (src / "main.tex").write_text("x")
    (src / "figs" / "a.png").write_bytes(b"png")
    (src / ".hidden.tex").write_text("x")
    (src / "main.log").write_text("x")
    os.symlink(src / "main.tex", src / "link.tex")
    warnings = project.snapshot(src, tmp_path / "copy")
    assert warnings == ["Skipped the symbolic link link.tex"]
    assert files(tmp_path / "copy") == {"main.tex", "figs/a.png"}
    with pytest.raises(EngineError, match="already exists"):
        project.snapshot(src, tmp_path / "copy")
    with pytest.raises(EngineError, match="inside the student's source"):
        project.snapshot(src, src / "paper" / "r1" / "src")


def test_detect(tmp_path):
    (tmp_path / "a.tex").write_text(DOC.format("A"))
    (tmp_path / "b.tex").write_text("% !TEX program = xelatex\n" + DOC.format("B"))
    (tmp_path / "c.tex").write_text("% \\documentclass{article}\n\\section{C}\n")
    with pytest.raises(EngineError, match="a.tex, b.tex"):
        project.detect(tmp_path)
    assert project.detect(tmp_path, "b.tex") == {"main": "b.tex", "engine": "xelatex"}
    (tmp_path / "main.tex").write_text(DOC.replace("\\begin", "\\usepackage{{fontspec}}\n\\begin").format("M"))
    assert project.detect(tmp_path) == {"main": "main.tex", "engine": "xelatex"}
    with pytest.raises(EngineError, match="not in the source"):
        project.detect(tmp_path, "nope.tex")
    (tmp_path / "paper").mkdir()  # latexmk runs in src, so main's \input names would not be found (E1-14)
    (tmp_path / "paper" / "main.tex").write_text(DOC.format("P"))
    with pytest.raises(EngineError, match="not in a folder: paper/main.tex"):
        project.detect(tmp_path, "paper/main.tex")


def test_detect_reads_the_files_of_the_preamble(tmp_path):
    """fontspec loaded from a file that main's preamble reads, two levels deep, picks xelatex (E1-09)."""
    (tmp_path / "setup").mkdir()
    (tmp_path / "main.tex").write_text(DOC.replace("\\begin", "\\input{{setup/preamble}}\n% \\input{{off}}\n\\begin")
                                       .format("\\input{body}"))
    (tmp_path / "setup" / "preamble.tex").write_text("\\usepackage{amsmath}\n\\input{setup/fonts.tex}\n")
    (tmp_path / "setup" / "fonts.tex").write_text("% \\usepackage{fontspec}\n")
    (tmp_path / "off.tex").write_text("\\usepackage{fontspec}\n")  # commented out in main
    (tmp_path / "body.tex").write_text("Text.\n")
    assert project.detect(tmp_path) == {"main": "main.tex", "engine": "pdflatex"}
    (tmp_path / "setup" / "fonts.tex").write_text("\\usepackage[no-math]{fontspec}\n")
    assert project.detect(tmp_path) == {"main": "main.tex", "engine": "xelatex"}


def test_snapshot_zip_names(tmp_path):
    """Finder's Compress and Info-ZIP write UTF-8 names without the UTF-8 flag, so zipfile reads them as cp437 (E1-03);
    a name from Finder may be NFD (E2E-02); some Windows and Java zippers end a folder's name with "\\" (E1-15).
    The snapshot has the names as written, in NFC, and still unwraps the one top-level folder."""
    archive = tmp_path / "finder.zip"
    unflagged = ["Maya 论文/main.tex", nfd("Maya 论文/sections/méthode.tex")]
    stand_in = [str(i).ljust(len(name.encode()), "#") for i, name in enumerate(unflagged)]  # ASCII, same length
    with zipfile.ZipFile(archive, "w") as z:
        for name in stand_in:
            z.writestr(name, "x")
        z.writestr(nfd("Maya 论文/sections/naïve.tex"), "x")  # flagged as UTF-8, but NFD
        z.writestr("Maya 论文\\figs\\", "")
        z.writestr("Maya 论文\\figs\\a.png", "png")
    data = archive.read_bytes()
    for name, ascii_name in zip(unflagged, stand_in):
        data = data.replace(ascii_name.encode(), name.encode())
    archive.write_bytes(data)
    infos = zipfile.ZipFile(archive).infolist()
    assert infos[0].filename == "Maya Φ«║µûç/main.tex" and not infos[0].flag_bits & 0x800
    assert project.snapshot(archive, tmp_path / "src") == []
    assert files(tmp_path / "src") == {"main.tex", nfc("sections/méthode.tex"), nfc("sections/naïve.tex"), "figs/a.png"}


@pytest.mark.skipif(not (shutil.which("ditto") and shutil.which("zip")), reason="needs macOS ditto and Info-ZIP zip")
def test_finder_and_info_zip_zips_build(tmp_path):
    """A zip from Finder's Compress (ditto) or from Info-ZIP's zip, of a folder with a Chinese name and an NFD accented
    file name, builds (E2E-01: "File `sections/m├⌐thode.tex' not found"), and its snapshot names are in NFC (E2E-02).
    The README that the zip holds beside the folder is skipped, and the folder still unwrapped (E2E-06)."""
    top = tmp_path / "Maya 论文"
    (top / "sections").mkdir(parents=True)
    (top / "main.tex").write_text(DOC.format("\\input{sections/méthode}"))
    (top / "sections" / nfd("méthode.tex")).write_text("Notre méthode.\n")
    (tmp_path / "README.txt").write_text("Round 2.\n")
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(top), str(tmp_path / "finder.zip")], check=True)
    subprocess.run(["zip", "-qr", "info.zip", top.name, "README.txt"], cwd=tmp_path, check=True)
    for archive, skipped in (("finder.zip", []), ("info.zip", ["Skipped README.txt beside the source folder"])):
        paper, events = tmp_path / archive.replace(".", "-"), []
        api.new({"paper": str(paper), "title": "T", "student": "S"}, quiet)
        build = api.ingest({"paper": str(paper), "source": str(tmp_path / archive)}, events.append)["state"]["round"]["build"]
        assert build["status"] == "ok", build
        assert files(paper / "r1" / "src") == {"main.tex", nfc("sections/méthode.tex")}
        assert [e for e in events if e.startswith("Skipped")] == skipped


def test_snapshot_folder_names_in_nfc(tmp_path):
    """Folder and file names that Finder or a Cocoa editor wrote in NFD are copied in NFC, as \\input names them
    (E2E-02)."""
    src = tmp_path / "student"
    (src / nfd("Données")).mkdir(parents=True)
    (src / "main.tex").write_text("x")
    (src / nfd("Données") / nfd("méthode.tex")).write_text("x")
    assert project.snapshot(src, tmp_path / "copy") == []
    assert files(tmp_path / "copy") == {"main.tex", nfc("Données/méthode.tex")}


def test_snapshot_zip_with_files_beside_the_folder(tmp_path):
    """A zip of the student's folder plus a README or a PDF beside it unwraps the folder and skips those files, also
    for received (E1-14). A .tex file beside the folder may be main, so then nothing is unwrapped."""
    archive = tmp_path / "sub.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr(zipfile.ZipInfo("paper/main.tex", (2026, 10, 1, 9, 0, 0)), "x")
        z.writestr(zipfile.ZipInfo("paper/sections/a.tex", (2026, 10, 1, 8, 0, 0)), "x")
        z.writestr(zipfile.ZipInfo("README.txt", (2026, 10, 20, 9, 0, 0)), "x")
        z.writestr(zipfile.ZipInfo("paper.pdf", (2026, 10, 20, 9, 0, 0)), "x")
    assert project.snapshot(archive, tmp_path / "src") == ["Skipped README.txt beside the source folder",
                                                           "Skipped paper.pdf beside the source folder"]
    assert files(tmp_path / "src") == {"main.tex", "sections/a.tex"}
    assert project.received(archive) == datetime.datetime(2026, 10, 1, 9, 0).astimezone().isoformat(timespec="seconds")
    with zipfile.ZipFile(tmp_path / "two.zip", "w") as z:
        z.writestr("paper/main.tex", "x")
        z.writestr("notes.tex", "x")
    assert project.snapshot(tmp_path / "two.zip", tmp_path / "two") == []
    assert files(tmp_path / "two") == {"paper/main.tex", "notes.tex"}


def test_an_error_keeps_its_continuation_lines(tmp_path):
    """A package error's "(fontspec)   …" lines are part of its message, as a warning's are (E1-10: the message ended
    with "requires either XeTeX or")."""
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "main.tex").write_text(DOC.replace("\\begin", "\\usepackage{{fontspec}}\n\\begin").format("Hi"))
    build = project.compile(tmp_path / "src", tmp_path / "build", "main.tex", "pdflatex")
    [err] = build["errors"]
    assert "requires either XeTeX or LuaTeX. You must change your typesetting engine" in err["message"], err


def test_a_build_with_errors_resolves_its_references(tmp_path):
    """latexmk -f stops after a LaTeX run with an error, before the runs that resolve \\cite and \\ref, so compile
    calls it once more with -g (E2E-03: every citation printed [?], and final.pdf listed them as undefined). Checked
    with thebibliography (the fixture paper without its figure) and with BibTeX."""
    fixture, bib = tmp_path / "fixture", tmp_path / "bib"
    shutil.copytree(FIXTURE / "v1", fixture)
    (fixture / "figures" / "coldstart.png").unlink()
    bib.mkdir()
    (bib / "refs.bib").write_text("@book{knuth84, author={Donald Knuth}, title={The TeXbook}, publisher={AW}, "
                                  "year={1984}}\n")
    for i, (src, figure) in enumerate(((fixture, None), (bib, "\\includegraphics{nofig}"), (bib, ""))):
        if figure is not None:
            (bib / "main.tex").write_text(DOC.replace("\\begin", "\\usepackage{{graphicx}}\n\\begin").format(
                "\\section{One}\\label{one}\nSee~\\cite{knuth84} and Section~\\ref{two}.\n" + figure
                + "\n\\section{Two}\\label{two}\n\\bibliographystyle{plain}\n\\bibliography{refs}"))
        events = []
        build = project.compile(src, tmp_path / "build{}".format(i), "main.tex", "pdflatex", events.append)
        text = "".join(page.get_text() for page in pymupdf.open(build["pdf"]))
        assert "[?]" not in text and "??" not in text and not any("undefined" in w for w in build["warnings"]), i
        if figure == "":  # no error: latexmk is called once
            assert build["status"] == "ok" and events == ["Compiling with pdflatex…"]
        else:
            [err] = build["errors"]
            assert build["status"] == "errors" and "not found" in err["message"]
            assert events == ["Compiling with pdflatex…", "Compiling again after LaTeX errors…"]


def test_include_in_subfolder_from_zip(tmp_path):
    archive = tmp_path / "submission.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("thesis/main.tex", DOC.format("\\include{chap/a}"))
        z.writestr("thesis/chap/a.tex", "Chapter text.\n")
    paper = tmp_path / "paper"
    api.new({"paper": str(paper), "title": "T", "student": "S"}, quiet)
    build = api.ingest({"paper": str(paper), "source": str(archive)}, quiet)["state"]["round"]["build"]
    assert build["status"] == "ok", build
    assert files(paper / "r1" / "src") == {"main.tex", "chap/a.tex"}


def test_build_status_and_replacing_a_round(tmp_path):
    paper, bad, broken = tmp_path / "paper", tmp_path / "bad", tmp_path / "broken"
    bad.mkdir()
    (bad / "main.tex").write_text(DOC.format("See Section~\\ref{nope}. \\undefinedmacro Hello."))
    broken.mkdir()
    (broken / "main.tex").write_text(DOC.replace("article", "nosuchclassxyz").format("Hi"))
    (tmp_path / "busy").mkdir()
    (tmp_path / "busy" / "notes.txt").write_text("x")
    with pytest.raises(EngineError, match="not empty"):
        api.new({"paper": str(tmp_path / "busy"), "title": "T", "student": "S"}, quiet)
    api.new({"paper": str(paper), "title": "T", "student": "S"}, quiet)

    # A build with LaTeX errors still has a PDF and can be reviewed.
    build = api.ingest({"paper": str(paper), "source": str(bad)}, quiet)["state"]["round"]["build"]
    assert build["status"] == "errors" and build["pages"] == 1 and os.path.exists(build["pdf"])
    assert build["errors"] == [{"file": "main.tex", "line": 3, "message": "Undefined control sequence."}]
    assert any("Reference `nope' on page 1 undefined" in w for w in build["warnings"])

    # Re-ingesting replaces an open round that has no comments or verdicts; a failed build has no PDF.
    state = api.ingest({"paper": str(paper), "source": str(broken)}, quiet)["state"]
    assert [r["n"] for r in state["rounds"]] == [1]
    build = state["round"]["build"]
    assert build["status"] == "failed" and build["pdf"] is None and build["errors"]
    assert "nosuchclassxyz" in build["log_tail"]
    assert state["comments"] == [] and state["changes"] == []
    assert state["summary"] == {"round": 1, "closed": False, "status": "failed", "to_judge": 0, "to_check": 0,
                                "closed_at": None, "resumable": False}
    with pytest.raises(EngineError, match="build failed"):
        api.comment({"paper": str(paper), "page": 0, "rects": [[1, 1, 2, 2]], "note": "x"}, quiet)

    state = api.ingest({"paper": str(paper), "source": str(FIXTURE / "v1")}, quiet)["state"]
    assert [r["n"] for r in state["rounds"]] == [1] and state["round"]["build"]["status"] == "ok"
    assert sorted(os.listdir(paper / "r1" / "src")) == ["figures", "main.tex", "sections"]
    pdf = state["round"]["build"]["pdf"]
    # a failed re-ingest leaves the open round as it was
    with pytest.raises(EngineError, match="not in the source"):
        api.ingest({"paper": str(paper), "source": str(FIXTURE / "v1"), "main": "nope.tex"}, quiet)
    assert os.path.exists(pdf) and sorted(os.listdir(paper)) == [".history", ".lock", "ledger.json", "r1"]
    assert api.state_({"paper": str(paper)}, quiet)["state"]["round"]["build"]["status"] == "ok"
    api.comment({"paper": str(paper), "page": 0, "rects": select(pdf, 0, "simple keep-alive policy:"), "note": "x"}, quiet)
    with pytest.raises(EngineError, match="Finish it"):
        api.ingest({"paper": str(paper), "source": str(FIXTURE / "v2")}, quiet)


def test_a_killed_reingest_is_undone(paper):
    """ingest keeps the round it replaces in rN.old until the new one is built. If the engine is killed meanwhile,
    the next call puts that round back, so the ledger and the folder agree again. What the ledger does not describe
    (the half-built round, an rN.old of a round it does not have) goes to .orphans, never deleted."""
    r1, aside = paper / "r1", paper / "r1.old"
    good = (r1 / "build" / "main.pdf").read_bytes()
    r1.rename(aside)  # what ingest does first when it replaces round 1 …
    (r1 / "build").mkdir(parents=True)
    (r1 / "build" / "main.pdf").write_bytes(good[:100])  # … and a half-built new round when it is killed
    (paper / "r2.old").mkdir()  # left from a killed ingest of a round the ledger does not have
    state = api.state_({"paper": str(paper)}, quiet)["state"]
    assert sorted(os.listdir(paper)) == [".history", ".lock", ".orphans", "ledger.json", "r1"]
    assert sorted(p.name.split("-")[0] for p in (paper / ".orphans").iterdir()) == ["r1", "r2"]
    assert (r1 / "build" / "main.pdf").read_bytes() == good and state["round"]["build"]["pages"] == 4
    assert files(r1 / "src") == files(FIXTURE / "v1")
    r1.rename(aside)
    r1.mkdir()
    pdf = str(r1 / "build" / "main.pdf")
    r = api.comment({"paper": str(paper), "page": 0, "rects": select(str(aside / "build" / "main.pdf"), 0, "simple"),
                     "text": "simple", "note": "x"}, quiet)  # any locked call recovers first
    assert r["id"] == "R1-01" and r["state"]["round"]["build"]["pdf"] == pdf and not aside.exists()
