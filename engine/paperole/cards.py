"""What a comment's card shows for one round (CONTRACT.md Amendments, M2a): the sentence(s) around its anchor as that
round's PDF prints them, or, for boxes, figures, tables, display math and algorithms, the region of the PDF to crop.

A context is {"display": "text"|"image", "page", "rects", "clip", "text", "sel", "cut", "changed", "against"};
offsets index `text` as a Python str. Contexts are computed when a round's record is made (create, carry,
reanchor) and stored with it in the ledger."""
import difflib
import functools
import re
import unicodedata
from pathlib import Path

from . import anchor, comments, texdiff

MAX_TEXT = 1200  # characters of text kept, around the anchor
GAP = 0.45  # a gap between text lines of more than this × the line height breaks a paragraph (ACL headings and
# footnotes sit 0.5–0.6 lines below the text before them; lines of a paragraph 0.2–0.4)
PAD = 6.0  # points around an image's rects
MIN_CLIP = (200.0, 48.0)  # smallest width and height of an image's clip, so a small selection keeps its context
INK = (0.18, 0.05)  # share of a text line box's height above its ink (capitals) and below it (descenders)
LIGATURES = str.maketrans({"ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st"})
OPENERS, CLOSERS = "([{\"'‘“", ")]}\"'’”"
BULLETS = set("•◦▪▸‣∗–")  # a text line starting with one of these as a word starts a list item
LABEL = re.compile(r"\d{1,2}[.)]")  # a text line starting with one of these and more words starts a numbered item
MARK = re.compile(r"[0-9*†‡§¶]{1,2}")  # a footnote mark
GLUED_MARK = re.compile(r"(?<=[A-Za-z)\]'\"’”][.?!])[0-9*†‡§¶]{1,2}$")  # a footnote mark glued to a full stop
CAPTION = re.compile(r"(?:Figure|Fig\.|Table|Tab\.|Algorithm|Listing)\s*[A-Z]?\d+(?:\.\d+)*\s*[:.]")
# Environments whose content a card shows as an image (outside a \caption for the floats).
IMAGE_ENVS = set("tabular tabularx tabulary longtable array tikzpicture algorithm algorithmic algorithm2e".split())
FLOATS = set("figure table wrapfigure wraptable subfigure subtable".split())
HEAD_GAP = 12.0  # points: a running head or foot is at least this far from the page's other lines (_edge_row)
NEAR_PAGES = 2  # pages before and after a page that may repeat its running head or foot (_furniture)
JOIN = 8  # letters on each side of a column or page break that must follow each other in the source to join them
# Source between two parts that ends a paragraph: a blank line, \par, \item, or the start or end of an environment
# other than inline-able math (a tcolorbox's text and the paragraph after it are not one sentence).
BREAK = re.compile(r"\n[ \t]*\n|\\par\b|\\item\b|\\(?:begin|end)\s*\{(?!(?:equation|align|gather|multline|math|"
                   r"displaymath|eqnarray|flalign|alignat|split|aligned|cases)\*?\})")


def reference_round(c, n):
    """The round whose text a card shows above round n's: in the round a comment was revived (reopened after it was
    closed), the round it was closed in; else the latest round after its creation and before n in which it was
    followed up (verdict `reopened`) or revived, else its creation round; None in the creation round."""
    if n <= c["created_round"]:
        return None
    revived = (c["rounds"].get(str(n)) or {}).get("revived")
    if revived:
        return revived["from"]
    return max((int(k) for k, r in c["rounds"].items() if c["created_round"] < int(k) < n
                and (r["verdict"] == "reopened" or r.get("revived"))), default=c["created_round"])


def record_context(paper, lg, c, n, changes=()):
    """The context of comment c's round-n record (None for an orphan or without a PDF), with "changed" against the
    reference round's text (its stored context, or one worked out from that round's PDF). `changes` are the round's
    changes: the sentences of those attached to c in its paragraph (not moves) are shown too (a sentence the student
    inserted before the commented one)."""
    ctx = context(paper, lg, c, n, [r for ch in changes if c["id"] in ch["attached_to"] and ch["kind"] != "move"
                                    and ch["page"] == (c["rounds"][str(n)]["anchor"] or {}).get("page")
                                    for r in ch["rects"]])
    k = reference_round(c, n)
    if ctx is None or k is None or ctx["display"] != "text" or c["rounds"][str(n)]["anchor_state"] == "gone":
        return ctx
    rec = c["rounds"][str(k)]
    ref = rec["context"] if "context" in rec else context(paper, lg, c, k)
    if ref and ref["display"] == "text":
        ctx = dict(ctx, changed=changed(ref["text"], ctx["text"]), against=k)
    return ctx


def context(paper, lg, c, n, extra=()):
    """The context of comment c's round-n record without "changed", or None (`extra`: rects of attached changes)."""
    rec = c["rounds"][str(n)]
    a = rec["anchor"]
    pdf = next(r for r in lg["rounds"] if r["n"] == n)["build"]["pdf"]
    if not a or a["page"] is None or not a["rects"] or not pdf or not (Path(paper) / pdf).is_file():
        return None
    return page_context(Path(paper) / "r{}".format(n) / "src", Path(paper) / pdf, a, c["kind"],
                        rec["anchor_state"] == "gone", extra)


