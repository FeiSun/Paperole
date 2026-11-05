"""One function per RPC method (CONTRACT.md §7): fn(params, progress) -> dict with "state".

cli.py and rpc.py only translate to and from these functions."""
import contextlib
import datetime
import hashlib
import json
import os
import re
import shutil
import sys
import traceback
from pathlib import Path

from . import EngineError, analysis, anchor, archive, cards, check, check_items, check_report, checks, comments, disk, export, \
    history, ledger, links, notes, overview, project, prose, refs, render, state, tags, texdiff

_REQUIRED = object()


def _param(params, name, default=_REQUIRED):
    if name in params and params[name] is not None:
        return params[name]
    if default is _REQUIRED:
        raise EngineError("Missing parameter: {}".format(name))
    return default


def _paper(params):
    return Path(_param(params, "paper"))


def _shell_escape(params):
    """The shell_escape given (true or false), or None when it is not: whether the paper's rounds are built with shell
    escape (project.compile)."""
    if "shell_escape" not in params:
        return None
    if not isinstance(params["shell_escape"], bool):
        raise EngineError("shell_escape is true or false.")
    return params["shell_escape"]


def _choose_shell_escape(p, on):
    """Remember the advisor's choice in the ledger's paper: shell_escape true, or no key (off, as in every paper
    before it)."""
    if on:
        p["shell_escape"] = True
    else:
        p.pop("shell_escape", None)


def _state(paper, **extra):
    return dict(extra, state=state.build(paper))


@contextlib.contextmanager
def _edit(paper, keep=None):
    """ledger.edit (keep: ingest, finish or reopen, why the new version is copied into .history), after putting back
    what a killed call left (_recover). An analysis.json staged by the call is swapped in once the ledger is saved,
    and removed when the call fails (analysis.settle)."""
    with ledger.edit(paper, keep, after=analysis.settle) as lg:
        _recover(paper, lg)
        try:
            yield lg
        except BaseException:
            analysis.settle(paper, None)
            raise


ASIDE = re.compile(r"r(\d+)\.old(?:-([0-9a-f]{12}))?")  # a round ingest set aside (an engine before stamps: rN.old)


