"""ledger.json: the authoritative record of a paper (CONTRACT.md §4).

Since design/data/DATA.md §2.3 (additive, schema stays 1): `paper.id` tells copies of a paper apart, and each write is
a new version: `rev` (+1 a write), `saved` (when), and `trail`, [rev, short SHA-256] of the last 300 versions and of
every Finish (marked "finish"), so two copies compare as the same, older, newer or diverged (compare)."""
import contextlib
import datetime
import fcntl
import hashlib
import json
import secrets
import sys
import traceback
from pathlib import Path

from . import EngineError, disk, history

SCHEMA = 2  # the newest ledger this engine reads; it writes 1 until a comment uses what only 2 has (schema_needed)
BASE = 1  # what a new ledger is written as (engine/CONTRACT.md amendment "Comments on places, step 1")
V2_KINDS = ("overall",)  # comment kinds an engine reading schema 1 does not know; a comment's `link` (several
# places) is schema 2 too
TRAIL = 300  # versions on the trail, besides every Finish


def now():
    """ISO 8601 local time with offset, to the second."""
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def _path(paper):
    return Path(paper) / "ledger.json"


def new_paper_id():
    return "p-" + secrets.token_hex(8)


def derived_id(paper, lg, files=None):
    """The id of a ledger written before ids (DATA.md §2.3): from the SHA-256 of paper.created, round 1's created and
    the names and sizes of r1/src's files, so byte copies of a folder share it and papers made in the same second
    don't. files: those names and sizes, sorted, when they are not read from the folder (a ledger in an export)."""
    src = Path(paper) / "r1" / "src" if files is None else None
    if files is None:
        files = sorted((p.relative_to(src).as_posix(), p.stat().st_size) for p in src.rglob("*") if p.is_file()) \
            if src.is_dir() else []
    first = lg["rounds"][0].get("created") if lg.get("rounds") else None
    text = json.dumps([lg["paper"].get("created"), first, files], ensure_ascii=False)
    return "p-" + hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def paper_id(paper, lg):
    """The paper's id: its own, else derived (without writing it; the first locked write stores it)."""
    return lg["paper"].get("id") or derived_id(paper, lg)


