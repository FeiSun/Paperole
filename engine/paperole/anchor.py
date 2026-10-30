"""Place source ranges in the PDF, and carry open comments into a new round (CONTRACT.md §5, anchor).

New comments are located by comments.locate.

Source and PDF are linked through `synctex` line boxes. Inside those boxes the PDF words are matched to the
source letter by letter (letters and digits only; markup, math symbols and spacing ignored), so re-wrapping,
hyphenation, ligatures and citation numbers do not get in the way.
"""
import atexit
import bisect
import difflib
import gzip
import os
import posixpath
import re
import shutil
import subprocess
import tempfile
import unicodedata
import zlib
from collections import Counter
from functools import lru_cache
from pathlib import Path

import pymupdf

from . import comments, ledger, project, texdiff

CONTEXT = 40  # source characters of prefix and suffix
AROUND = 2  # extra source lines aligned with a range's PDF lines, as context
MIN_RUN = 2  # shorter runs of matching characters are ignored
POINT_WIDTH = 2.0  # points: the rect of a deletion point
MIN_HINT = 4  # letters and digits a last known PDF text needs to be looked for
EXACT_CONFIDENCE, FUZZY_MIN = 0.9, 0.6
LABEL_CONFIDENCE = 0.8  # a box comment's environment found again only by its \label
FIT = 15.0  # points: a box this close to a picture's extent on every side was drawn around the picture
PICTURE = 20.0  # points: a drawn part at least this wide or high is a picture, not a rule or a tick
DRAW_GAP = 30.0  # points: parts of a picture (paths, images) at most this far apart are one picture
BOX_PAD = 6.0  # points around the page's text that a carried box stays inside
GRAPHICS = {"fill-path", "stroke-path", "fill-image", "fill-imgmask", "fill-shade"}
# Floats; with a star (figure*), one set across both columns of a two-column page (_wide).
FLOATS = set("figure table wrapfigure wraptable algorithm sidewaysfigure sidewaystable".split())
GUESSED = 0.5  # the confidence of a position that is a guess (below 0.75, so it needs attention)
NEIGHBOURS = 1  # source lines before and after a range whose PDF lines may hold its first or last word (_place)
LINE = 14.0  # points: a synctex box at most this high is one line of text
# Commands whose [optional] and first {argument} print nothing that is in the source.
SKIP_ARG = {"label", "ref", "eqref", "pageref", "autoref", "cref", "Cref", "vref", "nameref", "subref", "cite",
            "citep", "citet", "citealp", "citealt", "citeauthor", "citeyear", "citeyearpar", "Citet", "Citep",
            "Citealp", "Citealt", "Citeauthor", "parencite", "textcite", "autocite", "nocite", "includegraphics",
            "input", "include", "begin", "end", "href", "bibliography", "bibliographystyle", "bibitem", "usepackage",
            "documentclass", "hspace", "vspace"}
INCLUDE = texdiff.INCLUDE
# Commands that print words the source does not have: citations and reference numbers.
PRINTS = re.compile(r"\\(?:([Cc]ite[a-z]*|parencite|textcite|autocite)|ref|eqref|autoref|[cC]ref|pageref|vref|subref)\b")
NUMBER = re.compile(r"\(?§?(?:[A-Z](?:\.?\d+(?:\.\d+)*)?|\d+(?:\.\d+)*)\)?(?:\([a-z]\))?\)?")  # what \ref prints
DISPLAY = re.compile(r"\\begin\{(equation|align|alignat|gather|multline|flalign|eqnarray|displaymath)(\*?)\}"
                     r".*?\\end\{\1\2\}|(?<!\\)\\\[.*?\\\]|\$\$.*?\$\$", re.S)
VIEW = re.compile(r"Page:(\d+)\nx:\S+\ny:\S+\nh:(\S+)\nv:(\S+)\nW:(\S+)\nH:(\S+)")


# ---- files, synctex and PDF words (cached by path and modification stamp) ----

def _stamp(path):
    st = os.stat(path)
    return str(path), st.st_mtime_ns, st.st_size


@lru_cache(maxsize=64)
def _read_cached(stamp):
    return Path(stamp[0]).read_text(encoding="utf-8", errors="replace")


def _read(src, file, pdf):
    path = comments.source_path(src, pdf, file) if file else None
    return _read_cached(_stamp(path)) if path and path.is_file() else None


@lru_cache(maxsize=16)
def _line_starts(text):
    return [0] + [m.end() for m in re.finditer(r"\n", text)]


def _line_of(text, offset):
    return bisect.bisect_right(_line_starts(text), offset)


def _line_span(text, line):
    """(start, end) of a 1-based line, without its newline; clamped to the file."""
    starts = _line_starts(text)
    line = min(max(line, 1), len(starts))
    end = starts[line] - 1 if line < len(starts) else len(text)
    return starts[line - 1], end


@lru_cache(maxsize=16)
def _clean(text):
    return texdiff.blank_comments(text)


@lru_cache(maxsize=16)
def _displays(text):
    return [m.span() for m in DISPLAY.finditer(_clean(text))]


def _display_around(text, start, end):
    """The display-math environment that a range (or point) touches, as (start, end), or None."""
    for s, e in _displays(text):
        if s < max(end, start + 1) and e > start:
            return s, e
    return None


@lru_cache(maxsize=4)
def _synctex_exe(path):
    return shutil.which("synctex", path=path) or "synctex"


