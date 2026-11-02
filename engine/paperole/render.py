"""final.pdf and the email text of a round (CONTRACT.md §9 and the amendment "Final PDF in the margin style").

final.pdf = summary page(s) + the round's build PDF, each page widened by a review margin (right; both sides on a
two-column paper). Everything the student must see is burned into the page content, so every reader and print
show it: per-comment boxes in the margin, ID chips beside the anchors with leader lines, the marks in each comment's
own colour and kind, and the student's changes in grey. There are no PDF annotations: a reader showed each note
again in a popup beside its margin box. The outline lists the comments ("Comments (k)") for navigation."""
import datetime
import functools
import math
import os
import re
from pathlib import Path

import pymupdf

from . import analysis, cards, checks, comments, disk, ledger, prose, state

NOTE_EXAMPLE = "% R1-03 your note"  # a student's note (notes.py)
REPLY_RULE = ("No need to list what you fixed. To explain a change, or why you left something as it is, add a comment "
              "line next to it in the .tex: {}.".format(NOTE_EXAMPLE))
# check items that go out with the round (check_items.py; amendment "Checks to the student"): the program's look, one
# slate that is none of the comments' six colours, a square chip, and the student told (in the summary) it may be wrong
CHECK_FILL, CHECK_INK, CHECK_OPACITY = "#6E8092", "#4E5D6C", 0.30
CHECK_BOX, CHECK_CHIP = (CHECK_INK, "#FFFFFF", CHECK_INK), (CHECK_INK, CHECK_INK, "#FFFFFF")  # (mark, fill, text)
CHECK_LABELS = {"new": "new", "still": "still open"}
CHECK_SIGNS = {"new": "new", "still": "open"}  # their _glyph: + and the ring
CHECK_EXAMPLE = "% {} for an automatic check"
CHECK_RULE = "Fix it, or reply % {} with why it is right."  # the box's header names it an automatic check
CHECK_INTRO = "Paperole found these, not me, and it can be wrong. Fix each, or reply with % {} why it is right."
CHECK_KEY = "an automatic check, found by Paperole, not by me"
CHECK_GROUPS = {"references": "References", "bibliography": "Bibliography", "consistency": "Consistency",
                "typesetting": "Typesetting", "submission": "Submission"}
LABELS = {"new": "new", None: "still open", "reopened": "follow-up", "verified": "resolved",
          "wontfix": "no change needed", "revived": "reopened"}  # the student's words for the statuses (the ledger
# keeps its values; "revived" is a comment closed in an earlier round that the advisor reopened in this one, not the
# verdict `reopened`, which is a follow-up)
INK, MUTED, FAINT, RULE = "#1F1F1F", "#555555", "#BDBDBD", "#DDDDDD"
HIST, HIST_TEXT, HIST_FILL = "#A0A0A0", "#5C5C5C", "#E4EFE6"  # the student's changes: grey, a faint green fill
OPEN, CLOSED = (INK, "#FFFFFF", INK), (HIST, "#F2F2F2", HIST_TEXT)
STATUS = {  # (mark, fill, text) colours of a comment's status on chips, boxes and summary rows: open black (its sign
    # tells which), closed grey like the rest of the history; text ≥ 5.5:1
    "new": OPEN, None: OPEN, "reopened": OPEN, "revived": OPEN, "verified": CLOSED, "wontfix": CLOSED}
MARGIN_BG, MARGIN_EDGE = "#FAFAF7", "#E2E2DC"
MARGIN = 200  # points: the review margin beside the paper
BOX_W = 176  # points: the width of a margin item
GAP = 6  # points between stacked margin items
CHIP = 6.5  # font size of an ID chip beside the paper's text
CHIP_H = 8.6  # points: the height of an ID chip
HIGHLIGHT_OPACITY = 0.35  # a burned-in highlight over the words; the colours are saturated
FADED = 0.45  # opacity of the marks of verified and won't-fix comments
SIZE = {"head": 8.5, "note": 9.0, "small": 8.0}  # margin type, the same on every page: a note is never made smaller
# or cut; what a side cannot hold goes to the band under the paper (_band), and the page grows taller
BAND_TOP = 30  # points from the paper's foot to the band's first items: its rule and label above them
CJK_FONTS = ("/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/STHeiti Light.ttc")
CJK = "\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef"  # ideographs, CJK punctuation and full-width forms: break anywhere
CLOSE = "，。、；：！？）」』〉》】”’"  # never starts a line
TOKEN = re.compile(r"[^\S\xa0]+|[{0}][{1}]*|(?:[^\s{0}]|\xa0)+[{1}]*".format(CJK, CLOSE))  # no break at U+00A0
DISPLAY_IMAGE_H = 64  # points: the most a summary crop is high
DIGIT_INK = 0.18  # of a line number's box height: no ink above its digits, nor below them (digits have no descenders)


# --- Comments and changes ---------------------------------------------------------------------------------

def _groups(lg, n):
    """The comments of round n by group: reopened (revived in this round and not closed again), follow-ups, still
    open, new, verified, won't fix (id order)."""
    key = str(n)
    cs = sorted((c for c in lg["comments"] if key in c["rounds"]), key=lambda c: ledger.id_key(c["id"]))
    carried = [c for c in cs if c["created_round"] < n]
    revived = [c for c in carried if _status(c, n) == "revived"]

    def by(verdict):
        return [c for c in carried if c["rounds"][key]["verdict"] == verdict and c not in revived]
    return revived, by("reopened"), by(None), [c for c in cs if c["created_round"] == n], by("verified"), \
        by("wontfix")


def _status(c, n):
    """new, a verdict, or "revived": a comment reopened in round n after it was closed (a follow-up written for it
    keeps it revived; resolved or kept again, it is closed as any)."""
    if c["created_round"] == n:
        return "new"
    rec = c["rounds"][str(n)]
    return "revived" if rec.get("revived") and rec["verdict"] in (None, "reopened") else rec["verdict"]


def _closed_in(c, n):
    """"Closed in Round K (resolved)" for a comment revived in round n."""
    k = c["rounds"][str(n)]["revived"]["from"]
    return "Closed in Round {} ({})".format(k, LABELS.get(c["rounds"][str(k)]["verdict"], "closed"))


def _quote(c, n, limit=60):
    """The PDF text the comment points at (the last known one if empty now), collapsed, at most limit chars."""
    for k in sorted((int(k) for k in c["rounds"] if int(k) <= n), reverse=True):
        anchor = c["rounds"][str(k)]["anchor"]
        text = " ".join(anchor["text"].split()) if anchor else ""
        if text:
            return text if len(text) <= limit else text[:limit - 1] + "…"
    return ""


def _where(c, n):
    anchor = c["rounds"][str(n)]["anchor"]
    return "p.{}".format(anchor["page"] + 1) if anchor and anchor["page"] is not None else "location not found"


def _verdict_note(c, n):
    """`Round N: <note>` for round n's verdict note, else `Round K (follow-up): <note>` for the latest earlier
    follow-up (a comment followed up in round K and left without a verdict since), else "". An earlier closing remark
    (a comment resolved, then reopened: `revive`) is not repeated under an open comment."""
    if c["rounds"][str(n)]["verdict_note"]:
        return "Round {}: {}".format(n, c["rounds"][str(n)]["verdict_note"])
    for k in sorted((int(k) for k in c["rounds"] if int(k) < n), reverse=True):
        rec = c["rounds"][str(k)]
        if rec["verdict_note"] and rec["verdict"] == "reopened":
            return "Round {} ({}): {}".format(k, LABELS[rec["verdict"]], rec["verdict_note"])
    return ""


def _texts(c, n):
    """(main, muted) text of a comment in the margin and the summary: the reopen or won't-fix note with the
    original note muted, else the original note with an earlier reopen note muted."""
    rec = c["rounds"][str(n)]
    if _status(c, n) == "revived":  # its follow-up first (when written), then where it was closed
        if rec["verdict_note"]:
            return rec["verdict_note"], _closed_in(c, n) + (" · Round {}: {}".format(c["created_round"], c["note"])
                                                           if c["note"] else "")
        return c["note"], "{}, reopened in Round {}.".format(_closed_in(c, n), n)
    if rec["verdict"] and rec["verdict_note"]:
        return rec["verdict_note"], "Round {}: {}".format(c["created_round"], c["note"]) if c["note"] else ""
    return c["note"], _verdict_note(c, n) if rec["verdict"] in (None, "reopened") and c["created_round"] < n else ""


def _short(text, limit):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _printed(ch, side):
    """One side ("before" or "now") of a change in the words its PDF prints, from the change's context (amendment
    "Changes tab"): the marked words of a text context, or the words in the rects of a table, figure or formula when
    they hold the source's letters and digits (a table cell, not a formula's glyphs). "" when there are none, or when
    they are much longer than the source (a footnote mark's whole sentence)."""
    c = (ch.get("context") or {}).get(side)
    if not c:
        return ""
    words = " ".join((" ".join(c["text"][a:b] for a, b in c["sel"]) if c["display"] == "text" else c["text"]).split())
    src = comments._fold(re.sub(r"\\[A-Za-z@]+", "", ch["old_text" if side == "before" else "new_text"]))
    got = comments._fold(words)
    if not got or len(got) > 2 * len(src) + 12 or c["display"] != "text" and src not in got:
        return ""
    return words


