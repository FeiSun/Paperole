"""Snapshot a student's source, detect its main file and engine, and compile it (CONTRACT.md §5)."""
import datetime
import os
import re
import shutil
import signal
import stat
import subprocess
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


def compile(src, build, main, engine, progress=lambda message: None):
    """Run latexmk in src with output in build; return the build result with absolute paths."""
    src, build = Path(src), Path(build)
    build.mkdir(parents=True, exist_ok=True)
    for d in src.rglob("*"):  # latexmk does not create output subfolders for \include{chap/a}
        if d.is_dir():
            (build / d.relative_to(src)).mkdir(parents=True, exist_ok=True)
    env = dict(tex_env(), max_print_line="10000")  # keep log lines unwrapped
    cmd = ["latexmk", "-norc", ENGINES[engine], "-f", "-synctex=1", "-interaction=nonstopmode",
           "-file-line-error", "-no-shell-escape", "-outdir=" + str(build), main]
    progress("Compiling with {}…".format(engine))
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
            "tex": tex_version(log)}


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