def page_context(src, pdf, a, kind, gone, extra=()):
    """The context of an anchor (CONTRACT.md §4) in a PDF built from src, with the sentences of the rects `extra`
    that are in the anchor's paragraph."""
    stamp = anchor._stamp(pdf)
    words = _page_words(stamp, a["page"])
    rects = a["rects"]
    point = all(r[0] == r[2] and r[1] == r[3] for r in rects)
    picked = [] if gone or point else [k for k, w in enumerate(words) if anchor._inside(w, rects)]
    base = {"page": a["page"], "rects": rects, "clip": None, "sel": [], "cut": None, "changed": [], "against": None}
    tex = anchor._read(src, a["file"], pdf)
    if _image(tex, a, kind, gone, picked or point):
        x0, x1 = _text_span(stamp, a["page"], rects, words)
        shown = rects
        if kind != "box" and not gone and a["end"] > a["start"]:  # all of a formula or picture, not just the lines
            page, printed, _ = anchor.to_pdf(src, pdf, a["file"], a["start"], a["end"])  # the advisor selected
            shown = rects + [[max(r[0], x0), r[1], min(r[2], x1), r[3]] for r in printed if page == a["page"]
                             and min(r[2], x1) > max(r[0], x0)]  # synctex's boxes of a picture can pass the text
        elif kind != "box" and gone:  # a deletion point in a table: the row it is in
            y = (rects[0][1] + rects[0][3]) / 2
            row = [w for w in words if w[1] <= y <= w[3] and x0 - 1 <= w[0] and w[2] <= x1 + 1]
            shown = rects + [[min(w[0] for w in row), rects[0][1], max(w[2] for w in row), rects[0][3]]] if row \
                else rects
        bound = area = anchor._doc(stamp)[a["page"]].rect
        if words and kind != "box":
            area = area & (x0 - PAD, area.y0, x1 + PAD, area.y1)
        return dict(base, display="image", text=" ".join(a["text"].split()),
                    clip=_clip(shown, area, kind == "box", words, anchor._graphics(stamp, a["page"]), bound))
    if not words:
        return dict(base, display="text", text="")
    drop = _furniture(stamp, a["page"])  # (unless the anchor is on it)
    if drop:
        words = [w for k, w in enumerate(words) if k not in drop or anchor._inside(w, rects)]
        picked = [] if gone or point else [k for k, w in enumerate(words) if anchor._inside(w, rects)]
        if not words:
            return dict(base, display="text", text="")
    ends, paras = _boundaries(words)
    if gone:
        first = last = _before(words, rects[0])
    elif picked:
        first, last = picked[0], picked[-1]
    else:  # a note at a point: the sentence of the nearest word (not the page number), nothing marked
        body = comments.without_page_number(words)
        if not body:
            return dict(base, display="text", text="")
        first = last = words.index(body[_nearest(body, rects[0])])
    lo, hi = _sentence(ends, first)[0], _sentence(ends, last)[1]
    if gone and hi == first and hi + 1 < len(words):
        hi = _sentence(ends, hi + 1)[1]  # the deletion point ends a sentence (or a heading): the next one too
    for k in (k for k, w in enumerate(words) if extra and anchor._inside(w, extra)):
        if paras[k] in (paras[lo], paras[hi]):  # an attached change in the paragraph: its sentence too
            lo, hi = min(lo, _sentence(ends, k)[0]), max(hi, _sentence(ends, k)[1])
    start = paras.index(paras[lo])
    if CAPTION.match(" ".join(w[4] for w in words[start:start + 3])) or _item(words, start):
        lo, hi = start, len(paras) - 1 - paras[::-1].index(paras[hi])  # a caption or list item is taken whole
    item = texdiff.bibitem(tex, a["start"], a["end"]) if tex and not gone else None
    if item:  # an entry of the reference list is taken whole: the paragraphs that hold its words
        page, rects_, _ = anchor.to_pdf(src, pdf, a["file"], *item)
        entry = [k for k, w in enumerate(words) if anchor._inside(w, rects_)] if page == a["page"] else []
        if entry:
            lo = min(lo, paras.index(paras[entry[0]]))
            hi = max(hi, len(paras) - 1 - paras[::-1].index(paras[entry[-1]]))
    run = list(range(lo, hi + 1))
    held = {paras[k] for k in picked}
    if len(held) > 1:  # a selection in two places (across a column break, a figure between): their paragraphs only
        run = [k for k in run if paras[k] in held]
    head, tail = _across(stamp, a["page"], words, ends, paras, lo, hi, _letters(tex) if tex else None)
    text, spans = comments.join_spans(head + [words[k] for k in run] + tail, tex or "")
    pos = {k: len(head) + i for i, k in enumerate(run)}  # words[k] is word pos[k] of the text
    sel = []
    for k in picked:
        if sel and pos[k] == pos[prev] + 1:
            sel[-1][1] = spans[pos[k]][1]
        else:
            sel.append(list(spans[pos[k]]))
        prev = k
    cut = spans[pos[first]][1] if gone else None
    if gone and tail and first == hi:  # to_pdf put the point on the page or column where its line starts
        cut = spans[-1][1]
    keep = (sel[0][0], sel[-1][1]) if sel else (cut, cut) if gone else spans[pos[first]]
    text, sel, cut = _cap(text, sel, cut, keep)
    return dict(base, display="text", text=text, sel=sel, cut=cut)


@functools.lru_cache(maxsize=64)
def _furniture(stamp, page):
    """The indexes of a page's words (_page_words) that are no part of its text, so no sentence of a card goes on into
    them (demo: a point after a column's last sentence showed "… retrieval depths. 7"): its page number (a number
    alone on its lowest or highest line, comments.without_page_number) and its running head and foot (_edge_row: its
    highest or lowest row of text, besides the page number, when a page up to NEAR_PAGES before or after has the same
    letters at the same height)."""
    out = set(_page_number(stamp, page))
    for top in (True, False):
        row = _edge_row(stamp, page, top)
        if row and any(other and other[2] == row[2] and abs(other[1] - row[1]) <= 2
                       for q in range(page - NEAR_PAGES, page + NEAR_PAGES + 1) if q != page
                       for other in [_edge_row(stamp, q, top)]):
            out.update(row[0])
    return frozenset(out)


def _page_number(stamp, page):
    words = _page_words(stamp, page)
    body = {id(w) for w in comments.without_page_number(words)}
    return [k for k, w in enumerate(words) if id(w) not in body]


@functools.lru_cache(maxsize=128)
def _edge_row(stamp, page, top):
    """(word indexes, top, letters) of a page's highest row of text (lowest: not top), its page number left out,
    when it may be a running head (foot): the lines level with its highest (lowest) line, in the top (bottom) eighth
    of the page, at least HEAD_GAP points from its other lines, with letters other than digits; else None."""
    if not 0 <= page < anchor._doc(stamp).page_count:
        return None
    words, height = _page_words(stamp, page), anchor._doc(stamp)[page].rect.height
    number = set(_page_number(stamp, page))
    lines = {}
    for k, w in enumerate(words):
        if k not in number:
            lines.setdefault(w[5:7], []).append(k)
    boxes = [(min(words[k][1] for k in ks), max(words[k][3] for k in ks), ks) for ks in lines.values()]
    if not boxes:
        return None
    edge = min(boxes, key=lambda b: b[0]) if top else max(boxes, key=lambda b: b[1])
    row = [b for b in boxes if edge[0] <= (b[0] + b[1]) / 2 <= edge[1]]
    rest = [b for b in boxes if b not in row]
    y0, y1 = min(b[0] for b in row), max(b[1] for b in row)
    if (y1 > height / 8 or rest and min(b[0] for b in rest) - y1 < HEAD_GAP) if top else \
            (y0 < height * 7 / 8 or rest and y0 - max(b[1] for b in rest) < HEAD_GAP):
        return None
    ks = sorted(k for b in row for k in b[2])
    letters = "".join(ch for ch in comments._fold(" ".join(words[k][4] for k in ks)) if ch.isalpha())
    return (tuple(ks), round(y0, 1), letters) if letters else None


