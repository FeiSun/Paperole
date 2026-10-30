"""The overview of papers, read only (CONTRACT.md amendment "Overview"; design/overview/v2/OVERVIEW-v2.md §5): for each
paper and round, the round's level-1 sections and where they are printed (spans), how they continue the round
before's (match, by paragraphs), its edits and the places of its comments, and the round's counts; per paper the
threads of its comments; per student the numbers of the Student page. It reads ledger.json and each round's
analysis.json and prose.json. It builds no prose.json (a missing or stale one makes the round `pending`; the app's
second engine process fills it in with `prose`), takes no lock and writes no file.

Places are in page units: pos = page + the fraction of the page above the point. On a page in two columns the left
column is the first half and the right column the second (a rect across both columns counts as the left column in the
top half of the page, the right one in the bottom half, as state._printed orders them). The fraction runs over the
page's text: from the top of its highest paragraph part to the bottom of its lowest, widened to the paper's usual
text area (the median of those over its pages), so a short last page ends part way."""
import datetime
import functools
import re
import statistics
import sys
import traceback
import unicodedata
from collections import Counter
from pathlib import Path

import pymupdf

from . import EngineError, analysis, comments, ledger, prose, state, tags

FRONT = "front"  # the key of "Title and abstract" (the blocks before the first section)
FRONT_TITLE = "Title and abstract"
TEXT = {"paragraph", "item", "heading", "title", "bibitem", "figure", "table"}  # kinds whose words count (captions)
BODY = TEXT - {"bibitem"}  # the words of the paper's body: not its reference list
UNCOUNTED = {"math", "tex"}  # marks whose characters are no words (inline TeX, a command printed as a chip)
# a word: a CJK character, or a run without spaces
WORD = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]|[^\s\u3400-\u9fff\uf900-\ufaff]+")
EDGE = 3.0  # points: a rect starting right of a column gap less this is in the right column (prose, state)
SPLIT = 1 / 3  # a section whose paragraphs went into two sections, each more than this share of them, was split
BUCKETS = (  # the Student page's standard sections (id, title); a heading takes the first whose words it holds
    ("abstract", "Abstract", ("abstract", "摘要")),
    ("conclusion", "Conclusion", ("conclusion", "conclusions", "concluding remarks", "summary", "结论", "总结", "结语")),
    ("discussion", "Discussion", ("discussion", "limitation", "limitations", "implications", "outlook", "future work",
                                  "uncertainty", "讨论", "局限", "展望")),
    ("introduction", "Introduction", ("introduction", "background", "related work", "related works", "literature",
                                      "motivation", "preliminaries", "problem statement", "引言", "介绍", "绪论",
                                      "背景", "相关工作")),
    ("method", "Methods", ("method", "methods", "methodology", "approach", "materials", "model", "data", "dataset",
                           "design", "setup", "set up", "settings", "setting", "implementation", "framework",
                           "study area", "site", "sites", "sampling", "estimation", "construction", "方法", "模型",
                           "数据", "实验设置", "设计")),
    ("results", "Results", ("results", "result", "experiments", "experiment", "experimental", "evaluation",
                            "findings", "analysis", "validation", "sensitivity", "ablation", "结果", "实验", "评估",
                            "分析")),
)
STANDARD = ["abstract", "introduction", "method", "results", "discussion", "conclusion"]  # the columns' order
TITLES = {b: t for b, t, _ in BUCKETS}
VERDICT = {"verified": "resolved", "wontfix": "kept", "reopened": "follow_up"}
REFERENCES = {"references", "reference", "bibliography", "参考文献"}  # a reference list's heading (folded)
APPENDIX = re.compile(r"^(?:appendix|appendices|supplementary(?: material)?|附录)\b", re.I)  # an unnumbered one's
KEY_KINDS = ("figure", "table")  # a page's key block: the largest of these on it, else its first paragraph


# --- words, keys, buckets --------------------------------------------------------------------------------------

def _words(text, marks, s=0, e=None):
    """The printed words of text[s:e]: runs of non-space characters holding a letter or digit (a CJK character is a
    word), leaving out what inline math and chips hold."""
    e = len(text) if e is None else e
    chars = list(text[s:e])
    for m in marks:
        if m[2] in UNCOUNTED and m[0] < e and m[1] > s:
            for i in range(max(m[0], s) - s, min(m[1], e) - s):
                chars[i] = " "
    return sum(1 for w in WORD.findall("".join(chars)) if any(ch.isalnum() for ch in w))


def fold(name):
    """A name folded for grouping: compatibility forms, case and all white space ignored."""
    return "".join(unicodedata.normalize("NFKC", name or "").casefold().split())


def _plain(name):
    return " ".join(re.sub(r"[^\w]+", " ", unicodedata.normalize("NFKC", name or "").casefold()).split())


def _slug(name):
    """A section's key from its title: its words, lower case, joined by "-" (at most 40 characters)."""
    return (_plain(name).replace(" ", "-")[:40].strip("-")) or "section"


def suggested_bucket(name, number=None):
    """The standard section a heading probably is (only a suggestion; the advisor confirms it in the app): the first of
    BUCKETS one of whose words or phrases its title holds; None for an appendix (lettered) or no match."""
    if number and number[:1].isalpha():
        return None
    words, raw = " {} ".format(_plain(name)), unicodedata.normalize("NFKC", name or "")
    for bucket, _, keys in BUCKETS:
        if any((" {} ".format(k) in words) if k.isascii() else (k in raw) for k in keys):
            return bucket
    return None


# --- places -------------------------------------------------------------------------------------------------------

def _column(rect, y, gap):
    """0 for the left column of a two-column page, 1 for the right (a rect across both: by the half of the page)."""
    if gap is None:
        return None
    x, half = gap
    if rect[0] < x - EDGE and rect[2] > x + EDGE:
        return 0 if y < half else 1
    return 1 if rect[0] >= x - EDGE else 0


