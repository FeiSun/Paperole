"""Shell escape per paper (CONTRACT.md amendment "Shell escape per paper"): off by default; the advisor's choice,
given to ingest or edit_paper, remembered for the paper; asked for by a package (needs_shell_escape, derived, so also
for a round built before it); never brought in from a file. Synthetic documents in tests/fixtures/shell-escape, built
in temporary folders: minted (pygmentize through \\write18, as a student's paper: "preamble.tex:28: Package minted
Error: You must invoke LaTeX with the -shell-escape flag"), a \\write18 that leaves a file, and a student's
latexmkrc; and the fixture paper, for where comments land."""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pymupdf
import pytest

from conftest import FIXTURE, select
from paperole import EngineError, anchor, api, archive, cli, history, ledger, project
from test_data_safety import PATH, call, handmade

pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "shell-escape"
MINTED, WRITE18 = FIXTURES / "minted", FIXTURES / "write18"
IMAKEIDX, MULTIBIB = FIXTURES / "imakeidx", FIXTURES / "multibib"
# an app launched from the Finder has no more on its PATH (the engine adds TeX's folder, and with shell escape the
# folder of its own Python, where pygmentize is)
GUI_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
PYGMENTIZE = shutil.which("pygmentize", path=GUI_PATH + os.pathsep + os.path.dirname(sys.executable))
MINTED_ERROR = "Package minted Error: You must invoke LaTeX with the -shell-escape flag."


def new(tmp_path, name="paper"):
    paper = tmp_path / name
    call("new", paper=str(paper), title="Code listings", student="Ana Ruiz")
    return paper


def ingest(paper, source, **params):
    return call("ingest", paper=str(paper), source=str(source), **params)["state"]


def files(folder):
    return sorted(p.relative_to(folder).as_posix() for p in Path(folder).rglob("*") if p.is_file())


def ran(paper, n=1):
    """Whether the \\write18 of write18/main.tex ran: it writes ran.txt where LaTeX runs (the round's src)."""
    return (Path(paper) / "r{}".format(n) / "src" / "ran.txt").is_file()


def test_minted_without_shell_escape_asks_for_it(tmp_path, monkeypatch):
    """By default a round is built without shell escape, as always: minted stops in the preamble, the PDF still shows
    (the advisor's report), and the build asks for shell escape."""
    monkeypatch.setenv("PATH", GUI_PATH)
    paper = new(tmp_path)
    state = ingest(paper, MINTED)
    b = state["round"]["build"]
    assert (b["status"], b["shell_escape"], b["needs_shell_escape"]) == ("errors", False, True)
    assert b["pdf"] and b["pages"] == 1 and state["paper"]["shell_escape"] is False
    assert b["errors"][0]["file"] == "preamble.tex" and b["errors"][0]["message"].startswith(MINTED_ERROR)
    lg = ledger.load(paper)
    assert lg["rounds"][0]["build"]["shell_escape"] is False and "shell_escape" not in lg["paper"]


@pytest.mark.skipif(PYGMENTIZE is None, reason="minted runs pygmentize, which is neither beside the Python running "
                                               "the tests (Pygments comes with pytest) nor on an app's PATH")
def test_minted_with_shell_escape(tmp_path, monkeypatch):
    """With shell escape (given to ingest, so remembered for the paper) minted finds pygmentize beside the engine's
    Python, and its outputdir is the build folder: no errors, the listing printed, nothing new in the round's src."""
    monkeypatch.setenv("PATH", GUI_PATH)
    paper, events = new(tmp_path), []
    state = api.ingest({"paper": str(paper), "source": str(MINTED), "shell_escape": True}, events.append)["state"]
    b = state["round"]["build"]
    assert (b["status"], b["errors"], b["shell_escape"], b["needs_shell_escape"]) == ("ok", [], True, False)
    assert state["paper"]["shell_escape"] is True and "Compiling with pdflatex and shell escape…" in events
    assert "return 1" in pymupdf.open(b["pdf"])[0].get_text()
    assert files(paper / "r1" / "src") == files(MINTED)
    assert (paper / "r1" / "build" / "_minted-main").is_dir()
    lg = ledger.load(paper)
    assert lg["paper"]["shell_escape"] is True and lg["rounds"][0]["build"]["shell_escape"] is True