@functools.lru_cache(maxsize=8)
def _columns(stamp):
    """comments.columns of a PDF (by its stamp)."""
    return comments.columns(stamp[0])


def _page_words(stamp, page):
    """A page's words in reading order without margin line numbers, ligatures spelt out."""
    return [w[:4] + (w[4].translate(LIGATURES),) + w[5:] for w in anchor._words(stamp, page)]


@functools.lru_cache(maxsize=16)
def _letters(tex):
    """(the letters LaTeX source prints, folded (comments._units), without digits (\\ref and \\cite numbers are not
    in the source); the source span of each letter)."""
    chars, spans, _ = comments._units(tex)
    keep = [i for i, ch in enumerate(chars) if ch.isalpha()]
    return "".join(chars[i] for i in keep), [spans[i] for i in keep], tex


def _side(words, end):
    """The letters (folded) of words without what \\cite and \\ref print (comments.printed, which `_letters` does not
    hold either): the last up to 2 × JOIN of them for the left side of a break (`end`), else the first."""
    text = comments._fold(comments.printed(" ".join(w[4] for w in (words[-12:] if end else words[:12])))[0])
    letters = "".join(ch for ch in text if ch.isalpha())
    return letters[-2 * JOIN:] if end else letters[:2 * JOIN]


def _follows(letters, before, after):
    """Whether the last words of `before` and the first of `after` follow each other in the source (`letters`:
    _letters): up to 2 × JOIN letters on each side (at least JOIN), what citations and references print left out,
    with no paragraph break (BREAK) between them."""
    left, right = _side(before, True), _side(after, False)
    if len(left) < JOIN or len(right) < JOIN:
        return False
    text, spans, tex = letters
    k = text.find(left + right)
    while k >= 0:
        if not BREAK.search(tex, spans[k + len(left) - 1][1], spans[k + len(left)][0]):
            return True
        k = text.find(left + right, k + 1)
    return False


def _full_lines(seq, gap):
    """For words in reading order, whether each word's line is a full line of text: at least 75% as wide as the
    widest line of its column (`gap`: the x between the page's two columns, or None; text in a figure or a legend is
    narrower), and not a page number."""
    boxes = {}
    for w in seq:
        b = boxes.get(w[5:7], w[:4])
        boxes[w[5:7]] = (min(b[0], w[0]), min(b[1], w[1]), max(b[2], w[2]), max(b[3], w[3]))

    def side(b):  # 1 left column, 2 right, 3 across both; 0 on a page of one column
        return 0 if gap is None else (b[0] < gap) + 2 * (b[2] > gap)
    widest = {}
    for b in boxes.values():
        widest[side(b)] = max(widest.get(side(b), 0), b[2] - b[0])
    full = {k: b[2] - b[0] >= 0.75 * widest[side(b)] for k, b in boxes.items()}
    body = {id(w) for w in comments.without_page_number(seq)}
    return [full[w[5:7]] and id(w) in body for w in seq]


def _across(stamp, page, words, ends, paras, lo, hi, letters):
    """(head, tail): the words of the sentence words[lo:hi + 1] that a column or page break cut off (a float at the
    top of the next column, a page break). The head is looked for when words[lo] starts a paragraph in lower case:
    at the ends of the page's earlier full lines of text (_full_lines; nearest first), then of the previous page's
    (last first). The tail is looked for when words[hi] ends a paragraph of two or more rows without ending a
    sentence: at the starts of the page's later lines, then of the next page's lines. A place is taken when the
    words on either side of the break follow each other in the source (letters), the place's side taken from its own
    paragraph only (not a page number, a figure's tick labels or a table's numbers before or after it)."""
    head, tail = [], []
    if not letters or not letters[0]:
        return head, tail
    if (not lo or paras[lo - 1] != paras[lo]) and words[lo][4][:1].islower():
        places = [(words, ends, paras, i) for i in range(lo - 1, -1, -1) if words[i][5:7] != words[i + 1][5:7]]
        if page > 0:
            prev = _page_words(stamp, page - 1)
            bounds = _boundaries(prev)
            places += [(prev,) + bounds + (i,) for i in range(len(prev) - 1, -1, -1)
                       if i + 1 == len(prev) or prev[i][5:7] != prev[i + 1][5:7]]
        full = {}
        for seq, seq_ends, seq_paras, i in places:
            if id(seq) not in full:
                full[id(seq)] = _full_lines(seq, (_columns(stamp)[page - (seq is not words)] or [None])[0])
            start = seq_paras.index(seq_paras[i])
            if full[id(seq)][i] and not _ends(seq[i][4], words[lo][4]) \
                    and _follows(letters, seq[start:i + 1], words[lo:]):
                head = seq[_sentence(seq_ends, i)[0]:i + 1]
                break
    para = [w for w, p in zip(words, paras) if p == paras[hi]]
    rows = max(w[3] for w in para) - min(w[1] for w in para) > 1.5 * (words[hi][3] - words[hi][1])
    if (hi + 1 == len(words) or paras[hi + 1] != paras[hi]) and rows and not _ends(words[hi][4], "X"):
        places = [(words, ends, paras, j) for j in range(hi + 1, len(words)) if words[j][5:7] != words[j - 1][5:7]]
        if page + 1 < anchor._doc(stamp).page_count:
            nxt = _page_words(stamp, page + 1)
            bounds = _boundaries(nxt)
            places += [(nxt,) + bounds + (j,) for j in range(len(nxt)) if not j or nxt[j][5:7] != nxt[j - 1][5:7]]
        for seq, seq_ends, seq_paras, j in places:
            end = len(seq_paras) - seq_paras[::-1].index(seq_paras[j])
            if _follows(letters, words[lo:hi + 1], seq[j:end]):
                tail = seq[j:_sentence(seq_ends, j)[1] + 1]
                break
    return head, tail


