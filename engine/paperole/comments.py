"""Comments: create from a PDF selection, edit, delete, verdicts and PDF import (CONTRACT.md §4–§6).

Every function works on the ledger dict from ledger.edit() and raises EngineError on a broken rule.
"""
import bisect
import difflib
import functools
import os
import re
import subprocess
import unicodedata
from collections import Counter
from pathlib import Path

import pymupdf

from . import EngineError, annots, ledger, project, texdiff

KINDS = ("highlight", "underline", "strikeout", "note", "box")
OVERALL = "overall"  # a comment on the whole paper: no place, so no anchor in any round (ledger schema 2)


def overall_record(state="new"):
    """A round's record of an overall comment, before its verdict fields: nothing to locate, so never Not found."""
    return {"anchor": None, "anchor_state": state, "confidence": 1.0, "method": OVERALL}
VERDICTS = (None, "verified", "reopened", "wontfix")
# The advisor's mark colours (mac/UX.md §5): name -> (fill, ink). A comment without "color" is yellow. Green is
# kept for changes and "verified", so the second colour is teal; "green" from M2a ledgers reads as teal (LEGACY).
PALETTE = {"yellow": ("#EAB308", "#A16207"), "teal": ("#2DD4BF", "#0F766E"), "blue": ("#60A5FA", "#1D4ED8"),
           "pink": ("#F472B6", "#BE185D"), "purple": ("#A78BFA", "#6D28D9"), "orange": ("#FB923C", "#C2410C")}
LEGACY = {"green": "teal"}
# Environments a box comment anchors to as a whole (DESIGN §5: figures, tables and formulas by environment).
BOX_ENVS = set("figure table wrapfigure wraptable subfigure subtable algorithm equation align gather multline "
               "flalign alignat eqnarray displaymath".split())
CONTEXT = 40  # characters of prefix and suffix
WINDOW = 3  # lines around the synctex lines that the selected words are searched in
CONTEXT_WORDS = 3  # PDF words on each side of a selection compared with the source around each match
MIN_AROUND = 6  # letters around a match that must agree with the PDF to overrule synctex's lines
MIN_SAME = 3  # fewer letters around a match that agree with the PDF are chance (the "a" of "(a)")
MIN_UNIQUE = 6  # letters a selection needs for its only match in the source to be taken without agreeing context
MAX_CELLS = 3000000  # largest fuzzy alignment tried (selection length × window length)
LEVEL = 2.0  # points: lines whose heights differ by less than this are level for a click beside them
MAX_PARAGRAPH = 60  # source lines of a paragraph that a selection is searched in around synctex's lines
RULER_MIN = 5  # digit-only words in one margin column that make it a column of line numbers
RULER_RUN = 10  # numbers counting up by one that make a column of line numbers however short it is

# The de-TeX normaliser keeps only letters and digits. These macros' arguments are not text.
SKIP_ARGS = set("label ref eqref autoref cref Cref pageref vref nameref subref cite citep citet citealp citealt "
                "citeauthor citeyear citeyearpar Citet Citep Citealp Citealt Citeauthor parencite textcite autocite "
                "nocite includegraphics input include vspace hspace bibliographystyle bibliography bibitem "
                "usepackage documentclass setlength addtolength newcommand renewcommand".split())
# What \cite and \ref print, which is not in the source: author-year and numeric citations, and the numbers after
# "Section", "Figure", "§", … A selection is matched without them when it is not found with them.
_YEAR = r"(?:1[6-9]|20)\d\d[a-z]?"
_NAME = r"[A-Z][^\s()\[\];,]*"
CITATION = re.compile(r"\((?=[^()]*[A-Z])[^()]*?" + _YEAR + r"[^()]*\)"  # (Wang et al., 2026; Lee, 2024)
                      r"|" + _NAME + r"(?:\s+et\s+al\.|\s+(?:and|&)\s+" + _NAME + r")?\s*\(" + _YEAR
                      + r"(?:[,;]\s*" + _YEAR + r")*\)"  # Chen and Li (2025)
                      r"|\[\d+(?:\s*[,–—-]\s*\d+)*\]"  # [3, 5]
                      r"|^[^()]*?" + _YEAR + r"\)"  # the end of a citation that a selection starts in
                      r"|\((?=[^()]*(?:et\s+al\.|" + _YEAR + r"))[^()]*$")  # the start of one it ends in
REF_NUMBER = re.compile(r"\b((?:Sections?|Secs?\.|Figures?|Figs?\.|Tables?|Tabs?\.|Equations?|Eqs?\.|Appendix|"
                        r"Appendices|App\.|Algorithms?|Alg\.|Lines?|Chapters?|Theorems?|Lemmas?|Definitions?|"
                        r"Propositions?|Corollar(?:y|ies))\s+)\(?(?:[A-Z](?:\.?\d+(?:\.\d+)*)?|\d+(?:\.\d+)*)\)?"
                        r"(?:\s*\(?[a-z]\))?(?![\w.]*\w)|§\s*\d+(?:\.\d+)*")
CITE_CMD = r"\\(?:[Cc]ite[a-z]*|parencite|textcite|autocite|footcite)\*?(?:\s*\[[^\]]*\])*\s*\{[^{}]*\}"
MATH_ENVS = set("equation align gather multline eqnarray displaymath math flalign alignat".split())
TABULAR = {"tabular", "tabularx", "array", "longtable"}  # their column spec is not text
GREEK = dict(zip("alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa lambda mu nu xi pi "
                 "rho sigma tau upsilon phi varphi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon "
                 "Phi Psi Omega".split(), "αβγδεεζηθθικλμνξπρστυφφχψωΓΔΘΛΞΠΣΥΦΨΩ"))
FUNCS = set("arg det exp inf lim ln log max min sin cos tan sup Pr".split())  # typeset as their names
_MACRO = re.compile(r"\\([A-Za-z@]+)\*?|\\(.)", re.S)
_ENV_NAME = re.compile(r"\s*\{([^{}]*)\}")
_HEADING = re.compile(r"\\(?:chapter|section|subsection|subsubsection)\*?\s*(?:\[[^\]]*\])?\s*\{")


def require_open(lg):
    """The open round, which must have a build PDF."""
    rnd = ledger.open_round(lg)
    if rnd is None:
        raise EngineError("There is no open round. Ingest the student's source first.")
    if not rnd["build"]["pdf"]:
        raise EngineError("Round {} has no PDF because the build failed. Ingest the source again.".format(rnd["n"]))
    return rnd


def _check_kind(kind):
    if kind not in KINDS:
        raise EngineError("Unknown comment kind {!r}; use {}.".format(kind, ", ".join(KINDS)))


def color(c):
    """A comment's mark colour (a palette name)."""
    name = c.get("color", "yellow")
    return LEGACY.get(name, name)


def _check_color(color):
    if color not in PALETTE:
        raise EngineError("Unknown colour {!r}; use {}.".format(color, ", ".join(PALETTE)))


def _place(paper, rnd, page, rects, text, kind):
    """(Anchor, method, confidence) of a selection, click or box on a page of the open round's PDF."""
    _check_kind(kind)
    if not isinstance(page, int) or not 0 <= page < rnd["build"]["pages"]:
        raise EngineError("Page {} is not in the PDF (pages are 0 to {}).".format(page, rnd["build"]["pages"] - 1))
    if not rects or any(len(r) != 4 or r[0] > r[2] or r[1] > r[3] for r in rects):
        raise EngineError("A comment needs rects as [x0, y0, x1, y1] with x0 <= x1 and y0 <= y1.")
    if kind == "box" and len(rects) != 1:
        raise EngineError("A box comment needs exactly one rect.")
    paper = Path(paper)
    src, pdf = paper / "r{}".format(rnd["n"]) / "src", paper / rnd["build"]["pdf"]
    if kind == "box":
        return locate_box(src, pdf, page, rects[0], text or "")
    return locate(src, pdf, page, rects, text or "")