def _change_text(ch, limit=40):
    """One line about a change: its "about" when it has one (an \\input line, formatting: cards.describe), else what
    was added, deleted, moved or replaced, in the words the PDF prints (LaTeX source when its context has none, or
    when both sides print the same words: a change of case or of a reference), after the table or figure it is in."""
    if ch.get("about"):
        return ch["about"]["text"]
    where = ch["float"] + ": " if ch.get("float") else ""
    if ch.get("figure"):
        return where + "new image file " + ch["figure"]
    old, new = _printed(ch, "before"), _printed(ch, "now")
    if ch["kind"] == "replace" and old == new:
        old = new = ""
    old, new = _short(old or ch["old_text"], limit), _short(new or ch["new_text"], limit)
    was = ((ch.get("context") or {}).get("before") or {}).get("page")
    moved = "moved here (was on p.{}) “{{1}}”".format(was + 1) if was is not None and was != ch.get("page") \
        else "moved “{1}”"
    return where + {"insert": "added “{1}”", "delete": "deleted “{0}”", "move": moved}.get(
        ch["kind"], "“{0}” → “{1}”").format(old, new)


# --- Text -------------------------------------------------------------------------------------------------

@functools.lru_cache(maxsize=None)
def _font(face):
    """Helvetica (MuPDF's built-in clone) for r, b and i; a CJK font for what Helvetica lacks (system Hiragino
    Sans GB or STHeiti, else MuPDF's Droid Sans Fallback)."""
    if face == "cjk":
        path = next((p for p in CJK_FONTS if os.path.exists(p)), None)
        return pymupdf.Font(fontfile=path) if path else pymupdf.Font("cjk")
    return pymupdf.Font({"r": "helv", "b": "hebo", "i": "heit"}[face])


@functools.lru_cache(maxsize=8192)
def _face(style, ch):
    return style if ch.isspace() or _font(style).has_glyph(ord(ch)) else "cjk"


def _runs(s, style):
    out = []
    for ch in s:
        face = _face(style, ch)
        if out and out[-1][0] == face:
            out[-1][1] += ch
        else:
            out.append([face, ch])
    return out


def _width(s, size, style="r"):
    return sum(_font(face).text_length(t, fontsize=size) for face, t in _runs(s, style))


def _put(page, x, y, s, size, style="r", color=INK):
    """One line of text with its baseline at y; returns the x after it."""
    if not s:
        return x
    tw = pymupdf.TextWriter(page.rect)
    for face, t in _runs(s, style):
        tw.append((x, y), t, font=_font(face), fontsize=size)
        x = tw.last_point.x
    tw.write_text(page, color=_rgb(color))
    return x


def _fit(s, width, size, style="r"):
    """s cut with … to fit width."""
    if _width(s, size, style) <= width:
        return s
    while s and _width(s + "…", size, style) > width:
        s = s[:-1]
    return s.rstrip(" ,;:·") + "…"


def _wrap(s, width, size, style="r", maxlines=None):
    """Lines of s at most width wide: breaks at spaces and between CJK characters; a longer word is cut."""
    lines = []
    for para in (s or "").splitlines():
        cur = ""
        for tok in TOKEN.findall(para):
            if tok.isspace():
                cur += " " if cur else ""
            elif _width(cur + tok, size, style) <= width:
                cur += tok
            else:
                if cur.strip():
                    lines.append(cur.rstrip())
                while len(tok) > 1 and _width(tok, size, style) > width:
                    k = len(tok) - 1
                    while k > 1 and _width(tok[:k], size, style) > width:
                        k -= 1
                    lines.append(tok[:k])
                    tok = tok[k:]
                cur = tok
        if cur.strip():
            lines.append(cur.rstrip())
    if maxlines and len(lines) > maxlines:
        lines = lines[:maxlines - 1] + [_fit(lines[maxlines - 1] + " …", width, size, style)]
    return lines


def _rgb(hex_colour):
    return tuple(int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))


def _glyph(page, kind, x, y, size, color):
    """A status sign before a header, drawn (Helvetica has no ✓ or ↺); returns the x after it. A revived comment has
    none: its word "reopened" says it (no circular arrow, which meant follow-up in final.pdfs before 2026-10-17)."""
    if kind == "revived":
        return x
    c, s = _rgb(color), size / 7.0
    if kind == "verified":
        page.draw_polyline([(x, y - 2.6 * s), (x + 1.9 * s, y - 0.5 * s), (x + 5.2 * s, y - 5.4 * s)], color=c,
                           width=1.1 * s)
        return x + 8.3 * s
    if kind == "open":  # still open: a ring
        r = size * 0.28
        page.draw_circle((x + r + 0.3, y - size * 0.33), r, color=c, width=0.9)
        return x + 2 * r + 2.4
    if kind == "reopened":  # a U-turn arrow, as the app's follow-up sign (arrow.uturn.backward)
        top, bottom = y - 4.6 * s, y - 0.6 * s
        r = (bottom - top) / 2
        cx = x + 6.0 * s - r
        arc = [(cx + r * math.sin(math.radians(a)), top + r - r * math.cos(math.radians(a))) for a in range(0, 181, 15)]
        page.draw_polyline([(x + 0.5 * s, top)] + arc + [(x + 2.4 * s, bottom)], color=c, width=0.9)
        page.draw_polyline([(x + 2.2 * s, top - 1.5 * s), (x + 0.5 * s, top), (x + 2.2 * s, top + 1.5 * s)], color=c,
                           width=0.9)
        return x + 8.3 * s
    if kind == "deleted":
        _cross(page, x + 2.2, y - size * 0.32, color, 1.6)
        return x + 7
    return _put(page, x, y, {"new": "+", "wontfix": "–"}[kind], size, "b", color) + 2.2


def _cross(page, cx, cy, color, s=1.7):
    """A small ×: a deletion point."""
    for d in (1, -1):
        page.draw_line((cx - s, cy - s * d), (cx + s, cy + s * d), color=_rgb(color), width=0.85)


# --- Rows: one list of text blocks for measuring and drawing ------------------------------------------------

def _row(lines, size, style="r", color=INK, gap=0.0, glyph="", lead=None, struck=False):
    return {"lines": lines, "size": size, "lead": lead or round(size * 1.22, 2), "style": style, "color": color,
            "gap": gap, "glyph": glyph, "struck": struck}


def _rows_h(rows):
    return sum(r["gap"] + len(r["lines"]) * r["lead"] for r in rows)


def _draw_rows(page, x, y, rows):
    for r in rows:
        y += r["gap"]
        for k, line in enumerate(r["lines"]):
            base = y + (r["lead"] + r["size"] * 0.70) / 2
            x0 = _glyph(page, r["glyph"], x, base, r["size"], r["color"]) if k == 0 and r["glyph"] else x
            x1 = _put(page, x0, base, line, r["size"], r["style"], r["color"])
            if r["struck"]:
                page.draw_line((x0, base - r["size"] * 0.3), (x1, base - r["size"] * 0.3), color=_rgb(r["color"]),
                               width=0.6)
            y += r["lead"]
    return y


def _glyph_w(kind, size):
    s = size / 7.0
    if kind == "revived":
        return 0.0
    return {"verified": 8.3 * s, "open": 2 * size * 0.28 + 2.4, "reopened": 8.3 * s, "deleted": 7}.get(
        kind, _width({"new": "+", "wontfix": "–"}.get(kind, ""), size, "b") + 2.2)


# --- The margin of a paper page ---------------------------------------------------------------------------

class _Overflow(Exception):
    pass


def _comment_item(c, n, snippets, sz=SIZE):
    """A comment's margin item {"rows", "inside", "ey"}: a box for an open comment (its first `inside` rows), a
    heading line for a closed one with its verdict note below, both grey, every text whole; then the deleted words of
    its changes on the page, in grey. ey: the header's middle."""
    status, rec = _status(c, n), c["rounds"][str(n)]
    text, head = STATUS[status][2], "{} · {}".format(c["id"], LABELS[status])
    if status in ("verified", "wontfix"):
        rows = [_row([head], sz["head"], "b", text, glyph=status, lead=sz["head"] + 3.2)]
        if rec["verdict_note"]:
            rows.append(_row(_wrap(rec["verdict_note"], BOX_W - 12, sz["small"]), sz["small"], color=text))
    else:
        head += " · text deleted" if rec["anchor_state"] == "gone" else ""
        rows = [_row([head], sz["head"], "b", text, glyph=status or "open", lead=sz["head"] + 3.2)]
        main, muted = _texts(c, n)
        if main:
            rows.append(_row(_wrap(main, BOX_W - 13, sz["note"]), sz["note"]))
        if muted:
            rows.append(_row(_wrap(muted, BOX_W - 13, sz["small"]), sz["small"], color=MUTED, gap=2.5))
    inside = len(rows) if status not in ("verified", "wontfix") else 0
    for old in snippets:
        lines = _wrap(old, BOX_W - 12, sz["small"])
        rows.append(_row(lines[:2], sz["small"], color=HIST_TEXT, gap=3, glyph="deleted", struck=True))
        more = len(old.split()) - len(" ".join(lines[:2]).split())
        if len(lines) > 2 and more > 0:
            rows.append(_row(["(+{} more words deleted)".format(more)], sz["small"], color=HIST_TEXT))
    return {"rows": rows, "inside": inside, "ey": (4 if inside else 0) + rows[0]["lead"] / 2,
            "h": _rows_h(rows) + (7.5 if inside else 0)}