def test_the_choice_is_remembered_until_it_is_changed(tmp_path):
    """Given to ingest, the choice is stored on the paper and used for this build; an ingest without it uses the
    stored one; edit_paper changes it without a build (for the next round), either way. Anything but true or false
    is refused by both, changing nothing."""
    paper = new(tmp_path)
    b = ingest(paper, WRITE18)["round"]["build"]
    assert not ran(paper) and (b["status"], b["shell_escape"], b["needs_shell_escape"]) == ("ok", False, False)

    state = ingest(paper, WRITE18, shell_escape=True)  # the open round, without comments, built again
    assert ran(paper) and state["round"]["build"]["shell_escape"] and state["paper"]["shell_escape"]
    assert (paper / "r1" / "src" / "ran.txt").read_text().strip() == "ran"
    state = ingest(paper, WRITE18)
    assert ran(paper) and state["round"]["build"]["shell_escape"] and state["paper"]["shell_escape"]

    state = call("edit_paper", paper=str(paper), shell_escape=False)["state"]
    assert state["paper"]["shell_escape"] is False and "shell_escape" not in ledger.load(paper)["paper"]
    assert state["round"]["build"]["shell_escape"] is True  # the round stays as it was built
    state = ingest(paper, WRITE18)
    assert not ran(paper) and state["round"]["build"]["shell_escape"] is False
    raw = (paper / "ledger.json").read_bytes()
    call("edit_paper", paper=str(paper), shell_escape=False)  # off already: no new version
    assert (paper / "ledger.json").read_bytes() == raw

    assert call("edit_paper", paper=str(paper), shell_escape=True)["state"]["paper"]["shell_escape"] is True
    assert ingest(paper, WRITE18)["round"]["build"]["shell_escape"] and ran(paper)
    state = ingest(paper, WRITE18, shell_escape=False)
    assert not ran(paper) and state["paper"]["shell_escape"] is False

    raw = (paper / "ledger.json").read_bytes()
    for bad in ("yes", "true", 1, 0, None, [True], {}):
        with pytest.raises(EngineError, match="^shell_escape is true or false.$"):
            ingest(paper, WRITE18, shell_escape=bad)
        with pytest.raises(EngineError, match="^shell_escape is true or false.$"):
            call("edit_paper", paper=str(paper), title="Other", shell_escape=bad)
    assert (paper / "ledger.json").read_bytes() == raw and files(paper / "r1" / "src") == ["main.tex"]
    with pytest.raises(EngineError, match="Give the paper's title or the student's name."):
        call("edit_paper", paper=str(paper))


def test_a_latexmkrc_in_the_source_never_runs(tmp_path):
    """A student's latexmkrc is Perl that latexmk would run, and this one asks for shell escape too: -norc keeps it
    out, with shell escape off and on (latexmk without -norc runs it: it leaves rc-ran.txt, and lets ran.txt be
    written)."""
    source = tmp_path / "student"
    shutil.copytree(WRITE18, source)
    shutil.copyfile(FIXTURES / "latexmkrc", source / "latexmkrc")
    paper = new(tmp_path)
    assert ingest(paper, source)["round"]["build"]["status"] == "ok"
    assert files(paper / "r1" / "src") == ["latexmkrc", "main.tex"]
    assert ingest(paper, source, shell_escape=True)["round"]["build"]["status"] == "ok"
    assert files(paper / "r1" / "src") == ["latexmkrc", "main.tex", "ran.txt"]


