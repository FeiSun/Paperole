"""Check items (CONTRACT.md amendment "Checks to the student"; design/checks-ui/PROPOSAL.md): the checks that go to the
student, each an item of the ledger's `check_items` map, id → {"id": "A2-03", "key", "code", "group", "created_round",
"rounds": {"<n>": {"state": new | still | fixed | null, "text", "detail", "note", "places", "student_note"?,
"advisor_note"?}}}. An item is found in an open round's checks.json (`sync`), carried while it is open, and closes
itself as fixed once no check matches it; a comment never closes by itself, an item does. Mark as OK stays the
ledger's checks_ok (api.check_ok): an item marked OK never goes out, and one carried closes as "no change needed"."""
import re

from . import checks, ledger

PER_ROUND = re.compile(r"\|r\d+(?:#\d+)?$")  # a key known by its place only (checks._keys): its round alone
SENT = ("new", "still")  # the states that go to the student


def _items(lg):
    return lg.get("check_items") or {}


def _stated(item, n):
    """(round, record) of the item's latest record with a state before round n, or None."""
    for k in sorted((int(j) for j in item["rounds"] if int(j) < n), reverse=True):
        if item["rounds"][str(k)].get("state"):
            return k, item["rounds"][str(k)]
    return None


def _went_out(item, n):
    """Whether its latest record with a state before round n is one that goes out (new or still)."""
    got = _stated(item, n)
    return got is not None and got[1]["state"] in SENT


def is_open(lg, item, n):
    """Open in round n: its latest record with a state before n is new or still, and its key is not marked OK."""
    return _went_out(item, n) and item["key"] not in (lg.get("checks_ok") or {})


def open_ids(lg, n):
    """The ids of the items open in round n, in id order."""
    return sorted((i for i, it in _items(lg).items() if is_open(lg, it, n)), key=ledger.id_key)


def closed_as(lg, cid):
    """(round, words) for the warning on a student's note naming item cid that is not open: marked OK ("no change
    needed", the round it was marked in) or fixed (its round), else None (no such item, or never sent)."""
    item = _items(lg).get(cid)
    if item is None:
        return None
    ok = lg.get("checks_ok") or {}
    if item["key"] in ok:
        return ok[item["key"]], "no change needed"
    got = _stated(item, 10 ** 9)
    return (got[0], "fixed") if got and got[1]["state"] == "fixed" else None


def _texts(item, n):
    """The latest record of rounds up to n with the check's words (a record without a state has none)."""
    for k in sorted((int(j) for j in item["rounds"] if int(j) <= n), reverse=True):
        if "text" in item["rounds"][str(k)]:
            return item["rounds"][str(k)]
    return {}


def _kept(rec):
    """What a round's record keeps when it is synced again: the student's and the advisor's notes."""
    return {k: rec[k] for k in ("student_note", "advisor_note") if k in (rec or {})}


def _match(live, matched, c, n):
    """The live item a current check is: the same key; else, for a check known by its place only, a carried item of
    the same code, also known by its place, whose first place's printed text is the check's, else whose text is."""
    rest = [it for it in live if it["id"] not in matched]
    it = next((it for it in rest if it["key"] == c["key"]), None)
    if it is not None or not PER_ROUND.search(c["key"]):
        return it
    rest = [it for it in rest if it["created_round"] < n and it["code"] == c["code"] and PER_ROUND.search(it["key"])]
    text = c["places"][0]["text"] if c["places"] else None

    def first(it):
        places = _texts(it, n - 1).get("places") or []
        return places[0]["text"] if places else None
    return next((it for it in rest if text is not None and first(it) == text), None) \
        or next((it for it in rest if _texts(it, n - 1).get("text") == c["text"]), None)


def _let_go(items, ok, c, n):
    """Whether a check known by its place only is a slip the advisor marked OK in an earlier round (its key, with that
    round's `|r<k>`, is in checks_ok): an item of the same code, also known by its place, closed as OK, whose first
    place's printed text is the check's, else whose text is. It is not sent again as new."""
    if not PER_ROUND.search(c["key"]):
        return False
    text = c["places"][0]["text"] if c["places"] else None
    for it in items.values():
        if it["key"] not in ok or it["code"] != c["code"] or not PER_ROUND.search(it["key"]) or it["created_round"] >= n:
            continue
        words = _texts(it, n - 1)
        places = words.get("places") or []
        if (text is not None and places and places[0]["text"] == text) or words.get("text") == c["text"]:
            return True
    return False


