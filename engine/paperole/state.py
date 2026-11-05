"""The state JSON the app renders (CONTRACT.md §8)."""
import contextlib
import fcntl
import functools
import hashlib
import json
import os
import tempfile
from pathlib import Path

from . import EngineError, analysis, cards, check, comments, ledger, project, prose, tags, texdiff

_CONTEXTS = {}  # contexts of records written before contexts were stored, worked out once per process
_CHANGES = {}  # the same for the contexts of changes
CONTEXTS = 1  # schema of rN/contexts.json, the cache of the contexts in _CONTEXTS


def _collapse(text):
    return " ".join(text.split()) if isinstance(text, str) else text


def _digest(text):
    """The key of a comment in rN/contexts.json: a digest of its JSON (sort_keys)."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _json(c):
    """A comment's JSON as contexts are keyed by: without its tags, which change no context (a comment tagged or
    untagged keeps its cached contexts; one never tagged has the same JSON as before tags)."""
    return json.dumps({k: v for k, v in c.items() if k != "tags"}, sort_keys=True)


@functools.lru_cache(maxsize=16)
def _contexts_file(path, mtime, size):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data.get("contexts", {}) if isinstance(data, dict) and data.get("schema") == CONTEXTS else {}


def _saved_contexts(paper, k):
    """{digest of a comment: its round-k context} from rK/contexts.json (cached by modification time)."""
    path = Path(paper) / "r{}".format(k) / "contexts.json"
    try:
        st = path.stat()
    except OSError:
        return {}
    return _contexts_file(str(path), st.st_mtime_ns, st.st_size)


def _context(paper, lg, c, k, found):
    """The card context of comment c's round-k record: as stored, or for a record from before contexts were stored,
    as rK/contexts.json keeps it for the comment as it is now (by a digest of its JSON), else worked out from the
    round's PDF and added to `found` ({k: {digest: context}}, which build stores), so it is worked out once."""
    rec = c["rounds"][str(k)]
    if "context" in rec:
        return rec["context"]
    text = _json(c)
    key = (str(paper), k, text)
    if key not in _CONTEXTS:
        if len(_CONTEXTS) > 4096:  # keys of edited comments pile up in a long-running engine
            _CONTEXTS.clear()
        digest = _digest(text)
        saved = _saved_contexts(paper, k)
        if digest in saved:
            _CONTEXTS[key] = saved[digest]
        else:
            _CONTEXTS[key] = found.setdefault(k, {})[digest] = cards.record_context(paper, lg, c, k)
    return _CONTEXTS[key]


def _replace_json(path, data, **dump):
    """Write JSON to a temporary file beside path, then move it into place."""
    fd, tmp = tempfile.mkstemp(dir=str(Path(path).parent), prefix=Path(path).name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, **dump)
        os.replace(tmp, str(path))
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def _store_contexts(paper, lg, found):
    """Add the contexts this state worked out to each round's contexts.json, a cache: it keeps only the entries of
    comments as they are now (one edited since, or carried into a new round, is worked out again)."""
    live = {_digest(_json(c)) for c in lg["comments"]}
    for k, new in found.items():
        kept = {d: ctx for d, ctx in dict(_saved_contexts(paper, k), **new).items() if d in live}
        with contextlib.suppress(OSError):
            _replace_json(Path(paper) / "r{}".format(k) / "contexts.json", {"schema": CONTEXTS, "contexts": kept},
                          separators=(",", ":"))