def _pos(page, rect, y, bounds, gaps, col_y=None):
    """The place of point y of a rect on a page, in page units (module docstring); the column is the one the rect is
    in at col_y (default y: a block's end stays in the column its top is in)."""
    top, bottom = bounds(page)
    frac = min(max((y - top) / (bottom - top), 0.0), 1.0) if bottom > top else 0.0
    col = _column(rect, y if col_y is None else col_y, gaps[page] if page < len(gaps) else None)
    return page + (frac if col is None else (col + frac) / 2)


def _bounder(own, usual):
    """bounds(page) -> (top, bottom): a page's own text extent widened to the usual one, or the usual one."""
    def bounds(page):
        if page in own:
            t, b = own[page]
            return min(t, usual[0]), max(b, usual[1])
        return usual
    return bounds


@functools.lru_cache(maxsize=32)
def _pdf_area(pdf, stamp):
    """(0, height) of the first page of a PDF: the text area when no round has paragraphs to measure it by."""
    with pymupdf.open(pdf) as doc:
        return (0.0, float(doc[0].rect.height)) if doc.page_count else (0.0, 792.0)


# --- one round's paragraphs, digested (cached by prose.json's path, modification time and the round's columns) ----

_DIGESTS = {}  # prose.json path -> ((mtime, size, gaps), digest): one entry a file, replaced when it changes


def _digest_file(p, mtime, size, gaps):
    """A round's digest, kept per file: an LRU of fixed size missed every time once the papers listed had more rounds
    than it held (a hierarchy request reads every round in order)."""
    stamp = (mtime, size, gaps)
    hit = _DIGESTS.get(p)
    if hit is not None and hit[0] == stamp:
        return hit[1]
    data = prose._load(p, mtime, size)
    digest = None
    if data and data.get("parser") == prose.PARSER and data.get("schema") == prose.SCHEMA:
        digest = _digest(data, gaps)
    _DIGESTS[p] = (stamp, digest)
    return digest


def _digest(data, gaps):
    """What the overview needs of a round's prose.json: its level-1 sections (front matter first) with their blocks
    and printed spans, each block's section, the page text extents, the words, and `previous`."""
    blocks = data["blocks"]
    own = {}
    for b in blocks:
        if b["kind"] in ("deleted", "missing"):
            continue
        for page, r in b.get("parts") or ():
            t, z = own.get(page, (r[1], r[3]))
            own[page] = (min(t, r[1]), max(z, r[3]))
    usual = (statistics.median(t for t, _ in own.values()), statistics.median(z for _, z in own.values())) \
        if own else None
    bounds = _bounder(own, usual) if usual else None

    secs = [{"block": -1, "title": FRONT_TITLE, "name": FRONT_TITLE, "number": None, "content": []}]
    sec_of = [None] * len(blocks)
    pages = []  # per block: (kind, its first part's page, {page: area} for a figure or table) for the key page
    for k, b in enumerate(blocks):
        if b["kind"] in ("deleted", "missing"):
            pages.append((b["kind"], None, {}))
            continue
        parts = b.get("parts") or ()
        area = {}
        if b["kind"] in KEY_KINDS:
            for page, r in parts:
                area[page] = area.get(page, 0.0) + max(r[2] - r[0], 0) * max(r[3] - r[1], 0)
        pages.append((b["kind"], parts[0][0] if parts else None, area))
        if b["kind"] == "heading" and (b["level"] or 1) == 1:
            secs.append({"block": k, "title": " ".join(t for t in (b["number"], b["text"]) if t), "name": b["text"],
                         "number": b["number"], "content": []})
        sec_of[k] = len(secs) - 1
        if b["kind"] in prose.READ:
            secs[-1]["content"].append(k)
    _parts(secs, blocks)

    def place(b, last=False):
        parts = b.get("parts") or ()
        if not parts or bounds is None:
            return None
        page, r = parts[-1] if last else parts[0]
        return _pos(page, r, r[3] if last else r[1], bounds, gaps, col_y=r[1])

    # where each section starts: its heading as printed; without one (References, a heading with no place) its first
    # text block; else where the text of the sections before it ends
    text_end, starts, ends = 0.0, [], []
    for i, s in enumerate(secs):
        start = 0.0 if i == 0 else place(blocks[s["block"]])
        if start is None:
            start = next((p for p in (place(blocks[k]) for k in s["content"]
                                      if blocks[k]["kind"] not in prose.IMAGE_KINDS) if p is not None), None)
        if start is None:
            start = text_end
        starts.append(max(start, starts[-1]) if starts else start)
        for k in s["content"] + ([s["block"]] if s["block"] >= 0 else []):
            p = place(blocks[k], last=True)
            if p is not None:
                ends.append(p)
                if blocks[k]["kind"] not in prose.IMAGE_KINDS:
                    text_end = max(text_end, p)
    last = max(ends + [starts[-1]])
    for i, s in enumerate(secs):
        s["start"], s["end"] = starts[i], (starts[i + 1] if i + 1 < len(secs) else last)

    # words: the body's, and each change's inserted and deleted ones (whole blocks added or deleted included)
    owner = {}
    for cid, ks in (data.get("changes") or {}).items():
        for k in ks:
            owner.setdefault(k, cid)
    body, by_change = 0, {}
    for k, b in enumerate(blocks):
        kind = b.get("was") if b["kind"] == "deleted" else b["kind"]
        if kind not in TEXT:
            continue
        if b["kind"] == "deleted":
            by_change.setdefault(owner.get(k), [0, 0])[1] += _words(b["text"], b["marks"])
            continue
        if kind in BODY:
            body += _words(b["text"], b["marks"])
        if b.get("added"):
            by_change.setdefault(b["added"], [0, 0])[0] += _words(b["text"], b["marks"])
        else:
            for s, e, cid in b.get("ins") or ():
                by_change.setdefault(cid, [0, 0])[0] += _words(b["text"], b["marks"], s, e)
        for _, text, marks, cid in b.get("del") or ():
            by_change.setdefault(cid, [0, 0])[1] += _words(text, marks)
    return {"sections": secs, "sec_of": sec_of, "nblocks": len(blocks), "bounds": bounds, "usual": usual,
            "body": body, "words": by_change, "previous": data.get("previous"), "against": data.get("against"),
            "blocks": pages}