def _check_item(v, sz=SIZE):
    """A check item's margin box {"rows", "inside", "ey", "h"} (v: its view, check_items.view): headed "A2-03 · new ·
    automatic check" in slate, its note (else its detail), the advisor's follow-up ("Me: …") and a muted last line, fix
    it or reply (CHECK_RULE); every text whole."""
    head = "{} · {} · automatic check".format(v["id"], CHECK_LABELS[v["state"]])
    rows = [_row(_wrap(head, BOX_W - 20, sz["head"], "b"), sz["head"], "b", CHECK_INK,
                 glyph=CHECK_SIGNS[v["state"]], lead=sz["head"] + 3.2)]
    if v["note"]:
        rows.append(_row(_wrap(v["note"], BOX_W - 13, sz["note"]), sz["note"]))
    if v["detail"] and not v["note"]:  # the note says it for the student; the detail is the finding's source
        rows.append(_row(_wrap(v["detail"], BOX_W - 13, sz["small"]), sz["small"], gap=2.5))
    if v.get("advisor_note"):
        rows.append(_row(_wrap("Me: " + v["advisor_note"], BOX_W - 13, sz["note"]), sz["note"], gap=2.5))
    rows.append(_row(_wrap(CHECK_RULE.replace("% ", "%\xa0").format(v["id"]), BOX_W - 13, sz["small"]), sz["small"],
                     color=MUTED, gap=2.5))
    return {"rows": rows, "inside": len(rows), "ey": 4 + rows[0]["lead"] / 2, "h": _rows_h(rows) + 7.5}


def _draw_item(page, x, y, e):
    rows, inside = e["rows"], e["inside"]
    if inside:
        mark, fill, _ = (_rgb(h) for h in (CHECK_BOX if "a" in e else STATUS[e["status"]]))
        h = 4 + _rows_h(rows[:inside]) + 3.5
        page.draw_rect(pymupdf.Rect(x, y, x + BOX_W, y + h), color=mark, fill=fill, width=0.5)
        page.draw_rect(pymupdf.Rect(x, y, x + 2.2, y + h), color=None, fill=mark, width=0)
        _draw_rows(page, x + 7, y + 4, rows[:inside])
        _draw_rows(page, x + 3, y + h, rows[inside:])
    else:
        _draw_rows(page, x + 1, y, rows)


def _stack(items, top, bottom, least=GAP):
    """Each item at the height its leader leaves the paper, or just below the one above; then pushed up from the
    bottom. Items keep the order of their leaders, so leaders never cross. GAP apart, or closer when they must, down to
    `least`; _Overflow when they do not fit."""
    items.sort(key=lambda it: (it["ly"], it["prio"]))
    gap = GAP
    if len(items) > 1:
        gap = max(min(GAP, (bottom - top - sum(it["h"] for it in items)) / (len(items) - 1)), least)
    y = top
    for it in items:
        it["y"] = max(it["ly"] - it["ey"], y)
        y = it["y"] + it["h"] + gap
    limit = bottom
    for it in reversed(items):
        it["y"] = min(it["y"], limit - it["h"])
        limit = it["y"] - gap
    if items and items[0]["y"] < top - 0.1:
        raise _Overflow
    for it in items:  # rounding
        it["y"] = max(it["y"], top)


