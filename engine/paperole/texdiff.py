"""Word-level differences between two rounds' source trees (CONTRACT.md §5, texdiff).

Tokens ignore whitespace and `%` comments, so re-wrapping a paragraph or editing a comment is no change.
Paragraphs are diffed as units first and only the differing regions token by token: a flat token diff
took 3.3 s on a 30k-token file and 57 s on a 90k-token one.
"""
import bisect
import difflib
import filecmp
import gzip
import posixpath
import re
import unicodedata
from collections import Counter
from functools import lru_cache
from pathlib import Path

TOKEN = re.compile(r"\\[A-Za-z@]+\*?|\\.|\w+|[^\w\s]", re.S)
# What TeX does not read as a comment is matched first: verbatim bodies, \verb and \lstinline, the argument of \url,
# \nolinkurl, \path and \href (their % is printed) and escapes (\%); then a comment, from % to the end of its line.
COMMENT = re.compile(r"\\begin\s*\{(verbatim|Verbatim|BVerbatim|LVerbatim|lstlisting|minted)(\*?)\}"
                     r".*?\\end\s*\{\1\2\}|"
                     r"\\verb\*?([^\sA-Za-z*])[^\n]*?\3|"
                     r"\\lstinline\s*(?:\[[^\]\n]*\])?\s*(?:\{[^{}\n]*\}|([^\sA-Za-z{\[])[^\n]*?\4)|"
                     r"\\(?:url|nolinkurl|path|href)\s*\{[^{}\n]*\}|\\.|%[^\n]*", re.S)
BLANK_LINE = re.compile(r"^[^\S\n]*$", re.M)
# A full stop (closing brackets and quotes may follow) before white space or a footnote, or a line break \\, ends a
# sentence; so does an \item, which ends the sentence before it and starts the next (ITEM).
SENTENCE_END = re.compile(r"[.?!][)\]}'\"’”]*(?=\s|$|\\footnote\b)|\\\\")
ITEM = re.compile(r"\\item\b(?:\s*\[[^\]]*\])?")
# A caption is a sentence unit of its own (CAPTION and its closing brace), apart from the picture, table or float
# settings before it: a comment on a caption is not changed by a replaced figure or a new float width.
CAPTION = re.compile(r"\\(?:sub)?caption\*?\s*(?:\[[^\]]*\])?\s*\{")
# A word ending in one of these does not end a sentence (lower case, with its full stop): in the source (sentence) and
# in the PDF (cards._ends).
ABBREVIATIONS = set("e.g. i.e. cf. vs. viz. fig. figs. eq. eqs. sect. sects. tab. tabs. alg. appx. ch. ref. refs. "
                    "resp. approx. def. thm. lem. prop. cor. vol. pp. ed. eds. dr. prof. mr. mrs. st. et. jan. feb. "
                    "mar. apr. jun. jul. aug. sep. sept. oct. nov. dec.".split())
# ... and these, written in lower case, end one when the next word starts with a capital letter or a command ("12 ms.
# It", "et al. We", "is no. The"), as capitalised abbreviations do not ("Sec. 3", "App. B", "No. 5").
AMBIGUOUS = set("al. ms. no. nos. sec. secs. app.".split())
INITIALS = re.compile(r"[A-Z]\.|(?:[A-Za-z]\.){2,}")  # J. or e.g. or U.S.: not a sentence end
# ... unless the next word is one that starts sentences, not a name ("Appendix A. The", "variant B. We", "the U.S. In")
STARTERS = set("The This These That Those There Then Thus Here We Our Us It Its In On At By For From To As A An Each "
               "All Both Such One Most Many Some Only Also Moreover Furthermore However Finally First Second Third "
               "Next When While If Since Because With Without Unlike Like They Their He She His Her Note See After "
               "Before Table Figure Section Appendix Algorithm Overall Instead Hence Therefore Specifically "
               "Similarly".split())
CITE_OR_REF = re.compile(r"\\(?:[A-Za-z]*cite[A-Za-z]*|[cC]?ref|eqref|autoref|pageref|vref|nameref|footnote)\b")
BIBITEM = re.compile(r"\\bibitem\b|\\end\s*\{thebibliography\}")
GRAPHICS = re.compile(r"\\includegraphics\*?\s*(?:\[[^\]]*\])?\s*\{([^{}]+)\}")
GRAPHICS_EXT = ("", ".pdf", ".png", ".jpg", ".jpeg", ".eps", ".PDF", ".PNG", ".JPG", ".JPEG")
RENAMED = 0.8  # a deleted and an added file sharing this share of their tokens are one renamed file
RENAMED_SITE = 0.5  # ... or this share of the old file's, when the \input that read it now reads the new one
# \input{name}, \include{name}, \subfile{name}, TeX's own \input name (up to a space), and \import{folder}{name} and
# \subimport{folder}{name} (groups 3 and 4, as prose reads them); include_name
INCLUDE = re.compile(r"\\(?:input|include|subfile)\s*\{([^{}]*)\}|\\input[ \t]+([^\s{}\\%]+)|"
                     r"\\(?:sub)?import\s*\{([^{}]*)\}\s*\{([^{}]*)\}")
# sources TeX skips: \iffalse … \fi, the comment package's environment
HIDDEN = re.compile(r"\\iffalse\b.*?\\fi\b|\\begin\s*\{comment\}.*?\\end\s*\{comment\}", re.S)
SHINGLE = 4  # tokens in a run compared for RENAMED_SITE
PAR = "\n\n"  # the text of a paragraph-break token
MERGE_GAP = 5  # hunks with fewer equal tokens between them, and no paragraph break, merge
MOVE_MIN = 8  # a delete and an insert sharing a run of this many tokens become a move