def _parts(secs, blocks):
    """Each section's `part` (the map folds the appendix, VISUAL.md §5.1): `front` (title and abstract), `references`
    (a section holding reference entries, or an unnumbered References or Bibliography), `appendix` (a section numbered
    by a letter, as after \\appendix, or an unnumbered Appendix, and every section after the first of them but a
    reference list), else `body`."""
    appendix = False
    for i, s in enumerate(secs):
        if i == 0:
            s["part"] = "front"
            continue
        number, name = s["number"] or "", unicodedata.normalize("NFKC", s["name"] or "").strip()
        if any(blocks[k]["kind"] == "bibitem" for k in s["content"]) or not number and fold(name) in REFERENCES:
            s["part"] = "references"
            continue
        appendix = appendix or number[:1].isalpha() or not number and bool(APPENDIX.match(name))
        s["part"] = "appendix" if appendix else "body"


def _gaps(paper, b):
    cols = state._build_layout(paper, b, "columns") or []
    return tuple(tuple(c) if c else None for c in cols)


def _round_prose(paper, rnd, gaps):
    """("ok", digest) | ("pending", None) | ("unavailable", None) for a round (OVERVIEW-v2 §5.5)."""
    n, b = rnd["n"], rnd["build"]
    if b["status"] == "failed" or not b["pdf"]:
        return "unavailable", None
    p = prose.path(paper, n)
    try:
        st = p.stat()
    except OSError:
        st = None
    digest = _digest_file(str(p), st.st_mtime_ns, st.st_size, gaps) if st else None
    if digest is not None:
        return "ok", digest
    return ("unavailable" if prose.failed(paper, n) else "pending"), None


# --- matching a round's sections to the round before's ----------------------------------------------------------

def _match(old, new, near):
    """Match the sections of round n-1 (digest `old`) to those of round n (`new`) by their paragraphs (OVERVIEW-v2
    §5.3) through `new["previous"]`: an old section goes to the new one holding most of its paragraphs; on a tie, to
    the one with its title, then to the one with more of its comments (near(i, j): comments in old section i and new
    section j), then the first. A section without paragraphs follows its heading, else its title (one that had
    paragraphs, none of them left, is removed when that heading is in a section continuing another). Returns
    ([(i | None, j | None, kind, kept, of)], {j: i}: the old section each new one continues)."""
    prev, os_, ns = new["previous"], old["sections"], new["sections"]
    kept = [Counter() for _ in os_]
    for i, s in enumerate(os_):
        for k in s["content"]:
            t = prev[k] if k < len(prev) else None
            j = new["sec_of"][t] if t is not None else None
            if j is not None:
                kept[i][j] += 1
    of = [len(s["content"]) for s in os_]
    names = [_plain(s["name"]) for s in os_], [_plain(s["name"]) for s in ns]
    targets = {}
    for i, s in enumerate(os_):
        if i == 0:
            targets[i] = [0]  # the title and abstract stay first
        elif kept[i]:
            targets[i] = sorted(kept[i], key=lambda j: (-kept[i][j], names[0][i] != names[1][j], -near(i, j), j))
        else:  # a section without paragraphs follows its heading, else its title
            t = prev[s["block"]] if s["block"] < len(prev) else None
            j = new["sec_of"][t] if t is not None else None
            if not j:
                j = next((j for j in range(1, len(ns)) if names[1][j] == names[0][i]), None)
            targets[i] = [j] if j else []
    split = {i: ts[:2] for i, ts in targets.items() if i and len(ts) > 1 and of[i]
             and kept[i][ts[1]] > SPLIT * of[i] and kept[i][ts[0]] > SPLIT * of[i]}
    primary = {0: (0, None)}  # the title and abstract continue themselves
    for i, ts in sorted(targets.items()):
        if i and ts and ts[0]:
            j = ts[0]
            rank = (kept[i][j], names[0][i] == names[1][j], near(i, j), -i)
            if j not in primary or rank > primary[j][1]:
                primary[j] = (i, rank)
    primary = {j: i for j, (i, _) in primary.items()}

    # moved: the continuing sections outside the heaviest run kept in order (weighted longest increasing run)
    pairs = sorted((i, j) for j, i in primary.items())
    weight = [max(kept[i][j], 1) for i, j in pairs]
    best, back = list(weight), [-1] * len(pairs)
    for a in range(len(pairs)):
        for z in range(a):
            if pairs[z][1] < pairs[a][1] and best[z] + weight[a] > best[a]:
                best[a], back[a] = best[z] + weight[a], z
    in_order, a = set(), (max(range(len(pairs)), key=lambda x: best[x]) if pairs else -1)
    while a >= 0:
        in_order.add(pairs[a])
        a = back[a]

    entries, sources = [], set()
    for i, s in enumerate(os_):
        ts = targets[i]
        if not ts:
            entries.append((i, None, "removed", 0, of[i]))
        elif i in split:
            for j in split[i]:
                entries.append((i, j, "split", kept[i][j], of[i]))
                sources.add(j)
        else:
            j = ts[0]
            if primary.get(j) != i and of[i] and not kept[i][j]:
                # it followed its heading into a section that continues another, and none of its paragraphs are left:
                # nothing of it went there (OVERVIEW-v2 §5.3), so it was removed, not merged with 0 kept
                entries.append((i, None, "removed", 0, of[i]))
                continue
            if primary.get(j) != i:
                kind = "merged"
            elif (i, j) not in in_order:
                kind = "moved"
            else:
                kind = "same" if names[0][i] == names[1][j] else "renamed"
            entries.append((i, j, kind, kept[i][j], of[i]))
            sources.add(j)
    for j, s in enumerate(ns):
        if j not in sources:
            entries.append((None, j, "added", 0, len(s["content"])))
    entries.sort(key=lambda e: (e[1] if e[1] is not None else len(ns) + e[0], e[0] if e[0] is not None else -1))
    return entries, primary