def _band(items, top, last):
    """Lay out under the paper, from `top`, the comments a crowded margin could not hold, in the reading order of
    their anchors (the left column first on a two-column paper), across a grid of columns BOX_W wide from 12 pt in
    to `last` (the x of the right margin's items): as many columns as the grid has, or as there are items, fewer
    standing in the grid's middle; each item, in turn, at the foot of the shortest column (the leftmost of equals),
    GAP below the one above it, so the band reads across, row by row, and its columns stay even. Sets each item's
    "x" and "y"; returns the band's height."""
    items.sort(key=lambda e: (e["side"] != "L", e["ly"]))
    slots = int((last - 12) // (BOX_W + GAP)) + 1  # never closer than a box and a gap (504 pt pages overlapped)
    step = (last - 12) / (slots - 1) if slots > 1 else 0
    k = min(slots, len(items))
    x0 = 12 + (slots - k) * step / 2  # the grid's middle
    feet = [top + BAND_TOP] * k
    for e in items:
        c = feet.index(min(feet))
        e["x"], e["y"] = x0 + c * step, feet[c]
        feet[c] += e["h"] + GAP
    return max(feet) - GAP - top + 24


def _bounds(rects):
    r = pymupdf.Rect(rects[0])
    for q in rects[1:]:
        r |= pymupdf.Rect(q)
    return r


def _overlap(rects, others):
    """The area two sets of rects share, each other rect grown by 1 pt (a deletion point is 2 pt wide)."""
    return sum(max(0, min(r.x1, q[2] + 1) - max(r.x0, q[0] - 1)) * max(0, min(r.y1, q[3] + 1) - max(r.y0, q[1] - 1))
               for r in rects for q in others)


def _review_page(page, pno, n, cs, changes, geo, header, asked, marks=()):
    """Widen one paper page and burn in its marks, chips, margin items and leaders. header: the margin's header, cut
    to fit (final_pdf); asked: comments.commenters; marks: the views of the check items that go out (check_items.py),
    each with a chip and a box at its first place on the page and all its places there highlighted. Returns the
    margin items placed: [{"page", "id", "side", "rect"}]."""
    two, tx, gap = geo
    pw, ph = page.rect.width, page.rect.height
    words = page.get_text("words")
    dx = MARGIN if two else 0
    mb = page.mediabox
    page.set_mediabox(pymupdf.Rect(mb.x0 - dx, mb.y0, mb.x1 + MARGIN, mb.y1))
    W = page.rect.width
    x0, x1 = tx or (0, pw)
    mid = gap or pw / 2
    # what lies in the paper's own margins (line numbers of a review-mode ruler): leaders pass between its numbers
    outside = {"R": [w for w in words if w[0] > x1 + 1], "L": [w for w in words if w[2] < x0 - 1]}

    def side(r):
        return "L" if two and (r.x0 + r.x1) / 2 < mid else "R"

    # entries: comments located on the page, and the student's changes no comment asked for
    ents = []
    mine = [ch for ch in changes if ch["page"] == pno and ch["rects"]]
    for c in cs:
        rec = c["rounds"][str(n)]
        a = rec["anchor"]
        if not a or a["page"] != pno or not a["rects"]:
            continue
        rects = [pymupdf.Rect(r) for r in a["rects"]]
        last = rects[-1]
        ly = last.y0 + 8 if c["kind"] == "box" else (last.y0 + last.y1) / 2
        ents.append({"c": c, "id": c["id"], "status": _status(c, n), "rects": rects, "ly": min(max(ly, 0), ph),
                     "gone": rec["anchor_state"] == "gone", "side": side(_bounds(rects)), "prio": 0, "snippets": []})
    for v in marks:  # a check item ("a"), placed by its first place on the page as a comment by its anchor
        here = [p for p in v["places"] if p["page"] == pno and p["rects"]]
        if not here:
            continue
        rects = [pymupdf.Rect(r) for r in here[0]["rects"]]
        ly = (rects[-1].y0 + rects[-1].y1) / 2
        ents.append({"a": v, "id": v["id"], "status": v["state"], "rects": rects, "ly": min(max(ly, 0), ph),
                     "all": [pymupdf.Rect(r) for p in here for r in p["rects"]], "side": side(_bounds(rects)),
                     "prio": 0})
    # the old words of a change once, under the comment for it (or on it) whose mark covers most of it
    located = {e["id"]: e for e in ents}
    for ch in mine:
        mates = [located[k] for k in sorted(set(ch["attached_to"]) | set(asked.get(ch["id"], [])), key=ledger.id_key)
                 if k in located]
        if mates and ch["kind"] in ("replace", "delete") and ch["old_text"].strip() and not ch.get("figure") \
                and not ch.get("about"):  # an \input line or formatting deletes no printed words
            owner = max(mates, key=lambda e: _overlap(e["rects"], ch["rects"]))
            owner["snippets"].append(" ".join((_printed(ch, "before") or ch["old_text"]).split()))
    for ch in mine:
        if ch["attached_to"] or asked.get(ch["id"]):
            continue
        r = pymupdf.Rect(ch["rects"][0])
        ents.append({"ch": ch, "id": ch["id"], "rects": [r], "ly": (r.y0 + r.y1) / 2,
                     "side": side(_bounds([pymupdf.Rect(q) for q in ch["rects"]])), "prio": 1})

    # ID chips beside the text at the anchor's line; when another chip has that line, at the nearest line above of
    # the comment's own mark that has none (chips side by side ran into a margin ruler), else beside it; past the
    # paper's margin ruler when it would cover a line number there (a ruler close to the text: ICML, ACM review)
    for sd in "LR":
        ends = {}
        for e in sorted((e for e in ents if e["side"] == sd), key=lambda e: (e["ly"], e["prio"])):
            k = next((k for k in ends if abs(k - e["ly"]) < 4), e["ly"])
            if k in ends and ("a" in e or "c" in e and e["c"]["kind"] != "box"):
                free = [y for y in ((r.y0 + r.y1) / 2 for r in reversed(e["rects"]) if side(r) == sd)
                        if y < e["ly"] - 4 and not any(abs(y - j) < 4 for j in ends)]
                if free:
                    e["ly"] = k = max(free)
            x = ends.get(k, x1 + 6 if sd == "R" else x0 - 9)
            if "c" in e or "a" in e:
                cw = _width(e["id"], CHIP, "b") + 5 + (_glyph_w(CHECK_SIGNS[e["status"]], CHIP) if "a" in e else 0)
                e["chip"] = pymupdf.Rect(x, e["ly"] - CHIP_H / 2, x + cw, e["ly"] + CHIP_H / 2) if sd == "R" else \
                    pymupdf.Rect(x - cw, e["ly"] - CHIP_H / 2, x, e["ly"] + CHIP_H / 2)
                if _covers(e["chip"], outside[sd]):
                    x = max(w[2] for w in outside[sd]) + 3 if sd == "R" else min(w[0] for w in outside[sd]) - 3
                    e["chip"] = pymupdf.Rect(x, e["chip"].y0, x + cw, e["chip"].y1) if sd == "R" else \
                        pymupdf.Rect(x - cw, e["chip"].y0, x, e["chip"].y1)
                    e["past"] = True  # its leader crosses no number
                e["start"] = e["chip"].x1 + 0.5 if sd == "R" else e["chip"].x0 - 0.5
                ends[k] = e["chip"].x1 + 2.5 if sd == "R" else e["chip"].x0 - 2.5
            else:
                e["start"] = x1 + 1.5 if sd == "R" else x0 - 1.5

    # margin items, whole and in one size (SIZE), GAP apart or closer, down to GAP / 2; a side that cannot hold them
    # gives up first the changes no comment asked for (the summary lists them), then its tallest comments, one by one
    # (the lowest of equals), to the band under the paper, and the page grows taller to hold it. Nothing goes above
    # the margin's header.
    box_x = {"L": 12, "R": dx + pw + 12}
    for e in ents:
        _margin_item(e, n)
    band = []
    for sd in "LR":
        mine_side = [e for e in ents if e["side"] == sd]
        if not _fit_side(mine_side, ph):
            ents = [e for e in ents if e["side"] != sd or "c" in e or "a" in e]
            mine_side = [e for e in mine_side if "c" in e or "a" in e]
            while not _fit_side(mine_side, ph):
                e = max(mine_side, key=lambda e: (e["h"], e["ly"]))
                mine_side.remove(e)
                e["band"] = True
                band.append(e)
    if band:
        bh = _band(band, ph, box_x["R"])
        page.set_mediabox(pymupdf.Rect(mb.x0 - dx, mb.y0 - bh, mb.x1 + MARGIN, mb.y1))
        page.draw_rect(pymupdf.Rect(0, ph, W, ph + bh), color=None, fill=_rgb(MARGIN_BG), width=0)
        page.draw_line((dx, ph), (dx + pw, ph), color=_rgb(MARGIN_EDGE), width=0.6)  # the paper's foot
        bx0 = min(e["x"] for e in band) - 2
        _put(page, bx0, ph + 16, "Continued from the margin", 7.5, "r", MUTED)
        page.draw_line((bx0, ph + 21), (W - 8, ph + 21), color=_rgb(RULE), width=0.4)

    # margins, then the paper's marks
    for mx0, mx1 in ([(0, dx)] if two else []) + [(dx + pw, W)]:
        page.draw_rect(pymupdf.Rect(mx0, 0, mx1, ph), color=None, fill=_rgb(MARGIN_BG), width=0)
        edge = mx1 if mx0 == 0 else mx0
        page.draw_line((edge, 0), (edge, ph), color=_rgb(MARGIN_EDGE), width=0.6)
    hx = dx + pw + 10
    _put(page, hx, 26, header, 7.5, "r", MUTED)
    page.draw_line((hx, 31), (W - 8, 31), color=_rgb(RULE), width=0.4)
    _change_marks(page, mine, dx, x0, x1, mid if two else None)
    for e in ents:
        if "c" in e:
            _comment_mark(page, e, dx, n)
        elif "a" in e:
            for r in e["all"]:  # a check's places: the slate highlight
                page.draw_rect(r + (dx, 0, dx, 0), color=None, fill=_rgb(CHECK_FILL), width=0,
                               fill_opacity=CHECK_OPACITY)

    placed = []
    for e in ents:
        if e.get("band"):  # its chip with a small pointer down from its foot (beside it, a chip on the same line
            # covered it), and the item; no leader
            mark = _rgb(CHECK_INK if "a" in e else STATUS[e["status"]][0])
            chip = e["chip"] + (dx, 0, dx, 0)
            _draw_chip(page, e, chip)
            cx = (chip.x0 + chip.x1) / 2
            page.draw_polyline([(cx - 1.9, chip.y1 - 0.3), (cx, chip.y1 + 1.7), (cx + 1.9, chip.y1 - 0.3)],
                               color=None, fill=mark, width=0, closePath=True)
            _draw_item(page, e["x"], e["y"], e)
            placed.append({"page": pno, "id": e["id"], "side": "B", "leader": None, "chip": chip,
                           "rect": pymupdf.Rect(e["x"], e["y"], e["x"] + BOX_W, e["y"] + e["h"])})
            continue
        bx = box_x[e["side"]]
        if "c" in e or "a" in e:
            mark = _rgb(CHECK_INK if "a" in e else STATUS[e["status"]][0])
            _draw_chip(page, e, e["chip"] + (dx, 0, dx, 0))
            _draw_item(page, bx, e["y"], e)
            closed = e["status"] in ("verified", "wontfix")
            style = {"color": mark, "width": 0.5 if closed else 0.6, "stroke_opacity": 0.75 if closed else 0.9}
        else:
            _draw_item(page, bx, e["y"], e)
            style = {"color": _rgb(HIST), "width": 0.45, "stroke_opacity": 0.8, "dashes": "[1.4 1.2] 0"}
        end = (bx - 1.5 if e["side"] == "R" else bx + BOX_W + 1.5, e["y"] + e["ey"])
        pts = _leader(dx + e["start"], e["ly"], end, [] if e.get("past") else
                      [_ink(w) + (dx, 0, dx, 0) for w in outside[e["side"]]], e["side"])
        page.draw_polyline(pts, **style)
        rect = pymupdf.Rect(bx, e["y"], bx + BOX_W, e["y"] + e["h"])
        placed.append({"page": pno, "id": e["id"], "side": e["side"], "rect": rect, "leader": pts,
                       "chip": e["chip"] + (dx, 0, dx, 0) if "chip" in e else None})
    return placed


def _draw_chip(page, e, chip):
    """An entry's ID chip beside the paper's text: a comment's in its status's colours, a check item's square, slate,
    its sign and id in white."""
    if "a" in e:
        page.draw_rect(chip, color=_rgb(CHECK_CHIP[0]), fill=_rgb(CHECK_CHIP[1]), width=0.6)
        x = _glyph(page, CHECK_SIGNS[e["status"]], chip.x0 + 2.5, chip.y1 - 2.6, CHIP, CHECK_CHIP[2])
        _put(page, x, chip.y1 - 2.6, e["id"], CHIP, "b", CHECK_CHIP[2])
        return
    mark, fill = (_rgb(h) for h in STATUS[e["status"]][:2])
    page.draw_rect(chip, color=mark, fill=fill, width=0.6, radius=0.3)
    _put(page, chip.x0 + 2.5, chip.y1 - 2.6, e["id"], CHIP, "b", STATUS[e["status"]][2])


def _margin_item(e, n):
    """An entry's rows (a comment's item, a check item's, or "your change" for a change no comment asked for), whole,
    in SIZE."""
    if "c" in e:
        e.update(_comment_item(e["c"], n, e["snippets"]))
    elif "a" in e:
        e.update(_check_item(e["a"]))
    else:
        row = _row(_wrap("your change · " + _change_text(e["ch"]), BOX_W - 4, SIZE["small"], maxlines=2),
                   SIZE["small"], color=HIST_TEXT)
        e.update(rows=[row], inside=0, ey=row["lead"] / 2, h=_rows_h([row]))


def _fit_side(items, ph):
    """Whether one side's margin items fit beside the paper, below its header, GAP / 2 apart at least; when they do,
    they are placed (_stack)."""
    try:
        _stack(items, 44, ph - 24, GAP / 2)
        return True
    except _Overflow:
        return False


def _covers(chip, words):
    """Whether a chip rect would cover any of the words (a margin ruler's numbers), with 1 pt to spare."""
    return any(w[0] - 1 < chip.x1 and w[2] + 1 > chip.x0 and w[1] - 1 < chip.y1 and w[3] + 1 > chip.y0 for w in words)


def _ink(w):
    """The rect of a margin word that its ink fills: a line number's box without the empty band above and below its
    digits (DIGIT_INK), so a leader finds the gap between numbers set 2 pt apart (ICML, ACL); other words whole."""
    r = pymupdf.Rect(w[:4])
    if w[4].isdigit():
        pad = DIGIT_INK * r.height
        r = pymupdf.Rect(r.x0, r.y0 + pad, r.x1, r.y1 - pad)
    return r


def _leader(sx, ly, end, ruler, sd):
    """The points of a leader from (sx, ly), the side of a chip (CHIP_H high; for a change, the text's edge), to `end`
    at its margin item. Past words in the paper's margin on its side (`ruler`: rects, a review ruler's line numbers)
    it runs level through a gap between them (_gap), so it never touches or underlines a number: from the chip's side
    when the gap is level with the chip, else sloping to the gap before the numbers; then on to the item."""
    if not ruler:
        return [(sx, ly), end]
    right = sd == "R"
    near = min(r.x0 for r in ruler) - 1.5 if right else max(r.x1 for r in ruler) + 1.5
    bend = max(r.x1 for r in ruler) + 3 if right else min(r.x0 for r in ruler) - 3
    y = _gap([(r.y0, r.y1) for r in ruler], ly + 1.0)  # level with the chip, else the gap below it on a tie
    y0 = min(max(y, ly - CHIP_H / 2 + 0.6), ly + CHIP_H / 2 - 0.6)  # where it leaves the chip
    if y0 == y or (near - sx if right else sx - near) < 1:
        return [(sx, y0), (sx, y), (bend, y), end] if y0 != y else [(sx, y), (bend, y), end]
    return [(sx, y0), (near, y), (bend, y), end]


def _gap(boxes, want):
    """The height nearest `want` at which a level line passes between boxes (y0, y1) of a margin's words: in a gap
    between two of them, its middle when the gap is under 6 pt, else at least 3 pt from both; above or below them all,
    3 pt clear. Gaps under 2 pt are not used unless there is no other."""
    boxes = sorted(boxes)
    free, edge = [], -1e9  # (low, high) of the free bands: above the first box, between them, below the last
    for y0, y1 in boxes:
        if y0 > edge:
            free.append((edge, y0))
        edge = max(edge, y1)
    free.append((edge, 1e9))
    best = None
    for lo, hi in free:
        pad = min(3.0, (hi - lo) / 2)
        y = min(max(want, lo + pad), hi - pad)
        key = (hi - lo < 2, abs(y - want))
        if best is None or key < best[0]:
            best = (key, y)
    return best[1]


def _kind(c, n):
    """The kind a comment's mark is drawn as: a closed strike-out as an underline, so accepted words are not read as
    "delete this"."""
    return "underline" if c["kind"] == "strikeout" and _status(c, n) in ("verified", "wontfix") else c["kind"]


def _comment_mark(page, e, dx, n):
    """The anchor in the comment's own colour and kind; faded when the comment is closed."""
    c, rects = e["c"], [r + (dx, 0, dx, 0) for r in e["rects"]]
    fill, ink = (_rgb(h) for h in comments.PALETTE[comments.color(c)])
    alpha = FADED if e["status"] in ("verified", "wontfix") else 1.0
    kind = _kind(c, n)
    r0 = rects[0]
    if e["gone"]:
        cx, cy = r0.x0 + 1, (r0.y0 + r0.y1) / 2
        for d in (1, -1):
            page.draw_line((cx - 2.2, cy - 2.2 * d), (cx + 2.2, cy + 2.2 * d), color=ink, width=1.1,
                           stroke_opacity=alpha)
    elif kind == "note" or all(r.is_empty for r in rects):
        page.draw_circle((r0.x0, (r0.y0 + r0.y1) / 2), 2.4, color=None, fill=ink, fill_opacity=alpha)
    elif kind == "highlight":
        for r in rects:
            page.draw_rect(r, color=None, fill=fill, width=0, fill_opacity=HIGHLIGHT_OPACITY * alpha)
    elif kind == "underline":
        for r in rects:
            page.draw_line((r.x0, r.y1 - 0.8), (r.x1, r.y1 - 0.8), color=ink, width=1.1, stroke_opacity=alpha)
    elif kind == "box":
        page.draw_rect(r0, color=ink, width=1.2, stroke_opacity=alpha)
    else:  # strikeout
        for r in rects:
            y = (r.y0 + r.y1) / 2 + 0.5
            page.draw_line((r.x0, y), (r.x1, y), color=ink, width=1.0, stroke_opacity=alpha)


def _change_marks(page, mine, dx, x0, x1, gap):
    """The student's changes in grey: a faint fill under the new words, a bar beside their lines (two thin bars
    for a change no comment asked for, a dashed one for a move), a × at a deletion, a frame round a new image."""
    under = page.new_shape()
    for ch in mine:
        rects = [pymupdf.Rect(r) + (dx, 0, dx, 0) for r in ch["rects"]]
        if ch.get("figure"):
            page.draw_rect(rects[0] + (-2, -2, 2, 2), color=_rgb(HIST), width=0.9)
            continue
        if ch["kind"] == "delete":
            _cross(page, rects[0].x0 + 1, rects[0].y1 - 3, HIST)
            continue
        runs = []
        for r in rects:
            under.draw_rect(r + (-0.9, -0.2, 0.9, 0.4))
            bx = (x1 + 3 if gap is not None and r.x0 - dx > gap else x0 - 6) + dx
            if runs and runs[-1][0] == bx and r.y0 - runs[-1][2] < 4:
                runs[-1][2] = max(runs[-1][2], r.y1)
            else:
                runs.append([bx, r.y0, r.y1])
        for bx, y0, y1 in runs:
            if ch["kind"] == "move":
                page.draw_line((bx + 0.8, y0), (bx + 0.8, y1), color=_rgb(HIST), width=1.6, dashes="[2.2 1.6] 0")
            elif not ch["attached_to"]:
                for b in (bx - 0.6, bx + 1.4):
                    page.draw_rect(pymupdf.Rect(b, y0, b + 0.9, y1), color=None, fill=_rgb(HIST), width=0)
            else:
                page.draw_rect(pymupdf.Rect(bx, y0, bx + 1.7, y1), color=None, fill=_rgb(HIST), width=0)
    under.finish(color=None, fill=_rgb(HIST_FILL), width=0)
    under.commit(overlay=False)  # under the paper's text


# --- The summary --------------------------------------------------------------------------------------------

class _Flow:
    """Summary pages inserted before the paper, filled from the top; a new page when the next block does not fit."""

    def __init__(self, doc, size):
        self.doc, self.size, self.count, self.links = doc, size, 0, []
        self.L, self.R = 48, size[0] - 48
        self.new_page()

    def new_page(self):
        self.page = self.doc.new_page(pno=self.count, width=self.size[0], height=self.size[1])
        self.count += 1
        self.y = 48

    def need(self, h):
        if self.y + h > self.size[1] - 40:
            self.new_page()

    def chip(self, x, y, text, colours, size=8.0, target=None, glyph=None, radius=0.3):
        """A chip with its baseline at y, its text after a status sign (_glyph) when given; returns the x after it.
        radius None: square (a check item's)."""
        mark, fill, ink = colours
        r = pymupdf.Rect(x, y - size - 1.0, x + (_glyph_w(glyph, size) if glyph else 0) + _width(text, size, "b") + 8,
                         y + 2.8)
        self.page.draw_rect(r, color=_rgb(mark), fill=_rgb(fill), width=0.6, radius=radius)
        _put(self.page, _glyph(self.page, glyph, x + 3.5, y, size, ink) + 0.5 if glyph else x + 4, y, text, size, "b",
             ink)
        if target:
            self.links.append((self.count - 1, r, target))
        return r.x1

    def section(self, title):
        self.need(40)
        self.y += 14
        _put(self.page, self.L, self.y, title, 10.5, "b")
        self.page.draw_line((self.L, self.y + 4.5), (self.R, self.y + 4.5), color=_rgb(RULE), width=0.6)
        self.y += 18


def _target(c, n):
    """(paper page, y) a summary chip jumps to, or None."""
    a = c["rounds"][str(n)]["anchor"]
    return (a["page"], a["rects"][0][1]) if a and a["page"] is not None and a["rects"] else None


def _crop(paper, lg, c, n):
    """(page, clip) of the round's image context of a comment (display math, figure, table, box), or None."""
    rec = c["rounds"][str(n)]
    ctx = rec["context"] if "context" in rec else cards.context(paper, lg, c, n)
    if ctx and ctx.get("display") == "image" and ctx.get("clip") and ctx.get("page") is not None:
        return ctx["page"], pymupdf.Rect(ctx["clip"])
    return None


def _comment_row(f, clean, paper, lg, c, n, label=None):
    """A summary row: group label, chip, page, the comment's text, and its quote or a crop of its image."""
    status = _status(c, n)
    X1 = f.L + 160
    TW = (f.R - X1) * 0.55 - 12
    X2, QW = X1 + TW + 16, f.R - (X1 + TW + 16)
    main, muted = _texts(c, n)
    a = _wrap(main, TW, 9.0) if main else []
    b = _wrap(muted, TW, 8.0) if muted else []
    room = f.size[1] - 96  # the most text a row holds: a summary page's room (_Flow: 48 pt from its top to 40 pt
    # from its foot), less the row's 2 pt below its text and 6 pt before the next
    if 11 * len(a) + 9.8 * len(b) > room:  # longer than a page (about 2,400 characters): the main text first, then
        # at least two lines of the muted one and, when the main text is cut, where the whole text is
        ka = min(len(a), int((room - 9.8 * (min(len(b), 2) + 1)) // 11))
        cue = ["(full text in the email)"] if ka < len(a) else []
        a = _wrap(main, TW, 9.0, maxlines=ka)
        kb = int((room - 11 * len(a)) // 9.8) - len(cue)
        b = (_wrap(muted, TW, 8.0, maxlines=kb) if muted and kb > 0 else []) + cue
    crop = _crop(paper, lg, c, n)
    if crop:
        scale = min(QW / crop[1].width, DISPLAY_IMAGE_H / crop[1].height, 1.0)
        qh = crop[1].height * scale + 2
    else:
        quote, state = _quote(c, n, 200), c["rounds"][str(n)]["anchor_state"]
        quote = ("deleted: " if state == "gone" else "") + "“{}”".format(quote) if quote else ""
        if state == "orphan":
            quote += " (location not found in Round {})".format(n)
        q = _wrap(quote, QW, 8.5, "i", 3) if quote else []
        qh = 10.5 * len(q)
    heading = _wrap(label, 74, 9, "b") if label else []  # "No change needed (k)": on two lines, clear of the chip
    h = max(11 * len(a) + 9.8 * len(b) + 2, qh, 11 * len(heading), 11)
    f.need(h + 6)
    top, yb = f.y, f.y + 9
    for k, line in enumerate(heading):
        _put(f.page, f.L, yb + 11 * k, line, 9, "b", STATUS[status][2])
    f.chip(f.L + 78, yb, c["id"], STATUS[status], target=_target(c, n))
    _put(f.page, f.L + 126, yb, _where(c, n).replace("location not found", "—"), 8.5, "r", MUTED)
    for k, line in enumerate(a):
        _put(f.page, X1, yb + 11 * k, line, 9.0)
    for k, line in enumerate(b):
        _put(f.page, X1, yb + 11 * len(a) + 2 + 9.8 * k, line, 8.0, "r", MUTED)
    if crop:
        r = pymupdf.Rect(X2, top + 1, X2 + crop[1].width * scale, top + 1 + crop[1].height * scale)
        # a picture, not the page as a form: PDFKit would find the whole page's text in it (search, copy)
        pix = clean[crop[0]].get_pixmap(matrix=pymupdf.Matrix(4 * scale, 4 * scale), clip=crop[1], alpha=False)
        f.page.insert_image(r, pixmap=pix)
        f.page.draw_rect(r + (-1, -1, 1, 1), color=_rgb(FAINT), width=0.4)
    else:
        for k, line in enumerate(q):
            _put(f.page, X2, yb + 10.5 * k, line, 8.5, "i", MUTED)
    f.y = top + h + 6


def _check_row(f, v, label=None):
    """A summary row of a check item: its group's name (the group's first row), its square chip, page and text."""
    X1 = f.L + 160
    lines = _wrap(v["text"], f.R - X1, 9.0)
    heading = _wrap(label, 74, 9, "b") if label else []
    h = max(11 * len(lines), 11 * len(heading), 11)
    f.need(h + 4)
    yb = f.y + 9
    for k, line in enumerate(heading):
        _put(f.page, f.L, yb + 11 * k, line, 9, "b", CHECK_INK)
    f.chip(f.L + 78, yb, v["id"], CHECK_CHIP, target=_check_target(v), glyph=CHECK_SIGNS[v["state"]], radius=None)
    _put(f.page, f.L + 126, yb, "p.{}".format(v["places"][0]["page"] + 1) if v["places"] else "—", 8.5, "r", MUTED)
    for k, line in enumerate(lines):
        _put(f.page, X1, yb + 11 * k, line, 9.0)
    f.y += h + 4


def _check_section(f, n, sent):
    """"Automatic checks (k)": the sentence that Paperole found them, not the advisor, and may be wrong; the items
    still open, then the new ones (under those two headings when some are still open), each by group, a row each;
    then those fixed since the round before and those closed as no change needed."""
    items = sent["items"]
    f.section("Automatic checks ({})".format(len(items)))
    if items:
        for line in _wrap(CHECK_INTRO.replace("% ", "%\xa0").format(_first(items)), f.R - f.L, 8.5):
            _put(f.page, f.L, f.y + 2, line, 8.5, "r", MUTED)
            f.y += 12
    still = [v for v in items if v["state"] == "still"]
    for name, group in (("Still open", still), ("New", [v for v in items if v["state"] == "new"])):
        if not group:
            continue
        if still:
            f.need(28)
            _put(f.page, f.L, f.y + 11, "{} ({})".format(name, len(group)), 9.5, "b")
            f.y += 16
        for g in checks.GROUPS:
            rows = [v for v in group if v["group"] == g]
            for k, v in enumerate(rows):
                _check_row(f, v, CHECK_GROUPS[g] if k == 0 else None)
            if rows:
                f.y += 3
    for words, ids in (("Fixed since Round {}".format(n - 1), sent["fixed"]), ("No change needed", sent["ok"])):
        if ids:
            lines = _wrap("{}: {}.".format(words, ", ".join(ids)), f.R - f.L, 9)
            f.need(12 * len(lines) + 4)
            for line in lines:
                _put(f.page, f.L, f.y + 11, line, 9, "r", MUTED)
                f.y += 12
            f.y += 2


def _build_line(lg, n, changes):
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    prev = next((r for r in lg["rounds"] if r["n"] == n - 1), None)
    b = rnd["build"]
    parts = ["{} pages".format(b["pages"])]
    if prev and prev["build"].get("pages"):
        q = prev["build"]["pages"]
        parts[0] += " (same as Round {})".format(n - 1) if q == b["pages"] else " (Round {}: {})".format(n - 1, q)

    def norm(w):
        return re.sub(r" on (input line|page) \d+", "", w)
    undefined = [m for w in b["warnings"]
                 for m in re.findall(r"(?:Reference|Citation) `([^']*)' on page \d+ undefined", w)]
    parts.append("undefined: " + ", ".join(sorted(set(undefined))) if undefined
                 else "no undefined references or citations")
    if prev:
        new = {norm(w) for w in b["warnings"]} - {norm(w) for w in prev["build"]["warnings"]}
        parts.append("{} new LaTeX warning{}".format(len(new), "" if len(new) == 1 else "s") if new
                     else "no new LaTeX warnings")
    parts += ["{} was replaced".format(ch["figure"]) for ch in changes if ch.get("figure")]
    if b["status"] == "errors":
        parts.append("the build had LaTeX errors")
    return "  ·  ".join(parts)


def _sign(status):
    """The _glyph of a status (a ring for still open), so status reads without colour too."""
    return status or "open"


def _names(ids):
    return ids[0] if len(ids) == 1 else ", ".join(ids[:-1]) + " and " + ids[-1]


def _reply_rule(items):
    """REPLY_RULE, naming a check item's id too when check items go out (items: their views)."""
    if not items:
        return REPLY_RULE
    return REPLY_RULE[:-1] + ", or {}.".format(CHECK_EXAMPLE.format(_first(items)))


def _first(items):
    """The first id of check items (their views), for the examples of a reply."""
    return min((v["id"] for v in items), key=ledger.id_key)


def _check_target(v):
    """(paper page, y) a check item's chip jumps to (its first place with rects), or None."""
    p = next((p for p in v["places"] if p["rects"]), None)
    return (p["page"], p["rects"][0][1]) if p else None


def _summary(doc, clean, paper, lg, n, changes, size, asked, read=(), sent=None):
    """Draw the summary pages at the front of doc; returns them as a _Flow (count and chip links). changes: in the
    paper's order; asked: comments.commenters; sent: the check items that go out (check_items.outgoing) or None."""
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    revived, reopened, still, new, verified, wontfix = _groups(lg, n)
    today = datetime.date.today().isoformat()
    f = _Flow(doc, size)
    L, R, p = f.L, f.R, f.page
    _put(p, L, 32, "Paperole · Round {} review · {}".format(n, today), 8, "r", MUTED)
    _put(p, L, 60, "Review of Round {}".format(n), 19, "b")
    y = 78
    for line in _wrap(lg["paper"]["title"], R - L, 11):
        _put(p, L, y, line, 11)
        y += 13.5
    meta = ("Student: {} · source received {} · reviewed {} · page numbers are the paper's (the summary comes before "
            "its page 1)").format(lg["paper"]["student"], rnd["created"][:10], today)
    for line in _wrap(meta, R - L, 8.5):
        _put(p, L, y + 1.5, line, 8.5, "r", MUTED)
        y += 11

    # how to reply, and what to do next round
    todo = sorted(revived + reopened + still + new, key=lambda c: ledger.id_key(c["id"]))
    items = sent["items"] if sent else []
    rule = _wrap(_reply_rule(items).replace(NOTE_EXAMPLE, NOTE_EXAMPLE.replace(" ", "\xa0")).replace("% A", "%\xa0A"),
                 R - L - 106, 9.5)
    # one line of chips, or with check items going out a line of comments and one of checks (each when it has any),
    # each after its label: [(label or None, [(chip, its sign, colours, target, radius)])]
    lines = [(None if not items else "Comments ({}):".format(len(todo)),
              [(c["id"], _sign(_status(c, n)), STATUS[_status(c, n)], _target(c, n), 0.3) for c in todo])]
    if items:
        lines = [ln for ln in lines if ln[1]] + [("Automatic checks ({}):".format(len(items)),
                                                  [(v["id"], CHECK_SIGNS[v["state"]], CHECK_CHIP, _check_target(v),
                                                    None) for v in items])]
    chips, labels, cy = [], [], 0
    for k, (label, row) in enumerate(lines):
        if k:
            cy += 14
        labels.append((cy, label))
        x0 = L + 130 + (_width(label, 9.5) + 6 if label else 0)
        cx = x0
        for chip in row:
            w = _glyph_w(chip[1], 8) + _width(chip[0], 8, "b") + 13
            if cx + w > R - 10:
                cx, cy = x0, cy + 14
            chips.append((cx, cy, chip))
            cx += w
    top = y + 6
    box_h = 12 * len(rule) + 41 + cy
    p.draw_rect(pymupdf.Rect(L, top, R, top + box_h), color=_rgb("#D5DDEA"), fill=_rgb("#F5F8FC"), width=0.6)
    _put(p, L + 10, top + 15, "How to reply", 9.5, "b")
    for k, line in enumerate(rule):
        _put(p, L + 96, top + 15 + 12 * k, line, 9.5)
    ty = top + 15 + 12 * len(rule) + 6
    _put(p, L + 10, ty, "To do for Round {} ({})".format(n + 1, len(todo)) if not items else
         "To do for Round {}".format(n + 1), 9.5, "b")
    for ly, label in labels:
        if label:
            _put(p, L + 130, ty + ly, label, 9.5)
    for cx, cy, (cid, sign, colours, target, radius) in chips:
        f.chip(cx, ty + cy, cid, colours, target=target, glyph=sign, radius=radius)
    if not chips:
        _put(p, L + 130, ty, "nothing", 9.5)
    _put(p, L + 10, ty + cy + 15, "Next round: send the full LaTeX source (zip) again.", 9.5)
    f.y = top + box_h + 22

    # key of the statuses in this round, in the order of the summary's groups: each its sign and word, open ones black
    # and closed ones grey
    used = {_status(c, n) for c in revived + reopened + still + new + verified + wontfix}
    x = _put(p, L, f.y, "Key", 8, "b") + 9
    for status in ("reopened", None, "new"):
        if status in used:
            x = _glyph(p, _sign(status), x, f.y, 8, STATUS[status][2])
            x = _put(p, x, f.y, "new comment" if status == "new" else LABELS[status], 8) + 12
    if "wontfix" in used:
        x = _put(p, x, f.y, "– " + LABELS["wontfix"], 8, "r", STATUS["wontfix"][2]) + 12
    if "verified" in used:
        x = _glyph(p, "verified", x, f.y, 8, STATUS["verified"][2])
        x = _put(p, x, f.y, LABELS["verified"], 8, "r", STATUS["verified"][2]) + 12
    if items:  # the check chip, square and slate
        if x + _width(_first(items), 8, "b") + 12 + _width(CHECK_KEY, 8) > R:  # on a line of its own
            f.y += 13
            x = L + _width("Key", 8, "b") + 9
        x = f.chip(x, f.y, _first(items), CHECK_CHIP, radius=None) + 4
        x = _put(p, x, f.y, CHECK_KEY, 8) + 12
    if n > 1:
        if x + 32 + _width("text your change since Round {} old deleted".format(n - 1), 8) > R:  # on a line of its own
            f.y += 13
            x = L + _width("Key", 8, "b") + 9
        p.draw_rect(pymupdf.Rect(x, f.y - 8, x + 1.7, f.y + 1.5), color=None, fill=_rgb(HIST), width=0)
        p.draw_rect(pymupdf.Rect(x + 5, f.y - 7, x + 9 + _width("text", 8), f.y + 1.8), color=None,
                    fill=_rgb(HIST_FILL), width=0)
        x = _put(p, x + 7, f.y, "text", 8) + 6
        x = _put(p, x, f.y, "your change since Round {}".format(n - 1), 8) + 12
        _cross(p, x + 2, f.y - 2.5, HIST)
        x1 = _put(p, x + 7, f.y, "old", 8, "r", HIST_TEXT)
        p.draw_line((x + 7, f.y - 2.4), (x1, f.y - 2.4), color=_rgb(HIST_TEXT), width=0.6)
        x = _put(p, x1 + 4, f.y, "deleted", 8) + 12
    f.y += 13
    _put(p, L, f.y, "In the paper, each comment's mark keeps the colour I chose for it; its status is on its ID chip "
                    "and margin box.", 8, "r", MUTED)
    f.y += 4

    carried = revived + reopened + still + wontfix + verified
    if carried:
        f.section("Earlier comments ({})".format(len(carried)))
        noted = [c for c in verified if c["rounds"][str(n)]["verdict_note"]]  # a row each: the note says something
        plain = [c for c in verified if c not in noted]
        for group, name, total in ((revived, "Reopened", len(revived)), (reopened, "Follow-ups", len(reopened)),
                                   (still, "Still open", len(still)),
                                   (wontfix, "No change needed", len(wontfix)), (noted, "Resolved", len(verified))):
            for k, c in enumerate(group):
                _comment_row(f, clean, paper, lg, c, n, "{} ({})".format(name, total) if k == 0 else None)
            if group:
                f.y += 5
        if plain:
            f.need(20)
            yb, x = f.y + 9, L + 78
            if not noted:
                _put(f.page, L, yb, "Resolved ({})".format(len(verified)), 9, "b", STATUS["verified"][2])
            for c in plain + [None]:  # None: the closing words
                w = _glyph_w("verified", 8) + _width(c["id"], 8, "b") + 14 if c else \
                    _width("Closed. No action needed.", 9) + 12
                if x + w > R:
                    f.y = yb + 6
                    f.need(15)
                    yb, x = f.y + 9, L + 78
                if c:
                    x = f.chip(x, yb, c["id"], STATUS["verified"], target=_target(c, n), glyph="verified") + 6
            _put(f.page, x + 6, yb, "Closed. No action needed.", 9, "r", MUTED)
            f.y = yb + 10
    if new:
        f.section("New comments in this round ({})".format(len(new)))
        for c in new:
            _comment_row(f, clean, paper, lg, c, n)
    if sent:
        _check_section(f, n, sent)
    unrequested = [ch for ch in changes if not ch["attached_to"]]
    if unrequested:
        # what the advisor did with each: checked it, marked its paragraphs read (read), or wrote a comment on it
        # this round (asked about it)
        checked = set(rnd.get("checked", [])) | set(read)
        about = [ch for ch in unrequested if asked.get(ch["id"])]
        read = [ch for ch in unrequested if ch["id"] in checked or asked.get(ch["id"])]
        said = "I have read all of these." if len(read) == len(unrequested) else \
            "I have read {} of them: those marked read{}.".format(len(read), " or asked about" if about else "") \
            if read else ""
        if about:
            ids = sorted({k for ch in about for k in asked[ch["id"]]}, key=ledger.id_key)
            said += " {} {} about {} of them.".format(_names(ids), "asks" if len(ids) == 1 else "ask", len(about))
        f.section("Your changes no comment asked for ({})".format(len(unrequested)))
        for line in _wrap(said.strip(), R - L, 8.5):
            _put(f.page, L, f.y + 2, line, 8.5, "r", MUTED)
            f.y += 12
        for ch in unrequested:
            lines = _wrap(_change_text(ch, 90), R - (L + 126) - 150, 8.5)
            f.need(13.5 * len(lines))
            yb = f.y + 9
            f.chip(L, yb, "your change", (HIST, STATUS["wontfix"][1], HIST_TEXT), 7.5)
            _put(f.page, L + 78, yb, "p.{}".format(ch["page"] + 1) if ch["page"] is not None else "—", 8.5, "b")
            for k, line in enumerate(lines):
                _put(f.page, L + 126, yb + 11 * k, line, 8.5)
            x, ids = R - 140, asked.get(ch["id"], [])
            for k in ids:
                x = f.chip(x, yb, k, STATUS["new"], target=_target(ledger.get_comment(lg, k), n)) + 3
            if ids:
                _put(f.page, x + 1, yb, "asks about this" if len(ids) == 1 else "ask about this", 8, "r", MUTED)
            elif ch["id"] in checked:
                x = _glyph(f.page, "verified", x, yb, 8, STATUS["verified"][2])
                _put(f.page, x, yb, "read", 8, "b", STATUS["verified"][2])
            f.y += 11 * len(lines) + 3.5
    f.section("Build")
    for line in _wrap(_build_line(lg, n, changes), R - L, 8.5):
        f.need(12)
        _put(f.page, L, f.y, line, 8.5)
        f.y += 11
    return f


# --- final.pdf ----------------------------------------------------------------------------------------------

def final_pdf(paper, lg, n, out, sent=None):
    """Summary page(s), then the round's build PDF in the margin style; sent: the check items that go out with the
    round (check_items.outgoing), or None. Returns the margin items placed ([{"page": paper page, "id", "side",
    "rect", "leader": its points, "chip": its rect or None}], for tests)."""
    paper = Path(paper)
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    pdf = str(paper / rnd["build"]["pdf"])
    doc, clean = pymupdf.open(pdf), pymupdf.open(pdf)  # crops for the summary come from the unmarked build
    lay = {k: state._build_layout(paper, rnd["build"], k) for k in ("text_x", "columns")}  # as ingest stored them
    changes = analysis.changes(paper, n)
    changes = [dict(ch, **extra) for ch, extra in zip(changes, state._change_details(paper, lg, n, changes))]

    def order(ch):  # the paper's order: page, the left column before the right, top
        r = ch["rects"][0] if ch["rects"] else [0, 0, 0, 0]
        gap = (lay["columns"][ch["page"]] or [None])[0] if ch["page"] is not None else None
        return ch["page"] is None, ch["page"] or 0, gap is not None and r[0] >= gap - 3, r[1], r[0]
    changes.sort(key=order)
    asked = comments.commenters(lg, n, changes)
    cs = sorted((c for c in lg["comments"] if str(n) in c["rounds"]), key=lambda c: ledger.id_key(c["id"]))
    two = 4 * sum(1 for g in lay["columns"] if g) >= sum(1 for t in lay["text_x"] if t)  # appendix pages of
    # figures and wide tables count as one column, so a quarter of two-column pages makes a two-column paper
    x0s, x1s = sorted(t[0] for t in lay["text_x"] if t), sorted(t[1] for t in lay["text_x"] if t)
    usual = (x0s[len(x0s) // 2], x1s[len(x1s) // 2]) if x0s else None  # where the paper's text usually is: a
    # page of figures has only its page number as text, and its chips and bars go there
    header = _fit("Round {} review, final · {} · {}".format(n, lg["paper"]["title"], datetime.date.today().isoformat()),
                  MARGIN - 18, 7.5)  # each page's margin: from 10 pt into it to 8 pt before its edge
    labels = doc.get_page_labels()
    placed = []
    for pno, page in enumerate(doc):
        gap = lay["columns"][pno][0] if lay["columns"][pno] else None
        own = lay["text_x"][pno]
        tx = (min(own[0], usual[0]), max(own[1], usual[1])) if own and usual else own or usual
        placed += _review_page(page, pno, n, cs, changes, (two, tx, gap), header, asked,
                               sent["items"] if sent else ())
        for link in page.get_links():  # the paper's link boxes (hyperref's green and red) would read as marks
            if link.get("xref"):
                doc.xref_set_key(link["xref"], "Border", "[0 0 0]")

    data, done = prose.load(paper, n), prose.read_map(paper, lg)
    read = {ch["id"] for ch in changes if prose.change_read(ch, prose.change_hashes(data, ch), done, n)}
    # the summary at the paper's own page size (Letter, A4), not the widened one, so it prints at 100%
    f = _summary(doc, clean, paper, lg, n, changes, (clean[0].rect.width, clean[0].rect.height), asked, read, sent)
    offset = f.count
    for spno, r, (pno, y) in f.links:
        doc[spno].insert_link({"kind": pymupdf.LINK_GOTO, "from": r, "page": pno + offset,
                               "to": pymupdf.Point(0, max(0, y - 60)), "zoom": 0})
    _outline(doc, offset, [c for c in cs if _target(c, n)], n,
             [v for v in sent["items"] if _check_target(v)] if sent else ())
    doc.set_page_labels([{"startpage": 0, "prefix": "Summary" + (" " if offset > 1 else ""),
                          "style": "D" if offset > 1 else "", "firstpagenum": 1}]
                        + ([] if any(lb["startpage"] == 0 for lb in labels) else
                           [{"startpage": offset, "prefix": "", "style": "D", "firstpagenum": 1}])
                        + [dict(lb, startpage=lb["startpage"] + offset) for lb in labels])
    # open on the summary (the build's own OpenAction names the paper's first page), and say what the file is
    doc.xref_set_key(doc.pdf_catalog(), "OpenAction", "[{} 0 R /Fit]".format(doc[0].xref))
    doc.set_metadata({"title": "Round {} review: {}".format(n, lg["paper"]["title"]), "author": "",
                      "subject": "", "keywords": "", "creator": "Paperole", "producer": "Paperole",
                      "creationDate": pymupdf.get_pdf_now(), "modDate": pymupdf.get_pdf_now()})
    doc.subset_fonts()  # the CJK font is several MB whole
    tmp = Path(str(out) + ".tmp")
    doc.save(tmp, garbage=3, deflate=True)
    disk.replace(tmp, out)  # synced, then renamed (DATA.md §2.4)
    return placed


def _outline(doc, offset, located, n, checked=()):
    """Summary, the comments by page, the check items that go out by page (checked), then the paper's own outline
    (named destinations resolved to pages). A point
    is given to set_toc as MuPDF's y less the page's MediaBox y0: set_toc writes the height less y, as if the MediaBox
    began at 0, and a page grown by a band (_review_page) begins below it."""
    def at(pno, pt):
        return pymupdf.Point(pt.x, pt.y - doc[pno].mediabox.y0)

    toc = [[1, "Summary", 1, {"kind": pymupdf.LINK_GOTO, "page": 0, "to": pymupdf.Point(0, 0), "zoom": 0}]]
    if located:
        toc.append([1, "Comments ({})".format(len(located)), 1,
                    {"kind": pymupdf.LINK_GOTO, "page": 0, "to": pymupdf.Point(0, 0), "zoom": 0}])
        for c in sorted(located, key=lambda c: (_target(c, n), ledger.id_key(c["id"]))):
            pno, y = _target(c, n)
            toc.append([2, "{} · {} · p.{}".format(c["id"], LABELS[_status(c, n)], pno + 1), pno + offset + 1,
                        {"kind": pymupdf.LINK_GOTO, "page": pno + offset,
                         "to": at(pno + offset, pymupdf.Point(0, max(0, y - 60))), "zoom": 0}])
    if checked:
        toc.append([1, "Automatic checks ({})".format(len(checked)), 1,
                    {"kind": pymupdf.LINK_GOTO, "page": 0, "to": pymupdf.Point(0, 0), "zoom": 0}])
        for v in sorted(checked, key=lambda v: (_check_target(v), ledger.id_key(v["id"]))):
            pno, y = _check_target(v)
            toc.append([2, "{} · {} · p.{}".format(v["id"], CHECK_LABELS[v["state"]], pno + 1), pno + offset + 1,
                        {"kind": pymupdf.LINK_GOTO, "page": pno + offset,
                         "to": at(pno + offset, pymupdf.Point(0, max(0, y - 60))), "zoom": 0}])
    last = 0  # the level of the paper's last item kept: an item without a page (a web link) is dropped, and its
    # children move up to stay in a valid outline (set_toc refuses a level more than one below the item before)
    for level, title, page, dest in doc.get_toc(simple=False):
        if page >= 1:
            last = min(level, last + 1)
            toc.append([last, title, page, {"kind": pymupdf.LINK_GOTO, "page": page - 1,
                                            "to": at(page - 1, dest.get("to", pymupdf.Point(0, 0))), "zoom": 0}])
    doc.set_toc(toc)


# --- The email ----------------------------------------------------------------------------------------------

def _indented(text):
    """The non-blank lines of text, each indented by two spaces (an email entry's lines under its id)."""
    return ["  " + line for line in text.splitlines() if line.strip()]


def _entry(c, n):
    quote = _quote(c, n)
    lines = ["{}  {}".format(c["id"], _where(c, n)) + ('  "{}"'.format(quote) if quote else "")]
    lines += _indented(c["note"])
    if _status(c, n) == "revived":  # where it was closed, then this round's follow-up when written
        rec = c["rounds"][str(n)]
        lines.append("  {}, reopened in Round {}.".format(_closed_in(c, n), n))
        return lines + (_indented("Round {}: {}".format(n, rec["verdict_note"])) if rec["verdict_note"] else [])
    return lines + _indented(_verdict_note(c, n))


def _check_entry(v):
    """A check item in the email: `A2-03  p.12  <text>`, its note indented, the advisor's follow-up ("Me: …")."""
    where = ["p.{}".format(v["places"][0]["page"] + 1)] if v["places"] else []
    lines = ["  ".join([v["id"]] + where + [v["text"]])] + _indented(v["note"] or "")
    return lines + (_indented("Me: " + v["advisor_note"]) if v.get("advisor_note") else [])


def email_text(lg, n, sent=None):
    """The email of round n; sent: the check items that go out with it (check_items.outgoing), or None."""
    revived, reopened, still, new, verified, wontfix = _groups(lg, n)
    items = sent["items"] if sent else []
    out = ["Round {} review: {}".format(n, lg["paper"]["title"]), "", _reply_rule(items)]
    for name, group in (("Reopened", revived), ("Follow-ups", reopened), ("Still open", still),
                        ("New comments", new)):
        if group:
            out += ["", "{} ({})".format(name, len(group))]
            for c in group:
                out += _entry(c, n)
    if items:
        out += ["", "Automatic checks ({})".format(len(items))]
        for v in items:
            out += _check_entry(v)
    closed = ["{} ({})".format(", ".join(ids), label)
              for ids, label in (([c["id"] for c in verified], LABELS["verified"]),
                                 ([c["id"] for c in wontfix] + (sent["ok"] if sent else []), LABELS["wontfix"]),
                                 (sent["fixed"] if sent else [], "fixed")) if ids]
    if closed:
        out += ["", "Closed: " + "; ".join(closed)]
        out += ["  {} ({}): {}".format(c["id"], LABELS[c["rounds"][str(n)]["verdict"]],
                                       " ".join(c["rounds"][str(n)]["verdict_note"].split()))
                for c in verified + wontfix if c["rounds"][str(n)]["verdict_note"].strip()]
    return "\n".join(out) + "\n"
