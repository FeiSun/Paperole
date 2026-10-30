"""Writing-analysis tags (design/tags/TAGS.md; CONTRACT.md amendment "Tags, key page and Reopen").

The ledger keeps only tag ids, on the comment itself (not on a round): `comment.tags` = [{"id", "by", "at"}], set
through the `tag` RPC on a comment of any round, and `tag_names` at the top level, the names of the advisor's own tags
as the app sent them (a backup for a folder read on another Mac). The catalogue (names, groups, order, hidden) is the
app's (tags.json). A comment without `tags`, or with an empty list, is not tagged; ledgers written before read so.

The overview's numbers (paper_tags, student_tags) follow TAGS.md §6.1 with the critique's fixes (2026-10-20): counts
only, a comment with two tags in both rows and once in every total; trend words compare first drafts only, need three
usable ones of similar length, and say "fewer" or "more" only for a steady halving or doubling; facts are single facts,
never two counts across papers side by side."""
import datetime
import re
from collections import Counter

from . import EngineError, ledger

ID = re.compile(r"^[a-z][a-z0-9-]{0,31}$")  # built-in ids are words (grammar …), the advisor's "u-" + 8 hex digits
MAX = 12  # tags a comment can hold
NAME_MAX = 64  # characters of a name in tag_names
DEFAULT_ORDER = ("grammar", "wording", "clarity", "logic", "evidence", "structure", "figures", "math", "format",
                 "praise")  # TAGS.md §1.2: the order picks follow when the app sends none
PRAISE = "praise"  # Well done: never a problem, so in no fact and no focus
BY = ("advisor", "suggestion")
# A first draft is a trend point with at least FIRST_MIN new comments, at least 4 in 5 of them tagged; a trend needs
# TREND_POINTS of them, the longest at most LENGTHS times the pages of the shortest.
FIRST_MIN, TREND_POINTS, LENGTHS = 5, 3, 1.5
STEADY_MIN = 4  # "fewer" needs a first count, "more" a last one, of at least this
SLOW_MIN = 3  # a "slow" fact: at least this many comments that took two rounds or more, a third of the tag's at least
FOCUS_MIN, FOCUS_SCORE, PICKS = 3, 2, 2  # For the next draft: comments a tag needs, its least score, tags shown
EXAMPLE_MAX = 240  # characters of a student's sentence in an example


# --- the ledger ------------------------------------------------------------------------------------------------

def check(values, what="tags", limit=MAX):
    """The ids of a list as given (duplicates dropped, order kept), or EngineError; at most `limit` of them."""
    if not isinstance(values, list) or not all(isinstance(t, str) for t in values):
        raise EngineError("{} is a list of tag ids.".format(what))
    bad = next((t for t in values if not ID.fullmatch(t)), None)
    if bad is not None:
        raise EngineError("{!r} is not a tag id: lower-case letters, digits and -, starting with a letter, at most 32."
                          .format(bad))
    out = list(dict.fromkeys(values))
    if limit is not None and len(out) > limit:
        raise EngineError("A comment holds at most {} tags.".format(limit))
    return out


def ids(c):
    """The tag ids a ledger comment holds, in the order they were put on (none for a ledger written before tags)."""
    out = []
    for t in c.get("tags") or ():
        tid = t.get("id") if isinstance(t, dict) else None
        if isinstance(tid, str) and ID.fullmatch(tid) and tid not in out:
            out.append(tid)
    return out


def set_tags(lg, cid, values, accepted=None, names=None):
    """Set comment cid's whole list of tags (idempotent). An id it held keeps its "by" and "at"; a new one gets now and
    "suggestion" when it is in `accepted` (a suggestion the advisor took), else "advisor". An empty list takes the key
    away. `names` ({id: name}) go into the ledger's tag_names. Any comment of any round, closed or not: tags change no
    record of a round, nor anything the student receives."""
    c = ledger.get_comment(lg, cid)
    values = check(values)
    taken = set(check(accepted if accepted is not None else [], "accepted", limit=None))
    _names(lg, names)
    old = {t["id"]: t for t in c.get("tags") or () if isinstance(t, dict) and isinstance(t.get("id"), str)}
    now = ledger.now()
    held = [old.get(t) or {"id": t, "by": "suggestion" if t in taken else "advisor", "at": now} for t in values]
    if held:
        c["tags"] = held
    else:
        c.pop("tags", None)
    return c