def test_the_command_with_and_without_shell_escape(tmp_path, monkeypatch):
    """Without shell escape, latexmk's command and environment are exactly as before; with it, -shell-escape in place
    of -no-shell-escape, minted's outputdir as a pretex (only for a plain path) and the engine's Python folder last
    on PATH. The second call, after LaTeX errors (-g), runs the same command."""
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text("\\documentclass{article}\n\\begin{document}\nHi \\undefinedmacro.\n"
                                  "\\end{document}\n")
    calls, real = [], project._latexmk
    monkeypatch.setattr(project, "_latexmk", lambda cmd, cwd, env, timeout: calls.append((cmd, env))
                        or real(cmd, cwd, env, timeout))
    today = dict(os.environ, PATH=project.TEXBIN + os.pathsep + os.environ.get("PATH", ""), max_print_line="10000")

    def built(build, **kw):
        calls.clear()
        out = project.compile(src, build, "main.tex", "pdflatex", **kw)
        assert out["status"] == "errors" and len(calls) == 2
        (first, env), (second, env2) = calls
        assert second == first[:1] + ["-g"] + first[1:] and env2 == env
        return out, first, env
    out, cmd, env = built(tmp_path / "build")
    assert cmd == ["latexmk", "-norc", "-e", project.SAFE_AUX, "-pdf", "-f", "-synctex=1", "-interaction=nonstopmode",
                   "-file-line-error", "-no-shell-escape", "-outdir=" + str(tmp_path / "build"), "main.tex"]
    assert env == today and out["shell_escape"] is False
    out, cmd, env = built(tmp_path / "build2", shell_escape=True)
    assert cmd == ["latexmk", "-norc", "-e", project.SAFE_AUX, "-pdf", "-f", "-synctex=1", "-interaction=nonstopmode",
                   "-file-line-error", "-shell-escape", "-outdir=" + str(tmp_path / "build2"),
                   "-usepretex=\\PassOptionsToPackage{outputdir=../build2}{minted}", "main.tex"]
    assert env == dict(today, PATH=today["PATH"] + os.pathsep + os.path.dirname(sys.executable))
    assert out["shell_escape"] is True
    _, cmd, _ = built(tmp_path / "a b" / "build", shell_escape=True)  # "../a b/build": no pretex
    assert "-shell-escape" in cmd and not any(a.startswith("-usepretex") for a in cmd)


def test_a_main_file_latexmk_would_misread_is_refused(tmp_path):
    """latexmk reads an argument that starts with - as its own option, and puts the main file's name in "…" in a
    shell command line, where a backquote is not quoted: such a name is refused before anything runs, with or without
    shell escape."""
    src = tmp_path / "src"
    src.mkdir()
    for name in ("-draft.tex", "notes`v2`.tex"):
        (src / name).write_text("\\documentclass{article}\n\\begin{document}\nHi.\n\\end{document}\n")
        for escape in (False, True):
            with pytest.raises(EngineError, match="starts with - or has a `, which latexmk would misread"):
                project.compile(src, tmp_path / "build", name, "pdflatex", shell_escape=escape)
    assert not (tmp_path / "build").exists()


def test_a_folder_path_latexmk_would_run_is_refused(tmp_path):
    """latexmk puts the output folder in "…" in its shell command lines, where a $(…), a backquote, " and \\ are
    still read (a build folder under o$(touch MARK)o left MARK in src): a review folder's path with one is refused
    before anything runs, with or without shell escape; ingest leaves the paper as it was. New folders' names drop
    them (safe_name, as the app's DataFiles.name)."""
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.tex").write_text("\\documentclass{article}\n\\begin{document}\nHi.\n\\end{document}\n")
    refused = "which latexmk would run as part of a command. Rename the folder that has it."
    for name in ("o$(touch MARK)o", "b`touch MARK`b", 'q";touch MARK;"q', "s\\$(touch MARK)s"):
        for escape in (False, True):
            with pytest.raises(EngineError, match=refused):
                project.compile(src, tmp_path / name / "r1" / "build", "main.tex", "pdflatex", shell_escape=escape)
            with pytest.raises(EngineError, match=refused):
                project.compile(tmp_path / name / "r1" / "src", tmp_path / "build", "main.tex", "pdflatex",
                                shell_escape=escape)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["src"] and files(src) == ["main.tex"]

    paper = new(tmp_path, "Why `make` hangs")  # named from its title, as the app did before
    with pytest.raises(EngineError, match=refused):
        ingest(paper, WRITE18, shell_escape=True)
    assert ledger.load(paper)["rounds"] == [] and "shell_escape" not in ledger.load(paper)["paper"]
    assert not (paper / "r1").exists()
    assert archive.safe_name("Why `make` hangs", "Paper") == "Why make hangs"
    assert archive.safe_name('o$(touch MARK)o "q" a\\b', "Paper") == "o(touch MARK)o q ab"
    assert archive.safe_name("`$\"\\", "Paper") == "Paper"


