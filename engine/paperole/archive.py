"""Export files and Import (design/data/DATA.md §3, §5.2, §5.4; CONTRACT.md amendment "Export and import files").

An export is one plain .zip (backup.json schema 2) holding one folder named as the file:
  README.txt                       what it is, how to import it and check it without the app
  backup.json                      what it holds; pins manifest-sha256.txt by its SHA-256
  manifest-sha256.txt              every other file's SHA-256, in shasum's format
  students/<student>/<folder>/…    each review folder whole (.history included; not .lock)
  app/tags.json, app/drafts/<id>.json, app/settings.json (an export of everything only): the app's data as it gives it
write makes it under each paper's lock and reads it back before naming it; check reads a file without unpacking (also
a schema-1 backup, a review folder zipped or not, and a folder searched three levels down for review folders, which
are listed where they are); unpack takes one paper out into a new folder; swap_in puts it in place of yours by two
renames. Every entry of a file is checked before anything is read (_Zip). Nothing here writes into a review folder
but unpack's fork of its own new folder and swap_in's renames."""
import contextlib
import datetime
import hashlib
import json
import os
import shutil
import stat
import tempfile
import time
import unicodedata
import zipfile
import zlib
from pathlib import Path

from . import EngineError, __version__, check as checks, disk, ledger

SCHEMA = 2
FORMAT = "Paperole"  # backup.json's "app": the format's name, the same in Dev
# The app was PaperCollab until 2026-10-27 and its files said so: read forever, never written. made_by's "variant" is
# the app's name ("Paperole", "Paperole Dev"); an older file's ("PaperCollab", "PaperCollab Dev") is shown as its new one.
FORMATS = (FORMAT, "PaperCollab")
SHOWN = {"PaperCollab": "Paperole", "PaperCollab Dev": "Paperole Dev"}
# the hidden folder an import unpacks into, beside where the paper goes; the app sweeps both names' leftovers
STAGING = ".Paperole-import-"
KINDS = ("export", "automatic")
SCOPES = ("everything", "chosen")
MANIFEST = "manifest-sha256.txt"
BACKUP = "backup.json"
REPLACED = "Replaced by Import"
SKIP = (".lock",)  # never in an export: the lock's empty target
MAX_ENTRIES = 200000
MAX_RATIO = 100  # an entry over BIG compressed more than this, or all of them against the file: a zip bomb
BIG = 1 << 20
MAX_LEDGER = 32 << 20  # also backup.json, a checksums file and the app's files, read whole
HEADROOM = 5 * 10 ** 9  # free space to keep besides the file: decimal GB, as Finder counts
FLOOR = 2 * 10 ** 9  # stop writing below this
SEARCH_DEPTH = 3
CHUNK = 1 << 20
QUIET = ("leftovers", "orphans", "conflict_copies", "evicted")  # check's problems that are no damage
CANCELLED = "Cancelled. Nothing was written."


def _never():
    return False


def _stop(cancelled):
    if cancelled():
        raise EngineError(CANCELLED)


def free_space(folder):
    """Free bytes on the disk holding folder (the tests replace it)."""
    return shutil.disk_usage(str(folder)).free


def _gb(n):
    return "{:.1f} GB".format(n / 1e9)


def _room(folder, estimate):
    """Start only with free space of the estimate × 1.2 + 5 GB, so a file never fills the disk comments are saved on."""
    need, free = int(estimate * 1.2) + HEADROOM, free_space(folder)
    if free < need:
        raise EngineError("There is not enough free space on the disk of “{}”: this needs about {} free (the files "
                          "and 5 GB to spare), and {} is.".format(folder, _gb(need), _gb(free)))


def _floor(folder):
    if free_space(folder) < FLOOR:
        raise EngineError("Stopped: less than 2 GB is free on the disk of “{}”. Nothing was written.".format(folder))


def _engine():
    return __version__


def safe_name(name, fallback):
    """A folder's name from a title, a student's name or a folder's name, as the app's DataFiles.name makes one: no
    "/", ":" or control characters, white space collapsed, no dot, dash or space first, at most 80 characters;
    fallback when nothing is left."""
    s = "".join("-" if c in "/:" else " " if unicodedata.category(c) == "Cc" else c for c in str(name or ""))
    return " ".join(s.split()).lstrip(". -")[:80].strip() or fallback


def _key(name):
    """A name as APFS compares names: Unicode-normalized and case-folded."""
    return unicodedata.normalize("NFC", name).casefold()


def _unique(name, taken):
    """name, or "name 2", "name 3" … when taken (a set of _key) has it; the name is then taken."""
    out, n = name, 2
    while _key(out) in taken:
        out, n = "{} {}".format(name, n), n + 1
    taken.add(_key(out))
    return out


def _claim(folder, name):
    """A new empty folder in folder named name ("name 2" … when taken), made now so nothing else takes the name; the
    caller renames its own folder over it (rename replaces an empty folder)."""
    n = 1
    while True:
        p = Path(folder) / (name if n == 1 else "{} {}".format(name, n))
        try:
            p.mkdir()
            return p
        except FileExistsError:
            n += 1


def _mac(name):
    """An entry of the Mac's own (__MACOSX: Finder's copies of extended attributes), never read or unpacked."""
    return name.split("/", 1)[0] == "__MACOSX"


def _entry_name(info):
    """An entry's name as written: UTF-8 also when the .zip did not flag it (zipfile then read it as cp437)."""
    name = info.orig_filename  # with any NUL: zipfile's filename is cut at the first one
    if not info.flag_bits & 0x800:
        with contextlib.suppress(UnicodeEncodeError, UnicodeDecodeError):
            name = name.encode("cp437").decode("utf-8")
    return name