def _synctex(args):
    env = project.tex_env()
    try:  # with its full path and close_fds=False, Python starts it with posix_spawn: 2 ms less than a fork
        return subprocess.run([_synctex_exe(env["PATH"])] + args, capture_output=True, text=True, env=env,
                              timeout=60, close_fds=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _rel(name, src, disk):
    """The path relative to src of a synctex input name such as `<src>/./sections/method.tex`, spelled as on disk
    (disk: texdiff.spellings of src; synctex keeps the \\input's spelling), or None."""
    if "/./" in name:
        rel = posixpath.normpath(name.split("/./", 1)[1])
    else:
        try:
            rel = Path(name).resolve().relative_to(Path(src).resolve()).as_posix()
        except (ValueError, OSError):
            return None
    return None if rel.startswith("../") else disk.get(texdiff.name_key(rel), rel)


@lru_cache(maxsize=8)
def _inputs(pdf_stamp, src):
    """{relative file: input name as synctex knows it} for the inputs under src, and for a .bbl that BibTeX wrote
    beside the PDF, its name (comments.source_path). synctex keeps the .bbl's absolute path, so after the review
    folder was moved, a .bbl of that name beside the PDF is the one."""
    names, build = {}, Path(pdf_stamp[0]).parent.resolve()
    for path in (Path(pdf_stamp[0]).with_suffix(".synctex.gz"), Path(pdf_stamp[0]).with_suffix(".synctex")):
        if not path.is_file():
            continue
        opener, disk = gzip.open if path.suffix == ".gz" else open, texdiff.spellings(src)
        with opener(path, "rb") as f:
            for raw in f:
                if raw.startswith(b"Input:"):
                    name = raw.decode("utf-8", "replace").rstrip("\r\n").split(":", 2)[2]
                    rel = _rel(name, src, disk)
                    if rel is None and name.endswith(".bbl") and (Path(name).parent.resolve() == build
                                                                  or (build / Path(name).name).is_file()):
                        rel = Path(name).name
                    if rel:
                        names.setdefault(rel, name)
        break
    return names


def _input_name(stamp, src, file):
    """synctex's input name of a file under src (_inputs), named as on disk or in another case or Unicode form (an
    older ledger's anchor has synctex's spelling: texdiff.find_file), or None."""
    names = _inputs(stamp, str(src))
    found = texdiff.find_file(file, names)
    return names[found] if found is not None else None


SHEET_MARK = re.compile(rb"^[{}]\d+$", re.M)  # a sheet (a page's records) opens with {page and closes with }page
RECORD_TAG = re.compile(rb"^[\[(vhxkg$r](\d+),", re.M)
INPUT_LINE = re.compile(rb"^Input:(\d+):([^\r\n]*)", re.M)
FORM_REF = re.compile(rb"^f", re.M)
PARTS = 16  # parts of .synctex files kept in the temporary folder at a time
_parts, _tmp = {}, []  # (PDF stamp, tags) -> stand-in PDF, least recently used first; the temporary folder


@lru_cache(maxsize=4)
def _sheets(pdf_stamp):
    """(decompressed <stem>.synctex.gz, [(start, end, tags)] of its sheets, {tag: input name}): the input tags a
    sheet's records name, or None for a sheet that draws a form (a \\pdfxform: its records are elsewhere). None
    without the file."""
    try:
        data = gzip.decompress(Path(pdf_stamp[0]).with_suffix(".synctex.gz").read_bytes())
    except (OSError, EOFError, zlib.error):
        return None
    sheets, start = [], None
    for m in SHEET_MARK.finditer(data):
        if data[m.start():m.start() + 1] == b"{":
            start = m.start()
        elif start is not None:
            body = data[start:m.end()]
            sheets.append((start, m.end() + 1, None if FORM_REF.search(body) else
                           frozenset(int(t) for t in RECORD_TAG.findall(body))))
            start = None
    names = {int(t): n.decode("utf-8", "replace") for t, n in INPUT_LINE.findall(data)}
    return data, sheets, names


def _view_target(pdf_stamp, name):
    """The output path for `synctex view` of input `name`: a stand-in for the PDF in a temporary folder beside a
    <stem>.synctex that keeps only the sheets naming an input of the same file name (synctex matches names more
    loosely than by equality), the sheets that draw forms, and every line outside the sheets (with the inputs the
    left-out sheets open). synctex reads the whole file for each query, but answers from the records of the input
    asked for, all in those sheets, so it gives the same boxes in the same order from a fraction of the work. The
    PDF itself when nothing would be left out, no input has that file name, or the part cannot be written."""
    found = _sheets(pdf_stamp)
    if found is None:
        return pdf_stamp[0]
    data, sheets, names = found
    base = posixpath.basename(name).lower()
    tags = frozenset(t for t, n in names.items() if posixpath.basename(n).lower() == base)
    if not tags or all(s[2] is None or s[2] & tags for s in sheets):
        return pdf_stamp[0]
    key = (pdf_stamp, tags)
    target = _parts.pop(key, None)
    if target is None or not os.path.isfile(target[:-4] + ".synctex"):  # (the system may clear old temporary files)
        target = _write_part(pdf_stamp, data, sheets, tags)
        if target is None:
            return pdf_stamp[0]
    _parts[key] = target
    while len(_parts) > PARTS:
        shutil.rmtree(Path(_parts.pop(next(iter(_parts)))).parent, ignore_errors=True)
    return target


def _write_part(pdf_stamp, data, sheets, tags):
    """Write the part of a .synctex for _view_target; the stand-in PDF's path, or None."""
    try:
        if not _tmp:
            _tmp.append(tempfile.mkdtemp(prefix="paperole-synctex-"))
            atexit.register(shutil.rmtree, _tmp[0], True)
        os.makedirs(_tmp[0], mode=0o700, exist_ok=True)
        folder = Path(tempfile.mkdtemp(dir=_tmp[0]))
        out, prev = [], 0
        for start, end, sheet_tags in sheets:
            out.append(data[prev:start])
            body = data[start:end]
            out += [body] if sheet_tags is None or sheet_tags & tags else \
                [m.group() + b"\n" for m in INPUT_LINE.finditer(body)]
            prev = end
        out.append(data[prev:])
        stem = Path(pdf_stamp[0]).stem
        (folder / (stem + ".synctex")).write_bytes(b"".join(out))
        (folder / (stem + ".pdf")).touch()
        return str(folder / (stem + ".pdf"))
    except OSError:
        return None


@lru_cache(maxsize=4096)
def _line_boxes(pdf_stamp, name, line):
    """[(page, rect)] of the PDF boxes synctex gives for a source line (from part of the .synctex: _view_target)."""
    out = _synctex(["view", "-i", f"{line}:0:{name}", "-o", _view_target(pdf_stamp, name)])
    boxes = []
    for p, h, v, w, ht in VIEW.findall(out):
        h, v, w, ht = map(float, (h, v, w, ht))
        if w > 0 and ht > 0:
            boxes.append((int(p) - 1, (h, v - ht, h + w, v)))
    return boxes


RECORD = re.compile(rb"([\[(vhxkg$r])(\d+),(\d+)(?:,-?\d+)?:(-?\d+),(-?\d+)(?::(-?\d+),(-?\d+),(-?\d+))?")


def line_boxes(pdf):
    """{(file, line): [(page, rect)]} for the source lines under src (and a .bbl beside the PDF), from one pass over
    <stem>.synctex.gz: the line box (hbox) that holds each record of the line, rects as `synctex view` gives them; an
    hbox holding no records (a picture) counts for its own line. An hbox that holds others is not its own line's: the
    output routine of a review ruler boxes every text line of the page again with the line TeX is reading at
    shipout. It replaces a `synctex view` call per line where many lines are needed (the blocks of prose.json)."""
    return _all_line_boxes(_stamp(pdf))


@lru_cache(maxsize=4)
def _all_line_boxes(pdf_stamp):
    pdf = Path(pdf_stamp[0])
    path = pdf.with_suffix(".synctex.gz")
    if not path.is_file():
        return {}
    names, scale, offset, out = {}, 1 / 65781.76, (0, 0), {}
    page, stack, content = None, [], False

    def add(key, box):
        if box and key[0] in names:
            out.setdefault((names[key[0]], key[1]), set()).add((page, box))
    with gzip.open(path, "rb") as f:
        for raw in f:
            if raw.startswith(b"Input:"):  # also between records, for files opened while typesetting
                tag, name = raw.decode("utf-8", "replace").rstrip("\r\n").split(":", 2)[1:]
                rel = posixpath.normpath(name.split("/./", 1)[1]) if "/./" in name else \
                    Path(name).name if name.endswith(".bbl") and (Path(name).parent.resolve() == pdf.parent.resolve()
                                                                  or (pdf.parent / Path(name).name).is_file()) else None
                if rel:
                    names[int(tag)] = rel
                continue
            if not content:
                if raw.startswith(b"Unit:"):
                    scale *= float(raw[5:])
                elif raw.startswith(b"Magnification:"):
                    scale *= float(raw[14:]) / 1000
                elif raw.startswith(b"X Offset:"):
                    offset = (int(raw[9:]), offset[1])
                elif raw.startswith(b"Y Offset:"):
                    offset = (offset[0], int(raw[9:]))
                elif raw.startswith(b"Content:"):
                    content = True
                continue
            c = raw[:1]
            if c == b"{":
                page, stack = int(raw[1:]) - 1, []
                continue
            if c in b")]":
                if stack:
                    kind, box, key, children = stack.pop()
                    if kind == b"(" and not children:
                        add(key, box)
                continue
            m = RECORD.match(raw)
            if not m or page is None:
                continue
            if stack:
                stack[-1][3] = True
            kind, key = m.group(1), (int(m.group(2)), int(m.group(3)))
            if kind in b"([":
                h, v, w, ht, d = (int(m.group(k)) for k in (4, 5, 6, 7, 8))
                h, v = h + offset[0], v + offset[1]
                box = (h * scale, (v - ht) * scale, (h + w) * scale, (v + d) * scale) if w > 0 and ht + d > 0 \
                    else None
                stack.append([kind, box, key, False])
            else:
                add(key, next((b for k, b, _, _ in reversed(stack) if k == b"("), None))
    return {k: sorted(v) for k, v in out.items()}


@lru_cache(maxsize=4)
def _doc(pdf_stamp):
    return pymupdf.open(pdf_stamp[0])


@lru_cache(maxsize=64)
def _words(pdf_stamp, page):
    """The page's words as (x0, y0, x1, y1, text, block, line, word), in reading order, without margin line
    numbers."""
    doc = _doc(pdf_stamp)
    return comments.body_words(doc[page].get_text("words"), comments.ruler_edges(pdf_stamp[0])) \
        if 0 <= page < doc.page_count else []


# ---- matching source characters to PDF words ----

def _skip_args(s, pos, limit=500):
    """The position after the [optional] and first {argument} of a command that ends at pos."""
    n = min(len(s), pos + limit)
    while pos < n:
        while pos < n and s[pos] in " \t":
            pos += 1
        if pos < n and s[pos] == "[":
            close = s.find("]", pos, n)
            if close < 0:
                return pos
            pos = close + 1
        else:
            break
    if pos < n and s[pos] == "{":
        depth = 0
        for k in range(pos, n):
            if s[k] in "{}" and s[k - 1] != "\\":
                depth += 1 if s[k] == "{" else -1
                if depth == 0:
                    return k + 1
    return pos


def _src_chars(text, lo, hi):
    """[(character, offset)] of the letters and digits LaTeX prints from text[lo:hi], lower-cased, roughly."""
    clean = _clean(text)
    out, skip_to = [], lo
    for m in texdiff.TOKEN.finditer(clean, lo, hi):
        if m.start() < skip_to:
            continue
        tok = m.group()
        if tok[0] == "\\":
            include = INCLUDE.match(clean, m.start())
            if include:  # its file name (in braces or not; \import's folder too) prints nothing
                skip_to = include.end()
            elif tok[1:].rstrip("*") in SKIP_ARG:
                skip_to = _skip_args(clean, m.end())
        elif tok[0].isalnum() or tok[0] == "_":
            for k, ch in enumerate(tok):
                out += [(c.lower(), m.start() + k) for c in unicodedata.normalize("NFKD", ch) if c.isalnum()]
    return out


def _pdf_chars(words):
    """[(character, word index)] of the letters and digits of PDF words, lower-cased."""
    return [(c.lower(), i) for i, w in enumerate(words) for c in unicodedata.normalize("NFKD", w[4]) if c.isalnum()]


def _align(a, b):
    """Index pairs of matching characters of two char lists, ignoring runs shorter than MIN_RUN."""
    sm = difflib.SequenceMatcher(None, [c for c, _ in a], [c for c, _ in b], autojunk=False)
    return [(i + k, j + k) for i, j, n in sm.get_matching_blocks() if n >= MIN_RUN for k in range(n)]


def _inside(w, rects, pad=0.0):
    cx, cy = (w[0] + w[2]) / 2, (w[1] + w[3]) / 2
    return any(r[0] - pad <= cx <= r[2] + pad and r[1] - pad <= cy <= r[3] + pad for r in rects)


def _line_rects(words):
    """One rect per text line for words in reading order."""
    rects, prev = [], None
    for w in words:
        cy = (w[1] + w[3]) / 2
        if prev and w[0] >= prev[0] - 1 and rects[-1][1] - 1 <= cy <= rects[-1][3] + 1:
            r = rects[-1]
            rects[-1] = [min(r[0], w[0]), min(r[1], w[1]), max(r[2], w[2]), max(r[3], w[3])]
        else:
            rects.append(list(w[:4]))
        prev = w
    return rects


def _union_boxes(boxes):
    """Boxes with exact duplicates and boxes inside another box removed."""
    boxes = list(dict.fromkeys(boxes))
    return [list(b) for b in boxes if not any(o != b and o[0] <= b[0] and o[1] <= b[1] and o[2] >= b[2]
                                              and o[3] >= b[3] for o in boxes)]


def _rounded(rects):
    return [[round(v, 2) for v in r] for r in rects]


def _text_in(words, rects):
    return comments.join_words([w for w in words if _inside(w, rects)])


def to_pdf(src, pdf, file, start, end, hint="", before=None):
    """(page or None, rects, text) of a source range in the PDF. A range inside display math gives the whole display.
    `hint`, the range's last known PDF text, is looked for when no word of the range is found (the range of a
    \\bibliography prints nothing of its own); `before`, (src, pdf, anchor) of the range's last known place, picks
    which of several occurrences of the hint in the range's boxes it is (an axis label drawn twice in a picture)."""
    text = _read(src, file, pdf)
    if text is None or start is None or not Path(pdf).is_file():
        return None, [], ""
    stamp = _stamp(pdf)
    name = _input_name(stamp, src, file)
    if name is None:
        return None, [], ""
    display = _display_around(text, start, end)
    lo, hi = display or _whole_commands(text, start, end)
    l1, l2 = _line_of(text, lo), _line_of(text, max(lo, hi - 1))
    need = len(_src_chars(text, lo, hi)) / 2  # fewer matched letters than this: look further
    caption = not display and _in_caption(text, lo, hi)
    found = _place(text, stamp, name, lo, hi, l1, l2, display, caption=caption, file=file)
    if not display and hi > lo and found[0] < need:
        # synctex puts a macro argument that spans lines (a \caption, say) on the line where it ends
        p1, p2 = (_line_of(text, x) for x in texdiff.paragraph(text, lo, hi))
        if (p1, p2) != (l1, l2) and p2 - p1 <= 60:
            wider = _place(text, stamp, name, lo, hi, p1, p2, None, caption=caption, file=file)
            if wider[0] > found[0]:
                found = wider
    if found[0] < need:
        # synctex gives the inside of a scaled box (\resizebox, adjustbox) its unscaled place: the whole page
        wider = _place(text, stamp, name, lo, hi, l1, l2, display, whole=True, file=file)
        if wider[0] > found[0]:
            found = wider
    _, page, rects, boxes = found
    if page is None:
        return None, [], ""
    if not rects and hi > lo:
        seen = _find_text(stamp, hint, page, boxes, _rank(before, hint) if before else None)
        if seen:
            page, rects = seen
    if not rects and hi > lo and not display and not _src_chars(text, lo, hi):
        point = _place(text, stamp, name, lo, lo, l1, l2, None)  # it prints no word of its own ("(", \vspace): a point
        if point[2]:
            page, rects = point[1], point[2]
    area = _doc(stamp)[page].rect
    if not rects and hi == lo and (_sane(boxes) or boxes):  # a point with no word before it on its lines: a point
        b = (_sane(boxes) or boxes)[0]  # at the start of the first line box, never the boxes (a page number)
        rects = [[b[0], b[1], b[0] + POINT_WIDTH, b[3]]]
    areas = None
    if not rects:  # no word matched: the line boxes, within the page's text (synctex gives a scaled picture its
        rects = _union_boxes(_sane(boxes))  # unscaled size, past the text into the margin)
        words = _words(stamp, page)
        whole = area
        if words:
            area = area & (min(w[0] for w in words) - 1, min(w[1] for w in words) - 1, max(w[2] for w in words) + 1,
                           max(w[3] for w in words) + 1)
        count = sum(1 for _ in texdiff.GRAPHICS.finditer(_clean(text), lo, hi))
        if count:  # pictures as drawn, inside the page, not cut to its words (a page of floats has few)
            drawn = _pictures(src, pdf, file, lo, page, [b for b in dict.fromkeys(_sane(boxes))
                                                         if b[3] - b[1] > LINE], count)
            rects = [r for r in rects if r[3] - r[1] <= LINE] + drawn
            areas = [area] * (len(rects) - len(drawn)) + [whole] * len(drawn)
    rects = [r for r in ([max(r[0], a.x0), max(r[1], a.y0), min(r[2], a.x1), min(r[3], a.y1)]
                         for r, a in zip(rects, areas or [area] * len(rects))) if r[0] <= r[2] and r[1] <= r[3]]
    return page, _rounded(rects), _text_in(_words(stamp, page), rects)


def box_place(src, pdf, file, start, end, box=None, ref=None, old=None):
    """(page, rects, text, ref) of a box comment's range. `ref` is the box around the PDF words of the \\caption of
    the environment at the range (else of the range), and `text` those words. Given the box and ref of an earlier
    round, the box keeps its place against the ref: moved with its centre across, and with its top when the box is
    above the ref (a figure above its caption), its bottom when below (a table below its caption), else its centre.
    When it was drawn around the picture next to the caption (within FIT points of the drawing's extent in `old`, that
    round's (PDF, page)), it is drawn around the new picture with the same margins (a replaced or resized figure). It
    is kept inside the page's text and the picture. Without them the rect is the ref."""
    text = _read(src, file, pdf)
    span = comments.caption_span(text, start, end) if text is not None and end > start else None
    page, rects, ptext = to_pdf(src, pdf, file, *(span or (start, end)))
    if not rects:
        return page, rects, ptext, None
    new = [min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects)]
    if not (box and ref):
        return page, [new], ptext, _rounded([new])[0]
    middle = (box[1] + box[3]) / 2
    dx = (new[0] + new[2] - ref[0] - ref[2]) / 2
    dy = new[1] - ref[1] if middle < ref[1] else new[3] - ref[3] if middle > ref[3] else \
        (new[1] + new[3] - ref[1] - ref[3]) / 2
    moved = [box[0] + dx, box[1] + dy, box[2] + dx, box[3] + dy]
    stamp = _stamp(pdf)
    side = -1 if middle < ref[1] else 1 if middle > ref[3] else 0
    drawn = _drawing(stamp, page, new, side) if side else None
    if drawn and old and Path(old[0]).is_file():
        before = _drawing(_stamp(old[0]), old[1], ref, side)
        if before and all(abs(b - e) <= FIT for b, e in zip(box, before)):
            moved = [d + b - e for d, b, e in zip(drawn, box, before)]
    words = _words(stamp, page)
    parts = [w[:4] for w in words] + [new] + ([drawn] if drawn else [])
    area = _doc(stamp)[page].rect & (min(r[0] for r in parts) - BOX_PAD, min(r[1] for r in parts) - BOX_PAD,
                                     max(r[2] for r in parts) + BOX_PAD, max(r[3] for r in parts) + BOX_PAD)
    moved = [max(moved[0], area.x0), max(moved[1], area.y0), min(moved[2], area.x1), min(moved[3], area.y1)]
    return page, _rounded([moved if moved[0] < moved[2] and moved[1] < moved[3] else new]), ptext, _rounded([new])[0]


