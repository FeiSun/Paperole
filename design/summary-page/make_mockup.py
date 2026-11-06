"""Mockups of final.pdf's new summary page (design only; the engine is not changed).

Draws the proposed page with the engine's own drawing helpers (paperole.render), from a synthetic review: a copy of
samples/promo-demo/review with round 2 judged and finished. Writes mockup-a.pdf (the to-do table) and mockup-b.pdf
(the same with the page strip), and png/ renders of both.

    engine/.venv/bin/python design/summary-page/make_mockup.py <copy of the review folder> <out dir>
"""
import json
import pathlib
import sys

import pymupdf

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
from paperole import ledger  # noqa: E402
from paperole.comments import PALETTE  # noqa: E402
from paperole.render import (INK, MUTED, FAINT, RULE, HIST, HIST_TEXT, HIST_FILL, STATUS, LABELS,  # noqa: E402
                             CHECK_CHIP, _Flow, _put, _fit, _wrap, _width, _rgb, _glyph, _cross, _status, _texts,
                             _sign, _target, _change_text, _build_line, _glyph_w)

VERMILION = "#C04734"  # the app's mark colour: "your move"
HAIR = "#ECECEC"
CLOSED_BAR, NEW_BAR = "#D4D4D4", INK


TAG_NAMES = {"grammar": "Grammar", "wording": "Wording", "clarity": "Clarity", "logic": "Logic & claims",
             "evidence": "Evidence & citations", "structure": "Structure", "figures": "Figures & tables",
             "math": "Math & notation", "format": "Format & LaTeX", "praise": "Well done"}  # Tags.swift's catalogue
SMALL = ("grammar", "wording", "format")  # small fixes: one row of chips, not a row each
ROWS = 20  # the most one-line rows the to-do table takes before it is grouped by section


def tag_name(t):
    return TAG_NAMES.get(t, t.capitalize())


def small(c):
    tags = {t["id"] for t in c.get("tags") or []}
    return bool(tags) and tags <= set(SMALL)


NOTES = {  # synthetic notes for the many-comments mockup, a few per tag
    "grammar": ["Subject and verb disagree: “the results shows”.", "Missing article: “a small model”.",
                "Keep the present tense here.", "“Its”, not “it's”."],
    "wording": ["“Very significant” says nothing. Give the number.", "Use “we”, not “the authors”.",
                "“Utilize” → “use”."],
    "format": ["Parenthetical citation: \\citep, not \\citet.", "Non-breaking space before \\ref: Table~\\ref{…}.",
               "Use the same number format as Table 1."],
    "clarity": ["What does “it” refer to here?", "Too long: split this sentence in two, the claim first.",
                "Define the term before you use it.", "I had to read this three times. Say it plainly."],
    "logic": ["This does not follow from Table 2.", "Overclaim: say what you show, not more.",
              "Why would easy examples first help? Give the reason before the result."],
    "evidence": ["Which paper? Cite it.", "Report the spread over seeds, not only the mean.",
                 "Add the baseline you cite in §2."],
    "structure": ["Move this to Related Work.", "This paragraph has two topics. Split it."],
    "figures": ["The axis labels are too small to read.", "Use Figure 1's colours for the same methods."],
    "math": ["Define this symbol.", "i is used twice with two meanings.", "Number this equation: you refer to it."],
}