def test_an_aux_name_the_student_chooses_never_reaches_the_shell(tmp_path):
    """latexmk builds its bibtex, biber and makeindex command lines from auxiliary-file names the student's LaTeX
    chooses (imakeidx's \\makeindex[name=…], multibib's \\newcites{…}), and runs them through /bin/sh with the name in
    "…", where a backquote still runs. These names exist only after TeX has run, so compile cannot screen them as it
    does the main file and the folder paths. The fixtures name an index and a set of citations x`date>MARK`x: were the
    name run through the shell, a file MARK would appear in the build (it did before SAFE_AUX). The engine's -e Perl
    makes latexmk run those three as argv lists, so with shell escape off nothing runs (CONTRACT §"Shell escape per
    paper", Security). (With shell escape on, imakeidx runs makeindex itself through \\write18, the trusted path the
    advisor turned on; multibib still goes through latexmk, which stays argv-safe.)"""
    for fixture in (IMAKEIDX, MULTIBIB):
        work = tmp_path / fixture.name
        shutil.copytree(fixture, work / "src")
        out = project.compile(work / "src", work / "build", "main.tex", "pdflatex")
        assert out["status"] == "ok", (fixture.name, out["errors"])
        assert not list(work.rglob("MARK")), fixture.name


def test_ordinary_bibtex_and_makeindex_still_build(tmp_path):
    """SAFE_AUX only changes how bibtex, biber and makeindex are launched (an argv list, not the shell); they still
    run. An ordinary bibliography resolves its citation, an index lists its term, and a bibliography inside an
    \\include'd chapter resolves too (the chapter's .aux reaches bibtex through latexmk)."""
    bib = "@article{kelp, author={A. Ruiz}, title={On Kelp}, journal={J. Mar.}, year={2020}}\n"

    def built(name, sources):
        src = tmp_path / name / "src"
        src.mkdir(parents=True)
        for rel, text in sources.items():
            (src / rel).parent.mkdir(parents=True, exist_ok=True)
            (src / rel).write_text(text)
        out = project.compile(src, tmp_path / name / "build", "main.tex", "pdflatex")
        text = "".join(p.get_text() for p in pymupdf.open(out["pdf"])) if out["pdf"] else ""
        return out, text

    out, text = built("bib", {"main.tex": "\\documentclass{article}\n\\begin{document}\nKelp~\\cite{kelp}.\n"
                              "\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n", "refs.bib": bib})
    assert out["status"] == "ok" and "[1]" in text and "[?]" not in text and "Ruiz" in text, out["errors"]
    out, text = built("idx", {"main.tex": "\\documentclass{article}\n\\usepackage{makeidx}\n\\makeindex\n"
                              "\\begin{document}\nKelp\\index{kelp} drifts across the page.\n\\printindex\n"
                              "\\end{document}\n"})
    assert out["status"] == "ok" and "kelp" in text.lower(), out["errors"]
    out, text = built("inc", {"main.tex": "\\documentclass{article}\n\\begin{document}\n\\include{chap/one}\n"
                              "\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n",
                              "chap/one.tex": "Kelp~\\cite{kelp} in the chapter.\n", "refs.bib": bib})
    assert out["status"] == "ok" and "[1]" in text and "[?]" not in text and "Ruiz" in text, out["errors"]
    if shutil.which("biber", path=PATH):  # parse_bcf, through SAFE_AUX's guard
        out, text = built("biber", {"main.tex": "\\documentclass{article}\n\\usepackage[backend=biber]{biblatex}\n"
                                    "\\addbibresource{refs.bib}\n\\begin{document}\nKelp~\\cite{kelp}.\n"
                                    "\\printbibliography\n\\end{document}\n", "refs.bib": bib})
        assert out["status"] == "ok" and "[1]" in text and "Ruiz" in text, out["errors"]