def _text_span(stamp, page, rects, words, columns=None):
    """(x0, x1) that an image of rects stays within: the page's text, or on a two-column page the rects' column (not
    the margin). `columns`: comments.columns of the PDF when known."""
    x0, x1 = min((w[0] for w in words), default=0), max((w[2] for w in words), default=1e9)
    gap = ((columns if columns is not None else _columns(stamp))[page] or [None])[0]
    if gap is not None:
        middle = sum(r[0] + r[2] for r in rects) / 2 / len(rects)
        x0, x1 = (x0, gap) if all(r[2] <= gap + 2 for r in rects) and middle < gap else \
            (gap, x1) if all(r[0] >= gap - 2 for r in rects) else (x0, x1)
    return x0, x1


def block_clip(pdf, page, rects, columns=None):
    """The crop [x0, y0, x1, y1] of a prose block (its synctex boxes on a page), as a card's image clip (_clip)."""
    stamp = anchor._stamp(pdf)
    words = _page_words(stamp, page)
    x0, x1 = _text_span(stamp, page, rects, words, columns)
    bound = area = anchor._doc(stamp)[page].rect
    if words:
        area = area & (x0 - PAD, area.y0, x1 + PAD, area.y1)
        if (x0, x1) != (min(w[0] for w in words), max(w[2] for w in words)):  # one column of two: a float's clip
            bound = area  # stays in it, not widened to the rules of a full-width table beside it
    return _clip(rects, area, False, words, anchor._graphics(stamp, page), bound)


def _image(tex, a, kind, gone, has_words):
    """Whether a card shows the anchor as an image: a box; a range (or deletion point, in source tex) in display math,
    a tabular, a picture or an algorithm, or in a float outside its \\caption; or a range of which no PDF word is in
    its rects."""
    if kind == "box" or not (has_words or gone):
        return True
    s, e = a["start"], a["end"]
    if tex is None:
        return False
    if anchor._display_around(tex, s, e):
        return True
    names = {name.rstrip("*") for es, ee, name in comments.envs(tex) if es <= s and e <= ee}
    if names & IMAGE_ENVS:
        return True
    floats = [(es, ee) for es, ee, name in comments.envs(tex) if name.rstrip("*") in FLOATS and es <= s and e <= ee]
    if not floats:
        return False
    caption = comments.caption_span(tex, *max(floats))
    return not (caption and caption[0] <= s and e <= caption[1])


def _clip(rects, page, box, words=(), graphics=(), bound=None):
    """The region to crop: the rects' bounds plus PAD (a box as drawn), at least MIN_CLIP in size, inside `page`
    (for anything but a box, the width of the page's text): a window widened past it is moved back in, not cut.
    Anything but a box is widened to the drawings that its band crosses (a plot's axes) and to the rules within
    MIN_CLIP's height of it (a table's), within `bound` (the page: a table across both columns). Then its edges are
    moved so they cut no text (`words`: the page's words; _snap)."""
    bound = bound or page
    x0, y0 = min(r[0] for r in rects) - PAD, min(r[1] for r in rects) - PAD
    x1, y1 = max(r[2] for r in rects) + PAD, max(r[3] for r in rects) + PAD
    if not box:
        grow_x, grow_y = max(MIN_CLIP[0] - (x1 - x0), 0) / 2, max(MIN_CLIP[1] - (y1 - y0), 0) / 2
        x0, x1, y0, y1 = x0 - grow_x, x1 + grow_x, y0 - grow_y, y1 + grow_y
        shift = max(page.x0 - x0, 0) - max(x1 - page.x1, 0)  # moved back inside rather than cut
        x0, x1 = x0 + shift, x1 + shift
        x0, y0, x1, y1 = max(x0, page.x0), max(y0, page.y0), min(x1, page.x1), min(y1, page.y1)
        near = [g for g in graphics if g[2] > x0 and g[0] < x1 and (
            g[3] > y0 and g[1] < y1 or g[3] - g[1] <= 2 and g[2] - g[0] >= 40
            and g[3] > y0 - MIN_CLIP[1] and g[1] < y1 + MIN_CLIP[1])]
        x0 = max(min([x0] + [g[0] - PAD for g in near]), bound.x0)
        x1 = min(max([x1] + [g[2] + PAD for g in near]), bound.x1)
    return [round(v, 2) for v in _snap([x0, y0, x1, y1], rects, words)]


def _snap(clip, rects, words):
    """The clip with no text cut by its edges. Text lines (MuPDF's) level with the rects, not holding any and beside
    them (another column, text wrapped around a table) are left out by moving that side in. A word of a line that
    holds a rect, or of a row level with the rects, is taken in by a side when half of it is inside, else left out.
    Above and below the rects, rows of lines are taken in from the rects outwards until a row that the sides cut by
    more than a tenth (body text around a formula) or of which less than half is inside: the edge goes between."""
    x0, y0, x1, y1 = clip
    top, bottom = min(r[1] for r in rects), max(r[3] for r in rects)
    left, right = min(r[0] for r in rects), max(r[2] for r in rects)
    groups = {}
    for w in words:
        groups.setdefault(w[5:7], []).append(w)
    lines = [(min(w[0] for w in ws), min(w[1] for w in ws), max(w[2] for w in ws), max(w[3] for w in ws), ws,
              any(anchor._inside(w, rects) for w in ws)) for ws in groups.values()]
    level = [ln for ln in lines if ln[3] > top and ln[1] < bottom and ln[3] > y0 and ln[1] < y1]
    for bx0, _, bx1, _, _, held in level:  # beside the rects: that side moves in
        if not held and bx0 >= right and bx0 < x1 and (bx0 + bx1) / 2 > x1:
            x1 = bx0 - 0.5
        elif not held and bx1 <= left and bx1 > x0 and (bx0 + bx1) / 2 < x0:
            x0 = bx1 + 0.5

    def sides(ws, force):
        nonlocal x0, x1
        for w in ws:
            if w[0] < x0 < w[2]:
                x0 = w[0] - 0.5 if force or w[2] - x0 >= x0 - w[0] else w[2] + 0.5
            if w[0] < x1 < w[2]:
                x1 = w[2] + 0.5 if force or x1 - w[0] >= w[2] - x1 else w[0] - 0.5

    taken = [top, bottom]  # the extent of the lines taken in: an edge moved to leave a line out stops there
    for ln in sorted(level, key=lambda ln: not ln[5]):  # the lines holding rects first
        if ln[0] < x1 and ln[2] > x0:
            sides(ln[4], ln[5])
            y0, y1 = min(y0, ln[1] - 0.5), max(y1, ln[3] + 0.5)
            taken = [min(taken[0], ln[1]), max(taken[1], ln[3])]
    for up in (True, False):
        out = sorted((ln for ln in lines if ln[0] < x1 and ln[2] > x0 and (ln[3] <= top + 0.5 if up else
                                                                         ln[1] >= bottom - 0.5)),
                     key=lambda ln: -ln[3] if up else ln[1])
        rows = []
        for ln in out:  # rows: lines level with each other
            if rows and min(ln[3], rows[-1][3]) - max(ln[1], rows[-1][1]) > 0.5 * min(ln[3] - ln[1], rows[-1][3] - rows[-1][1]):
                r = rows[-1]
                rows[-1] = [min(r[0], ln[0]), min(r[1], ln[1]), max(r[2], ln[2]), max(r[3], ln[3]), r[4] + [ln]]
            else:
                rows.append(list(ln[:4]) + [[ln]])
        for rx0, ry0, rx1, ry1, members in rows:
            if (ry1 <= y0) if up else (ry0 >= y1):
                break
            cut = any(min(m[2], x1) - max(m[0], x0) < 0.9 * (m[2] - m[0]) for m in members)
            inside = (min(ry1, y1) - max(ry0, y0)) / max(ry1 - ry0, 0.01)
            if cut or inside < 0.5:
                # the edge goes midway between the two rows' ink, which lies about INK of a line box's height inside
                # it at the top (above capitals) and at the bottom (below descenders): in a tightly set table the
                # boxes overlap, and an edge at either box cut the other row's letters
                h = ry1 - ry0
                if up:
                    y0 = max(y0, (ry1 - INK[1] * h + taken[0] + INK[0] * h) / 2)
                else:
                    y1 = min(y1, (taken[1] - INK[1] * h + ry0 + INK[0] * h) / 2)
                break
            for m in members:
                sides(m[4], False)
            y0, y1 = (min(y0, ry0 - 0.5), y1) if up else (y0, max(y1, ry1 + 0.5))
            taken = [min(taken[0], ry0), max(taken[1], ry1)]
    return [x0, y0, x1, y1]


