"""A round's link table for reference previews (design/pdf-reader/PLAN.md §4.5; CONTRACT.md amendment "Reference
previews").

For each reference the round's build PDF prints, where it is and what it points to: a figure, table, algorithm,
formula, section, theorem, bibliography entry, footnote or URL, with the target's place in the PDF from prose.json's
blocks (the whole float, not hyperref's point above its caption), or a label or citation the round does not define.
Two sources, in order: hyperref's links (PyMuPDF reads each link's rect and named destination), then the \\ref,
\\cref, \\eqref, \\cite… and \\url marks of prose.json's blocks, whose printed words are found among the PDF words
of the block's parts (without hyperref, and for "??" and "[?]", which hyperref leaves unlinked). `build` writes
rN/links.json, a cache outside the round's checksums, as prose.json is; a file with another LINKS or prose.PARSER is
stale. The table is a convenience: building it never fails a request (build_quietly), and without it the app follows
a link as PDFKit does.
"""
import bisect
import functools
import json
import os
import re
import sys
import traceback
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

from . import anchor, comments, prose, texdiff

# stored in links.json, with prose.PARSER (the blocks' indices); a file with other values is stale
LINKS = 1
SCHEMA = 1
BELOW = 12.0  # points: a destination at most this far above a block's top is that block's (section.4 above "4 …")
MERGE = 20.0  # points: a link rect on the next line at most this far down continues the last one (a broken reference)
LINES = 6  # lines of text a section's or a theorem's target holds below its first line
NOTE_LINES = 8  # at most this many lines for a target found from its destination alone (a footnote, a biblatex entry)
RAISED = 3.0  # points: a word's top at most this far above a destination's point is on the destination's first line
SCHEMES = ("http:", "https:", "mailto:")  # the URLs a target may carry; a link to any other (javascript:) is left out

# a destination's prefix (figure.1), cleveref type or label prefix (fig:x), lower case -> (kind, the title's noun)
_THEOREMS = {"theorem": "Theorem", "thm": "Theorem", "lemma": "Lemma", "lem": "Lemma", "proposition": "Proposition",
             "prop": "Proposition", "corollary": "Corollary", "cor": "Corollary", "definition": "Definition",
             "def": "Definition", "defn": "Definition", "remark": "Remark", "rem": "Remark", "example": "Example",
             "assumption": "Assumption", "claim": "Claim", "conjecture": "Conjecture", "hypothesis": "Hypothesis",
             "observation": "Observation", "fact": "Fact", "problem": "Problem", "property": "Property"}
TYPES = dict({w: ("figure", "Figure") for w in ("figure", "subfigure", "fig")},
             **{w: ("table", "Table") for w in ("table", "subtable", "tab", "tbl")},
             **{w: ("algorithm", "Algorithm") for w in ("algorithm", "algocf", "alg", "algo")},
             **{w: ("equation", "Equation") for w in ("equation", "eq", "eqn", "ams")},
             **{w: ("section", "Section") for w in ("section", "subsection", "subsubsection", "paragraph",
                                                     "subparagraph", "sec", "subsec", "ssec")},
             **{w: ("section", "Chapter") for w in ("chapter", "chap", "ch")},
             **{w: ("appendix", "Appendix") for w in ("appendix", "subappendix", "subsubappendix", "app", "appx")},
             **{w: ("theorem", noun) for w, noun in _THEOREMS.items()},
             **{w: ("footnote", "Footnote") for w in ("hfootnote", "footnote", "fn")},
             **{w: ("other", "Listing") for w in ("lstlisting", "listing", "lst")},
             **{w: ("other", "Item") for w in ("item", "enumi")},
             part=("section", "Part"))
# a target block's kind, when nothing above names one
BLOCK_KINDS = {"figure": "figure", "picture": "figure", "table": "table", "math": "equation", "heading": "section",
               "bibitem": "cite"}
NOUNS = {"figure": "Figure", "table": "Table", "algorithm": "Algorithm", "equation": "Equation", "section": "Section",
         "appendix": "Appendix"}
LABEL = re.compile(r"\\label\s*\{([^{}]*)\}")
FLOAT_NUMBER = re.compile(r"(?:Figure|Table|Algorithm)\s+(\S+?):")  # a float block's text: "Figure 3: …"
LINK_GOTO, LINK_URI, LINK_NAMED = 1, 2, 4  # PyMuPDF's link kinds