# --- the overview of a paper -------------------------------------------------------------------------------------

def _first_rect(rects):
    return rects[0] if rects else None


def _days(a, b):
    """Calendar days from timestamp a to timestamp (or date) b, each on its own local date."""
    da = datetime.datetime.fromisoformat(a).date()
    db = b if isinstance(b, datetime.date) else datetime.datetime.fromisoformat(b).date()
    return (db - da).days


def paper_overview(path, marks=False, key_page=None, buckets=None):
    """PaperOverview (CONTRACT.md amendment "Overview") of one paper folder; key_page: the advisor's {round, page}, and
    buckets the Map Headings answers, as the app keeps them (the ledger's own win: _facts)."""
    return _paper_overview(path, marks, key_page, buckets)[0]


def _facts(paper, lg, key_page, buckets):
    """The paper's id and its three facts (design/data/DATA.md §2.2): the ledger's, and while the ledger lacks one
    the app's (key_page, buckets; finished null)."""
    p = lg["paper"]
    return {"id": ledger.paper_id(paper, lg), "finished": p.get("finished"),
            "buckets": p["buckets"] if "buckets" in p else buckets or None,
            "key_page": p["key_page"] if "key_page" in p else key_page or None}


def _paper_overview(path, marks=False, key_page=None, buckets=None):
    """(PaperOverview, latest) where latest is {comment id: {"round", "page", "text", "created"}}, the words each
    comment is printed beside in its latest round that prints them (the Student page's examples, tags.student_tags)."""
    paper = Path(path)
    lg = ledger.load(paper)
    facts = _facts(paper, lg, key_page, buckets)
    key_page = facts["key_page"]
    rounds = lg["rounds"]
    info = {}
    for rnd in rounds:
        n = rnd["n"]
        gaps = _gaps(paper, rnd["build"])
        status, digest = _round_prose(paper, rnd, gaps)
        info[n] = {"rnd": rnd, "gaps": gaps, "prose": status, "digest": digest,
                   "changes": analysis.changes(paper, n) if rnd["build"]["status"] != "failed" else []}
    # the text area of a round without paragraphs: the nearest round's, else the PDF's page
    measured = [n for n in info if info[n]["digest"] and info[n]["digest"]["usual"]]
    for n, x in info.items():
        if x["digest"] and x["digest"]["usual"]:
            x["bounds"] = x["digest"]["bounds"]
        elif measured:
            usual = info[min(measured, key=lambda m: (abs(m - n), m))]["digest"]["usual"]
            x["bounds"] = _bounder({}, usual)
        elif x["rnd"]["build"]["pdf"] and (paper / x["rnd"]["build"]["pdf"]).is_file():
            pdf = paper / x["rnd"]["build"]["pdf"]
            st = pdf.stat()
            x["bounds"] = _bounder({}, _pdf_area(str(pdf), (st.st_mtime_ns, st.st_size)))
        else:
            x["bounds"] = _bounder({}, (0.0, 792.0))

    def where(n, pos):
        """The index of the section of round n whose span holds pos (the last one for a place past its end)."""
        secs = info[n]["digest"]["sections"]
        return next((i for i in range(len(secs) - 1, -1, -1) if secs[i]["start"] <= pos), 0)

    def place(n, page, rects):
        r = _first_rect(rects)
        if page is None or r is None:
            return None
        return _pos(page, r, (r[1] + r[3]) / 2, info[n]["bounds"], info[n]["gaps"])

    # every comment's place in every round it is in
    attached = {n: {} for n in info}
    for n, x in info.items():
        for ch in x["changes"]:
            for cid in ch["attached_to"]:
                attached[n].setdefault(cid, []).append(ch)
    paths = {}  # id -> {n: [round, state, page, pos, section index, response, answer]}
    for c in lg["comments"]:
        recs = {int(k): r for k, r in c["rounds"].items()}
        path_ = paths[c["id"]] = {}
        for n in sorted(recs):
            if n not in info:
                continue
            rec, a = recs[n], recs[n]["anchor"]
            st = rec["anchor_state"]
            page, pos = (a["page"], place(n, a["page"], a["rects"])) if a else (None, None)
            if st == "orphan" or a is None:
                where_ = "unplaced"
            elif st == "gone":
                where_ = "gone"
                if pos is None:  # the deletion point has no place in the PDF: the change that took it out
                    ch = next((ch for ch in attached[n].get(c["id"], ()) if ch.get("page") is not None and ch["rects"]),
                              None)
                    if ch:
                        page, pos = ch["page"], place(n, ch["page"], ch["rects"])
            else:
                where_ = "placed" if pos is not None else "unplaced"
            if where_ == "unplaced":
                page = pos = None
            response = answer = None
            if n == c["created_round"]:
                response = "new"
            elif rec.get("revived"):  # reopened after it was closed: what the student did since it was closed
                response = "edited" if st in ("changed", "gone") or c["id"] in attached[n] else \
                    "note_only" if rec.get("student_note") else "untouched"
                answer = VERDICT.get(rec["verdict"]) or ("left_open" if info[n]["rnd"]["closed"] else "to_check")
            else:
                prev = recs.get(n - 1) or {}
                if st in ("changed", "gone") or c["id"] in attached[n]:
                    response = "edited"
                elif rec.get("student_note"):
                    response = "note_only"
                elif c["created_round"] == n - 1 or prev.get("verdict") == "reopened":
                    response = "untouched"
                else:
                    response = "waiting"
                answer = VERDICT.get(rec["verdict"]) or ("left_open" if info[n]["rnd"]["closed"] else "to_check")
            sec = where(n, pos) if pos is not None and info[n]["digest"] else None
            path_[n] = [n, where_, page, pos, sec, response, answer, st, bool(rec.get("revived"))]

    def near(n):
        """(i, j) -> the comments in section i of round n-1 and section j of round n (a tie-breaker)."""
        pairs = Counter()
        for p in paths.values():
            if n - 1 in p and n in p and p[n - 1][4] is not None and p[n][4] is not None:
                pairs[(p[n - 1][4], p[n][4])] += 1
        return lambda i, j: pairs[(i, j)]

    # sections across rounds: match each round's to the round before's, and give each a key that its continuations keep
    keys, matches = {}, {}
    for n in sorted(info):
        d = info[n]["digest"]
        if d is None:
            continue
        pd = info[n - 1]["digest"] if n - 1 in info else None
        primary = {}
        if pd is not None and d["previous"] is not None and d["against"] == n - 1 \
                and len(d["previous"]) == pd["nblocks"]:
            entries, primary = _match(pd, d, near(n))
            matches[n] = entries
        used, ks = set(), []
        for j, s in enumerate(d["sections"]):
            k = keys[n - 1][primary[j]] if j in primary else FRONT if j == 0 else None
            if k is None or k in used:
                base = _slug(s["name"])
                k, m = base, 2
                while k in used or any(k == keys[n - 1][i] for j2, i in primary.items() if j2 > j):
                    k, m = "{}-{}".format(base, m), m + 1
            used.add(k)
            ks.append(k)
        keys[n] = ks

    # a gone comment whose deletion point has no place: the end of the nearest earlier section still there
    for cid, p in paths.items():
        for n, e in sorted(p.items()):
            if e[1] != "gone" or e[3] is not None or info[n]["digest"] is None:
                continue
            spans = {k: s for k, s in zip(keys[n], info[n]["digest"]["sections"])}
            before = p.get(n - 1)
            chain = keys.get(n - 1, [])
            k0 = keys[n - 1][before[4]] if before and before[4] is not None and n - 1 in keys else FRONT
            at = chain.index(k0) if k0 in chain else 0
            k = next((k for k in reversed(chain[:at + 1]) if k in spans), FRONT)
            s = spans[k]
            e[3], e[4] = round(max(s["start"], s["end"] - 0.01), 3), keys[n].index(k)

    # the rounds
    out_rounds, pending = [], []
    read = None
    created = {c["id"]: c["created_round"] for c in lg["comments"]}
    for n in sorted(info):
        x = info[n]
        rnd, d, changes = x["rnd"], x["digest"], x["changes"]
        open_ = not rnd["closed"]
        b = rnd["build"]
        rdir = paper / "r{}".format(n)
        if x["prose"] == "pending":
            pending.append(n)
        ks = keys.get(n)
        present = [(cid, p[n]) for cid, p in paths.items() if n in p]
        new = [e for cid, e in present if created[cid] == n]
        carried = [e for cid, e in present if created[cid] < n]
        responses = Counter(e[5] for e in carried)
        answers = Counter(e[6] for e in carried)
        counts = {"new": len(new), "carried": len(carried), "edited": responses["edited"],
                  "note_only": responses["note_only"], "untouched": responses["untouched"],
                  "moved_only": sum(1 for e in carried if e[7] == "moved" and e[5] in ("untouched", "waiting")),
                  "waiting": responses["waiting"], "not_found": sum(1 for e in carried if e[7] == "orphan"),
                  "resolved": answers["resolved"], "follow_up": answers["follow_up"], "kept": answers["kept"],
                  "left_open": answers["left_open"], "to_check": answers["to_check"],
                  "open_after": len(new) + len(carried) - answers["resolved"] - answers["kept"],
                  "revived": sum(1 for e in carried if e[8])}
        # the edits
        checked, asked = set(rnd.get("checked", [])), {}
        if open_ and changes:
            asked = comments.commenters(lg, n, changes)
            if read is None:
                read = prose.read_map(paper, lg) if "read" in lg else {}
        moves = {ch["id"] for ch in changes if ch["kind"] == "move"}
        words = d["words"] if d else {}
        edits, excerpts = [], {}
        for ch in changes:
            pos = place(n, ch.get("page"), ch.get("rects") or [])
            to_check = bool(open_ and state.unchecked(ch, checked, asked, read, n))
            about = ch.get("about") or {}
            move = ch["kind"] == "move" or (about.get("kind") == "file" and about.get("text", "").endswith(" moved"))
            wa, wd = (0, 0) if ch["id"] in moves else words.get(ch["id"], [0, 0])
            edits.append([ch["id"], ch.get("page") if pos is not None else None,
                          round(pos, 3) if pos is not None else None,
                          ks[where(n, pos)] if pos is not None and d else None,
                          list(ch["attached_to"]), not ch["attached_to"], to_check, move, wa if d else None,
                          wd if d else None])
            excerpts[ch["id"]] = _excerpt(ch)
        total_words = {"body": d["body"],
                       "added": sum(v[0] for cid, v in words.items() if cid not in moves),
                       "deleted": sum(v[1] for cid, v in words.items() if cid not in moves)} if d else None
        # sections, heat, pages
        spans = [[ks[i], s["title"], round(s["start"], 3), round(s["end"], 3), s["part"]]
                 for i, s in enumerate(d["sections"])] if d else None
        if d:
            end = max([spans[-1][3]] + [e[3] for _, e in present if e[3] is not None] +
                      [e[2] for e in edits if e[2] is not None])
            if b["pages"] and (not d["sections"][-1]["content"] or spans[-1][3] < b["pages"] - 1):
                # whole pages after the last part: a listing that runs on (its place is its first page's box), a
                # reference list without entries (biblatex)
                end = max(end, float(b["pages"]))
            spans[-1][3] = round(end, 3)  # every place counted in a section is drawn in it
        heat = None
        if d:
            rows = {k: [k, 0, 0, 0, 0, 0, 0] for k in ks}
            for cid, e in present:
                if e[4] is not None:
                    row = rows[ks[e[4]]]
                    row[1 if created[cid] == n else 2] += 1
                    row[3] += e[6] == "to_check"
            for e in edits:
                if e[3] is not None:
                    row = rows[e[3]]
                    row[4] += 1
                    row[5] += e[8] or 0
                    row[6] += e[9] or 0
            heat = [rows[k] for k in ks]
        pages = Counter()
        for _, e in present:
            if e[2] is not None:
                pages[(e[2], "comments")] += 1
        for e in edits:
            if e[1] is not None:
                pages[(e[1], "changes")] += 1
        busy = sorted({p for p, _ in pages}, key=lambda p: (-(pages[(p, "comments")] + pages[(p, "changes")]), p))
        item = {"n": n, "created": rnd["created"], "received": rnd.get("received"), "closed": rnd["closed"],
                "closed_at": rnd["closed_at"], "build": {"status": b["status"], "pages": b["pages"]},
                "pdf": str(paper / b["pdf"]) if b["pdf"] else None,
                "final_pdf": str(rdir / "final.pdf") if rnd["closed"] and (rdir / "final.pdf").exists() else None,
                "email": str(rdir / "email.txt") if rnd["closed"] and (rdir / "email.txt").exists() else None,
                "finishes": state.finishes(paper, rnd), "prose": x["prose"], "comments": counts,
                "changes": {"total": len(changes), "requested": sum(1 for ch in changes if ch["attached_to"]),
                            "unrequested": sum(1 for ch in changes if not ch["attached_to"]),
                            "to_check": sum(1 for e in edits if e[6])},
                "words": total_words, "unplaced": sum(1 for _, e in present if e[1] == "unplaced"),
                "spans": spans,
                "match": [[keys[n - 1][i] if i is not None else None, ks[j] if j is not None else None, kind, kp, of]
                          for i, j, kind, kp, of in matches[n]] if n in matches else None,
                "heat": heat, "edits": edits, "excerpts": excerpts,
                "pages": [{"page": p, "comments": pages[(p, "comments")], "changes": pages[(p, "changes")]}
                          for p in busy]}
        if marks:
            item["marks"] = _marks(lg, n, changes)
        out_rounds.append(item)

    # comments with their paths, and the paper's sections
    out_comments, ever, written, written_as, latest = [], {}, Counter(), {}, {}
    for c in lg["comments"]:
        p = paths[c["id"]]
        entries = []
        for n, e in sorted(p.items()):
            key = keys[n][e[4]] if e[4] is not None and n in keys else None
            entries.append([n, e[1], e[2], round(e[3], 3) if e[3] is not None else None, key, e[5], e[6]])
            if key is not None:
                ever.setdefault(key, set()).add(c["id"])
                if n == c["created_round"]:
                    written[key] += 1
                    s = info[n]["digest"]["sections"][e[4]]  # the heading it was written under, as it was then
                    written_as.setdefault(key, Counter())[(s["name"], s["number"])] += 1
        out_comments.append({"id": c["id"], "created_round": c["created_round"], "kind": c["kind"],
                             "color": comments.color(c), "note": c["note"], "path": entries, "tags": tags.ids(c),
                             "revived": [{"round": int(k), "from": r["revived"]["from"]}
                                         for k, r in sorted(c["rounds"].items(), key=lambda kr: int(kr[0]))
                                         if r.get("revived")],
                             "revivable": comments.revivable(lg, c)})
        shown = next(((int(k), r["anchor"]) for k, r in sorted(c["rounds"].items(), key=lambda kr: -int(kr[0]))
                      if r["anchor"] and r["anchor"].get("text")), None)
        latest[c["id"]] = {"round": shown[0] if shown else c["created_round"],
                           "page": shown[1]["page"] if shown else None, "text": shown[1]["text"] if shown else "",
                           "created": c.get("created")}
    seen = {}
    for n in sorted(keys):
        for k, s in zip(keys[n], info[n]["digest"]["sections"]):
            first = seen.setdefault(k, {"key": k, "first": n})
            first.update(title=s["title"], last=n, number=s["number"], name=s["name"], part=s["part"])
    last_ok = max(keys) if keys else None
    sections = [{"key": s["key"], "title": s["title"], "name": s["name"],
                 "suggested_bucket": "abstract" if s["key"] == FRONT else suggested_bucket(s["name"], s["number"]),
                 "first": s["first"], "last": s["last"], "gone": s["last"] != last_ok,
                 "part": s["part"], "comments": len(ever.get(s["key"], ())), "written": written[s["key"]],
                 "written_as": [{"name": name, "number": number, "written": k}
                                for (name, number), k in written_as.get(s["key"], Counter()).items()]}
                for s in seen.values()]
    p = lg["paper"]
    ov = {"paper": dict({"title": p["title"], "student": p["student"], "created": p.get("created")}, **facts),
          "summary": state.summary(paper, lg), "sections": sections, "rounds": out_rounds,
          "comments": out_comments, "threads": _threads(lg, paths), "pending": pending,
          "key_page": _key_page(info, out_rounds, key_page), "tag_names": dict(lg.get("tag_names") or {})}
    ov["tags"] = tags.paper_tags(ov)
    return ov, latest


