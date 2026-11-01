"""Snapshot a student's source, detect its main file and engine, and compile it (CONTRACT.md §5)."""
import datetime
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath

import pymupdf

from . import EngineError, texdiff

TEXBIN = "/Library/TeX/texbin"
TIMEOUT = 300  # seconds
ENGINES = {"pdflatex": "-pdf", "xelatex": "-xelatex", "lualatex": "-lualatex"}
BUILD_PRODUCTS = (".aux", ".log", ".out", ".toc", ".lof", ".lot", ".fls", ".fdb_latexmk", ".synctex.gz", ".blg", ".xdv")
ERROR = re.compile(r"^(.*?\.\w+):(\d+): (.*)$")  # -file-line-error format
WARNING = re.compile(r"^(?:LaTeX(?: Font)?|Package \S+|Class \S+) Warning: ")
FOLLOW_UP = re.compile(r"Emergency stop\.|==> Fatal error occurred")
# Warnings of a run that stopped early say only that it did not finish (undefined references, reruns).
UNFINISHED = re.compile(r"undefined|[Rr]erun|may have changed")
# A package or class asking for shell escape: minted's "You must invoke LaTeX with the -shell-escape flag",
# standalone's "Shell escape needed to create graphic!", tikz's "… this is 'pdflatex -shell-escape'", svg's "You didn't
# enable `shell escape' (or `write18') so it wasn't possible to launch the Inkscape export for `figure.svg'". LaTeX's
# own messages are not asking: they quote the student's labels and file names.
ASKS_SHELL_ESCAPE = re.compile(r"(?:Package|Class) \S+ (?:Error|Warning): .*(?:shell[ -]escape|write18)", re.I)
# A name a message quotes is the student's (natbib's "Citation `shell-escape' on page 1 undefined"): never asking. svg
# quotes its own `shell escape', which no key or label is.
QUOTED = re.compile(r"`(?!shell escape')[^`']*'")
# What a package says as it loads, whether anything needs shell escape or not: shellesc's "Shell escape disabled" (svg,
# standalone and minted load it), epstopdf's "Shell escape feature is not enabled", ifplatform's "shell escape is
# disabled", gnuplottex's "Shell escape not enabled".
LOADING = re.compile(r"Package (?:shellesc|epstopdf|ifplatform|gnuplottex) Warning: ")
# epstopdf asks by the figure it could not make: figure.eps becomes figure-eps-converted-to.pdf by a program it runs
CONVERTED = re.compile(r"File `[^`']*-eps-converted-to\.pdf' not found")
# What a shell still reads inside "…", where latexmk puts the output folder (and the main file) in its command lines:
# in a path, a $(…) or a backquote would run as a command, with shell escape or without (compile refuses such a path)
SHELL_QUOTED = "$`\"\\"
# minted's outputdir, in a pretex only when it is this plain: latexmk puts the pretex in "…" in a shell command line
PLAIN_PATH = re.compile(r"[A-Za-z0-9._/-]+")
# latexmk builds the bibtex, biber and makeindex command lines from auxiliary-file names the student's LaTeX chooses
# (imakeidx's \makeindex[name=…], multibib's \newcites{…}) and runs them through /bin/sh with the name in "…", where a
# backquote or $(…) still runs — with shell escape or without. The names exist only after TeX has run, so compile
# cannot screen them (the main file and the folder paths it can, and does). This fixed -e Perl, with no student string
# in it, makes latexmk run those three as its own `internal` commands that call one sub, which runs the program as an
# argv list (system BLOCK, never the shell); latexmk splits the substituted arguments itself (its parse_quotes). The
# rest of the command, and the *latex run, are unchanged. Two more places hand such names to the shell (latexmk 4.79):
# its kpsewhich sub, which looks up \bibdata and \bibstyle names and names read from the log through open "$cmd|"
# with the names unquoted, is replaced by one that runs kpsewhich as an argv list; and parse_aux1 and parse_bcf, which
# open an .aux named in an .aux with Perl's two-argument open (a name ending in | would run), refuse a name with a |.
# CONTRACT §"Shell escape per paper" (Security).
SAFE_AUX = ("sub paperole_run { my $p = shift; return system { $p } $p, @_; } "
            "foreach my $c (\\$bibtex, \\$biber, \\$makeindex) { $$c = \"internal paperole_run $$c\"; } "
            "no warnings 'redefine'; "
            "*kpsewhich = sub { my @found; open(my $fh, '-|', 'kpsewhich', @_) or return (); "
            "while (<$fh>) { s/\\r?\\n$//; push @found, $_; } close $fh; return @found; }; "
            "foreach my $s ('parse_aux1', 'parse_bcf') { my $orig = \\&$s; "
            "*$s = sub { return 0 if $_[0] =~ /\\|/; return $orig->(@_); }; }")


