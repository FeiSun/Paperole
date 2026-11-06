"""Every comment of a paper, round by round, for a spreadsheet or a JSON file (the app's Settings › Data & Storage;
CONTRACT.md amendment "Export"). Read only: the ledger and the overview's places; nothing is written."""
from pathlib import Path

from . import ledger, overview


def comments(path):
    """{"paper": {"title", "student"}, "tag_names", "comments"} of one paper folder. Each comment, in the ledger's
    order: id, created_round, created, kind, color, note, tags (ids), and its rounds, oldest first, one for each round
    it is in: round; section, that round's title of the section it is printed in (null when not placed or the round's
    paragraphs are not known yet); page, 0-based (null when not placed); place (placed, gone, unplaced, whole: an overall comment) and response
    and answer as the overview's path has them; state, verdict and verdict_note as the ledger has them; student_note,
    the text of the student's note in that round (null without one); text, the PDF words it marks there."""
    paper = Path(path)
    lg = ledger.load(paper)
    ov = overview.paper_overview(paper)
    titles = {r["n"]: {s[0]: s[1] for s in (r.get("spans") or [])} for r in ov["rounds"]}
    by_id = {c["id"]: c for c in lg["comments"]}
    out = []
    for c in ov["comments"]:
        lc = by_id[c["id"]]
        rounds = []
        for n, place, page, _pos, key, response, answer in c["path"]:
            rec = lc["rounds"].get(str(n)) or {}
            anchor = rec.get("anchor") or {}
            note = rec.get("student_note")
            rounds.append({"round": n, "section": titles.get(n, {}).get(key) if key is not None else None,
                           "page": page, "place": place, "state": rec.get("anchor_state"), "response": response,
                           "answer": answer, "verdict": rec.get("verdict"),
                           "verdict_note": rec.get("verdict_note") or "",
                           "student_note": note.get("text") if isinstance(note, dict) else None,
                           "text": anchor.get("text") or ""})
        out.append({"id": c["id"], "created_round": c["created_round"], "created": lc.get("created"),
                    "kind": c["kind"], "color": c["color"], "note": c["note"], "tags": c["tags"], "rounds": rounds})
    p = lg["paper"]
    return {"paper": {"title": p["title"], "student": p["student"]}, "tag_names": dict(lg.get("tag_names") or {}),
            "comments": out}
