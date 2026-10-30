"""Safe writes and round checksums (design/data/DATA.md §2.4). A primary file (the ledger, analysis.json, final.pdf,
email.txt, a round's checksums) is written whole or not at all, and is on the drive, not in its cache, before the
engine goes on."""
import contextlib
import errno
import fcntl
import hashlib
import os
import re
import tempfile
from pathlib import Path

MANIFEST = "manifest-sha256.txt"  # a finished round's checksums, in shasum's format (shasum -a 256 -c reads it)


def _sync(fd):
    """Flush a file to the drive: F_FULLFSYNC on macOS (its fsync leaves the data in the drive's cache), else fsync."""
    if hasattr(fcntl, "F_FULLFSYNC"):
        try:
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
            return
        except OSError as e:  # a file system without it (some network and FAT drives): fsync
            if e.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.EINVAL, errno.ENOTTY):
                raise
    os.fsync(fd)


def _sync_folder(folder):
    """Flush a folder's entries (a rename into it); a file system that cannot sync a folder is left as it is."""
    with contextlib.suppress(OSError):
        fd = os.open(str(folder), os.O_RDONLY)
        try:
            _sync(fd)
        finally:
            os.close(fd)


def replace(tmp, path):
    """Move a finished temporary file over path: the file synced, renamed, then its folder synced."""
    fd = os.open(str(tmp), os.O_RDONLY)
    try:
        _sync(fd)
    finally:
        os.close(fd)
    os.replace(str(tmp), str(path))
    _sync_folder(Path(path).parent)


def atomic_write(path, data):
    """Write data (bytes, or str as UTF-8) to path: a temporary file beside it, synced, renamed over path, the folder
    synced. A failure (a full disk) leaves path as it was and no temporary file. A file keeps its permissions."""
    path = Path(path)
    if isinstance(data, str):
        data = data.encode("utf-8")
    try:
        mode = path.stat().st_mode & 0o7777
    except OSError:
        mode = 0o644
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fchmod(f.fileno(), mode)
            _sync(f.fileno())
        os.replace(tmp, str(path))
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    _sync_folder(path.parent)


def move(src, dest):
    """Move a file to dest on the same disk (one rename, whole or not at all), never over a file there; both folders
    synced (Resume keeps a finished round's files in rN/earlier/)."""
    src, dest = Path(src), Path(dest)
    if os.path.lexists(str(dest)):
        raise FileExistsError(errno.EEXIST, "There is a file there already", str(dest))
    os.rename(str(src), str(dest))
    _sync_folder(dest.parent)
    if src.parent != dest.parent:
        _sync_folder(src.parent)


def sha256(path):
    """The SHA-256 of a file, hex."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


# --- round checksums -------------------------------------------------------------------------------------------

def hidden(name):
    """Whether a name relative to a round's folder has a part that starts with "." (Finder's .DS_Store, left when the
    advisor looks at rN/src): the snapshot never copies one, so it is none of the round's files."""
    return any(part.startswith(".") for part in name.split("/"))


def round_files(rdir, stem):
    """A round's primary files that exist, relative to its folder and sorted: every file of src (not a hidden one),
    the build's PDF, synctex, log and .bbl (<stem>.*), analysis.json, final.pdf and email.txt. Not the rebuildable
    ones (prose.json, contexts.json, analysis.cache.json, latexmk's other files)."""
    rdir = Path(rdir)
    names = [p.relative_to(rdir).as_posix() for p in (rdir / "src").rglob("*") if p.is_file() and not p.is_symlink()]
    names = [n for n in names if not hidden(n)]
    names += ["build/" + stem + ext for ext in (".pdf", ".synctex.gz", ".log", ".bbl")]
    names += ["analysis.json", "final.pdf", "email.txt"]
    return sorted(n for n in set(names) if (rdir / n).is_file())


def _escape(name):
    """A file name as shasum writes it: a backslash or a line break escaped, and the line marked with a backslash."""
    if "\\" in name or "\n" in name:
        return True, name.replace("\\", "\\\\").replace("\n", "\\n")
    return False, name


def _unescape(name):
    """_escape undone, left to right (a backslash before an n in a name is not a line break)."""
    return re.sub(r"\\([\\n])", lambda m: "\n" if m.group(1) == "n" else "\\", name)


def manifest_line(name, digest):
    """One line of a checksums file, as shasum writes it."""
    escaped, text = _escape(name)
    return "{}{}  {}\n".format("\\" if escaped else "", digest, text)


def parse_manifest(text):
    """The lines of a checksums file in shasum's format: [(name, digest)] and whether a line could not be read (no
    name, an absolute name or one with "..": the list itself is not intact)."""
    out, damaged = [], False
    lines = text.split("\n")  # only \n ends a line, as for shasum: a name may hold \r, \f or U+2028
    for line in lines[:-1] if lines[-1] == "" else lines:
        escaped = line.startswith("\\")
        digest, sep, name = line[1 if escaped else 0:].partition("  ")
        if not sep:
            digest, sep, name = line[1 if escaped else 0:].partition(" *")
        name = _unescape(name) if escaped else name
        if not sep or not name or name.startswith("/") or ".." in name.split("/"):
            damaged = True
            continue
        out.append((name, digest.lower()))
    return out, damaged


def write_manifest(rdir, stem):
    """Write rN/manifest-sha256.txt over the round's primary files (Finish): closed rounds never change, so damage
    shows in any copy of the folder."""
    lines = [manifest_line(name, sha256(Path(rdir) / name)) for name in round_files(rdir, stem)]
    atomic_write(Path(rdir) / MANIFEST, "".join(lines))


def verify_manifest(rdir):
    """A finished round against its checksums: {"changed", "missing", "extra"} (relative names; extra: files of src
    that are not listed), or None when the round has none (finished before they were written). Hidden files (hidden)
    are not compared, also when an older list names them. Read only."""
    rdir = Path(rdir)
    try:
        text = (rdir / MANIFEST).read_bytes().decode("utf-8", "replace")  # as written: no \r read as a line end
    except FileNotFoundError:
        return None
    out = {"changed": [], "missing": [], "extra": []}
    listed = set()
    entries, damaged = parse_manifest(text)
    if damaged:
        out["changed"].append(MANIFEST)  # a damaged line: the list itself is not intact
    for name, digest in entries:
        listed.add(name)
        if hidden(name):
            continue
        p = rdir / name
        if p.is_symlink():  # a link in a round's folder is never the engine's: not followed
            out["changed"].append(name)
        elif not p.is_file():
            out["missing"].append(name)
        elif sha256(p) != digest.lower():
            out["changed"].append(name)
    if (rdir / "src").is_dir():
        out["extra"] = sorted(n for n in (p.relative_to(rdir).as_posix() for p in (rdir / "src").rglob("*")
                                          if p.is_file()) if n not in listed and not hidden(n))
    out["changed"] = sorted(set(out["changed"]))
    return out