class _Zip:
    """A .zip opened for reading, every entry checked at the boundary before anything is read: no link, absolute
    name, "..", NUL or two names a Mac takes for one (equal after NFC and case folding; one name twice; a file and a
    folder of one name); no password; at most 200,000 entries; an entry over 1 MB compressed at most 100×, and all
    of them together at most 100× the file. files: {name: ZipInfo} in the file's order; folders: folder names (no
    "/" last). An entry's bytes are checked as they are read (digest)."""

    def __init__(self, path):
        self.path = Path(path)
        try:
            self.zf = zipfile.ZipFile(str(self.path))
        except (zipfile.BadZipFile, ValueError, EOFError):
            raise EngineError("“{}” is not a .zip file, or it is damaged.".format(self.path.name))
        try:
            self._entries()
        except BaseException:
            self.zf.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.zf.close()

    def _refuse(self, why, name):
        shown = name.replace("\0", "\\0")
        raise EngineError("“{}” was not used: it holds {} (“{}”).".format(
            self.path.name, why, shown if len(shown) <= 120 else shown[:117] + "…"))

    def _entries(self):
        infos = self.zf.infolist()
        if len(infos) > MAX_ENTRIES:
            raise EngineError("“{}” was not used: it holds more than {:,} files.".format(self.path.name, MAX_ENTRIES))
        self.files, self.folders, spelled, total = {}, set(), {}, 0
        for info in infos:
            name = _entry_name(info)
            folder = name.endswith("/")
            parts = (name[:-1] if folder else name).split("/")
            if "\0" in name:
                self._refuse("a name with a NUL character", name)
            if name.startswith("/") or any(p in ("", ".", "..") or ".." in p.split("\\") for p in parts):
                self._refuse("a name that points outside its folder", name)
            if stat.S_ISLNK(info.external_attr >> 16):
                self._refuse("a link", name)
            if info.flag_bits & 0x1:
                self._refuse("a password-protected file", name)
            if not folder and info.file_size > BIG and info.file_size > MAX_RATIO * info.compress_size:
                self._refuse("a file compressed more than {} times".format(MAX_RATIO), name)
            for i in range(1, len(parts) + 1):
                sub, is_folder = "/".join(parts[:i]), folder or i < len(parts)
                k = _key(sub)
                if k not in spelled:
                    spelled[k] = (sub, is_folder)
                elif spelled[k][0] != sub:
                    self._refuse("two names a Mac would take for one", sub)
                elif not (is_folder and spelled[k][1]):
                    self._refuse("one name twice", sub)
            if folder:
                self.folders.add("/".join(parts))
            else:
                self.files["/".join(parts)] = info
                total += info.file_size
        if total > BIG and total > MAX_RATIO * max(self.path.stat().st_size, 1):
            raise EngineError("“{}” was not used: its files are compressed more than {} times.".format(
                self.path.name, MAX_RATIO))

    def digest(self, name, sink=None, cancelled=_never):
        """Stream a file's bytes (sink(block) gets each): its SHA-256, or None when it is damaged: a bad CRC, more or
        fewer bytes than it declares, data that cannot be decompressed."""
        info, h, n = self.files[name], hashlib.sha256(), 0
        try:
            f = self.zf.open(info)
        except (zipfile.BadZipFile, NotImplementedError, zlib.error, EOFError):
            return None
        with f:
            while True:
                _stop(cancelled)
                try:
                    block = f.read(CHUNK)
                except (zipfile.BadZipFile, zlib.error, EOFError):
                    return None
                if not block:
                    break
                n += len(block)
                if n > info.file_size:
                    return None
                h.update(block)
                if sink:
                    sink(block)
        return h.hexdigest() if n == info.file_size else None

    def read(self, name):
        """A small file's bytes, or None when it is missing, over 32 MB or damaged."""
        if name not in self.files or self.files[name].file_size > MAX_LEDGER:
            return None
        out = bytearray()
        return bytes(out) if self.digest(name, out.extend) is not None else None

    def json(self, name):
        raw = self.read(name)
        try:
            return json.loads(raw.decode("utf-8")) if raw is not None else None
        except ValueError:
            return None


# --- writing ---------------------------------------------------------------------------------------------------

def _walk(real):
    """A review folder's plain files ([(name relative to it, full path)]) and empty folders ([name]), sorted; not
    .lock, links or anything but plain files and folders."""
    files, empty = [], []
    for root, dirs, names in os.walk(real):
        dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(root, d)))
        rel = os.path.relpath(root, real)
        kept = [n for n in sorted(names) if n not in SKIP and _plain(os.path.join(root, n))]
        files += [(n if rel == "." else rel + "/" + n, os.path.join(root, n)) for n in kept]
        if rel != "." and not kept and not dirs:
            empty.append(rel)
    return files, empty


def _plain(full):
    """Whether a file is a plain file: not when it is gone (a cache's temporary file that viewing, which takes no
    lock, renamed meanwhile)."""
    try:
        return stat.S_ISREG(os.lstat(full).st_mode)
    except FileNotFoundError:
        return False


def _size(full):
    try:
        return os.path.getsize(full)
    except FileNotFoundError:
        return 0


