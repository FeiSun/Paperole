"""The quiet check of a review folder (design/data/DATA.md §6.3): what is wrong, read only. It takes no lock and writes
nothing (not even .lock), so it may run on any folder at any time; a problem is reported, never repaired, and it
reads no file iCloud removed from this Mac (reading one would download it).

A problem is {"code", "message", "round": n or null, "files": [paths relative to the folder; ledger.json for a
comment's]}. Codes:
- `missing_folder`; `no_ledger`, `ledger_unreadable`, `ledger_too_new` (then the ledger's own checks are skipped;
  `ledger_unreadable` also for a comment whose rounds are not an object, beside the other checks);
- `source_missing` (rN/src missing or empty), `build_pdf_missing` (named by the ledger, missing or empty),
  `build_pdf_damaged` (it cannot be opened), `page_count` (not the ledger's count), `final_pdf_missing` (a closed
  round's, or empty);
- `round_changed`: a finished round whose files fail its checksums (changed, missing, or extra in src);
- `earlier_changed`: files kept from a round's earlier finish (rN/earlier/, Resume) missing, or not those its kept
  checksums list;
- `analysis_out_of_step`: a round's analysis.json is not the one its ledger records;
- `duplicate_ids`, `ids_beyond_last_seq`: comment ids used twice, or beyond their round's last_seq;
- `path_outside_round`: a build path not in its round's folder, or an anchor's file absolute or with "..";
- `leftovers`: what a crashed call left (temporary files, rN.old, a staged analysis.json) over 10 minutes ago;
- `orphans`: round folders kept in .orphans; `conflict_copies`: copies of the ledger a sync service made
  ("ledger 2.json"); `evicted`: files iCloud removed from this Mac."""
import json
import os
import re
import time
from pathlib import Path, PurePosixPath

import pymupdf

from . import disk, ledger

SETTLED = 10 * 60  # a temporary file younger than this may belong to a call still running
DATALESS = 0x40000000  # SF_DATALESS: a file whose data iCloud removed from this Mac


def _problem(code, message, n=None, files=()):
    return {"code": code, "message": message, "round": n, "files": list(files)}


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _relative(path, prefix=()):
    """Whether a path from the ledger is relative, without "..", and starts with the parts prefix."""
    if not isinstance(path, str) or not path or "\0" in path:
        return False
    parts = PurePosixPath(path).parts
    return not path.startswith("/") and ".." not in parts and parts[:len(prefix)] == tuple(prefix)


def _old(p, now):
    try:
        return now - os.lstat(str(p)).st_mtime > SETTLED
    except OSError:
        return False


def _folder(paper, now):
    """The folder's own problems (no ledger needed), and the set of its files iCloud removed (relative paths)."""
    out, leftovers, conflicts, evicted = [], [], [], set()
    for root, dirs, files in os.walk(str(paper)):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, str(paper))
            m = re.fullmatch(r"\.(.+)\.icloud", name)
            if m:  # the placeholder an older macOS leaves
                evicted.add(os.path.join(os.path.dirname(rel), m.group(1)) if os.path.dirname(rel) else m.group(1))
                continue
            try:
                if getattr(os.lstat(full), "st_flags", 0) & DATALESS:
                    evicted.add(rel)
            except OSError:  # gone meanwhile
                pass
    for p in paper.iterdir():
        name = p.name
        if (name.endswith(".tmp") or re.fullmatch(r"r\d+\.old(-[0-9a-f]{12})?", name)) and _old(p, now):
            leftovers.append(name)
        elif name != "ledger.json" and re.fullmatch(r"ledger\b.*\.json", name, re.I):
            conflicts.append(name)
        elif re.fullmatch(r"r\d+|\.history", name) and p.is_dir():
            leftovers += [q.relative_to(paper).as_posix() for q in p.iterdir()
                          if (q.name.endswith(".tmp") or q.name == "analysis.json.new") and _old(q, now)]
    orphans = sorted(p.name for p in (paper / ".orphans").iterdir()) if (paper / ".orphans").is_dir() else []
    if leftovers:
        out.append(_problem("leftovers", "A call that stopped part way left files behind.", files=sorted(leftovers)))
    if orphans:
        out.append(_problem("orphans", "Round folders the ledger does not name are kept in .orphans.",
                            files=[".orphans/" + o for o in orphans]))
    if conflicts:
        out.append(_problem("conflict_copies", "There are other copies of the ledger beside it.",
                            files=sorted(conflicts)))
    if evicted:
        out.append(_problem("evicted", "iCloud removed some of the folder's files from this Mac.",
                            files=sorted(evicted)))
    return out, evicted