def test_latexmks_lookups_keep_names_off_the_shell():
    """SAFE_AUX's other half, run in plain Perl with latexmk's subs stubbed: kpsewhich gets each name as one argument
    (a space or ; in it splits nothing and runs nothing), and parse_aux1 and parse_bcf refuse a name with a |, which
    Perl's two-argument open would run, and hand any other name to latexmk's own sub."""
    stubs = "sub kpsewhich {} sub parse_aux1 { print \"aux:$_[0]\\n\"; 1 } sub parse_bcf { print \"bcf:$_[0]\\n\"; 1 } "
    code = stubs + project.SAFE_AUX + (' print join("|", kpsewhich("article.cls", "no such;file name.sty")), "\\n";'
                                       ' print parse_aux1("build/one.aux"), parse_aux1("build/x|"), "\\n";'
                                       ' print parse_bcf("build/main.bcf"), parse_bcf("build/y|"), "\\n";')
    r = subprocess.run(["perl", "-e", code], capture_output=True, text=True, env=project.tex_env())
    assert r.returncode == 0 and r.stderr == "", r.stderr
    found, aux, auxed, bcf, bcfed = r.stdout.splitlines()
    assert found.endswith("/article.cls") and "|" not in found
    assert (aux, auxed, bcf, bcfed) == ("aux:build/one.aux", "10", "bcf:build/main.bcf", "10")


def test_needs_shell_escape():
    """A package or class asking for shell escape in a build made without it that has errors: in an error, or in a
    warning but one printed as it loads, the names quoted aside; or epstopdf's figure missing."""
    def build(errors=(), warnings=(), **kw):
        return dict({"errors": [{"file": None, "line": None, "message": m} for m in errors],
                     "warnings": list(warnings)}, **kw)
    loading = ["Package shellesc Warning: Shell escape disabled on input line 73.",
               "Package epstopdf Warning: Shell escape feature is not enabled.",
               "Package ifplatform Warning: shell escape is disabled, so I can only detect \\ifwindows.",
               "Package gnuplottex Warning: Shell escape not enabled. You'll need to convert the graphs yourself."]
    svg = ("Package svg Warning: You didn't enable `shell escape' (or `write18') so it wasn't possible to launch the "
           "Inkscape export for `figure.svg' on input line 12.")
    keys = ["Package natbib Warning: Citation `shell-escape' on page 1 undefined on input line 4.",
            "Package natbib Warning: Citation `write18' on page 1 undefined on input line 4."]
    other = "Undefined control sequence."
    asks = [build([MINTED_ERROR]),
            build(["minted.sty:12: " + MINTED_ERROR]),  # raised in a file outside src
            build(["Package standalone Error: Shell escape needed to create graphic! Use the '-shell-escape' "
                   "option.."]),
            build(["Package svg Error: File `figure_svg-tex.pdf' is missing."], loading[:1] + [svg]),
            build(["Package pdftex.def Error: File `figure-eps-converted-to.pdf' not found: using draft setting."],
                  loading[1:2], shell_escape=False)]
    assert [project.needs_shell_escape(b) for b in asks] == [True] * len(asks)
    quiet_ones = [build(), build([MINTED_ERROR], shell_escape=True),
                  build(warnings=loading), build([other], loading),  # packages loading, needed or not
                  build(warnings=[svg]),  # svg kept an older export: no error
                  build(warnings=keys), build([other], keys),  # the student's citation keys
                  build(warnings=["LaTeX Warning: Reference `sec:shell-escape' on page 1 undefined on input line 3."]),
                  build(["LaTeX Error: File `write18.sty' not found."]),
                  build(["Package pdftex.def Error: File `results.png' not found: using draft setting."], loading[1:2]),
                  build([other], ["Package hyperref Warning: Token not allowed."])]
    assert [project.needs_shell_escape(b) for b in quiet_ones] == [False] * len(quiet_ones)