def _stored(full, size, cancelled):
    """Whether a file goes into the .zip stored, not deflated: one over 1 MB that deflates more than 100× (a blank
    picture), which _Zip would refuse as a zip bomb when the file is read back. Deflated as zipfile deflates, and only
    as far as it takes to tell (a PDF's first megabyte)."""
    if size <= BIG:
        return False
    c, out = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -15), 0
    with open(full, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            _stop(cancelled)
            out += len(c.compress(block))
            if size <= MAX_RATIO * out:
                return False
    return size > MAX_RATIO * (out + len(c.flush()))


def _add_file(zf, name, full, cancelled):
    """Stream a file into the .zip: (its size, its SHA-256)."""
    info = zipfile.ZipInfo.from_file(full, name, strict_timestamps=False)
    info.compress_type = zipfile.ZIP_STORED if _stored(full, info.file_size, cancelled) else zipfile.ZIP_DEFLATED
    h, n = hashlib.sha256(), 0
    with open(full, "rb") as f, zf.open(info, "w") as out:
        for block in iter(lambda: f.read(CHUNK), b""):
            _stop(cancelled)
            h.update(block)
            out.write(block)
            n += len(block)
    return n, h.hexdigest()


def _add_data(zf, name, data):
    info = zipfile.ZipInfo(name, time.localtime()[:6])
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(info, data)
    return len(data), hashlib.sha256(data).hexdigest()


def _add_folder(zf, name):
    info = zipfile.ZipInfo(name + "/", time.localtime()[:6])
    info.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
    zf.writestr(info, b"")


def _dump(data):
    return json.dumps(data, ensure_ascii=False, indent=1).encode("utf-8")


def _readme(backup):
    n = len(backup["papers"])
    made = backup["made_by"]
    return """Paperole {what}
Made {created} by {variant}{app}.

This file holds {n} review folder{s} and Paperole's data for {them}. To bring {them} back, use Import… in
Paperole: it shows what the file holds and compares each paper with yours before anything changes, and a copy of
yours that it replaces is kept.

Without Paperole:
- Each folder under students/ is one paper, under its student's name.
- rN/final.pdf is what the student received in round N, with your comments; rN/email.txt is the list of comments.
  rN/earlier/ holds what an earlier finish of round N gave, named for its time, when the round was resumed.
- rN/build/ holds the paper as it was compiled (the PDF your comments are placed on), rN/src the student's source as
  it was that round.
- ledger.json holds every comment and where it sits in each round; .history holds its earlier versions.
- app/ holds Paperole's tags{settings} and the unsent drafts of these papers.

To check that nothing was damaged: unzip the file, open Terminal in this folder and run
    shasum -a 256 -c manifest-sha256.txt
Every line should end in OK. backup.json lists what the file holds; its "manifest" "sha256" is the checksum of
manifest-sha256.txt.
""".format(what="automatic backup" if backup["kind"] == "automatic" else "export",
           created=datetime.datetime.fromisoformat(backup["created"]).strftime("on %Y-%m-%d at %H:%M"),
           variant=SHOWN.get(made.get("variant") or FORMAT, made.get("variant") or FORMAT), app=" {}".format(made["app"]) if made.get("app") else "",
           n=n, s="" if n == 1 else "s", them="it" if n == 1 else "them",
           settings=", settings" if backup["scope"] == "everything" else "")


def write(papers, dest, scope="chosen", kind="export", tags=None, drafts=None, settings=None, made_by=None,
          progress=None, cancelled=_never):
    """Write the export file dest (DATA.md §3): each paper's review folder streamed in under its lock, then the
    app's files, README.txt, manifest-sha256.txt and backup.json, into a temporary file beside dest that is read back
    against the checksums and only then named dest (replacing a file there; kind automatic: never, "dest 2.zip" …
    instead). A failure or cancel leaves nothing.
    papers: [{path, title, student}] (the app's list; a folder that is not there, or holds no ledger, is left out and
    named in backup.json's missing); tags: tags.json's content; drafts: {paper path: its drafts file's content};
    settings: the portable settings, only with scope everything; made_by: {variant, install, app}.
    Returns {"path", "bytes", "backup": backup.json's content}."""
    progress = progress or (lambda message: None)
    if scope not in SCOPES:
        raise EngineError("scope is everything or chosen.")
    if kind not in KINDS:
        raise EngineError("kind is export or automatic.")
    if not isinstance(papers, list) or not all(isinstance(p, dict) and isinstance(p.get("path"), str) for p in papers):
        raise EngineError("papers is a list of {path, title, student}.")
    if settings is not None and scope != "everything":
        raise EngineError("Settings go only into an export of everything.")
    drafts = drafts or {}
    if not isinstance(drafts, dict) or not all(isinstance(k, str) for k in drafts):
        raise EngineError("drafts maps a paper folder to its drafts.")
    made_by = made_by or {}
    if not isinstance(made_by, dict):
        raise EngineError("made_by is {variant, install, app}.")
    dest = Path(os.path.abspath(dest))
    folder = dest.parent
    if not folder.is_dir():
        raise EngineError("There is no folder {}.".format(folder))
    if dest.is_dir():
        raise EngineError("{} is a folder.".format(dest))
    if _in_review_folder(folder):  # any review folder, chosen or not: a file in a finished round is damage
        raise EngineError("Save the file outside the review folders: “{}” is in one.".format(folder))
    inside = os.path.realpath(str(folder))

    chosen, missing, seen = [], [], set()
    for p in papers:
        path = os.path.abspath(p["path"])
        real = os.path.realpath(path)
        if real in seen:
            continue
        seen.add(real)
        why = "The folder is not there." if not os.path.isdir(real) else \
            "There is no ledger.json in it." if not os.path.isfile(os.path.join(real, "ledger.json")) else None
        if why:
            missing.append({"path": path, "title": p.get("title"), "student": p.get("student"), "why": why})
            continue
        if inside == real or inside.startswith(real + os.sep):
            raise EngineError("Save the file outside the review folders: “{}” is one.".format(path))
        chosen.append((p, path, real))
    estimate = sum(_size(full) for _, _, real in chosen for _, full in _walk(real)[0]) \
        + len(_dump([tags, drafts, settings]))
    _room(folder, estimate)

    top = safe_name(dest.stem, "Paperole")
    fd, tmp = tempfile.mkstemp(dir=str(folder), prefix="." + dest.name + ".", suffix=".tmp")
    os.close(fd)
    try:
        listed, entries, students = [], [], {}
        taken_students, taken_folders = set(), {}
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, strict_timestamps=False) as zf:
            for i, (p, path, real) in enumerate(chosen):
                with ledger.locked(real):  # an edit meanwhile waits; nothing is caught half written
                    raw = Path(real, "ledger.json").read_bytes()
                    lg, _ = checks.read_ledger(raw)
                    info = lg["paper"] if lg else {}
                    title = info.get("title") or p.get("title") or Path(real).name
                    student = info.get("student") or p.get("student") or ""
                    progress("Writing “{}” ({} of {})…".format(title, i + 1, len(chosen)))
                    sdir = students.get(_key(student))
                    if sdir is None:
                        sdir = students[_key(student)] = _unique(safe_name(student, "Unknown student"), taken_students)
                    base = "students/{}/{}".format(sdir, _unique(safe_name(Path(real).name, "Paper"),
                                                                 taken_folders.setdefault(_key(sdir), set())))
                    files, empty = _walk(real)
                    size = 0
                    for rel, full in files:
                        _floor(folder)
                        try:  # nothing is in the .zip until the file is open
                            n, digest = _add_file(zf, "{}/{}/{}".format(top, base, rel), full, cancelled)
                        except FileNotFoundError:  # a cache's temporary file, renamed meanwhile (_plain)
                            continue
                        entries.append((base + "/" + rel, digest))
                        size += n
                    for rel in empty:
                        _add_folder(zf, "{}/{}/{}".format(top, base, rel))
                pid = ledger.paper_id(real, lg) if lg else None
                draft = drafts.get(p["path"], drafts.get(path))
                listed.append({"folder": base, "id": pid, "title": title, "student": student,
                               "rounds": len(lg["rounds"]) if lg else None,
                               "comments": len(lg["comments"]) if lg else None,
                               "ledger": {"rev": ledger.version(lg)[0] if lg else None,
                                          "sha256": hashlib.sha256(raw).hexdigest()},
                               "bytes": size, "draft": None, "was_at": path})
                if draft is not None:
                    listed[-1]["draft"] = "app/drafts/{}.json".format(pid or "paper-{}".format(i + 1))
                    entries.append((listed[-1]["draft"], _add_data(zf, top + "/" + listed[-1]["draft"],
                                                                   _dump(draft))[1]))
            _stop(cancelled)
            if tags is not None:
                entries.append(("app/tags.json", _add_data(zf, top + "/app/tags.json", _dump(tags))[1]))
            if settings is not None:
                entries.append(("app/settings.json", _add_data(zf, top + "/app/settings.json", _dump(settings))[1]))
            backup = {"schema": SCHEMA, "app": FORMAT, "kind": kind, "scope": scope, "created": ledger.now(),
                      "made_by": {"variant": made_by.get("variant"), "install": made_by.get("install"),
                                  "app": made_by.get("app"), "engine": _engine()},
                      "papers": listed, "missing": missing,
                      "tags": len(tags["tags"]) if isinstance(tags, dict) and isinstance(tags.get("tags"), list)
                      else None}
            entries.append(("README.txt", _add_data(zf, top + "/README.txt", _readme(backup).encode("utf-8"))[1]))
            manifest = "".join(disk.manifest_line(name, digest) for name, digest in sorted(entries)).encode("utf-8")
            pin = _add_data(zf, top + "/" + MANIFEST, manifest)[1]
            backup["manifest"] = {"sha256": pin, "files": len(entries)}
            last = _add_data(zf, top + "/" + BACKUP, _dump(backup))[1]

        progress("Checking…")
        want = {top + "/" + name: digest for name, digest in entries}
        want.update({top + "/" + MANIFEST: pin, top + "/" + BACKUP: last})
        with _Zip(tmp) as z:
            if set(z.files) != set(want):
                raise EngineError("The file did not read back as it was written, so it was not kept.")
            for name, digest in want.items():
                if z.digest(name, cancelled=cancelled) != digest:
                    raise EngineError("The file did not read back as it was written (“{}”), so it was not kept. The "
                                      "disk may be failing.".format(name))
        _stop(cancelled)
        # an automatic backup never replaces a file: another Mac backing up here may have named one so meanwhile
        name, n = dest, 1
        while kind == "automatic" and os.path.lexists(str(dest)):
            n += 1
            dest = name.with_name("{} {}{}".format(name.stem, n, name.suffix))
        disk.replace(tmp, dest)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return {"path": str(dest), "bytes": dest.stat().st_size, "backup": backup}