@lru_cache(maxsize=16)
def blank_comments(text):
    """text with every `%` comment replaced by spaces (same length; newlines kept). Cached: finding paragraphs and
    carrying comments blank a file's comments again and again."""
    return COMMENT.sub(lambda m: m.group() if m.group()[0] == "\\" else " " * len(m.group()), text)


def break_only(h):
    """Whether a hunk (or a Change) only puts a paragraph break in or takes one out, as when a paragraph is split or
    joined: neither side holds a token (white space and comments only). It changes no sentence."""
    return h["kind"] != "move" and not blank_comments(h["old_text"] or "").strip() \
        and not blank_comments(h["new_text"] or "").strip()


class Tokens:
    """The tokens of one file: parallel lists of token text, start and end offsets."""

    def __init__(self, text):
        self.text = text
        self.texts, self.starts, self.ends = [], [], []
        blanks = [m.start() for m in BLANK_LINE.finditer(text)]  # comment-only lines are not blank, as in TeX
        for m in TOKEN.finditer(blank_comments(text)):
            tok = m.group()
            if tok == "\ufeff":  # a byte order mark an editor added prints nothing
                continue
            if self.ends:
                k = bisect.bisect_left(blanks, self.ends[-1])
                if k < len(blanks) and blanks[k] < m.start():
                    self._add(PAR, self.ends[-1], m.start())
            self._add("\\ " if tok[0] == "\\" and tok[1:].isspace() else tok, m.start(), m.end())

    def _add(self, tok, start, end):
        self.texts.append(tok)
        self.starts.append(start)
        self.ends.append(end)

    def point(self, i):
        """The offset just after the last token before index i that is not a paragraph break."""
        k = i - 1
        while k >= 0 and self.texts[k] == PAR:
            k -= 1
        return self.ends[k] if k >= 0 else 0

    def span(self, i1, i2):
        return (self.starts[i1], self.ends[i2 - 1]) if i2 > i1 else (self.point(i1),) * 2


class _H:
    """A hunk over token indexes. Files are None on the side where the file does not exist."""

    def __init__(self, kind, of, i1, i2, nf, j1, j2, public=True):
        self.kind, self.of, self.i1, self.i2, self.nf, self.j1, self.j2 = kind, of, i1, i2, nf, j1, j2
        self.public = public  # False for leftovers of a move that hold only punctuation or paragraph breaks


def _is_word(tok):
    return tok[0].isalnum() or tok[0] == "_" or (tok[0] == "\\" and tok[1:2].isalpha())


def _units(texts):
    """Boundaries of the paragraph units of a token list: each paragraph and each paragraph break is a unit."""
    bounds = [0]
    for i, tok in enumerate(texts):
        if tok == PAR:
            if bounds[-1] != i:
                bounds.append(i)
            bounds.append(i + 1)
    if bounds[-1] != len(texts):
        bounds.append(len(texts))
    return [tuple(texts[bounds[k]:bounds[k + 1]]) for k in range(len(bounds) - 1)], bounds


def _opcodes(a, b):
    """difflib opcodes of token lists a and b, diffing paragraphs as units first."""
    ua, ba = _units(a)
    ub, bb = _units(b)
    ops = []
    for tag, u1, u2, v1, v2 in difflib.SequenceMatcher(None, ua, ub, autojunk=False).get_opcodes():
        i1, i2, j1, j2 = ba[u1], ba[u2], bb[v1], bb[v2]
        if tag == "equal" or i1 == i2 or j1 == j2:
            sub = [(tag, i1, i2, j1, j2)]
        else:
            sub = [(t, i1 + x1, i1 + x2, j1 + y1, j1 + y2) for t, x1, x2, y1, y2 in
                   difflib.SequenceMatcher(None, a[i1:i2], b[j1:j2], autojunk=False).get_opcodes()]
        for op in sub:
            if ops and ops[-1][0] == op[0] == "equal":
                ops[-1][2], ops[-1][4] = op[2], op[4]
            else:
                ops.append(list(op))
    return ops


def _slide(ops, a, b):
    """Shift each pure insert or delete (a and b are the two files' Tokens), where the alignment allows, so that it
    starts at a word, and preferably ends at punctuation: "It is cheap." rather than "is cheap. It"; whole source
    lines count as much as a word start ("\\input{sections/b}" or "\\input sections/b" rather than
    "b} \\input{sections/" between two \\input lines), and on a tie lines that start or end."""
    for k, op in enumerate(ops):
        tag, i1, i2, j1, j2 = op
        if tag not in ("insert", "delete"):
            continue
        toks, s1, s2 = (b, j1, j2) if tag == "insert" else (a, i1, i2)
        seq = toks.texts

        def lines(d):  # 2 when the shifted hunk starts and ends a source line
            s, e = s1 + d, s2 + d
            return (s == 0 or "\n" in toks.text[toks.ends[s - 1]:toks.starts[s]]) + \
                (e == len(seq) or "\n" in toks.text[toks.ends[e - 1]:toks.starts[e]])
        room_left = ops[k - 1][2] - ops[k - 1][1] if k > 0 and ops[k - 1][0] == "equal" else 0
        room_right = ops[k + 1][2] - ops[k + 1][1] if k + 1 < len(ops) and ops[k + 1][0] == "equal" else 0
        shifts = [0]
        for d in range(1, room_left + 1):
            if seq[s1 - d] != seq[s2 - d]:
                break
            shifts.append(-d)
        for d in range(1, room_right + 1):
            if seq[s1 + d - 1] != seq[s2 + d - 1]:
                break
            shifts.append(d)
        d = min(shifts, key=lambda d: (-2 * _is_word(seq[s1 + d]) - (not _is_word(seq[s2 + d - 1]))
                                       - 2 * (lines(d) == 2), -lines(d), abs(d), d))
        if d == 0:
            continue
        op[1:] = [i1 + d, i2 + d, j1 + d, j2 + d]
        if k > 0:
            ops[k - 1][2] += d
            ops[k - 1][4] += d
        if k + 1 < len(ops):
            ops[k + 1][1] += d
            ops[k + 1][3] += d