def _round(paper, r, evicted):
    """The problems of one round of the ledger."""
    out, n = [], r["n"]
    rdir, prefix = paper / "r{}".format(n), "r{}".format(n)
    away = {f for f in evicted if f.startswith(prefix + "/")}
    src = rdir / "src"
    if not src.is_dir() or not (any(f.startswith(prefix + "/src/") for f in away)
                                or any(p.is_file() for p in src.rglob("*"))):
        out.append(_problem("source_missing", "Round {}'s source is missing.".format(n), n, [prefix + "/src"]))
    b = r.get("build") if isinstance(r.get("build"), dict) else {}
    outside = [b[k] for k in ("pdf", "log") if b.get(k) is not None and not _relative(b[k], (prefix,))]
    if outside:
        out.append(_problem("path_outside_round", "Round {}'s build is named outside its folder.".format(n), n,
                            [str(v) for v in outside]))
    pdf = b.get("pdf")
    if pdf is not None and pdf not in outside and pdf not in away:
        f = paper / pdf
        if not f.is_file() or f.stat().st_size == 0:
            out.append(_problem("build_pdf_missing", "Round {}'s PDF is missing.".format(n), n, [pdf]))
        else:
            try:
                with pymupdf.open(str(f)) as doc:
                    pages = doc.page_count
            except Exception:
                out.append(_problem("build_pdf_damaged", "Round {}'s PDF cannot be opened.".format(n), n, [pdf]))
            else:
                if _int(b.get("pages")) and pages != b["pages"]:
                    out.append(_problem("page_count", "Round {}'s PDF has {} pages, not {}.".format(
                        n, pages, b["pages"]), n, [pdf]))
    if r.get("closed"):
        final = rdir / "final.pdf"
        if prefix + "/final.pdf" not in away and (not final.is_file() or final.stat().st_size == 0):
            out.append(_problem("final_pdf_missing", "Round {}'s final.pdf is missing.".format(n), n,
                                [prefix + "/final.pdf"]))
        found = disk.verify_manifest(rdir) if not away else None
        if found and any(found.values()):
            out.append(_problem("round_changed", "Round {} has changed since it was finished.".format(n), n,
                                [prefix + "/" + f for f in found["changed"] + found["missing"] + found["extra"]]))
    kept = kept_changed(r, lambda f: disk.sha256(paper / f) if (paper / f).is_file() else None,
                        lambda f: (paper / f).read_bytes().decode("utf-8", "replace") if (paper / f).is_file()
                        else None, away)
    if kept:
        out.append(_problem("earlier_changed", "Files kept from an earlier finish of Round {} are missing or "
                                               "changed.".format(n), n, kept))
    want = r.get("analysis_sha256")
    a = rdir / "analysis.json"
    if isinstance(want, str) and prefix + "/analysis.json" not in away and not (rdir / "analysis.json.new").exists() \
            and (not a.is_file() or disk.sha256(a) != want):
        out.append(_problem("analysis_out_of_step", "Round {}'s list of changes is not the one the ledger "
                                                    "records.".format(n), n, [prefix + "/analysis.json"]))
    return out


def kept_changed(r, digest, text, away=()):
    """The files kept from round r's earlier finishes (its `finishes`: Resume moved them into rN/earlier/) that are
    missing or changed, relative to the paper folder, sorted: each one a finish names must be in rN/earlier/ and there
    (digest(name): its SHA-256, None when missing), and its final.pdf and email.txt what that finish's kept checksums
    list (text(name): their text, None when missing; a line that cannot be read names the checksums). A name in away
    (iCloud removed it) is not read. Also for a copy inside an export file (archive.py)."""
    where, bad = ("r{}".format(r["n"]), "earlier"), set()
    for f in r.get("finishes") or ():
        if not isinstance(f, dict):
            continue
        names = {k: f[k] for k in ("final", "email", "manifest") if f.get(k) is not None}
        m = names.get("manifest")
        raw = text(m) if _relative(m, where) and m not in away else None
        entries, damaged = disk.parse_manifest(raw) if raw is not None else ([], False)
        listed = dict(entries)
        if damaged:
            bad.add(m)
        for k, name in names.items():
            if not _relative(name, where) or len(PurePosixPath(name).parts) != 3:
                bad.add(str(name))
            elif name not in away:
                d = digest(name)
                want = listed.get({"final": "final.pdf", "email": "email.txt"}.get(k))
                if d is None or (want is not None and d != want.lower()):
                    bad.add(name)
    return sorted(bad)