# --- reading ---------------------------------------------------------------------------------------------------

def _relative(name):
    return isinstance(name, str) and bool(name) and not name.startswith("/") and "\0" not in name \
        and not any(p in ("", ".", "..") for p in name.split("/"))


def _layout(z):
    """What a .zip holds: {"kind", "schema", "root" (the folder backup.json is in, "/" last, or ""), "backup",
    "papers": [{"folder", "prefix", "title", "student", "was_at", "draft", "facts"?, "bad"?}]}. kind: export or
    automatic (schema 2), backup (schema 1), folders (no backup.json: the review folders found up to three levels
    down). Refused: a kind for reading, a newer schema, a backup.json that cannot be read, no review folder."""
    marks = [n for n in z.files if n.rsplit("/", 1)[-1] == BACKUP and n.count("/") <= 1 and not _mac(n)]
    if len(marks) > 1:
        raise EngineError("“{}” holds more than one backup.json, so it was not used.".format(z.path.name))
    if not marks:
        ledgers = sorted(n[:-len("ledger.json")] for n in z.files
                         if n.rsplit("/", 1)[-1] == "ledger.json" and n.count("/") <= SEARCH_DEPTH and not _mac(n)
                         and REPLACED not in n.split("/"))
        prefixes = [p for p in ledgers if not any(q != p and p.startswith(q) for q in ledgers)]
        if not prefixes:
            raise EngineError("“{}” holds no review folder: there is no Paperole ledger (ledger.json) in "
                              "it.".format(z.path.name))
        return {"kind": "folders", "schema": None, "root": "", "backup": None,
                "papers": [{"folder": p[:-1], "prefix": p, "title": None, "student": None, "was_at": None,
                            "draft": None} for p in prefixes]}
    root = marks[0][:-len(BACKUP)]
    backup = z.json(marks[0])
    if not isinstance(backup, dict) or backup.get("app") not in FORMATS:
        raise EngineError("“{}” is not a Paperole export: its backup.json cannot be read.".format(z.path.name))
    schema = backup.get("schema")
    if isinstance(schema, int) and not isinstance(schema, bool) and schema > SCHEMA:
        raise EngineError("“{}” was made by a newer Paperole. Update Paperole to import it.".format(z.path.name))
    if schema == SCHEMA and backup.get("kind") == "reading":
        raise EngineError("“{}” holds PDFs and comments for reading; it cannot be imported.".format(z.path.name))
    if schema not in (1, SCHEMA) or (schema == SCHEMA and backup.get("kind") not in KINDS) \
            or not isinstance(backup.get("papers"), list):
        raise EngineError("“{}” is not a Paperole export: its backup.json cannot be read.".format(z.path.name))
    papers = []
    for i, p in enumerate(backup["papers"]):
        p = p if isinstance(p, dict) else {}
        ref = p.get("ref") if schema == 1 and isinstance(p.get("ref"), dict) else p
        folder = p.get("folder")
        entry = {"folder": folder if isinstance(folder, str) else "paper {}".format(i + 1),
                 "prefix": root + folder + "/" if _relative(folder) else None,
                 "title": ref.get("title"), "student": ref.get("student"),
                 "was_at": ref.get("path") if schema == 1 else p.get("was_at"),
                 "draft": p.get("draft") if schema == SCHEMA else None}
        if schema == 1:
            entry["facts"] = {"finished": ref.get("finished"), "buckets": ref.get("buckets"),
                              "key_page": ref.get("keyPage")}
        if entry["prefix"] is None or _mac(folder) or (schema == 1 and folder.split("/")[0] != "papers"):
            entry["bad"] = "backup.json names its folder in a way that cannot be used."
            entry["prefix"] = None
        papers.append(entry)
    return {"kind": backup["kind"] if schema == SCHEMA else "backup", "schema": schema, "root": root,
            "backup": backup, "papers": papers}