def _file_hunks(of, nf, a, b):
    """Merged hunks of one file pair (old file of, new file nf), and the equal token pairs."""
    ops = _opcodes(a.texts, b.texts)
    _slide(ops, a, b)
    hunks, equal = [], []
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            equal.append((i1, i2, j1))
            continue
        if hunks:
            last = hunks[-1]
            gap = a.texts[last.i2:i1]
            if len(gap) < MERGE_GAP and PAR not in gap:
                last.kind, last.i2, last.j2 = "replace", i2, j2
                continue
        hunks.append(_H(tag, of, i1, i2, nf, j1, j2))
    return hunks, equal


def name_key(name):
    """A file name as macOS compares names: it finds a file by any case or Unicode form of its name, so
    \\input{Sections/Intro} reads sections/intro.tex, and an \\input in NFC a file whose name Finder wrote in NFD;
    synctex keeps the \\input's spelling."""
    return unicodedata.normalize("NFC", name).casefold()


def spellings(src):
    """{name_key: path relative to src as on disk} of the files under src: the names the engine keys them by."""
    src = Path(src)
    return {name_key(rel): rel for rel in (p.relative_to(src).as_posix() for p in src.rglob("*") if p.is_file())}


def find_file(name, files):
    """The name in `files` (relative to src) of the file `name` reads: name itself, else the one that differs from it
    only in case or Unicode form (name_key); or None."""
    if name in files:
        return name
    key = name_key(name)
    return next((f for f in files if name_key(f) == key), None)


def read_files(src, build):
    """The files under src (relative paths, spelled as on disk: spellings) that the build in `build` read, from the
    Input lines of its .synctex.gz; None when there is none (the files read are not known). A name counts by its part
    after "/./" (TeX runs in src, so this holds after the review folder was moved) and by its path under src."""
    if not build:
        return None
    for path in sorted(Path(build).glob("*.synctex.gz")):
        out, root, disk = set(), Path(src).resolve(), spellings(src)
        with gzip.open(path, "rb") as f:
            for raw in f:
                if raw.startswith(b"Input:"):
                    name = raw.decode("utf-8", "replace").rstrip("\r\n").split(":", 2)[2]
                    rels = [posixpath.normpath(name.split("/./", 1)[1])] if "/./" in name else []
                    try:
                        rels.append(Path(name).resolve().relative_to(root).as_posix())
                    except (ValueError, OSError):
                        pass
                    out.update(disk.get(name_key(rel), rel) for rel in rels)
        return out
    return None


def include_name(m):
    """The name of the file an INCLUDE match reads, as written but for "./" and "a/../" (resolved); for \\import, its
    folder and name joined (both relative to src, as prose reads them)."""
    if m.group(3) is not None:
        name = posixpath.join(m.group(3).strip(), m.group(4).strip())
    else:
        name = (m.group(1) if m.group(1) is not None else m.group(2)).strip()
    return posixpath.normpath(name) if name else name


def include_file(m, files):
    """The file of `files` (names relative to src) that an INCLUDE match reads: its name, else with .tex, in any
    case or Unicode form (find_file); or None."""
    name = include_name(m)
    return find_file(name, files) or find_file(name + ".tex", files)


def reads(texts, file, start, end):
    """(the files read by the \\input or \\include commands of file that a range touches, in order; whether the range
    holds nothing else but white space). A point touches the command it lies inside. A name without a file in
    texts is given with .tex added. The diff can cut commands anywhere ("figs/plot} \\input{" for one deleted
    \\input before another, or two edited lines in one hunk), so the whole commands are taken."""
    text = blank_comments(texts.get(file, ""))
    out, rest = [], list(range(start, end))
    for m in INCLUDE.finditer(text):
        if (m.start() < end and start < m.end()) if end > start else m.start() < start < m.end():
            out.append(include_file(m, texts) or include_name(m) + ".tex")
            rest = [i for i in rest if not m.start() <= i < m.end()]
    return out, all(text[i].isspace() for i in rest)


def hidden_spans(text):
    """[(start, end)] of the parts of a source that TeX skips (HIDDEN), comments blanked first."""
    return [m.span() for m in HIDDEN.finditer(blank_comments(text))]


def hidden_reads(texts, file, start, end):
    """The files read by the \\input or \\include commands inside the parts of file that TeX skips (hidden_spans)
    which the range [start, end] touches: a hunk there (taking out \\iffalse or \\fi, say) brings them back."""
    text = texts.get(file)
    if text is None:
        return []
    clean = blank_comments(text)
    return [include_file(m, texts) or include_name(m) + ".tex" for a, b in hidden_spans(text) if a <= end and start <= b
            for m in INCLUDE.finditer(clean, a, b)]


def _includes(texts):
    """{file: the files of the tree its \\input, \\include and \\subfile commands read (outside comments)}."""
    out = {}
    for f, t in texts.items():
        out[f] = {include_file(m, texts) or include_name(m) for m in INCLUDE.finditer(blank_comments(t))}
    return out


def _shingles(toks):
    """The runs of SHINGLE tokens of a file (paragraph breaks left out)."""
    t = [x for x in toks.texts if x != PAR]
    return {tuple(t[k:k + SHINGLE]) for k in range(len(t) - SHINGLE + 1)}