def _names(lg, names):
    """Put `names` ({id: name}, or None) into the ledger's tag_names, white space collapsed; EngineError, changing
    nothing, when one is not a tag id or not 1 to NAME_MAX characters."""
    if names is None:
        return
    if not isinstance(names, dict):
        raise EngineError("names maps a tag id to its name.")
    check(list(names), "names", limit=None)
    for name in names.values():
        if not isinstance(name, str) or not name.split() or len(name.strip()) > NAME_MAX:
            raise EngineError("A tag's name is 1 to {} characters.".format(NAME_MAX))
    if names:
        lg.setdefault("tag_names", {}).update({tid: " ".join(name.split()) for tid, name in names.items()})


def replace(lg, old, new, names=None):
    """Merge Into… for one ledger: every comment holding tag `old` holds `new` in its place, keeping old's "by" and
    "at" (a comment holding both keeps its own `new`); `new` None takes `old` off. Each comment's list is read here, as
    the ledger has it now, never a list the app held (a stale list would overwrite tags put on since). `names` as in
    set_tags. The ids of the comments changed, in the ledger's order."""
    check([old], "from", limit=None)
    if new is not None:
        check([new], "into", limit=None)
    _names(lg, names)
    changed = []
    for c in lg["comments"]:
        held = [t for t in c.get("tags") or () if isinstance(t, dict) and isinstance(t.get("id"), str)]
        if old == new or not any(t["id"] == old for t in held):
            continue
        both = any(t["id"] == new for t in held)  # its own `new` stays, with its "by" and "at"
        out = []
        for t in held:
            if t["id"] == old and both:
                continue
            t = dict(t, id=new) if t["id"] == old else t
            if t["id"] is not None and not any(u["id"] == t["id"] for u in out):
                out.append(t)
        if out:
            c["tags"] = out
        else:
            c.pop("tags", None)
        changed.append(c["id"])
    return changed


# --- the overview's numbers ----------------------------------------------------------------------------------

def _thread(c):
    """How an overview comment (its `path`) went: closed (its last answer resolved or kept), after how many answered
    rounds (amendment "Overview", `threads`), followed up, revived."""
    answers = [s[6] for s in c["path"] if s[0] != c["created_round"]]
    closed = bool(answers) and answers[-1] in ("resolved", "kept")
    answered = sum(1 for a in answers if a in ("resolved", "kept", "follow_up"))
    return {"closed": closed, "after": ("3+" if answered >= 3 else str(max(answered, 1))) if closed else None,
            "followed_up": "follow_up" in answers, "revived": bool(c.get("revived"))}


def _row():
    return {"comments": 0, "open": 0, "closed_after": {"1": 0, "2": 0, "3+": 0}, "followed_up": 0, "revived": 0}


def _count(row, th):
    row["comments"] += 1
    row["open"] += not th["closed"]
    if th["closed"]:
        row["closed_after"][th["after"]] += 1
    row["followed_up"] += th["followed_up"]
    row["revived"] += th["revived"]


def paper_tags(ov):
    """A paper's `tags`: per round the new comments by tag; per tag (and for the comments without one) how many, how
    many are open, the sections they were written in (most first), how they closed. A comment with two tags counts in
    both rows; `comments`, `tagged`, `open` and each round's `new` and `untagged` count it once."""
    rounds = {r["n"]: {"n": r["n"], "new": 0, "untagged": 0, "by_tag": Counter()} for r in ov["rounds"]}
    order = {s["key"]: i for i, s in enumerate(ov.get("sections") or ())}
    rows, untagged, written = {}, _row(), {}
    total = tagged = open_ = 0
    for c in ov["comments"]:
        ts, th = c.get("tags") or [], _thread(c)
        total, tagged, open_ = total + 1, tagged + bool(ts), open_ + (not th["closed"])
        r = rounds.get(c["created_round"])
        if r:
            r["new"] += 1
            r["untagged"] += not ts
            r["by_tag"].update(ts)
        key = next((s[4] for s in c["path"] if s[0] == c["created_round"]), None)
        for t in ts or [None]:
            row = rows.setdefault(t, _row()) if t else untagged
            _count(row, th)
            if key is not None:
                written.setdefault(t, Counter())[key] += 1

    def where(t):
        return [[k, v] for k, v in sorted(written.get(t, Counter()).items(), key=lambda kv: (-kv[1], order.get(kv[0],
                                                                                                          len(order))))]
    return {"comments": total, "tagged": tagged, "open": open_,
            "rounds": [dict(r, by_tag=dict(r["by_tag"])) for r in rounds.values()],
            "by_tag": {t: dict(row, written_in=where(t)) for t, row in rows.items()},
            "untagged": dict(untagged, written_in=where(None))}