def _verify(z, layout, cancelled, only=""):
    """Every file's bytes checked: ({name: SHA-256, or None when damaged}, [{"file", "problem"}], whether every file
    could be checked against a checksum). Schema 2: against manifest-sha256.txt, pinned by backup.json (damaged,
    missing, extra); otherwise each entry's CRC. only: the files under that prefix (one paper's: unpack), the list of
    checksums still checked against its pin."""
    digests, problems, root = {}, [], layout["root"]
    expected = None
    if layout["schema"] == SCHEMA:
        pin = layout["backup"].get("manifest")
        raw = z.read(root + MANIFEST)
        if raw is None or not isinstance(pin, dict) or hashlib.sha256(raw).hexdigest() != pin.get("sha256"):
            return None, [{"file": MANIFEST, "problem": "damaged"}], False
        lines, damaged = disk.parse_manifest(raw.decode("utf-8", "replace"))
        if damaged:  # a line that cannot be read names a file that might be missing: nothing can be trusted
            return None, [{"file": MANIFEST, "problem": "damaged"}], False
        expected = {root + name: digest for name, digest in lines}
    for name in z.files:
        if not name.startswith(root) or _mac(name[len(root):]) or name in (root + MANIFEST, root + BACKUP) \
                or not name.startswith(only):
            continue
        digests[name] = d = z.digest(name, cancelled=cancelled)
        if expected is not None and name not in expected:
            problems.append({"file": name[len(root):], "problem": "extra"})
        elif d is None or (expected is not None and d != expected[name]):
            problems.append({"file": name[len(root):], "problem": "damaged"})
    for name in expected or ():
        if name not in z.files and name.startswith(only):
            problems.append({"file": name[len(root):], "problem": "missing"})
    return digests, problems, expected is not None


def _facts(lg, saved=None):
    """What the preview shows of a copy: title, student, its latest round, open or not, comments, last saved."""
    p, last = lg["paper"], (lg["rounds"][-1] if lg["rounds"] else None)
    return {"title": p.get("title"), "student": p.get("student"), "round": last["n"] if last else None,
            "open": bool(last) and not last.get("closed"), "comments": len(lg["comments"]),
            "saved": lg["saved"] if isinstance(lg.get("saved"), str) else saved}


def _when(t):
    return datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def _rounds(z, prefix, lg, files):
    """check.py's per-round checks on a copy inside a file, from its entries ({name relative to the folder: (size,
    SHA-256)}): source, build PDF and final.pdf there, a finished round's checksums (hidden files not compared, as
    disk.verify_manifest), the files kept from earlier finishes (check.kept_changed), analysis.json in step. A PDF is
    not opened here (its checksum says whether it is intact)."""
    out, problem = [], checks._problem
    for r in lg["rounds"]:
        n = r["n"]
        rp = "r{}".format(n)
        if not any(f.startswith(rp + "/src/") for f in files):
            out.append(problem("source_missing", "Round {}'s source is missing.".format(n), n, [rp + "/src"]))
        b = r.get("build") if isinstance(r.get("build"), dict) else {}
        outside = [b[k] for k in ("pdf", "log") if b.get(k) is not None and not checks._relative(b[k], (rp,))]
        if outside:
            out.append(problem("path_outside_round", "Round {}'s build is named outside its folder.".format(n), n,
                               [str(v) for v in outside]))
        pdf = b.get("pdf")
        if pdf is not None and pdf not in outside and not files.get(pdf, (0,))[0]:
            out.append(problem("build_pdf_missing", "Round {}'s PDF is missing.".format(n), n, [pdf]))
        if r.get("closed"):
            if not files.get(rp + "/final.pdf", (0,))[0]:
                out.append(problem("final_pdf_missing", "Round {}'s final.pdf is missing.".format(n), n,
                                   [rp + "/final.pdf"]))
            m = rp + "/" + disk.MANIFEST
            if m in files:
                raw = z.read(prefix + m)
                lines, damaged = disk.parse_manifest(raw.decode("utf-8", "replace")) if raw is not None else ([], True)
                listed = {rp + "/" + name for name, _ in lines}
                wrong = ([m] if damaged else []) + [rp + "/" + name for name, d in lines
                                                    if not disk.hidden(name)
                                                    and files.get(rp + "/" + name, (0, None))[1] != d]
                wrong += sorted(f for f in files if f.startswith(rp + "/src/") and f not in listed
                                and not disk.hidden(f))
                if wrong:
                    out.append(problem("round_changed", "Round {} has changed since it was finished.".format(n), n,
                                       wrong))
        kept = checks.kept_changed(r, lambda f: files[f][1] if f in files else None,
                                   lambda f: (z.read(prefix + f) or b"").decode("utf-8", "replace") if f in files
                                   else None)
        if kept:
            out.append(problem("earlier_changed", "Files kept from an earlier finish of Round {} are missing or "
                                                  "changed.".format(n), n, kept))
        want = r.get("analysis_sha256")
        if isinstance(want, str) and rp + "/analysis.json.new" not in files \
                and files.get(rp + "/analysis.json", (0, None))[1] != want:
            out.append(problem("analysis_out_of_step", "Round {}'s list of changes is not the one the ledger "
                                                       "records.".format(n), n, [rp + "/analysis.json"]))
    return out


def _damage(problems):
    return [p for p in problems if p["code"] not in QUIET]


WHY = {"damaged": "A file in it is damaged: {}.", "missing": "A file of it is missing from this file: {}.",
       "extra": "It holds a file that was not in it when this file was made: {}."}