def path(paper, n):
    return Path(paper) / "r{}".format(n) / "links.json"


def load(paper, n):
    """Round n's links.json when it exists and is current (cached by path and modification time), else None."""
    p = path(paper, n)
    try:
        st = p.stat()
    except OSError:
        return None
    data = _load(str(p), st.st_mtime_ns, st.st_size)
    current = isinstance(data, dict) and data.get("schema") == SCHEMA and data.get("version") == LINKS \
        and data.get("parser") == prose.PARSER and isinstance(data.get("links"), list) \
        and isinstance(data.get("targets"), list)
    return data if current else None


@functools.lru_cache(maxsize=8)
def _load(p, mtime, size):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def build(paper, lg, n, data):
    """Build round n's links.json from its build PDF and prose data (prose.json's) and return it."""
    paper = Path(paper)
    rnd = prose._round(lg, n)
    pdf = paper / rnd["build"]["pdf"]
    table = _Table(paper / "r{}".format(n) / "src", pdf, Path(lg["paper"]["main"]).stem, data["blocks"],
                   rnd["build"].get("columns")).run()
    out = dict({"schema": SCHEMA, "version": LINKS, "parser": prose.PARSER, "round": n}, **table)
    p = path(paper, n)
    tmp = p.with_name("links.json.{}.tmp".format(os.getpid()))  # two engine processes may build it at once
    tmp.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, p)
    return out


_FAILED = set()  # the builds that failed in this process (_attempt)


def _attempt(paper, lg, n):
    """A build's key: round n's table, its build PDF and prose.json, as they are now."""
    def stamp(p):
        try:
            st = os.stat(p)
            return st.st_mtime_ns, st.st_size
        except OSError:
            return None
    return str(path(paper, n)), stamp(Path(paper) / prose._round(lg, n)["build"]["pdf"]), stamp(prose.path(paper, n))


def build_quietly(paper, lg, n, data):
    """build, or None when it fails (the traceback on stderr): previews are a convenience, nothing depends on them.
    A failure is not tried again in this process until the round's PDF or prose.json changes (every links call
    would otherwise build it again, the RPC queue waiting)."""
    key = None
    try:
        key = _attempt(paper, lg, n)
        if key in _FAILED:
            return None
        return build(paper, lg, n, data)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        if key is not None:
            _FAILED.add(key)
        return None


# --- the table -------------------------------------------------------------------------------------------------

def _norm(word):
    """A word as compared between prose's display text and the PDF: letters and digits (and ?) only, accents and
    case dropped ("Rozi`ere" and "Rozière", "(3)." and "3")."""
    return "".join(c for c in unicodedata.normalize("NFKD", word) if c.isalnum() or c == "?").lower()


def _rect(r):
    return [round(float(v), 2) for v in r]


def _overlap(a, b):
    return min(a[2], b[2]) - max(a[0], b[0]) > 0.5 and min(a[3], b[3]) - max(a[1], b[1]) > 0.5


def _kind_of(word):
    return TYPES.get((word or "").lower(), (None,))[0]


def _openable(uri):
    return uri.strip().lower().startswith(SCHEMES)


def _anchors(build_dir, stem):
    """{label: hyperref anchor (figure.1)} from the build's .aux files (\\newlabel's fourth group)."""
    out, seen = {}, set()

    def read(p):
        if p in seen or not p.is_file():
            return
        seen.add(p)
        t = p.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"\\newlabel\{([^{}]*)\}\{", t):
            g = prose._groups(t[m.end():prose._group_end(t, m.end() - 1, len(t)) - 1])
            if len(g) >= 4 and g[3].strip() and not m.group(1).endswith("@cref"):
                out.setdefault(m.group(1), g[3].strip())
        for m in re.finditer(r"\\@input\{([^{}]*)\}", t):
            read(Path(build_dir) / m.group(1))
    read(Path(build_dir) / (stem + ".aux"))
    return out