def _skipped(parts):
    return (any(p.startswith(".") or p == "__MACOSX" for p in parts)
            or parts[-1].endswith(BUILD_PRODUCTS))


def _nfc(name):
    """A file name in NFC: a name copied from Finder or a Cocoa editor may be NFD, and an \\input names it in NFC."""
    return unicodedata.normalize("NFC", name)


def snapshot(source, dest):
    """Copy a folder or .zip into dest (which must not exist) as read-only files; return warnings."""
    source, dest = Path(source), Path(dest)
    if dest.exists():
        raise EngineError("{} already exists.".format(dest))
    if source.is_dir():
        if dest.resolve() == source.resolve() or source.resolve() in dest.resolve().parents:
            raise EngineError("The paper folder must not be inside the student's source folder.")
        return _copy_folder(source, dest)
    if source.is_file() and zipfile.is_zipfile(source):
        return _copy_zip(source, dest)
    raise EngineError("{} is not a folder or a .zip file.".format(source))


def _copy_folder(source, dest):
    warnings = []
    dest.mkdir(parents=True)
    for root, dirs, names in os.walk(source):
        rel = Path(root).relative_to(source)
        out = dest / _nfc(rel.as_posix())
        for d in list(dirs):
            if Path(root, d).is_symlink():
                warnings.append("Skipped the symbolic link {}".format((rel / d).as_posix()))
                dirs.remove(d)
            elif _skipped(rel.parts + (d,)):
                dirs.remove(d)
            else:
                (out / _nfc(d)).mkdir()
        for name in names:
            path = Path(root, name)
            if path.is_symlink():
                warnings.append("Skipped the symbolic link {}".format((rel / name).as_posix()))
            elif path.is_file() and not _skipped(rel.parts + (name,)):
                shutil.copyfile(path, out / _nfc(name))
                os.chmod(out / _nfc(name), 0o444)
    return warnings


def _member_name(info):
    """A zip member's name: UTF-8 also when the zip did not flag it (Finder's Compress and Info-ZIP; zipfile then
    read it as cp437), in NFC, with "\\" as "/" (some Windows and Java zippers)."""
    name = info.filename
    if not info.flag_bits & 0x800:
        try:
            name = name.encode("cp437").decode("utf-8")
        except UnicodeError:
            pass
    return _nfc(name).replace("\\", "/")


def _members(z):
    """What snapshot copies from the open zip z, and its warnings: [(parts, is_dir, info)], with parts below the
    single top-level folder it unwraps. That folder is unwrapped when no .tex file is beside it; the files beside it
    (a README, the PDF) are skipped."""
    warnings, members = [], []
    for info in z.infolist():
        name = _member_name(info)
        parts = PurePosixPath(name).parts
        if not parts:
            continue
        if name.startswith("/") or ".." in parts or ":" in parts[0]:
            raise EngineError("The zip file contains an unsafe path: {}".format(name))
        if stat.S_ISLNK(info.external_attr >> 16):
            warnings.append("Skipped the symbolic link {}".format(name))
        elif not _skipped(parts):
            members.append((parts, name.endswith("/"), info))
    tops = {parts[0] for parts, is_dir, _ in members if len(parts) > 1 or is_dir}
    beside = [parts[0] for parts, is_dir, _ in members if len(parts) == 1 and not is_dir]
    strip = 1 if len(tops) == 1 and not any(n.endswith(".tex") for n in beside) else 0
    if strip:
        warnings += ["Skipped {} beside the source folder".format(n) for n in beside]
    return [(parts[strip:], is_dir, info) for parts, is_dir, info in members if len(parts) > strip], warnings