def _key_block(d, page):
    """The block that stands for a page of a round (its digest): the largest figure or table on it, else the first
    paragraph or item that starts on it, else the first block read in the PDF that starts on it; None without one."""
    blocks = d["blocks"]
    figs = [(area[page], -k) for k, (kind, _, area) in enumerate(blocks) if kind in KEY_KINDS and area.get(page)]
    if figs:
        return -max(figs)[1]
    for kinds in (("paragraph", "item"), prose.READ):
        k = next((k for k, (kind, first, _) in enumerate(blocks) if kind in kinds and first == page), None)
        if k is not None:
            return k
    return None


def _key_page(info, rounds, chosen):
    """The paper's key page (TAGS.md §7): in its latest built round, the page the advisor chose (Set as Key Page:
    `key_pages`, {round, page}) followed there through the rounds' paragraphs (prose.json `previous`: the page now of
    the block that stood for the chosen page, `followed` "block"), else the same page number (`followed` "page"); without
    a choice, the busiest page (most comments and edits, the first of equals; MapRules.keyPage). None without a built
    round."""
    built = [r for r in rounds if r["pdf"] and r["build"]["status"] != "failed" and (r["build"]["pages"] or 0) > 0]
    if not built:
        return None
    last = built[-1]
    L, pages = last["n"], last["build"]["pages"]
    if not chosen:
        return {"round": L, "page": last["pages"][0]["page"] if last["pages"] else 0, "chosen": False, "followed": None}
    k, page = chosen["round"], chosen["page"]
    same = {"round": L, "page": min(max(page, 0), pages - 1), "chosen": True}
    if k == L:
        return dict(same, followed=None)
    d = info[k]["digest"] if k in info and k < L else None
    idx = _key_block(d, page) if d else None
    for j in range(k + 1, L + 1):
        if idx is None:
            break
        dj, dp = info[j]["digest"], info[j - 1]["digest"]
        if not dj or not dp or dj["against"] != j - 1 or dj["previous"] is None \
                or len(dj["previous"]) != dp["nblocks"]:
            idx = None
            break
        idx = dj["previous"][idx]
    now = info[L]["digest"]["blocks"][idx][1] if idx is not None else None
    if now is None:
        return dict(same, followed="page")
    return {"round": L, "page": now, "chosen": True, "followed": "block"}