def sync(lg, n, found, groups, disabled=()):
    """Bring round n's records in step with its checks (`found`: checks.json's) of the groups asked: each check of
    those groups is an item open into round n or one created in it (_match), now `still` (or `new`, created in n), or
    a new item `new` with the next id (none for a check marked OK); an open item of a group asked that no check is
    `fixed`, one of another group keeps a record without a state; an item created in round n that no check is any
    more loses its record and goes. Writes nothing when the records are as they were."""
    items = _items(lg)
    ok = lg.get("checks_ok") or {}
    live = [it for it in sorted(items.values(), key=lambda it: ledger.id_key(it["id"]))
            if it["created_round"] == n or is_open(lg, it, n)]
    matched = {}
    for c in found:
        if c["group"] not in groups or c["code"] in disabled:
            continue
        it = _match(live, matched, c, n)
        if it is None:
            if c["key"] in ok or _let_go(items, ok, c, n):
                continue
            it = {"id": ledger.new_check_id(lg, n), "key": c["key"], "code": c["code"], "group": c["group"],
                  "created_round": n, "rounds": {}}
            items[it["id"]] = it
            live.append(it)
        matched[it["id"]] = c
    for it in live:
        rec, c = it["rounds"].get(str(n)), matched.get(it["id"])
        if c is not None:
            it["key"] = c["key"]  # a check known by its place: its key names this round
            it["rounds"][str(n)] = dict({"state": "new" if it["created_round"] == n else "still", "text": c["text"],
                                         "detail": c["detail"], "note": c["note"], "places": c["places"]},
                                        **_kept(rec))
        elif it["code"] in disabled:
            it["rounds"][str(n)] = dict({"state": None}, **_kept(rec))  # paused, never fixed by a switch
        elif it["created_round"] == n:
            it["rounds"].pop(str(n), None)
            if not it["rounds"]:
                del items[it["id"]]  # its id is not given again (last_check_seq)
        elif it["group"] in groups:
            last = _texts(it, n - 1)
            it["rounds"][str(n)] = dict({"state": "fixed", "text": last.get("text"), "detail": last.get("detail"),
                                         "note": last.get("note"), "places": []}, **_kept(rec))
        else:
            it["rounds"][str(n)] = dict({"state": None}, **_kept(rec))
    if items:
        lg["check_items"] = items


def carry(lg, n, found):
    """Ingest: each item open into round n gets a record without a state (not checked yet), with the student's note
    on it when there is one (`found`: notes.find's, by id)."""
    for cid in open_ids(lg, n):
        rec = {"state": None}
        if cid in found:
            rec["student_note"] = found[cid]
        lg["check_items"][cid]["rounds"][str(n)] = rec


def drop(lg, n, unsent=False):
    """Take round n's records off the items (finish without checks, or a replaced round), and the items left without
    one; unsent: only those of the items created in round n that do not go out (marked OK before they were sent)."""
    items, ok = _items(lg), lg.get("checks_ok") or {}
    for cid, it in list(items.items()):
        if unsent and (it["created_round"] != n or it["key"] not in ok):
            continue
        it["rounds"].pop(str(n), None)
        if not it["rounds"]:
            del items[cid]


def _order(v):
    """Groups in checks.GROUPS' order, then by the first place's page and top (items without places last in their
    group), then id."""
    first = v["places"][0] if v["places"] else None
    top = min((r[1] for r in first["rects"]), default=0.0) if first else 0.0
    return checks.GROUPS.index(v["group"]), first is None, first["page"] if first else 0, top, ledger.id_key(v["id"])


def view(lg, item, n):
    """An item as round n shows it: its fields and its round-n record's (the words of the latest record that has
    them), with `ok` (its key in checks_ok, marked in round n or before: an earlier round never shows a later Mark
    as OK), `carried` (created before n) and `history` (its earlier records)."""
    rec, words = item["rounds"].get(str(n)) or {}, _texts(item, n)
    earlier = [(k, item["rounds"][str(k)]) for k in sorted(int(j) for j in item["rounds"] if int(j) < n)]
    out = {k: item[k] for k in ("id", "key", "code", "group", "created_round")}
    out.update(state=rec.get("state"), text=words.get("text"), detail=words.get("detail"), note=words.get("note"),
               places=rec.get("places") or [], ok=(lg.get("checks_ok") or {}).get(item["key"], n + 1) <= n,
               carried=item["created_round"] < n,
               history=[dict({"round": k, "state": r.get("state")}, **_kept(r)) for k, r in earlier])
    out.update(_kept(rec))
    return out


def views(lg, n):
    """Round n's items ({"round", "items", "closed": {"fixed", "ok"}}): every item with a round-n record, in _order;
    closed: those fixed in it, and those carried into it and marked OK in it (no change needed)."""
    ok = lg.get("checks_ok") or {}
    rnd = next((r for r in lg["rounds"] if r["n"] == n), {})
    disabled = rnd.get("check_disabled") or []
    groups = rnd.get("check_groups", checks.GROUPS)
    have = [it for it in _items(lg).values() if str(n) in it["rounds"] and it["code"] not in disabled
            and it["group"] in groups]
    done = sorted((it["id"] for it in have if it["created_round"] < n and ok.get(it["key"]) == n and _went_out(it, n)),
                  key=ledger.id_key)
    fixed = sorted((it["id"] for it in have if it["rounds"][str(n)].get("state") == "fixed" and it["id"] not in done),
                   key=ledger.id_key)
    return {"round": n, "items": sorted((view(lg, it, n) for it in have), key=_order),
            "closed": {"fixed": fixed, "ok": done}}


def outgoing(lg, n):
    """What goes to the student with round n (render.py): {"items": the views of those new or still and not marked
    OK, "fixed", "ok"}, or None when there is nothing to say."""
    got = views(lg, n)
    out = {"items": [v for v in got["items"] if v["state"] in SENT and not v["ok"]], "fixed": got["closed"]["fixed"],
           "ok": got["closed"]["ok"]}
    return out if any(out.values()) else None