def _when(stamp):
    try:
        return datetime.datetime.fromisoformat(stamp).timestamp()
    except (TypeError, ValueError):
        return 0.0


def _trend(counts):
    """The trend word of counts over first drafts (TAGS.md §6.1 T6 with the critique's fix): "same" when they all lie
    within one of each other; "fewer" when each draft has fewer than the one before, the first at least STEADY_MIN and
    the last at most half of it; "more" the other way round; else "mixed" (no clear trend: 3 → 2 → 1 is noise)."""
    steps = [b - a for a, b in zip(counts, counts[1:])]
    first, last = counts[0], counts[-1]
    if max(counts) - min(counts) <= 1:
        return "same"
    if all(s < 0 for s in steps) and first >= STEADY_MIN and 2 * last <= first:
        return "fewer"
    if all(s > 0 for s in steps) and last >= STEADY_MIN and last >= 2 * first:
        return "more"
    return "mixed"


def _order(order, present):
    """The tags picks consider, in order: the app's (`tag_order`: its visible tags; the others are never picked), else
    the built-in order and then the other ids present."""
    if order is not None:
        return [t for t in order if isinstance(t, str)]
    return list(DEFAULT_ORDER) + sorted(t for t in present if t not in DEFAULT_ORDER)


def student_tags(group, order=None):
    """A student's `tags` (the Student page's writing profile) from [(path, PaperOverview, latest)] of the student's
    papers, where latest is {comment id: {"round", "page", "text", "created"}} (its latest printed words). `order`: the
    app's tag order (_order)."""
    rows, comments = [], []  # rows: the built rounds of every paper, in time order
    for path, ov, latest in group:
        built = [r for r in ov["rounds"] if r["build"]["status"] != "failed"]
        last_n = built[-1]["n"] if built else None
        for r in built:
            rows.append({"path": path, "n": r["n"], "date": (r.get("created") or "")[:10] or None,
                         "pages": r["build"].get("pages"), "first": r["n"] == 1, "closed": r.get("closed", False),
                         "latest": r["n"] == last_n, "added": (r.get("words") or {}).get("added"),
                         "new": 0, "untagged": 0, "by_tag": Counter(), "_at": _when(r.get("created"))})
        for c in ov.get("comments") or ():
            comments.append((path, c, latest.get(c["id"]) or {}))
    rows.sort(key=lambda r: (r["_at"], r["path"], r["n"]))
    at = {(r["path"], r["n"]): r for r in rows}
    by_tag, untagged = {}, dict(_row(), papers={})
    for path, c, _ in comments:
        ts, th = c.get("tags") or [], _thread(c)
        r = at.get((path, c["created_round"]))
        if r:
            r["new"] += 1
            r["untagged"] += not ts
            r["by_tag"].update(ts)
        for t in ts or [None]:
            row = by_tag.setdefault(t, dict(_row(), papers={})) if t else untagged
            _count(row, th)
            row["papers"][path] = row["papers"].get(path, 0) + 1
    present = list(by_tag)
    picks = [t for t in _order(order, present) if t != PRAISE]

    # first drafts: each paper's Round 1, in time order
    firsts = [r for r in rows if r["first"]]
    usable, skipped = [], []
    for r in firsts:
        if r["new"] < FIRST_MIN:
            skipped.append({"path": r["path"], "why": "small"})
        elif 5 * (r["new"] - r["untagged"]) < 4 * r["new"]:
            skipped.append({"path": r["path"], "why": "untagged"})
        else:
            usable.append(r)
    pages = [r["pages"] for r in usable if r["pages"]]
    trend = {}
    for t in present:
        counts = [r["by_tag"].get(t, 0) for r in usable]
        word, why = None, None
        if len(firsts) < TREND_POINTS:
            why = "two_points"
        elif len(usable) < TREND_POINTS:
            why = skipped[0]["why"]
        elif len(pages) < len(usable) or max(pages) > LENGTHS * min(pages):
            why = "lengths_differ"
        else:
            word = _trend(counts)
        trend[t] = {"word": word, "why": why, "counts": counts}

    facts = []
    for t in picks:
        fact = _fact(t, rows, by_tag.get(t))
        if fact:
            facts.append(fact)
        if len(facts) == PICKS:
            break

    newest = Counter()  # each paper's latest round: what is still happening
    for r in rows:
        if r["latest"]:
            newest.update(r["by_tag"])
    scored = []
    for i, t in enumerate(picks):
        row = by_tag.get(t)
        if not row or row["comments"] < FOCUS_MIN:
            continue
        score = row["open"] + newest[t] + row["followed_up"]
        if score >= FOCUS_SCORE:
            scored.append((-score, i, t, score))
    focus = []
    for _, _, t, score in sorted(scored)[:PICKS]:
        row = by_tag[t]
        focus.append({"tag": t, "comments": row["comments"], "open": row["open"], "followed_up": row["followed_up"],
                      "score": score, "example": _example([e for e in comments if t in (e[1].get("tags") or ())],
                                                          open_first=True)})
    praised = [e for e in comments if PRAISE in (e[1].get("tags") or ())]
    praise = {"comments": len(praised), "latest": _example(praised, open_first=False, text=False)}
    return {"comments": len(comments), "tagged": sum(1 for _, c, _ in comments if c.get("tags")),
            "rounds": [{k: (dict(v) if k == "by_tag" else v) for k, v in r.items() if k not in ("_at", "latest")}
                       for r in rows],
            "by_tag": by_tag, "untagged": untagged,
            "first_drafts": {"points": [r["path"] for r in usable], "skipped": skipped, "trend": trend},
            "facts": facts, "focus": focus, "praise": praise}