def create(paper, lg, page, rects, text, note, kind, source="app", color="yellow"):
    rnd = require_open(lg)
    n = rnd["n"]
    _check_color(color)
    anchor, method, confidence = _place(paper, rnd, page, rects, text, kind)
    if source == "import" and method == "selection":
        method = "import"
    comment = {"id": ledger.new_id(lg, n), "created_round": n, "created": ledger.now(), "source": source,
               "kind": kind, "color": color, "note": note or "",
               "rounds": {str(n): {"anchor": anchor, "anchor_state": "new", "confidence": confidence,
                                   "method": method, "verdict": None, "verdict_note": "", "verdict_at": None}}}
    lg["comments"].append(comment)
    return comment


def create_overall(lg, note, color="yellow"):
    """A comment on the whole paper (engine/CONTRACT.md amendment "Comments on places, step 1"): one note, no place.
    Its colour is kept for when a later step shows it; it marks nothing on the page."""
    n = require_open(lg)["n"]
    _check_color(color)
    comment = {"id": ledger.new_id(lg, n), "created_round": n, "created": ledger.now(), "source": "app",
               "kind": OVERALL, "color": color, "note": note or "",
               "rounds": {str(n): dict(overall_record(), verdict=None, verdict_note="", verdict_at=None)}}
    lg["comments"].append(comment)
    return comment


PLACE_KEYS = "bcdefghijklmnopqrstuvwxyz"  # a comment's other places; "a" is its own anchor (design/comments/PLAN.md §2)


def places(c, n):
    """[(key, record)] of comment c's places in round n: "a", its own record (with `anchor` None when not found), then
    each other place that has a record in that round, in the order added."""
    rec = c["rounds"].get(str(n))
    if rec is None:
        return []
    extra = rec.get("places") or {}
    return [("a", rec)] + [(p["key"], extra[p["key"]]) for p in (c.get("link") or {}).get("places", ())
                           if p["key"] in extra]


def place_comment(c, key):
    """Comment c seen from one of its other places, as the code that knows one anchor reads a comment: its id
    "R1-03#b", that place's kind, and its records (only the rounds that have the place), each with the round's verdict
    fields."""
    entry = next(p for p in c["link"]["places"] if p["key"] == key)
    rounds = {k: dict({f: r.get(f) for f in ("verdict", "verdict_note", "verdict_at", "revived")}, **r["places"][key])
              for k, r in c["rounds"].items() if key in (r.get("places") or {})}
    for r in rounds.values():  # reopened from a round before the place was added: nothing there to compare with
        if r["revived"] and str(r["revived"]["from"]) not in rounds:
            r["revived"] = None
    # its first round is the one it was added in (a place added to a carried comment has no earlier text)
    return dict(c, id="{}#{}".format(c["id"], key), kind=entry["kind"], rounds=rounds,
                created_round=entry.get("added", c["created_round"]))


def add_place(paper, lg, cid, page, rects, text, kind):
    """Another place of comment cid, of the open round (one written in it or carried into it), from a selection, click
    or box, located as create() locates a comment: its key ("b", "c", …), never reused, and its record in the round.
    The comment keeps one note, number and answer (PLAN.md §2)."""
    c, n = _in_open(lg, cid)
    if c["kind"] == OVERALL:
        raise EngineError("{} is on the whole paper, so it takes no places.".format(cid))
    anchor, method, confidence = _place(paper, require_open(lg), page, rects, text, kind)
    link = c.setdefault("link", {"text": "", "places": []})
    used = {p["key"] for p in link["places"]}
    key = next((k for k in PLACE_KEYS if k not in used), None)
    if key is None:
        raise EngineError("{} has as many places as a comment can have.".format(cid))
    link["places"].append({"key": key, "kind": kind, "added": n})
    c["rounds"][str(n)].setdefault("places", {})[key] = {"anchor": anchor, "anchor_state": "new",
                                                        "confidence": confidence, "method": method}
    return c, key


def remove_place(lg, cid, key):
    """Stop following one of comment cid's other places from the open round on: added in this round, it goes
    altogether; else it is kept in the rounds it was in and marked removed. The last one taken off, the comment has
    one place again (no `link`)."""
    c, n = _in_open(lg, cid)
    entry = next((p for p in (c.get("link") or {}).get("places", ()) if p["key"] == key), None)
    rec = c["rounds"][str(n)]
    if entry is None or key not in (rec.get("places") or {}):
        raise EngineError("{} has no place {} in Round {}.".format(cid, key, n))
    del rec["places"][key]
    if not rec["places"]:
        del rec["places"]
    if entry["added"] == n:
        c["link"]["places"].remove(entry)
    else:
        entry["removed"] = n
    if not any("removed" not in p for p in c["link"]["places"]) and not any(
            "places" in r for r in c["rounds"].values()):
        del c["link"]


def set_relation(lg, cid, text):
    """The advisor's words for how comment cid's places relate (PLAN.md §6a: free text, optional), which the student
    reads at each place. Any comment of the open round that has other places."""
    c, _ = _in_open(lg, cid)
    if not (c.get("link") or {}).get("places"):
        raise EngineError("{} has one place; add another before saying how they relate.".format(cid))
    c["link"]["text"] = " ".join((text or "").split())


def _in_open(lg, cid):
    """(comment, open round number) for a comment that is part of the open round."""
    n = require_open(lg)["n"]
    c = ledger.get_comment(lg, cid)
    if str(n) not in c["rounds"]:
        raise EngineError("{} was closed before round {} and is not part of it.".format(cid, n))
    return c, n


def _own(lg, cid):
    """A comment created in the open round (only those can be edited or deleted)."""
    c, n = _in_open(lg, cid)
    if c["created_round"] != n:
        raise EngineError("{} is from round {}; only comments written in round {} can be edited or deleted. "
                          "Give it a verdict instead.".format(cid, c["created_round"], n))
    return c


def edit(lg, cid, note=None, kind=None, color=None):
    """Change what is not None: the note and kind of a comment written in the open round, the colour of any comment
    of the open round. A box stays a box and a note at a point stays a note: re-anchor to change those."""
    if note is None and kind is None and color is None:
        raise EngineError("Nothing to change: give a note, kind or colour.")
    c = _own(lg, cid) if note is not None or kind is not None else _in_open(lg, cid)[0]
    if kind is not None and OVERALL in (kind, c["kind"]):
        if kind != c["kind"]:
            raise EngineError("{} is {}; a comment on the whole paper and one on a place cannot be changed into "
                              "each other.".format(cid, "on the whole paper" if c["kind"] == OVERALL else "on a place"))
        kind = None
    if kind is not None:
        _check_kind(kind)
        rects = c["rounds"][str(c["created_round"])]["anchor"]["rects"]
        if kind != c["kind"] and ("box" in (kind, c["kind"])
                                  or (c["kind"] == "note" and all(r[0] == r[2] and r[1] == r[3] for r in rects))):
            raise EngineError("{} is a {}; re-anchor it to change its kind.".format(
                cid, "note at a point" if c["kind"] == "note" else c["kind"]))
    if color is not None:
        _check_color(color)
    for key, value in (("note", note), ("kind", kind), ("color", color)):
        if value is not None:
            c[key] = value