def _stamp(rnd):
    """A short digest of a round's record: ingest sets the round it replaces aside as rN.old-<stamp>."""
    return hashlib.sha256(json.dumps(rnd, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()[:12]


def _recover(paper, lg):
    """Put back what a killed call left, under the lock. While a round is re-ingested, the round the ledger describes
    waits in rN.old-<stamp of its record> (see ingest). While the ledger still has that record, the ingest never
    finished: the round comes back, and the half-built one goes to .orphans. Once the ledger has another (the new
    round's), the one it replaced goes, as ingest would have done (it was killed before it could), so a round half
    deleted never comes back. An rN.old of an engine before stamps comes back when the ledger has round N. A round
    set aside that the ledger does not name goes to .orphans, and so does a round folder rN it does not name (an ingest
    stopped hard): no round folder is deleted because the ledger does not name it (DATA.md §2.4). A staged
    analysis.json is finished or undone by the ledger's checksum. The files a Resume killed before the ledger was saved
    moved into rN/earlier/ go back (_unresumed)."""
    rounds = {r["n"]: r for r in lg["rounds"]}
    for aside in Path(paper).glob("r*.old*"):
        m = ASIDE.fullmatch(aside.name)
        if not m:
            continue
        n, stamp = int(m.group(1)), m.group(2)
        rdir = Path(paper) / "r{}".format(n)
        if n in rounds and stamp in (None, _stamp(rounds[n])):
            if rdir.exists():
                _orphan(paper, rdir)
            aside.rename(rdir)
        elif n in rounds and stamp:
            shutil.rmtree(aside, ignore_errors=True)
        else:
            _orphan(paper, aside)
    for rdir in _unnamed(paper, rounds):
        _orphan(paper, rdir)
    for kept, back in _unresumed(paper, lg):  # a Resume killed before the ledger was saved: the round stays finished
        disk.move(kept, back)
    analysis.settle(paper, lg)


ROUND = re.compile(r"r\d+")


def _unnamed(paper, rounds):
    """The paper's round folders (rN) of no round in rounds (round numbers): left by an ingest stopped hard."""
    named = {"r{}".format(n) for n in rounds}
    return [d for d in Path(paper).iterdir() if ROUND.fullmatch(d.name) and d.name not in named and d.is_dir()]


def _orphan(paper, folder):
    """Move a round folder the ledger does not describe to .orphans/rN-<time>, where check reports it."""
    base = Path(paper) / ".orphans"
    base.mkdir(exist_ok=True)
    m = ASIDE.fullmatch(folder.name)
    name = "r" + m.group(1) if m else folder.name
    stem = "{}-{}".format(name, datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    dest, k = base / stem, 2
    while dest.exists():
        dest, k = base / "{}-{}".format(stem, k), k + 1
    folder.rename(dest)


def new(params, progress):
    paper = _paper(params)
    paper.mkdir(parents=True, exist_ok=True)
    if not (paper / "ledger.json").exists() and any(not p.name.startswith(".") for p in paper.iterdir()):
        raise EngineError("{} is not empty. Choose a new or empty folder for the paper.".format(paper))
    ledger.create(paper, _param(params, "title"), _param(params, "student"))
    return _state(paper)


def ingest(params, progress):
    paper = _paper(params)
    source = os.path.abspath(_param(params, "source"))
    main, engine = params.get("main"), params.get("engine")
    if engine is not None and engine not in project.ENGINES:
        raise EngineError("Unknown engine {!r}; use pdflatex, xelatex or lualatex.".format(engine))
    escape = _shell_escape(params)
    with _edit(paper, keep="ingest") as lg:
        last = ledger.latest_round(lg)
        last_seq, last_check_seq = 0, None
        replacing = bool(last and not last["closed"])
        aside = None
        if replacing:
            n = last["n"]
            aside = paper / "r{}.old-{}".format(n, _stamp(last))
            if last.get("finishes"):  # replacing it would delete what its earlier finishes wrote (rN/earlier/)
                raise EngineError("Round {} was finished before and resumed. Finish it again before ingesting a new "
                                  "round.".format(n))
            if not ledger.can_replace_round(lg):
                raise EngineError("Round {} already has comments or verdicts. Finish it before ingesting a new "
                                  "round.".format(n))
            last_seq = last["last_seq"]  # deleted ids stay used
            last_check_seq = last.get("last_check_seq")  # so do check items' (check_items.py)
            lg["rounds"].remove(last)
            for c in lg["comments"]:
                c["rounds"].pop(str(n), None)
            check_items.drop(lg, n)
        else:
            n = last["n"] + 1 if last else 1
            if last:
                last.pop("marked_read", None)  # only Resume uses it, and round n makes the round before it final
        if escape is not None:  # the advisor's choice, kept for the next ingests (saved with the new round only)
            _choose_shell_escape(lg["paper"], escape)
        # The open round being replaced is kept aside, named for its record, until the ledger names the new one, so
        # a failure, or a kill before the ledger is saved, leaves the folder that the unchanged ledger describes
        # (_recover). A folder the ledger does not name (left by a crashed ingest, or by a ledger put back from
        # before it) is in .orphans already (_recover), never deleted.
        rdir = paper / "r{}".format(n)
        if aside is not None and rdir.exists():
            rdir.rename(aside)
        try:
            _new_round(paper, lg, n, source, main, engine, last_seq, progress)
        except BaseException:
            shutil.rmtree(rdir, ignore_errors=True)
            if aside is not None and aside.exists():
                aside.rename(rdir)
            raise
        if last_check_seq is not None:  # the replaced round's check ids stay used (check_items.py)
            next(r for r in lg["rounds"] if r["n"] == n)["last_check_seq"] = last_check_seq
    if aside is not None:  # the ledger names the new round now (killed before this: _recover deletes it)
        with ledger.locked(paper):  # so an export meanwhile never catches it half deleted
            shutil.rmtree(aside, ignore_errors=True)
    return _state(paper)


def _new_round(paper, lg, n, source, main, engine, last_seq, progress):
    """Snapshot, detect (round 1 or when asked), compile (with shell escape when the paper has it) and, from round 2,
    carry the open comments and check items."""
    rdir = paper / "r{}".format(n)
    src = rdir / "src"
    progress("Copying the source…")
    skipped = project.snapshot(source, src)
    for warning in skipped:
        progress(warning)
    received = project.received(source)  # when the student last changed it (the overview's round trips)
    p = lg["paper"]
    if n == 1 or main:
        found = project.detect(src, main)
        p["main"], p["engine"] = found["main"], engine or found["engine"]
    elif engine:
        p["engine"] = engine
    if p.get("finished"):  # a new round from the student: no longer finished (the mark would show again once closed)
        p["finished"] = None
    shell_escape = p.get("shell_escape") is True  # the advisor's choice for this paper (ingest, edit_paper)
    build = project.compile(src, rdir / "build", p["main"], p["engine"], progress, shell_escape)
    build["warnings"] = skipped + build["warnings"]  # kept with the round: why a skipped refs.bib leaves [?]
    build.update(comments.layout(build["pdf"]) if build["pdf"] else {"text_x": [], "columns": []})
    for key in ("pdf", "log"):
        if build[key]:
            build[key] = Path(build[key]).relative_to(paper).as_posix()
    lg["rounds"].append({"n": n, "created": ledger.now(), "received": received, "source": source,
                         "source_name": Path(source).name, "closed": False, "closed_at": None, "last_seq": last_seq,
                         "build": build})
    if build["status"] == "failed":
        return
    diff = _carry(paper, lg, n, progress) if n > 1 else None
    _prose(paper, lg, n, diff, progress)


def _prose(paper, lg, n, diff, progress):
    """Build round n's prose.json (prose.build: the paragraphs read in the PDF). A failure leaves the round without
    it (the prose RPC tries again): the review does not depend on it."""
    progress("Finding the paragraphs…")
    try:
        data = prose.build(paper, lg, n, diff, progress)
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        prose.record_failure(paper, n, e)  # the overview: "Sections unavailable" rather than waiting for them
        progress("The paragraphs for reading could not be found: {}".format(e))
        return None
    links.build_quietly(paper, lg, n, data)  # the link table (reference previews); the links RPC tries again
    return data


def _carry(paper, lg, n, progress):
    """Diff round n-1's source against round n's, re-anchor the carried comments, save the changes."""
    old_src, src = paper / "r{}".format(n - 1) / "src", paper / "r{}".format(n) / "src"
    progress("Comparing with round {}…".format(n - 1))
    diff = texdiff.diff_trees(old_src, src, old_src.parent / "build", src.parent / "build")
    carried = ledger.carried_into(lg, n)
    items = [_carry_item(paper, lg, c, n - 1) for c in carried]
    progress("Locating {} comments from earlier rounds…".format(len(items)))
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    before = next(r for r in lg["rounds"] if r["n"] == n - 1)["build"]["pdf"]
    records, changes = anchor.carry(old_src, src, paper / rnd["build"]["pdf"], diff, items,
                                    old_pdf=paper / before if before else None)
    found, rnd["note_warnings"] = _notes(diff, lg, n, changes, progress)
    for c in carried:
        c["rounds"][str(n)] = dict(records[c["id"]], verdict=None, verdict_note="", verdict_at=None)
        if c["id"] in found:
            c["rounds"][str(n)]["student_note"] = found[c["id"]]
        c["rounds"][str(n)]["context"] = cards.record_context(paper, lg, c, n, changes)
    check_items.carry(lg, n, found)  # the open check items, with the student's notes on them
    shadows = _shadows(paper, lg, n, diff, changes, progress)
    progress("Reading the {} changes in both PDFs…".format(len(changes)))
    cards.change_details(old_src, paper / before if before else None, src, paper / rnd["build"]["pdf"], diff, changes)
    data = {"schema": 1, "changes": changes}
    if shadows is not None:  # a failure leaves the key out, so the next round derives them (_older_shadows)
        data["shadows"] = shadows
    analysis.write(paper, rnd, data)  # its checksum in the round
    return diff


def _carry_item(paper, lg, c, k):
    """anchor.carry's item for comment c from its round-k anchor (a carry: k = n − 1; a revive: the round it was
    closed in, its last record)."""
    recs = [c["rounds"][j] for j in sorted(c["rounds"], key=int)]
    # the latest position the advisor gave (creation or re-anchoring): a synctex line is a guess, and a note placed by
    # a click stays a point beside its line (anchor.carry)
    p, placed = [(int(j), r) for j, r in sorted(c["rounds"].items(), key=lambda jr: int(jr[0]))
                 if r["method"] in ("selection", "import", "line", "advisor")][-1]
    point = c["kind"] == "note" and all(r[0] == r[2] and r[1] == r[3] for r in placed["anchor"]["rects"])
    pdf_p = next(r for r in lg["rounds"] if r["n"] == p)["build"]["pdf"]
    # the latest record with a quote, and its round's source and PDF: a gone comment whose text comes back
    q = next((int(j) for j, r in sorted(c["rounds"].items(), key=lambda jr: -int(jr[0]))
              if r["anchor"] and r["anchor"]["quote"]), None)
    pdf_q = next(r for r in lg["rounds"] if r["n"] == q)["build"]["pdf"] if q else None
    return {"id": c["id"], "anchor": c["rounds"][str(k)]["anchor"],
            "last": next((r["anchor"] for r in reversed(recs) if r["anchor"]), None),
            "quoted": c["rounds"][str(q)]["anchor"] if q else None,
            "quoted_at": (paper / "r{}".format(q) / "src", paper / pdf_q) if q and pdf_q else None,
            "guessed": placed["method"] == "line", "box": c["kind"] == "box", "point": point,
            "click": (paper / "r{}".format(p) / "src", paper / pdf_p, placed["anchor"]) if point and pdf_p else None}


def _older_shadows(paper, lg, m, progress):
    """Round m's shadows when it has none (ingested before them): the comments closed before round m, each carried
    from the round it was closed in into round m's source by one diff a closing round (anchor.shadows)."""
    by_round = {}
    for c in lg["comments"]:
        k, rec = comments.last_record(c)
        if k < m and rec["verdict"] in ("verified", "wontfix") and rec["anchor"]:
            by_round.setdefault(k, {})[c["id"]] = {"anchor": rec["anchor"], "closed": k, "verdict": rec["verdict"]}
    out = {}
    for k, items in sorted(by_round.items()):
        progress("Following the comments closed in round {}…".format(k))
        old, new = paper / "r{}".format(k), paper / "r{}".format(m)
        placed, _ = anchor.shadows(texdiff.diff_trees(old / "src", new / "src", old / "build", new / "build"),
                                   [{"id": cid, "anchor": s["anchor"]} for cid, s in items.items()])
        out.update({cid: dict(s, anchor=placed[cid]) for cid, s in items.items() if cid in placed})
    return out


def _shadows(paper, lg, n, diff, changes, progress):
    """The comments closed before round n carried into round n's source without the PDF (anchor.shadows), for
    analysis.json's `shadows` ({id: {"anchor", "closed": round, "verdict"}}); a change that edits one's sentence gets
    `near_closed` (its ids). Those closed in round n−1 start from their round-(n−1) anchors, earlier ones from round
    n−1's shadows, or for a round n−1 ingested before shadows (or whose shadows failed), from the rounds they were
    closed in (_older_shadows). A failure gives None, and the round's analysis.json has no `shadows`, so the next round
    derives them again rather than taking an empty set as all there is: the review does not depend on the hint."""
    try:
        old = (analysis.read(paper, n - 1) or {}).get("shadows")
        if old is None:  # round n−1 ingested before shadows, or its shadows failed: derived from the closing rounds
            old = _older_shadows(paper, lg, n - 1, progress)
        items = {}
        for c in lg["comments"]:
            rec = c["rounds"].get(str(n - 1))
            if rec is not None:
                if rec["verdict"] in ("verified", "wontfix") and rec["anchor"]:
                    items[c["id"]] = {"anchor": rec["anchor"], "closed": n - 1, "verdict": rec["verdict"]}
            elif c["id"] in old and str(n) not in c["rounds"]:
                items[c["id"]] = old[c["id"]]
        placed, near = anchor.shadows(diff, [{"id": cid, "anchor": s["anchor"]} for cid, s in items.items()])
        for ch, ids in zip(changes, near):
            if ids:
                ch["near_closed"] = ids
        return {cid: {"anchor": placed[cid], "closed": s["closed"], "verdict": s["verdict"]}
                for cid, s in sorted(items.items(), key=lambda kv: ledger.id_key(kv[0])) if cid in placed}
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        progress("Edits near closed comments could not be found: {}".format(e))
        return None


def _notes(diff, lg, n, changes, progress):
    """The students' notes of round n and their warnings (notes.find, which attaches the changes next to them). A
    failure leaves the round without notes and says so in a warning: the review does not depend on them."""
    progress("Reading the student's notes…")
    try:
        return notes.find(diff, lg, n, changes)
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        return {}, [{"kind": "error", "ids": [], "file": None, "line": None, "text": "",
                     "message": "The student's notes could not be read: {}".format(e)}]


def _store_context(paper, lg, c):
    """Store the card context of a comment's open-round record (cards.py)."""
    n = ledger.open_round(lg)["n"]
    c["rounds"][str(n)]["context"] = cards.record_context(paper, lg, c, n)


def comment(params, progress):
    paper = _paper(params)
    with _edit(paper) as lg:
        c = comments.create(paper, lg, _param(params, "page"), _param(params, "rects"), _param(params, "text", ""),
                            _param(params, "note", ""), _param(params, "kind", "highlight"),
                            color=_param(params, "color", "yellow"))
        if params.get("tags"):
            tags.set_tags(lg, c["id"], params["tags"], params.get("accepted"), params.get("names"))
        _store_context(paper, lg, c)
    return _state(paper, id=c["id"])


def tag(params, progress):
    """Set a comment's whole list of tags (tags.set_tags), on a comment of any round: tags change no round's record
    and nothing the student receives. With state: false the result is {id, tags} only (each click of the app's
    picker)."""
    paper = _paper(params)
    if "tags" not in params:
        raise EngineError("Missing parameter: tags")
    with _edit(paper) as lg:
        c = tags.set_tags(lg, _param(params, "id"), params["tags"] or [], params.get("accepted"), params.get("names"))
        out = {"id": c["id"], "tags": tags.ids(c)}
    if params.get("state", True) is not False:
        out["state"] = state.build(paper, params.get("round"))  # the round the app shows (default: the latest)
    return out


def retag(params, progress):
    """Merge Into… for one paper (tags.replace): every comment holding tag `from` gets `into` instead (`into` null:
    `from` taken off), read from the ledger as it is now, so a tag put on since the app last read the paper is kept.
    Any round, closed or not. The result is {changed: [ids]}, with the state of `round` (default: the latest) unless
    state: false."""
    paper = _paper(params)
    source = _param(params, "from")
    if "into" not in params:
        raise EngineError("Missing parameter: into")
    with _edit(paper) as lg:
        changed = tags.replace(lg, source, params["into"], params.get("names"))
    out = {"changed": changed}
    if params.get("state", True) is not False:
        out["state"] = state.build(paper, params.get("round"))
    return out


def revive(params, progress):
    """The advisor's Reopen: bring a comment closed in an earlier round (its last record verified or wontfix) back
    into the open round, to check. Not the verdict `reopened`, which is Follow up. Its round-n record is placed from
    the round it was closed in (round k) by the normal carry (anchor.carry) over a diff of round k's source against
    round n's, so its anchor_state says what changed since it was closed; it has verdict null and `revived`:
    {"from": k, "at"}; the round's changes in its new sentence are attached to it; its card's text is compared with
    round k's. After the round it is carried like any comment. With undo: true, a revived comment's round-n record
    goes again (its answer and follow-up too) and the changes attached to it are unattached."""
    paper = _paper(params)
    cid = _param(params, "id")
    if params.get("undo"):
        with _edit(paper) as lg:
            rnd = comments.require_open(lg)
            n = rnd["n"]
            c = ledger.get_comment(lg, cid)
            if not (c["rounds"].get(str(n)) or {}).get("revived"):
                raise EngineError("{} was not reopened in Round {}.".format(cid, n))
            del c["rounds"][str(n)]
            _unattach(paper, rnd, cid)
        return _state(paper)
    with _edit(paper, keep="reopen") as lg:
        c, rnd = comments.require_revivable(lg, cid)
        n = rnd["n"]
        k, _ = comments.last_record(c)
        before = next(r for r in lg["rounds"] if r["n"] == k)["build"]["pdf"]
        old_src, src = paper / "r{}".format(k) / "src", paper / "r{}".format(n) / "src"
        progress("Comparing Round {} with Round {}…".format(k, n))
        diff = texdiff.diff_trees(old_src, src, old_src.parent / "build", src.parent / "build")
        records, _ = anchor.carry(old_src, src, paper / rnd["build"]["pdf"], diff, [_carry_item(paper, lg, c, k)],
                                  old_pdf=paper / before if before else None)
        rec = c["rounds"][str(n)] = dict(records[cid], verdict=None, verdict_note="", verdict_at=None,
                                         revived={"from": k, "at": ledger.now()})
        if rec["anchor"] and any(ch["kind"] != "move" for ch in _reattach(paper, lg, c)) \
                and rec["anchor_state"] not in ("gone", "orphan"):
            rec["anchor_state"] = "changed"  # an edit of this round in its sentence: what broke it
        rec["context"] = cards.record_context(paper, lg, c, n,
                                              (analysis.read(paper, n, staged=True) or {}).get("changes", []))
    return _state(paper)


def _unattach(paper, rnd, cid):
    """Take comment cid off the changes of round rnd it was attached to (undoing a revive): staged, swapped in with
    the ledger (analysis.py)."""
    data = analysis.read(paper, rnd["n"], staged=True)
    if data is None:
        return
    for ch in data["changes"]:
        if cid in ch["attached_to"]:
            ch["attached_to"] = [i for i in ch["attached_to"] if i != cid]
            ch["unrequested"] = not ch["attached_to"]
    analysis.stage(paper, rnd, data)


def edit_comment(params, progress):
    paper = _paper(params)
    with _edit(paper) as lg:
        comments.edit(lg, _param(params, "id"), params.get("note"), params.get("kind"), params.get("color"))
    return _state(paper)


def reanchor(params, progress):
    paper = _paper(params)
    with _edit(paper) as lg:
        c, placed = comments.reanchor(paper, lg, _param(params, "id"), _param(params, "page"), _param(params, "rects"),
                                      _param(params, "text", ""), params.get("kind"))
        n = ledger.open_round(lg)["n"]
        if c["created_round"] != n and placed and any(ch["kind"] != "move" for ch in _reattach(paper, lg, c)):
            c["rounds"][str(n)]["anchor_state"] = "changed"  # the student edited the sentence it is now on
        _store_context(paper, lg, c)
    return _state(paper)


def _reattach(paper, lg, c):
    """After a carried comment was placed anew, attach to it the round's changes that start in its sentence (in
    place of those attached by carry); those its student note names (notes.find) stay attached, and its note's
    "elsewhere" becomes those of them outside the new sentence. Returns the changes in its sentence."""
    rnd = ledger.open_round(lg)
    n = rnd["n"]
    data = analysis.read(paper, n, staged=True)
    if data is None:
        return []
    a = c["rounds"][str(n)]["anchor"]
    tex = comments.source_path(paper / "r{}".format(n) / "src", paper / rnd["build"]["pdf"], a["file"]) \
        .read_text(encoding="utf-8", errors="replace")
    s, e = texdiff.sentence(tex, a["start"], a["end"])
    first, last = tex.count("\n", 0, s) + 1, tex.count("\n", 0, e) + 1
    here = []
    for ch in data["changes"]:
        att = [cid for cid in ch["attached_to"] if cid != c["id"]]
        inside = ch["file"] == a["file"] and ch["line"] is not None and first <= ch["line"] <= last \
            and not texdiff.break_only(ch)  # a paragraph split or joined changes no sentence
        if inside:
            here.append(ch)
        if inside or c["id"] in ch.get("student_notes", []):
            att = sorted(att + [c["id"]], key=ledger.id_key)
        ch["attached_to"], ch["unrequested"] = att, not att
    analysis.stage(paper, rnd, data)  # swapped in with the ledger
    note = c["rounds"][str(n)].get("student_note")
    if note:
        note["elsewhere"] = [i for i in note["changes"] if i not in {ch["id"] for ch in here}]
    return here


def delete_comment(params, progress):
    paper = _paper(params)
    with _edit(paper) as lg:
        comments.delete(lg, _param(params, "id"))
    return _state(paper)


def verdict(params, progress):
    paper = _paper(params)
    if "verdict" not in params:
        raise EngineError("Missing parameter: verdict")
    with _edit(paper) as lg:
        comments.set_verdict(lg, _param(params, "id"), params["verdict"], _param(params, "note", ""))
    return _state(paper)


def import_(params, progress):
    paper = _paper(params)
    with _edit(paper) as lg:
        result = comments.import_pdf(paper, lg, _param(params, "pdf"))
        for cid in result["ids"]:
            _store_context(paper, lg, ledger.get_comment(lg, cid))
    return _state(paper, **result)


def _checks_flag(params):
    """The `checks` given (default false): whether the round's check items go to the student (the app's Checks
    setting)."""
    flag = params.get("checks", False)
    if not isinstance(flag, bool):
        raise EngineError("checks is true or false.")
    return flag


def finish(params, progress):
    paper = _paper(params)
    send = _checks_flag(params)
    with _edit(paper, keep="finish") as lg:
        rnd = comments.require_open(lg)
        n = rnd["n"]
        rdir = paper / "r{}".format(n)
        if send:  # synced once more with checks.json when it is current (else as last synced); an item marked OK
            # before it was sent never goes out
            groups = _check_groups(params) if "groups" in params else rnd.get("check_groups", list(checks.GROUPS))
            disabled = _check_disabled(params) if "disabled" in params else rnd.get("check_disabled", [])
            rnd["check_groups"] = groups
            if disabled or "check_disabled" in rnd:
                rnd["check_disabled"] = disabled
            found = checks.load(paper, n)
            if found is not None:
                check_items.sync(lg, n, found["checks"], groups, disabled, check_report.failed(found))
            # A setting changed while checks were rebuilding: honour it even without a current cache.
            for item in (lg.get("check_items") or {}).values():
                if str(n) in item["rounds"] and (item["code"] in disabled or item["group"] not in groups):
                    item["rounds"][str(n)]["state"] = None
            check_items.drop(lg, n, unsent=True)
        else:  # nothing goes out: the open items stay open for a later round
            check_items.drop(lg, n)
        sent = check_items.outgoing(lg, n) if send else None
        rnd.pop("checks_sent", None)
        rnd.pop("checks_fixed", None)
        if send:
            rnd["checks_sent"] = len(sent["items"]) if sent else 0
            rnd["checks_fixed"] = len(sent["fixed"]) if sent else 0
        prose.materialize(paper, lg)  # before closing: an older ledger counts the rounds closed before as read
        progress("Writing final.pdf…")
        render.final_pdf(paper, lg, n, rdir / "final.pdf", sent)
        disk.atomic_write(rdir / "email.txt", render.email_text(lg, n, sent))
        # every paragraph is read once the round is closed (round 1: the advisor read it in the PDF while
        # commenting), so the next round's bars are the paragraphs changed since; after final.pdf, which lists the
        # changes read in this round only
        # the hashes it marks are kept, so Resume can take them off again
        rnd["marked_read"] = prose.close_read(lg, n, prose.load(paper, n) or _prose(paper, lg, n, None, progress))
        # the round's checksums, last: a closed round never changes, so damage shows in any copy (DATA.md §2.4)
        disk.write_manifest(rdir, Path(rnd["build"]["pdf"]).stem)
        rnd["closed"], rnd["closed_at"] = True, ledger.now()
    return _state(paper)


EARLIER = "earlier"  # rN/earlier/: what each earlier Finish of round N wrote, kept there by Resume
KEPT = {"final": "final.pdf", "email": "email.txt", "manifest": disk.MANIFEST}  # a finish's key: the round's file


def _kept_name(key, stamp):
    """The name a finish's file (KEPT) is kept under in rN/earlier/: "final 2026-10-21 1530.pdf" (stamp: the finish's
    local time, with " 2", " 3"… when taken)."""
    stem, ext = os.path.splitext(KEPT[key])
    return "{} {}{}".format(stem, stamp, ext)


def _kept(key, name):
    """Whether a file name in rN/earlier/ is one Resume gives a finish's file of that key."""
    stem, ext = os.path.splitext(KEPT[key])
    return re.fullmatch(re.escape(stem) + r" \d{4}-\d{2}-\d{2} \d{4}(?: \d+)?" + re.escape(ext), name) is not None


def _loose(paper, rnd):
    """{key: [files]} of round rnd's rN/earlier/ kept by a Resume that none of the round's finishes names (one killed
    before the ledger was saved, or a ledger from before a Resume): plain files named as Resume names them."""
    folder = Path(paper) / "r{}".format(rnd["n"]) / EARLIER
    if not folder.is_dir():
        return {}
    named = {f.get(k) for f in rnd.get("finishes") or () if isinstance(f, dict) for k in KEPT}
    out = {}
    for p in sorted(folder.iterdir()):
        key = next((k for k in KEPT if _kept(k, p.name)), None)
        if key and p.is_file() and not p.is_symlink() \
                and "r{}/{}/{}".format(rnd["n"], EARLIER, p.name) not in named:
            out.setdefault(key, []).append(p)
    return out


def _unresumed(paper, lg):
    """What to put back after a Resume that lg does not record: its latest round finished, a file of it missing
    (final.pdf, email.txt, its checksums) and exactly one file of that kind in rN/earlier/ that none of its finishes
    names (_loose): [(that file, the round's file)]. After a kill before the ledger was saved (_recover), or for a
    version from before the Resume that Put Back puts back."""
    rnd = ledger.latest_round(lg)
    if rnd is None or not rnd.get("closed"):
        return []
    rdir = Path(paper) / "r{}".format(rnd["n"])
    return [(files[0], rdir / KEPT[key]) for key, files in _loose(paper, rnd).items()
            if len(files) == 1 and not os.path.lexists(str(rdir / KEPT[key]))]


def resume_round(params, progress):
    """Resume Round N: the latest round, finished, open again as it was before Finish, to add and change comments and
    finish it again; refused while it is open (a next round started makes the round before it final). It changes no
    source and builds nothing. What Finish wrote is never deleted or overwritten (the student may have it): final.pdf,
    email.txt and the round's checksums move into rN/earlier/, named for that finish's local time ("final 2026-10-21
    1530.pdf"), and the round's `finishes` records it ({"at": its closed_at, "resumed", "final", "email", "manifest":
    paths relative to the paper, null for a file that was not there}); the paragraphs that Finish marked read are
    unread again (prose.open_read). The version before is copied into .history (kind resume), kept for good. A move
    that fails puts back those made; after a kill before the ledger is saved, the next locked call (or state) puts
    them back (_recover)."""
    paper = _paper(params)
    with _edit(paper) as lg:
        rnd = ledger.latest_round(lg)
        if rnd is None:
            raise EngineError("There is no round yet. Ingest the student's source first.")
        n = rnd["n"]
        if not rnd["closed"]:
            raise EngineError("Round {} is open already: only a finished round can be resumed.".format(n))
        history.keep(paper, (paper / "ledger.json").read_bytes(), lg, "resume")
        rdir, prefix = paper / "r{}".format(n), "r{}/{}/".format(n, EARLIER)
        try:
            stamp = datetime.datetime.fromisoformat(rnd["closed_at"]).strftime("%Y-%m-%d %H%M")
        except (TypeError, ValueError):
            stamp = datetime.datetime.now().strftime("%Y-%m-%d %H%M")
        named = {f.get(k) for f in rnd.get("finishes") or () if isinstance(f, dict) for k in KEPT}
        k = 1
        while True:
            names = {key: _kept_name(key, stamp if k == 1 else "{} {}".format(stamp, k)) for key in KEPT}
            if not any(os.path.lexists(str(rdir / EARLIER / v)) or prefix + v in named for v in names.values()):
                break
            k += 1
        (rdir / EARLIER).mkdir(exist_ok=True)
        moved = []
        try:
            for key, name in KEPT.items():
                if (rdir / name).is_file():
                    disk.move(rdir / name, rdir / EARLIER / names[key])
                    moved.append(key)
        except BaseException:
            for key in reversed(moved):
                disk.move(rdir / EARLIER / names[key], rdir / KEPT[key])
            raise
        rnd.setdefault("finishes", []).append(dict({"at": rnd["closed_at"], "resumed": ledger.now()},
                                                   **{key: prefix + names[key] if key in moved else None
                                                      for key in KEPT}))
        prose.open_read(lg, n, rnd.pop("marked_read", None))
        rnd["closed"], rnd["closed_at"] = False, None
    return _state(paper)


def check_change(params, progress):
    """Marks a change of the open round as checked by the advisor (checked: false clears it)."""
    paper = _paper(params)
    cid = _param(params, "id")
    with _edit(paper) as lg:
        rnd = comments.require_open(lg)
        ids = [ch["id"] for ch in (analysis.read(paper, rnd["n"]) or {}).get("changes", [])]
        if cid not in ids:
            raise EngineError("Round {} has no change {}.".format(rnd["n"], cid))
        done = set(rnd.get("checked", [])) - {cid}
        rnd["checked"] = sorted(done | ({cid} if _param(params, "checked", True) else set()))
    return _state(paper)


def prose_(params, progress):
    """Round n's prose.json (default: the latest round): its paragraphs for reading, built when missing or stale. With
    state: false the result has no state (the overview's second engine process fills in closed rounds with it). A
    build that fails is noted (prose.record_failure), so the overview shows the round's sections as unavailable."""
    paper = _paper(params)
    lg = ledger.load(paper)
    n = params.get("round")
    rnd = ledger.latest_round(lg) if n is None else next((r for r in lg["rounds"] if r["n"] == n), None)
    if rnd is None:
        raise EngineError("There is no round {}.".format(n) if n is not None else
                          "There is no round yet. Ingest the student's source first.")
    if prose.load(paper, rnd["n"]) is None:
        if not rnd["build"]["pdf"]:
            raise EngineError("Round {} has no build PDF.".format(rnd["n"]))
        with ledger.locked(paper):  # building writes the blocks each change touches into analysis.cache.json
            try:
                prose.ensure(paper, ledger.load(paper), rnd["n"], progress)
            except Exception as e:
                prose.record_failure(paper, rnd["n"], e)
                raise
    out = {"path": str(prose.path(paper, rnd["n"]))}
    if params.get("state", True) is not False:
        out["state"] = state.build(paper, n)
    return out


def _built_round(paper, lg, n):
    """Round n of the paper (the latest when n is None), refused when it does not exist or has no build PDF."""
    rnd = ledger.latest_round(lg) if n is None else next((r for r in lg["rounds"] if r["n"] == n), None)
    if rnd is None:
        raise EngineError("There is no round {}.".format(n) if n is not None else
                          "There is no round yet. Ingest the student's source first.")
    if not rnd["build"]["pdf"]:
        raise EngineError("Round {} has no build PDF.".format(rnd["n"]))
    return rnd


def _prose_quietly(paper, n, progress):
    """Round n's prose.json, built when missing or stale (under the ledger lock, as the prose RPC), or None when its
    paragraphs cannot be found (noted in rN/prose.failed, the error on stderr)."""
    data = prose.load(paper, n)
    if data is None and not prose.failed(paper, n):
        with ledger.locked(paper):  # as the prose RPC: building writes analysis.cache.json
            try:
                data = prose.ensure(paper, ledger.load(paper), n, progress)
            except Exception as e:
                traceback.print_exc(file=sys.stderr)
                prose.record_failure(paper, n, e)
    return data


def links_(params, progress):
    """Round n's link table (default: the latest round; links.py, rN/links.json), read only and without state: built
    when missing or stale, after the round's prose.json. `table` is null when it cannot be built (the paragraphs
    cannot be found, an error: on stderr): the app then follows a link as before."""
    paper = _paper(params)
    lg = ledger.load(paper)
    rnd = _built_round(paper, lg, params.get("round"))
    table = links.load(paper, rnd["n"])
    if table is None:
        data = _prose_quietly(paper, rnd["n"], progress)
        if data is not None:
            table = links.build_quietly(paper, lg, rnd["n"], data)
    return {"round": rnd["n"], "path": str(links.path(paper, rnd["n"])) if table is not None else None,
            "table": table}


def checks_(params, progress):
    """Round n's checks (default: the latest round; checks.py, rN/checks.json; design/pdf-reader/PLAN.md P1.5), read
    only and without state: built when missing or stale, after the round's prose.json and link table, and only when
    asked (the app asks while Checks is on). `checks` is null when the paragraphs cannot be found or the checks
    cannot be built (an error: on stderr); a link table that cannot be built leaves the checks that need it empty."""
    paper = _paper(params)
    lg = ledger.load(paper)
    rnd = _built_round(paper, lg, params.get("round"))
    found = _checks_built(paper, lg, rnd["n"], progress)
    ok = lg.get("checks_ok") or {}
    groups = rnd.get("check_groups", []) if rnd["closed"] else _check_groups(params)
    disabled = rnd.get("check_disabled", []) if rnd["closed"] else _check_disabled(params)
    if rnd["closed"] and "checks_sent" not in rnd:
        groups = []
    return {"round": rnd["n"], "path": str(checks.path(paper, rnd["n"])) if found is not None else None,
            "report": check_report.selected(found.get("report"), groups, disabled) if found else None,
            "checks": [dict(c, ok=c["key"] in ok) for c in found["checks"]]
            if found is not None else None}


def _checks_built(paper, lg, n, progress):
    """Round n's checks.json, built when missing or stale (after its prose.json and link table; again with the table
    when built without it and the table can now be built), or None when it cannot be built."""
    found = checks.load(paper, n)
    if found is not None and not found["table"]:  # built without the table: try it again (once a process if it fails)
        data = prose.load(paper, n)
        if data is not None and links.build_quietly(paper, lg, n, data) is not None:
            found = None
    if found is None:
        data = _prose_quietly(paper, n, progress)
        if data is not None:
            table = links.load(paper, n) or links.build_quietly(paper, lg, n, data)
            found = checks.build_quietly(paper, lg, n, data, table)
    return found


def references(params, progress):
    """Round n's cited entries (default: the latest round; refs.py, rN/refs.json; design/pdf-reader/PLAN.md P1.3) and
    the online look-ups' results stored for them, read only and without state: {"round", "entries", "results":
    {source: {key: Result}}}. The entries are built with the round's checks (built first when missing or stale, as the
    checks RPC does); `entries` is null when the checks cannot be built."""
    paper = _paper(params)
    lg = ledger.load(paper)
    n = _built_round(paper, lg, params.get("round"))["n"]
    data = refs.load(paper, n) if _checks_built(paper, lg, n, progress) is not None else None
    entries = data.get("entries") if data else None
    keys = {e["key"] for e in entries or ()}
    return {"round": n, "entries": entries,
            "attempts": {s: {k: a for k, a in attempts.items() if k in keys}
                         for s, attempts in (data or {}).get("attempts", {}).items()},
            "results": {s: {k: r for k, r in found.items() if k in keys} for s, found in data["results"].items()}
            if entries is not None else {}}


def ref_results(params, progress):
    """Store one source's look-ups for round n's cited entries (refs.store: merged by key into rN/refs.json, any round,
    open or closed), so the round's checks are stale and built again: {"stored": k}, without state. The entries are
    built first when refs.json has none (as `references`); a key the round does not cite is refused."""
    paper = _paper(params)
    lg = ledger.load(paper)
    n = _param(params, "round")
    if not isinstance(n, int) or isinstance(n, bool):
        raise EngineError("round is a round's number.")
    n = _built_round(paper, lg, n)["n"]
    if not isinstance((refs.load(paper, n) or {}).get("entries"), list):
        _checks_built(paper, lg, n, progress)
    return {"stored": refs.store(paper, n, _param(params, "source"), _param(params, "results"), params.get("attempts"))}


def check_ok(params, progress):
    """Mark a check OK (or, with ok: false, not OK): the advisor looked and the paper is fine there. Kept in the
    ledger's checks_ok map, key (each check's, `checks._keys`: the same in every round while the slip is, or for its
    round alone when the slip is known only by its place) to the round it was marked in. Any round, open or closed: it is the advisor's own
    note, never the student's. {"checks_ok": [keys]}."""
    paper = _paper(params)
    key, flag = _param(params, "key"), _param(params, "ok", True)
    if not isinstance(key, str) or not key or not isinstance(flag, bool):
        raise EngineError("key is a check's key, ok true or false.")
    with _edit(paper) as lg:
        if flag:
            rnd = ledger.latest_round(lg)
            lg.setdefault("checks_ok", {})[key] = rnd["n"] if rnd else 0
        else:  # nothing written when there is nothing to clear
            lg.get("checks_ok", {}).pop(key, None)
        return {"checks_ok": sorted(lg.get("checks_ok") or {})}


def _check_groups(params):
    """The check groups asked (default: all five), in checks.GROUPS' order."""
    groups = params.get("groups")
    if groups is None:
        return list(checks.GROUPS)
    if not isinstance(groups, list) or not all(isinstance(g, str) and g in checks.GROUPS for g in groups):
        raise EngineError("groups is a list of {}.".format(", ".join(checks.GROUPS)))
    return [g for g in checks.GROUPS if g in groups]


def _check_disabled(params):
    disabled = params.get("disabled", [])
    if not isinstance(disabled, list) or not all(isinstance(c, str) and c in checks.CODES for c in disabled):
        raise EngineError("disabled is a list of known check codes.")
    return sorted(set(disabled))


def check_items_(params, progress):
    """Round n's check items (default: the latest round; check_items.py), without state: {"round", "items", "closed":
    {"fixed", "ok"}}. For the latest round while open, its records are first synced with its checks.json under the
    ledger's lock (check_items.sync, the groups asked; refused while the checks are not built: the app asks `checks`
    first), which gives new items their ids; a closed or earlier round is read as recorded."""
    paper = _paper(params)
    groups = _check_groups(params)
    disabled = _check_disabled(params)
    lg = ledger.load(paper)
    n = params.get("round")
    rnd = ledger.latest_round(lg) if n is None else next((r for r in lg["rounds"] if r["n"] == n), None)
    if rnd is None:
        raise EngineError("There is no round {}.".format(n) if n is not None else
                          "There is no round yet. Ingest the student's source first.")
    if rnd is not ledger.latest_round(lg) or rnd["closed"]:
        return check_items.views(lg, rnd["n"])
    found = checks.load(paper, rnd["n"])
    if found is None:
        raise EngineError("The round's checks are not built yet.")
    with _edit(paper) as lg:
        rnd = ledger.latest_round(lg)
        if rnd["n"] != found["round"] or rnd["closed"]:  # finished, or replaced, meanwhile: as recorded
            return check_items.views(lg, rnd["n"])
        check_items.sync(lg, rnd["n"], found["checks"], groups, disabled, check_report.failed(found))
        if rnd.get("check_groups") != groups:  # finish syncs again with them
            rnd["check_groups"] = groups
        if disabled or "check_disabled" in rnd:
            rnd["check_disabled"] = disabled
        return check_items.views(lg, rnd["n"])


def check_note(params, progress):
    """The advisor's words on a check item carried into the open round and open there (its round-n advisor_note: the
    follow-up of a check; empty text removes it). Returns the item's view (check_items.view), without state."""
    paper = _paper(params)
    cid, text = _param(params, "id"), _param(params, "text")
    if not isinstance(text, str):
        raise EngineError("text is the advisor's words, a string.")
    with _edit(paper) as lg:
        n = comments.require_open(lg)["n"]
        item = (lg.get("check_items") or {}).get(cid)
        if item is None or item["created_round"] >= n or str(n) not in item["rounds"] \
                or not check_items.is_open(lg, item, n):
            raise EngineError("{} is not a check carried into Round {} and open there.".format(cid, n))
        rec = item["rounds"][str(n)]
        if text.strip():
            rec["advisor_note"] = text
        else:
            rec.pop("advisor_note", None)
        return check_items.view(lg, item, n)


def follow(params, progress):
    """Where the reader's paragraph is in another round (design/pdf-reader/PLAN.md P1.1), read only and without state:
    round `round`'s block `block` in round `to` (prose.follow), else the nearest block before it that has one there
    (`exact` false: a paragraph new in its round, or rewritten, goes to its neighbour). `parts` are the block's places
    in round `to`'s PDF (prose.json, as `reading.paragraphs`). block null when either round's prose.json is not built
    (never built here: the app then keeps the page number) or nothing before it maps."""
    paper = _paper(params)
    frm, block, to = _param(params, "round"), _param(params, "block"), _param(params, "to")
    if not all(isinstance(v, int) and not isinstance(v, bool) for v in (frm, block, to)) or min(frm, to) < 1 or block < 0:
        raise EngineError("round, block and to are numbers.")
    rounds = {r["n"] for r in ledger.load(paper)["rounds"]}
    if frm not in rounds or to not in rounds:
        raise EngineError("There is no round {}.".format(frm if frm not in rounds else to))
    out = {"round": to, "block": None, "exact": False, "parts": []}
    if frm == to:
        out["block"], out["exact"] = block, True
    else:
        for b in range(block, max(block - 51, -1), -1):  # the block, then the nearest 50 before it at most
            k = prose.follow(paper, frm, b, to)
            if k is not None:
                out["block"], out["exact"] = k, b == block
                break
    data = prose.load(paper, to) if out["block"] is not None else None
    if data is None or not 0 <= out["block"] < len(data["blocks"]):
        return {"round": to, "block": None, "exact": False, "parts": []}
    out["parts"] = data["blocks"][out["block"]].get("parts") or []
    return out


def read(params, progress):
    """Mark blocks of the open round read (or, with read: false, unread): their hashes go into (or leave) the
    ledger's read map."""
    paper = _paper(params)
    blocks = _param(params, "blocks")
    flag = _param(params, "read", True)
    if not isinstance(blocks, list) or not all(isinstance(k, int) and not isinstance(k, bool) for k in blocks):
        raise EngineError("blocks is a list of paragraph numbers.")
    with _edit(paper) as lg:
        rnd = ledger.latest_round(lg)
        if rnd is not None and rnd["closed"]:
            raise EngineError("Round {} is closed.".format(rnd["n"]))
        n = comments.require_open(lg)["n"]
        data = prose.ensure(paper, lg, n, progress)
        bad = next((k for k in blocks if not 0 <= k < len(data["blocks"])), None)
        if bad is not None:
            raise EngineError("Round {} has no paragraph {}.".format(n, bad))
        rm = prose.materialize(paper, lg)
        for k in blocks:
            h = data["blocks"][k]["hash"]
            if h and flag:
                rm[h] = n  # read in this round: a block showing this round's edits needs it (prose.is_read)
            elif h:
                rm.pop(h, None)
    return _state(paper)


def state_(params, progress):
    """The latest round's state, or with "round" an earlier round's, read only (the app's round picker)."""
    paper = _paper(params)
    if any(paper.glob("r*.old*")) or any(paper.glob("r*/analysis.json.new")):  # a killed call: put back (_recover)
        with _edit(paper):
            pass
    out = state.build(paper, params.get("round"))
    if _unnamed(paper, [r["n"] for r in out["rounds"]]):  # an ingest stopped hard: its round to .orphans (_recover)
        with _edit(paper):
            pass
    last = out["rounds"][-1] if out["rounds"] else None
    rdir = paper / "r{}".format(last["n"]) if last else None
    if last and last["closed"] and (rdir / EARLIER).is_dir() \
            and not all(os.path.lexists(str(rdir / name)) for name in KEPT.values()) \
            and _unresumed(paper, ledger.load(paper)):  # a Resume killed before its save: its files back (_recover)
        with _edit(paper):
            pass
        out = state.build(paper, params.get("round"))
    return {"state": out}


def email_preview(params, progress):
    """The email `finish` would write for the open round now: render.email_text of the ledger as it stands, which
    depends on nothing else. Read only, for the app's Finish sheet; like summaries, its result has no state."""
    paper = _paper(params)
    send = _checks_flag(params)  # as finish's: with the round's check items as last synced
    lg = ledger.load(paper)
    n = comments.require_open(lg)["n"]
    return {"round": n, "text": render.email_text(lg, n, check_items.outgoing(lg, n) if send else None)}


def _int(v, least):
    return isinstance(v, int) and not isinstance(v, bool) and v >= least


def _facts(params):
    """The paper's three facts given in params (DATA.md §2.2), checked: finished, the day the advisor marked the paper
    finished ("YYYY-MM-DD") or null; buckets, the Map Headings answers ({section key: standard section, or null for a
    column of its own name; "" is read as null}) or null; key_page, the page chosen to stand for the paper ({round,
    page}, page 0-based) or null. A key not given is left out."""
    out = {}
    if "finished" in params:
        f = params["finished"]
        try:
            ok = f is None or bool(isinstance(f, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", f)
                                   and datetime.date.fromisoformat(f))
        except ValueError:
            ok = False
        if not ok:
            raise EngineError("finished is a day (YYYY-MM-DD) or null.")
        out["finished"] = f
    if "buckets" in params:
        b = params["buckets"]
        if b is not None and not (isinstance(b, dict) and all(isinstance(k, str) and (v is None or isinstance(v, str))
                                                              for k, v in b.items())):
            raise EngineError("buckets maps a section key to a standard section or null.")
        out["buckets"] = None if b is None else {k: v or None for k, v in b.items()}
    if "key_page" in params:
        k = params["key_page"]
        if k is not None and not (isinstance(k, dict) and _int(k.get("round"), 1) and _int(k.get("page"), 0)):
            raise EngineError("key_page is {round, page} or null.")
        out["key_page"] = None if k is None else {"round": k["round"], "page": k["page"]}
    return out


def edit_paper(params, progress):
    """Set a paper's title or student (or both): to correct a name, or to put the papers of one student written in
    different ways under one name (the overview groups papers by student). White space is collapsed. Also its three
    facts (_facts: finished, buckets, key_page), each when the key is given, null clearing it; and shell_escape, the
    advisor's choice without a build (from the next ingest: an open round with comments is not built again)."""
    paper = _paper(params)
    fields = {}
    for key, what in (("title", "A paper's title"), ("student", "The student's name")):
        value = params.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or not value.split():
            raise EngineError("{} cannot be empty.".format(what))
        fields[key] = " ".join(value.split())
    fields.update(_facts(params))
    escape = _shell_escape(params)
    if not fields and escape is None:
        raise EngineError("Give the paper's title or the student's name.")
    with _edit(paper) as lg:
        lg["paper"].update(fields)
        if escape is not None:
            _choose_shell_escape(lg["paper"], escape)
    return _state(paper)


FACTS = ("finished", "buckets", "key_page")


def adopt_facts(params, progress):
    """Move the app's values of the three facts (papers.json) into the ledger, once per paper (DATA.md §2.2): a fact
    the ledger lacks and the app gives (not null, not {}) is written; one the ledger has, even as null, is never
    overwritten, so asking again changes nothing (and writes nothing). No state: {"adopted": [names written], "paper":
    {"id", "finished", "buckets", "key_page"}} as the ledger now has them (null when it lacks one)."""
    paper = _paper(params)
    given = {k: v for k, v in _facts(params).items() if v not in (None, {})}
    with _edit(paper) as lg:
        p = lg["paper"]
        adopted = [k for k in FACTS if k in given and k not in p]
        p.update((k, given[k]) for k in adopted)
        facts = {k: p.get(k) for k in ("id",) + FACTS}
    return {"adopted": adopted, "paper": facts}


def fork(params, progress):
    """Give the paper a new id, recording the one it had in paper.forked_from (DATA.md §2.3: a copy listed beside the
    paper it was copied from, or Keep Both): {"id", "forked_from", "state"}."""
    paper = _paper(params)
    with _edit(paper) as lg:
        p = lg["paper"]
        p["forked_from"], p["id"] = p["id"], ledger.new_paper_id()
        out = {"id": p["id"], "forked_from": p["forked_from"]}
    return _state(paper, **out)


def history_(params, progress):
    """The saved versions of the paper's ledger, newest first (history.versions), for Put Back an Earlier Ledger…:
    read only, no state, and it works when the ledger cannot be read."""
    paper = _paper(params)
    if not paper.is_dir():
        raise EngineError("There is no folder {}.".format(paper))
    return {"versions": history.versions(paper)}


def put_back_ledger(params, progress):
    """Put back a saved version of the ledger (`version`: a name from history) as a new version: its rev past the
    replaced one's, the replaced one on its trail and copied into .history as it was (kept for good, even when it
    cannot be read), so an older export never looks newer; the paper's id and shell escape as they are now; the
    version's analysis.json of its open round comes back with it. Refused when the version lacks a round that is on
    disk, or shows open a round that is closed (in the ledger, or finished on disk), or is from before a Resume whose
    kept files (rN/earlier/) it cannot match; a version from just before a Resume of a round still open gets that
    round's files back from rN/earlier/ (_unresumed). Works when the ledger cannot be read."""
    paper = _paper(params)
    name = _param(params, "version")
    with ledger.locked(paper):
        raw, kept_analysis = history.read(paper, name)
        copy, bad = check.read_ledger(raw)
        if bad:
            raise EngineError("This saved version cannot be read, so it cannot be put back.")
        try:
            current = ledger.load(paper)
        except (EngineError, ValueError, OSError):
            current = None
        if current is not None:
            _recover(paper, current)
        else:
            analysis.settle(paper, None)
        on_disk = sorted(int(d.name[1:]) for d in paper.iterdir() if d.is_dir() and re.fullmatch(r"r\d+", d.name))
        lost = [n for n in on_disk if n not in {r.get("n") for r in copy["rounds"]}]
        if lost:
            raise EngineError("This version does not have Round {}, which is on disk: putting it back would lose "
                              "it.".format(lost[0]))
        # a round started again with a new source since (an open round without comments, re-ingested) is another
        # round under the same number: the version's record of it (and its analysis.json) would not match the disk
        created = {r.get("n"): r.get("created") for r in (current or {}).get("rounds", []) if isinstance(r, dict)}
        redone = [r["n"] for r in copy["rounds"] if r.get("n") in created and r.get("created") != created[r["n"]]]
        if redone:
            raise EngineError("This version is from before Round {} was started again with a new source: putting it "
                              "back would not match that round's files.".format(redone[0]))
        closed = {r["n"] for r in (current or {}).get("rounds", []) if r.get("closed")} \
            | {n for n in on_disk if (paper / "r{}".format(n) / disk.MANIFEST).is_file()}
        undone = [r["n"] for r in copy["rounds"] if not r.get("closed") and r.get("n") in closed]
        if undone:
            raise EngineError("In this version Round {} is still open, but it has been finished since: putting it "
                              "back would undo that.".format(undone[0]))
        back = _unresumed(paper, copy)  # from just before a Resume: the round's files come back, after the save
        moved = {kept for kept, _ in back}
        resumed = [r["n"] for r in copy["rounds"]
                   if any(f not in moved for fs in _loose(paper, r).values() for f in fs)]
        # the resumed round's edits may have changed its analysis.json (_reattach): finished again as in the version,
        # it gets back the one its checksums list, kept with the copy before the Resume (a Finish copy keeps none)
        last, restage = ledger.latest_round(copy), None
        want = last.get("analysis_sha256") if back else None
        if isinstance(want, str) and not resumed and (not analysis.path(paper, last["n"]).is_file()
                                                      or disk.sha256(analysis.path(paper, last["n"])) != want):
            if kept_analysis and kept_analysis[0] == last["n"] \
                    and hashlib.sha256(kept_analysis[1]).hexdigest() == want:
                restage = kept_analysis[1]
            else:
                resumed = [last["n"]]
        if resumed:
            raise EngineError("This version is from before Round {} was resumed: putting it back would not match that "
                              "round's files.".format(resumed[0]))
        seqs = {r.get("n"): r.get("last_seq") for r in (current or {}).get("rounds", []) if isinstance(r, dict)}
        for r in copy["rounds"]:  # ids given out since stay used (CONTRACT §4)
            if isinstance(seqs.get(r["n"]), int) and isinstance(r.get("last_seq"), int):
                r["last_seq"] = max(r["last_seq"], seqs[r["n"]])
        check_seqs = {r.get("n"): r.get("last_check_seq") for r in (current or {}).get("rounds", [])
                      if isinstance(r, dict)}
        for r in copy["rounds"]:  # and so do check items' (check_items.py)
            if isinstance(check_seqs.get(r["n"]), int):
                r["last_check_seq"] = max(r.get("last_check_seq") or 0, check_seqs[r["n"]])
        if (paper / "ledger.json").exists():
            history.keep(paper, (paper / "ledger.json").read_bytes(), current, "replaced")
        trail = list((current or copy).get("trail") or [])
        if current is not None and ledger.version(current) not in [e[:2] for e in trail if isinstance(e, list)]:
            trail.append(ledger.version(current))  # written by an older engine: on the trail all the same
        copy["trail"] = trail
        copy["rev"] = max([ledger.version(current or {})[0], ledger.version(copy)[0]]  # save adds 1
                          + [v["rev"] for v in history.versions(paper)])  # past any version kept, readable or not
        copy["paper"]["id"] = ((current or {}).get("paper") or {}).get("id") or copy["paper"].get("id") \
            or ledger.derived_id(paper, copy)
        # shell escape stays the advisor's choice as it is now, never a version's: one kept in .history from before an
        # import took it off (archive._distrusted) would turn it on without the advisor; off when the ledger is unread
        _choose_shell_escape(copy["paper"], ((current or {}).get("paper") or {}).get("shell_escape") is True)
        rnd = ledger.open_round(copy)
        if rnd is not None and kept_analysis and kept_analysis[0] == rnd["n"]:
            analysis.stage(paper, rnd, kept_analysis[1])
        elif rnd is not None and analysis.path(paper, rnd["n"]).is_file():
            rnd["analysis_sha256"] = disk.sha256(analysis.path(paper, rnd["n"]))
        elif restage is not None:  # swapped in with the ledger, as an open round's
            analysis.stage(paper, last, restage)
        ledger.save(paper, copy)
        analysis.settle(paper, copy)
        for kept, where in back:  # killed before this: the next locked call does it (_recover)
            disk.move(kept, where)
    return _state(paper)


def check_(params, progress):
    """The read-only check of paper folders (check.py; DATA.md §6.3): {"papers": [{"path", "problems"} | {"path",
    "error"}]}, in the order given; a folder that cannot be read gets its error. No state, no lock, nothing written."""
    papers = _param(params, "papers")
    if not isinstance(papers, list) or not all(isinstance(p, str) for p in papers):
        raise EngineError("papers is a list of paper folders.")
    out = []
    for p in papers:
        try:
            out.append({"path": p, "problems": check.paper(p)})
        except Exception as e:  # one folder that cannot be checked does not fail the others
            out.append({"path": p, "error": str(e) or type(e).__name__})
    return {"papers": out}


def overview_(params, progress):
    """The overview of one or more papers (overview.py): read only, no state, like summaries."""
    papers = _param(params, "papers")
    if not isinstance(papers, list) or not all(isinstance(p, str) for p in papers):
        raise EngineError("papers is a list of paper folders.")
    buckets = params.get("buckets") or {}
    if not isinstance(buckets, dict) or not all(isinstance(m, dict) for m in buckets.values()):
        raise EngineError("buckets maps a paper folder to {section key: standard section}.")
    key_pages = params.get("key_pages") or {}
    if not isinstance(key_pages, dict) or not all(
            isinstance(k, dict) and all(isinstance(k.get(f), int) and not isinstance(k.get(f), bool)
                                        for f in ("round", "page")) for k in key_pages.values()):
        raise EngineError("key_pages maps a paper folder to {round, page}.")
    order = params.get("tag_order")
    if order is not None:
        order = tags.check(order, "tag_order", limit=None)
    return overview.overview(papers, marks=bool(params.get("marks", False)), buckets=buckets, key_pages=key_pages,
                             tag_order=order)


def summaries(params, progress):
    """The papers list's next steps (state.summary), one per paper folder, without a state, with the paper's title and
    student (the sidebar groups the papers by student), id and finished day; a folder that cannot be read gets its
    error instead."""
    out = []
    for p in _param(params, "papers"):
        try:
            lg = ledger.load(p)
            out.append({"path": p, "summary": state.summary(Path(p), lg),
                        "paper": {"title": lg["paper"]["title"], "student": lg["paper"]["student"],
                                  "id": ledger.paper_id(p, lg), "finished": lg["paper"].get("finished")}})
        except (EngineError, OSError, ValueError) as e:
            out.append({"path": p, "error": str(e)})
    return {"papers": out}


def export_comments(params, progress):
    """Every comment of each paper folder, round by round (export.py), for the app's export to CSV or JSON: read only,
    no state, like summaries; a folder that cannot be read gets its error instead."""
    papers = _param(params, "papers")
    if not isinstance(papers, list) or not all(isinstance(p, str) for p in papers):
        raise EngineError("papers is a list of paper folders.")
    out = []
    for p in papers:
        try:
            out.append(dict(export.comments(p), path=p))
        except (EngineError, OSError, ValueError) as e:
            out.append({"path": p, "error": str(e) or type(e).__name__})
    return {"papers": out}


def _cancelled(progress):
    """Whether the app asked to cancel the request: rpc.py's progress says so (its `cancel`); the CLI's never does."""
    return getattr(progress, "cancelled", None) or (lambda: False)


def archive_write(params, progress):
    """Write an export file (archive.write; DATA.md §3): {"path", "bytes", "backup"}, no state. Progress: "Writing
    “…” (1 of 3)…", then "Checking…"; `cancel` stops it and leaves nothing."""
    return archive.write(_param(params, "papers"), _param(params, "dest"), scope=params.get("scope") or "chosen",
                         kind=params.get("kind") or "export", tags=params.get("tags"), drafts=params.get("drafts"),
                         settings=params.get("settings"), made_by=params.get("made_by"), progress=progress,
                         cancelled=_cancelled(progress))


def archive_check(params, progress):
    """What a file or folder holds, each paper compared with the app's list (archive.check; DATA.md §5.2): read only,
    no state."""
    return archive.check(_param(params, "path"), params.get("papers") or [], progress, _cancelled(progress))


def archive_info(params, progress):
    """What each file says it holds, from its backup.json alone (archive.info): {"files"}, read only, no state."""
    return archive.info(_param(params, "paths"))


def archive_unpack(params, progress):
    """One paper of a file into a new folder (archive.unpack; DATA.md §5.4): {"path", "id", "problems"}, no state."""
    return archive.unpack(_param(params, "path"), _param(params, "paper"), _param(params, "dest"),
                          fork=bool(params.get("fork")), copy=bool(params.get("copy")), progress=progress,
                          cancelled=_cancelled(progress))


def swap_in(params, progress):
    """Use This Copy (archive.swap_in; DATA.md §5.4): {"path", "replaced"}, no state."""
    return archive.swap_in(_param(params, "incoming"), _param(params, "current"))


METHODS = {"new": new, "ingest": ingest, "comment": comment, "edit_comment": edit_comment, "reanchor": reanchor,
           "delete_comment": delete_comment, "verdict": verdict, "import": import_, "finish": finish,
           "check_change": check_change, "state": state_, "summaries": summaries, "prose": prose_, "links": links_,
           "checks": checks_, "check_ok": check_ok, "check_items": check_items_, "check_note": check_note,
           "references": references, "ref_results": ref_results,
           "follow": follow, "read": read,
           "email_preview": email_preview, "edit_paper": edit_paper, "overview": overview_, "tag": tag, "retag": retag,
           "revive": revive, "export_comments": export_comments, "adopt_facts": adopt_facts, "fork": fork,
           "history": history_, "put_back_ledger": put_back_ledger, "check": check_, "archive_write": archive_write,
           "archive_check": archive_check, "archive_info": archive_info, "archive_unpack": archive_unpack,
           "swap_in": swap_in, "resume_round": resume_round}