def _renames(old, new, old_texts, new_texts, old_read=None, new_read=None):
    """{old file: new file}: each file of the old tree that the new one has not, or no longer reads (old_read,
    new_read: the files each build read, or None), is paired with the file of the same extension that the new tree
    has and the old one had not (or did not read) and that shares most of its tokens: at least RENAMED of both files'
    tokens, or RENAMED_SITE of the old file's runs of SHINGLE tokens when a file that included the old one now includes
    the new one in its place (an \\input renamed with a section that grew). Runs, not single tokens: two different
    sections of one paper share half their words, but few runs of four. A file whose name differs only in case or
    Unicode form (name_key: a round snapshotted with Finder's NFD names, then one in NFC) is the same file."""
    def gone(f):
        return f not in new or (new_read is not None and f not in new_read and (old_read is None or f in old_read))

    def fresh(f):
        return f not in old or (old_read is not None and f not in old_read and (new_read is None or f in new_read))
    added = {f: Counter(t for t in new[f].texts if t != PAR) for f in new if fresh(f)}
    old_inc, new_inc = _includes(old_texts), _includes(new_texts)
    out = {}
    for of in sorted(f for f in old if gone(f)):
        same = next((nf for nf in sorted(added) if nf != of and name_key(nf) == name_key(of)), None)
        if same is not None and same not in out.values():
            out[of] = same
            continue
        ca = Counter(t for t in old[of].texts if t != PAR)
        runs = None
        best = None
        for nf, cb in sorted(added.items()):
            if nf in out.values() or nf == of or Path(nf).suffix != Path(of).suffix:
                continue
            common = sum((ca & cb).values())
            shared = common / max(sum(ca.values()), sum(cb.values()), 1)
            site = any(of in old_inc[x] and nf not in old_inc[x] and nf in new_inc.get(x, ()) and of not in new_inc[x]
                       for x in old_inc if x in new_inc)
            if site and shared < RENAMED:
                runs = _shingles(old[of]) if runs is None else runs
                site = bool(runs) and len(runs & _shingles(new[nf])) >= RENAMED_SITE * len(runs)
            if (shared >= RENAMED or site) and (best is None or shared > best[0]):
                best = shared, nf
        if best:
            out[of] = best[1]
    return out


def _graphic(src, name, dirs):
    """The graphics file \\includegraphics{name} reads in src (trying \\graphicspath's folders), or None."""
    for d in [""] + dirs:
        for ext in GRAPHICS_EXT:
            path = Path(src) / d / (name.strip() + ext)
            if path.is_file():
                return path
    return None


def _same_graphic(a, b):
    """Whether two graphics files draw the same: equal bytes, or for PDFs the same pages' content streams and images
    (a plot saved again differs in its creation date and file ID)."""
    if filecmp.cmp(a, b, shallow=False):
        return True
    if Path(a).suffix.lower() != ".pdf" or Path(b).suffix.lower() != ".pdf":
        return False
    import pymupdf

    def drawing(path):
        try:
            with pymupdf.open(path) as doc:
                return [(page.read_contents(), [doc.xref_stream_raw(img[0]) for img in page.get_images()])
                        for page in doc]
        except Exception:
            return None
    da = drawing(a)
    return da is not None and da == drawing(b)


def _graphics_dirs(texts):
    """The folders of \\graphicspath{{a/}{b/}} in a tree's files."""
    return [d for t in texts.values() for m in re.finditer(r"\\graphicspath\s*\{((?:\s*\{[^{}]*\})*)\s*\}",
                                                            blank_comments(t))
            for d in re.findall(r"\{([^{}]*)\}", m.group(1))]


def _runs(seq):
    """The runs of MOVE_MIN tokens of a token list, by their start, for _longest."""
    return [tuple(seq[k:k + MOVE_MIN]) for k in range(len(seq) - MOVE_MIN + 1)]


def _run_index(seq):
    """{run of MOVE_MIN tokens: [its starts, in order]} of a token list, for _longest."""
    index = {}
    for k, run in enumerate(_runs(seq)):
        index.setdefault(run, []).append(k)
    return index


def _longest(a, b, runs, index):
    """(i, j, size) of the longest run of tokens that lists a and b share, at least MOVE_MIN long (runs: a's _runs;
    index: b's _run_index), or (0, 0, 0). Of the longest, the one that starts first in a, then first in b, as
    difflib's find_longest_match gives (which took seconds on the long pieces of reordered sections): each run is grown
    from its first MOVE_MIN tokens, found in the index, once."""
    best = (0, 0, 0)
    for i, run in enumerate(runs):
        for j in index.get(run, ()):
            if i and j and a[i - 1] == b[j - 1]:
                continue  # inside the run that starts one token before
            k = MOVE_MIN
            while i + k < len(a) and j + k < len(b) and a[i + k] == b[j + k]:
                k += 1
            if k > best[2]:
                best = i, j, k
    return best


def _droppable(texts):
    return all(t == PAR or not any(c.isalnum() for c in t) for t in texts)


def _strip(h, s, e, texts):
    """A piece (h, s, e) without paragraph breaks at its ends, or None if nothing is left."""
    while s < e and texts[s] == PAR:
        s += 1
    while e > s and texts[e - 1] == PAR:
        e -= 1
    return (h, s, e) if e > s else None