def reanchor(paper, lg, cid, page, rects, text, kind=None, key=None):
    """Place a comment of the open round anew from a selection, click or box (DESIGN §5: a position the advisor set
    comes first). A comment written in this round gets a new creation anchor, located as create() does. A carried
    one gets this round's anchor replaced, with method "advisor" and confidence 1.0; later rounds carry from it.
    Placed on the same source range as before (a box redrawn around the same table), it keeps its state; else its
    state is "moved" when the PDF text is the last earlier round's, else "changed" (api.reanchor then makes it
    "changed" when a change of the round is in its new sentence). Without a kind, a box comment placed on text
    becomes a highlight and any other comment keeps its kind. key: one of its other places ("b", …), placed anew the
    same way: one added in this round as when added, one carried as a carried comment. Returns (comment, whether the
    source range changed)."""
    c, n = _in_open(lg, cid)
    if c["kind"] == OVERALL:
        raise EngineError("{} is on the whole paper, so it has no place to move.".format(cid))
    if key is None:
        view, rec = c, c["rounds"][str(n)]
    else:
        if key not in (c["rounds"][str(n)].get("places") or {}):
            raise EngineError("{} has no place {} in Round {}.".format(cid, key, n))
        view, rec = place_comment(c, key), c["rounds"][str(n)]["places"][key]
    kind = kind or ("highlight" if view["kind"] == "box" else view["kind"])
    anchor, method, confidence = _place(paper, require_open(lg), page, rects, text, kind)
    old = rec["anchor"]
    placed = not (old and rec["anchor_state"] not in ("orphan", "gone")
                  and (old["file"], old["start"], old["end"]) == (anchor["file"], anchor["start"], anchor["end"]))
    first = c["created_round"] if key is None else \
        next(p["added"] for p in c["link"]["places"] if p["key"] == key)
    if first != n:
        before = next((r["anchor"]["text"] for k, r in sorted(view["rounds"].items(), key=lambda kr: -int(kr[0]))
                       if int(k) < n and r["anchor"] and r["anchor"]["text"]), "")
        method, confidence = "advisor", 1.0
        if placed:
            rec["anchor_state"] = "moved" if before and _fold(before) == _fold(anchor["text"]) else "changed"
    rec.update(anchor=anchor, method=method, confidence=confidence)
    if key is None:
        c["kind"] = kind
    else:
        next(p for p in c["link"]["places"] if p["key"] == key)["kind"] = kind
    return c, placed


def delete(lg, cid):
    lg["comments"].remove(_own(lg, cid))


def set_verdict(lg, cid, verdict, note=""):
    n = require_open(lg)["n"]
    if verdict not in VERDICTS:
        raise EngineError("Unknown verdict {!r}; use verified, reopened, wontfix or null.".format(verdict))
    c = ledger.get_comment(lg, cid)
    if c["created_round"] == n:
        raise EngineError("{} was written in round {}. Verdicts are given to comments from earlier rounds."
                          .format(cid, n))
    rec = c["rounds"].get(str(n))
    if rec is None:
        raise EngineError("{} was closed before round {} and is not part of it.".format(cid, n))
    rec.update(verdict=verdict, verdict_note=(note or "") if verdict else "",
               verdict_at=ledger.now() if verdict else None)


def last_record(c):
    """(round, record) of a comment's latest round."""
    k = max(c["rounds"], key=int)
    return int(k), c["rounds"][k]


def _why_not_revivable(lg, cid, c=None):
    """The advisor's reason why comment cid (c: the comment, when at hand) cannot be reopened (the advisor's Reopen;
    `revive` in the engine, since the verdict `reopened` is Follow up), or None when it can: the latest round is open
    with a PDF, the comment has no record in it, and its last record closed it. An unknown cid raises EngineError
    once the round would allow a Reopen."""
    rnd = ledger.latest_round(lg)
    if rnd is None:
        return "There is no round yet. Ingest the student's source first."
    n = rnd["n"]
    if rnd["closed"]:
        return "Round {} is closed: import the next draft first.".format(n)
    if not rnd["build"]["pdf"]:
        return "Round {} has no PDF (the build failed): there is nothing to place {} on.".format(n, cid)
    c = c or ledger.get_comment(lg, cid)
    if c["created_round"] == n:
        return "{} was written in Round {}.".format(cid, n)
    rec = c["rounds"].get(str(n))
    if rec is not None:
        return "{} is already in Round {}.".format(cid, n) if rec.get("revived") else \
            "{} is still open; it is in Round {} already.".format(cid, n)
    if last_record(c)[1]["verdict"] not in ("verified", "wontfix"):
        return "{} is not closed.".format(cid)
    return None


def revivable(lg, c):
    """Whether comment c can be reopened (_why_not_revivable)."""
    return _why_not_revivable(lg, c["id"], c) is None


def require_revivable(lg, cid):
    """(comment, open round) for a comment closed in an earlier round that may come back into the open round, or the
    advisor's reason why not (_why_not_revivable)."""
    why = _why_not_revivable(lg, cid)
    if why is not None:
        raise EngineError(why)
    return ledger.get_comment(lg, cid), ledger.latest_round(lg)


def commenters(lg, n, changes):
    """{change id: sorted ids of the comments written in round n whose marks overlap the change on its page}: a new
    comment on an edit no comment asked for asks about it (amendment "Fix round M2b")."""
    def grown(r):
        d = 4.0 if r[2] - r[0] < 1 or r[3] - r[1] < 1 else 1.0  # a point: a note, a deletion
        return r[0] - d, r[1] - d, r[2] + d, r[3] + d

    def meet(a, b):
        a, b = grown(a), grown(b)
        return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]
    fresh = [(c["id"], c["rounds"][str(n)]["anchor"]) for c in lg["comments"] if c["created_round"] == n]
    out = {}
    for ch in changes:
        ids = [cid for cid, a in fresh if a and ch["page"] is not None and a["page"] == ch["page"]
               and any(meet(r, q) for r in a["rects"] for q in ch["rects"])]
        if ids:
            out[ch["id"]] = sorted(ids, key=ledger.id_key)
    return out