@lru_cache(maxsize=64)
def _graphics(stamp, page):
    """The rects of what a page draws other than text (paths, images, shadings), from MuPDF's bbox log."""
    doc = _doc(stamp)
    if not 0 <= page < doc.page_count:
        return []
    width = doc[page].rect.width
    return [tuple(r) for kind, r in doc[page].get_bboxlog() if kind in GRAPHICS
            and r[2] > r[0] - 0.01 and r[3] > r[1] - 0.01 and r[2] - r[0] < 0.95 * width]


def _pictures(src, pdf, file, offset, page, boxes, count):
    """`count` pictures (\\includegraphics) at source offset of file as drawn on page, from synctex's `boxes` of
    their lines that are taller than a line. synctex gives the line that holds a picture (as wide as the column when
    it is centred), and a scaled picture's natural size and, for some, its printed size. Each box is taken as drawn
    (_drawn); those that hold the most of the page's drawings go first, the smallest first among them, and each that
    overlaps none taken before is a picture."""
    graphics = _graphics(_stamp(pdf), page)
    found = [_drawn(src, pdf, file, offset, page, b) for b in boxes]
    found.sort(key=lambda d: (-sum(1 for g in graphics if d[0] - 1 <= g[0] and d[1] - 1 <= g[1] and g[2] <= d[2] + 1
                                   and g[3] <= d[3] + 1), (d[2] - d[0]) * (d[3] - d[1])))
    out = []
    for d in found:
        if len(out) < count and not any(min(d[2], o[2]) - max(d[0], o[0]) > 1
                                        and min(d[3], o[3]) - max(d[1], o[1]) > 1 for o in out):
            out.append(d)
    return out