class TreeDiff:
    """The difference between two source trees. `hunks` are dicts as in CONTRACT.md §5; `old_texts`/`new_texts`
    and `old_tokens`/`new_tokens` map each .tex file (relative to src) to its text and Tokens; `old_read`/`new_read`
    are the files each build read (read_files), or None, and `unread` the new tree's files its build did not read;
    `renamed` maps old files to new ones (_renames); `old_src` and `new_src` are the two trees' folders."""

    def __init__(self, old_src, new_src, old_build=None, new_build=None):
        self.old_src, self.new_src = Path(old_src), Path(new_src)
        self.old_texts = _read_tree(old_src, old_build)
        self.new_texts = _read_tree(new_src, new_build)
        self.old_tokens = {f: Tokens(t) for f, t in self.old_texts.items()}
        self.new_tokens = {f: Tokens(t) for f, t in self.new_texts.items()}
        self.old_read, self.new_read = read_files(old_src, old_build), read_files(new_src, new_build)
        # the new tree's files in new_src that its build did not read: they print nothing
        self.unread = {f for f in self.new_texts if self.new_read is not None and f not in self.new_read
                       and (Path(new_src) / f).is_file()}
        self.renamed = _renames(self.old_tokens, self.new_tokens, self.old_texts, self.new_texts, self.old_read,
                                self.new_read)  # {old file: new file}
        internal = []
        self._img = {f: [None] * len(t.texts) for f, t in self.old_tokens.items()}  # old token -> (new file, index)
        paired = set(self.renamed) | set(self.renamed.values())  # a file left behind unread is not compared
        pairs = [(f, f) for f in self.old_tokens if f in self.new_tokens and f not in paired] + \
            list(self.renamed.items())
        for of, nf in sorted(pairs):
            hunks, equal = _file_hunks(of, nf, self.old_tokens[of], self.new_tokens[nf])
            internal += hunks
            for i1, i2, j1 in equal:
                for i in range(i1, i2):
                    self._img[of][i] = (nf, j1 + i - i1)
        for rel, a in sorted(self.old_tokens.items()):  # (a deleted file the old build did not read printed nothing)
            if rel not in self.new_tokens and rel not in self.renamed and a.texts:
                internal.append(_H("delete", rel, 0, len(a.texts), None, None, None, public=self._old_printed(rel)))
        for rel, b in sorted(self.new_tokens.items()):
            if rel not in self.old_tokens and rel not in self.renamed.values() and b.texts:
                internal.append(_H("insert", None, None, None, rel, 0, len(b.texts)))
        internal = self._find_moves(internal)
        self._label_echoes(internal)
        for h in internal:  # an edit in a file the build does not read prints nothing: no change to check
            if h.nf in self.unread:
                h.public = False

        self._owner = {f: [None] * len(t.texts) for f, t in self.old_tokens.items()}  # old token -> its hunk
        for h in internal:
            if h.of is not None:
                for i in range(h.i1, h.i2):
                    self._owner[h.of][i] = h
                    if h.kind == "move":
                        self._img[h.of][i] = (h.nf, h.j1 + i - h.i1)
        public = [(self._dict(h), h) for h in internal if h.public]
        public += [(d, None) for d in self._figure_hunks(old_src, new_src)]
        public.sort(key=lambda p: (p[0]["new_file"] is None, p[0]["new_file"] or p[0]["old_file"],
                                   p[0]["new_start"] if p[0]["new_start"] is not None else p[0]["old_start"],
                                   p[0]["old_start"] or 0))
        self.hunks = [d for d, _ in public]
        self._hunk_of = {id(h): d for d, h in public if h is not None}

    def _label_echoes(self, hunks):
        """In a reference list, a hunk inside an entry's label (the \\bibitem's [optional argument], which natbib
        prints where the entry is cited, not in the list) is not listed (public False) when a hunk in the entry's text
        makes the same edit: the year, which both hold, is one change, drawn where the list prints it."""
        def key(h):
            os_, oe = self._span("old", h.of, h.i1, h.i2)
            ns, ne = self._span("new", h.nf, h.j1, h.j2)
            return " ".join(self.old_texts[h.of][os_:oe].split()), " ".join(self.new_texts[h.nf][ns:ne].split()), ns, ne
        bbl = [h for h in hunks if h.public and h.kind != "move" and h.of and h.nf and h.nf.endswith(".bbl")]
        for h in bbl:
            old_text, new_text, ns, ne = key(h)
            new = self.new_texts[h.nf]
            if _label_at(new, ns, ne) is None or _label_at(self.old_texts[h.of], *self._span("old", h.of, h.i1, h.i2)) \
                    is None:
                continue
            entry = bibitem(new, ns, max(ne, ns + 1))
            for g in bbl:
                if g is h or g.nf != h.nf or g.of != h.of:
                    continue
                g_old, g_new, gs, ge = key(g)
                if entry and entry[0] <= gs and ge <= entry[1] and _label_at(new, gs, ge) is None \
                        and (g_old, g_new) == (old_text, new_text):
                    h.public = False
                    break

    def _figure_hunks(self, old_src, new_src):
        """A replace hunk over each \\includegraphics that is the same in both trees but reads a graphics file whose
        bytes changed (a figure replaced under the same name), with "figure": that file, relative to src."""
        rev = {img: (of, i) for of, imgs in self._img.items() for i, img in enumerate(imgs) if img}
        old_dirs, new_dirs = _graphics_dirs(self.old_texts), _graphics_dirs(self.new_texts)
        out = []
        for nf, text in sorted(self.new_texts.items()):
            if nf in self.unread:
                continue  # prints nothing
            toks = self.new_tokens[nf]
            for m in GRAPHICS.finditer(blank_comments(text)):
                new, old = _graphic(new_src, m.group(1), new_dirs), _graphic(old_src, m.group(1), old_dirs)
                if new is None or old is None or _same_graphic(old, new):
                    continue
                j1, j2 = bisect.bisect_left(toks.starts, m.start()), bisect.bisect_left(toks.starts, m.end())
                back = [rev.get((nf, j)) for j in range(j1, j2)]
                if not back or None in back or len({b[0] for b in back}) > 1:
                    continue  # the command itself was edited: a hunk of the diff holds it
                of, ot = back[0][0], self.old_tokens[back[0][0]]
                os_, oe, ns, ne = ot.starts[back[0][1]], ot.ends[back[-1][1]], toks.starts[j1], toks.ends[j2 - 1]
                out.append({"kind": "replace", "old_file": of, "old_start": os_, "old_end": oe, "new_file": nf,
                            "new_start": ns, "new_end": ne, "old_text": self.old_texts[of][os_:oe],
                            "new_text": text[ns:ne], "figure": new.relative_to(Path(new_src)).as_posix()})
        return out

    def _span(self, side, f, i1, i2):
        if f is None:
            return None, None
        return (self.old_tokens if side == "old" else self.new_tokens)[f].span(i1, i2)

    def _dict(self, h):
        os_, oe = self._span("old", h.of, h.i1, h.i2)
        ns, ne = self._span("new", h.nf, h.j1, h.j2)
        return {"kind": h.kind, "old_file": h.of, "old_start": os_, "old_end": oe,
                "new_file": h.nf, "new_start": ns, "new_end": ne,
                "old_text": self.old_texts[h.of][os_:oe] if h.of is not None else "",
                "new_text": self.new_texts[h.nf][ns:ne] if h.nf is not None else ""}

    def _old_printed(self, f):
        """Whether the old build printed file f of the old tree: it read it, or what it read is not known, or f is a
        reference list in the build folder (not in src)."""
        return self.old_read is None or f in self.old_read or not (self.old_src / f).is_file()

    def _find_moves(self, hunks):
        """Turn shared runs of >= MOVE_MIN tokens between deleted and inserted text into move hunks. The deleted and
        inserted sides of replace hunks count too, so a sentence moved next to an edit is still a move. Only printed
        text moves: a paragraph cut into a file the new build does not read (a scrap file) is deleted, and one pasted
        from a file the old build did not read is inserted."""
        olds = [(h, h.i1, h.i2) for h in hunks if h.kind in ("delete", "replace")]  # pieces still unmatched
        news = [(h, h.j1, h.j2) for h in hunks if h.kind in ("insert", "replace")]
        printed = {h.of for h, _, _ in olds if self._old_printed(h.of)}
        moves, split = [], set()
        # (old piece, new piece) -> their longest shared run (_longest), old piece -> its _runs, new piece -> its
        # _run_index: worked out once, since the pieces a move leaves alone stay as they are
        found, runs, index = {}, {}, {}
        while True:
            best = None
            for di, (h, i1, i2) in enumerate(olds):
                if h.of not in printed:
                    continue
                for ii, (g, j1, j2) in enumerate(news):
                    if g.nf in self.unread:
                        continue
                    key = (h.of, i1, i2), (g.nf, j1, j2)
                    if key not in found:
                        da, nb = self.old_tokens[h.of].texts[i1:i2], self.new_tokens[g.nf].texts[j1:j2]
                        if key[0] not in runs:
                            runs[key[0]] = _runs(da)
                        if key[1] not in index:
                            index[key[1]] = _run_index(nb)
                        found[key] = _longest(da, nb, runs[key[0]], index[key[1]])
                    m = found[key]
                    if m[2] >= MOVE_MIN and (best is None or m[2] > best[2][2]):
                        best = (di, ii, m)
            if best is None:
                break
            di, ii, (a, b, size) = best
            h, i1, i2 = olds.pop(di)
            g, j1, j2 = news.pop(ii)
            moves.append(_H("move", h.of, i1 + a, i1 + a + size, g.nf, j1 + b, j1 + b + size))
            split |= {id(h), id(g)}
            olds += [(h, s, e) for s, e in ((i1, i1 + a), (i1 + a + size, i2)) if e > s]
            news += [(g, s, e) for s, e in ((j1, j1 + b), (j1 + b + size, j2)) if e > s]
        rest = [h for h in hunks if id(h) not in split]
        return rest + moves + self._leftovers([p for p in olds if id(p[0]) in split],
                                              [p for p in news if id(p[0]) in split], moves)

    def _leftovers(self, olds, news, moves):
        """Hunks for what moves left of the hunks they were cut from: old pieces (h, i1, i2) and new pieces (h, j1, j2).

        An old and a new piece between the same moved tokens (or beside one and of a similar size), or left of one
        replace, become a replace there: a word edited inside a moved paragraph is a replace at its new place. A
        piece between two moved tokens that are still neighbours goes between them, and punctuation beside a moved
        token goes with it. Any other piece keeps its hunk's position, as does a deleted sentence whose neighbour
        moved away. Paragraph breaks at a piece's ends are left out; their tokens map as whitespace."""
        img, pre = {}, {}  # moved tokens: (old file, i) -> (new file, j), and back
        for m in moves:
            for k in range(m.i2 - m.i1):
                img[(m.of, m.i1 + k)] = (m.nf, m.j1 + k)
                pre[(m.nf, m.j1 + k)] = (m.of, m.i1 + k)
        olds = [p for p in (_strip(h, s, e, self.old_tokens[h.of].texts) for h, s, e in olds) if p]
        news = [p for p in (_strip(g, s, e, self.new_tokens[g.nf].texts) for g, s, e in news) if p]

        def beside(p, q):  # between the same moved tokens, or next to one and of a similar size
            left = img.get((p[0].of, p[1] - 1)) == (q[0].nf, q[1] - 1)
            right = img.get((p[0].of, p[2])) == (q[0].nf, q[2])
            a, b = p[2] - p[1], q[2] - q[1]
            return (left and right) or ((left or right) and max(a, b) <= 2 * min(a, b) + MERGE_GAP)

        pairs = []
        for side_by_side in (beside, lambda p, q: p[0] is q[0]):
            for p in list(olds):
                q = next((q for q in news if side_by_side(p, q)), None)
                if q:
                    pairs.append((p, q))
                    olds.remove(p)
                    news.remove(q)
        out = []
        for (h, i1, i2), (g, j1, j2) in pairs:
            drop = _droppable(self.old_tokens[h.of].texts[i1:i2]) and _droppable(self.new_tokens[g.nf].texts[j1:j2])
            out.append(_H("replace", h.of, i1, i2, g.nf, j1, j2, public=not drop))
        for h, i1, i2 in olds:
            left, right = img.get((h.of, i1 - 1)), img.get((h.of, i2))
            drop = _droppable(self.old_tokens[h.of].texts[i1:i2])
            if left and right and left[0] == right[0] and left[1] + 1 == right[1]:
                nf, j = left[0], right[1]
            elif drop and (left or right):  # punctuation beside moved text goes with it
                nf, j = (left[0], left[1] + 1) if left else right
            else:
                nf, j = h.nf, h.j1
            out.append(_H("delete", h.of, i1, i2, nf, j, j, public=not drop))
        for g, j1, j2 in news:
            if _droppable(self.new_tokens[g.nf].texts[j1:j2]):
                continue
            left, right = pre.get((g.nf, j1 - 1)), pre.get((g.nf, j2))
            of, i = (left[0], right[1]) if left and right and left[0] == right[0] and left[1] + 1 == right[1] \
                else (g.of, g.i1)
            out.append(_H("insert", of, i, i, g.nf, j1, j2))
        return out

    def map_offset(self, file, offset, bias="left"):
        """Map an offset in the old file to (new file, offset), or None if it has no place there."""
        toks = self.old_tokens.get(file)
        if toks is None or not toks.texts:
            return None
        n = len(toks.texts)
        if bias == "left":
            i = bisect.bisect_right(toks.ends, offset)
            if i == n:
                return self.map_offset(file, toks.ends[-1], "right")
            i += toks.texts[i] == PAR  # a paragraph break is whitespace: go to the next token
            offset = max(offset, toks.starts[i])
        else:
            i = bisect.bisect_left(toks.starts, offset) - 1
            if i < 0:
                return self.map_offset(file, toks.starts[0], "left")
            i -= toks.texts[i] == PAR
            offset = min(offset, toks.ends[i])
        img = self._img[file][i]
        if img is not None:
            nf, j = img
            new = self.new_tokens[nf]
            return nf, new.starts[j] + min(offset - toks.starts[i], new.ends[j] - new.starts[j])
        h = self._owner[file][i]
        if h is None or h.nf is None:
            return None
        ns, ne = self.new_tokens[h.nf].span(h.j1, h.j2)
        return h.nf, ns if bias == "left" else ne

    def same_place(self, old_file, old_offset, new_file, new_offset):
        """Whether a point between tokens of the old file (where a comment is, say) is that point of the new file: the
        token just before it, or the one just after it, is unchanged (or moved) and is the one just before (after) the
        new point."""
        a, b = self.old_tokens.get(old_file), self.new_tokens.get(new_file)
        if a is None or b is None:
            return False
        return any(i is not None and j is not None and self._img[old_file][i] == (new_file, j)
                   for i, j in zip(_beside(a, old_offset), _beside(b, new_offset)))

    def kept_ratio(self, file, start, end):
        """Share of the range's old tokens (paragraph breaks aside) outside every hunk or inside a move."""
        toks = self.old_tokens.get(file)
        if toks is None:
            return 1.0
        i1 = bisect.bisect_right(toks.ends, start)
        i2 = bisect.bisect_left(toks.starts, end)
        idx = [i for i in range(i1, i2) if toks.texts[i] != PAR]
        if not idx:
            return 1.0
        owner = self._owner[file]
        kept = sum(1 for i in idx if owner[i] is None or owner[i].kind == "move" or not owner[i].public)
        return kept / len(idx)

    def hunks_touching(self, file, start, end):
        """The hunks whose old range touches [start, end], ends inclusive."""
        return [d for d in self.hunks if d["old_file"] == file and d["old_start"] <= end and d["old_end"] >= start]

    def tokens_in(self, file, start, end):
        """[(text, start, end, hunk dict or None)] for the old tokens overlapping [start, end)."""
        toks = self.old_tokens.get(file)
        if toks is None:
            return []
        out = []
        for i in range(bisect.bisect_right(toks.ends, start), bisect.bisect_left(toks.starts, end)):
            h = self._owner[file][i]
            out.append((toks.texts[i], toks.starts[i], toks.ends[i], self._hunk_of.get(id(h)) if h else None))
        return out