def import_pdf(paper, lg, pdf):
    """Create comments from an annotated copy of this round's build PDF."""
    rnd = require_open(lg)
    n = rnd["n"]
    build_pdf = Path(paper) / rnd["build"]["pdf"]
    try:
        doc = pymupdf.open(pdf)
    except Exception:
        raise EngineError("{} cannot be opened as a PDF.".format(pdf))
    build = pymupdf.open(build_pdf)
    wrong = "This PDF is not round {}'s build PDF: ".format(n)
    if doc.page_count != build.page_count:
        raise EngineError(wrong + "it has {} pages, the build has {}.".format(doc.page_count, build.page_count))
    for i in range(doc.page_count):
        a, b = doc[i].rect, build[i].rect
        if abs(a.width - b.width) > 1 or abs(a.height - b.height) > 1:
            raise EngineError(wrong + "page {} has a different size.".format(i + 1))
    for i, (a, b) in enumerate(zip(_page_words(pdf), _page_words(build_pdf))):
        if a != b and difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() < 0.9:
            raise EngineError(wrong + "the text of page {} differs.".format(i + 1))

    ids, skipped = [], []
    for a in annots.extract(pdf)["comments"]:
        page = a["page"] - 1
        height = doc[page].rect.height
        boxes = [(min(q[0::2]), min(q[1::2]), max(q[0::2]), max(q[1::2])) for q in a["quads"]] or [a["rect"]]
        rects = [[round(x0, 2), round(height - y1, 2), round(x1, 2), round(height - y0, 2)]
                 for x0, y0, x1, y1 in boxes]
        kind = {"highlight": "highlight", "underline": "underline", "squiggly": "underline",
                "strikeout": "strikeout"}.get(a["kind"]) or ("box" if a["annot_type"] in ("Square", "Circle") else "note")
        dup = next((c for c in lg["comments"] if c["created_round"] == n and _same(c, n, page, kind, a["note"], rects)),
                   None)
        if dup:
            skipped.append({"page": page, "kind": kind, "note": a["note"], "reason": "duplicate of " + dup["id"]})
            continue
        ids.append(create(paper, lg, page, rects, a["quote"], a["note"], kind, source="import",
                          color=nearest_color(a["color"]))["id"])
    return {"ids": ids, "skipped": skipped}


def nearest_color(rgb):
    """The palette colour whose fill or ink is nearest to an RGB colour (components 0–1); yellow without one."""
    if len(rgb) != 3:
        return "yellow"

    def dist(hex_colour):
        return sum((int(hex_colour[i:i + 2], 16) / 255 - v) ** 2 for i, v in zip((1, 3, 5), rgb))
    return min(PALETTE, key=lambda name: min(dist(h) for h in PALETTE[name]))


def _same(c, n, page, kind, note, rects):
    anchor = c["rounds"][str(n)]["anchor"]
    return (c["kind"] == kind and c["note"] == note and anchor["page"] == page
            and len(anchor["rects"]) == len(rects)
            and all(abs(u - v) <= 1 for r, s in zip(anchor["rects"], rects) for u, v in zip(r, s)))


def _page_words(path):
    """Each page's words, ignoring annotations (MuPDF's page text includes FreeText boxes)."""
    doc = pymupdf.open(path)
    for i in range(doc.page_count):
        doc.xref_set_key(doc.page_xref(i), "Annots", "null")
    return [[w[4] for w in page.get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP)] for page in doc]


# --- From a PDF selection to the LaTeX source ------------------------------------------------------------

def locate(src, pdf, page, rects, text):
    """(Anchor, method, confidence) for the PDF words whose centres lie in rects.

    synctex gives the file and lines at each rect's centre; the words are then searched for in the
    de-TeXed source within WINDOW lines ("selection", 1.0). Otherwise the anchor is the synctex lines
    ("line", 0.5), or the whole formula when they are in display math ("selection", 1.0). Without words (a
    note at a point) it is the nearest line, flagged position_guessed. Line numbers in the margin are not words.
    Words drawn in an included picture (synctex names only its \\includegraphics line) anchor to that
    \\includegraphics ("selection", 1.0) when they are not found, or are found on other lines (a caption with the
    same words).
    A spot in BibTeX's reference list is in the .bbl that TeX read (from src, or the build folder beside the
    PDF, named as if in src); without that file it anchors to the \\bibliography line, as a guess."""
    src = Path(src)
    words = body_words(pymupdf.open(pdf)[page].get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP), ruler_edges(pdf))
    at = [k for k, w in enumerate(words) if any(r[0] <= (w[0] + w[2]) / 2 <= r[2] and r[1] <= (w[1] + w[3]) / 2 <= r[3]
                                                for r in rects)]
    picked = [words[k] for k in at]
    # the PDF words around the selection pick the right one of several equal matches (a word used twice nearby)
    around = (_fold(printed(" ".join(w[4] for w in words[max(at[0] - CONTEXT_WORDS, 0):at[0]]))[0]),
              _fold(printed(" ".join(w[4] for w in words[at[-1] + 1:at[-1] + 1 + CONTEXT_WORDS]))[0])) \
        if at else ("", "")
    if picked:
        points = [((r[0] + r[2]) / 2, (r[1] + r[3]) / 2) for r in rects]
    else:  # a click: synctex at the centre of the nearest word of the nearest line, not its first word (at a line's
        # edge, and at the first word of the lines of a file's last paragraph, synctex names another file or line)
        x, y = (rects[0][0] + rects[0][2]) / 2, (rects[0][1] + rects[0][3]) / 2
        body = without_page_number(words)
        line = _nearest_line(body, x, y)
        if line:
            on = sorted((w for w in body if line[0] <= (w[0] + w[2]) / 2 <= line[2]
                         and line[1] <= (w[1] + w[3]) / 2 <= line[3]), key=lambda w: w[0])
            w = nearest(on[1:] or on, x, y)
            x, y = ((w[0] + w[2]) / 2, (w[1] + w[3]) / 2) if w else (min(max(x, line[0]), line[2]), (line[1] + line[3]) / 2)
        points = [(x, y)]
    hits = [h for h in (_synctex(pdf, page, x, y, src) for x, y in points) if h]
    bib = any(f is None and name.endswith(".bbl") for f, name in hits)  # the reference list BibTeX generated
    hits = [h for h in hits if h[0] is not None]

    found = picture = None
    if hits:
        file = Counter(f for f, _ in hits).most_common(1)[0][0]
        lines = [l for f, l in hits if f == file]
        tex = _read(source_path(src, pdf, file))
        picture = _picture(file, tex, lines) if picked else None  # synctex names an \includegraphics: in a picture
        # synctex often names a paragraph's last line for all of its lines (two-column layouts): search the paragraph
        p0, p1 = (_line_of(tex, x) for x in texdiff.paragraph(tex, *_line_span(tex, min(lines), max(lines))))
        wide = (min(p0, min(lines)), max(p1, max(lines))) if p1 - p0 <= MAX_PARAGRAPH else None
        # an exact match near synctex's lines first, then in the paragraph, then fuzzy ones
        steps = [(False, None), (False, wide), (True, None), (True, wide)] if wide else [(False, None), (True, None)]
        for fuzzy, span in steps if picked else ():
            found = _find(tex, picked, min(lines), max(lines), around=around, fuzzy=fuzzy, wide=span)
            if found:
                break
    if picked and (hits or not bib) and (found is None or (found[2] < MIN_AROUND and any(around))):
        # synctex names no file in src, or the words are not near its lines, or little around the match agrees
        # with the PDF (synctex can be off near math, and \maketitle prints the title far from \title): look in
        # every .tex file, and with synctex lines take only a match whose surroundings agree better
        raw = " ".join(w[4] for w in picked)
        targets = [x for x in dict.fromkeys((_fold(raw), _fold(printed(raw)[0]))) if len(x) >= MIN_UNIQUE]
        counts, only = [0] * len(targets), {}  # exact matches of the selection's letters (or without what \cite
        # and \ref print) in all files, and the match _find gives in a file that has one
        for path in sorted(src.rglob("*.tex")):
            t = _read(path)
            f = _find(t, picked, 1, t.count("\n") + 1, window=0, around=around, fuzzy=not hits)
            if f and (not hits or f[2] >= MIN_AROUND) and (found is None or f[2] > found[2]):
                found, file, tex = f, path.relative_to(src).as_posix(), t
            letters = "".join(_units(t)[0])
            for i, target in enumerate(targets):
                k = letters.count(target)
                counts[i] += k
                if k and f:
                    only[i] = f, path.relative_to(src).as_posix(), t
        first = next((i for i, k in enumerate(counts) if k), None)
        if found is None and first is not None and counts[first] == 1 and first in only:
            # the only place in the source with these letters, though the words around it are not the PDF's:
            # \maketitle prints authors, affiliations and keywords in an order and with headings of its own
            found, file, tex = only[first]
    if not hits and not found:
        ref = _bibliography(src) if bib else None
        if ref is None:
            raise EngineError("No LaTeX source was found for this spot on page {}.".format(page + 1))
        file, tex, line = ref  # a comment on a reference: the \bibliography line, as a guess
        lines = [line, line]
    if found:
        (start, end, _), method, confidence = found, "selection", 1.0
    else:
        l0, l1 = min(lines), max(lines)
        if not _blank_comments(tex)[slice(*_line_span(tex, l0, l1))].strip():
            l0 = l1 = _text_line(tex, l0)  # synctex named a blank line (where a paragraph ended): the nearest text
        (start, end), method, confidence = _line_span(tex, l0, l1), "line", 0.5
        display = next(((s, e) for s, e in _units(tex)[2] if s <= start and end <= e), None)
        if display and picked:  # symbols selected in display math: the whole formula (DESIGN §5)
            (start, end), method, confidence = display, "selection", 1.0
    if hits and picture and (method == "line" or file != picture[0]
                             or not _line_of(tex, start) <= _line_of(tex, picture[2][0]) <= _line_of(tex, end)):
        # words drawn in a picture: not in the source, or matched elsewhere (a caption with the same words)
        file, tex, method, confidence = picture[0], picture[1], "selection", 1.0
        start, end = picture[2]
    section, env = _structure(tex, start, end)
    return ({"file": file, "start": start, "end": end,
             "lines": [_line_of(tex, start), _line_of(tex, max(start, end - 1))], "quote": tex[start:end],
             "prefix": tex[max(0, start - CONTEXT):start], "suffix": tex[end:end + CONTEXT],
             "page": page, "rects": [[round(v, 2) for v in r] for r in rects],
             "text": join_words(picked) or text,
             "section": section, "env": env, "position_guessed": not picked or not (hits or found)},
            method, confidence)