def _excerpt(ch, limit=60):
    """The first printed words of a change, for a help tag: what the engine says it is (`about`), else the words it
    changed as the new round prints them (its context's `changed` spans), else those it took out as the round before
    printed them, else its source text without LaTeX's commands, braces and comments (`_unlatex`)."""
    about = ch.get("about")
    text = about["text"] if about and about.get("text") else ""
    for side in ("now", "before"):
        ctx = (ch.get("context") or {}).get(side)
        if not text and isinstance(ctx, dict) and ctx.get("text") and ctx.get("changed"):
            text = " ".join(ctx["text"][s:e] for s, e in ctx["changed"])
    if not text:
        source = ch.get("new_text") or ch.get("old_text") or ""
        text = _unlatex(source) or source
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


_COMMENT = re.compile(r"(?<!\\)%[^\n]*")
_COMMAND = re.compile(r"\\(?:(?:begin|end)\{[^}]*\}(?:\[[^\]]*\])?|[A-Za-z@]+\*?(?:\[[^\]]*\])?|.)")


def _unlatex(source):
    """A source text as words: comments, environments' \\begin and \\end, commands (with an optional argument in
    brackets) and braces taken out, a command's braced argument kept ("\\section{Conclusion} Close" → "Conclusion
    Close"); `~` is a space."""
    def command(m):  # a named command goes; an escaped character (\\%, \\&) stays as itself; \\\\ is a space
        s = m.group(0)
        return " " if s[1].isalpha() or s[1] == "@" or s in ("\\\\", "\\ ") else s[1:]
    text = _COMMAND.sub(command, _COMMENT.sub("", source))
    return " ".join(text.replace("{", "").replace("}", "").replace("~", " ").split())