def _incoming(z, entry, digests, problems):
    """A review folder inside a file: (why it cannot be imported, or None; its ledger; check's problems)."""
    prefix = entry["prefix"]
    if prefix is None:
        return entry["bad"], None, []
    rel = len(prefix)  # names below are relative to the review folder
    bad = [p for p in problems if p["file"] != MANIFEST and (entry["root"] + p["file"]).startswith(prefix)]
    if bad:
        return WHY[bad[0]["problem"]].format((entry["root"] + bad[0]["file"])[rel:]), None, []
    if digests is None:
        return "The file's list of checksums is damaged, so nothing in it can be trusted.", None, []
    led = prefix + "ledger.json"
    if led not in z.files:
        return "There is no ledger.json in it.", None, []
    if z.files[led].file_size > MAX_LEDGER:
        return "Its ledger is larger than 32 MB.", None, []
    raw = z.read(led)
    lg, bad = checks.read_ledger(raw) if raw is not None else (None, {"code": "ledger_unreadable"})
    if bad:
        return ("Its ledger was written by a newer Paperole." if bad["code"] == "ledger_too_new"
                else "Its ledger cannot be read."), None, []
    files = {n[rel:]: (z.files[n].file_size, digests.get(n)) for n in z.files if n.startswith(prefix)}
    return None, lg, checks._comments(lg) + _rounds(z, prefix, lg, files)


def _listed(papers):
    """The app's list, [{path, id?}], as [{"path", "real", "id", "lg", "there"}]: each folder's id read from its ledger,
    else the one the app gave; real: the place with its links resolved ("/tmp/…" and "/private/tmp/…" are one)."""
    if not isinstance(papers, list) or not all(isinstance(p, dict) and isinstance(p.get("path"), str)
                                               and isinstance(p.get("id"), (str, type(None))) for p in papers):
        raise EngineError("papers is a list of {path, id}.")
    out = []
    for p in papers:
        path = os.path.abspath(p["path"])
        there = os.path.isdir(path)
        lg = None
        if there:
            with contextlib.suppress(OSError):
                lg = checks.read_ledger(Path(path, "ledger.json").read_bytes())[0]
        # the ledger's own id while it reads; the app's for a folder gone or a ledger that cannot be read
        pid = (ledger.paper_id(path, lg) if lg else None) or p.get("id")
        out.append({"path": path, "real": os.path.realpath(path), "id": pid, "lg": lg, "there": there})
    return out


def _same_paper(a, b):
    """Whether two ledgers with one id are one paper: made at the same moment, round 1 received at the same moment
    (a title or a student's name may have been corrected since; the trail tells versions apart)."""
    def first(lg):
        return lg["rounds"][0].get("created") if lg["rounds"] else None
    return a["paper"].get("created") == b["paper"].get("created") \
        and (first(a) == first(b) or None in (first(a), first(b)))


def _status(out, lg, problems, listed, ids):
    """Set a readable copy's status (DATA.md §5.3) against the app's list: new (found: yours still at was_at but not
    listed, _unlisted), put_back (listed, its folder gone), same, older, newer, diverged (both changed, or no telling),
    different_paper (the same id, another paper; also a second paper with one id in a file), yours_damaged (your copy
    fails the check, this one passes)."""
    pid = out["id"]
    if pid in ids:
        out.update(status="different_paper", reason="Another paper in this file has the same id.")
        return
    ids.add(pid)
    was_at = os.path.abspath(out["was_at"]) if isinstance(out["was_at"], str) and out["was_at"].startswith("/") \
        else None
    match = [p for p in listed if p["id"] == pid]
    match = [p for p in match if p["there"]] or match \
        or [p for p in listed if was_at and p["real"] == os.path.realpath(was_at) and p["id"] is None]
    if not match:
        out["status"] = "new"
        if not out["in_place"]:
            out["found"] = _unlisted(was_at, pid, lg)
        return
    yours = match[0]
    out["listed"] = yours["path"]
    if not yours["there"]:
        out["status"] = "put_back"
        return
    same = out["in_place"] and yours["real"] == os.path.realpath(out["folder"])  # a folder listed where it is
    out["yours_problems"] = problems if same else checks.paper(yours["path"])
    if yours["lg"] is not None:
        out["yours"] = _facts(yours["lg"], _when(os.path.getmtime(os.path.join(yours["path"], "ledger.json"))))
        if not _same_paper(lg, yours["lg"]):
            out["status"] = "different_paper"
            return
    if _damage(out["yours_problems"]) and not _damage(problems):
        out["status"] = "yours_damaged"
    elif yours["lg"] is None:
        out["status"] = "diverged"
    else:
        out["status"] = ledger.compare(lg, yours["lg"])


def _unlisted(was_at, pid, lg):
    """was_at when the folder there is this very paper and the list does not name it (the list lost, or the paper
    removed from it): yours is still where it was, so the copy in the file is not yours to replace it with."""
    if not was_at or not os.path.isdir(was_at):
        return None
    try:
        theirs = checks.read_ledger(Path(was_at, "ledger.json").read_bytes())[0]
    except OSError:
        return None
    if theirs is None or ledger.paper_id(was_at, theirs) != pid or not _same_paper(lg, theirs):
        return None
    return was_at


def _blank(folder, in_place, title=None, student=None, was_at=None):
    return {"folder": folder, "in_place": in_place, "id": None, "title": title, "student": student, "was_at": was_at,
            "status": "cannot_import", "reason": None, "listed": None, "found": None, "this": None, "yours": None,
            "problems": [], "draft": None}


def search(root):
    """The review folders at root, or up to three levels under it: not inside one found, a hidden folder, a link or
    Replaced by Import (the copies Import kept). Sorted by path."""
    root = Path(root)
    if (root / "ledger.json").is_file():
        return [root]
    out = []

    def walk(folder, depth):
        try:
            items = sorted(os.scandir(str(folder)), key=lambda e: e.name)
        except OSError:
            return
        for e in items:
            if e.name.startswith(".") or e.name == REPLACED or not e.is_dir(follow_symlinks=False):
                continue
            if os.path.isfile(os.path.join(e.path, "ledger.json")):
                out.append(Path(e.path))
            elif depth < SEARCH_DEPTH:
                walk(e.path, depth + 1)
    walk(root, 1)
    return out