GRAPHICS_CMD = re.compile(r"\\includegraphics\*?\s*(?:\[[^\]]*\])?\s*\{[^{}]*\}")


def _picture(file, tex, lines):
    """(file, tex, (start, end)) of the one \\includegraphics on synctex's lines (all its lines hold that one), or
    None. synctex names that line for any point inside an included picture."""
    blank, spans = _blank_comments(tex), set()
    for line in set(lines):
        found = [m.span() for m in GRAPHICS_CMD.finditer(blank, *_line_span(tex, line, line))]
        if len(found) != 1:
            return None
        spans.add(found[0])
    return (file, tex, spans.pop()) if len(spans) == 1 else None


def locate_box(src, pdf, page, box, text):
    """(Anchor, method, confidence) for a box drawn on a page. At the box's centre synctex names a line; the innermost
    figure, table, display-math or algorithm environment holding it is the anchor, as a whole ("selection", 1.0).
    Otherwise the box is located as a selection by locate(): the words inside it, else the nearest line ("line",
    0.5, position_guessed). The rect is the box. The anchor also has "label" (the environment's \\label or null)
    and "ref": the box around the words of the environment's caption (or of the range) on the page, which later
    rounds move the box with (anchor.box_place). Its text is those words, or the app's text when there are none."""
    from . import anchor as placing  # anchor imports this module
    src = Path(src)
    hit = _synctex(pdf, page, (box[0] + box[2]) / 2, (box[1] + box[3]) / 2, src)
    span = None
    if hit and hit[0] is not None:
        file, tex = hit[0], _read(source_path(src, pdf, hit[0]))
        at = _line_span(tex, hit[1], hit[1])[0]
        span = box_env(tex, at, at)
    if span:
        start, end = span
        section, env = _structure(tex, start, end)
        a, method, confidence = {
            "file": file, "start": start, "end": end, "lines": [_line_of(tex, start), _line_of(tex, end - 1)],
            "quote": tex[start:end], "prefix": tex[max(0, start - CONTEXT):start], "suffix": tex[end:end + CONTEXT],
            "page": page, "rects": [[round(v, 2) for v in box]], "text": text, "section": section, "env": env,
            "position_guessed": False, "label": env_label(tex, start, end)}, "selection", 1.0
    else:
        a, method, confidence = locate(src, pdf, page, [box], text)
        a["label"] = None
    rpage, _, rtext, ref = placing.box_place(src, pdf, a["file"], a["start"], a["end"])
    a["ref"] = ref if rpage == page else None
    if span:
        a["text"] = rtext or text
    return a, method, confidence


@functools.lru_cache(maxsize=16)
def envs(tex):
    """(start, end, name) of every environment of LaTeX source, from its \\begin to the end of its \\end."""
    out, stack = [], []
    for m in re.finditer(r"\\(begin|end)\s*\{([^{}]*)\}", _blank_comments(tex)):
        name = m.group(2).strip()
        if m.group(1) == "begin":
            stack.append((m.start(), name))
        elif stack and stack[-1][1] == name:
            out.append((stack.pop()[0], m.end(), name))
    return out


def box_env(tex, start, end):
    """(start, end) of the innermost figure, table, display-math or algorithm environment (or \\[…\\] or $$…$$
    display) that holds [start, end), or None."""
    spans = [(s, e) for s, e, name in envs(tex) if name.rstrip("*") in BOX_ENVS and s <= start and end <= e]
    spans += [(s, e) for s, e in _units(tex)[2] if tex.startswith(("\\[", "$$"), s) and s <= start and end <= e]
    return max(spans, key=lambda se: (se[0], -se[1]), default=None)


def _own_matches(pattern, tex, start, end):
    """The matches of pattern in tex[start:end] (comments blanked) that are not inside an environment nested in it
    that a box anchors to (a subfigure's \\caption is not its figure's)."""
    nested = [(s, e) for s, e, name in envs(tex) if name.rstrip("*") in BOX_ENVS and start < s and e <= end]
    return [m for m in re.compile(pattern).finditer(_blank_comments(tex), start, end)
            if not any(s <= m.start() < e for s, e in nested)]


def caption_span(tex, start, end):
    """(start, end) of the argument of the last \\caption of the environment at [start, end), or None."""
    found = _own_matches(r"\\caption\*?\s*(?:\[[^\]]*\])?\s*\{", tex, start, end)
    return (found[-1].end(), _skip_args(tex, found[-1].end() - 1, "{") - 1) if found else None


def env_label(tex, start, end):
    """The last \\label of the environment at [start, end), or None."""
    found = _own_matches(r"\\label\s*\{([^{}]*)\}", tex, start, end)
    return found[-1].group(1).strip() if found else None


def _read(path):
    return Path(path).read_text(encoding="utf-8", errors="replace")


def source_path(src, pdf, file):
    """The path of a source file: src/file, or for a .bbl that is not in src, the one BibTeX wrote beside the PDF
    (TeX reads a .bbl from its working folder first, then from the output folder)."""
    path = Path(src) / file
    if file.endswith(".bbl") and not path.is_file():
        return Path(pdf).parent / file
    return path


def _text_line(tex, line):
    """The nearest line at or above `line` with text outside comments, else the nearest one below it."""
    rows = _blank_comments(tex).split("\n")
    for k in list(range(min(line, len(rows)), 0, -1)) + list(range(line + 1, len(rows) + 1)):
        if rows[k - 1].strip():
            return k
    return line