def _marks(lg, n, changes):
    out = []
    for c in lg["comments"]:
        rec = c["rounds"].get(str(n))
        a = rec and rec["anchor"]
        if a and a["page"] is not None:
            out += [[a["page"], "comment"] + list(r) + [c["id"]] for r in a["rects"]]
    for ch in changes:
        if ch.get("page") is not None:
            out += [[ch["page"], "change"] + list(r) + [ch.get("id")] for r in ch.get("rects") or ()]
    return out


def _threads(lg, paths):
    """How the paper's comments closed: rounds from written to decided, counting only rounds you answered in."""
    out = {"comments": 0, "resolved": 0, "kept": 0, "open": 0, "followed_up": 0, "untouched_after_follow_up": 0,
           "revived": 0, "closed_after": {"1": 0, "2": 0, "3+": 0}}
    for c in lg["comments"]:
        recs = sorted((int(k), r) for k, r in c["rounds"].items())
        out["comments"] += 1
        last = recs[-1][1]["verdict"]
        if last in ("verified", "wontfix"):
            out["resolved" if last == "verified" else "kept"] += 1
            answered = sum(1 for k, r in recs if k > c["created_round"] and r["verdict"])
            out["closed_after"]["3+" if answered >= 3 else str(max(answered, 1))] += 1
        else:
            out["open"] += 1
        if any(r["verdict"] == "reopened" for _, r in recs):
            out["followed_up"] += 1
        if any(r.get("revived") for _, r in recs):  # reopened after it was closed (not a follow-up)
            out["revived"] += 1
        p = paths.get(c["id"], {})
        if any(r["verdict"] == "reopened" and k + 1 in p and p[k + 1][5] == "untouched" for k, r in recs):
            out["untouched_after_follow_up"] += 1
    return out