def _folders(root, listed, progress, cancelled):
    """check of a folder on disk: the review folders found, each listed where it is."""
    found = search(root)
    if not found:
        raise EngineError("There is no review folder in “{}” or the three levels of folders under it.".format(root))
    papers, ids = [], set()
    for i, f in enumerate(found):
        _stop(cancelled)
        progress("Checking “{}” ({} of {})…".format(f.name, i + 1, len(found)))
        out = _blank(str(f), True, was_at=str(f))
        out["problems"] = checks.paper(f)
        try:
            raw = (f / "ledger.json").read_bytes()
        except OSError:
            raw = b""
        lg, bad = checks.read_ledger(raw)
        if bad:
            out["reason"] = "Its ledger was written by a newer Paperole." if bad["code"] == "ledger_too_new" \
                else "Its ledger cannot be read."
        else:
            out.update(id=ledger.paper_id(f, lg), title=lg["paper"].get("title"), student=lg["paper"].get("student"),
                       this=_facts(lg, _when(os.path.getmtime(str(f / "ledger.json")))), reason=None)
            _status(out, lg, out["problems"], listed, ids)
        papers.append(out)
    damaged = any(p["status"] == "cannot_import" or _damage(p["problems"]) for p in papers)
    return {"kind": "folders", "zip": False, "schema": None, "created": None, "made_by": None, "scope": None,
            "intact": not damaged, "checked": False, "problems": [], "missing": [], "tags": None, "settings": None,
            "papers": papers}


def check(path, papers=(), progress=None, cancelled=_never):
    """What a file or folder holds, read without unpacking (DATA.md §5.2), each paper compared with the app's list
    (papers: [{path, id?}]). See CONTRACT.md amendment "Export and import files" for the reply."""
    progress = progress or (lambda message: None)
    listed = _listed(list(papers))
    source = Path(os.path.abspath(path))
    if source.is_dir():
        return _folders(source, listed, progress, cancelled)
    if not source.is_file():
        raise EngineError("There is no file {}.".format(source))
    progress("Checking “{}”…".format(source.name))
    with _Zip(source) as z:
        layout = _layout(z)
        digests, problems, checked = _verify(z, layout, cancelled)
        root, backup = layout["root"], layout["backup"] or {}
        drafts_v1 = {}
        if layout["schema"] == 1:
            for name in z.files:
                if name.startswith(root + "app/drafts/") and name.endswith(".json"):
                    d = z.json(name)
                    if isinstance(d, dict) and isinstance(d.get("paper"), str):
                        drafts_v1.setdefault(d["paper"], d)
        out_papers, ids = [], set()
        for entry in layout["papers"]:
            _stop(cancelled)
            entry["root"] = root
            out = _blank(entry["folder"], False, entry["title"], entry["student"], entry["was_at"])
            if "facts" in entry:
                out["facts"] = entry["facts"]
            why, lg, found = _incoming(z, entry, digests, problems)
            out["problems"] = found
            if why:
                out["reason"] = why
            else:
                led = z.files[entry["prefix"] + "ledger.json"]
                out.update(id=lg["paper"].get("id") or _derived(z, entry["prefix"], lg), title=lg["paper"].get("title"),
                           student=lg["paper"].get("student"),
                           this=_facts(lg, _when(time.mktime(led.date_time + (0, 0, -1)))))
                _status(out, lg, found, listed, ids)
            draft = entry["draft"]
            if layout["schema"] == 1:
                out["draft"] = drafts_v1.get(entry["was_at"])
            elif isinstance(draft, str) and _relative(draft) and digests is not None \
                    and not any(p["file"] == draft for p in problems):
                out["draft"] = z.json(root + draft)
            out_papers.append(out)

        def app_file(name):
            if digests is None or any(p["file"] == name for p in problems):
                return None
            return z.json(root + name)
        settings = app_file("app/settings.json") if layout["schema"] == SCHEMA else None
        damaged = digests is None or bool(problems) or any(
            p["status"] == "cannot_import" or _damage(p["problems"]) for p in out_papers)
        return {"kind": layout["kind"], "zip": True, "schema": layout["schema"], "created": backup.get("created"),
                "made_by": backup.get("made_by") if isinstance(backup.get("made_by"), dict) else None,
                "scope": backup.get("scope"), "intact": not damaged, "checked": checked, "problems": problems[:100],
                "missing": backup.get("missing") if isinstance(backup.get("missing"), list) else [],
                "tags": app_file("app/tags.json"), "settings": settings, "papers": out_papers}


def info(paths):
    """What each file says it holds, from its backup.json alone: nothing else is read or checked, so it is quick on a
    folder of backups (the app's rotation of its automatic backups, and the newest backup holding a paper). Every
    entry is still checked at the boundary (_Zip). Returns {"files": [{"path", "backup" (null without one)} |
    {"path", "error"}]}, in the order given."""
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise EngineError("paths is a list of files.")
    out = []
    for path in paths:
        try:
            if not os.path.isfile(path):
                raise EngineError("There is no file {}.".format(path))
            with _Zip(path) as z:
                out.append({"path": path, "backup": _layout(z)["backup"]})
        except (EngineError, OSError) as e:
            out.append({"path": path, "error": str(e)})
    return {"files": out}


def _derived(z, prefix, lg):
    """ledger.derived_id of a ledger without an id, from r1/src's names and sizes in the file (as they will be once
    unpacked)."""
    src = prefix + "r1/src/"
    return ledger.derived_id(None, lg, sorted((n[len(src):], z.files[n].file_size) for n in z.files
                                              if n.startswith(src)))


# --- unpacking and swapping ------------------------------------------------------------------------------------

def _in_review_folder(folder):
    """Whether a folder is a review folder or inside one: it or a folder above it holds a ledger.json Paperole
    reads (or a newer one's)."""
    real = Path(os.path.realpath(str(folder)))
    for d in (real,) + tuple(real.parents):
        try:
            raw = (d / "ledger.json").read_bytes()
        except OSError:
            continue
        lg, bad = checks.read_ledger(raw)
        if lg is not None or bad["code"] == "ledger_too_new":
            return True
    return False