def _copy_zip(source, dest):
    with zipfile.ZipFile(source) as z:
        members, warnings = _members(z)
        dest.mkdir(parents=True)
        for parts, is_dir, info in members:
            target = dest.joinpath(*parts)
            if is_dir:
                target.mkdir(parents=True, exist_ok=True)
            elif not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                with z.open(info) as fsrc, open(target, "wb") as fdst:
                    shutil.copyfileobj(fsrc, fdst)
                os.chmod(target, 0o444)
    return warnings


def received(source):
    """When the student last changed the source: the latest modification time of the files snapshot copies from the
    folder (or, for a .zip, the latest date its members carry, read as local time), as ISO 8601 local time with offset,
    to the second; None when there is no such file or it cannot be read. Ingest stores it as round.received."""
    source, times = Path(source), []
    try:
        if source.is_dir():
            for root, dirs, names in os.walk(source):
                rel = Path(root).relative_to(source)
                dirs[:] = [d for d in dirs if not Path(root, d).is_symlink() and not _skipped(rel.parts + (d,))]
                for name in names:
                    path = Path(root, name)
                    if not path.is_symlink() and path.is_file() and not _skipped(rel.parts + (name,)):
                        times.append(path.stat().st_mtime)
        else:
            with zipfile.ZipFile(source) as z:
                for _, is_dir, info in _members(z)[0]:
                    if not is_dir:
                        try:
                            times.append(datetime.datetime(*info.date_time).timestamp())
                        except (ValueError, OverflowError):  # a member with no valid date
                            pass
    except (OSError, ValueError, zipfile.BadZipFile, EngineError):
        return None
    if not times:
        return None
    return datetime.datetime.fromtimestamp(max(times)).astimezone().isoformat(timespec="seconds")


def _read(path):
    return Path(path).read_text(encoding="utf-8", errors="replace")


def _uncomment(text):
    """Drop each unescaped % and the rest of its line."""
    return re.sub(r"((?:^|[^\\])(?:\\\\)*)%.*", r"\1", text, flags=re.M)


def detect(src, main=None):
    """{"main", "engine"}: main is given or is the top-level .tex file with a \\documentclass."""
    src = Path(src)
    if main is None:
        found = sorted(p.name for p in src.glob("*.tex")
                       if p.is_file() and "\\documentclass" in _uncomment(_read(p)))
        if not found:
            raise EngineError("No top-level .tex file in the source has a \\documentclass.")
        if len(found) > 1 and "main.tex" not in found:
            raise EngineError("Several files could be the main file: {}. Choose one.".format(", ".join(found)))
        main = found[0] if len(found) == 1 else "main.tex"
    elif len(PurePosixPath(main).parts) > 1:  # latexmk runs in src, so its \input names would not be found
        raise EngineError("The main file must be at the top of the source, not in a folder: {}.".format(main))
    elif not (src / main).is_file():
        raise EngineError("The main file {} is not in the source.".format(main))
    text = _read(src / main)
    for line in text.splitlines()[:20]:
        m = re.match(r"\s*%\s*!\s*TEX\s+(?:TS-)?program\s*=\s*(\w+)", line, re.I)
        if m and m.group(1).lower() in ENGINES:
            return {"main": main, "engine": m.group(1).lower()}
    unicode_pkg = r"\\usepackage\s*(?:\[[^\]]*\])?\s*\{[^}]*\b(?:fontspec|xeCJK|polyglossia|unicode-math)\b"
    files = {p.relative_to(src).as_posix() for p in src.rglob("*") if p.is_file()}
    xe = any(re.search(unicode_pkg, t) for t in _preamble(src, _uncomment(text), files))
    return {"main": main, "engine": "xelatex" if xe else "pdflatex"}


def _preamble(src, text, files, depth=2):
    """text up to \\begin{document}, then the texts of the files of `files` that it reads (\\input …), depth levels
    deep: where main loads its packages."""
    text = text.split("\\begin{document}")[0]
    texts = [text]
    for m in texdiff.INCLUDE.finditer(text) if depth else ():
        f = texdiff.include_file(m, files)
        if f:
            texts += _preamble(src, _uncomment(_read(src / f)), files, depth - 1)
    return texts


def tex_env():
    """The environment for TeX tools; apps launched from the GUI lack TeX on PATH."""
    return dict(os.environ, PATH=TEXBIN + os.pathsep + os.environ.get("PATH", ""))