def _bibliography(src):
    """(file, text, line) of the first \\bibliography{…} or \\printbibliography in src's .tex files, or None."""
    for path in sorted(Path(src).rglob("*.tex")):
        tex = _read(path)
        m = re.search(r"\\bibliography\s*\{|\\printbibliography\b", _blank_comments(tex))
        if m:
            return path.relative_to(src).as_posix(), tex, _line_of(tex, m.start())
    return None


def _synctex(pdf, page, x, y, src):
    """(file relative to src, spelled as on disk (texdiff.spellings), line) at a point of the PDF; for the .bbl BibTeX
    wrote beside the PDF, its name; (None, input name) for another file outside src; or None."""
    try:
        out = subprocess.run(["synctex", "edit", "-o", "{}:{:.2f}:{:.2f}:{}".format(page + 1, x, y, pdf)],
                             env=project.tex_env(), capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    name, line = re.search(r"^Input:(.*)$", out, re.M), re.search(r"^Line:(-?\d+)", out, re.M)
    if not name or not line:
        return None
    path = name.group(1)
    rel = path.split("/./", 1)[1] if "/./" in path else os.path.relpath(path, src)
    rel = texdiff.spellings(src).get(texdiff.name_key(rel), rel)  # synctex keeps the \input's spelling
    if rel.startswith("..") or not (src / rel).is_file():
        bbl = Path(path)
        if bbl.suffix != ".bbl" or bbl.parent.resolve() != Path(pdf).parent.resolve() or not bbl.is_file() \
                or (src / bbl.name).is_file():
            return None, path
        rel = bbl.name
    n = int(line.group(1))
    if n > _read(source_path(src, pdf, rel)).count("\n") + 1:
        return None  # a line past the end of the file: synctex mixed up its inputs
    return rel, max(n, 1)


def margin_numbers(words, edges=()):
    """Indexes of the words that are line numbers in a page margin (lineno, or the ruler of a review-mode paper):
    at least RULER_MIN digit-only words sharing a left or right edge, running down at least half the height of the
    page's words or, at least RULER_RUN of them, counting up by one from top to bottom (ACL numbers only the text
    lines of a column, so a page with floats has a short ruler), and all left of every other word on the page or all
    right of them. With `edges` (ruler_edges: the rulers found on the PDF's pages), digit-only words within 1 pt of
    such an edge count too, however few (a page of figures with one numbered line), when they are outside the
    page's other words in the same way."""
    return _rulers(words, edges)[0]


def _rulers(words, edges=()):
    """(margin_numbers, {(edge, x)}: the shared edge of each ruler found by count; edge 2 is the right edge of the
    numbers, 0 the left)."""
    digits = [i for i, w in enumerate(words) if w[4].isdecimal()]  # int() reads these (not "²")
    height = max((w[3] for w in words), default=0) - min((w[1] for w in words), default=0)
    out, found = set(), set()

    def outside(col):
        x0, x1 = min(words[i][0] for i in col), max(words[i][2] for i in col)
        rest = [w for k, w in enumerate(words) if k not in col and k not in out]
        return all(w[0] > x1 for w in rest) or all(w[2] < x0 for w in rest)

    for edge in (2, 0):
        columns = {}
        for i in digits:
            columns.setdefault(round(words[i][edge]), set()).add(i)
        for col in columns.values():
            if len(col) < RULER_MIN or col <= out:
                continue
            nums = [int(words[i][4]) for i in sorted(col, key=lambda i: words[i][1])]
            if 2 * (max(words[i][3] for i in col) - min(words[i][1] for i in col)) < height \
                    and (len(nums) < RULER_RUN or any(b != a + 1 for a, b in zip(nums, nums[1:]))):
                continue
            if outside(col):
                out |= col
                found.add((edge, round(sum(words[i][edge] for i in col) / len(col), 1)))
    for edge, x in edges:
        col = {i for i in digits if abs(words[i][edge] - x) <= 1.0} - out
        if col and outside(col):
            out |= col
    return out, found


@functools.lru_cache(maxsize=8)
def _ruler_edges(stamp):
    with pymupdf.open(stamp[0]) as doc:
        return frozenset(e for page in doc for e in _rulers(page.get_text("words"))[1])


def ruler_edges(pdf):
    """The (edge, x) of the margin rulers found on any page of a PDF (cached by its path and modification stamp)."""
    st = os.stat(pdf)
    return _ruler_edges((str(pdf), st.st_mtime_ns, st.st_size))


def body_words(words, edges=()):
    """The words without margin line numbers (`edges`: the PDF's ruler_edges)."""
    ruler = margin_numbers(words, edges)
    return [w for k, w in enumerate(words) if k not in ruler] if ruler else list(words)


def text_x(pdf):
    """For each page of the PDF, [x0, x1]: the horizontal extent of its words other than margin line numbers (so
    running heads and page numbers count), or None when the page has none. The app keeps drag points inside it."""
    return layout(pdf)["text_x"]


def columns(pdf):
    """For each page of the PDF, [x of the gap between its two text columns, half the page's height], or None when
    its text is not set in two columns. Comments are listed column by column (state)."""
    return layout(pdf)["columns"]


def layout(pdf):
    """{"text_x": text_x, "columns": columns, "rulers": rulers} of a PDF, in one pass over its pages. A page is set in
    two columns when at least 5 lines at least 30% as wide as its text lie wholly left of the middle of its text, and
    5 wholly right, and such lines on one side outnumber those across the middle. rulers: for each page with a
    text_x, [left, right], the bounds [x0, y0, x1, y1] of its margin line numbers left of text_x and right of it (a
    review ruler), each None when that side has none; None for a page without text_x. The app places id labels
    clear of them without reading the page's text."""
    with pymupdf.open(pdf) as doc:
        pages = [(page.get_text("words"), page.rect.height) for page in doc]
    edges = frozenset(e for words, _ in pages for e in _rulers(words)[1])
    out = {"text_x": [], "columns": [], "rulers": []}
    for words, height in pages:
        ruler = margin_numbers(words, edges)
        nums, words = [w for k, w in enumerate(words) if k in ruler], [w for k, w in enumerate(words) if k not in ruler]
        x0 = min((w[0] for w in words), default=None)
        out["text_x"].append([round(x0, 2), round(max(w[2] for w in words), 2)] if words else None)
        # margin numbers lie wholly left or wholly right of every other word (_rulers)
        out["rulers"].append([_bounds([w for w in nums if w[0] < x0]), _bounds([w for w in nums if w[0] >= x0])]
                             if words else None)
        lines = {}
        for w in words:
            b = lines.get(w[5:7], w[:4])
            lines[w[5:7]] = (min(b[0], w[0]), min(b[1], w[1]), max(b[2], w[2]), max(b[3], w[3]))
        x0, x1 = min((b[0] for b in lines.values()), default=0), max((b[2] for b in lines.values()), default=0)
        mid, wide = (x0 + x1) / 2, [b for b in lines.values() if b[2] - b[0] >= 0.3 * (x1 - x0)]
        left, right = [b for b in wide if b[2] < mid], [b for b in wide if b[0] > mid]
        two = len(left) >= 5 and len(right) >= 5 and len(left) + len(right) > len(wide) - len(left) - len(right)
        out["columns"].append([round((max(b[2] for b in left) + min(b[0] for b in right)) / 2, 2), round(height / 2, 2)]
                              if two else None)
    return out


def _bounds(words):
    """The bounds [x0, y0, x1, y1] of the words (rounded to 0.01), or None without words."""
    return [round(f(w[k] for w in words), 2) for k, f in ((0, min), (1, min), (2, max), (3, max))] if words else None


def join_words(words):
    """The words' text joined by spaces. A word that ends a line with a hyphen after a letter is joined to the next
    line's first word, when that starts in lower case, without the hyphen (TeX's hyphenation: "evalu-" "ation")."""
    return join_spans(words)[0]


def join_spans(words, source=""):
    """(join_words(words), [[start, end] of each word in it]); a joined hyphenated word is two adjacent spans. The
    hyphen is kept when source has the two parts with it ("preference-" "aligned"), and then the next line's word
    may start in upper case too ("GPT-5.6-" "Luna")."""
    out, spans = "", []
    for k, w in enumerate(words):
        prev = words[k - 1] if k else None
        if prev and out[-2:-1].isalnum() and out.endswith("-") and prev[5:7] != w[5:7] \
                and (w[4][:1].islower() and out[-2:-1].isalpha() or (prev[4] + w[4]) in source):
            if (prev[4] + w[4]) not in source:
                out = out[:-1]
                spans[-1][1] = len(out)
        elif k:
            out += " "
        spans.append([len(out), len(out) + len(w[4])])
        out += w[4]
    return out, spans


def _nearest_line(words, x, y):
    """The bounding box of the line of words nearest to height y (of those, the nearest to x), or None."""
    boxes = {}
    for x0, y0, x1, y1, _, block, line, _ in words:
        b = boxes.get((block, line), (x0, y0, x1, y1))
        boxes[(block, line)] = (min(b[0], x0), min(b[1], y0), max(b[2], x1), max(b[3], y1))
    return nearest(list(boxes.values()), x, y)


def without_page_number(words):
    """The words without a page number: a line that holds only a number (arabic or roman) and is the page's lowest or
    highest line. A click on an empty page is not a note on its page number."""
    lines = {}
    for k, w in enumerate(words):
        lines.setdefault(w[5:7], []).append(k)
    if not lines:
        return list(words)
    drop = {ks[0] for ks in (max(lines.values(), key=lambda ks: max(words[k][3] for k in ks)),
                             min(lines.values(), key=lambda ks: min(words[k][1] for k in ks)))
            if len(ks) == 1 and re.fullmatch(r"\d{1,4}|[ivxlcdm]{1,7}", words[ks[0]][4], re.I)}
    return [w for k, w in enumerate(words) if k not in drop]


def nearest(boxes, x, y):
    """The box nearest to the point (x, y) by height, then by horizontal distance; boxes within LEVEL points of the
    nearest height are level (the lines of two columns are rarely at exactly the same height). None without boxes."""
    def dy(b):
        return max(b[1] - y, y - b[3], 0)
    low = min(map(dy, boxes), default=None)
    return min((b for b in boxes if dy(b) <= low + LEVEL), key=lambda b: (max(b[0] - x, x - b[2], 0), dy(b)),
               default=None)


def _fold(s):
    """Letters and digits only, compatibility-decomposed (ligatures, accents) and case-folded."""
    return "".join(ch for ch in unicodedata.normalize("NFKD", s).casefold() if ch.isalnum())


def _skip_args(text, j, opens):
    """Index after the [..] / {..} groups (whichever of `opens`) that start at j."""
    while j < len(text) and text[j] in opens:
        close, depth = ("]" if text[j] == "[" else "}"), 0
        while j < len(text):
            ch = text[j]
            if ch == "\\":
                j += 2
                continue
            j += 1
            depth += (ch == "{") - (ch == "}")
            if depth == 0 and ch == close:
                break
    return j


@functools.lru_cache(maxsize=16)
def _units(text):
    """The de-TeXed letters and digits of LaTeX source, each with its source span, and the math spans.

    Comments, macro names, braces and non-text arguments are dropped. Math keeps its letters, and a
    math span ($…$, \\[…\\], an equation environment) is one unit when an anchor's range is mapped back."""
    chars, spans, maths = [], [], []
    math = None  # (start, closer) of the open math span

    def emit(s, a, b):
        for ch in _fold(s):
            chars.append(ch)
            spans.append((a, b))

    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "%":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "$":
            closer = "$$" if text.startswith("$$", i) else "$"
            if math is None:
                math = (i, closer)
            elif math[1] == closer:
                maths.append((math[0], i + len(closer)))
                math = None
            i += len(closer)
            continue
        m = _MACRO.match(text, i) if c == "\\" else None
        if not m:
            emit(c, i, i + 1)
            i += 1
            continue
        name, j = m.group(1), m.end()
        if name is None:  # a control symbol: \( \[ \) \] \\ \% …
            sym = m.group(2)
            if sym in "([" and math is None:
                math = (i, ")" if sym == "(" else "]")
            elif math and sym == math[1]:
                maths.append((math[0], j))
                math = None
            elif sym == "\\":
                j = _skip_args(text, j, "[")
        elif name in ("begin", "end"):
            e = _ENV_NAME.match(text, j)
            env = e.group(1).strip() if e else ""
            j = e.end() if e else j
            if name == "begin":
                if math is None and env.rstrip("*") in MATH_ENVS:
                    math = (i, env)
                j = _skip_args(text, j, "[{" if env.rstrip("*") in TABULAR else "[")
            elif math and math[1] == env:
                maths.append((math[0], j))
                math = None
        elif name in GREEK:
            emit(GREEK[name], i, j)
        elif name in FUNCS:
            emit(name, i, j)
        elif name in SKIP_ARGS:
            j = _skip_args(text, j, "[{")
        i = j
    return chars, spans, maths


def _line_starts(tex):
    return [0] + [m.end() for m in re.finditer("\n", tex)]


def _line_of(tex, offset):
    return bisect.bisect_right(_line_starts(tex), offset)


def printed(text):
    """(text without what \\cite and \\ref print, whether a citation was cut at its start, whether at its end):
    author-year and numeric citations, the numbers of references (CITATION, REF_NUMBER) and a footnote mark glued to
    the first word ("1See") are removed."""
    core = REF_NUMBER.sub(lambda m: m.group(1) or "", re.sub(r"^\d{1,2}(?=[A-Z][a-z])", "", text))  # a footnote mark
    spans = [m.span() for m in CITATION.finditer(core)]
    lead = bool(spans) and not any(ch.isalnum() for ch in core[:spans[0][0]])
    trail = bool(spans) and not any(ch.isalnum() for ch in core[spans[-1][1]:])
    for s, e in reversed(spans):
        core = core[:s] + " " + core[e:]
    return " ".join(core.split()), lead, trail


_CITES_AFTER = re.compile(r"[\s~]*" + CITE_CMD + r"(?:[\s~,;]*" + CITE_CMD + r")*")
_CITES_BEFORE = re.compile(r"(?:" + CITE_CMD + r"[\s~,;]*)+$")


def _find(tex, picked, l0, l1, window=WINDOW, around=("", ""), fuzzy=True, wide=None):
    """The source (start, end, letters around it that agree with the PDF) of the picked PDF words near lines
    l0–l1 (or in the lines `wide`), widened by `window` lines, or None.

    Tries an exact match of the folded text, then of the text without what \\cite and \\ref print (`printed`), then
    the cheapest fuzzy alignment with at most one edit per four characters. Among equal matches, one that starts
    and ends at source word boundaries wins, then the one whose source around it matches the folded PDF words
    around the selection (`around`, before and after) furthest, then the one nearest the synctex lines. A match
    without the citations takes in the \\cite commands that the selection starts or ends in. A selection of only
    citations is the \\cite commands between the words around it."""
    raw = " ".join(w[4] for w in picked)
    core, lead, trail = printed(raw)
    targets = [t for t in dict.fromkeys((_fold(raw), _fold(core))) if t]
    if not targets:
        return None
    starts = _line_starts(tex)
    w0, w1 = wide or (l0, l1)
    a0 = starts[max(w0 - window, 1) - 1]
    a1 = starts[w1 + window] if w1 + window < len(starts) else len(tex)
    chars, spans, maths = _units(tex)
    lo = bisect.bisect_left(spans, (a0,))
    hi = bisect.bisect_left(spans, (a1,))
    hay = "".join(chars[lo:hi])
    # synctex puts display math on its last line, so a match inside the math that holds that line counts as on it
    at = starts[min(l1, len(starts)) - 1]
    display = next(((s, e) for s, e in maths if s <= at < e), None)

    def dist(k):
        if display and display[0] <= spans[lo + k][0] < display[1]:
            return 0
        line = bisect.bisect_right(starts, spans[lo + k][0])
        return max(l0 - line, line - l1, 0)

    def rank(cost, a, b):
        s, e = spans[lo + a][0], spans[lo + b - 1][1]
        inside = (s > 0 and tex[s - 1].isalnum()) + (e < len(tex) and tex[e].isalnum())
        before, after = around
        same = _common(reversed(before), (chars[i] for i in range(lo + a - 1, -1, -1)))
        same += _common(after, (chars[i] for i in range(lo + b, len(chars))))
        return cost, inside, -(same if same >= MIN_SAME else 0), dist(a), a, b  # a letter or two agree by chance

    found, target = [], targets[0]
    for target in targets:
        k = hay.find(target)
        while k >= 0:
            found.append(rank(0, k, k + len(target)))
            k = hay.find(target, k + 1)
        if found:
            break
    stripped = target != targets[0]
    if not found and not _fold(core):  # only citations: the \cite commands between the words around them
        return _between_cites(tex, chars, spans, lo, hay, around, dist)
    if not found and fuzzy and hay and len(target) >= 4 and len(target) * len(hay) <= MAX_CELLS:
        # (hay is empty when synctex's lines print nothing, as \maketitle's line for acmart's teaser and authors)
        found = [rank(cost, a, b) for cost, a, b in _align(hay, target) if cost <= len(target) // 4]
    if not found:
        return None
    _, _, minus_same, _, a, b = min(found)
    start, end = spans[lo + a][0], spans[lo + b - 1][1]
    for s, e in maths:  # math is atomic
        if s < start < e:
            start = s
        if s < end < e:
            end = e
    if stripped and trail:
        m = _CITES_AFTER.match(tex, end)
        end = m.end() if m else end
    if stripped and lead:
        m = _CITES_BEFORE.search(tex, max(0, start - 400), start)
        start = m.start() if m else start
    start, end = _balanced(tex, start, end)
    words = (core if stripped else raw).split()
    lead = re.match(r"\W*", words[0]).group(0)  # punctuation the first and last words carry
    trail = re.search(r"\W*$", words[-1]).group(0)
    if lead and tex[start - len(lead):start] == lead:
        start -= len(lead)
    if trail and tex[end:end + len(trail)] == trail:
        end += len(trail)
    return start, end, -minus_same


def _balanced(tex, start, end):
    """(start, end) widened so a group the range starts or ends inside is whole: "\\textit{Sysprompt} alone", not
    "Sysprompt} alone"; "{LMSYS-Chat-1M}: A …", not "LMSYS-Chat-1M}: A …"."""
    if start and tex[start - 1] == "{" and start < _skip_args(tex, start - 1, "{") <= end:
        start -= 1
        m = re.search(r"\\[A-Za-z@]+\*?$", tex[max(0, start - 40):start])
        start -= len(m.group()) if m else 0
    if end < len(tex) and tex[end] == "}":
        depth = 0
        for i in range(end - 1, start - 1, -1):
            depth += (tex[i] == "}") - (tex[i] == "{")
            if depth < 0:
                return start, end + 1  # its "{" is in the range
    return start, end


def _between_cites(tex, chars, spans, lo, hay, around, dist):
    """(start, end, agreeing letters) of the \\cite commands where the folded words before and after a selection of
    only citations meet in hay (the de-TeXed letters from chars[lo]), nearest the synctex lines; or None."""
    before, after = around[0][-12:], around[1][:12]
    if len(before) + len(after) < 8:
        return None
    best, k = None, hay.find(before + after)
    while k >= 0:
        p = k + len(before)  # the first letter after the citations
        s = spans[lo + p - 1][1] if p else spans[lo][0]
        m = _CITES_AFTER.match(tex, s)
        if m and (best is None or dist(p) < best[0]):
            best = dist(p), s + len(m.group()) - len(m.group().lstrip(" \t\n~")), m.end()
        k = hay.find(before + after, k + 1)
    return best and (best[1], best[2], len(before) + len(after))


def _common(a, b):
    """The length of the common prefix of two iterables."""
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def _align(hay, target):
    """Semi-global edit distance of target against substrings of hay: [(cost, start, end)] of the best."""
    n = len(hay)
    prev, prev_start = [0] * (n + 1), list(range(n + 1))
    for j, ch in enumerate(target, 1):
        cur, cur_start = [j] + [0] * n, [0] * (n + 1)
        for i in range(1, n + 1):
            best, st = prev[i - 1] + (hay[i - 1] != ch), prev_start[i - 1]
            if prev[i] + 1 < best:
                best, st = prev[i] + 1, prev_start[i]
            if cur[i - 1] + 1 < best:
                best, st = cur[i - 1] + 1, cur_start[i - 1]
            cur[i], cur_start[i] = best, st
        prev, prev_start = cur, cur_start
    low = min(prev[1:])
    return [(low, prev_start[i], i) for i in range(1, n + 1) if prev[i] == low and prev_start[i] < i]


def _line_span(tex, l0, l1):
    """Lines l0–l1 without their leading and trailing whitespace."""
    starts = _line_starts(tex)
    start = starts[l0 - 1]
    end = starts[l1] - 1 if l1 < len(starts) else len(tex)
    while start < end and tex[start].isspace():
        start += 1
    while end > start and tex[end - 1].isspace():
        end -= 1
    return start, end


@functools.lru_cache(maxsize=16)
def _blank_comments(tex):
    """tex with every % comment replaced by spaces, so offsets are kept. Cached: finding paragraphs blanks a file's
    comments for each float."""
    return re.sub(r"((?:^|[^\\])(?:\\\\)*)(%.*)", lambda m: m.group(1) + " " * len(m.group(2)), tex, flags=re.M)


def _structure(tex, start, end):
    """(innermost heading title before start, innermost environment containing [start, end)) or None."""
    blank = _blank_comments(tex)
    section = None
    for m in _HEADING.finditer(blank):
        if m.start() > start:
            break
        section = " ".join(tex[m.end():_skip_args(tex, m.end() - 1, "{") - 1].split())
    env = max(((s, name) for s, e, name in envs(tex) if s <= start and e >= end and name != "document"), default=None)
    return section, env and env[1]