def _fact(t, rows, row):
    """The first fact about tag t that holds, or None: "none_since" (no new comment with it in the rounds since the last
    one that had it, two closed rounds at least), "slow" (n of its `of` comments took two answered rounds or more),
    "new_words" (a paper's latest closed round from Round 3: its new comments with t against the words the student put
    in, never as a rate). A fact names one round or one tag's own numbers: never two counts side by side."""
    if not row:
        return None
    had = [i for i, r in enumerate(rows) if r["by_tag"].get(t)]
    if had and row["comments"] >= 2:
        after = rows[had[-1] + 1:]
        if sum(1 for r in after if r["closed"]) >= 2:
            return {"tag": t, "kind": "none_since", "path": after[0]["path"], "round": after[0]["n"]}
    slow = row["closed_after"]["2"] + row["closed_after"]["3+"]
    if slow >= SLOW_MIN and 3 * slow >= row["comments"]:
        return {"tag": t, "kind": "slow", "n": slow, "of": row["comments"]}
    for r in reversed(rows):
        if r["closed"] and r["n"] >= 3 and r["added"]:
            before = sum(q["by_tag"].get(t, 0) for q in rows if q["path"] == r["path"] and q["n"] < r["n"])
            if before >= FOCUS_MIN:
                return {"tag": t, "kind": "new_words", "path": r["path"], "round": r["n"], "n": r["by_tag"].get(t, 0),
                        "words": r["added"]}
    return None


def _example(entries, open_first, text=True):
    """The latest comment of [(path, overview comment, latest)] (an open one first when open_first), as {"path", "id",
    "round", "page", "text", "note"}: the student's words where it is printed last, and the advisor's note."""
    if not entries:
        return None

    def key(e):
        return (not _thread(e[1])["closed"]) if open_first else True, _when(e[2].get("created")), \
            ledger.id_key(e[1]["id"])
    path, c, latest = max(entries, key=key)
    out = {"path": path, "id": c["id"], "round": latest.get("round", c["created_round"]), "page": latest.get("page"),
           "note": c.get("note", "")}
    if text:
        words = " ".join((latest.get("text") or "").split())
        out["text"] = words if len(words) <= EXAMPLE_MAX else words[:EXAMPLE_MAX - 1] + "…"
    return out