def compile(src, build, main, engine, progress=lambda message: None, shell_escape=False):
    """Run latexmk in src with output in build; return the build result with absolute paths. shell_escape (the paper's
    choice, off unless the advisor turns it on): \\write18 may run any command, for minted and the like
    (_with_shell_escape); off, the command and its environment are as they always were."""
    # latexmk reads an argument that starts with - as its own option, and puts the name in "…" in a shell command
    # line, where a backquote is not quoted; the output folder too, where the shell reads a $, backquote, " or \ of the
    # review folder's path, which src shares (SHELL_QUOTED)
    if main.startswith("-") or "`" in main:
        raise EngineError("The main file's name {} starts with - or has a `, which latexmk would misread. Rename the "
                          "file.".format(main))
    for path in (build, src):
        if any(c in str(path) for c in SHELL_QUOTED):
            raise EngineError("The folder path {} has a $, `, \" or \\, which latexmk would run as part of a command. "
                              "Rename the folder that has it.".format(path))
    src, build = Path(src), Path(build)
    build.mkdir(parents=True, exist_ok=True)
    for d in src.rglob("*"):  # latexmk does not create output subfolders for \include{chap/a}
        if d.is_dir():
            (build / d.relative_to(src)).mkdir(parents=True, exist_ok=True)
    env = dict(tex_env(), max_print_line="10000")  # keep log lines unwrapped
    cmd = ["latexmk", "-norc", "-e", SAFE_AUX, ENGINES[engine], "-f", "-synctex=1", "-interaction=nonstopmode",
           "-file-line-error", "-no-shell-escape", "-outdir=" + str(build), main]
    if shell_escape:
        cmd, env = _with_shell_escape(cmd, env, src, build)
    progress("Compiling with {}{}…".format(engine, " and shell escape" if shell_escape else ""))
    start = time.monotonic()
    out, timed_out = _latexmk(cmd, src, env, TIMEOUT)

    stem = Path(main).stem
    pdf, log = build / (stem + ".pdf"), build / (stem + ".log")
    # With -f, latexmk stops after a LaTeX run with an error, before the runs that resolve \cite and \ref, so they
    # would print [?] and ??. One more call with -g finishes them, when as much time is left as the first call took.
    spent = time.monotonic() - start
    if not timed_out and pdf.exists() and log.exists() and spent <= TIMEOUT / 2 and _parse_log(log, src)[0]:
        progress("Compiling again after LaTeX errors…")
        out, timed_out = _latexmk(cmd[:1] + ["-g"] + cmd[1:], src, env, TIMEOUT - spent)
    pages = 0
    if pdf.exists():
        try:
            pages = pymupdf.open(pdf).page_count
        except Exception:
            pages = 0
    errors, warnings = _parse_log(log, src) if log.exists() else ([], [])
    if timed_out:
        errors.append({"file": None, "line": None, "message": "Compilation stopped after {} s.".format(TIMEOUT)})
    elif not pages and not errors:
        tail = [l for l in out.decode("utf-8", "replace").splitlines() if l.strip()][-5:]
        errors.append({"file": None, "line": None, "message": "No PDF was produced. " + " ".join(tail)})
    status = "failed" if timed_out or not pages else "errors" if errors else "ok"
    if status == "failed":
        warnings = [w for w in warnings if not UNFINISHED.search(w)]
    return {"status": status, "pdf": str(pdf) if status != "failed" else None,
            "log": str(log) if log.exists() else None, "pages": pages, "errors": errors, "warnings": warnings,
            "tex": tex_version(log), "shell_escape": bool(shell_escape)}


def _with_shell_escape(cmd, env, src, build):
    """cmd and env for a build with shell escape: -shell-escape for -no-shell-escape; the folder of the engine's own
    Python last on PATH (not resolved: the venv's bin), where pygmentize is, which minted runs and an app launched from
    the GUI finds nowhere else; and, as a pretex, minted 2's outputdir: the build folder relative to src, where TeX
    writes what pygmentize reads and minted keeps its cache (without it minted finds no output with -outdir, and
    writes _minted-<job>/ into src). The rest of the command is unchanged: no student string is added to it."""
    cmd = ["-shell-escape" if a == "-no-shell-escape" else a for a in cmd]
    python = os.path.dirname(sys.executable or "")
    if python:  # an empty entry would put src on PATH
        env = dict(env, PATH=env["PATH"] + os.pathsep + python)
    rel = os.path.relpath(build, src)
    if PLAIN_PATH.fullmatch(rel):
        cmd.insert(-1, "-usepretex=\\PassOptionsToPackage{outputdir=" + rel + "}{minted}")
    return cmd, env


