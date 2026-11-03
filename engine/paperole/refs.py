"""A round's cited references (design/pdf-reader/PLAN.md P1.3; CONTRACT.md amendment "References").

Each cited entry as the round prints it: its key and printed label, its .bib fields (else what its bibitem block tells:
authors, title, venue, year, arXiv id, DOI, pages, URL), whether it is a preprint (Paperlib's rule), its printed words
and its place in the build PDF, all from checks._Paper (the .aux, .bib, .bbl and link table same_work and no_year
read). They are written into rN/refs.json with the round's checks (checks.build, `keep`), beside the results of the
online look-ups the app stores (`store`: Semantic Scholar's and Google Scholar's; the engine fetches nothing), from
which the online checks are built; checks.json records the results' digest (`state`), so new results make it stale. A
cache outside the round's checksums, as checks.json is, written atomically under the ledger's lock; the entries are
rebuilt with the checks, the results are kept.
"""
import functools
import hashlib
import json
import re
import unicodedata
from datetime import datetime
from pathlib import Path

from . import EngineError, checks, disk, ledger

SCHEMA = 1
SOURCES = {"semantic_scholar": "Semantic Scholar", "google_scholar": "Google Scholar"}
# Paperlib's rule: a preprint's venue is empty or names a preprint server
PREPRINT = re.compile(r"\b(arxiv|biorxiv|medrxiv|chemrxiv|openreview|corr)\b", re.I)
SERVERS = {"arxiv": "arXiv", "corr": "arXiv", "biorxiv": "bioRxiv", "medrxiv": "medRxiv", "chemrxiv": "ChemRxiv",
           "openreview": "OpenReview"}