def _boundaries(words):
    """(ends, paras) for words in reading order: ends[k] is true when a sentence ends after word k, paras[k] is
    word k's paragraph number. A paragraph breaks between text lines where the next line starts more than GAP × the
    line height below the previous one, or above it unless another column flows on (a line right of the previous
    one, and, when more than two lines up, at least 80% as wide: not the text in a figure at the column's top), and
    before a line that starts with a bullet."""
    lines = []  # [first word, last word, bbox]
    for k, w in enumerate(words):
        if lines and words[lines[-1][0]][5:7] == w[5:7]:
            b = lines[-1][2]
            lines[-1][1:] = [k, [min(b[0], w[0]), min(b[1], w[1]), max(b[2], w[2]), max(b[3], w[3])]]
        else:
            lines.append([k, k, list(w[:4])])
    paras, n = [], 0
    for i, (k0, k1, b) in enumerate(lines):
        if i:
            p = lines[i - 1][2]
            height = min(b[3] - b[1], p[3] - p[1])
            if min(b[3], p[3]) - max(b[1], p[1]) > 0.5 * height:  # the same row
                broken = False
            elif b[1] >= p[1]:
                broken = b[1] - p[3] > GAP * max(b[3] - b[1], p[3] - p[1])
            else:
                broken = b[0] < p[2] - 1 or (p[1] - b[1] > 2 * height and b[2] - b[0] < 0.8 * (p[2] - p[0]))
            n += broken or _item(words, k0)
        paras += [n] * (k1 - k0 + 1)
    ends = [k + 1 == len(words) or paras[k + 1] != paras[k] or
            (not (_item(words, k) and words[k][4] not in BULLETS) and _ends(words[k][4], words[k + 1][4]))
            for k in range(len(words))]
    for k in range(len(words) - 1):  # a raised footnote mark goes with the word before it, whose sentence it ends
        if paras[k + 1] == paras[k] and _mark(words[k], words[k + 1]):
            ends[k + 1] = ends[k + 1] or ends[k] and (k + 2 == len(words) or paras[k + 2] != paras[k]
                                                      or _ends(words[k][4], words[k + 2][4]))
            ends[k] = False
    return ends, paras


def _item(words, k):
    """Whether words[k] starts a list item: a bullet, or a number such as "2." that starts a text line and is
    followed by more words on it (an enumerate label)."""
    if words[k][4] in BULLETS:
        return True
    return bool(LABEL.fullmatch(words[k][4])) and (k == 0 or words[k - 1][5:7] != words[k][5:7]) \
        and k + 1 < len(words) and words[k + 1][5:7] == words[k][5:7]


def _mark(word, after):
    """Whether `after`, the word after `word`, is a footnote mark set as a superscript: one or two digits or
    symbols, smaller and raised."""
    return bool(MARK.fullmatch(after[4])) and after[3] - after[1] < 0.85 * (word[3] - word[1]) \
        and (after[1] + after[3]) / 2 < (word[1] + word[3]) / 2 - 0.1 * (word[3] - word[1])


def _ends(word, following):
    """Whether a sentence ends after a word: it ends in . ? or ! (before closing brackets or quotes, or a footnote
    mark glued to it: "cost.1"), the next word does not start in lower case, and it is not an abbreviation (e.g., et
    al., Fig., Sect., Aug., i.e.) or an initial (J.; texdiff.abbreviation)."""
    core = GLUED_MARK.sub("", word.rstrip(CLOSERS)).rstrip(CLOSERS)
    if not core.endswith((".", "?", "!")) or following[:1].islower():
        return False
    bare = core.lstrip(OPENERS)
    return not (bare.endswith(".") and texdiff.abbreviation(bare, following))


def _sentence(ends, k):
    """(first, last) word of the sentence that holds word k."""
    lo, hi = k, k
    while lo and not ends[lo - 1]:
        lo -= 1
    while not ends[hi]:
        hi += 1
    return lo, hi


def _before(words, rect):
    """The word just before a deletion point (whose rect starts at that word's right edge), else the nearest word."""
    cy = (rect[1] + rect[3]) / 2
    left = [k for k, w in enumerate(words) if w[1] <= cy <= w[3] and w[2] <= rect[0] + 1]
    return max(left, key=lambda k: words[k][2]) if left else _nearest(words, rect)