def _beside(toks, offset):
    """(the index of the last token that ends at or before offset, of the first that starts at or after it), paragraph
    breaks passed over; None where there is none."""
    i = bisect.bisect_right(toks.ends, offset) - 1
    while i >= 0 and toks.texts[i] == PAR:
        i -= 1
    j = bisect.bisect_left(toks.starts, offset)
    while j < len(toks.texts) and toks.texts[j] == PAR:
        j += 1
    return (i if i >= 0 else None), (j if j < len(toks.texts) else None)


def _read_tree(src, build=None):
    """{file: text} of src's .tex files and of the reference lists BibTeX typeset: the .bbl files with \\bibitem in
    src, and in build those that src has no file of the same name for (TeX reads src's first), named as if they were
    in src. biblatex's .bbl holds entry data, not the printed list, and is left out."""
    src = Path(src)
    paths = {p.relative_to(src).as_posix(): p for p in sorted(src.rglob("*.tex")) + sorted(src.rglob("*.bbl"))}
    keys = {name_key(rel) for rel in paths}  # (TeX finds src's file in any case or Unicode form of its name)
    for p in sorted(Path(build).glob("*.bbl")) if build else ():
        if name_key(p.name) not in keys:
            paths[p.name] = p
    texts = {rel: p.read_text(encoding="utf-8", errors="replace") for rel, p in paths.items() if p.is_file()}
    return {rel: t for rel, t in texts.items() if not rel.endswith(".bbl") or "\\bibitem" in t}