def synthesize(lg, prose, n, counts, seed=7):
    """Add made-up new comments to round n of lg (in memory): counts {tag: k}, placed on the paper's paragraphs
    with more of them in the method and experiments."""
    import random
    rnd = random.Random(seed)
    spots = [(pg, r) for b in prose["blocks"] if b["kind"] == "paragraph" for pg, r in b.get("parts") or []]
    weights = [3 if 2 <= pg <= 4 else 1 for pg, _ in spots]
    colours = ["yellow", "pink", "blue", "purple", "teal", "orange"]
    k = 1 + max(int(c["id"].split("-")[1]) for c in lg["comments"] if c["created_round"] == n)
    for tag, m in counts.items():
        for _ in range(m):
            pg, r = rnd.choices(spots, weights)[0]
            y = r[1] + rnd.random() * max(r[3] - r[1] - 10, 0)
            lg["comments"].append({
                "id": "R{}-{:02d}".format(n, k), "created_round": n, "kind": "highlight",
                "color": colours[0] if tag in SMALL else rnd.choice(colours[1:4]),
                "note": rnd.choice(NOTES[tag]), "tags": [{"id": tag}],
                "rounds": {str(n): {"anchor": {"page": pg, "rects": [[r[0] + 20, y, r[0] + 160, y + 9]], "text": ""},
                                    "anchor_state": "ok", "verdict": None, "verdict_note": None}}})
            k += 1


def add_overall(lg, n=2):
    """Two made-up comments on the whole paper (engine kind "overall": no place in any round): one from Round 1 that
    the advisor follows up in round n, and a new one."""
    def rec(verdict=None, note=""):
        return {"anchor": None, "anchor_state": "overall", "confidence": 1.0, "method": "overall", "verdict": verdict,
                "verdict_note": note}
    lg["comments"].append({
        "id": "R1-15", "created_round": 1, "kind": "overall", "color": "orange", "tags": [{"id": "logic"}],
        "note": "The story is there, but the introduction promises more than the experiments show. Make every claim "
                "match Table 1, or add the evaluations that would support it.",
        "rounds": {"1": rec(), str(n): rec("reopened", "Much better. Only the abstract's “more robust” is left: "
                                                       "cut it, or test on a shifted set.")}})
    k = 1 + max(int(c["id"].split("-")[1]) for c in lg["comments"] if c["created_round"] == n)
    lg["comments"].append({
        "id": "R{}-{:02d}".format(n, k), "created_round": n, "kind": "overall", "color": "yellow",
        "tags": [{"id": "evidence"}],
        "note": "A clear step forward: the method section now reads well. What is left is mostly the evaluation. "
                "Report the spread over seeds, add sequence-level KD as a baseline, and say plainly what the "
                "curriculum costs in training time. With those, this is ready for a first submission.",
        "rounds": {str(n): rec()}})


def overall(c):
    return c.get("kind") == "overall"


def top_section(prose, page, y):
    """(number, title) of the top-level section over (page, y)."""
    blocks = prose["blocks"]
    num = section_of(prose, page, y)[1:].split(".")[0]
    if not num:
        return "", "Abstract"
    head = next((b for b in blocks if b["kind"] == "heading" and b.get("number") == num), None)
    return num, " ".join(head["text"].split()) if head else ""


def section_of(prose, page, y):
    """The number of the heading over the block at (page, y), from prose.json: the block whose part holds y, else
    the last block above it on that page, else the last block of an earlier page."""
    blocks = prose["blocks"]
    text = [b for b in blocks if b["kind"] in ("paragraph", "item", "heading")]  # floats print away from their source
    best = next((((pg, r[1]), b) for b in text for pg, r in b.get("parts") or []
                 if pg == page and r[1] - 2 <= y <= r[3] + 2), None)
    for b in text if best is None else ():
        for pg, r in b.get("parts") or []:
            if (pg, r[1]) <= (page, y + 2):
                if best is None or (pg, r[1]) >= best[0]:
                    best = ((pg, r[1]), b)
    if not best:
        return ""
    b = best[1]
    k = b.get("section")
    k = None if k is None or k < 0 else k  # -1: before the first heading (the abstract)
    while k is not None and blocks[k].get("number") is None:  # a run-in paragraph heading: its section's number
        k = blocks[k].get("section")
    return "§" + blocks[k]["number"] if k is not None else ""


def cut(text, width, size, style="r"):
    """text cut at a word boundary with … to fit width."""
    if _width(text, size, style) <= width:
        return text
    words = text.split(" ")
    while len(words) > 1 and _width(" ".join(words) + "…", size, style) > width:
        words.pop()
    return " ".join(words).rstrip(" ,;:·") + "…"


