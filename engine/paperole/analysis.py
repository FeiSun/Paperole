"""rN/analysis.json, what changed since the round before (CONTRACT.md §2), is primary (design/data/DATA.md §2.2: the
ledger names its change ids) and kept in step with the ledger: the round records its SHA-256 (`analysis_sha256`).
A later write under the paper's lock (Reopen, re-placing a comment) is staged beside it as analysis.json.new, the
ledger is saved, then it is swapped in; after a crash the next locked call finishes or undoes it by that checksum
(settle). What viewing works out (the changes' details, the blocks they touch) goes to rN/analysis.cache.json, so
viewing never rewrites a primary file."""
import contextlib
import hashlib
import json
import os
import tempfile
from pathlib import Path

from . import disk

CACHE = 1  # schema of analysis.cache.json


def path(paper, n):
    return Path(paper) / "r{}".format(n) / "analysis.json"


def _dump(data):
    return json.dumps(data, ensure_ascii=False, indent=1).encode("utf-8")


def read(paper, n, staged=False):
    """Round n's analysis.json as written, or None without one; staged: the version this call staged, if any (the
    caller holds the lock)."""
    p = path(paper, n)
    new = p.with_name("analysis.json.new")
    for q in ((new, p) if staged else (p,)):
        try:
            return json.loads(q.read_text(encoding="utf-8"))
        except FileNotFoundError:
            continue
    return None


def _cache(paper, n, digest):
    """The cache's entries for the analysis.json of this checksum ({change id: {key: value}}), else {}."""
    try:
        data = json.loads((path(paper, n).with_name("analysis.cache.json")).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    ok = isinstance(data, dict) and data.get("schema") == CACHE and data.get("analysis") == digest
    return (data.get("changes") or {}) if ok else {}


def changes(paper, n):
    """Round n's changes ([] without analysis.json), each with what the cache holds for it (details worked out by
    state, the blocks it touches from prose), when the cache is for this analysis.json."""
    try:
        raw = path(paper, n).read_bytes()
    except FileNotFoundError:
        return []
    out = json.loads(raw.decode("utf-8"))["changes"]
    cached = _cache(paper, n, hashlib.sha256(raw).hexdigest())
    for ch in out:
        ch.update(cached.get(ch["id"]) or {})
    return out


def store_cache(paper, n, entries):
    """Add entries ({change id: {key: value}}) to round n's analysis.cache.json, for analysis.json as it is now (an
    older cache is dropped). A cache: written with a plain rename, and a failure is the caller's to ignore."""
    raw = path(paper, n).read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    kept = _cache(paper, n, digest)
    for cid, extra in entries.items():
        kept.setdefault(cid, {}).update(extra)
    out = path(paper, n).with_name("analysis.cache.json")
    fd, tmp = tempfile.mkstemp(dir=str(out.parent), prefix=out.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"schema": CACHE, "analysis": digest, "changes": kept}, f, ensure_ascii=False,
                      separators=(",", ":"))
        os.replace(tmp, str(out))
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def write(paper, rnd, data):
    """Write a new round's analysis.json (ingest, whose round folder the ledger does not name yet) and record its
    checksum in the round."""
    raw = _dump(data)
    disk.atomic_write(path(paper, rnd["n"]), raw)
    rnd["analysis_sha256"] = hashlib.sha256(raw).hexdigest()


def stage(paper, rnd, data):
    """Stage a new analysis.json for round rnd (data, or the bytes of one) beside the current one and record its
    checksum in the round: settle swaps it in once the ledger is saved."""
    raw = data if isinstance(data, bytes) else _dump(data)
    disk.atomic_write(path(paper, rnd["n"]).with_name("analysis.json.new"), raw)
    rnd["analysis_sha256"] = hashlib.sha256(raw).hexdigest()


def settle(paper, lg):
    """Under the paper's lock: each staged analysis.json is swapped in when the ledger (lg, as saved) records its
    checksum, and removed when it does not (the call failed, or was killed before the ledger was saved); lg None
    removes every one. The cache is kept for the new analysis.json: within a round a new one changes only the changes'
    attached_to and unrequested, not what the cache holds."""
    want = {r["n"]: r.get("analysis_sha256") for r in lg["rounds"]} if lg else {}
    for new in Path(paper).glob("r*/analysis.json.new"):
        n = new.parent.name[1:]
        if n.isdigit() and want.get(int(n)) and disk.sha256(new) == want[int(n)]:
            current = new.with_name("analysis.json")
            try:
                kept = _cache(paper, int(n), disk.sha256(current))
            except OSError:
                kept = {}
            disk.replace(new, current)
            if kept:
                with contextlib.suppress(OSError, ValueError):
                    store_cache(paper, int(n), kept)
        else:
            with contextlib.suppress(FileNotFoundError):
                new.unlink()