def _nearest(words, rect):
    """The index of the word nearest to a rect's centre, by height first (comments.nearest)."""
    w = comments.nearest(words, (rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2)
    return words.index(w)


def _cap(text, sel, cut, keep):
    """(text, sel, cut) cut to MAX_TEXT characters around the span `keep`, at spaces, with "…" where text was left
    out."""
    if len(text) <= MAX_TEXT:
        return text, sel, cut
    middle = (keep[0] + keep[1]) // 2
    lo = min(max(middle - MAX_TEXT // 2, 0), len(text) - MAX_TEXT)
    hi = lo + MAX_TEXT
    if lo:
        lo = text.find(" ", lo, hi) + 1 or lo
    space = text.rfind(" ", lo, hi)
    if hi < len(text) and space > lo:
        hi = space
    head, tail = ("… " if lo else ""), (" …" if hi < len(text) else "")
    shift = len(head) - lo
    sel = [[max(s, lo) + shift, min(e, hi) + shift] for s, e in sel if e > lo and s < hi]
    cut = cut + shift if cut is not None and lo <= cut <= hi else None
    return head + text[lo:hi] + tail, sel, cut


def _tokens(text):
    """[(token, start, end)]: the words between spaces, with punctuation and symbols at their edges split off one
    character each (as the app's WordDiff does), so "policy." is two tokens and "2309.11998" one."""
    out = []
    for m in re.finditer(r"\S+", text):
        a, b = m.start(), m.end()
        while a < b and unicodedata.category(text[a])[0] in "PS":
            out.append((text[a], a, a + 1))
            a += 1
        tail = []
        while b > a and unicodedata.category(text[b - 1])[0] in "PS":
            b -= 1
            tail.insert(0, (text[b], b, b + 1))
        out += ([(text[a:b], a, b)] if b > a else []) + tail
    return out


def changed(old, new):
    """Spans of the words of new that are not in old, by a word diff with punctuation split off (_tokens); [p, p]
    marks where words of old were left out."""
    a = [t for t, _, _ in _tokens(old)]
    toks = _tokens(new)
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, [t for t, _, _ in toks], autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if j2 > j1:
            out.append([toks[j1][1], toks[j2 - 1][2]])
        else:
            p = toks[j1 - 1][2] if j1 else 0
            out.append([p, p])
    return out


def change_details(old_src, old_pdf, src, pdf, diff, changes):
    """Add to each Change (anchor.carry's, one per hunk of diff, in order) its "section" (the heading it is under, as
    printed; "References" in a .bbl) and its "context": {"before", "now"}, the sentence(s) around it as round n-1's PDF
    (old_pdf, from old_src) and round n's print them. Each side is a context as for cards: `sel` the change's own
    words, `cut` where words were inserted (before) or deleted (now), or where a side that prints no word of its own
    stands; an image for figures, tables and math. A side is null when it prints nothing (a whole file added or
    deleted, an \\input line) or its PDF is missing."""
    for ch, h in zip(changes, diff.hunks):
        includes = anchor._included(diff, h) if h["new_file"] is not None else None
        now = before = None
        if h["new_file"] is not None and ch["page"] is not None and ch["rects"]:
            now = _change_side(src, pdf, h, "new", ch["page"], ch["rects"],
                        h["kind"] == "delete" or includes is not None or anchor._only_includes(diff, h, "new"))
        if old_pdf and h["old_file"] is not None and includes is None and \
                not (h["kind"] != "insert" and anchor._only_includes(diff, h, "old")):
            page, rects, _ = anchor.to_pdf(old_src, old_pdf, h["old_file"], h["old_start"], h["old_end"])
            if page is not None and rects:
                before = _change_side(old_src, old_pdf, h, "old", page, rects, h["kind"] == "insert")
        file, start, end = (h["new_file"], h["new_start"], h["new_end"]) if h["new_file"] is not None else \
            (h["old_file"], h["old_start"], h["old_end"])
        tex = (diff.new_texts if h["new_file"] is not None else diff.old_texts).get(file, "")
        section = "References" if file.endswith(".bbl") else comments._structure(tex, start, end)[0]
        ch["section"] = " ".join(re.sub(r"\\[A-Za-z@]+\*?|[{}$~]", " ", section).split()) if section else None
        ch["context"] = {"before": before, "now": now}
    return describe(old_src, old_pdf, src, pdf, diff, changes)


def _macro_words(before, now):
    """A replace whose side marks no words though the two sides' sentences differ prints words its source does not
    have (a macro: \\answerTODO prints "[TODO]", \\answerYes "[Yes]"): such a side marks the run of words that the
    word diff of the two sentences finds nearest its `cut`, which it then no longer has."""
    if before["display"] != "text" or now["display"] != "text" or \
            " ".join(before["text"].split()) == " ".join(now["text"].split()):
        return
    for side, other in ((before, now), (now, before)):
        if side["sel"] or side["cut"] is None:
            continue
        spans = [sp for sp in changed(other["text"], side["text"]) if sp[1] > sp[0]]
        if spans:
            at = side["cut"]
            side["sel"] = [min(spans, key=lambda sp: (max(sp[0] - at, at - sp[1], 0), sp[0]))]
            side["cut"] = None


def _change_side(src, pdf, h, side, page, rects, point):
    """One side's context of a hunk: its range at page and rects of the PDF built from src. A range whose rects hold
    no word (a "(" that replaced "\\footnote{", a formatting command) is shown as a point, except a replaced figure."""
    words = anchor._words(anchor._stamp(pdf), page)
    inside = [w for w in words if anchor._inside(w, rects)]
    a = {"file": h[side + "_file"], "start": h[side + "_start"], "end": h[side + "_end"], "page": page, "rects": rects,
         "text": comments.join_words(inside)}
    return page_context(src, pdf, a, "highlight", point or not inside and "figure" not in h)


# --- A change in words, for the Changes tab, the summary and the margin (amendment "Readable changes") ----------

# Commands that change only how words look or where lines break, and spacing: an edit of these alone prints the
# same text.
STYLE = set(("textbf textit textsl textsc texttt textrm textsf textup textmd textnormal emph underline mbox bf it sl "
             "sc tt rm sf em bfseries itshape slshape scshape ttfamily rmfamily sffamily mdseries upshape normalfont "
             "tiny scriptsize footnotesize small normalsize large Large LARGE huge Huge noindent indent centering "
             "raggedright raggedleft par newline linebreak nolinebreak pagebreak newpage clearpage smallskip medskip "
             "bigskip vfill hfill quad qquad").split())
SPACING = re.compile(r"\\(?:label|vspace\*?|hspace\*?)\s*\{[^{}]*\}|\\\\(?:\s*\[[^\]]*\])?|\\[,;:! ]|[{}~\s]")
FLOAT_KINDS = {"figure": "Figure", "wrapfigure": "Figure", "table": "Table", "wraptable": "Table"}
NUMBERED = re.compile(r"(Figure|Fig\.|Table|Tab\.)\s*([A-Z]?\.?\d+(?:\.\d+)*)\s*[:.]")  # a caption's label
SECTION_NUMBER = re.compile(r"(?:[A-Z]|\d+)(?:\.\d+)*\.?$")  # 4, 4.1, A, C.2: the first word of a heading line


def describe(old_src, old_pdf, src, pdf, diff, changes):
    """Add to each Change (one per hunk of diff, in order; with its context) "float", the table or figure it is in as
    printed ("Table 2", from its caption in round n's PDF; null when not in one, or not found), and "about", a line
    that says what a change is when its words would be LaTeX: {"kind": "file", "text"} for \\input and \\include
    lines (a file renamed, replaced, added, removed or moved: "Figure 'plot' removed"), whose figure or table is then
    shown as a crop of each round's PDF (its context side); {"kind": "formatting", "text"} for an edit that prints no
    other text ("Formatting only: no printed text changed in §4.1"); else null, and then a replace whose context
    sides mark no words of their own though they differ gets the words its macros print marked (_macro_words)."""
    files = [_input_files(diff, h) or ([], []) for h in diff.hunks]
    moved = {f for removed, _ in files for f in removed} & {f for _, added in files for f in added}
    for ch, h in zip(changes, diff.hunks):
        texts, file, start, end = (diff.new_texts, h["new_file"], h["new_start"], h["new_end"]) \
            if h["new_file"] is not None else (diff.old_texts, h["old_file"], h["old_start"], h["old_end"])
        hit = _float_of(texts, file, start, end)
        ch["float"] = _float_name(pdf if h["new_file"] is not None else None, ch["page"], ch["rects"], texts, hit) \
            if hit else None
        said = _input_change(diff, h, moved)
        if said:
            text, before, now = said
            ctx = dict(ch.get("context") or {"before": None, "now": None})
            if before:
                ctx["before"] = _float_context(old_src, old_pdf, diff.old_texts, before) or ctx["before"]
            if now:
                ctx["now"] = _float_context(src, pdf, diff.new_texts, now) or ctx["now"]
            ch["context"], ch["about"] = ctx, {"kind": "file", "text": text}
        elif h["kind"] != "move" and "figure" not in h and _formatting(h, ch.get("context") or {}):
            where = ch["float"] or (_section_label(pdf, ch["page"], ch["section"]) if ch.get("section") else None)
            ch["about"] = {"kind": "formatting",
                           "text": "Formatting only: no printed text changed" + (" in " + where if where else "")}
        else:
            ch["about"] = None
            ctx = ch.get("context") or {}
            if h["kind"] == "replace" and ctx.get("before") and ctx.get("now"):
                _macro_words(ctx["before"], ctx["now"])
    return changes


def _formatting(h, ctx):
    """Whether a hunk prints no other text: both sides are the same once commands that change only how words look
    (STYLE), \\label, spacing and braces are left out, or both rounds' PDFs print the same sentence(s) around it."""
    def residue(text):
        t = SPACING.sub("", texdiff.blank_comments(text))
        return re.sub(r"\\([A-Za-z@]+)\*?", lambda m: "" if m.group(1) in STYLE else m.group(0), t)
    if residue(h["old_text"]) == residue(h["new_text"]):
        return True
    b, n = ctx.get("before"), ctx.get("now")
    return bool(b and n and b["display"] == n["display"] == "text" and b["text"].strip()
                and " ".join(b["text"].split()) == " ".join(n["text"].split()))


def _float_of(texts, file, start, end, depth=0):
    """(file, start, end, "Table" or "Figure") of the innermost table or figure environment that holds [start, end)
    of a file, or that holds an \\input of the file (up to 5 levels), or None."""
    tex = texts.get(file)
    if tex is None or depth > 5:
        return None
    found = [(s, e, FLOAT_KINDS[name.rstrip("*")]) for s, e, name in comments.envs(tex)
             if name.rstrip("*") in FLOAT_KINDS and s <= start and end <= e]
    if found:
        return (file,) + max(found)
    for f, t in sorted(texts.items()):
        for m in texdiff.INCLUDE.finditer(texdiff.blank_comments(t)):
            if texdiff.include_file(m, texts) == file and f != file:
                hit = _float_of(texts, f, m.start(), m.end(), depth + 1)
                if hit:
                    return hit
    return None


def _float_name(pdf, page, rects, texts, hit):
    """"Table 2": the label printed on page before the caption of the float `hit` (_float_of): of the captions of its
    kind there, the one that goes on with the most of the source caption's letters (at least 8, or all of them),
    nearest to `rects` on a tie (two captions that start alike); the page's only one when the caption has fewer than
    4 letters; else None."""
    file, s, e, kind = hit
    cap = comments.caption_span(texts[file], s, e)
    if pdf is None or page is None or cap is None:
        return None
    want = "".join(ch for ch in comments._units(texts[file][cap[0]:cap[1]])[0] if ch.isalpha())[:80]
    words = _page_words(anchor._stamp(pdf), page)
    found = []  # (letters in common, distance to the rects, number)
    y = (min(r[1] for r in rects) + max(r[3] for r in rects)) / 2 if rects else 0
    for k in range(len(words)):
        m = NUMBERED.match(" ".join(w[4] for w in words[k:k + 3]))
        if m and ("Table" if m.group(1).startswith("Tab") else "Figure") == kind:
            got = "".join(ch for ch in comments._fold(" ".join(w[4] for w in words[k:k + 40])[m.end():])
                          if ch.isalpha())
            same = next((i for i, (a, b) in enumerate(zip(want, got)) if a != b), min(len(want), len(got)))
            found.append((same, abs((words[k][1] + words[k][3]) / 2 - y), m.group(2)))
    if len(want) < 4:
        return "{} {}".format(kind, found[0][2]) if len(found) == 1 else None
    best = max((f[0] for f in found), default=0)
    if best < min(len(want), 8):
        return None
    return "{} {}".format(kind, min((f for f in found if f[0] == best), key=lambda f: f[1])[2])


def _section_label(pdf, page, title):
    """"§4.1" for the heading titled `title` as printed on page or up to 3 pages before (the number before it on its
    line), else "§ title"."""
    want = comments._fold(title)
    if pdf is not None and page is not None and want:
        stamp = anchor._stamp(pdf)
        for p in range(page, max(page - 4, -1), -1):
            lines = []  # words of a block on one baseline: a heading's number is a line of its own for MuPDF
            for w in _page_words(stamp, p):
                if lines and lines[-1][0] == w[5] and abs(lines[-1][1] - w[3]) < 2:
                    lines[-1][2].append(w[4])
                else:
                    lines.append([w[5], w[3], [w[4]]])
            numbers = [ws[0] for _, _, ws in lines if len(ws) > 1 and SECTION_NUMBER.match(ws[0])
                       and want.startswith(comments._fold(" ".join(ws[1:])))
                       and len(comments._fold(" ".join(ws[1:]))) >= min(len(want), 8)]
            if numbers:
                return "§" + numbers[-1].rstrip(".")
    return "§ " + title


def _noun(text):
    """What a file read by \\input holds: "Section file" (a heading), else "Figure" or "Table" (its first float),
    else "File"."""
    if text is None:
        return "File"
    if comments._HEADING.search(texdiff.blank_comments(text)):
        return "Section file"
    kinds = [FLOAT_KINDS[name.rstrip("*")] for _, _, name in sorted(comments.envs(text))
             if name.rstrip("*") in FLOAT_KINDS]
    return kinds[0] if kinds else "File"


def _input_files(diff, h):
    """(files removed, files added) by a hunk that holds only parts of \\input or \\include commands on both sides
    (and white space), or None."""
    if h["old_file"] is None or h["new_file"] is None:
        return None
    olds, only_old = texdiff.reads(diff.old_texts, h["old_file"], h["old_start"], h["old_end"])
    news, only_new = texdiff.reads(diff.new_texts, h["new_file"], h["new_start"], h["new_end"])
    if not (only_old and only_new and (olds or news)):
        return None
    removed = [f for k, f in enumerate(olds) if olds[:k + 1].count(f) > news.count(f)]
    added = [f for k, f in enumerate(news) if news[:k + 1].count(f) > olds.count(f)]
    return (olds, news) if h["kind"] == "move" else (removed, added)


def _input_change(diff, h, moved=()):
    """(text, old file, new file) for a hunk that only adds, removes, moves or changes \\input or \\include commands:
    what happened to the files they read, in words, and the files whose figure or table each side shows (or None);
    None for any other hunk. `moved`: files that one hunk of the diff removes and another adds."""
    files = _input_files(diff, h)
    if not files or not (files[0] or files[1]):
        return None
    removed, added = files
    nouns = {f: _noun(diff.old_texts.get(f)) for f in removed}
    nouns.update({f: _noun(diff.new_texts.get(f)) for f in added if f not in nouns})

    def said(f, verb):
        noun = nouns[f]
        return "{} '{}' {}".format(noun, Path(f).stem, verb) if noun in ("Figure", "Table") else \
            "{} {} {}".format(noun, f, verb)

    def shown(fs):
        return fs[0] if len(fs) == 1 and nouns.get(fs[0]) in ("Figure", "Table") else None
    if h["kind"] == "move":
        return "; ".join(said(f, "moved") for f in dict.fromkeys(removed + added)), shown(removed), shown(added)

    def pair(old, new, verb):
        noun = nouns[new] if nouns[new] != "File" else nouns[old]
        noun = noun + " file" if noun in ("Figure", "Table") else noun
        return "{} {} {} {}".format(noun, old, verb, new)
    if len(removed) == len(added) == 1:
        old, new = removed[0], added[0]
        return pair(old, new, "renamed to" if diff.renamed.get(old) == new else "replaced by"), shown(removed), \
            shown(added)
    pairs = {f: diff.renamed[f] for f in removed if diff.renamed.get(f) in added}  # two edited lines in one hunk
    return "; ".join([pair(f, pairs[f], "renamed to") for f in pairs]
                     + [said(f, "moved" if f in moved else "removed") for f in removed if f not in pairs]
                     + [said(f, "moved" if f in moved else "added") for f in added if f not in pairs.values()]), \
        shown(removed), shown(added)


def _float_context(src, pdf, texts, file):
    """The image context of the first figure or table of a file in the PDF built from src: its caption, pictures,
    tabulars and drawings (synctex's boxes of the whole environment hold only the caption's lines), or None."""
    tex = texts.get(file) or ""
    spans = sorted((s, e) for s, e, name in comments.envs(tex) if name.rstrip("*") in FLOAT_KINDS)
    if not spans or pdf is None:
        return None
    s, e = spans[0]
    pictures = [m.start() for m in texdiff.GRAPHICS.finditer(texdiff.blank_comments(tex), s, e)]
    tables = [(a, b) for a, b, name in comments.envs(tex) if name.rstrip("*") in IMAGE_ENVS and s <= a and b <= e]
    cap = comments.caption_span(tex, s, e)
    found = [anchor.to_pdf(src, pdf, file, a, b)[:2] for a, b in ([cap] if cap else []) + tables]
    pages = [p for p, rects in found if p is not None and rects]
    if not pages:
        return None
    page, stamp = pages[0], anchor._stamp(pdf)
    rects = [r for p, rs in found if p == page for r in rs]
    starts = pictures + [a for a, _ in tables]
    if cap and found[0][0] == page and found[0][1] and starts:  # the drawing above the caption when the
        # pictures come before it in the source, else below it
        ref = [min(r[0] for r in found[0][1]), min(r[1] for r in found[0][1]), max(r[2] for r in found[0][1]),
               max(r[3] for r in found[0][1])]
        drawn = anchor._drawing(stamp, page, ref, -1 if min(starts) < cap[0] else 1)
        rects += [drawn] if drawn else []
    words = [w for w in anchor._words(stamp, page) if anchor._inside(w, rects)]
    frame = [min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects)]
    a = {"file": file, "start": s, "end": e, "page": page, "rects": [[round(v, 2) for v in frame]],
         "text": comments.join_words(words)}  # one frame round the whole float
    ctx = page_context(src, pdf, a, "highlight", False)
    return ctx if ctx["display"] == "image" else None