def digest(lg):
    """A ledger version's short SHA-256: of its JSON without the trail (keys sorted)."""
    text = json.dumps({k: v for k, v in lg.items() if k != "trail"}, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _rev(lg):
    rev = lg.get("rev")
    return rev if isinstance(rev, int) and not isinstance(rev, bool) else 0


def version(lg):
    """[rev, digest]: rev 0 for a ledger written before versions."""
    return [_rev(lg), digest(lg)]


def compare(a, b):
    """How ledger a stands to ledger b, copies of one paper: "same"; "older" (a's version is on b's trail); "newer"
    (b's is on a's); else "diverged": both changed since they parted, or there is no telling (a ledger written by an
    older engine keeps its rev, so its version is on no trail: the safe side)."""
    va, vb = version(a), version(b)
    if va == vb:
        return "same"

    def on(trail, v):
        return any(isinstance(e, list) and e[:2] == v for e in trail or ())
    if on(b.get("trail"), va):
        return "older"
    if on(a.get("trail"), vb):
        return "newer"
    return "diverged"


def readable_schema(schema):
    """A ledger schema this engine reads: 1 or 2."""
    return isinstance(schema, int) and not isinstance(schema, bool) and BASE <= schema <= SCHEMA


def schema_needed(lg):
    """2 once any comment is of a kind only schema 2 has (an overall comment), else 1. An engine that reads only
    schema 1 then refuses the ledger, rather than drawing or carrying such a comment wrongly."""
    return 2 if any(c.get("kind") in V2_KINDS or c.get("link") for c in lg.get("comments", ())) else BASE


def save(paper, lg, finish=False, prior=None):
    """Write lg as the paper's next version (the caller holds the lock): rev + 1, saved, and its [rev, digest] on the
    trail (marked "finish" for Finish), whole or not at all (disk.atomic_write). prior: the version it was read as,
    put on the trail first when it is not there (written by an older engine, or before versions). Returns the bytes
    written."""
    trail = [e for e in lg.get("trail") or () if isinstance(e, list)]
    if prior and not any(e[:2] == prior for e in trail):
        trail.append(prior)
    lg["schema"] = max(lg.get("schema", BASE), schema_needed(lg))  # never lowered: a copy stays what it was
    rev = _rev(lg) + 1
    lg["rev"], lg["saved"] = rev, now()
    trail.append([rev, digest(lg)] + (["finish"] if finish else []))
    lg["trail"] = [e for i, e in enumerate(trail) if i >= len(trail) - TRAIL or e[2:] == ["finish"]]
    raw = json.dumps(lg, ensure_ascii=False, indent=1).encode("utf-8")
    disk.atomic_write(_path(paper), raw)
    return raw


def create(paper, title, student):
    with _lock(paper):
        if _path(paper).exists():
            raise EngineError("{} already has a ledger.json.".format(paper))
        lg = {"schema": BASE,
              "paper": {"title": title, "student": student, "main": None, "engine": None, "created": now(),
                        "id": new_paper_id()},
              "rounds": [], "comments": [], "read": {}}
        save(paper, lg)
    return lg


def _no_ledger(paper):
    return EngineError("{} is not a Paperole paper folder (no ledger.json).".format(paper))


def _read(paper):
    """(the ledger's bytes, the ledger)."""
    try:
        raw = _path(paper).read_bytes()
    except FileNotFoundError:
        raise _no_ledger(paper)
    try:
        lg = json.loads(raw.decode("utf-8"))
    except ValueError:  # cut short (a sync copy, a hand edit), or not UTF-8
        raise EngineError("ledger.json cannot be read. Put back an earlier ledger.")
    if not isinstance(lg, dict) or not readable_schema(lg.get("schema")):
        raise EngineError("ledger.json has schema {}; this engine reads schema 1 and {}.".format(
            lg.get("schema") if isinstance(lg, dict) else None, SCHEMA))
    return raw, lg


def load(paper):
    return _read(paper)[1]


@contextlib.contextmanager
def _lock(paper):
    with open(Path(paper) / ".lock", "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def locked(paper):
    """The ledger's lock without reading or writing it (for writers of a round's caches)."""
    return _lock(paper)


@contextlib.contextmanager
def edit(paper, keep=None, after=None):
    """Yield the ledger under an exclusive lock; save it as a new version only if the block exits normally and changed
    it (an older ledger gets its id first: derived_id). keep (ingest, finish, reopen): the new version is copied into
    .history (a failure is printed to stderr: the version is saved); any other write first copies the version before
    it when the newest copy is over 10 minutes old (history.py). after(paper, lg) runs after the save, still under
    the lock, before that copy."""
    if not _path(paper).is_file():  # before the lock: no .lock made in a folder that is not a paper's
        raise _no_ledger(paper)
    with _lock(paper):
        raw, lg = _read(paper)
        prior = version(lg)
        before = prior[1]
        if not lg["paper"].get("id"):
            lg["paper"]["id"] = derived_id(paper, lg)
            before = digest(lg)
        yield lg
        if digest(lg) == before:  # nothing changed: no new version
            if after:
                after(paper, lg)
            return
        if keep is None and history.due(paper):
            history.keep(paper, raw, json.loads(raw.decode("utf-8")), "edit")
        written = save(paper, lg, finish=keep == "finish", prior=prior)
        if after:
            after(paper, lg)
        if keep:
            try:
                history.keep(paper, written, lg, keep)
            except OSError:  # the version is saved: a copy that could not be made is reported, not the write
                traceback.print_exc(file=sys.stderr)


def open_round(lg):
    return next((r for r in lg["rounds"] if not r["closed"]), None)


def latest_round(lg):
    return lg["rounds"][-1] if lg["rounds"] else None


def can_replace_round(lg):
    """The latest draft can be replaced only before review work or an earlier Finish."""
    rnd = latest_round(lg)
    if rnd is None or rnd["closed"] or rnd.get("finishes"):
        return False
    n, key = rnd["n"], str(rnd["n"])
    return not (any(c["created_round"] == n or (c["rounds"].get(key) or {}).get("verdict")
                    or (c["rounds"].get(key) or {}).get("revived") for c in lg["comments"])
                or any("advisor_note" in (it["rounds"].get(key) or {})
                       for it in (lg.get("check_items") or {}).values()))


def get_comment(lg, cid):
    for c in lg["comments"]:
        if c["id"] == cid:
            return c
    raise EngineError("There is no comment {}.".format(cid))


def id_key(cid):
    """Sort key for ids like R1-03: (round, sequence); a place of one ("R1-03#b", carried as its own item: api._carry)
    after it, by its key."""
    cid, _, key = cid.partition("#")
    n, seq = cid[1:].split("-")
    return (int(n), int(seq), key) if key else (int(n), int(seq))


def new_id(lg, n):
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    rnd["last_seq"] += 1
    return "R{}-{:02d}".format(n, rnd["last_seq"])


def new_check_id(lg, n):
    """A check item's id A<n>-<seq> (check_items.py): its own sequence, the round's last_check_seq (no key until the
    round's first)."""
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    rnd["last_check_seq"] = rnd.get("last_check_seq", 0) + 1
    return "A{}-{:02d}".format(n, rnd["last_check_seq"])


def carried_into(lg, n):
    """Comments open at the close of round n-1: verdict there null or reopened."""
    prev = str(n - 1)
    return sorted((c for c in lg["comments"]
                   if prev in c["rounds"] and c["rounds"][prev]["verdict"] in (None, "reopened")),
                  key=lambda c: id_key(c["id"]))