def test_a_build_asks_only_when_it_failed_for_want_of_it(tmp_path, monkeypatch):
    """Built without shell escape (on an app's PATH): packages that only load say shell escape is off whether anything
    needs it (shellesc for standalone and svg, epstopdf), and a citation key may name it; such a paper does not ask,
    built clean or with an error of its own. svg and epstopdf failing for want of it do (minted: above)."""
    monkeypatch.setenv("PATH", GUI_PATH)
    eps = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\nnewpath 10 10 moveto 90 90 lineto stroke\nshowpage\n"
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><line x1="0" y1="0" x2="100" y2="100" '
           'stroke="black"/></svg>\n')
    loads = "\\usepackage{graphicx}\n\\usepackage{epstopdf}\n\\usepackage{standalone}\n\\usepackage{svg}\n" \
            "\\usepackage{natbib}\n"
    cites = "See \\citep{shell-escape,write18-attack}."
    for name, preamble, body, more, asks, errors in (
            ("loads", loads, cites, {}, False, False),
            ("loads-and-fails", loads, cites + " \\undefinedmacro", {}, False, True),
            ("svg", "\\usepackage{svg}\n", "\\includesvg{figure}", {"figure.svg": svg}, True, True),
            ("epstopdf", "\\usepackage{graphicx}\n\\usepackage{epstopdf}\n", "\\includegraphics{figure.eps}",
             {"figure.eps": eps}, True, True)):
        src = tmp_path / name
        src.mkdir()
        (src / "main.tex").write_text("\\documentclass{article}\n" + preamble + "\\begin{document}\n" + body
                                      + "\n\\end{document}\n")
        for file, text in more.items():
            (src / file).write_text(text)
        out = project.compile(src, tmp_path / (name + "-build"), "main.tex", "pdflatex")
        assert (bool(out["errors"]), project.needs_shell_escape(out)) == (errors, asks), (name, out["errors"],
                                                                                          out["warnings"])
        assert any("Shell escape" in w for w in out["warnings"]), name  # a package said it is off


def test_an_older_round_asks_too(tmp_path):
    """needs_shell_escape is derived in the state, so a round whose stored build lacks shell_escape (built before it
    was recorded: the advisor's minted paper) asks too, in whichever round is shown."""
    paper = handmade(tmp_path)  # rounds 1 (finished) and 2, their builds as an older engine stored them
    with ledger.edit(paper) as lg:
        for r in lg["rounds"]:
            r["build"]["errors"] = [{"file": "preamble.tex", "line": 28, "message": MINTED_ERROR}]
    assert all("shell_escape" not in r["build"] for r in ledger.load(paper)["rounds"])
    for n in (1, 2):
        b = call("state", paper=str(paper), round=n)["state"]["round"]["build"]
        assert (b["shell_escape"], b["needs_shell_escape"]) == (False, True)
    state = call("state", paper=str(paper))["state"]
    assert state["round"]["n"] == 2 and state["paper"]["shell_escape"] is False


def test_trust_does_not_travel(tmp_path):
    """A paper that comes in from a file (archive_unpack: Add, Put back, Keep Both; swap_in: Use This Copy) starts
    with shell escape off; one without it comes in byte for byte, as before."""
    reviews = tmp_path / "Reviews"
    paper = handmade(reviews)
    call("edit_paper", paper=str(paper), shell_escape=True)
    plain = handmade(tmp_path / "Other")
    out = Path(archive.write([{"path": str(paper)}, {"path": str(plain)}], tmp_path / "out.zip")["path"])
    dest = tmp_path / "dest"
    dest.mkdir()
    folders = {p["id"]: p["folder"] for p in archive.check(str(out))["papers"]}
    folder, other = (folders[ledger.load(p)["paper"]["id"]] for p in (paper, plain))
    for kw in ({}, {"fork": True}, {"copy": True}):
        got = archive.unpack(str(out), folder, dest, **kw)["path"]
        assert "shell_escape" not in ledger.load(got)["paper"], kw
        assert call("state", paper=got)["state"]["paper"]["shell_escape"] is False
    got = archive.unpack(str(out), other, dest)["path"]
    assert (Path(got) / "ledger.json").read_bytes() == (plain / "ledger.json").read_bytes()

    incoming = reviews / "incoming"
    shutil.copytree(paper, incoming)  # a folder with it on, put in place of yours
    assert ledger.load(incoming)["paper"]["shell_escape"] is True
    replaced = archive.swap_in(incoming, paper)["replaced"]
    assert "shell_escape" not in ledger.load(paper)["paper"]
    assert ledger.load(replaced)["paper"]["shell_escape"] is True  # yours, kept as it was