def _drawn(src, pdf, file, offset, page, box):
    """A picture (the \\includegraphics at source offset of file) as drawn on page, for a synctex `box` of it. synctex
    gives a scaled picture its natural size, from its reference point (bottom left) up and right, so a picture made to
    fit one column of a two-column page ran across the other column (demo round 4: a replaced picture's change). The
    box is scaled about its bottom-left corner, never beyond its size: to end at the gap between the columns when it
    crosses it in a float of one column (_wide; figure, table), else at the text's right edge on the PDF's pages, and
    inside the page; then to just take in the drawings (paths, images) inside that (a plot's background or axes)."""
    stamp = _stamp(pdf)
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    lay = _layout(stamp)
    right = max((tx[1] for tx in lay["text_x"] if tx), default=x1)
    gap = _gap(lay, page)
    if gap is not None and x0 < gap < x1 and _wide(src, pdf, file, offset) is False:
        right = gap
    s = min(1.0, (right - x0) / w, y1 / h)
    if s <= 0:
        return list(box)
    inside = [g for g in _graphics(stamp, page) if g[0] >= x0 - 1 and g[1] >= y1 - s * h - 1
              and g[2] <= x0 + s * w + 1 and g[3] <= y1 + 1]
    if inside:
        s = min(s, max(max((g[2] - x0) / w, (y1 - g[1]) / h) for g in inside))
    return [x0, y1 - s * h, x0 + s * w, y1]