def diff_trees(old_src, new_src, old_build=None, new_build=None):
    """Compare every *.tex and *.bbl file of two source trees, with the .bbl files BibTeX wrote in their builds."""
    return TreeDiff(old_src, new_src, old_build, new_build)


def abbreviation(word, following=""):
    """Whether a word that ends in a full stop (with it) is an abbreviation or an initial, not a sentence end, given
    the text that follows it (its next word): ABBREVIATIONS never end one; AMBIGUOUS words in lower case end one
    before a capital letter or a command (not a citation, reference or footnote); an initial before one of the
    STARTERS (or such a command) ends one."""
    lower = word.lower()
    if lower in ABBREVIATIONS:
        return True
    nxt = following.lstrip()
    command = nxt.startswith("\\") and not CITE_OR_REF.match(nxt)
    if lower in AMBIGUOUS:
        return not (word == lower and (nxt[:1].isupper() or command))
    if INITIALS.fullmatch(word) and lower not in ("e.g.", "i.e."):
        return not (command or re.match(r"[A-Za-z]+", nxt) and re.match(r"[A-Za-z]+", nxt).group() in STARTERS)
    return False


@lru_cache(maxsize=16)
def _bounds(text):
    """Sorted boundary lists of text: (sentence back, sentence forward, paragraph back, paragraph forward). A full
    stop after an abbreviation or an initial (abbreviation) ends no sentence; an \\item ends the sentence before it
    (forward) and starts one after it (back); so does a \\caption, and its closing brace ends one (CAPTION)."""
    clean = blank_comments(text)

    def abbreviated(k):  # the full stop at k ends an abbreviation or an initial
        return clean[k] == "." and abbreviation(re.search(r"[A-Za-z.]*$", clean[max(0, k - 12):k]).group() + ".",
                                                clean[k + 1:k + 40])
    ends = [m.end() for m in SENTENCE_END.finditer(clean) if not abbreviated(m.start())]
    items = [m.span() for m in ITEM.finditer(clean)]
    for m in CAPTION.finditer(clean):  # (\caption's start, the start of its text) and (its closing brace, after it)
        close = _group_close(clean, m.end() - 1)
        items += [(m.start(), m.end())] + ([(close, close + 1)] if close is not None else [])
    blanks = [(m.start(), m.end()) for m in BLANK_LINE.finditer(text)]
    bstarts, bends = [s for s, _ in blanks], [e for _, e in blanks]
    return sorted(ends + bends + [e for _, e in items]), sorted(ends + bstarts + [s for s, _ in items]), bends, bstarts


