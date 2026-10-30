"""Earlier versions of a paper's ledger, in <paper>/.history (design/data/DATA.md §2.4): a copy after every ingest,
Finish and Reopen, before every Resume, and before any other write when the newest copy is over 10 minutes old, each
with the open round's analysis.json (before a Resume, the one of the round it resumes). Kept: the 30 newest of the
last day, the newest of each day for 30 days, and for good every Finish copy, every copy before a Resume and every
ledger that Put Back replaced. Part of safe writing, not a backup: it lives in the review folder.

A copy is `<UTC time>-<rev>-<kind>.json` (kind: ingest, finish, reopen, edit: the version before an edit, resume: the
version before a Resume, its round finished, replaced: the version Put Back replaced, kept as it was even when it
cannot be read), its analysis.json beside it as `<same>.r<N>-analysis.json`."""
import datetime
import glob
import json
import os
import re
import time
from pathlib import Path

from . import EngineError, disk

FOLDER = ".history"
NAME = re.compile(r"^(\d{8}-\d{6})-(\d+)-(ingest|finish|reopen|edit|resume|replaced)\.json$")
EVERY = 10 * 60  # a copy before an edit when the newest is older than this
DAY = 24 * 3600
FOR_GOOD = ("finish", "resume", "replaced")


def _when(stamp):
    return datetime.datetime.strptime(stamp, "%Y%m%d-%H%M%S").replace(tzinfo=datetime.timezone.utc).timestamp()


def _copies(paper):
    """[(time, name, rev, kind)] of the ledger copies, newest first (by time, then rev)."""
    try:
        names = os.listdir(str(Path(paper) / FOLDER))
    except FileNotFoundError:
        return []
    return sorted(((_when(m.group(1)), name, int(m.group(2)), m.group(3))
                   for name, m in ((name, NAME.match(name)) for name in names) if m),
                  key=lambda c: (c[0], c[2], c[1]), reverse=True)


def _analysis_round(lg, kind=None):
    """The round whose analysis.json goes with a copy: the open one; before a Resume the latest (finished), which
    the resumed round's edits may change (api._reattach), for Put Back."""
    rounds = [r for r in (lg.get("rounds") if isinstance(lg, dict) else None) or () if isinstance(r, dict)]
    if kind == "resume" and rounds:
        return rounds[-1].get("n")
    return next((r.get("n") for r in rounds if not r.get("closed")), None)


def due(paper, now=None):
    """Whether a copy before an edit is due: none yet, or the newest over 10 minutes old."""
    copies = _copies(paper)
    return not copies or (time.time() if now is None else now) - copies[0][0] > EVERY


def keep(paper, raw, lg, kind, now=None):
    """Copy a version of the ledger (raw: its bytes; lg: it read, or None when it cannot be read) into .history with
    the open round's analysis.json (before a Resume: the round's it resumes), then prune. Returns the copy's name."""
    now = time.time() if now is None else now
    folder = Path(paper) / FOLDER
    folder.mkdir(exist_ok=True)
    rev = lg.get("rev") if isinstance(lg, dict) and isinstance(lg.get("rev"), int) else 0
    stem = "{}-{}-{}".format(datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y%m%d-%H%M%S"),
                             rev, kind)
    if not (folder / (stem + ".json")).exists():  # the same version, kind and second: already kept
        n = _analysis_round(lg, kind)
        a = Path(paper) / "r{}".format(n) / "analysis.json" if isinstance(n, int) else None
        if a is not None and a.is_file():
            disk.atomic_write(folder / "{}.r{}-analysis.json".format(stem, n), a.read_bytes())
        disk.atomic_write(folder / (stem + ".json"), raw)  # last: a listed copy has its analysis.json
    prune(paper, now)
    return stem + ".json"


def prune(paper, now=None):
    """Delete the copies beyond the limits: keep the 30 newest of the last day, the newest of each day (local) for 30
    days, and every Finish copy, copy before a Resume and replaced ledger."""
    now = time.time() if now is None else now
    copies = _copies(paper)
    kept = {name for _, name, _, _ in [c for c in copies if now - c[0] <= DAY][:30]}
    days = {}
    for t, name, _, _ in copies:  # newest first: the first of a day is its newest (one under a day old included)
        if now - t <= 30 * DAY:
            days.setdefault(datetime.date.fromtimestamp(t), name)
    kept.update(days.values())
    kept.update(name for _, name, _, kind in copies if kind in FOR_GOOD)
    folder = Path(paper) / FOLDER
    for _, name, _, _ in copies:
        if name not in kept:
            for a in folder.glob(glob.escape(name[:-len(".json")]) + ".r*-analysis.json"):
                a.unlink()
            (folder / name).unlink()


def versions(paper):
    """The saved versions, newest first: {"name", "time" (when the version was saved, else copied; ISO 8601 local),
    "rev", "kind", "comments", "rounds"} (comments and rounds null for a copy that cannot be read)."""
    out = []
    for t, name, rev, kind in _copies(paper):
        saved, comments, rounds = None, None, None
        try:
            lg = json.loads((Path(paper) / FOLDER / name).read_text(encoding="utf-8"))
            comments, rounds = len(lg["comments"]), len(lg["rounds"])
            saved = lg.get("saved") if isinstance(lg.get("saved"), str) else None
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            pass
        out.append({"name": name, "rev": rev, "kind": kind, "comments": comments, "rounds": rounds,
                    "time": saved or datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")})
    return out


def read(paper, name):
    """A saved version: (its bytes, (N, the bytes of its round N's analysis.json) or None)."""
    folder = Path(paper) / FOLDER
    if not isinstance(name, str) or not NAME.match(name):
        raise EngineError("There is no saved version {}.".format(name))
    try:
        raw = (folder / name).read_bytes()
    except FileNotFoundError:
        raise EngineError("There is no saved version {}.".format(name))
    for a in folder.glob(glob.escape(name[:-len(".json")]) + ".r*-analysis.json"):
        n = a.name[len(name) - len(".json") + 2:-len("-analysis.json")]
        if n.isdigit():
            return raw, (int(n), a.read_bytes())
    return raw, None