def needs_shell_escape(build):
    """Whether a round's build asks for shell escape: it was built without it, it has errors, and a package or class
    asks for it (ASKS_SHELL_ESCAPE) in an error or in a warning other than one printed as it loads (LOADING), the names
    the messages quote aside (QUOTED); or epstopdf's figure is missing (CONVERTED). So a build without errors never
    asks, nor one whose only asking is a package loading (standalone, epstopdf and svg say shell escape is off whether
    anything needs it). Derived from the build as stored, so a round built before builds recorded shell_escape has it
    too."""
    errors = [e["message"] for e in build["errors"]]
    if build.get("shell_escape") is True or not errors:
        return False
    asking = [QUOTED.sub("", m) for m in errors + [w for w in build["warnings"] if not LOADING.match(w)]]
    return any(ASKS_SHELL_ESCAPE.search(m) for m in asking) or any(CONVERTED.search(m) for m in errors)


def _latexmk(cmd, src, env, timeout):
    """Run cmd in src with output captured; (output, timed out)."""
    try:
        proc = subprocess.Popen(cmd, cwd=src, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, start_new_session=True)
    except FileNotFoundError:
        raise EngineError("latexmk was not found. Is TeX Live installed in {}?".format(TEXBIN))
    try:
        return proc.communicate(timeout=timeout)[0], False
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        return proc.communicate()[0], True


def tex_version(log):
    """The TeX that built the round, from the log's first line without "This is " and the run's date ("pdfTeX,
    Version 3.141592653-2.6-1.40.26 (TeX Live 2024) (preloaded format=pdflatex 2024.3.19)"), or None."""
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            first = f.readline()
    except OSError:
        return None
    m = re.match(r"This is (.+?)(?:\s+\d{1,2} [A-Z]{3} \d{4} \d{1,2}:\d{2})?\s*$", first)
    return " ".join(m.group(1).split()) if m else None


def _parse_log(log, src):
    lines = _read(log).splitlines()
    errors, warnings = [], []
    for i, line in enumerate(lines):
        m = ERROR.match(line)
        if m or line.startswith("! "):
            more = _continued(lines, i)
            err = {"file": None, "line": None, "message": line[2:] + more}
            if m:  # outside src (a TeX Live file), the place stays in the message
                file = _src_file(m.group(1), src)
                msg = m.group(3).strip() + more
                err = {"file": file, "line": int(m.group(2)) if file else None, "message": msg
                       if file else "{}:{}: {}".format(Path(m.group(1)).name, m.group(2), msg)}
                if FOLLOW_UP.match(m.group(3).strip()):  # TeX stopping after the error before it: its place only
                    if errors and errors[-1]["file"] is None and file:
                        errors[-1].update(file=file, line=err["line"])
                    continue
            if err not in errors:
                errors.append(err)
        elif WARNING.match(line):
            msg = line.strip() + _continued(lines, i)
            if msg not in warnings:
                warnings.append(msg)
    return errors, warnings


def _continued(lines, i):
    """The continuation lines after lines[i] ("(pkg)   …" or indented, up to a blank line), each after a space."""
    more = ""
    for nxt in lines[i + 1:]:
        if not nxt.strip() or not (nxt.startswith(" ") or re.match(r"\([^\s/()]*\)\s", nxt)):
            break
        piece = re.sub(r"^\([^\s/()]*\)", "", nxt).strip()
        if piece:  # a "(fontspec)" line alone parts two paragraphs of the message
            more += " " + piece
    return more


def _src_file(name, src):
    """A log file name relative to src, or None when it is outside src."""
    if name.startswith("./"):
        return name[2:]
    path = Path(name)
    if path.is_absolute():
        try:
            return path.resolve().relative_to(Path(src).resolve()).as_posix()
        except ValueError:
            return None
    return name


def log_tail(log, n=40):
    if not log or not Path(log).exists():
        return ""
    return "\n".join(_read(log).splitlines()[-n:])