def test_a_copy_made_here_keeps_it_and_a_version_put_back_does_not_change_it(tmp_path, monkeypatch):
    """fork (a copy listed beside the paper, Keep Both of a folder on disk) keeps what its ledger says. Put Back keeps
    the paper's choice as it is now, as it keeps the paper's id: a version saved with shell escape on (as one an import
    came in with, kept in .history before the import took it off) does not turn it on, and a version from before it was
    turned on does not turn it off."""
    monkeypatch.setattr(history, "EVERY", -1)  # a copy before every edit: each choice has its version
    paper = new(tmp_path)
    ingest(paper, WRITE18, shell_escape=True)
    assert call("fork", paper=str(paper))["state"]["paper"]["shell_escape"] is True
    on = next(v["name"] for v in call("history", paper=str(paper))["versions"] if v["kind"] == "ingest")
    call("edit_paper", paper=str(paper), shell_escape=False)
    assert call("put_back_ledger", paper=str(paper), version=on)["state"]["paper"]["shell_escape"] is False
    assert "shell_escape" not in ledger.load(paper)["paper"]
    call("edit_paper", paper=str(paper), shell_escape=True)
    off = next(v["name"] for v in call("history", paper=str(paper))["versions"] if v["kind"] == "edit")
    assert "shell_escape" not in json.loads((paper / ".history" / off).read_text())["paper"]
    assert call("put_back_ledger", paper=str(paper), version=off)["state"]["paper"]["shell_escape"] is True
    assert ledger.load(paper)["paper"]["shell_escape"] is True


def test_a_comment_on_a_build_with_shell_escape_lands_on_its_line(paper, tmp_path):
    """The pretex goes before the main file on LaTeX's command line: synctex still names each file and line, both
    ways, so comments anchor and are placed as on the build without shell escape (the fixture paper's round 1)."""
    escaped = new(tmp_path, "escaped")
    b = ingest(escaped, FIXTURE / "v1", shell_escape=True)["round"]["build"]
    assert (b["status"], b["shell_escape"], b["pages"]) == ("ok", True, 4)
    assert files(escaped / "r1" / "src") == files(FIXTURE / "v1")
    places = [(0, "rate from 18.4% to 6.1% while using 22% less idle memory", "main.tex", 25),
              (1, "which performed best on a held-out day of the trace.", "sections/method.tex", 20)]
    anchors = {}
    for folder in (paper, escaped):
        pdf = str(folder / "r1" / "build" / "main.pdf")
        for page, phrase, file, line in places:
            r = call("comment", paper=str(folder), page=page, rects=select(pdf, page, phrase), text="", note="x")
            c = next(c for c in r["state"]["comments"] if c["id"] == r["id"])
            assert (c["file"], c["line"], c["method"]) == (file, line, "selection"), folder
            a = ledger.get_comment(ledger.load(folder), r["id"])["rounds"]["1"]["anchor"]
            at, _, text = anchor.to_pdf(folder / "r1" / "src", pdf, a["file"], a["start"], a["end"])
            assert at == page and " ".join(phrase.split()) in text, (folder, text)
            anchors.setdefault(phrase, []).append({k: a[k] for k in ("file", "start", "end", "lines", "page", "rects")})
    assert all(a == b for a, b in anchors.values())


def test_cli(tmp_path, capsys):
    """ingest and edit-paper mirror the parameter: --shell-escape, --no-shell-escape, or neither (as stored)."""
    paper = new(tmp_path)

    def run(*args):
        assert cli.main([args[0], str(paper)] + list(args[1:])) == 0
        return json.loads(capsys.readouterr().out)["state"]
    assert run("ingest", str(WRITE18), "--shell-escape")["paper"]["shell_escape"] is True and ran(paper)
    assert run("ingest", str(WRITE18))["round"]["build"]["shell_escape"] is True and ran(paper)
    assert run("edit-paper", "--no-shell-escape")["paper"]["shell_escape"] is False
    assert run("ingest", str(WRITE18))["round"]["build"]["shell_escape"] is False and not ran(paper)
    assert run("edit-paper", "--shell-escape")["paper"]["shell_escape"] is True
    assert run("ingest", str(WRITE18), "--no-shell-escape")["paper"]["shell_escape"] is False and not ran(paper)
    assert "shell_escape" not in ledger.load(paper)["paper"]