def _gap(lay, page):
    """The x between the two text columns of a page (comments.columns), or for a page not found to be set in two
    (a page of floats) the middle one of the PDF's when at least half of its pages are; else None."""
    if page < len(lay["columns"]) and lay["columns"][page]:
        return lay["columns"][page][0]
    gaps = sorted(c[0] for c in lay["columns"] if c)
    return gaps[len(gaps) // 2] if gaps and 2 * len(gaps) >= len(lay["columns"]) else None


def _wide(src, pdf, file, offset, depth=0):
    """Whether source offset of file is in a float set across both columns of a two-column page (figure*, table*:
    True), in a float of one column (figure, table: False), or in neither (None), also through the \\input or
    \\include that reads the file (up to 5 levels)."""
    text = _read(src, file, pdf)
    if text is None or depth > 5:
        return None
    names = [name for s, e, name in comments.envs(text) if s <= offset < e and name.rstrip("*") in FLOATS]
    if names:
        return any(name.endswith("*") for name in names)
    files = _inputs(_stamp(pdf), str(src))
    for f in files:
        other = _read(src, f, pdf) if f != file and f.endswith(".tex") else None
        for m in INCLUDE.finditer(_clean(other)) if other else ():
            if texdiff.include_file(m, files) == file:
                found = _wide(src, pdf, f, m.start(), depth + 1)
                if found is not None:
                    return found
    return None


def _drawing(stamp, page, ref, side):
    """The extent [x0, y0, x1, y1] of the drawing next to a caption box `ref`: above it (side -1) or below it (1),
    across the caption's width, made of the paths and images that follow each other with gaps of at most DRAW_GAP
    points from the caption on; or None."""
    rects = [r for r in _graphics(stamp, page) if r[2] > ref[0] - 2 and r[0] < ref[2] + 2
             and (r[3] <= ref[1] + 2 if side < 0 else r[1] >= ref[3] - 2)]
    rects.sort(key=lambda r: -r[3] if side < 0 else r[1])
    edge, out = (ref[1] if side < 0 else ref[3]), None
    for r in rects:
        if (r[3] < edge - DRAW_GAP) if side < 0 else (r[1] > edge + DRAW_GAP):
            break
        out = list(r) if out is None else [min(out[0], r[0]), min(out[1], r[1]), max(out[2], r[2]), max(out[3], r[3])]
        edge = out[1] if side < 0 else out[3]
    return out


def _place(text, stamp, name, lo, hi, l1, l2, display, whole=False, caption=False, file=None):
    """(score, page, rects, line boxes on that page) for the range lo..hi, on the page of lines l1..l2's boxes
    where most of its letters match the words inside those boxes (with whole, all the page's words). A display's
    rect is one box around its matched words and the line boxes that hold them, which also cover its symbols.
    synctex gives a display its last line, so with no letters matched, that line's page wins. In a caption, the
    boxes that hold a picture are left out when others remain (a subfigure's box: the plot's own axis label).
    For a range of text (not a point) in `file`, words are also taken from the boxes of the lines just before and
    after (NEIGHBOURS; from line_boxes, one pass for all lines): synctex gives a PDF line to the source lines whose
    spaces it holds, so the first part of a hyphenated first word, or a paragraph's last line of one word, belongs to
    the line before or after; the letters aligned with the range's own decide. Only such boxes next to the range's
    own count (_next_to): a line that ends a footnote has boxes at the page's foot too, whose words would take the
    letters of the range's own."""
    boxes = [b for ln in range(l1, l2 + 1) for b in _line_boxes(stamp, name, ln)]
    near = [b for ln in (l1 - NEIGHBOURS, l2 + NEIGHBOURS) for b in _all_line_boxes(stamp).get((file, ln), ())] \
        if file and hi > lo and not whole else []
    best = (-1, None, [], [])
    for page in dict.fromkeys(p for p, _ in (boxes[::-1] if display else boxes)):
        pboxes = [r for p, r in boxes if p == page]
        if caption and not whole:
            pictures = [g for g in _graphics(stamp, page) if g[2] - g[0] >= PICTURE or g[3] - g[1] >= PICTURE]
            pboxes = [b for b in pboxes if not any(_inside(g, [b]) for g in pictures)] or pboxes
        words = _words(stamp, page)
        if not whole:
            around = [] if display or caption or hi <= lo else \
                _sane([r for p, r in near if p == page and r[3] - r[1] <= LINE and _next_to(r, pboxes)])
            words = [w for w in words if _inside(w, pboxes + around, 1.0)]
        score, rects = _match_range(text, lo, hi, l1, l2, words)
        if display:
            parts = rects + [b for b in _sane(pboxes) if any(_inside(r, [b], 1.0) for r in rects)] or _sane(pboxes)
            rects = [[min(r[0] for r in parts), min(r[1] for r in parts), max(r[2] for r in parts),
                      max(r[3] for r in parts)]] if parts else []
        if score > best[0]:
            best = score, page, rects, pboxes
    return best


def _next_to(r, boxes):
    """Whether box r is level with one of the boxes, or directly above or below one (at most half a line apart),
    across from it."""
    return any(min(r[2], b[2]) > max(r[0], b[0]) and max(b[1] - r[3], r[1] - b[3]) <= LINE / 2 for b in boxes)


def _sane(boxes):
    """Line boxes without those that start at the page's edge: pictures drawn over the whole page when it is
    shipped out (a margin ruler, say), which synctex gives the line TeX was reading at that moment."""
    return [b for b in boxes if b[0] > 0 and b[1] > 0]


def _target(hint):
    """The letters and digits of a PDF text that is looked for (_find_text), lower-cased."""
    return "".join(c for c, _ in _pdf_chars([(0, 0, 0, 0, hint or "")]))


def _hits(stamp, page, hint):
    """(the page's words, [word indexes of each occurrence of hint], in reading order), letters and digits compared;
    None when hint has fewer than MIN_HINT of them."""
    target = _target(hint)
    if len(target) < MIN_HINT:
        return None
    words = _words(stamp, page)
    chars = _pdf_chars(words)
    letters, hits = "".join(c for c, _ in chars), []
    k = letters.find(target)
    while k >= 0:
        hits.append(sorted({chars[j][1] for j in range(k, k + len(target))}))
        k = letters.find(target, k + 1)
    return words, hits


def _in_boxes(words, hits, boxes):
    """The occurrences (hits) whose words all lie in the boxes."""
    return [h for h in hits if boxes and all(_inside(words[i], boxes, 1.0) for i in h)]


def _find_text(stamp, hint, near, boxes, rank=None):
    """(page, rects) of a last known PDF text: on the page nearest to `near`, the occurrence nearest the boxes on it
    (letters and digits compared); with `rank`, on page `near` the rank-th of the occurrences in the boxes (_rank)
    when there are any. None if it is not found or has fewer than MIN_HINT letters and digits."""
    if len(_target(hint)) < MIN_HINT:
        return None
    cx, cy = (sum(b[0] + b[2] for b in boxes) / 2 / len(boxes), sum(b[1] + b[3] for b in boxes) / 2 / len(boxes)) \
        if boxes else (0, 0)
    for page in sorted(range(_doc(stamp).page_count), key=lambda p: (abs(p - near), p)):
        words, hits = _hits(stamp, page, hint)
        inside = _in_boxes(words, hits, _sane(boxes)) if rank is not None and page == near else []
        if inside:
            return page, _line_rects([words[i] for i in inside[min(rank, len(inside) - 1)]])
        if hits:
            first = min(hits, key=lambda idx: (words[idx[0]][0] - cx) ** 2 + (words[idx[0]][1] - cy) ** 2)
            return page, _line_rects([words[i] for i in first])
    return None


def _rank(before, hint):
    """Which of the occurrences of a last known PDF text (hint) in its range's boxes, in reading order, the range's
    rects held in an earlier round: `before` is (src, pdf, anchor) of that round. None when that is not known."""
    src, pdf, a = before
    if not a or a.get("page") is None or not a.get("rects") or not pdf or not Path(pdf).is_file():
        return None
    text, stamp = _read(src, a["file"], pdf), _stamp(pdf)
    name = _input_name(stamp, src, a["file"])
    if text is None or name is None or a.get("start") is None:
        return None
    lines = range(_line_of(text, a["start"]), _line_of(text, max(a["start"], a["end"] - 1)) + 1)
    boxes = _sane([r for ln in lines for p, r in _line_boxes(stamp, name, ln) if p == a["page"]])
    found = _hits(stamp, a["page"], hint)
    if found is None:
        return None
    words, hits = found
    inside = _in_boxes(words, hits, boxes)
    return next((k for k, h in enumerate(inside) if any(_inside(words[i], a["rects"], 1.0) for i in h)), None)


COMMAND = re.compile(comments.CITE_CMD + r"|\\(?:ref|eqref|autoref|[cC]ref|pageref|vref|nameref|subref)\*?\s*"
                     r"\{[^{}]*\}")
FOOTNOTE = re.compile(r"\\footnote\*?\s*(?:\[[^\]]*\])?\s*\{")


def _in_caption(text, start, end):
    """Whether [start, end) lies in the argument of a \\caption or \\subcaption."""
    clean = _clean(text)
    for m in texdiff.CAPTION.finditer(clean, max(0, start - 3000), start + 1):
        if m.end() <= start and end <= comments._skip_args(clean, m.end() - 1, "{") - 1:
            return True
    return False


def _whole_commands(text, start, end):
    """(start, end) widened to the whole \\cite or \\ref command that it starts or ends inside (an edited citation
    key prints no word of its own: the command's printed words are drawn)."""
    for m in COMMAND.finditer(_clean(text), max(0, start - 500), end + 500):
        if m.start() < start < m.end() or m.start() < end < m.end():
            start, end = min(start, m.start()), max(end, m.end())
    return start, end


def _footnote(text, start, end):
    """(start, end) of the argument of the \\footnote that holds [start, end), or None."""
    clean = _clean(text)
    for m in FOOTNOTE.finditer(clean, max(0, start - 3000), start + 1):
        close = comments._skip_args(clean, m.end() - 1, "{") - 1
        if m.end() <= start and end <= close:
            return m.end(), close
    return None


def _match_range(text, start, end, l1, l2, words):
    """(matched characters, rects) of a range (or of the point after the word before a deletion point) in words.
    A range in a footnote is aligned with the footnote's own text only (synctex gives it the line of its mark, and
    the paragraph around the mark would take its letters)."""
    lo = _line_span(text, l1 - AROUND)[0]
    hi = _line_span(text, l2 + AROUND)[1] if end > start else end
    note = _footnote(text, start, end)
    if note:
        lo, hi = note[0], (note[1] if end > start else end)
    src, pchars = _src_chars(text, lo, hi), _pdf_chars(words)
    pairs = _align(src, pchars)
    if end > start:
        inside = [(i, j) for i, j in pairs if start <= src[i][1] < end]
        hit = sorted({pchars[j][1] for _, j in inside})
        if hit:  # a citation or reference number the range starts or ends with prints words of its own
            hit = _printed_by_commands(words, hit[0], -1, text[start:src[inside[0][0]][1]]) + hit
            hit += _printed_by_commands(words, hit[-1], 1, text[src[inside[-1][0]][1] + 1:end])
        else:  # a range of only \cite or \ref commands: the words they print after the word before the range
            before = [pchars[j][1] for i, j in pairs if src[i][1] < start]
            hit = _printed_by_commands(words, max(before, default=-1), 1, text[start:end])
        return len(inside) or len(hit), _line_rects([words[k] for k in hit])
    before = [(src[i][1], pchars[j][1]) for i, j in pairs if src[i][1] < start]
    if not before:
        return 0, []
    w = words[max(before)[1]]
    return 1, [[w[2], w[1], w[2] + POINT_WIDTH, w[3]]]


# ---- anchors ----

def _printed_by_commands(words, k, step, edge):
    """Indexes (in order) of the words before words[k] (step -1) or after it (step 1) that a \\cite or \\ref in the
    source between them and the range's edge (`edge`) prints: words that together are a citation or a
    reference number (comments.CITATION, NUMBER), punctuation after them aside: the most such words, at most 12."""
    command = PRINTS.search(_clean(edge))
    if not command:
        return []
    pattern = NUMBER if command.group(1) is None else comments.CITATION
    found = []
    for n in range(1, 13):
        idx = sorted(range(k + step, k + step * (n + 1), step))
        if not all(0 <= i < len(words) for i in idx):
            break
        if pattern.fullmatch(" ".join(words[i][4] for i in idx).rstrip(".,;:")):
            found = idx  # the longest: "Li (2025)" is a citation too, but "Chen and Li (2025)" is the one
    return found


def _anchor(text, file, start, end, page, rects, ptext):
    return {"file": file, "start": start, "end": end,
            "lines": [_line_of(text, start), _line_of(text, max(start, end - 1))],
            "quote": text[start:end], "prefix": text[max(0, start - CONTEXT):start], "suffix": text[end:end + CONTEXT],
            "page": page, "rects": _rounded(rects), "text": ptext}


# ---- carrying comments into a new round ----

def carry(old_src, src, pdf, diff, items, old_pdf=None):
    """Re-anchor carried comments in the new round, and list the round's changes (CONTRACT.md §5, anchor.carry).
    An item with "guessed" true (a comment first placed by a synctex line) keeps a confidence of at most GUESSED.
    An item with "point" true is a note placed at a point: when its range prints nothing (a click on a blank page
    anchors to a line such as \\clearpage), it keeps its earlier point; otherwise it stays a point beside its line
    (_beside; "click" is (src, pdf, anchor) of the round where it was placed, else the previous round's), so its card
    marks no words. An item with "box" true is a box comment: its anchor has "label" and "ref", and its rect is moved
    with the ref (box_place). One anchored to a whole environment has that environment as its sentence, is found
    again by its \\label when its source is not (method "label", LABEL_CONFIDENCE), and is widened to the environment
    that holds its new range. A comment in a file the student took out of the paper (its \\input deleted, commented
    out, put in \\iffalse or changed, so the new build does not read it) is gone where that \\input was (_dropped),
    unless its quote is found as it is in a file the build reads (not a fuzzy match: another section's sentence).
    A gone comment whose point an edit touches is back where that edit put its last quote again, verbatim
    (_restored: a section whose \\input was put back, a deleted sentence typed in again): "moved", with the edit.
    An anchor's file is looked for in the old tree also in another case or Unicode form (_in_tree)."""
    records, ranges, extra = {}, {}, {}
    for item in items:
        a, last = _in_tree(diff.old_texts, item.get("anchor")), item.get("last") or {}
        seen = old_src, old_pdf  # the source and PDF of the round of `a`, the place drawn last
        old = diff.old_texts.get((a or {}).get("file"))
        env = item.get("box") and old is not None and comments.box_env(old, a["start"], a["end"]) == (a["start"],
                                                                                                         a["end"])
        found = dropped = None
        if old is not None and (a["file"] in diff.unread or a["file"] not in diff.new_texts
                                and a["file"] not in diff.renamed):
            dropped = _dropped(diff, a["file"])  # its \input taken out: not in the paper
        if old is not None and a.get("start") is not None:
            sent = (a["start"], a["end"]) if env else texdiff.sentence(old, a["start"], a["end"])
            ranges[item["id"]] = (a["file"], a["start"], a["end"], sent)
            found = _by_diff(diff, a["file"], a["start"], a["end"], sent)
            if found is not None and dropped is not None and found[1] in diff.unread:
                found = None
        if found is not None and a["start"] == a["end"] and found[0] == "changed":
            back = _restored(diff, a["file"], a["start"], item.get("quoted"))
            if back:  # drawn as the PDF printed its quote last (two equal labels in a picture: the same one)
                found, last = back, item["quoted"]
                a = last if item.get("quoted_at") else None
                seen = item.get("quoted_at") or seen
        if found is None:
            found = _search(diff, last, fuzzy=dropped is None)
        if found is None and item.get("box"):
            found = _by_label(diff, last.get("label"))
        if found is None:
            found = dropped
        if found is None:
            records[item["id"]] = {"anchor": None, "anchor_state": "orphan", "confidence": 0.0, "method": "none"}
            continue
        state, file, start, end, method, confidence = found[:6]
        extra[item["id"]] = found[6:]
        if item.get("guessed"):
            confidence = min(confidence, GUESSED)
        new = diff.new_texts[file]
        if item.get("box") and state != "gone":
            if env or method == "label":
                start, end = comments.box_env(new, start, end) or (start, end)
            prev = a or last
            page, rects, ptext, ref = box_place(src, pdf, file, start, end, (prev.get("rects") or [None])[0],
                                                prev.get("ref"), (seen[1], a["page"]) if a and seen[1] else None)
        else:
            # a point on a line that prints nothing before it, right before an \input (a dropped section's place):
            # the start of the file that \input reads, as for a change there; with none after it, right after one,
            # the end of the file that one reads (the last section of the paper dropped)
            bare = state == "gone" and not _src_chars(new, _line_span(new, _line_of(new, start))[0], start)
            after = _include_after(diff, file, start) if bare else None
            before = _include_before(diff, file, start) if bare and after is None else None
            reads, only = texdiff.reads(diff.new_texts, file, start, end) if end > start else ([], False)
            if not after and only and reads and reads[0] in diff.new_texts:  # a range of \input lines: the start
                after = reads[0]  # of the file the first reads (where synctex puts the line is no place)
            page, rects, ptext = _start_of(src, pdf, diff, after) if after else \
                _end_of(src, pdf, diff, before) if before else \
                to_pdf(src, pdf, file, start, end, last.get("text", ""), seen + (a,) if a else None)
            ref = None
            prev = a or last
            if item.get("point") and state != "gone" and not _src_chars(new, start, end) \
                    and prev.get("page") is not None and prev["page"] < _doc(_stamp(pdf)).page_count:
                page, rects, ptext = prev["page"], prev["rects"], ""  # a note on a spot that prints nothing stays
            elif item.get("point") and state != "gone" and rects:  # a click note stays a point by its line
                rects = [_beside(*(item.get("click") or seen + (a,)), pdf, page, rects)]
        anchor = _anchor(new, file, start, end, page, rects, ptext)
        if item.get("box"):
            anchor.update(label=comments.env_label(new, start, end) if end > start else None, ref=ref)
        records[item["id"]] = {"anchor": anchor, "anchor_state": state, "confidence": round(confidence, 3),
                               "method": method}
    return records, _changes(src, pdf, diff, ranges, extra)


def _in_tree(texts, a):
    """Anchor a with its file named as in the tree `texts` (texdiff.find_file): an older ledger's anchor has synctex's
    spelling, the \\input's, which can differ from the file's name on disk in case or Unicode form."""
    file = (a or {}).get("file")
    if file is None or file in texts:
        return a
    found = texdiff.find_file(file, texts)
    return dict(a, file=found) if found is not None else a


def _beside(old_src, old_pdf, a, pdf, page, rects):
    """The point [x, y, x, y] of a note clicked beside its line, carried to the line's new rects. The line is the
    nearest of the range's rects in an earlier round (`a`, its anchor there, in old_pdf built from old_src), found
    again among the new rects by its words (the sentence may wrap differently now), else by its rank. The point keeps
    its place against that line: inside it, as far from its start; in the margin or between the columns
    (_in_margin), where it was across the page when the new line is in the same column; else as far from the line's
    end or start (a click after a short last line);
    and as far from its middle, within it, up or down. A point that would fall on a word is moved past the line's
    end. Without those, at the start of the first new rect. Kept on the page."""
    r, point = rects[0], None
    if a and old_pdf and a.get("rects") and a.get("page") is not None and Path(old_pdf).is_file():
        x, y = (a["rects"][0][0] + a["rects"][0][2]) / 2, (a["rects"][0][1] + a["rects"][0][3]) / 2
        opage, orects, _ = to_pdf(old_src, old_pdf, a["file"], a["start"], a["end"])
        if opage == a["page"] and orects:
            k = min(range(len(orects)), key=lambda i: (max(orects[i][1] - y, y - orects[i][3], 0),
                                                       max(orects[i][0] - x, x - orects[i][2], 0)))
            o = orects[k]
            words = _words(_stamp(pdf), page)

            def letters(ws, rect):
                return "".join(c for c, _ in _pdf_chars([w for w in ws if _inside(w, [rect])]))
            line = letters(_words(_stamp(old_pdf), opage), o)

            def shared(rect):
                sm = difflib.SequenceMatcher(None, line, letters(words, rect), autojunk=False)
                return sum(b.size for b in sm.get_matching_blocks() if b.size >= 3)
            scores = [shared(q) for q in rects] if line else [0] * len(rects)
            j = min(range(len(rects)), key=lambda i: (-scores[i], abs(i - k)))
            r = rects[j] if scores[j] else rects[min(k, len(rects) - 1)]
            across = min(r[2], o[2]) - max(r[0], o[0]) > 0.5 * min(r[2] - r[0], o[2] - o[0])  # the same column
            ny = min(max((r[1] + r[3]) / 2 + y - (o[1] + o[3]) / 2, r[1]), r[3])
            if o[0] <= x <= o[2]:
                nx = min(r[0] + x - o[0], r[2])
            else:
                nx = x if across and _in_margin(old_pdf, opage, o, x) else \
                    r[2] + x - o[2] if x > o[2] else r[0] - (o[0] - x)
                if any(w[0] - 0.5 <= nx <= w[2] + 0.5 and w[1] <= ny <= w[3] for w in words):
                    nx = r[2] + max(x - o[2], 2.0) if x > o[2] else r[0] - max(o[0] - x, 2.0)
            point = nx, ny
    x, y = point or (r[0], (r[1] + r[3]) / 2)
    area = _doc(_stamp(pdf))[page].rect
    x, y = round(min(max(x, area.x0), area.x1), 2), round(min(max(y, area.y0), area.y1), 2)
    return [x, y, x, y]


@lru_cache(maxsize=8)
def _layout(stamp):
    return comments.layout(stamp[0])


def _in_margin(pdf, page, line, x):
    """Whether x, beside a line's rect, lies outside the text of the line's column: in the page's margin (past its
    text_x) or, on a two-column page, in the gap between the columns."""
    stamp = _stamp(pdf)
    lay = _layout(stamp)
    tx = lay["text_x"][page] if page < len(lay["text_x"]) else None
    if not tx:
        return False
    if x < tx[0] or x > tx[1]:
        return True
    gap = (lay["columns"][page] or [None])[0] if page < len(lay["columns"]) else None
    if gap is None:
        return False
    words = [w for w in _words(stamp, page) if tx[0] <= w[0] and w[2] <= tx[1]]
    left = max((w[2] for w in words if w[2] <= gap), default=gap)
    right = min((w[0] for w in words if w[0] >= gap), default=gap)
    return left < x < right


def _inserted_before(diff, file, start):
    """The insert hunks whose new text ends just before the new place of old offset `start` in the same paragraph
    (whitespace without a blank line between): a sentence inserted at the start of a paragraph touches the sentence
    it now precedes, though its old point lies before the paragraph break."""
    place = diff.map_offset(file, start, "left")
    if place is None:
        return []
    nf, ns = place
    text = diff.new_texts[nf]
    out = []
    for h in diff.hunks:
        if h["kind"] != "insert" or h["new_file"] != nf:  # (a deleted file's hunk has no new side)
            continue
        end = h["new_start"] + len((h["new_text"] or "").rstrip())  # without a paragraph break it ends with
        if end <= ns and text.count("\n", end, ns) < 2 and not text[end:ns].strip() and not texdiff.break_only(h):
            out.append(h)
    return out


def _dropped(diff, file, depth=0):
    """("gone", file, point, point, "diff", 1.0, hunks…) for a range in an old file that the new paper no longer reads
    because the student took out the old tree's \\input of it (deleted it, commented it out or changed it): the
    point where that \\input was, with the hunks that hold its tokens (to attach); outside the command an edit of
    the \\input next to it now holds (the two edits in one hunk). An \\input still there that TeX now skips
    (\\iffalse … \\fi, a comment environment around it) is taken out too: the point is after the skipped part, the
    hunks those that skip it. When the file that read it is not read either, that file's \\input is looked for.
    None when no \\input of it was taken out (a build that stopped early, \\includeonly)."""
    for x, text in sorted(diff.old_texts.items()):
        for m in INCLUDE.finditer(_clean(text)):
            if texdiff.include_file(m, diff.old_texts) != file or x == file:
                continue
            if (x in diff.unread or x not in diff.new_texts and x not in diff.renamed) and depth < 5:
                found = _dropped(diff, x, depth + 1)
                if found:
                    return found
                continue
            hunks = list({id(t[3]): t[3] for t in diff.tokens_in(x, m.start(), m.end()) if t[3]}.values())
            place = diff.map_offset(x, m.start(), "left")
            if place and hunks:
                place = place[0], _outside_command(diff.new_texts[place[0]], place[1],
                                                   min(h["old_start"] for h in hunks) < m.start())
            elif place:
                new = diff.new_texts[place[0]]
                span = next((sp for sp in texdiff.hidden_spans(new) if sp[0] <= place[1] < sp[1]), None)
                if span:
                    hunks = [h for h in diff.hunks if h["new_file"] == place[0] and h["kind"] != "move"
                             and h["new_start"] <= span[1] and h["new_end"] >= span[0]]
                    place = place[0], span[1]
            if hunks and place and place[0] not in diff.unread:
                return ("gone",) + place + (place[1], "diff", 1.0) + tuple(hunks)
    return None


def _outside_command(text, offset, after):
    """offset, or when it lies inside an \\input or \\include command, the command's end (after) or start."""
    for m in INCLUDE.finditer(_clean(text)):
        if m.start() < offset < m.end():
            return m.end() if after else m.start()
    return offset


def _include_after(diff, file, offset):
    """The new tree's file that the \\input or \\include right after `offset` reads (only white space between),
    or None."""
    clean = _clean(diff.new_texts[file])
    m = INCLUDE.search(clean, offset)
    if m is None or clean[offset:m.start()].strip():
        return None
    f = texdiff.include_file(m, diff.new_texts)
    return f if f not in diff.unread else None


def _include_before(diff, file, offset):
    """The new tree's file that the \\input or \\include right before `offset` reads (only white space between),
    or None."""
    clean = _clean(diff.new_texts[file])
    m = next((m for m in INCLUDE.finditer(clean, 0, offset) if not clean[m.end():offset].strip()), None)
    f = texdiff.include_file(m, diff.new_texts) if m else None
    return f if f not in diff.unread else None


def _restored(diff, file, point, quoted):
    """("moved", file, start, end, "exact", EXACT_CONFIDENCE, hunks…) for a gone comment (its point in the old
    file) whose last quote (`quoted`, an anchor) an edit touching that point put back verbatim: in the edit's new text,
    in a file read by an \\input it added, or in one read by an \\input that TeX skipped before it (\\iffalse taken
    out), or in a file those read; else None."""
    hunks = [h for h in diff.hunks_touching(file, point, point) + _inserted_before(diff, file, point)
             if h["kind"] != "move" and h["new_file"]]
    if not hunks or not quoted:
        return None
    found = _search(diff, quoted, fuzzy=False)
    if found is None:
        return None
    _, f, s, e = found[:4]
    includes = texdiff._includes(diff.new_texts)
    for h in hunks:
        added = texdiff.reads(diff.new_texts, h["new_file"], h["new_start"], h["new_end"])[0] + \
            texdiff.hidden_reads(diff.old_texts, h["old_file"], h["old_start"], h["old_end"])
        for _ in range(5):  # and the files those read (a figure's file read by a restored section)
            added += [x for a in added for x in includes.get(a, ()) if x not in added]
        if f in added or f == h["new_file"] and h["new_start"] <= s and e <= h["new_end"]:
            return found + tuple(hunks)
    return None


def _by_label(diff, label):
    """("changed", file, start, end, "label", LABEL_CONFIDENCE) for the environment with this \\label in the new
    tree's files that its build reads, or None."""
    if not label:
        return None
    for file, text in sorted(diff.new_texts.items()):
        if file in diff.unread:
            continue
        m = re.search(r"\\label\s*\{\s*" + re.escape(label) + r"\s*\}", _clean(text))
        span = m and comments.box_env(text, m.start(), m.end())
        if span:
            return ("changed", file) + span + ("label", LABEL_CONFIDENCE)
    return None


def _is_word(tok):
    return any(c.isalnum() for c in tok[0])


def _by_diff(diff, file, start, end, sent):
    """(state, file, start, end, method, confidence[, hunk to attach]) by the diff rules, or None if the range cannot
    be mapped."""
    old = diff.old_texts[file]
    confidence = diff.kept_ratio(file, *texdiff.paragraph(old, start, end))
    toks = [t for t in diff.tokens_in(file, start, end) if t[0] != texdiff.PAR]
    words = [t for t in toks if _is_word(t)]
    touching = any(h["kind"] != "move" and not texdiff.break_only(h) for h in diff.hunks_touching(file, *sent)) \
        or _inserted_before(diff, file, sent[0])
    if words and all(t[3] and t[3]["kind"] == "delete" for t in words):
        sent_toks = [t for t in diff.tokens_in(file, *sent) if t[0] != texdiff.PAR]
        found = _reinserted(diff, sent_toks, toks)
        if len(found) == 1:  # a move too short for texdiff (or one next to an edit): the text is there verbatim
            (nf, ns, ne, h), = found
            return "moved", nf, ns, ne, "exact", EXACT_CONFIDENCE, h
        point = diff.map_offset(file, start, "left")
        if point is None:
            return None
        if found or _near_reinserted(diff, toks):
            confidence = min(confidence, GUESSED)  # it may have been moved and edited
        return ("gone",) + point + (point[1], "diff", confidence)
    if end == start:  # a gone comment carried again stays gone unless its point was edited
        state = "changed" if touching else "gone"
    elif touching:
        state = "changed"
    elif words and all(t[3] and t[3]["kind"] == "move" for t in words):
        state = "moved"
    else:
        state = "unchanged"
    # A point (a gone comment carried again) sits right after a token: map it with that token.
    first, last = diff.map_offset(file, start, "left" if end > start else "right"), diff.map_offset(file, end, "right")
    if first is None or last is None or first[0] != last[0] or first[1] > last[1]:
        return None
    (nf, ns), ne = first, last[1]
    new, added = diff.new_texts[nf], 0
    for h in diff.hunks_touching(file, start, end):
        hs, he = h["new_start"], h["new_end"]
        if h["kind"] == "move" or h["new_file"] != nf or (hs > ne and new[ne:hs].strip()) \
                or (he < ns and new[he:ns].strip()):
            continue  # only hunks whose new side is inside the range or next to it
        ns, ne = min(ns, hs), max(ne, he)
        added += _count(diff.new_tokens[nf], hs, he)
    if _count(diff.new_tokens[nf], ns, ne) > 2 * (len(toks) + added) + 8:
        return None  # the ends were mapped far apart (split by a move): look for the quote instead
    return state, nf, ns, ne, "diff", confidence


def _count(toks, start, end):
    """The number of tokens that start in [start, end)."""
    return bisect.bisect_left(toks.starts, end) - bisect.bisect_left(toks.starts, start)


def _hunk_tokens(diff, h):
    """The new side of a hunk as (new Tokens, [token index]) without paragraph breaks."""
    nt = diff.new_tokens[h["new_file"]]
    j1, j2 = bisect.bisect_left(nt.starts, h["new_start"]), bisect.bisect_left(nt.starts, h["new_end"])
    return nt, [j for j in range(j1, j2) if nt.texts[j] != texdiff.PAR]


def _reinserted(diff, sent_toks, toks):
    """[(new file, start, end, hunk)] for each place where a deleted range was inserted again verbatim. When its whole
    sentence was deleted, the sentence is looked for, so a short range is found by its context; at least 3 words."""
    seq = sent_toks if all(t[3] and t[3]["kind"] == "delete" for t in sent_toks if _is_word(t)) else toks
    texts, k0 = [t[0] for t in seq], seq.index(toks[0])
    if sum(map(_is_word, seq)) < 3:
        return []
    found = []
    for h in diff.hunks:
        if h["kind"] not in ("insert", "replace") or h["new_file"] is None:
            continue
        nt, idx = _hunk_tokens(diff, h)
        tt = [nt.texts[j] for j in idx]
        for k in range(len(tt) - len(texts) + 1):
            if tt[k:k + len(texts)] == texts:
                found.append((h["new_file"], nt.starts[idx[k + k0]], nt.ends[idx[k + k0 + len(toks) - 1]], h))
    return found


def _near_reinserted(diff, toks):
    """Whether at least half of a deleted range (3 tokens or more) was inserted again as one run."""
    texts = [t[0] for t in toks]
    need = max(3, (len(texts) + 1) // 2)
    for h in diff.hunks:
        if h["kind"] in ("insert", "replace") and h["new_file"] is not None:
            nt, idx = _hunk_tokens(diff, h)
            tt = [nt.texts[j] for j in idx]
            if difflib.SequenceMatcher(None, texts, tt, autojunk=False).find_longest_match(
                    0, len(texts), 0, len(tt)).size >= need:
                return True
    return False


def _search(diff, last, fuzzy=True):
    """(state, file, start, end, method, confidence) for the last known quote found in the new tree's files that
    its build reads (with fuzzy, also a near match), or None. A paragraph break inside the quote is one in the file
    too (Tokens holds them only between tokens, never at the ends)."""
    if not last or not (last.get("quote") or "").strip():
        return None
    quote = texdiff.Tokens(last["quote"]).texts
    if not quote:
        return None
    pre = texdiff.Tokens(last.get("prefix") or "").texts
    suf = texdiff.Tokens(last.get("suffix") or "").texts
    exact = []
    for f, toks in diff.new_tokens.items():
        if f in diff.unread:
            continue
        t = toks.texts
        for k in range(len(t) - len(quote) + 1):
            if t[k] == quote[0] and t[k:k + len(quote)] == quote:
                score = _common_len(reversed(pre), reversed(t[:k])) + _common_len(suf, t[k + len(quote):])
                exact.append((score, f, k))
    if exact:
        exact.sort(key=lambda x: -x[0])
        if len(exact) > 1 and exact[0][0] == exact[1][0]:
            return None  # the quote occurs in several equally likely places
        _, f, k = exact[0]
        toks = diff.new_tokens[f]
        return ("moved", f, toks.starts[k], toks.ends[k + len(quote) - 1], "exact", EXACT_CONFIDENCE)
    best = _fuzzy(diff, quote) if fuzzy else None
    if best is None:
        return None
    ratio, f, k1, k2 = best
    toks = diff.new_tokens[f]
    return "changed", f, toks.starts[k1], toks.ends[k2 - 1], "fuzzy", ratio


def _common_len(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def _fuzzy(diff, quote, top=5):
    """(ratio, file, k1, k2) of the best token window for quote with ratio >= FUZZY_MIN, or None (also if two
    different places score the same)."""
    found = []
    for f, toks in diff.new_tokens.items():
        if f in diff.unread:
            continue
        t = toks.texts
        where = {}
        for k, tok in enumerate(t):
            where.setdefault(tok, []).append(k)
        votes = Counter()
        for qi, tok in enumerate(quote):
            for k in where.get(tok, ())[:500]:
                votes[k - qi] += 1
        slack = len(quote) // 2 + 2
        for c, _ in votes.most_common(top):
            lo = max(0, c - slack)
            window = t[lo:c + len(quote) + slack]
            blocks = [b for b in difflib.SequenceMatcher(None, quote, window, autojunk=False).get_matching_blocks() if b.size]
            if not blocks:
                continue
            k1, k2 = lo + blocks[0].b, lo + blocks[-1].b + blocks[-1].size
            ratio = 2 * sum(b.size for b in blocks) / (len(quote) + k2 - k1)
            found.append((ratio, f, k1, k2))
    found.sort(key=lambda x: -x[0])
    if not found or found[0][0] < FUZZY_MIN:
        return None
    best = found[0]
    for other in found[1:]:
        if other[0] < best[0]:
            break
        if other[1] != best[1] or other[2] >= best[3] or other[3] <= best[2]:
            return None  # an equally good match elsewhere
    return best


def shadows(diff, items):
    """Where comments closed in earlier rounds are in the new tree, worked out from the source alone (no PDF), and which
    hunks edit their sentences (the Changes tab's hint "near a closed comment", so the advisor can reopen one the
    student broke). items: [{"id", "anchor"}], an anchor in the old tree (its file, start, end, quote, prefix and
    suffix). Returns ({id: {"file", "start", "end", "lines", "quote", "prefix", "suffix"}}, [[ids] per hunk, in
    diff.hunks' order]). A range is carried by the diff rules (_by_diff), else found by its quote verbatim; one whose
    words were all deleted, or that is found nowhere, is not carried further. A hunk is near a closed comment when it
    edits (not a move, nor only a paragraph break) the comment's sentence, as carry attaches one to an open comment."""
    placed, ranges = {}, {}
    for item in items:
        a = _in_tree(diff.old_texts, item.get("anchor")) or {}
        old = diff.old_texts.get(a.get("file"))
        if old is None or a.get("start") is None:
            continue
        sent = texdiff.sentence(old, a["start"], a["end"])
        ranges[item["id"]] = (a["file"], sent, _inserted_before(diff, a["file"], sent[0]))
        found = _by_diff(diff, a["file"], a["start"], a["end"], sent)
        if found is not None and found[1] in diff.unread:
            found = None
        found = found or _search(diff, a, fuzzy=False)
        if found is None or found[0] == "gone":
            continue
        _, file, start, end = found[:4]
        placed[item["id"]] = {k: v for k, v in _anchor(diff.new_texts[file], file, start, end, None, [], "").items()
                              if k not in ("page", "rects", "text")}
    near = []
    for h in diff.hunks:
        edit = h["kind"] != "move" and not texdiff.break_only(h)
        near.append(sorted((cid for cid, (f, (ss, se), before) in ranges.items()
                            if edit and (f == h["old_file"] and h["old_start"] <= se and h["old_end"] >= ss
                                         or any(x is h for x in before))), key=ledger.id_key))
    return placed, near


def _changes(src, pdf, diff, ranges, extra):
    """One Change per hunk (CONTRACT.md §8), attached to the carried comments whose sentence it touches (for a move,
    or a paragraph break put in or taken out, whose range it overlaps), and to those whose text it inserted again
    (`extra`: id -> hunks)."""
    changes = []
    before = {cid: _inserted_before(diff, f, ss) for cid, (f, _, _, (ss, _)) in ranges.items()}
    for k, h in enumerate(diff.hunks, 1):
        if h["kind"] == "move" or texdiff.break_only(h):
            att = [cid for cid, (f, s, e, _) in ranges.items()
                   if f == h["old_file"] and h["old_start"] < max(e, s + 1) and s < h["old_end"]]
        else:
            att = [cid for cid, (f, _, _, (ss, se)) in ranges.items()
                   if f == h["old_file"] and h["old_start"] <= se and h["old_end"] >= ss
                   or h["kind"] == "insert" and any(x is h for x in before[cid])]
        att += [cid for cid, hs in extra.items() if any(x is h for x in hs) and cid not in att]
        nf = h["new_file"]
        if nf is not None:
            included = _included(diff, h)
            page, rects, _ = _start_of(src, pdf, diff, included) if included else (None, [], "") \
                if _only_includes(diff, h, "old" if h["kind"] == "delete" else "new") else \
                to_pdf(src, pdf, nf, h["new_start"], h["new_end"])
            line = _line_of(diff.new_texts[nf], h["new_start"])
        else:
            page, rects, line = None, [], None
        changes.append(dict({"id": f"c{k:02d}", "kind": h["kind"], "file": nf or h["old_file"], "line": line,
                             "old_text": " ".join(h["old_text"].split()), "new_text": " ".join(h["new_text"].split()),
                             "page": page, "rects": rects, "attached_to": sorted(att, key=ledger.id_key),
                             "unrequested": not att}, **({"figure": h["figure"]} if "figure" in h else {})))
    return changes


def _only_includes(diff, h, side):
    """Whether one side ("old", "new") of a hunk holds only (parts of) \\input or \\include commands and space, the
    whole commands taken (texdiff.reads: a hunk can start inside one, "b} \\input{sections/")."""
    f = h[side + "_file"]
    if f is None or h[side + "_end"] <= h[side + "_start"]:
        return False
    files, only = texdiff.reads(diff.old_texts if side == "old" else diff.new_texts, f, h[side + "_start"],
                                h[side + "_end"])
    return bool(files) and only


def _included(diff, h):
    """The new tree's file that a hunk's \\input or \\include reads: for (parts of) whole commands inserted, moved or
    edited, the first of them (texdiff.reads); for whole commands deleted, the one that now holds or follows the
    deletion point with nothing between. None otherwise (an \\input prints nothing where it stands)."""
    file, start, end = h["new_file"], h["new_start"], h["new_end"]
    news, only = texdiff.reads(diff.new_texts, file, start, end)
    if h["kind"] == "delete":
        if not _only_includes(diff, h, "old"):
            return None
        if not news:
            clean = _clean(diff.new_texts[file])
            m = INCLUDE.search(clean, end)
            news = [texdiff.include_file(m, diff.new_texts)] if m and not clean[end:m.start()].strip() else []
    elif not (news and only):
        return None
    return next((f for f in news if f in diff.new_texts), None)


def _end_of(src, pdf, diff, file):
    """(page, [point], "") just after the last word of the last line of a file that prints letters, or
    (None, [], "")."""
    text = diff.new_texts[file]
    chars = _src_chars(text, 0, len(text))
    if not chars:
        return None, [], ""
    page, rects, _ = to_pdf(src, pdf, file, *_line_span(text, _line_of(text, chars[-1][1])))
    if not rects:
        return None, [], ""
    r = rects[-1]
    return page, [[r[2], r[1], round(r[2] + POINT_WIDTH, 2), r[3]]], ""


def _start_of(src, pdf, diff, file):
    """(page, [point], "") at the start of the first line of a file that prints letters, or (None, [], "")."""
    toks = diff.new_tokens[file]
    first = next((s for t, s in zip(toks.texts, toks.starts) if t[0].isalnum()), None)
    if first is None:
        return None, [], ""
    text = diff.new_texts[file]
    page, rects, _ = to_pdf(src, pdf, file, *_line_span(text, _line_of(text, first)))
    if not rects:
        return None, [], ""
    r = rects[0]
    return page, [[r[0], r[1], round(r[0] + POINT_WIDTH, 2), r[3]]], ""