@contextlib.contextmanager
def _lock_if_free(paper):
    """The ledger's lock (ledger.locked) when no other process holds it: True, else False at once, so a cache is
    written by a later state rather than waited for."""
    with open(Path(paper) / ".lock", "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _store_details(paper, n, changes, details):
    """Write the change details this state worked out (_change_details) into rN/analysis.cache.json, so later
    processes read them (analysis.changes; viewing never rewrites analysis.json, which is primary): under the ledger's
    lock, and only when the round still holds the changes they were worked out for (`changes`, as build read them)."""
    with contextlib.suppress(OSError, ValueError), _lock_if_free(paper) as free:
        if not free or analysis.changes(paper, n) != changes:
            return
        analysis.store_cache(paper, n, {ch["id"]: extra for ch, extra in zip(changes, details) if extra})


def _attached(changes, cid):
    """The ids of the changes attached to comment cid."""
    return [ch["id"] for ch in changes if cid in ch["attached_to"]]


def _comment(paper, lg, c, n, changes, earlier_changes, data, found):
    """Comment c in round n's state; earlier_changes holds each earlier round's changes (analysis.json), for the
    changes attached in that round (history[].changes; those of them that replaced a picture file: figures; the page
    each is on in that round's PDF: change_pages). student_note is the round's note of the student (notes.py), or
    null."""
    rec = c["rounds"][str(n)]
    anchor = rec["anchor"]
    earlier = sorted((int(k), r) for k, r in c["rounds"].items() if int(k) < n)
    first = c["rounds"][str(c["created_round"])]["anchor"] or {}
    carried = c["created_round"] < n
    # the last known quote: an orphan has no anchor, and a gone comment's quote is ""
    old_quote = next((r["anchor"]["quote"] for _, r in reversed(earlier) if r["anchor"] and r["anchor"]["quote"]),
                     None) if carried else None
    return {"id": c["id"], "kind": c["kind"], "color": comments.color(c), "note": c["note"],
            "source": c["source"],
            "created_round": c["created_round"], "carried": carried,
            "verdict": rec["verdict"], "verdict_note": rec["verdict_note"],
            "anchor_state": rec["anchor_state"], "confidence": rec["confidence"], "method": rec["method"],
            "page": anchor["page"] if anchor else None, "rects": anchor["rects"] if anchor else [],
            "text": anchor["text"] if anchor else "",
            "old_quote": old_quote, "new_quote": anchor["quote"] if anchor else None,
            "file": anchor["file"] if anchor else None, "line": anchor["lines"][0] if anchor else None,
            "changes": _attached(changes, c["id"]), "student_note": rec.get("student_note"),
            "tags": tags.ids(c), "env": first.get("env"), "revived": rec.get("revived"),
            "revivable": comments.revivable(lg, c),
            "context": _context(paper, lg, c, n, found), "paragraph": prose.block_of(data, anchor),
            "history": [{"round": k, "page": r["anchor"]["page"] if r["anchor"] else None,
                         "anchor_state": r["anchor_state"], "verdict": r["verdict"], "verdict_note": r["verdict_note"],
                         "context": _context(paper, lg, c, k, found),
                         "changes": _attached(earlier_changes.get(k, []), c["id"]),
                         "figures": [ch["id"] for ch in earlier_changes.get(k, [])
                                     if c["id"] in ch["attached_to"] and ch.get("figure")],
                         "change_pages": {ch["id"]: ch["page"] for ch in earlier_changes.get(k, [])
                                          if c["id"] in ch["attached_to"] and ch.get("page") is not None},
                         "student_note": r.get("student_note"), "revived": r.get("revived")} for k, r in earlier]}


def _change_details(paper, lg, n, changes):
    """Each change's "section" and "context" (cards.change_details), "float" and "about" (cards.describe) as ingest
    stored them; for an analysis.json written before they were stored, worked out once per process from both rounds'
    sources and PDFs (the diff made again must give the stored changes, else they stay without them; stored contexts
    are kept, but for the figure or table of an \\input line)."""
    keys = ("section", "context", "float", "about")
    if all(k in ch for ch in changes for k in keys):
        return [{} for _ in changes]
    key = (str(paper), n, tuple((ch["id"], ch["kind"], ch["file"], ch["line"]) for ch in changes))
    if key not in _CHANGES:
        details = [{k: ch.get(k) for k in keys} for ch in changes]
        rounds = {r["n"]: r for r in lg["rounds"]}
        old, new = paper / "r{}".format(n - 1), paper / "r{}".format(n)
        diff = texdiff.diff_trees(old / "src", new / "src", old / "build", new / "build")
        if [(h["kind"], h["new_file"] or h["old_file"]) for h in diff.hunks] == \
                [(ch["kind"], ch["file"]) for ch in changes]:
            fresh = [dict(ch) for ch in changes]
            before = rounds[n - 1]["build"]["pdf"]
            args = (old / "src", paper / before if before else None, new / "src", paper / rounds[n]["build"]["pdf"],
                    diff, fresh)
            if all("context" in ch for ch in changes):
                cards.describe(*args)
            else:
                cards.change_details(*args)
            details = [{k: ch.get(k) for k in keys} for ch in fresh]
        _CHANGES[key] = details
    return _CHANGES[key]


@functools.lru_cache(maxsize=8)
def _layout(pdf, stamp):
    return comments.layout(pdf)


def _build_layout(paper, b, key):
    """build.text_x, build.columns or build.rulers as ingest stored it; for a round ingested before it was stored,
    worked out from the PDF once per process (about 6 ms a page)."""
    if key in b:
        return b[key]
    pdf = paper / b["pdf"] if b["pdf"] else None
    if pdf is None or not pdf.is_file():
        return []
    st = pdf.stat()
    return _layout(str(pdf), (st.st_mtime_ns, st.st_size))[key]


def _printed(page, first, gaps):
    """Where a rect is in the paper's printed order: page, then on a two-column page (gaps: comments.columns) a rect
    across both columns in the top half of the page first, then the left column, the right column, and one across
    both in the bottom half; then top, left."""
    gap, half = (gaps[page] if page is not None and page < len(gaps) else None) or (None, None)
    group = 1
    if gap is not None and first[2] > gap + 3 and first[0] < gap - 3:  # across both columns
        group = 0 if first[1] < half else 3
    elif gap is not None and first[0] >= gap - 3:
        group = 2
    return page or 0, group, first[1], first[0]


def _order(c, gaps):
    """Comments in printed order (_printed of their first rect), then by id."""
    first = c["rects"][0] if c["rects"] else [0, 0, 0, 0]
    return (c["page"] is None,) + _printed(c["page"], first, gaps) + (ledger.id_key(c["id"]),)


def _near_closed(lg, ch, n):
    """The comments closed before round n whose sentence a change of round n edits (analysis.json's `near_closed`,
    anchor.shadows), those still not in round n: [{"id", "round": the round it was closed in, "verdict", "revivable"}]."""
    out = []
    for cid in ch.get("near_closed") or ():
        c = next((c for c in lg["comments"] if c["id"] == cid), None)
        if c is None or str(n) in c["rounds"]:
            continue
        k = max((int(j) for j in c["rounds"] if int(j) < n), default=None)
        if k is not None:
            out.append({"id": cid, "round": k, "verdict": c["rounds"][str(k)]["verdict"],
                        "revivable": comments.revivable(lg, c)})
    return out


def _changes(paper, n):
    return analysis.changes(paper, n)


def _reading(blocks, read, n, gaps):
    """The round's paragraphs for reading in the PDF (prose.readable) with their places, in printed order (_printed of
    their first part: a float set on a later page, or above the text before it, is read where it is printed), which
    of them are read, and the headings of sections and subsections (the outline)."""
    counted = sorted((k for k, b in enumerate(blocks) if prose.readable(b)),
                     key=lambda k: _printed(blocks[k]["parts"][0][0], blocks[k]["parts"][0][1], gaps) + (k,))
    done = sorted(k for k in counted if prose.is_read(blocks[k]["hash"], prose.fresh(blocks[k]), read, n))
    return {"read": done, "count": len(counted), "unread": len(counted) - len(done),
            "paragraphs": [{"block": k, "section": blocks[k]["section"], "parts": blocks[k]["parts"]} for k in counted],
            "headings": [{"block": k, "level": b["level"] or 1, "title": " ".join(t for t in (b["number"], b["text"]) if t),
                          "parts": b.get("parts", [])}
                         for k, b in enumerate(blocks) if b["kind"] == "heading" and (b["level"] or 1) <= 2]}


def finishes(paper, rnd):
    """A round's earlier finishes, whose files Resume kept (the round's `finishes`): [{"at": when it was finished,
    "resumed": when it was resumed, "final", "email": the kept files' absolute paths, null when not there}], oldest
    first."""
    def where(name):
        p = Path(paper) / name if check._relative(name, ("r{}".format(rnd["n"]), "earlier")) else None
        return str(p) if p is not None and p.is_file() else None
    return [{"at": f.get("at"), "resumed": f.get("resumed"), "final": where(f.get("final")),
             "email": where(f.get("email"))} for f in rnd.get("finishes") or () if isinstance(f, dict)]


def summary(paper, lg):
    """The paper's next step, for the papers list: its latest round (closed_at: when it was finished; resumable: it
    is finished, so Resume can open it again) and, when that round is open with a PDF, what is left there: carried
    comments without a verdict (to_judge), and unrequested changes neither checked, asked about by a comment of the
    round, nor read (to_check; analysis.json's block hashes against the ledger's read map); and what is done there
    (the status ring's fill): carried comments with a verdict (answered) and unrequested changes no longer to check
    (handled). All four are 0 for a closed or failed round."""
    rnd = ledger.latest_round(lg)
    out = {"round": None, "closed": False, "status": None, "to_judge": 0, "to_check": 0, "answered": 0, "handled": 0,
           "closed_at": None, "resumable": False, "replaceable": ledger.can_replace_round(lg)}
    if rnd is None:
        return out
    n = rnd["n"]
    out.update(round=n, closed=rnd["closed"], status=rnd["build"]["status"], closed_at=rnd["closed_at"],
               resumable=bool(rnd["closed"]))
    if rnd["closed"] or rnd["build"]["status"] == "failed":
        return out
    carried = [c for c in lg["comments"] if c["created_round"] < n and str(n) in c["rounds"]]
    out["to_judge"] = sum(1 for c in carried if c["rounds"][str(n)]["verdict"] is None)
    out["answered"] = len(carried) - out["to_judge"]
    changes = _changes(paper, n)
    checked, asked = set(rnd.get("checked", [])), comments.commenters(lg, n, changes)
    read = prose.read_map(paper, lg) if "read" in lg else {}
    out["to_check"] = sum(1 for ch in changes if unchecked(ch, checked, asked, read, n))
    out["handled"] = sum(1 for ch in changes if not ch["attached_to"]) - out["to_check"]
    return out


def unchecked(ch, checked, asked, read, n):
    """Whether change ch of open round n is an edit to check (summary's to_check, the overview's edits): no comment
    asked for it, and it is neither checked (checked: ids), asked about by a comment of the round (asked:
    comments.commenters), nor read (read: prose.read_map; analysis.json's block hashes)."""
    return not ch["attached_to"] and ch["id"] not in checked and ch["id"] not in asked \
        and not prose.change_read(ch, prose.change_hashes(None, ch), read, n)


def note_warnings(lg, rnd):
    """A round's warnings about the student's notes (notes.find) as they read now: an ID that was unknown when the
    round's source was read but is a comment's now (the advisor made it later in the round) says so, and so does the
    ID of a closed comment the advisor reopened in the round since (`revive`)."""
    ids = {c["id"] for c in lg["comments"]}
    back = {c["id"] for c in lg["comments"] if (c.get("rounds", {}).get(str(rnd.get("n"))) or {}).get("revived")} \
        if any(w["kind"] == "closed" for w in rnd.get("note_warnings", [])) else set()

    def now(w):
        if w["kind"] == "unknown" and w["ids"] and all(i in ids for i in w["ids"]):
            return dict(w, message="There was no comment {} yet when this source was read, so this note is ignored."
                        .format(", ".join(w["ids"])))
        if w["kind"] == "closed" and w["ids"] and all(i in back for i in w["ids"]):
            return dict(w, message="{} was closed when this source was read, so this note was not attached to it; "
                                   "you reopened it later.".format(", ".join(w["ids"])))
        return w
    return [now(w) for w in rnd.get("note_warnings", [])]


def build(paper, n=None):
    """The state of round n (default: the latest) as it stands, so a closed round's as it was left; "rounds" and
    "summary" are the paper's now."""
    paper = Path(paper)
    lg = ledger.load(paper)
    p = lg["paper"]
    state = {"schema": 1,
             "paper": {"path": str(paper), "title": p["title"], "student": p["student"],
                       "main": p["main"], "engine": p["engine"], "id": ledger.paper_id(paper, lg),
                       "shell_escape": p.get("shell_escape") is True},
             "rounds": [{"n": r["n"], "created": r["created"], "source": r["source"], "closed": r["closed"],
                         "closed_at": r["closed_at"], "status": r["build"]["status"],
                         "pdf": str(paper / r["build"]["pdf"]) if r["build"]["pdf"] else None} for r in lg["rounds"]],
             "round": None, "comments": [], "changes": [], "note_warnings": [], "summary": summary(paper, lg),
             "reading": None, "tag_names": dict(lg.get("tag_names") or {})}
    rnd = ledger.latest_round(lg) if n is None else next((r for r in lg["rounds"] if r["n"] == n), None)
    if rnd is None:
        if n is not None:
            raise EngineError("There is no round {}.".format(n))
        return state
    n, b = rnd["n"], rnd["build"]
    state["note_warnings"] = note_warnings(lg, rnd)
    rdir = paper / "r{}".format(n)
    final, email = rdir / "final.pdf", rdir / "email.txt"
    state["round"] = {
        "n": n, "closed": rnd["closed"], "created": rnd["created"], "closed_at": rnd["closed_at"],
        "build": {"status": b["status"], "pdf": str(paper / b["pdf"]) if b["pdf"] else None, "pages": b["pages"],
                  "text_x": _build_layout(paper, b, "text_x"), "columns": _build_layout(paper, b, "columns"),
                  "rulers": _build_layout(paper, b, "rulers"),
                  "warnings": b["warnings"], "errors": b["errors"],
                  "log_tail": project.log_tail(paper / b["log"]) if b["log"] else "",
                  # how it was built (false for a round built before builds recorded it), and whether a package
                  # asks for shell escape there: derived, so an older round asks too
                  "shell_escape": b.get("shell_escape") is True, "needs_shell_escape": project.needs_shell_escape(b)},
        "final_pdf": str(final) if rnd["closed"] and final.exists() else None,
        "email": email.read_text(encoding="utf-8") if rnd["closed"] and email.exists() else None,
        "resumable": rnd is ledger.latest_round(lg) and bool(rnd["closed"]), "finishes": finishes(paper, rnd),
        # how many check items went out with the round (finish with checks), for the round card
        "checks_sent": rnd.get("checks_sent") if rnd["closed"] else None,
        "checks_fixed": rnd.get("checks_fixed") if rnd["closed"] else None}
    if b["status"] == "failed":
        return state
    data = prose.load(paper, n)
    read = prose.read_map(paper, lg) if data is not None or "read" in lg else {}
    gaps = _build_layout(paper, b, "columns")
    if data is not None:
        state["reading"] = _reading(data["blocks"], read, n, gaps)

    changes = _changes(paper, n)
    checked = set(rnd.get("checked", []))
    asked = comments.commenters(lg, n, changes)
    details = _change_details(paper, lg, n, changes)
    state["changes"] = [dict(ch, old_text=_collapse(ch["old_text"]), new_text=_collapse(ch["new_text"]),
                             unrequested=not ch["attached_to"], checked=ch["id"] in checked,
                             commented_by=asked.get(ch["id"], []), student_notes=ch.get("student_notes", []),
                             blocks=data["changes"].get(ch["id"], []) if data else [],
                             read=prose.change_read(ch, prose.change_hashes(data, ch), read, n),
                             near_closed=_near_closed(lg, ch, n), **extra)
                        for ch, extra in zip(changes, details)]
    found = {}
    earlier_changes = {r["n"]: _changes(paper, r["n"]) for r in lg["rounds"] if r["n"] < n}
    state["comments"] = sorted((_comment(paper, lg, c, n, changes, earlier_changes, data, found) for c in lg["comments"]
                                if str(n) in c["rounds"]),
                               key=lambda c: _order(c, gaps))
    if found:
        _store_contexts(paper, lg, found)
    if any(details):
        _store_details(paper, n, changes, details)
    return state