def _comments(lg):
    """Duplicate ids, ids beyond their round's last_seq, anchors whose file is outside the round's source."""
    out, seen, dups, beyond, outside, unread = [], set(), [], [], [], []
    last = {r["n"]: r.get("last_seq") for r in lg["rounds"]}
    for c in lg["comments"]:
        cid = c.get("id") if isinstance(c, dict) else None
        if cid in seen:
            dups.append(cid)
        seen.add(cid)
        m = re.fullmatch(r"R(\d+)-(\d+)", cid) if isinstance(cid, str) else None
        if not m or not _int(last.get(int(m.group(1)))) or int(m.group(2)) > last[int(m.group(1))]:
            beyond.append(str(cid))
        rounds = (c.get("rounds") or {}) if isinstance(c, dict) else {}
        if not isinstance(rounds, dict):  # a hand edit, a half-merged copy: the engine cannot read the comment
            unread.append(str(cid))
            continue
        for k, rec in rounds.items():
            a = rec.get("anchor") if isinstance(rec, dict) else None
            if isinstance(a, dict) and a.get("file") is not None and not _relative(a["file"]):
                outside.append("{} (round {}): {}".format(cid, k, a["file"]))
    if dups:
        out.append(_problem("duplicate_ids", "Comment ids are used twice: {}.".format(", ".join(map(str, dups))),
                            files=["ledger.json"]))
    if beyond:
        out.append(_problem("ids_beyond_last_seq", "Comment ids were never given out: {}.".format(", ".join(beyond)),
                            files=["ledger.json"]))
    if outside:
        out.append(_problem("path_outside_round", "Comments name files outside their round: {}.".format(
            "; ".join(outside)), files=["ledger.json"]))
    if unread:
        out.append(_problem("ledger_unreadable", "The ledger cannot be read: the rounds of {} are "
                                                 "damaged.".format(", ".join(unread)), files=["ledger.json"]))
    return out


def read_ledger(raw):
    """A ledger's bytes read as the check reads them: (the ledger, None), or (None, its problem: ledger_too_new or
    ledger_unreadable). Also for a ledger inside an export file (archive.py)."""
    try:
        lg = json.loads(raw.decode("utf-8"))
    except ValueError:
        lg = None
    if isinstance(lg, dict) and _int(lg.get("schema")) and lg["schema"] > ledger.SCHEMA:
        return None, _problem("ledger_too_new", "The ledger was written by a newer Paperole.", files=["ledger.json"])
    if not (isinstance(lg, dict) and lg.get("schema") == ledger.SCHEMA and isinstance(lg.get("paper"), dict)
            and isinstance(lg.get("rounds"), list) and isinstance(lg.get("comments"), list)
            and all(isinstance(r, dict) and _int(r.get("n")) for r in lg["rounds"])):
        return None, _problem("ledger_unreadable", "The ledger cannot be read.", files=["ledger.json"])
    return lg, None


def paper(path):
    """The problems of one review folder ([] when there are none). Read only."""
    paper = Path(path)
    if not paper.is_dir():
        return [_problem("missing_folder", "The folder is not there.")]
    out, evicted = _folder(paper, time.time())
    if "ledger.json" in evicted:
        return out
    try:
        raw = (paper / "ledger.json").read_bytes()
    except FileNotFoundError:
        return [_problem("no_ledger", "There is no ledger.json in this folder.", files=["ledger.json"])] + out
    lg, bad = read_ledger(raw)
    if bad:
        return [bad] + out
    for r in lg["rounds"]:
        out += _round(paper, r, evicted)
    return out + _comments(lg)