# the fields that say where an entry appeared, in the order one is taken as its venue
VENUE_FIELDS = ("journal", "journaltitle", "booktitle", "howpublished", "school", "institution", "publisher")
ARXIV_ID = r"(\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?"
ARXIV = re.compile(r"arXiv:\s*" + ARXIV_ID, re.I)  # "arXiv preprint arXiv:2010.11929", an eprint's "arXiv:…"
ARXIV_ABS = re.compile(r"\babs/" + ARXIV_ID)  # DBLP's CoRR volume "abs/2010.11929"
ARXIV_URL = re.compile(r"arxiv\.org/(?:abs|pdf)/" + ARXIV_ID, re.I)
DOI = re.compile(r"(?:doi\.org/|doi:\s*)?(10\.\d{4,9}/[^\s{}]+)", re.I)
URL = re.compile(r"\\url\s*\{([^{}]*)\}|(https?://[^\s{}]+)")
# the common CS and ML venues: short name -> long names, folded (fold_venue)
VENUES = {
    "NeurIPS": ("nips", "advances in neural information processing systems", "neural information processing systems",
                "conference on neural information processing systems"),
    "ICML": ("international conference on machine learning",),
    "ICLR": ("international conference on learning representations",),
    "CVPR": ("conference on computer vision and pattern recognition", "computer vision and pattern recognition",
             "ieee conference on computer vision and pattern recognition",
             "ieee cvf conference on computer vision and pattern recognition",
             "ieee computer society conference on computer vision and pattern recognition"),
    "ICCV": ("international conference on computer vision", "ieee international conference on computer vision",
             "ieee cvf international conference on computer vision"),
    "ECCV": ("european conference on computer vision",),
    "WACV": ("winter conference on applications of computer vision",
             "ieee cvf winter conference on applications of computer vision"),
    "AAAI": ("aaai conference on artificial intelligence",),
    "IJCAI": ("international joint conference on artificial intelligence",),
    "AISTATS": ("international conference on artificial intelligence and statistics",),
    "UAI": ("conference on uncertainty in artificial intelligence", "uncertainty in artificial intelligence"),
    "COLT": ("conference on learning theory",),
    "CoRL": ("conference on robot learning",),
    "ACL": ("annual meeting of the association for computational linguistics",
            "meeting of the association for computational linguistics"),
    "EMNLP": ("conference on empirical methods in natural language processing",
              "empirical methods in natural language processing"),
    "NAACL": ("conference of the north american chapter of the association for computational linguistics",
              "conference of the north american chapter of the association for computational linguistics human "
              "language technologies", "north american chapter of the association for computational linguistics"),
    "COLING": ("international conference on computational linguistics",),
    "TACL": ("transactions of the association for computational linguistics",),
    "KDD": ("acm sigkdd international conference on knowledge discovery and data mining",
            "acm sigkdd international conference on knowledge discovery data mining",
            "international conference on knowledge discovery and data mining", "knowledge discovery and data mining"),
    "SIGIR": ("international acm sigir conference on research and development in information retrieval",),
    "WWW": ("web conference", "acm web conference", "world wide web conference",
            "international world wide web conference", "international conference on world wide web"),
    "SIGMOD": ("international conference on management of data",
               "acm sigmod international conference on management of data"),
    "VLDB": ("vldb endowment", "pvldb", "international conference on very large data bases"),
    "OSDI": ("usenix symposium on operating systems design and implementation",
             "symposium on operating systems design and implementation"),
    "SOSP": ("acm symposium on operating systems principles", "symposium on operating systems principles"),
    "NSDI": ("usenix symposium on networked systems design and implementation",
             "symposium on networked systems design and implementation"),
    "EuroSys": ("european conference on computer systems",),
    "ICSE": ("international conference on software engineering",),
    "CHI": ("chi conference on human factors in computing systems", "conference on human factors in computing systems"),
    "ICASSP": ("ieee international conference on acoustics speech and signal processing",
               "international conference on acoustics speech and signal processing"),
    "ICRA": ("ieee international conference on robotics and automation",
             "international conference on robotics and automation"),
    "IROS": ("ieee rsj international conference on intelligent robots and systems",
             "international conference on intelligent robots and systems"),
    "JMLR": ("journal of machine learning research",),
    "TMLR": ("transactions on machine learning research",),
    "TPAMI": ("pami", "ieee transactions on pattern analysis and machine intelligence",
              "transactions on pattern analysis and machine intelligence"),
}
_SHORTS = {s.lower(): s for s in VENUES}
_ALIASES = dict({s.lower(): s for s in VENUES}, **{f: s for s, longs in VENUES.items() for f in longs})


def path(paper, n):
    return Path(paper) / "r{}".format(n) / "refs.json"


def load(paper, n):
    """Round n's refs.json ({"schema", "round", "entries", "results"}) when it can be read (cached by path,
    modification time and size), else None."""
    p = path(paper, n)
    try:
        st = p.stat()
    except OSError:
        return None
    data = _load(str(p), st.st_mtime_ns, st.st_size)
    ok = isinstance(data, dict) and data.get("schema") == SCHEMA and isinstance(data.get("results"), dict)
    return data if ok else None


@functools.lru_cache(maxsize=8)
def _load(p, mtime, size):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def results(paper, n):
    """The results stored for round n: {source: {key: Result}} ({} when none)."""
    data = load(paper, n)
    return data["results"] if data else {}