def unpack(path, paper, dest, fork=False, copy=False, progress=None, cancelled=_never):
    """Take one paper out of a file (paper: its folder as check names it) into a new folder in dest, named as its
    folder was ("… 2" when taken), with the same refusals as check and the paper's files checked first: written into
    a hidden folder in dest, each file synced and read back from the disk, then renamed into place. fork: a new id
    (the file's kept in forked_from: a second copy of a listed paper); copy: Keep Both, also " (copy)" after the
    title. A failure or cancel leaves nothing. Returns {"path", "id", "problems": check's on the new folder}."""
    progress = progress or (lambda message: None)
    dest = Path(os.path.abspath(dest))
    if not dest.is_dir():
        raise EngineError("There is no folder {}.".format(dest))
    if _in_review_folder(dest):  # never into a round's src (a place taken from a file's was_at)
        raise EngineError("Choose a folder outside the review folders: “{}” is in one.".format(dest))
    source = Path(os.path.abspath(path))
    if not source.is_file():
        raise EngineError("There is no file {}.".format(source))
    with _Zip(source) as z:
        layout = _layout(z)
        entry = next((p for p in layout["papers"] if p["folder"] == paper), None)
        if entry is None:
            raise EngineError("There is no paper “{}” in “{}”.".format(paper, source.name))
        entry["root"] = layout["root"]
        prefix = entry["prefix"] or ""
        progress("Checking “{}”…".format(entry["title"] or paper))
        digests, problems, _ = _verify(z, layout, cancelled, prefix)  # this paper's files only
        why, lg, _ = _incoming(z, entry, digests, problems)
        if why:
            raise EngineError("“{}” was not imported. {}".format(entry["title"] or paper, why))
        names = [n for n in z.files if n.startswith(prefix) and not _mac(n[len(prefix):])]
        empty = [f[len(prefix):] for f in z.folders if (f + "/").startswith(prefix) and f + "/" != prefix
                 and not _mac(f[len(prefix):])]
        _room(dest, sum(z.files[n].file_size for n in names))
        title = lg["paper"].get("title")
        name = safe_name(paper.rsplit("/", 1)[-1] if paper else title, "Paper")
        progress("Unpacking “{}”…".format(title or name))
        staging = Path(tempfile.mkdtemp(prefix=STAGING, dir=str(dest)))
        final = None
        try:
            for rel in empty:
                staging.joinpath(*rel.split("/")).mkdir(parents=True, exist_ok=True)
            for n in names:
                info = z.files[n]
                target = staging.joinpath(*n[len(prefix):].split("/"))
                target.parent.mkdir(parents=True, exist_ok=True)
                _floor(dest)
                fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "wb") as f:
                    got = z.digest(n, f.write, cancelled)
                    f.flush()
                    os.fsync(f.fileno())
                if got is None or got != digests[n]:
                    raise EngineError("“{}” is damaged in this file, so the paper was not imported.".format(
                        n[len(prefix):]))
                mode = (info.external_attr >> 16) & 0o777 or 0o644
                os.chmod(str(target), (mode & 0o755) | 0o400)
                t = time.mktime(info.date_time + (0, 0, -1))
                os.utime(str(target), (t, t))
            progress("Checking…")
            for n in names:  # read back from the disk
                _stop(cancelled)
                if disk.sha256(staging.joinpath(*n[len(prefix):].split("/"))) != digests[n]:
                    raise EngineError("“{}” did not read back from the disk as it was written, so the paper was not "
                                      "imported. The disk may be failing.".format(n[len(prefix):]))
            pid = ledger.paper_id(staging, lg)
            if fork or copy:
                with ledger.edit(staging) as new:
                    p = new["paper"]
                    p["forked_from"], p["id"] = p["id"], ledger.new_paper_id()
                    if copy:
                        p["title"] = "{} (copy)".format(p.get("title") or name)
                    pid = p["id"]
            _stop(cancelled)
            disk._sync_folder(staging)
            final = _claim(dest, name)
            os.rename(str(staging), str(final))
            disk._sync_folder(dest)
        except BaseException:
            shutil.rmtree(str(staging), ignore_errors=True)
            if final is not None:
                with contextlib.suppress(OSError):
                    final.rmdir()  # only while it is the empty folder _claim made
            raise
    return {"path": str(final), "id": pid, "problems": checks.paper(final)}


def swap_in(incoming, current):
    """Use This Copy (DATA.md §5.4): under the paper's lock, rename the current review folder to "Replaced by
    Import/<name> <YYYY-MM-DD>" beside it ("… 2" when taken), then the incoming folder into its place; both on one
    disk, so each step is a rename. A failure undoes what was done. Returns {"path", "replaced"}."""
    incoming, current = Path(os.path.abspath(incoming)), Path(os.path.abspath(current))
    if not (incoming / "ledger.json").is_file():
        raise EngineError("{} is not a Paperole paper folder (no ledger.json).".format(incoming))
    if not current.is_dir():  # yours may have lost its ledger.json: the copy is to put it right
        raise EngineError("There is no folder {}.".format(current))
    real_in, real_cur = os.path.realpath(str(incoming)), os.path.realpath(str(current))
    if real_in == real_cur or real_in.startswith(real_cur + os.sep) or real_cur.startswith(real_in + os.sep):
        raise EngineError("The copy to use and yours must be two folders, neither inside the other.")
    if os.stat(str(incoming)).st_dev != os.stat(str(current.parent)).st_dev:
        raise EngineError("The copy to use must be on the same disk as yours.")
    with ledger.locked(current):
        aside_folder = current.parent / REPLACED
        made = not aside_folder.exists()
        aside_folder.mkdir(exist_ok=True)
        aside = _claim(aside_folder, "{} {}".format(current.name, datetime.date.today().isoformat()))
        try:
            os.rename(str(current), str(aside))
        except BaseException:
            with contextlib.suppress(OSError):
                aside.rmdir()
                if made:
                    aside_folder.rmdir()
            raise
        try:
            os.rename(str(incoming), str(current))
        except BaseException:
            try:
                os.rename(str(aside), str(current))
            except OSError:
                raise EngineError("The copy could not be put in place, and yours could not be moved back: it is in "
                                  "{}.".format(aside))
            with contextlib.suppress(OSError):
                if made:
                    aside_folder.rmdir()
            raise
    disk._sync_folder(aside_folder)
    disk._sync_folder(current.parent)
    return {"path": str(current), "replaced": str(aside)}