class _Table:
    """Builds the link table of one round (build PDF, src, the round's prose blocks)."""

    def __init__(self, src, pdf, stem, blocks, columns):
        self.src, self.pdf, self.blocks, self.columns = Path(src), Path(pdf), blocks, columns or []
        self.stamp = anchor._stamp(self.pdf)
        self.doc = anchor._doc(self.stamp)
        self.cites, self.labels, self.types = prose._aux(self.pdf.parent, stem)
        self.anchors = _anchors(self.pdf.parent, stem)
        self.by_anchor = {}  # anchor: its labels (subcaption's figure.caption.2: the figure's and its subfigures')
        for label, a in self.anchors.items():
            self.by_anchor.setdefault(a, []).append(label)
        self.ctx = prose._Ctx({}, (self.cites, self.labels, self.types), False)
        self.texts = {}
        self.of_label, self.of_key = self._label_blocks(), self._bib_blocks()
        self.targets, self.index, self.links, self.failures = [], {}, [], 0
        self.stops = {}  # (page, kind): the y of the destinations there, where a footnote's or entry's lines end
        self.indexed = {}  # page: its words, and their centres' y sorted (_index)
        self.pages = self.doc.page_count
        self.sizes = {}  # page: its rect (_size)

    # -- sources

    def _text(self, file):
        """A source file's text with its comments blanked (same offsets), or None."""
        if file not in self.texts:
            p = comments.source_path(self.src, self.pdf, file)
            try:
                self.texts[file] = texdiff.blank_comments(p.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                self.texts[file] = None
        return self.texts[file]

    def _label_blocks(self):
        """{label: index of the block that holds its \\label}: the block whose range holds it; else the block just
        before it when only white space and labels lie between (a \\label on the line after \\section), else the
        next block of its file; a label in a file a float \\inputs is that float's."""
        by_file, inputs = {}, {}
        for k, b in enumerate(self.blocks):
            if b["kind"] in ("deleted", "missing") or b.get("start") is None:
                continue
            by_file.setdefault(b["file"], []).append(k)
            for f in b.get("inputs", ()):
                inputs.setdefault(f, k)
        out = {}
        for f in list(by_file) + [f for f in inputs if f not in by_file]:
            t = self._text(f)
            if t is None:
                continue
            ks = sorted(by_file.get(f, ()), key=lambda k: self.blocks[k]["start"])
            starts = [self.blocks[k]["start"] for k in ks]
            for m in LABEL.finditer(t):
                name, pos = m.group(1).strip(), m.start()
                if name in out:
                    continue
                if not ks:
                    out[name] = inputs.get(f)
                    continue
                i = bisect.bisect_right(starts, pos) - 1  # the last block of the file starting at or before it
                before, after = (ks[i] if i >= 0 else None), (ks[i + 1] if i + 1 < len(ks) else None)
                if before is not None and pos < self.blocks[before]["end"]:
                    out[name] = before
                elif before is not None and not LABEL.sub("", t[self.blocks[before]["end"]:pos]).strip():
                    out[name] = before
                else:
                    out[name] = after if after is not None else before
        return {k: v for k, v in out.items() if v is not None}

    def _bib_blocks(self):
        """{citation key: index of its bibitem block}."""
        out = {}
        for k, b in enumerate(self.blocks):
            if b["kind"] != "bibitem" or b.get("start") is None:
                continue
            t = self._text(b["file"])
            if t is None or not t.startswith("\\bibitem", b["start"]):
                continue
            j, e = b["start"] + len("\\bibitem"), b["end"]
            o = re.match(r"\s*\[", t[j:e])
            if o:
                j = prose._bracket_end(t, j + o.end() - 1, e)
            o = re.match(r"\s*\{([^{}]*)\}", t[j:e])
            if o:
                out.setdefault(o.group(1).strip(), k)
        return out

    # -- places

    def _index(self, page):
        """(the page's words in reading order, [(centre y, index)] sorted, the centres' y alone) for bisecting."""
        if page not in self.indexed:
            words = anchor._words(self.stamp, page)
            ys = sorted(((w[1] + w[3]) / 2, i) for i, w in enumerate(words))
            self.indexed[page] = words, ys, [y for y, _ in ys]
        return self.indexed[page]

    def _words_in(self, page, rects, pad=1.0):
        """The page's words whose centre lies in one of the rects (pad points around), in reading order."""
        words, ys, keys = self._index(page)
        found = set()
        for r in rects:
            for _, i in ys[bisect.bisect_left(keys, r[1] - pad):bisect.bisect_right(keys, r[3] + pad)]:
                if r[0] - pad <= (words[i][0] + words[i][2]) / 2 <= r[2] + pad:
                    found.add(i)
        return [words[i] for i in sorted(found)]

    def _size(self, page):
        if page not in self.sizes:
            self.sizes[page] = self.doc[page].rect
        return self.sizes[page]

    def _gap(self, page):
        """The x between the page's two text columns, or None (comments.columns)."""
        return self.columns[page][0] if page < len(self.columns) and self.columns[page] else None

    def _alone(self, page, r, after):
        """Whether no word of rect r's column lies on its line after it (after) or before it."""
        words, ys, keys = self._index(page)
        gap, mid = self._gap(page), (r[0] + r[2]) / 2
        for _, i in ys[bisect.bisect_left(keys, r[1]):bisect.bisect_right(keys, r[3])]:
            cx = (words[i][0] + words[i][2]) / 2
            if gap is not None and (cx < gap) != (mid < gap):
                continue
            if (cx > r[2] + 0.5) if after else (cx < r[0] - 0.5):
                return False
        return True

    def _joins(self, page, a, b):
        """Whether link rect b continues rect a, as one reference: on the same line just after it, or on the next
        line when a ends its line and b starts its own (natbib's "(Chen et al.," and "2021;" broken across lines,
        not a second reference to the same target on the next line)."""
        if abs(a[1] - b[1]) < 2:
            return 0 <= b[0] - a[2] <= 30
        return 0 < b[1] - a[1] <= MERGE and self._alone(page, a, True) and self._alone(page, b, False)

    def _rows(self, page, x0, x1, top, bottom=None, point=False):
        """The page's text lines from top down, of the words whose centre lies across x0..x1: [rect], one a line,
        stopping before a gap of more than two lines (or past bottom). Words reaching below top; with point (a
        destination's point, raised above its first line), words whose top is at most RAISED above it, so not the
        line before (the previous footnote's last line)."""
        words = sorted((w for w in anchor._words(self.stamp, page) if x0 - 1 <= (w[0] + w[2]) / 2 <= x1 + 1 and
                        (w[1] >= top - RAISED if point else w[3] >= top + 1)), key=lambda w: (w[1], w[0]))
        rows = []
        for w in words:
            cy = (w[1] + w[3]) / 2
            if rows and rows[-1][1] - 1 <= cy <= rows[-1][3] + 1:
                r = rows[-1]
                rows[-1] = [min(r[0], w[0]), min(r[1], w[1]), max(r[2], w[2]), max(r[3], w[3])]
            else:
                if rows and w[1] - rows[-1][3] > 2 * max(rows[-1][3] - rows[-1][1], 6):
                    break
                if bottom is not None and cy > bottom + 1:
                    break
                rows.append(list(w[:4]))
        return rows

    def _union(self, rows):
        return _rect([min(r[0] for r in rows), min(r[1] for r in rows), max(r[2] for r in rows),
                      max(r[3] for r in rows)])

    def _lines(self, page, rect, extra, bottom=None):
        """rect widened down to `extra` more text lines of its column (a section's heading and the lines after it)."""
        rows = self._rows(page, rect[0], rect[2], rect[1], bottom)
        own = [r for r in rows if (r[1] + r[3]) / 2 <= rect[3] + 1] or rows[:1]
        rows = rows[:len(own) + extra]
        return self._union(rows + [rect]) if rows else _rect(rect)

    def _from_point(self, page, x, y, stops):
        """The rect of the text lines that start at a destination point (a footnote, a biblatex entry), up to the next
        such point on the page (stops: their y), at most NOTE_LINES lines, in the point's column."""
        width = self._size(page).width
        gap = self._gap(page)
        x1 = gap if gap is not None and x < gap else width
        stop = min((s for s in stops if s > y + 1), default=None)
        rows = self._rows(page, x - 15, x1, y, stop - 1 if stop is not None else None, point=True)[:NOTE_LINES]
        return self._union(rows) if rows else None

    def _place(self, kind, k):
        """(page, box, parts) of block k as the target of a link of `kind`, or None: a float, formula or listing's
        box; a section's heading and LINES lines after it; a theorem's first lines; otherwise its parts."""
        b = self.blocks[k]
        parts = [b["box"]] if b.get("box") else [p for p in b.get("parts") or () if p]
        if not parts:
            return None
        page, rect = parts[0][0], parts[0][1]
        if b["kind"] == "heading" or kind in ("section", "appendix"):
            parts = [[page, self._lines(page, rect, LINES)]]
        elif kind == "theorem" and b["kind"] not in prose.IMAGE_KINDS:
            parts = [[page, self._lines(page, [rect[0], rect[1], rect[2], rect[1]], LINES, rect[3])]]
        parts = [[p, _rect(r)] for p, r in parts]
        return parts[0][0], parts[0][1], parts

    def _block_at(self, page, x, y, kind=None):
        """The block whose part on the page holds the point (by its height; x only between blocks level with it) or
        starts at most BELOW points below it; one of the expected kind first."""
        best = None
        for k, b in enumerate(self.blocks):
            if b["kind"] in ("deleted", "missing", "title"):
                continue
            for p, r in ([b["box"]] if b.get("box") else b.get("parts") or ()):
                if p != page:
                    continue
                if r[1] - 1 <= y <= r[3] + 1:
                    d = 0.0
                elif 0 <= r[1] - y <= BELOW:
                    d = r[1] - y
                else:
                    continue
                dx = 0.0 if r[0] - 1 <= x <= r[2] + 1 else min(abs(x - r[0]), abs(x - r[2]))
                score = (kind is not None and BLOCK_KINDS.get(b["kind"]) != kind, d, dx, k)
                best = min(best, score) if best else score
        return best[-1] if best else None

    # -- targets

    def _target(self, key, make):
        if key not in self.index:
            t = dict({"kind": "other", "label": "", "key": None, "page": None, "box": None, "parts": [],
                      "block": None, "at": None, "url": None, "note": None, "cited": [], "count": 0}, **make())
            self.index[key] = len(self.targets)
            self.targets.append(t)
        return self.index[key]

    def _plain(self, tex):
        return " ".join(self.ctx.plain(tex).split())

    def _kind(self, words, block):
        """(kind, noun) from the first of the words that names one (a destination's prefix, a cleveref type, a
        label's prefix), else from the target block's kind."""
        for w in words:
            if w and w.lower() in TYPES:
                return TYPES[w.lower()]
        kind = BLOCK_KINDS.get(block["kind"]) if block else None
        if block and block["kind"] == "heading" and re.fullmatch(r"[A-Z]", block.get("number") or ""):
            kind = "appendix"
        if block and block["kind"] == "code" and block.get("text", "").startswith("Algorithm"):
            kind = "algorithm"
        return (kind, NOUNS.get(kind)) if kind else ("other", None)

    def _title(self, kind, noun, number, text=""):
        if number and kind == "equation":
            return "Equation ({})".format(number.strip("()"))
        if number and noun:
            return "{} {}".format(noun, number)
        return noun or number or " ".join(text.split()).strip(" ,;.") or kind.capitalize()

    def _number(self, block):
        """A target block's printed number, from itself: a heading's, a float's caption's."""
        if not block:
            return None
        if block["kind"] == "heading":
            return block.get("number")
        m = FLOAT_NUMBER.match(block.get("text") or "")
        return m.group(1) if m else None

    def label_target(self, label, prefix=None, point=None, text=""):
        """The target of a \\label (from a reference or a hyperref anchor); kind "missing" when the round's .aux has
        no such label."""
        if label not in self.labels and point is None:
            return self._target(("missing", "ref", label), lambda: {
                "kind": "missing", "label": "Undefined reference", "key": label,
                "note": "No \\label{{{}}} in this round's source.".format(label)})
        if "\\caption@xref" in (self.labels.get(label) or [""])[0]:  # the caption package's "??"
            return self._target(("missing", "ref", label), lambda: {
                "kind": "missing", "label": "Undefined reference", "key": label,
                "note": "\\label{{{}}} comes before \\caption, so it names no number.".format(label)})

        def make():
            k = self.of_label.get(label)
            b = self.blocks[k] if k is not None else None
            words = [prefix or self.anchors.get(label, "").split(".")[0], self.types.get(label),
                     label.split(":")[0] if ":" in label else None]
            if _kind_of(words[0]) == "theorem":  # a lemma on the theorem counter: theorem.2, so cleveref's noun first
                words = [w for w in words[1:] if _kind_of(w) == "theorem"] + words[:1]
            kind, noun = self._kind(words, b)
            number = self._plain(self.labels[label][0]) if label in self.labels else self._number(b)
            t = {"kind": kind, "label": self._title(kind, noun, number, text), "key": label, "block": k,
                 "at": [point[1], point[2]] if point else None}
            place = self._place(kind, k) if k is not None else None
            if place:
                t.update(page=place[0], box=place[1], parts=place[2])
            elif point:
                t.update(self._point_place(point, kind))
            return t
        return self._target(("label", label), make)

    def cite_target(self, key, point=None, stops=()):
        """The target of a citation key: its bibitem block; with only a destination (biblatex), the lines there;
        kind "missing" when the round defines no such key."""
        if key not in self.cites and key not in self.of_key and point is None:
            return self._target(("missing", "cite", key), lambda: {
                "kind": "missing", "label": "Undefined citation", "key": key,
                "note": "No \\bibitem{{{}}} in this round's references.".format(key)})

        def make():
            k = self.of_key.get(key)
            c = self.cites.get(key)
            label = "{}, {}".format(self._plain(c[2]), self._plain(c[1])) if c and c[1] is not None and c[2] \
                else "[{}]".format(self._plain(c[0])) if c else key
            t = {"kind": "cite", "label": label, "key": key, "block": k, "at": [point[1], point[2]] if point else None}
            place = self._place("cite", k) if k is not None else None
            if place:
                t.update(page=place[0], box=place[1], parts=place[2])
            elif point:
                t["page"] = point[0]
                box = self._from_point(point[0], point[1], point[2], stops)
                if box:
                    t.update(box=box, parts=[[point[0], box]])
            return t
        return self._target(("cite", key), make)

    def _point_place(self, point, kind):
        """The place of a target known only by its destination: the block there, else the lines there."""
        page, x, y = point
        out = {"page": page, "at": [x, y]}
        k = self._block_at(page, x, y, kind)
        place = self._place(kind, k) if k is not None and kind != "footnote" else None
        if place:
            out.update(block=k, page=place[0], box=place[1], parts=place[2])
        else:
            box = self._from_point(page, x, y, self.stops.get((page, kind), ()))
            if box:
                out.update(box=box, parts=[[page, box]])
        return out

    def dest_target(self, name, point, text):
        """The target of a hyperref named destination."""
        if name.startswith("cite."):
            key = re.sub(r"^\d+@", "", name[5:])  # biblatex: cite.0@key
            return self.cite_target(key, point, self.stops.get((point[0], "cite"), ()))
        if name in self.by_anchor:
            return self.label_target(self._named(name, text), name.split(".")[0], point, text)
        return self.point_target(("dest", name), point, text, name)

    def _named(self, name, text):
        """The label of an anchor; of several (a figure's and its subfigures'), the one whose number the link prints
        ("2b", "fig. 2b"), else the first."""
        labels = self.by_anchor[name]
        if len(labels) > 1:
            printed = _norm(text)
            numbers = [(label, _norm(self._plain(self.labels[label][0]))) for label in labels if label in self.labels]
            for match in (lambda n: n == printed, lambda n: printed.endswith(n)):
                label = next((label for label, n in numbers if n and match(n)), None)
                if label:
                    return label
        return labels[0]

    def point_target(self, key, point, text, name=""):
        """The target of a destination no label names (a section without \\label, a footnote, a page): the block at
        its point, its kind from the destination's prefix, else from the block."""
        def make():
            kind, noun = self._kind([name.split(".")[0]], None)
            t = {"kind": kind, "key": None}
            t.update(self._point_place(point, kind))
            b = self.blocks[t["block"]] if t.get("block") is not None else None
            if kind == "other" and b:
                kind, noun = self._kind([], b)
                t["kind"] = kind
            number = self._number(b) or (name.split(".", 1)[1] if "." in name and kind == "footnote" else None)
            t["label"] = self._title(kind, noun, number, text)
            return t
        return self._target(key, make)

    # -- links

    def _destination(self, link):
        """(key, point) of a PyMuPDF link: ("named", name), ("goto", page) or ("uri", uri); point (page, x, y) in
        top-left coordinates (a named destination's point is PDF space, y up), or None."""
        kind = link.get("kind")
        page, to = link.get("page", -1), link.get("to")
        point = None
        if isinstance(page, int) and 0 <= page < self.pages and to is not None:
            x, y = float(to[0]), float(to[1])
            if kind == LINK_NAMED:
                y = self._size(page).height - y
            point = (page, round(x, 2), round(y, 2))
        if kind == LINK_NAMED and (link.get("nameddest") or link.get("name")) and point:
            return ("named", link.get("nameddest") or link.get("name")), point
        if kind == LINK_GOTO and point:
            return ("goto", point), point
        if kind == LINK_URI and link.get("uri"):
            return ("uri", link["uri"]), None
        return None, None

    def pdf_links(self):
        """Hyperref's links, consecutive rects to one destination joined ("(Chen et al.," and "2021;")."""
        merged = []
        for page in self.doc:
            try:
                found = page.get_links()
            except Exception:  # a page whose links PyMuPDF cannot read: its references may come from the source
                self._failed()
                continue
            for link in found:
                key, point = self._destination(link)
                if key is None or key[0] == "uri" and not _openable(key[1]):
                    continue
                r = _rect(link["from"])
                last = merged[-1] if merged else None
                if last and last["key"] == key and last["page"] == page.number and \
                        self._joins(page.number, last["rects"][-1], r):
                    last["rects"].append(r)
                else:
                    merged.append({"key": key, "point": point, "page": page.number, "rects": [r]})
        self._stops([(m["key"][1], m["point"]) for m in merged if m["key"][0] == "named" and m["point"]])
        for m in merged:
            try:
                text = comments.join_words(self._words_in(m["page"], m["rects"]))
                kind, value = m["key"]
                if kind == "uri":
                    t = self._target(m["key"], lambda: {"kind": "url", "label": value, "url": value})
                elif kind == "named":
                    t = self.dest_target(value, m["point"], text)
                else:
                    t = self.point_target(m["key"], m["point"], text)
                self.links.append({"page": m["page"], "rects": m["rects"], "text": text,
                                   "kind": self.targets[t]["kind"], "targets": [t], "via": "pdf"})
            except Exception:
                self._failed()

    def _stops(self, named):
        """self.stops from the document's named destinations of entries and footnotes, so one no link reaches still ends
        the one above it (a \\nocite, a link that could not be read), and from the links' (name, point)s."""
        try:
            for name, d in self.doc.resolve_names().items():
                page, to = d.get("page", -1), d.get("to")
                if (name.startswith("cite.") or _kind_of(name.split(".")[0]) == "footnote") and isinstance(page, int) \
                        and 0 <= page < self.pages and to is not None:
                    named.append((name, (page, 0.0, round(self._size(page).height - float(to[1]), 2))))
        except Exception:  # an older PyMuPDF or a damaged name tree: the links' destinations alone
            self._failed()
        for name, point in named:
            kind = "cite" if name.startswith("cite.") else _kind_of(name.split(".")[0]) or "other"
            self.stops.setdefault((point[0], kind), set()).add(point[2])

    def _failed(self):
        if not self.failures:
            traceback.print_exc(file=sys.stderr)
        self.failures += 1

    def source_runs(self):
        """[(kind, keys, page, rects, text)]: the PDF words printed by each \\ref, \\cite… and \\url mark of the
        blocks, found by aligning a block's display words with the PDF words of its parts; a mark is taken only when
        all its words align, in a row, next to aligned words around it."""
        runs = []
        for b in self.blocks:
            marks = [m for m in b.get("marks") or () if len(m) > 3 and m[2] in ("cite", "ref", "url")]
            parts = [p for p in ([b["box"]] if b.get("box") else b.get("parts") or ()) if p]
            if not marks or not parts or b["kind"] in ("deleted", "missing"):
                continue
            try:
                shown = [(n, m.start(), m.end()) for m in re.finditer(r"\S+", b["text"]) for n in [_norm(m.group())]
                         if n]
                printed = [(n, w, p) for p, r in parts for w in self._words_in(p, [r]) for n in [_norm(w[4])] if n]
                to = {}
                for i, j, size in SequenceMatcher(None, [s[0] for s in shown], [w[0] for w in printed],
                                                  autojunk=False).get_matching_blocks():
                    to.update((i + t, j + t) for t in range(size))
                taken = set(to.values())
                for d0, d1, kind, keys in (m[:4] for m in marks):
                    idx = [i for i, s in enumerate(shown) if s[1] < d1 and s[2] > d0]
                    js = [to.get(i) for i in idx]
                    lead = next((n for n, j in enumerate(js) if j is not None), len(js))
                    if 0 < lead < len(js) and js[lead] >= lead and \
                            not taken & set(range(js[lead] - lead, js[lead])):
                        # words printed otherwise before the aligned ones: cleveref's "fig. 1" for prose's "Figure 1"
                        js[:lead] = range(js[lead] - lead, js[lead])
                    if not idx or None in js or js != list(range(js[0], js[0] + len(js))):
                        continue
                    if to.get(idx[0] - 1) != js[0] - 1 and to.get(idx[-1] + 1) != js[-1] + 1:
                        continue  # no aligned word beside it: the alignment may have paired it by chance
                    page = printed[js[0]][2]
                    words = [printed[j][1] for j in js if printed[j][2] == page]
                    keys = [keys] if kind == "url" else [k.strip() for k in keys.split(",") if k.strip()]
                    runs.append((kind, keys, page, [_rect(r) for r in anchor._line_rects(words)],
                                 comments.join_words(words)))
            except Exception:
                self._failed()
        return runs

    def add_runs(self, runs):
        """The source's references: a run on a hyperref link gives a citation link its other keys (\\cite{a,b,c},
        the link's own first); any other becomes a link of its own."""
        on_page = {}  # page: [(the link's rects' top and bottom, link)]
        for e in self.links:
            on_page.setdefault(e["page"], []).append((min(a[1] for a in e["rects"]), max(a[3] for a in e["rects"]), e))
        for kind, keys, page, rects, text in runs:
            try:
                top, bottom = min(r[1] for r in rects), max(r[3] for r in rects)
                covered = [e for y0, y1, e in on_page.get(page, ()) if y0 < bottom and y1 > top and
                           any(_overlap(a, r) for a in e["rects"] for r in rects)]
                if covered:
                    for e in covered:
                        own = self.targets[e["targets"][0]]
                        if kind == "cite" and len(keys) > 1 and own["kind"] == "cite" and own["key"] in keys:
                            e["targets"] = e["targets"][:1] + [self.cite_target(k) for k in keys if k != own["key"]]
                    continue
                if kind == "url":
                    if not _openable(keys[0]):
                        continue
                    ts = [self._target(("uri", keys[0]), lambda: {"kind": "url", "label": keys[0], "url": keys[0]})]
                elif kind == "cite":
                    ts = [self.cite_target(k) for k in keys]
                else:
                    ts = [self.label_target(k, text=text) for k in keys]
                ts = list(dict.fromkeys(ts))
                if ts:
                    self.links.append({"page": page, "rects": rects, "text": text, "kind": self.targets[ts[0]]["kind"],
                                       "targets": ts, "via": "source"})
            except Exception:
                self._failed()

    def run(self):
        self.pdf_links()
        hyperref = any(e["via"] == "pdf" and self.targets[e["targets"][0]]["kind"] != "url" for e in self.links)
        self.add_runs(self.source_runs())
        self.links.sort(key=lambda e: (e["page"], e["rects"][0][1], e["rects"][0][0]))
        for e in self.links:  # a hyperref link cites its own target; a source run each of its keys
            for t in (e["targets"][:1] if e["via"] == "pdf" else e["targets"]):
                self.targets[t]["count"] += 1
                self.targets[t]["cited"].append(e["page"])
        for t in self.targets:
            t["cited"] = sorted(set(t["cited"]))
        if self.failures:
            print("links: {} links left out after errors".format(self.failures), file=sys.stderr)
        return {"hyperref": hyperref, "links": self.links, "targets": self.targets}