def digest(found):
    """The digest of a round's results, as checks.json records it."""
    return hashlib.sha1(json.dumps(found, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def state(paper, n):
    """What checks.json's "refs" must be for it to be current: the stored results' digest, or None while refs.json
    holds no entries (none written, or damaged: the checks build them again)."""
    data = load(paper, n)
    return digest(data["results"]) if data and isinstance(data.get("entries"), list) else None


def _write(paper, n, entries, found, attempts=None):
    data = {"schema": SCHEMA, "round": n, "entries": entries, "results": found, "attempts": attempts or {}}
    disk.atomic_write(path(paper, n), json.dumps(data, ensure_ascii=False, separators=(",", ":")))


def keep(paper, n, entries):
    """Write round n's entries into refs.json, keeping the results stored there (under the ledger's lock: a result
    stored meanwhile is never lost); nothing is written when they are the same."""
    with ledger.locked(paper):
        data = load(paper, n)
        if data is None or data.get("entries") != entries:
            _write(paper, n, entries, data["results"] if data else {}, (data or {}).get("attempts"))


def store(paper, n, source, found, attempts=None):
    """Merge one source's results into round n's refs.json (by key, a later result replacing an earlier) and return how
    many were stored; refused for a source not in SOURCES, a result that is no {"found": bool, …}, or a key round n does
    not cite (its entries)."""
    if source not in SOURCES:
        raise EngineError("source is {}.".format(" or ".join(SOURCES)))
    if not isinstance(found, dict) or not all(isinstance(k, str) and isinstance(r, dict) and
                                              isinstance(r.get("found"), bool) for k, r in found.items()):
        raise EngineError("results is a map of reference keys to results, each with found true or false.")
    attempts = {} if attempts is None else attempts
    states = {"matched", "not_found", "unavailable", "skipped", "stopped", "limited"}
    if not isinstance(attempts, dict):
        raise EngineError("attempts is a map of reference keys to lookup outcomes.")
    for k, a in attempts.items():
        if not isinstance(k, str) or not isinstance(a, dict) or set(a) != {"status", "at"} or \
                not isinstance(a["status"], str) or a["status"] not in states or not isinstance(a["at"], str):
            raise EngineError("Each lookup outcome has a known status and an ISO timestamp.")
        try:
            at = datetime.fromisoformat(a["at"].replace("Z", "+00:00"))
            if at.tzinfo is None:
                raise ValueError()
        except ValueError:
            raise EngineError("Each lookup outcome has a timestamp with a timezone.")
        if a["status"] in {"matched", "not_found"} and (k not in found or found[k]["found"] != (a["status"] == "matched")):
            raise EngineError("A completed lookup outcome needs its matching result.")
    with ledger.locked(paper):
        data = load(paper, n)
        keys = {e["key"] for e in (data or {}).get("entries") or ()}
        for k in found.keys() | attempts.keys():
            if k not in keys:
                raise EngineError("A result for reference {}, which round {} does not cite.".format(k, n))
        if not found and not attempts:
            return 0
        stored = dict(data["results"])
        stored[source] = dict(stored.get(source) or {}, **found)
        recorded = dict(data.get("attempts") or {})
        recorded[source] = dict(recorded.get(source) or {}, **attempts)
        _write(paper, n, data["entries"], stored, recorded)
    return len(found)


# --- the entries -----------------------------------------------------------------------------------------------

def entries(p):
    """The round's cited entries (p: checks._Paper): the .aux's citations that have a .bib entry or a bibitem, in
    citation order."""
    return [_entry(p, key) for key in p.cited if key in p.bib or key in p.bibitems]


def _entry(p, key):
    typ, fields = p.bib.get(key, (None, None))
    e = _from_bib(p, fields) if fields is not None else _from_bibitem(p, p.bibitems[key][1])
    parts = p.entry_parts(key)
    label = p.cite_label(key)
    place = checks._place(parts[0][0], [r for page, r in parts if page == parts[0][0]], label) if parts else None
    return {"key": key, "label": label, "type": typ, "title": e["title"], "authors": e["authors"], "year": e["year"],
            "venue": e["venue"], "arxiv": e["arxiv"], "doi": e["doi"], "pages": e["pages"], "url": e["url"],
            # a preprint names its server or has an arXiv id (review 2026-11-01: an empty venue alone made a hand-written
            # list's "In ICLR 2021" in plain type, or a @misc web page, a preprint)
            "preprint": bool(e["venue"] and PREPRINT.search(e["venue"])) or bool(e["arxiv"]),
            "printed": " ".join(w[4] for _, w in p.entry_words(key)), "place": place}


def _plain(p, tex):
    """The display text of a piece of TeX (NFC: an accent joined to its letter), its spaces collapsed, or None when
    empty."""
    s = unicodedata.normalize("NFC", " ".join(p.ctx.plain(tex).split())) if tex and tex.strip() else ""
    return s or None


def _from_bib(p, fields):
    """An entry's fields from its .bib entry (TeX as plain text; the URL and DOI as written)."""
    year = _plain(p, fields.get("year"))
    if not year:
        m = re.match(r"\s*(\d{4})", fields.get("date", ""))
        year = m.group(1) if m else None
    venue = next((_plain(p, fields[f]) for f in VENUE_FIELDS if fields.get(f, "").strip()), None)
    return {"title": _plain(p, fields.get("title")),
            "authors": [_plain(p, a) for a in names(fields.get("author", "")) if a.strip().lower() != "others"],
            "year": year, "venue": venue, "arxiv": _arxiv(fields), "doi": _doi(fields),
            "pages": _plain(p, fields.get("pages")), "url": _url(fields.get("url", "")) or None}


def _from_bibitem(p, tex):
    """An entry's fields from its bibitem's TeX (a .bbl's or a thebibliography's), where they can be told: the authors
    before the first \\newblock, the title its first, the venue a later one's \\emph, the year the last one printed,
    "pages 3--9" or "pp. 3--9", the arXiv id, DOI and URL anywhere."""
    blocks = re.split(r"\\newblock\b", tex)
    authors = (_plain(p, blocks[0]) or "").rstrip(". ") if len(blocks) > 1 else ""
    venue = next((m.group(1) for b in blocks[2:] for m in [re.search(r"\\(?:emph|textit)\s*\{([^{}]*)\}", b)] if m),
                 None)
    text = _plain(p, tex) or ""
    years = re.findall(r"\b((?:1[89]|20)\d{2})\b", text)
    pages = re.search(r"\b(?:pages|pp\.)\s*(\d+\s*[-–—]+\s*\d+)", text)
    return {"title": (_plain(p, blocks[1]) or "").rstrip(". ") or None if len(blocks) > 1 else None,
            "authors": [a for a in re.split(r",?\s+and\s+|,\s+", authors) if a],
            "year": years[-1] if years else None, "venue": _plain(p, venue), "arxiv": _arxiv({"note": tex}),
            "doi": _doi({"note": tex}), "pages": pages.group(1) if pages else None, "url": _url(tex) or None}


def _arxiv(fields):
    """An entry's arXiv id (without its version): an eprint with archivePrefix (or eprinttype) arXiv, "arXiv:…" in a
    venue or note, CoRR's "abs/…", or an arxiv.org URL."""
    prefix = (fields.get("archiveprefix") or fields.get("eprinttype") or "").strip().lower()
    m = re.search(ARXIV_ID, fields.get("eprint", "")) if prefix == "arxiv" else None
    if m:
        return m.group(1)
    for f in ("journal", "journaltitle", "booktitle", "howpublished", "note", "eprint", "volume"):
        m = ARXIV.search(fields.get(f, ""))
        if m:
            return m.group(1)
    if "corr" in (fields.get("journal", "") + fields.get("journaltitle", "")).lower():
        m = ARXIV_ABS.search(fields.get("volume", "") + " " + fields.get("journal", ""))
        if m:
            return m.group(1)
    for f in ("url", "howpublished", "note"):
        m = ARXIV_URL.search(fields.get(f, ""))
        if m:
            return m.group(1)
    return None


def _doi(fields):
    """An entry's DOI ("10.…"): its doi field (a doi.org URL's or "doi:" prefix dropped), else a doi.org URL."""
    m = DOI.search(fields.get("doi", "").strip())
    if m:
        return m.group(1).rstrip(".,;")
    for f in ("url", "howpublished", "note"):
        m = re.search(r"doi\.org/(10\.\d{4,9}/[^\s{}]+)", fields.get(f, ""), re.I)
        if m:
            return m.group(1).rstrip(".,;")
    return None


def _url(tex):
    """The first URL of a piece of TeX (\\url{…}, else a bare http(s) one)."""
    m = URL.search(tex or "")
    return (m.group(1) or m.group(2)).strip() if m else ""


def names(field):
    """The names of a .bib author field as written (TeX), split at "and" outside braces."""
    out, depth, start, i = [], 0, 0, 0
    while i < len(field):
        c = field[i]
        depth += (c == "{") - (c == "}")
        m = re.compile(r"\s+and\s+", re.I).match(field, i) if depth == 0 and c.isspace() else None
        if m:
            out.append(field[start:i])
            start = i = m.end()
            continue
        i += 1
    out.append(field[start:])
    return [" ".join(n.split()) for n in out if n.strip()]


def name_parts(name):
    """(first, last) of a .bib name (TeX): "Last, First", "Last, Jr, First" or "First von Last"; first is "" for a
    name of one word or in braces ("{Google Research}")."""
    parts, depth, start = [], 0, 0
    for i, c in enumerate(name):
        depth += (c == "{") - (c == "}")
        if c == "," and depth == 0:
            parts.append(name[start:i].strip())
            start = i + 1
    parts.append(name[start:].strip())
    if len(parts) > 1:
        return parts[-1], parts[0]
    words, depth, start = [], 0, 0
    for i, c in enumerate(name + " "):
        depth += (c == "{") - (c == "}")
        if c.isspace() and depth == 0:
            if name[start:i].strip():
                words.append(name[start:i])
            start = i + 1
    if len(words) < 2:
        return "", name
    von = next((k for k, w in enumerate(words[:-1]) if k and w[:1].islower()), len(words) - 1)
    return " ".join(words[:von]), " ".join(words[von:])


# --- venues ----------------------------------------------------------------------------------------------------

def _strip_venue(v):
    """A venue's words without its years ("2021", "'21"), ordinals ("34th"), "Proceedings of (the)", "Proc.", a
    leading "In" or "The", punctuation or lone numbers, case kept."""
    s = "".join(c for c in unicodedata.normalize("NFKD", v) if not unicodedata.combining(c)).replace("&", " and ")
    s = re.sub(r"\b(?:19|20)\d{2}\b|'\d{2}\b|\b\d+(?:st|nd|rd|th)\b", " ", s, flags=re.I)
    s = re.sub(r"[^\w\s]|_", " ", s)
    s = re.sub(r"\b(?:proceedings|proc)\b(?:\s+of\b)?(?:\s+the\b)?|\b\d+\b", " ", s, flags=re.I)
    return re.sub(r"^(?:(?:in|the)\s+)+", "", " ".join(s.split()), flags=re.I)


def fold_venue(v):
    """A venue folded (_strip_venue, lower case): the same for two writings of one form."""
    return _strip_venue(v).lower()


def venue_name(folded):
    """The venue a folded form names: its short name when VENUES knows it (a long name, the short one, or a long one
    with the short one beside it: "international conference on machine learning icml"), else the folded form."""
    if folded in _ALIASES:
        return _ALIASES[folded]
    words = folded.split()
    for w in words:
        if w in _SHORTS and _ALIASES.get(" ".join(x for x in words if x != w)) == _SHORTS[w]:
            return _SHORTS[w]
    return folded


def venue_form(v):
    """How a venue is written: "short" (its short name, an all-capitals word of 2–8 letters or one of VENUES,
    possibly with a year), "full" (three words or more) or None (neither: "J. Y", "Nature")."""
    words = _strip_venue(v).split()
    if len(words) == 1 and (words[0].lower() in _SHORTS or re.fullmatch(r"[A-Z0-9]*", words[0]) and
                            2 <= sum(c.isalpha() for c in words[0]) <= 8):
        return "short"
    return "full" if len(words) >= 3 else None


def server(e):
    """The preprint server an entry names ("arXiv", "bioRxiv", …), else None."""
    if e["arxiv"]:
        return "arXiv"
    m = PREPRINT.search(e["venue"] or "")
    return SERVERS[m.group(1).lower()] if m else None