def _group_close(text, i):
    """The index of the brace that closes the group opened at text[i] ("{"), or None."""
    depth = 0
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        depth += (c == "{") - (c == "}")
        if depth == 0:
            return i
        i += 1
    return None


def trim(text, start, end):
    """(start, end) without whitespace at either end."""
    while start < end and text[start].isspace():
        start += 1
    while end > start and text[end - 1].isspace():
        end -= 1
    return start, end


def _widen(text, start, end, back, fwd):
    """Widen [start, end] back to the last position in `back` <= start and on to the first in `fwd` >= end."""
    start, end = trim(text, start, end)
    k = bisect.bisect_right(back, start)
    s = back[k - 1] if k else 0
    k = bisect.bisect_left(fwd, end)
    e = fwd[k] if k < len(fwd) else len(text)
    while s < start and text[s].isspace():
        s += 1
    while e > end and text[e - 1].isspace():
        e -= 1
    return s, e


def sentence(text, start, end):
    """Widen a range to whole sentences: a sentence ends after . ? ! followed by whitespace or a footnote (not after an
    abbreviation or an initial), at \\\\, at an \\item, or at a blank line.
    A range in an entry of a reference list is widened to the entry (bibitem), since its authors, title, venue and
    year are one reference. A range that is an \\includegraphics command stays as it is."""
    item = bibitem(text, start, end)
    if item:
        return item
    if GRAPHICS.fullmatch(text, start, end):  # a picture (the words drawn in it) is a sentence of its own
        return start, end
    back, fwd, _, _ = _bounds(text)
    return _widen(text, start, end, back, fwd)


@lru_cache(maxsize=16)
def _bibitems(text):
    return [m.start() for m in BIBITEM.finditer(blank_comments(text))]


def bibitem(text, start, end):
    """(start, end) of the reference list entry, from its \\bibitem to the next one or the list's end, that holds
    [start, end), or None."""
    if "\\bibitem" not in text:
        return None
    marks = _bibitems(text)
    k = bisect.bisect_right(marks, start) - 1
    if k < 0 or k + 1 >= len(marks) or not text.startswith("\\bibitem", marks[k]) or end > marks[k + 1]:
        return None
    return trim(text, marks[k], marks[k + 1])


def _label_at(text, start, end):
    """(start, end) of the [optional argument] of the \\bibitem before `start` when [start, end) lies in it, else
    None. Brackets inside braces do not close it."""
    k = text.rfind("\\bibitem", 0, start)
    if k < 0:
        return None
    j = k + len("\\bibitem")
    while j < len(text) and text[j] in " \t\n":
        j += 1
    if j >= len(text) or text[j] != "[":
        return None
    depth, i = 0, j + 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "]" and depth == 0:
            break
        depth += (c == "{") - (c == "}")
        i += 1
    return (j + 1, i) if j + 1 <= start and end <= i else None


def paragraph(text, start, end):
    """Widen a range to the blank lines (or file ends) around it."""
    _, _, back, fwd = _bounds(text)
    return _widen(text, start, end, back, fwd)