def one_line(c, n):
    """The comment's current ask, the first line of what the margin box says in full."""
    main, _ = _texts(c, n)
    return " ".join((main or "").split())


def draw(paper, n, out, strip, many=None):
    lg = json.loads((paper / "ledger.json").read_text())
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    prose = json.loads((paper / "r{}".format(n) / "prose.json").read_text())
    add_overall(lg, n)
    if many:
        synthesize(lg, prose, n, many)
    changes = json.loads((paper / "r{}".format(n) / "analysis.json").read_text())["changes"]
    build = pymupdf.open(str(paper / rnd["build"]["pdf"]))
    size = (build[0].rect.width, build[0].rect.height)
    cs = [c for c in lg["comments"] if str(n) in c["rounds"]]

    doc = pymupdf.open()
    f = _Flow(doc, size)
    L, R, p = f.L, f.R, f.page

    # --- masthead --------------------------------------------------------------------------------------------
    _put(f.page, L, 34, "Paperole · Review of Round {} · {}".format(n, "2026-11-05"), 8, "r", MUTED)
    y = 60
    for line in _wrap(lg["paper"]["title"], R - L, 15, "b"):
        _put(f.page, L, y, line, 15, "b")
        y += 18
    _put(f.page, L, y + 1, "{} · draft received {}".format(lg["paper"]["student"], rnd["created"][:10]), 9, "r", MUTED)
    y += 30

    todo = [c for c in cs if _status(c, n) in ("new", None, "reopened", "revived")]

    # --- the round in one line: to do, and every comment's fate as a bar -----------------------------------
    closed = [c for c in cs if c not in todo]
    carried_open = [c for c in todo if _status(c, n) != "new"]
    new = [c for c in todo if _status(c, n) == "new"]
    x = _put(f.page, L, y + 14, str(len(todo)), 30, "b", VERMILION)
    _put(f.page, x + 6, y + 3, "to do", 9.5, "b")
    _put(f.page, x + 6, y + 14, "of {} comments".format(len(cs)), 9.5, "r", MUTED)
    bx0, bx1, by = L + 120, R, y - 4
    unit = (bx1 - bx0 - 4) / max(len(cs), 1)
    segs = [(len(closed), CLOSED_BAR, "{} closed".format(len(closed))),
            (len(carried_open), INK, "{} again".format(len(carried_open))),
            (len(new), NEW_BAR, "{} new".format(len(new)))]
    xs, free = bx0, bx0  # free: where the next label may start, clear of the one before
    for k, (count, colour, label) in enumerate(segs):
        if not count:
            continue
        w = count * unit
        if k == 2:  # new comments after a gap: they were not in the last round
            xs += 4
            f.page.draw_rect(pymupdf.Rect(xs, by, xs + w, by + 7), color=_rgb(INK), fill=None, width=0.8)
        else:
            f.page.draw_rect(pymupdf.Rect(xs, by, xs + w, by + 7), color=None, fill=_rgb(colour), width=0)
        free = _put(f.page, max(xs, free), by + 19, label, 8.5, "b" if k else "r", INK if k else MUTED) + 12
        xs += w
    y += 30

    # tags of what is to do: the round's main issues (the advisor, 2026-11-05)
    counts = {}
    for c in todo:
        for t in c.get("tags") or []:
            if t["id"] != "praise":
                counts[t["id"]] = counts.get(t["id"], 0) + 1
    if len(todo) >= 6 and counts and max(counts.values()) >= 2:  # a line of 1s says nothing
        x = _put(f.page, L, y + 10, "Main issues", 8.5, "b")
        for k, (t, m) in enumerate(sorted(counts.items(), key=lambda e: (-e[1], e[0]))[:5]):
            if k:
                x = _put(f.page, x + 6, y + 10, "·", 8.5, "r", FAINT)
            x = _put(f.page, x + (12 if k == 0 else 6), y + 10, tag_name(t), 8.5)
            x = _put(f.page, x + 3, y + 10, str(m), 8.5, "b", MUTED)
        y += 12
    if not strip:
        y += 8

    # --- the advisor on the whole paper, first and whole: no margin holds these ------------------------------------
    whole = sorted((c for c in todo if overall(c)), key=lambda c: (_status(c, n) == "new", ledger.id_key(c["id"])))
    if whole:
        f.y = y + 4
        f.section("Overall ({})".format(len(whole)))
        f.y -= 2
        for c in whole:
            status = _status(c, n)
            main, muted = _texts(c, n)
            lines = [(t, 10, INK, 13.5) for t in _wrap(main, R - L - 70, 10)]
            lines += [(t, 8.5, MUTED, 11) for t in _wrap(muted, R - L - 70, 8.5)]
            f.need(sum(e[3] for e in lines) + 10)
            yb = f.y + 11
            f.page.draw_rect(pymupdf.Rect(L, yb - 9, L + 2.4, yb - 9 + sum(e[3] for e in lines) - 1), color=None,
                             fill=_rgb(PALETTE[c["color"]][0]), width=0)
            f.chip(L + 8, yb, c["id"], STATUS[status], glyph=_sign(status))
            _put(f.page, L + 8, yb + 13, "new" if status == "new" else LABELS[status], 8, "r", MUTED)
            for k, (t, sz, ink, step) in enumerate(lines):
                if k and lines[k - 1][1] != sz:
                    yb += 3
                _put(f.page, L + 70, yb, t, sz, "r", ink)
                yb += step
            f.y = max(yb, f.y + 32) - 11 + 12
        y = f.y - (8 if strip else -6)

    # --- page strip: where the work is -------------------------------------------------------------------------
    if strip:
        y += 16
        pages = build.page_count
        tw = min(58.0, (R - L - 6 * (pages - 1)) / pages)
        gap = (R - L - tw * pages) / (pages - 1) if pages > 1 else 0
        s = tw / size[0]
        th = size[1] * s
        per_page = {}
        for c in cs:
            a = c["rounds"][str(n)]["anchor"]
            if a and a.get("page") is not None and a["rects"]:
                per_page.setdefault(a["page"], []).append((c, a["rects"][0]))
        for pg in range(pages):
            x0 = L + pg * (tw + gap)
            r = pymupdf.Rect(x0, y, x0 + tw, y + th)
            pix = build[pg].get_pixmap(matrix=pymupdf.Matrix(s * 3, s * 3), alpha=False)
            f.page.insert_image(r, pixmap=pix)
            f.page.draw_rect(r, color=_rgb("#FFFFFF"), fill=_rgb("#FFFFFF"), fill_opacity=0.55, width=0)  # faded paper
            open_here = 0
            for c, rect in sorted(per_page.get(pg, []), key=lambda e: e[0] in todo):
                cx = x0 + (rect[0] + rect[2]) / 2 * s
                cy = y + (rect[1] + rect[3]) / 2 * s
                if c in todo:
                    open_here += 1
                    f.page.draw_circle((cx, cy), 2.6, color=_rgb("#FFFFFF"), fill=_rgb(VERMILION), width=0.6)
                else:
                    f.page.draw_circle((cx, cy), 1.6, color=None, fill=_rgb("#9A9A9A"), width=0)
            f.page.draw_rect(r, color=_rgb(INK if open_here else FAINT), width=0.8 if open_here else 0.5)
            f.links.append((0, r, (pg, 0)))
            label = "p.{}".format(pg + 1) + (" · {}".format(open_here) if open_here else "")
            _put(f.page, x0 + (tw - _width(label, 7.5, "b" if open_here else "r")) / 2, y + th + 10, label, 7.5,
                 "b" if open_here else "r", INK if open_here else MUTED)
        y += th + 24

    # --- to do: one row per comment, in the paper's order ---------------------------------------------------------
    f.y = y
    located = [c for c in todo if not overall(c)]
    f.section("On the pages ({})".format(len(located)) if whole else "To do for Round {}".format(n + 1))
    f.y -= 6

    def place(c):
        t = _target(c, n)
        return t if t else (10 ** 6, 0)

    def where(c):
        a = c["rounds"][str(n)]["anchor"]
        return a["page"], a["rects"][0][1]

    def row(c, x0, columns=True):
        """One comment on one line: its colour, chip, status, page, section, the first line of its note, tags."""
        status = _status(c, n)
        f.need(18)
        yb = f.y + 12
        f.page.draw_rect(pymupdf.Rect(x0, yb - 8.5, x0 + 2.4, yb + 2.5), color=None, fill=_rgb(PALETTE[c["color"]][0]),
                    width=0)
        f.chip(x0 + 8, yb, c["id"], STATUS[status], target=_target(c, n), glyph=_sign(status))
        x = x0 + 64
        _put(f.page, x, yb, "new" if status == "new" else LABELS[status], 8, "r", MUTED)
        x += 58
        _put(f.page, x, yb, "p.{}".format(where(c)[0] + 1), 8.5, "b")
        x += 24
        if columns:
            _put(f.page, x, yb, section_of(prose, *where(c)), 8, "r", MUTED)
            x += 36
        tags = ", ".join(tag_name(t["id"]) for t in c.get("tags") or []) if columns else ""
        tw_ = _width(tags, 8)
        _put(f.page, R - tw_, yb, tags, 8, "r", MUTED)
        _put(f.page, x, yb, cut(one_line(c, n), R - x - (tw_ + 12 if tags else 0), 9), 9)
        f.y += 18
        f.page.draw_line((x0 + 8, f.y + 1), (R, f.y + 1), color=_rgb(HAIR), width=0.5)

    def chips(group, x0, signs=True):
        """The group's chips from x0 to R, wrapped, each after a bar of its mark's colour; returns the baseline of
        their last line. signs: False when every chip is new (the + says nothing)."""
        f.need(15 * (1 + sum(_width(c["id"], 8, "b") + 22 for c in group) // (R - x0)) + 8)
        yb, x = f.y + 12, x0
        for c in sorted(group, key=place):
            status = _status(c, n)
            w = _width(c["id"], 8, "b") + (22 if signs else 16)
            if x + w > R:
                yb, x = yb + 15, x0
            f.page.draw_rect(pymupdf.Rect(x, yb - 8.5, x + 2, yb + 2.5), color=None,
                             fill=_rgb(PALETTE[c["color"]][0]), width=0)
            x = f.chip(x + 4, yb, c["id"], STATUS[status], target=_target(c, n),
                       glyph=_sign(status) if signs else None) + 6
        return yb

    def label(lines, yb):
        """A group's name (bold) and its facts (muted) in the left column."""
        for k, (text, style) in enumerate(lines):
            for t in _wrap(text, 140, 9 if k == 0 else 8, style):
                _put(f.page, L, yb, t, 9 if k == 0 else 8, style, INK if k == 0 else MUTED)
                yb += 11
        return yb - 11

    def tag_line(group):
        counts = {}
        for c in group:
            for t in c.get("tags") or []:
                counts[t["id"]] = counts.get(t["id"], 0) + 1
        return " · ".join("{} {}".format(tag_name(t), m) for t, m in
                          sorted(counts.items(), key=lambda e: (-e[1], e[0]))[:2])

    def pages_of(group):
        ps = sorted({where(c)[0] + 1 for c in group})
        return "p.{}".format(ps[0]) if len(ps) == 1 else "pp.{}–{}".format(ps[0], ps[-1])

    placed = [c for c in todo if not overall(c)]
    smalls = [c for c in placed if small(c)]
    if len(smalls) < 3:
        smalls = []
    singles = [c for c in placed if c not in smalls]
    if len(singles) + bool(smalls) <= ROWS:  # a row each, in the paper's order
        for c in sorted(singles, key=place):
            row(c, L)
    else:  # grouped: what comes back first, a row each; then a row per section, its chips
        again = [c for c in singles if _status(c, n) != "new"]
        XC = L + 150
        if again:
            _put(f.page, L, f.y + 12, "Again", 9, "b")
            f.y += 14
            for c in sorted(again, key=place):
                row(c, L)
            f.y += 8
        secs = {}
        for c in singles:
            if c not in again:
                secs.setdefault(top_section(prose, *where(c)), []).append(c)
        for (num, title), group in sorted(secs.items(), key=lambda e: (e[0][0] != "", not e[0][0].isdigit(),
                                                                       int(e[0][0]) if e[0][0].isdigit() else e[0][0])):
            f.need(40)
            top = f.y
            end = chips(group, XC, signs=False)
            low = label([(("§{} ".format(num) if num else "") + title, "b"), ("{} on {}".format(len(group), pages_of(group)), "r")]
                        + ([(tag_line(group), "r")] if len(group) >= 5 else []), top + 12)
            f.y = max(end, low) + 8
            f.page.draw_line((L, f.y + 1), (R, f.y + 1), color=_rgb(HAIR), width=0.5)
    if smalls:
        top = f.y
        if len(singles) + 1 > ROWS:
            end = chips(smalls, L + 150, signs=False)
            low = label([("Small fixes", "b"), ("{} on {}".format(len(smalls), pages_of(smalls)), "r"),
                         ("Grammar, wording, format", "r")], top + 12)
        else:
            end = chips(smalls, L + 130)
            low = label([("Small fixes · {}".format(len(smalls)), "b")], top + 12)
        f.y = max(end, low) + 8
    f.y += 14
    f.need(26)
    _put(f.page, L, f.y, "No need to list what you fixed. To explain a change, or why you kept something, add a line",
         8.5, "r", MUTED)
    f.y += 11
    tw = pymupdf.TextWriter(f.page.rect)
    tw.append((L, f.y), "% R1-05 your note", font=pymupdf.Font("cour"), fontsize=8.5)
    x = tw.last_point.x
    tw.write_text(f.page, color=_rgb(INK))
    _put(f.page, x + 3, f.y, "next to it in the .tex. Next round, send the full LaTeX source (zip) again.", 8.5, "r",
         MUTED)
    f.y += 11

    # --- closed: chips only (the margin holds each note) ------------------------------------------------------
    praise = [c for c in closed if any(t["id"] == "praise" for t in c.get("tags") or [])]
    groups = [("Resolved", [c for c in closed if _status(c, n) == "verified"], "verified"),
              ("No change needed", [c for c in closed if _status(c, n) == "wontfix"], "wontfix")]
    f.section("Closed ({})".format(len(closed)))
    f.y -= 4
    for name, group, sign in groups:
        if not group:
            continue
        yb = f.y + 10
        _put(f.page, L, yb, name, 8.5, "b", STATUS["verified"][2])
        _put(f.page, L + _width(name, 8.5, "b") + 4, yb, str(len(group)), 8.5, "r", MUTED)
        x = L + 108
        for c in group:
            if x + 52 > R:
                f.y += 16
                yb, x = f.y + 10, L + 108
            x = f.chip(x, yb, c["id"], STATUS["verified"], target=_target(c, n), glyph=sign) + 5
        f.y += 17
    for c in praise:  # the advisor's praise, in their words: the page links to it
        yb = f.y + 10
        _put(f.page, L, yb, "Well done", 8.5, "b", STATUS["verified"][2])
        x = _put(f.page, L + 108, yb, "p.{}".format(where(c)[0] + 1), 8.5, "b")
        f.links.append((f.count - 1, pymupdf.Rect(L + 108, yb - 9, x, yb + 3), _target(c, n)))
        _put(f.page, x + 8, yb, cut("“{}”".format(one_line(c, n)), R - x - 8, 8.5, "i"), 8.5, "i", MUTED)
        f.y += 17

    # --- the student's other changes: what the advisor read ------------------------------------------------------
    unrequested = [ch for ch in changes if not ch["attached_to"]]
    if unrequested:
        f.section("Your other changes ({})".format(len(unrequested)))
        f.y -= 4
        checked = set(rnd.get("checked", []))
        for ch in unrequested:
            yb = f.y + 10
            _put(f.page, L, yb, "p.{}".format(ch["page"] + 1) if ch["page"] is not None else "—", 8.5, "b")
            _put(f.page, L + 40, yb, cut(_change_text(ch, 90), R - L - 40 - 50, 8.5), 8.5)
            if ch["id"] in checked or True:  # the mockup: all read
                x = _glyph(f.page, "verified", R - _width("read", 8, "b") - _glyph_w("verified", 8), yb, 8,
                           STATUS["verified"][2])
                _put(f.page, x, yb, "read", 8, "b", STATUS["verified"][2])
            f.y += 14

    # --- foot: build and the marks in the paper --------------------------------------------------------------
    f.y += 14
    f.page.draw_line((L, f.y - 10), (R, f.y - 10), color=_rgb(RULE), width=0.6)
    x = _put(f.page, L, f.y, "Build", 8, "b")
    for line in _wrap(_build_line(lg, n, changes), R - L - 40, 8):
        _put(f.page, L + 40, f.y, line, 8, "r", MUTED)
        f.y += 11
    yb = f.y + 3
    x = _put(f.page, L, yb, "Marks", 8, "b")
    x = L + 40
    f.page.draw_rect(pymupdf.Rect(x, yb - 8, x + 1.7, yb + 1.5), color=None, fill=_rgb(HIST), width=0)
    f.page.draw_rect(pymupdf.Rect(x + 5, yb - 7, x + 9 + _width("text", 8), yb + 1.8), color=None, fill=_rgb(HIST_FILL),
                width=0)
    x = _put(f.page, x + 7, yb, "text", 8) + 5
    x = _put(f.page, x, yb, "your change since Round {}".format(n - 1), 8, "r", MUTED) + 12
    _cross(f.page, x + 2, yb - 2.5, HIST)
    x1 = _put(f.page, x + 7, yb, "old", 8, "r", HIST_TEXT)
    f.page.draw_line((x + 7, yb - 2.4), (x1, yb - 2.4), color=_rgb(HIST_TEXT), width=0.6)
    x = _put(f.page, x1 + 4, yb, "deleted", 8, "r", MUTED) + 12
    f.page.draw_rect(pymupdf.Rect(x, yb - 8.5, x + 2.4, yb + 2.5), color=None, fill=_rgb(PALETTE["yellow"][0]), width=0)
    _put(f.page, x + 7, yb, "a comment's colour, as on its mark", 8, "r", MUTED)

    for k in range(1, f.count):
        _put(doc[k], L, 30, "Paperole · Review of Round {} · {}".format(n, lg["paper"]["title"]), 8, "r", MUTED)
    doc.save(str(out))
    return out


def main():
    paper, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    (out / "png").mkdir(parents=True, exist_ok=True)
    many = {"grammar": 12, "wording": 6, "format": 5, "clarity": 12, "math": 8, "evidence": 8, "logic": 5,
            "structure": 3, "figures": 3}  # 62 new comments, as a first draft by a newcomer may get
    for name, strip, extra in (("mockup-a", False, None), ("mockup-b", True, None), ("mockup-c", True, many)):
        doc = pymupdf.open(str(draw(paper, 2, out / "{}.pdf".format(name), strip, extra)))
        for k, page in enumerate(doc):
            page.get_pixmap(dpi=144).save(str(out / "png" / "{}{}.png".format(name, "-%d" % (k + 1) if k else "")))


if __name__ == "__main__":
    main()