# --- students ------------------------------------------------------------------------------------------------------

def _land_column(key, name, number):
    """The Student page's column of a heading: its standard section, else ("", its own name)."""
    b = "abstract" if key == FRONT else suggested_bucket(name, number)
    return b if b in TITLES else ("", name)


def _students(items, buckets, today, latest=None, tag_order=None):
    """The Student page's numbers for each student among the papers (grouped by folded name, fold); latest: per paper
    the words its comments are printed beside (_paper_overview), for the writing profile's examples (tags)."""
    groups = {}
    latest = latest or {}
    for path, ov in items:
        groups.setdefault(fold(ov["paper"]["student"]), []).append((path, ov))
    out = []
    for group in groups.values():
        cols, rows = [], []  # a column: a standard section's id, or ("", a section's own name)
        for path, ov in group:
            if not ov["rounds"]:  # a paper without rounds has no comments to land
                continue
            mapping = buckets.get(path) or {}
            counts = Counter()
            for s in ov["sections"]:
                if s["key"] in mapping:  # the advisor's answer holds for every comment of the section
                    col = mapping[s["key"]]
                    parts = [(col if col in TITLES else ("", s["name"]), s["written"])]
                else:  # each comment where it was written: the heading it had then (a later rename does not move it)
                    parts = [(_land_column(s["key"], w["name"], w["number"]), w["written"])
                             for w in s.get("written_as") or ()] \
                        or [(s["suggested_bucket"] if s["suggested_bucket"] in TITLES else ("", s["name"]), 0)]
                for col, k in parts:
                    if col in STANDARD or k:
                        counts[col] += k
                        if col not in cols:
                            cols.append(col)
            rows.append((path, counts))
        cols = [c for c in STANDARD if c in cols] + [c for c in cols if c not in STANDARD]
        time = []
        for path, ov in group:
            rs = ov["rounds"]
            for r, nx in zip(rs, rs[1:] + [None]):
                failed = r["build"]["status"] == "failed"
                if r["closed"] and nx and not failed:  # the next import, whether it built or not
                    time.append({"path": path, "round": r["n"], "next": nx["n"], "open": False,
                                 "you": _days(r["created"], r["closed_at"]),
                                 "student": _days(r["closed_at"], nx["created"]),
                                 "received": _days(r["closed_at"], nx["received"]) if nx.get("received") else None})
                elif not r["closed"]:  # with you, a failed build too (decision 10)
                    time.append({"path": path, "round": r["n"], "next": None, "open": True,
                                 "you": _days(r["created"], today), "student": None, "received": None,
                                 "failed": failed})
        closed = []
        for path, ov in group:
            if not ov["rounds"]:
                continue
            t = ov["threads"]
            closed.append({"path": path, "1": t["closed_after"]["1"], "2": t["closed_after"]["2"],
                           "3+": t["closed_after"]["3+"], "open": t["open"], "followed_up": t["followed_up"],
                           "untouched_after_follow_up": t["untouched_after_follow_up"], "revived": t.get("revived", 0)})
        keys = ("1", "2", "3+", "open", "followed_up", "untouched_after_follow_up", "revived")
        out.append({"student": group[0][1]["paper"]["student"], "papers": [path for path, _ in group],
                    "rounds": sum(len(ov["rounds"]) for _, ov in group),
                    "comments": sum(ov["threads"]["comments"] for _, ov in group),
                    "land": {"columns": [{"bucket": c, "title": TITLES[c]} if c in TITLES else
                                         {"bucket": None, "title": c[1]} for c in cols],
                             "papers": [{"path": path, "counts": [counts[c] for c in cols]} for path, counts in rows],
                             "total": [sum(counts[c] for _, counts in rows) for c in cols]},
                    "time": time,
                    "closed": {"papers": closed, "total": {k: sum(r[k] for r in closed) for k in keys}},
                    "tags": tags.student_tags([(path, ov, latest.get(path) or {}) for path, ov in group], tag_order)})
    return out


def overview(papers, marks=False, buckets=None, today=None, key_pages=None, tag_order=None):
    """{"papers": [{"path", "overview"} | {"path", "error"}], "students": [...]} for paper folders, in the order
    given (a folder that cannot be read gets its error); buckets: {path: {section key: standard section or null}},
    the advisor's own matching of headings to the Student page's columns (else the suggestions); key_pages: {path:
    {round, page}}, the pages the advisor chose (Set as Key Page), both as the app keeps them, while a ledger lacks
    its own (paper.buckets, paper.key_page: those win); tag_order: the advisor's visible tags in order, which
    the writing profile's facts and For the next draft pick from (tags.student_tags)."""
    out, ok, latest = [], [], {}
    for p in papers:
        try:
            ov, latest[p] = _paper_overview(p, marks, (key_pages or {}).get(p), (buckets or {}).get(p))
        except Exception as e:  # one paper that cannot be read (or is being ingested) does not fail the others
            if not isinstance(e, (EngineError, OSError, ValueError)):
                traceback.print_exc(file=sys.stderr)
            out.append({"path": p, "error": str(e) or type(e).__name__})
            continue
        out.append({"path": p, "overview": ov})
        ok.append((p, ov))
    return {"papers": out, "students": _students(ok, {p: ov["paper"]["buckets"] for p, ov in ok},
                                                 today or datetime.date.today(), latest, tag_order)}
