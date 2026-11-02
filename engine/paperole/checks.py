"""A round's checks (design/pdf-reader/PLAN.md §6.2 P1.5; CONTRACT.md amendment "Checks").

Rules every draft should meet, found by the engine instead of the eye, each a fact with its places in the round's build
PDF: references ("??" and "[?]", a label defined twice, a float never referenced, before its first reference or far
after it), the bibliography (one work under two keys, capitals the style lowered, an entry without a year or a venue,
the list written two ways or with a TeX leftover, and from the look-ups the app stores in refs.json a preprint
published since, a work no source finds, a record that differs), consistency (one word spelt two ways, one kind of
reference written two ways), typesetting (overfull lines, straight quotes in the source, a doubled word) and the
submission (Type 3 or unembedded fonts, draft markers, \\todo notes, coloured text and, for a paper meant to be
anonymous, what names its authors). From the link table (links.json),
prose.json's blocks, the build's .aux, .bbl, .log and synctex, the .bib, the source and the PDF's words, fonts, colours
and metadata, and refs.json's results; no network, nothing judged: a check states only what it found. `build` writes
rN/checks.json, a cache outside the round's checksums, as links.json is, and only when the app asks (the checks RPC,
while the advisor has Checks on), with the cited entries in rN/refs.json (refs.py); a file with another CHECKS,
prose.PARSER or links.LINKS is stale, and so is one built without the link table once the round has one, or with other
results than refs.json holds. Building never fails a request
(build_quietly), and a check that fails is left out alone.
"""
import bisect
import collections
import functools
import json
import os
import re
import sys
import traceback
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

import pymupdf

from . import anchor, comments, links, project, prose, refs, texdiff

# stored in checks.json, with prose.PARSER and links.LINKS (the blocks and the table it reads); other values: stale
# (2: biblatex's citations and .bib, places in reading order, a range of references covers its middle floats, an
# item's label before a sentence, the parts TeX skips, review anonymous only for the venues that mean it, …;
# 3: a \todo only when the PDF prints it; 4: each check's key; 5: the references' format and online checks, refs.json)
CHECKS = 5
SCHEMA = 1
GROUPS = ("references", "bibliography", "consistency", "typesetting", "submission")
OVERFULL = 1.0  # points: an overfull line at most this much too wide is not reported
FAR = 2  # pages: a float this many pages or more after its first reference is far from it
LINK_HEIGHT = 5.0  # points: a link rect at least this high excuses the colour of the words in it (colorlinks)
GREY = 24  # of 255: a colour whose channels lie at most this far apart is black or grey
EXCERPT = 5  # words of a run of coloured text in its row

CODES = {"undefined_ref": "references", "undefined_cite": "references", "label_twice": "references",
         "float_unreferenced": "references", "float_before": "references", "float_far": "references",
         "same_work": "bibliography", "lowered_caps": "bibliography", "no_year": "bibliography",
         "no_venue": "bibliography", "venue_forms": "bibliography", "venue_style": "bibliography",
         "author_names": "bibliography", "author_case": "bibliography", "title_case": "bibliography",
         "etal_by_hand": "bibliography", "leftovers": "bibliography", "field_mix": "bibliography",
         "page_dash": "bibliography", "arxiv_forms": "bibliography", "published_preprint": "bibliography",
         "no_record": "bibliography", "record_differs": "bibliography", "spelling": "consistency",
         "ref_style": "consistency",
         "overfull": "typesetting", "straight_quotes": "typesetting", "doubled_word": "typesetting",
         "type3_font": "submission", "unembedded_font": "submission", "draft_marker": "submission",
         "todo_note": "submission", "coloured_text": "submission", "pdf_author": "submission",
         "author_block": "submission", "acknowledgements": "submission", "personal_url": "submission"}

# the .log's messages (unwrapped: project.compile sets max_print_line)
LOG_EVENT = re.compile(
    r"LaTeX Warning: (?P<ref>Reference) [`'](?P<rname>[^']*)' on page \S+ undefined on input line (?P<rline>\d+)"
    r"|(?:LaTeX|Package natbib) Warning: (?P<cite>Citation) [`'](?P<cname>[^']*)' on page \S+ undefined on input line "
    r"(?P<cline>\d+)"
    r"|LaTeX Warning: Label [`'](?P<multi>[^']*)' multiply defined"
    r"|Overfull \\hbox \((?P<over>-?[\d.]+)pt too wide\) (?:in paragraph|in alignment|detected) at lines? "
    r"(?P<l1>\d+)(?:--(?P<l2>\d+))?"
    r"|(?P<box>(?:Overfull|Underfull|Tight|Loose) \\[hv]box)")
LOG_FILE = re.compile(r"[^\s()]+")
QUESTION = {"ref": re.compile(r"[^\w?]*\?\?[^\w?]*"), "cite": re.compile(r"[^\w?]*\?[^\w?]*")}
REF_CMD = re.compile(r"\\(?:ref|eqref|autoref|Autoref|cref|Cref|vref|Vref|nameref|Nameref|subref|labelcref|pageref|"
                     r"cpageref|Cpageref|namecref|nameCref)\*?\s*\{([^{}]*)\}|\\(?:c|C)refrange\*?\s*\{([^{}]*)\}\s*"
                     r"\{([^{}]*)\}|\\hyperref\s*\[([^\]]*)\]")
CITATION = re.compile(r"\\citation\{([^{}]*)\}|\\abx@aux@cite\{(?:[^{}]*\}\{)?([^{}]*)\}")  # BibTeX's, biblatex's
BIBDATA = re.compile(r"\\bibdata\{([^{}]*)\}")
RESOURCE = re.compile(r"\\(?:addbibresource|bibliography)\s*(?:\[[^\]]*\]\s*)?\{([^{}]*)\}")  # biblatex's preamble
# a range of references: \crefrange{a}{c}, \ref{a}--\ref{c}, \cref{a} to \ref{c} (the floats between are referenced)
RANGE = re.compile(r"\\[cC]refrange\*?\s*\{([^{}]*)\}\s*\{([^{}]*)\}|\\(?:ref|cref|Cref|autoref|Autoref)\*?\s*"
                   r"\{([^{},]*)\}(?:\s*(?:---?|–|-)\s*|[\s~]+to[\s~]+)\\(?:ref|cref|Cref|autoref|Autoref)\*?\s*"
                   r"\{([^{},]*)\}")
BY_HAND = re.compile(r"\b(Figures?|Figs?\.|Tables?|Tabs?\.|Algorithms?|Algs?\.|Algo\.)[\s~]+((?:[A-Z]?\d+(?:\.\d+)*"
                     r"[a-z]?(?:\s*(?:,|and|&|–|-|to)\s*)?)+)", re.I)
BY_HAND_NOUN = {"fig": "Figure", "tab": "Table", "alg": "Algorithm"}

# the bibliography: the fields that say where an entry of each type appeared (unknown types are not checked)
VENUES = {"article": ("journal", "journaltitle"), "inproceedings": ("booktitle",), "conference": ("booktitle",),
          "incollection": ("booktitle",), "book": ("publisher",), "phdthesis": ("school",),
          "mastersthesis": ("school",), "techreport": ("institution",),
          "misc": ("howpublished", "url", "eprint", "note", "publisher")}
VENUE_NAMES = {"journal": "a journal", "booktitle": "a booktitle", "publisher": "a publisher", "school": "a school",
               "institution": "an institution"}
WORD = re.compile(r"[A-Za-z][A-Za-z0-9]*")
# the references' format: a way of writing them is compared over FEW entries or more, and reported for a minority of at
# most MINORITY of them
FEW = 4
MINORITY = 1 / 3
TOKEN = re.compile(r"[^\W_]+(?:['’‐-][^\W_]+)*")  # a printed word: "Pre-training", "Schölkopf", "16x16"
PARTICLES = set("von van der den de del della di da du dos das le la ten ter bin al el".split())
LEFTOVER = re.compile(r"[{}\\]|(?<!\.)\.\.(?!\.)|,\s*,|\(\s*\)")
LEFTOVER_SHOWN = {"{": "{", "}": "}", "\\": "\\", ".": "..", ",": ", ,", "(": "()"}  # by the leftover's first character
ACCENTS = "¨´`ˆ˜¸"  # spacing accents: one printed alone, over or under no letter, is a leftover
FIELDS = {"doi": "DOI", "pages": "pages", "url": "URL", "publisher": "publisher", "volume": "volume", "number": "number"}
FIELD_TYPES = {"inproceedings": "inproceedings", "conference": "inproceedings", "article": "article"}
TYPE_NOUNS = {"inproceedings": "conference papers", "article": "journal articles"}
# the fields compared per type: a conference paper's volume or number is its proceedings' (NeurIPS has one, ICLR none)
TYPE_FIELDS = {"inproceedings": ("doi", "pages", "url", "publisher"), "article": tuple(FIELDS)}
ARXIV_FORMS = {"CoRR": "CoRR abs/{}", "arXiv": "arXiv:{}", "url": "arxiv.org/abs/{}"}

# consistency
BRITISH = {"modelling": "modeling", "modelled": "modeled", "labelled": "labeled", "labelling": "labeling",
           "colour": "color", "colours": "colors", "coloured": "colored", "colouring": "coloring",
           "behaviour": "behavior", "behaviours": "behaviors", "behavioural": "behavioral"}
ISE = re.compile(r"(?<=[a-z]{3})is(e|es|ed|ing|ation|ations|er|ers)$")
STOPWORDS = set("a an the and or nor but if of in on at to by for from with into onto upon as is are was were be been "
                "being it its this that these those there here then than so such not no any some every each all both "
                "one can may might must shall should will would could do does did have has had who whom whose which "
                "what when where why how per via our we you they he she his her their them us out up off over under "
                "about after before again more most much many few very also only just even well down through away "
                "back along around forward apart aside ahead behind across together".split())
SKIP_TOKEN = re.compile(r"[/@]|\w\.\w")
REF_NAMES = {"figure": "figure", "figures": "figure", "fig.": "figure", "figs.": "figure",
             "table": "table", "tables": "table", "tab.": "table", "tabs.": "table",
             "equation": "equation", "equations": "equation", "eq.": "equation", "eqs.": "equation",
             "eqn.": "equation", "eqns.": "equation", "section": "section", "sections": "section",
             "sec.": "section", "secs.": "section", "§": "section", "§§": "section",
             "algorithm": "algorithm", "algorithms": "algorithm", "alg.": "algorithm", "algo.": "algorithm",
             "appendix": "appendix", "appendices": "appendix", "app.": "appendix", "appx.": "appendix"}
SINGULAR = {"figures": "figure", "figs.": "fig.", "tables": "table", "tabs.": "tab.", "equations": "equation",
            "eqs.": "eq.", "eqns.": "eqn.", "sections": "section", "secs.": "sec.", "§§": "§",
            "algorithms": "algorithm", "appendices": "appendix"}
FAMILY_NOUNS = {"figure": "figures", "table": "tables", "equation": "equations", "section": "sections",
                "algorithm": "algorithms", "appendix": "appendices"}
NUMBER = re.compile(r"\(?(?:\d+(?:\.\d+)*[a-z]?|[A-Z](?:\.\d+)*)\)?[,.;:)]*")
EQ_NUMBER = re.compile(r"\(\d+[a-z]?\)[,.;:)]*")
ITEM_LABEL = re.compile(r"[•◦▪▫‣⁃∙·●○■□►▸➢✓✔*–—-]|\(?(?:\d+|[A-Za-z]|[ivxlcdm]+|[IVXLCDM]+)[.):]\)?")  # "•", "1)"
ABBREVIATIONS = {"al.", "e.g.", "i.e.", "cf.", "vs.", "resp.", "approx.", "fig.", "figs.", "eq.", "eqs.", "sec.",
                 "tab.", "no.", "et."}

# typesetting
SKIP_ENVS = {"verbatim", "verbatim*", "Verbatim", "Verbatim*", "BVerbatim", "LVerbatim", "lstlisting", "minted",
             "comment", "alltt", "filecontents", "filecontents*", "equation", "equation*", "align", "align*",
             "gather", "gather*", "multline", "multline*", "flalign", "flalign*", "alignat", "alignat*", "eqnarray",
             "eqnarray*", "displaymath", "math", "tikzpicture"}
ARG_COMMANDS = {"url", "href", "includegraphics", "input", "include", "label", "ref", "eqref", "autoref", "cref",
                "Cref", "pageref", "vref", "nameref", "subref", "texttt", "lstinline", "nolinkurl", "path",
                "usepackage", "documentclass", "bibliography", "bibliographystyle", "hyperref", "todo", "mintinline",
                "inputminted"}
TWO_ARGS = {"mintinline", "inputminted"}  # minted's: the language, then the code (braced or, inline, delimited)
SOURCE_TOKEN = re.compile(r'"|\\[vV]erb(?![A-Za-z])\*?|\\begin\s*\{([^{}]*)\}|\$\$|\$|\\\(|\\\[|\\([A-Za-z@]+)\*?|\\.', re.S)
DOUBLED_OK = {"that", "had"}
PAR_END = re.compile(r"\n[ \t]*\n|\\(?:begin\s*\{document\}|(?:sub)*section|chapter|paragraph|par)(?![A-Za-z])")

# submission
MARKER = re.compile(r"\W*(TODO|FIXME|XXX|TBD|TBA)\W*")
TODO = re.compile(r"\\(todo|missingfigure)(?![A-Za-z@])\*?")
# the paper's own \todo or \missingfigure, and one defined to print nothing: a mandatory argument, a body of tokens
# that print nothing ({}, \relax, \ignorespaces, \unskip, {{}}, \iffalse#1\fi)
_DEFINE = r"\\(?:(?:re)?newcommand|providecommand|DeclareRobustCommand)\*?\s*\{?\s*\\(todo|missingfigure)(?![A-Za-z@])"
_NOTHING = r"\{(?:\s|\\relax(?![A-Za-z@])|\\ignorespaces(?![A-Za-z@])|\\unskip(?![A-Za-z@])|\{\s*\}|\\iffalse\s*#\d\s*\\fi)*\}"
TODO_DEFINED = re.compile(_DEFINE + r"|\\def\s*\\(todo|missingfigure)(?![A-Za-z@])")
TODO_HIDDEN = re.compile(_DEFINE + r"\s*\}?\s*(?:\[[1-9]\]|\[[2-9]\]\s*\[[^\]]*\])\s*" + _NOTHING +
                         r"|\\def\s*\\(todo|missingfigure)\s*(?:#\d)+\s*" + _NOTHING)
TODO_DISABLE = re.compile(r"\\usepackage\s*\[[^\]]*\bdisable\b[^\]]*\]\s*\{todonotes\}")
TODO_INLINE = re.compile(r"\\(?:setuptodonotes|presetkeys\s*\{todonotes\})\s*\{[^{}]*(?<![A-Za-z])inline\b")
# TeX's conditionals: \ifthenelse{…} and etoolbox's \iftoggle{…} take arguments and have no \fi
CONDITIONAL = re.compile(r"\\newif\s*\\if[A-Za-z@]*|\\if[A-Za-z@]*(?![A-Za-z@])(?!\s*\{)|\\fi(?![A-Za-z@])")
ANONYMOUS_OPTIONS = {"anonymous", "submission", "blind", "doubleblind"}
# the classes and packages whose review option makes the paper anonymous (ACL's, CVPR's, ICCV's, ECCV's, WACV's; acmart's
# only numbers the lines, elsarticle's only doubles the spacing), and those that take none of ANONYMOUS_OPTIONS so
REVIEW_ANONYMOUS = {"acl", "acl_natbib", "cvpr", "iccv", "eccv", "wacv"}
OPTIONS_OF = {"acmart": {"anonymous"}, "elsarticle": set(), "llncs": set(), "ieeetran": set()}
AUTHOR_CMD = re.compile(r"\\(author|icmlauthor|IEEEauthorblockN|affiliation|institute|email)\*?\s*(?:\[[^\]]*\]\s*)?"
                        r"(?=\{)")
ACKNOWLEDGEMENTS = re.compile(r"\s*(?:[\dA-Z]+\.?\s+)?Acknowledge?ments?\b", re.I)
# the hosts themselves (a docs., api. or lookalike host is none of theirs), www. or gist.
HOSTED = re.compile(r"(?<![A-Za-z0-9.-])(?:https?://)?(?:www\.|gist\.)?(github\.com|gitlab\.com|bitbucket\.org|huggingface\.co)/"
                    r"([A-Za-z0-9_.-]+)(?:/([A-Za-z0-9_.-]+))?(/[A-Za-z0-9_.-]+)?", re.I)
# an account already anonymised: github.com/XXX, anonymous…, username, your-name, author
PLACEHOLDER = re.compile(r"x{3,}|anon.*|user(?:name)?|your[-_.]?.*|authors?|redacted|blind(?:ed)?", re.I)
PAGES_URL = re.compile(r"(?:https?://)?([A-Za-z0-9-]+)\.github\.io", re.I)
# "/~./enron" is "/~enron" (CMU's form); a user name never ends in "."
TILDE = re.compile(r"(?:https?://)?((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})/~(?:\./)?([A-Za-z0-9_-](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?)",
                   re.I)
RESERVED = {"orgs", "features", "topics", "about", "marketplace", "sponsors", "apps", "settings", "login", "pricing",
            "explore", "search", "collections", "site", "enterprise", "datasets", "spaces", "models", "papers",
            "docs", "blog", "users", "groups", "organizations", "learn", "readme", "trending", "new", "join", "security",
            "team", "codespaces", "customer-stories", "pulls", "issues", "notifications", "events", "sign_in", "sign_up"}
# a Hugging Face page of a repository, not a repository after an owner (datasets/squad/viewer)
HF_PAGES = {"viewer", "blob", "tree", "resolve", "raw", "discussions", "commits", "commit", "edit", "settings", "files"}
ORGS = {"google", "google-research", "google-deepmind", "deepmind", "facebookresearch", "facebook", "meta-llama",
        "microsoft", "openai", "huggingface", "pytorch", "tensorflow", "keras-team", "allenai", "nvidia", "nvlabs",
        "apple", "amazon-science", "aws", "awslabs", "ibm", "intel", "salesforce", "stanfordnlp", "eleutherai",
        "bigscience-workshop", "mistralai", "qwen", "qwenlm", "deepseek-ai", "anthropics", "tatsu-lab", "lm-sys",
        "vllm-project", "bigcode-project", "bigcode", "openai-community", "princeton-nlp", "thudm", "baidu",
        "alibaba", "tencent", "bytedance", "huggingface-course", "scikit-learn", "numpy", "scipy", "jax-ml",
        "google-research-datasets"}
COLOURS = {"Red": (220, 20, 20), "Dark red": (139, 0, 0), "Orange": (255, 140, 0), "Yellow": (230, 200, 0),
           "Olive": (128, 128, 0), "Green": (0, 160, 0), "Dark green": (0, 100, 0), "Teal": (0, 128, 128),
           "Cyan": (0, 200, 220), "Blue": (0, 0, 230), "Navy": (0, 0, 128), "Purple": (128, 0, 128),
           "Magenta": (230, 0, 230), "Pink": (255, 105, 180), "Brown": (139, 69, 19)}


def path(paper, n):
    return Path(paper) / "r{}".format(n) / "checks.json"


def load(paper, n):
    """Round n's checks.json when it exists and is current (cached by path, modification time and size), else None.
    One built without a link table is stale once the round has one, and one built from other results than refs.json
    holds (or once refs.json has no entries) is stale too (refs.state)."""
    p = path(paper, n)
    try:
        st = p.stat()
    except OSError:
        return None
    data = _load(str(p), st.st_mtime_ns, st.st_size)
    current = isinstance(data, dict) and data.get("schema") == SCHEMA and data.get("version") == CHECKS \
        and data.get("parser") == prose.PARSER and data.get("links") == links.LINKS \
        and isinstance(data.get("table"), bool) and isinstance(data.get("checks"), list) \
        and (data["table"] or links.load(paper, n) is None) and data.get("refs") == refs.state(paper, n)
    return data if current else None


@functools.lru_cache(maxsize=8)
def _load(p, mtime, size):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def build(paper, lg, n, data, table):
    """Build round n's checks.json from its build and prose data (prose.json's) and link table (links.json's, or None:
    the checks that need it find less) and refs.json's results, write the cited entries into refs.json (refs.keep),
    and return it. checks.json's "refs" is the digest of the results the checks read."""
    paper = Path(paper)
    p = _Paper(paper, lg, n, data, table)
    found = []
    try:
        p.entries
    except Exception as e:  # the cited entries cannot be told: none, and the checks that read them find nothing
        _failed("references", e)
        p.entries = []
    for code, run in RUNS:
        try:
            found += run(p)
        except Exception as e:  # that check is left out alone
            _failed(code, e)
    found.sort(key=_order)
    _keys(found, n)
    refs.keep(paper, n, p.entries)
    out = {"schema": SCHEMA, "version": CHECKS, "parser": prose.PARSER, "links": links.LINKS,
           "table": table is not None, "round": n, "refs": refs.digest(p.results), "checks": found}
    target = path(paper, n)
    tmp = target.with_name("checks.json.{}.tmp".format(os.getpid()))  # two engine processes may build it at once
    tmp.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, target)
    return out


def _failed(code, e):
    print("checks: {} failed: {}".format(code, "".join(traceback.format_exception_only(type(e), e)).strip()),
          file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


_FAILED = set()  # the builds that failed in this process (_attempt)


def _attempt(paper, lg, n):
    """A build's key: round n's checks, its build PDF, prose.json and links.json, as they are now."""
    def stamp(p):
        try:
            st = os.stat(p)
            return st.st_mtime_ns, st.st_size
        except OSError:
            return None
    return str(path(paper, n)), stamp(Path(paper) / prose._round(lg, n)["build"]["pdf"]), \
        stamp(prose.path(paper, n)), stamp(links.path(paper, n))


def build_quietly(paper, lg, n, data, table):
    """build, or None when it fails (the traceback on stderr): checks are a convenience, nothing depends on them. A
    failure is not tried again in this process until the round's PDF, prose.json or links.json changes."""
    key = None
    try:
        key = _attempt(paper, lg, n)
        if key in _FAILED:
            return None
        return build(paper, lg, n, data, table)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        if key is not None:
            _FAILED.add(key)
        return None


# --- the shape -------------------------------------------------------------------------------------------------

def _check(code, text, detail=None, note=None, places=(), ident=None, per_round=False):
    """A check. `ident`: what names the slip itself, the same while it is (a \\label, a .bib key, the spellings),
    when its words hold what changes (a count, a printed number); `per_round`: a slip known only by its place (a line,
    an amount), whose key holds for its round alone (`_keys`)."""
    return {"code": code, "group": CODES[code], "text": text, "detail": detail, "note": note, "places": list(places),
            "key": ident, "_round": per_round}


def _keys(found, n):
    """Each check's key (what Mark as OK keeps, the ledger's checks_ok): its code and ident (else its words), with
    "|r<n>" for a slip known only by its place, and "#2", "#3", … for the second and later checks of the same key
    in reading order (two “TODO” words, two "the the"); so no mark covers another slip, and one stays with the slip
    in the rounds after while it reads the same."""
    seen = {}
    for c in found:
        k = "{}|{}".format(c["code"], c["key"] if c["key"] is not None else c["text"])
        if c.pop("_round"):
            k += "|r{}".format(n)
        seen[k] = seen.get(k, 0) + 1
        c["key"] = k if seen[k] == 1 else "{}#{}".format(k, seen[k])


def _place(page, rects, text=None):
    return {"page": page, "rects": [links._rect(r) for r in rects], "text": text}


def _order(c):
    """Groups in GROUPS' order, then by the first place's page and top; checks without places last in their group."""
    first = c["places"][0] if c["places"] else None
    top = min((r[1] for r in first["rects"]), default=0.0) if first else 0.0
    return GROUPS.index(c["group"]), first is None, first["page"] if first else 0, top


def _sorted(p, places):
    """Places in reading order (_Paper.reading_key)."""
    return sorted(places, key=p.reading_key) if len(places) > 1 else list(places)


def _pages(places):
    """"p.2", "p.2 and p.5", "p.2, p.3 and p.5" (1-based) of places."""
    pages = ["p.{}".format(n + 1) for n in sorted({p["page"] for p in places})]
    return pages[0] if len(pages) == 1 else ", ".join(pages[:-1]) + " and " + pages[-1] if pages else ""


def _q(s):
    return "“{}”".format(s)


def _excerpt(text, words=EXCERPT):
    parts = text.split()
    return " ".join(parts[:words]) + ("…" if len(parts) > words else "")


def _norm(s):
    """Letters and digits only, accents and case dropped."""
    return "".join(c for c in unicodedata.normalize("NFKD", s) if c.isalnum()).lower()


def _plain_tex(s):
    """Rough plain text of a piece of TeX (a .bib title, an \\author argument): commands and braces dropped."""
    s = re.sub(r"\\[A-Za-z@]+\*?|\\.", " ", s)
    return " ".join(s.replace("{", "").replace("}", "").replace("~", " ").split())


# --- the paper -------------------------------------------------------------------------------------------------

class _Paper:
    """What the checks read of one round, each read once and only when a check needs it."""

    def __init__(self, paper, lg, n, data, table):
        rnd = prose._round(lg, n)
        self.paper, self.n = Path(paper), n
        self.pdf = self.paper / rnd["build"]["pdf"]
        self.build = self.pdf.parent
        self.src = self.paper / "r{}".format(n) / "src"
        self.main = lg["paper"]["main"]
        self.stem = Path(self.main).stem
        self.text_x = rnd["build"].get("text_x") or []
        self.columns = rnd["build"].get("columns") or []
        self.blocks = data["blocks"]
        self.links = table["links"] if table else []
        self.targets = table["targets"] if table else []
        self.stamp = anchor._stamp(self.pdf)
        self.doc = anchor._doc(self.stamp)
        self.pages = self.doc.page_count
        self._texts, self._indexed, self._dicts, self._norms, self._chars, self._entry_words = {}, {}, {}, {}, {}, {}

    # -- sources

    def text(self, file):
        """A source file's text with its comments and, after the main file's preamble (where an \\iffalse may be a
        macro's), the parts TeX skips (texdiff.HIDDEN: \\iffalse … \\fi, the comment environment) blanked (same
        offsets), or None."""
        if file not in self._texts:
            try:
                raw = comments.source_path(self.src, self.pdf, file).read_text(encoding="utf-8", errors="replace")
                t = texdiff.blank_comments(raw)
                m = re.search(r"\\begin\s*\{document\}", t) if file == self.main else None
                lo = m.end() if m else 0
                self._texts[file] = t[:lo] + texdiff.HIDDEN.sub(lambda h: re.sub(r"[^\n]", " ", h.group()), t[lo:])
            except OSError:
                self._texts[file] = None
        return self._texts[file]

    @functools.cached_property
    def body_start(self):
        """The offset of the main file's \\begin{document} end (0 when there is none)."""
        t = self.text(self.main) or ""
        m = re.search(r"\\begin\s*\{document\}", t)
        return m.end() if m else 0

    @functools.cached_property
    def preamble(self):
        return (self.text(self.main) or "")[:self.body_start]

    @functools.cached_property
    def sources(self):
        """[(file, its text, where its body starts)] of the paper's .tex files in reading order: the main file from
        \\begin{document}, then the files its blocks come from or a float \\inputs."""
        files = [self.main]
        for b in self.blocks:
            for f in [b.get("file")] + list(b.get("inputs") or ()):
                if f and f.endswith(".tex") and f not in files:
                    files.append(f)
        out = []
        for f in files:
            t = self.text(f)
            if t is not None:
                out.append((f, t, self.body_start if f == self.main else 0))
        return out

    def line_of(self, file, offset):
        return (self.text(file) or "").count("\n", 0, offset) + 1

    @functools.cached_property
    def aux_texts(self):
        """The texts of the build's .aux files (the main one and those it \\@inputs)."""
        out, seen = [], set()

        def read(p):
            if p in seen or not p.is_file():
                return
            seen.add(p)
            t = p.read_text(encoding="utf-8", errors="replace")
            out.append(t)
            for m in re.finditer(r"\\@input\{([^{}]*)\}", t):
                read(self.build / m.group(1))
        read(self.build / (self.stem + ".aux"))
        return out

    @functools.cached_property
    def aux(self):
        return prose._aux(self.build, self.stem)

    @functools.cached_property
    def ctx(self):
        return prose._Ctx({}, self.aux, False)

    @functools.cached_property
    def log(self):
        """[(kind, match, file, next line, closed)] of the .log's messages that the checks read (LOG_EVENT), with the
        source file TeX was reading (the log's stack of open files) and the one it closed last (or None)."""
        try:
            lines = (self.build / (self.stem + ".log")).read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return []
        out, stack, in_box = [], [], False
        self._closed = None
        for i, line in enumerate(lines):
            if in_box:  # a box's contents ("[]\OT1/cmr/m/n/10 text (…"): their parentheses are not files
                in_box = bool(line.strip())
                continue
            pos = 0
            for m in LOG_EVENT.finditer(line):
                self._parens(line[pos:m.start()], stack)
                pos = m.end()
                if m.group("box"):
                    in_box = "hbox" in m.group("box")  # only a \hbox's message prints its contents next
                    continue
                kind = next(k for k in ("ref", "cite", "multi", "over") if m.group(k))
                out.append((kind, m, self._log_file(stack), lines[i + 1] if i + 1 < len(lines) else "",
                            self._log_file([self._closed])))
                if kind == "over":
                    in_box = True
            if not in_box:
                self._parens(line[pos:], stack)
        return out

    def _parens(self, s, stack):
        """TeX's "(file" and ")" in a stretch of the log: a file opened or closed (other parentheses balance)."""
        for j, c in enumerate(s):
            if c == "(":
                m = LOG_FILE.match(s, j + 1)
                name = m.group() if m else ""
                stack.append(name if re.search(r"\.[A-Za-z]\w*$", name) else None)
            elif c == ")" and stack:
                self._closed = stack.pop() or self._closed

    def _log_file(self, stack):
        """The source file (relative to src, or a .bbl's name) innermost on the log's stack, or None."""
        name = next((s for s in reversed(stack) if s), None)
        if not name:
            return None
        if name.endswith(".bbl"):
            return Path(name).name
        rel = project._src_file(name, self.src)
        return rel if rel and (self.src / rel).is_file() else None

    @functools.cached_property
    def line_boxes(self):
        try:
            return anchor.line_boxes(self.pdf)
        except Exception:  # no synctex, or one that cannot be read: no places from the source
            traceback.print_exc(file=sys.stderr)
            return {}

    def boxes(self, file, line):
        """[(page, rect)] of the PDF lines that source line typesets."""
        return [(p, list(r)) for p, r in self.line_boxes.get((file, line), ())] if file else []

    # -- the PDF

    def _index(self, page):
        if page not in self._indexed:
            words = anchor._words(self.stamp, page)
            ys = sorted(((w[1] + w[3]) / 2, i) for i, w in enumerate(words))
            self._indexed[page] = words, ys, [y for y, _ in ys]
        return self._indexed[page]

    def words(self, page):
        return self._index(page)[0]

    def norms(self, page):
        """([_norm of each of the page's words], {norm: [indices]}), made once a page."""
        if page not in self._norms:
            norms, starts = [_norm(w[4]) for w in self.words(page)], {}
            for i, n in enumerate(norms):
                starts.setdefault(n, []).append(i)
            self._norms[page] = norms, starts
        return self._norms[page]

    def words_in(self, page, rects, pad=1.0):
        """[(index, word)] of the page's words whose centre lies in one of the rects, in reading order."""
        words, ys, keys = self._index(page)
        found = set()
        for r in rects:
            for _, i in ys[bisect.bisect_left(keys, r[1] - pad):bisect.bisect_right(keys, r[3] + pad)]:
                if r[0] - pad <= (words[i][0] + words[i][2]) / 2 <= r[2] + pad:
                    found.add(i)
        return [(i, words[i]) for i in sorted(found)]

    def spans(self, page):
        """The page's text spans (PyMuPDF's dict), in reading order: [(bbox, text, font, colour, text block)]."""
        if page not in self._dicts:
            out = []
            for k, b in enumerate(self.doc[page].get_text("dict", flags=pymupdf.TEXTFLAGS_TEXT)["blocks"]):
                for line in b.get("lines", ()):
                    for s in line["spans"]:
                        if s["text"].strip():
                            out.append((list(s["bbox"]), s["text"], s["font"], s["color"], k))
            self._dicts[page] = out
        return self._dicts[page]

    @functools.cached_property
    def text_area(self):
        """(left, right) of the text on most pages (the median of build.text_x: a margin note widens a page's), or
        None."""
        xs = [x for x in self.text_x if x]
        if not xs:
            return None
        return sorted(x[0] for x in xs)[len(xs) // 2], sorted(x[1] for x in xs)[len(xs) // 2]

    @functools.cached_property
    def text_columns(self):
        """[(left, right)] of the text's columns: the edges most paragraph parts share (one or two columns; a part
        widened by a margin note beside it is outvoted), else text_area's."""
        counts = collections.Counter((round(r[0]), round(r[2])) for b in self.blocks if b["kind"] == "paragraph"
                                     for _, r in self.parts(b) if r)
        if not counts:
            return [self.text_area] if self.text_area else []
        top = counts.most_common(1)[0][1]
        cols = [c for c, n in counts.items() if n >= max(2, top / 4)] or [counts.most_common(1)[0][0]]
        # a part a margin note widened keeps its column's one edge: a pair holding another is no column
        return [c for c in cols if not any(d != c and c[0] - 2 <= d[0] and d[1] <= c[1] + 2 for d in cols)]

    def in_margin(self, w):
        """Whether a word's centre lies outside every column (a margin note's)."""
        cx = (w[0] + w[2]) / 2
        return bool(self.text_columns) and not any(a - 2 <= cx <= b + 2 for a, b in self.text_columns)

    @staticmethod
    def parts(b):
        return [p for p in ([b["box"]] if b.get("box") else b.get("parts") or ()) if p]

    @functools.cached_property
    def refs_start(self):
        """The index of the first block of the references (a bibitem, or the heading above them), else len(blocks)."""
        k = next((k for k, b in enumerate(self.blocks) if b["kind"] == "bibitem"), len(self.blocks))
        if k > 0 and self.blocks[k - 1]["kind"] == "heading" and \
                re.fullmatch(r"\s*(References|Bibliography)\s*", self.blocks[k - 1].get("text") or "", re.I):
            k -= 1
        return k

    @functools.cached_property
    def appendix_start(self):
        """The index of the first block after \\appendix (in its file's reading order), else len(blocks)."""
        for f, t, lo in self.sources:
            m = re.search(r"\\appendix(?![A-Za-z@])", t[lo:])
            if not m:
                continue
            pos = lo + m.start()
            before = [k for k, b in enumerate(self.blocks) if b.get("file") == f and b.get("start") is not None
                      and b["start"] < pos]
            after = [k for k, b in enumerate(self.blocks) if b.get("file") == f and b.get("start") is not None
                     and b["start"] >= pos]
            return before[-1] + 1 if before else after[0] if after else len(self.blocks)
        return len(self.blocks)

    @functools.cached_property
    def reference_rects(self):
        """{page: [rect]} of the references' entries: bibitem blocks, and the table's entries (biblatex's)."""
        out = {}
        for b in self.blocks:
            if b["kind"] == "bibitem":
                for page, r in self.parts(b):
                    out.setdefault(page, []).append(r)
        for t in self.targets:
            if t["kind"] == "cite":
                for page, r in t["parts"]:
                    out.setdefault(page, []).append(r)
        return out

    def in_references(self, page, r):
        cx, cy = (r[0] + r[2]) / 2, (r[1] + r[3]) / 2
        return any(a[0] - 1 <= cx <= a[2] + 1 and a[1] - 1 <= cy <= a[3] + 1
                   for a in self.reference_rects.get(page, ()))

    def block_words(self, kinds, upto=None):
        """[(block index, [(page, index, word)])] of the PDF words in the parts of the blocks of these kinds (before
        block `upto`), each word in one block only."""
        taken, out = set(), []
        for k, b in enumerate(self.blocks[:upto]):
            if b["kind"] not in kinds:
                continue
            seq = []
            for page, r in self.parts(b):
                for i, w in self.words_in(page, [r]):
                    if (page, i) not in taken:
                        taken.add((page, i))
                        seq.append((page, i, w))
            if seq:
                out.append((k, seq))
        return out

    def geometry(self, page, r):
        """A rect's place on its page in reading order: (page, column, top, left); the column is the right one of a
        two-column page (build.columns) when the rect starts right of the gap."""
        gap = (self.columns[page] or [None])[0] if page < len(self.columns) else None
        return page, int(gap is not None and r[0] > gap), r[1], r[0]

    @functools.cached_property
    def _reading(self):
        """({(page, word index): (block, position)} of the words in the blocks' parts (block_words), [(geometry of a
        block's first word, block)] sorted)."""
        at, starts = {}, []
        for k, seq in self.block_words({b["kind"] for b in self.blocks}):
            for j, (page, i, _) in enumerate(seq):
                at[(page, i)] = k, j
            starts.append((self.geometry(seq[0][0], seq[0][2]), k))
        return at, sorted(starts)

    def reading_key(self, place):
        """A place's key in reading order: its first word's block in prose.json's order, then the word's position in
        it; a place in no block (a page only, a margin note, a source line's box) comes after the last block that
        starts before it (page, column, top, left)."""
        at, starts = self._reading
        rects = place["rects"]
        for i, _ in (self.words_in(place["page"], rects[:1]) if rects else ()):
            if (place["page"], i) in at:
                return at[(place["page"], i)]
        g = self.geometry(place["page"], rects[0] if rects else (0.0, 0.0, 0.0, 0.0))
        before = [k for start, k in starts[:bisect.bisect_right(starts, (g, len(self.blocks)))]]
        return max(before, default=-1), float("inf"), g

    @functools.cached_property
    def body_words(self):
        """block_words of the text before the references (paragraphs, items, headings)."""
        return self.block_words(("paragraph", "item", "heading"), self.refs_start)

    @functools.cached_property
    def label_sites(self):
        """{label: [(file, offset)]} of the \\label commands in the paper's source."""
        out = {}
        for f, t, lo in self.sources:
            for m in links.LABEL.finditer(t):
                out.setdefault(m.group(1).strip(), []).append((f, m.start()))
        return out

    @functools.cached_property
    def referenced_labels(self):
        """The labels the source references (\\ref, \\cref, \\autoref…, \\hyperref[…])."""
        out = set()
        for f, t, lo in self.sources:
            for m in REF_CMD.finditer(t, lo):
                for g in m.groups():
                    if g:
                        out.update(k.strip() for k in g.split(",") if k.strip())
        return out

    def source_block(self, file, pos):
        """The block whose source range holds offset pos of file, else the nearest one before it in the file, else
        the next one."""
        best, nxt = None, None
        for k, b in enumerate(self.blocks):
            if b.get("file") != file or b.get("start") is None or b["kind"] in ("deleted", "missing"):
                continue
            if b["start"] <= pos < b["end"]:
                return k
            if b["end"] <= pos and (best is None or b["end"] > self.blocks[best]["end"]):
                best = k
            if b["start"] > pos and (nxt is None or b["start"] < self.blocks[nxt]["start"]):
                nxt = k
        return best if best is not None else nxt

    def source_place(self, file, pos, text=None):
        """The place of a source offset: the PDF lines its line typesets (synctex), else its block's first part."""
        boxes = self.boxes(file, self.line_of(file, pos))
        if boxes:
            page = boxes[0][0]
            return _place(page, anchor._union_boxes([tuple(r) for p, r in boxes if p == page]), text)
        k = self.source_block(file, pos)
        parts = self.parts(self.blocks[k]) if k is not None else []
        return _place(parts[0][0], [parts[0][1]], text) if parts else None

    # -- the bibliography

    @functools.cached_property
    def biblatex(self):
        """Whether the build used biblatex (its \\abx@aux@ lines in the .aux)."""
        return any("\\abx@aux@" in t for t in self.aux_texts)

    @functools.cached_property
    def cited(self):
        """The citation keys the .aux records (\\citation, biblatex's \\abx@aux@cite), in order, without \\nocite{*}'s
        *."""
        out = []
        for t in self.aux_texts:
            for m in CITATION.finditer(t):
                out += [k.strip() for k in (m.group(1) or m.group(2) or "").split(",") if k.strip() and k.strip() != "*"]
        return list(dict.fromkeys(out))

    @functools.cached_property
    def bib(self):
        """{key: (type, {field: value})} of the .bib files the .aux names (\\bibdata) or, for biblatex, the main file's
        preamble (\\addbibresource, \\bibliography), from src; {} without them."""
        names = [m.group(1) for t in self.aux_texts for m in BIBDATA.finditer(t)]
        if self.biblatex:
            names += [m.group(1) for m in RESOURCE.finditer(self.preamble)]
        out = {}
        for name in (n.strip() for group in names for n in group.split(",")):
            if not name:
                continue
            p = self.src / (name if name.endswith(".bib") else name + ".bib")
            try:
                inside = p.resolve().relative_to(self.src.resolve())
            except (OSError, ValueError):
                continue  # a .bib outside the round's source is not read
            if inside and p.is_file():
                for key, entry in _bib_entries(p.read_text(encoding="utf-8", errors="replace")).items():
                    out.setdefault(key, entry)
        for key, (typ, fields) in out.items():  # a crossref's fields fill in the entry's missing ones
            parent = out.get(fields.get("crossref", "").strip())
            if parent:
                for f, v in parent[1].items():
                    fields.setdefault(f, v)
                if "booktitle" not in fields and parent[1].get("title"):
                    fields["booktitle"] = parent[1]["title"]
        return out

    @functools.cached_property
    def bibitems(self):
        """{key: (block index, the entry's TeX)} of the bibitem blocks (a .bbl's or a thebibliography's)."""
        out = {}
        for k, b in enumerate(self.blocks):
            if b["kind"] != "bibitem" or b.get("start") is None:
                continue
            t = self.text(b["file"])
            if t is None or not t.startswith("\\bibitem", b["start"]):
                continue
            j, e = b["start"] + len("\\bibitem"), b["end"]
            o = re.match(r"\s*\[", t[j:e])
            if o:
                j = prose._bracket_end(t, j + o.end() - 1, e)
            o = re.match(r"\s*\{([^{}]*)\}", t[j:e])
            if o:
                out.setdefault(o.group(1).strip(), (k, t[j + o.end():e]))
        return out

    def cite_label(self, key):
        """The citation as printed: natbib's "Chen et al., 2021", else "[4]", else the key."""
        t = next((t for t in self.targets if t["kind"] == "cite" and t["key"] == key), None)
        if t:
            return t["label"]
        c = self.aux[0].get(key)
        if c and c[1] is not None and c[2]:
            return "{}, {}".format(self.ctx.plain(c[2]), self.ctx.plain(c[1]))
        return "[{}]".format(self.ctx.plain(c[0])) if c else key

    def entry_place(self, key):
        """(page, rect) of an entry in the references list: its link target's box, else its bibitem block's part."""
        t = next((t for t in self.targets if t["kind"] == "cite" and t["key"] == key and t["box"]), None)
        if t:
            return t["page"], t["box"]
        k = self.bibitems.get(key, (None,))[0]
        parts = self.parts(self.blocks[k]) if k is not None else []
        return tuple(parts[0]) if parts else None

    def entry_parts(self, key):
        """[(page, rect)] of an entry in the references list: its link target's parts, else its bibitem block's."""
        t = next((t for t in self.targets if t["kind"] == "cite" and t["key"] == key and t.get("parts")), None)
        if t:
            return [(page, r) for page, r in t["parts"]]
        k = self.bibitems.get(key, (None,))[0]
        return [(page, r) for page, r in self.parts(self.blocks[k])] if k is not None else []

    def entry_words(self, key):
        """[(page, word)] of an entry's PDF words (entry_parts), in reading order."""
        if key not in self._entry_words:
            self._entry_words[key] = [(page, w) for page, r in self.entry_parts(key)
                                      for _, w in self.words_in(page, [r])]
        return self._entry_words[key]

    @functools.cached_property
    def entries(self):
        """The cited entries (refs.entries), as refs.json keeps them."""
        return refs.entries(self)

    @functools.cached_property
    def results(self):
        """The online look-ups' results stored for the round: {source: {key: Result}} (refs.json's)."""
        return refs.results(self.paper, self.n)

    def result(self, source, key):
        """A source's result for an entry, or None."""
        r = (self.results.get(source) or {}).get(key)
        return r if isinstance(r, dict) else None

    def detached(self, page, rect):
        """The spacing accents (ACCENTS) the PDF prints in a rect alone: over or under no letter beside it (TeX's
        \\accent sets one over its letter, so OT1's ö reads as "¨o" with the two glyphs in one place)."""
        if page not in self._chars:
            self._chars[page] = [[(c["c"], c["bbox"]) for s in line["spans"] for c in s["chars"]]
                                 for b in self.doc[page].get_text("rawdict", flags=pymupdf.TEXTFLAGS_TEXT)["blocks"]
                                 for line in b.get("lines", ())]
        out = []
        for line in self._chars[page]:
            for k, (c, b) in enumerate(line):
                if c not in ACCENTS or not (rect[0] - 1 <= (b[0] + b[2]) / 2 <= rect[2] + 1 and
                                            rect[1] - 1 <= (b[1] + b[3]) / 2 <= rect[3] + 1):
                    continue
                half = max(b[2] - b[0], 0.2) / 2
                if not any(line[j][0].isalpha() and min(b[2], line[j][1][2]) - max(b[0], line[j][1][0]) >= half
                           for j in (k - 1, k + 1) if 0 <= j < len(line)):
                    out.append(c)
        return out

    def title(self, key):
        """An entry's title: its .bib title, else the first \\newblock of its bibitem (TeX)."""
        if key in self.bib:
            return self.bib[key][1].get("title")
        tex = self.bibitems.get(key, (None, ""))[1]
        m = re.search(r"\\newblock\s*(.*?)(?=\\newblock|$)", tex, re.S)
        return m.group(1) if m else None

    # -- anonymity

    @functools.cached_property
    def anonymous(self):
        """Whether the paper is meant to be anonymous: page 1 prints "Anonymous author(s)", or the class or a
        package takes an option anonymous, submission, blind or doubleblind (acmart only anonymous; elsarticle, llncs
        and IEEEtran none), or review for the classes and packages of REVIEW_ANONYMOUS."""
        words = self.words(0) if self.pages else []
        for a, b in zip(words, words[1:] + [None]):
            if re.fullmatch(r"\W*anonymous\W*", a[4], re.I) and \
                    (b is None or re.fullmatch(r"authors?(?:\(s\))?\W*|author\(s\)\W*", b[4], re.I)):
                return True
        for m in re.finditer(r"\\(?:documentclass|usepackage)\s*\[([^\]]*)\]\s*\{([^{}]*)\}", self.preamble):
            options = {o.split("=")[0].strip().lower() for o in m.group(1).split(",")
                       if o.partition("=")[2].strip().lower() not in ("false", "no", "off")}
            for name in (n.strip().lower() for n in m.group(2).split(",")):
                if options & (OPTIONS_OF.get(name, ANONYMOUS_OPTIONS) |
                              ({"review"} if name in REVIEW_ANONYMOUS else set())):
                    return True
        return False


# --- references ------------------------------------------------------------------------------------------------

def _undefined(p, kind):
    """undefined_ref / undefined_cite: the table's missing targets with each link's place, and the .log's
    warnings with the "??" or "[?]" their source line prints that the table lacks (biblatex prints the key, in bold);
    a warning whose line already holds a place of its key from the table takes none."""
    title = "Undefined reference" if kind == "ref" else "Undefined citation"
    bold = kind == "cite" and p.biblatex
    found, of = {}, {}
    for t, target in enumerate(p.targets):
        if target["kind"] == "missing" and target["label"] == title:
            of[t] = target["key"]
            found.setdefault(target["key"], {"note": target["note"], "places": []})
    for e in p.links:
        for t in e["targets"]:
            if t not in of:
                continue
            if t == e["targets"][0] and len(e["targets"]) == 1:
                found[of[t]]["places"].append(_place(e["page"], e["rects"], _printed(e["text"])))
                continue
            # one key of several (\cite{a,b,c}): the question marks its link prints, not its neighbours' entries
            for _, w in p.words_in(e["page"], e["rects"]):
                if QUESTION[kind].fullmatch(w[4]) and not _covered(found[of[t]]["places"], e["page"], w):
                    found[of[t]]["places"].append(_place(e["page"], [w[:4]], _printed(w[4])))
    claimed, natbib = set(), False  # the places a warning has; whether natbib warned
    for event, m, file, _, _ in p.log:
        if event != kind:
            continue
        name = m.group("rname" if kind == "ref" else "cname")
        natbib = natbib or m.group().startswith("Package natbib")
        entry = found.setdefault(name, {"note": None, "places": []})
        boxes = p.boxes(file, int(m.group("rline" if kind == "ref" else "cline")))
        own = next((pl for pl in entry["places"] if id(pl) not in claimed and pl["rects"] and any(
            page == pl["page"] and _covered([_place(page, [r])], page, pl["rects"][0]) for page, r in boxes)), None)
        if own:  # the table placed this one
            claimed.add(id(own))
            continue
        taken = [pl for e in found.values() for pl in e["places"]]  # another reference's "??" on the line too
        hit = next(((page, w) for page, r in boxes for _, w in p.words_in(page, [r], pad=2.0)
                    if (_printed(w[4]) == name if bold else QUESTION[kind].fullmatch(w[4]))
                    and not _covered(taken, page, w)), None)
        if hit:  # one warning, one "??": the first on its line that no place has
            entry["places"].append(_place(hit[0], [hit[1][:4]], _printed(hit[1][4])))
            claimed.add(id(entry["places"][-1]))
    out = []
    for name, entry in found.items():
        places = _sorted(p, entry["places"])
        printed = (places[0]["text"] if places else None) or \
            ("??" if kind == "ref" else name if bold else "?" if natbib else "[?]")
        if kind == "ref":
            why = entry["note"] if entry["note"] and entry["note"].startswith("\\") else \
                "there is no \\label{{{}}} in this round's source.".format(name)
            what, note = "The reference to " + name, "This reference prints {}: {}".format(
                _q(printed), why if why.startswith("\\") else "there is no \\label{{{}}}.".format(name))
        else:
            why = "no entry in this round's references has the key {}.".format(name)
            what, note = "The citation of " + name, "This citation prints {}: no entry in the references has the " \
                                                    "key {}.".format(_q(printed), name)
        where = " on " + _pages(places) if places else ""
        out.append(_check("undefined_" + kind, "{} {}".format(title, name),
                          "{}{} prints {}: {}".format(what, where, _q(printed), why), note, places))
    return out


def _printed(word):
    """A word as a place's text: without trailing punctuation and an unpaired bracket ("?]" of "[1, 2, ?]")."""
    s = word.strip(".,;:")
    for a, b in ("()", "[]"):
        if s.endswith(b) and a not in s:
            s = s[:-1]
        if s.startswith(a) and b not in s:
            s = s[1:]
    return s


def _covered(places, page, w):
    cx, cy = (w[0] + w[2]) / 2, (w[1] + w[3]) / 2
    return any(pl["page"] == page and any(r[0] - 1 <= cx <= r[2] + 1 and r[1] - 1 <= cy <= r[3] + 1
                                          for r in pl["rects"]) for pl in places)


def undefined_ref(p):
    return _undefined(p, "ref")


def undefined_cite(p):
    return _undefined(p, "cite")


def label_twice(p):
    """A \\label defined twice: the .log's "multiply defined" or two \\newlabel of it in the .aux; each \\label of it
    in the source is a place."""
    names = [m.group("multi") for kind, m, _, _, _ in p.log if kind == "multi"]
    for t in p.aux_texts:
        seen = set()
        for m in re.finditer(r"\\newlabel\{([^{}]*)\}", t):
            if m.group(1) in seen:
                names.append(m.group(1))
            seen.add(m.group(1))
    out = []
    for name in dict.fromkeys(n for n in names if not n.endswith("@cref") and not n.startswith("sub@")):
        sites = p.label_sites.get(name, [])
        places = [pl for pl in (p.source_place(f, pos, "{}:{}".format(f, p.line_of(f, pos))) for f, pos in sites)
                  if pl]
        where = " and ".join("{}:{}".format(f, p.line_of(f, pos)) for f, pos in sites)
        out.append(_check("label_twice", "Label {} defined twice".format(name) if len(sites) <= 2 else
                          "Label {} defined {}×".format(name, len(sites)),
                          "\\label{{{}}} is defined more than once{}, so a reference to it may print the wrong "
                          "number.".format(name, " (" + where + ")" if where else ""),
                          "The label {} is defined {}, so references to it may print the wrong number."
                          .format(name, "twice" if len(sites) <= 2 else "{} times".format(len(sites))),
                          _sorted(p, places), ident=name))
    return out


@functools.lru_cache(maxsize=4)
def _float_kind(kind, text):
    if kind in ("figure", "table"):
        return kind.capitalize()
    return "Algorithm" if kind == "code" and (text or "").startswith("Algorithm") else None


def _floats(p):
    """[(block index, noun, number, labels)] of the paper's figures, tables and algorithms with a caption number."""
    out = []
    for k, b in enumerate(p.blocks):
        noun = _float_kind(b["kind"], (b.get("text") or "")[:9])
        if not noun or not p.parts(b):
            continue
        m = links.FLOAT_NUMBER.match(b.get("text") or "")
        if not m:
            continue
        files = [b["file"]] + list(b.get("inputs") or ())
        labels = [name for name, sites in p.label_sites.items() for f, pos in sites
                  if f in files and (f != b["file"] or b["start"] <= pos < b["end"])]
        out.append((k, noun, m.group(1), labels))
    return out


def _numbers(a, b):
    """The numbers of a range from a to b ("2" to "4": "2", "3", "4"; "A1" to "A3"; "3.1" to "3.4"), else []."""
    ma, mb = re.fullmatch(r"(.*?)(\d+)", a), re.fullmatch(r"(.*?)(\d+)", b)
    if not ma or not mb or ma.group(1) != mb.group(1) or not 0 <= int(mb.group(2)) - int(ma.group(2)) <= 100:
        return []
    return ["{}{}".format(ma.group(1), n) for n in range(int(ma.group(2)), int(mb.group(2)) + 1)]


def _by_hand(p):
    """{(noun, number)} that the text names by hand ("Figure 3", "Tables 2 and 3", "fig. 4", "Figures 2–4" and
    "Figures 2 to 4" with 3), outside floats."""
    out = set()
    for b in p.blocks:
        if b["kind"] not in ("paragraph", "item", "heading"):
            continue
        for m in BY_HAND.finditer(b.get("text") or ""):
            noun = BY_HAND_NOUN[m.group(1)[:3].lower()]
            tokens = re.findall(r"[A-Z]?\d+(?:\.\d+)*[a-z]?|–|-|\bto\b", m.group(2))
            for j, tok in enumerate(tokens):
                if tok not in ("–", "-", "to"):
                    out.add((noun, tok))
                elif 0 < j < len(tokens) - 1:
                    out.update((noun, n) for n in _numbers(tokens[j - 1], tokens[j + 1]))
    return out


def _ranges(p, floats):
    """{(noun, number)} of the floats a range of references in the source covers (RANGE: \\crefrange{a}{c},
    \\ref{a}--\\ref{c}), its two ends floats of one noun."""
    number = {label: (noun, n) for _, noun, n, labels in floats for label in labels}
    out = set()
    for f, t, lo in p.sources:
        for m in RANGE.finditer(t, lo):
            a, b = (m.group(1), m.group(2)) if m.group(1) is not None else (m.group(3), m.group(4))
            a, b = number.get(a.strip()), number.get(b.strip())
            if a and b and a[0] == b[0]:
                out.update((a[0], n) for n in _numbers(a[1], b[1]))
    return out


def _cited_pages(p, k):
    """The pages of the table's links to block k (any of a link's targets), sorted, with the first link in reading
    order."""
    found = [e for e in p.links if any(p.targets[t]["block"] == k for t in e["targets"])]
    first = min(found, key=lambda e: p.reading_key(e), default=None)
    return sorted({e["page"] for e in found}), first


def float_unreferenced(p):
    """A figure, table or algorithm (before \\appendix) whose labels the source never references and the table never
    links, and whose number the text never names by hand nor a range of references covers; one per float."""
    floats, out = _floats(p), []
    by_hand = _by_hand(p) | _ranges(p, floats)
    for k, noun, number, labels in floats:
        if k >= p.appendix_start:
            continue
        if set(labels) & p.referenced_labels or _cited_pages(p, k)[0] or (noun, number) in by_hand:
            continue
        page, box = p.parts(p.blocks[k])[0]
        name = "{} {}".format(noun, number)
        detail = "{} has no \\label, and the text never names {}.".format(name, _q(name)) if not labels else \
            "No \\ref, \\cref or \\autoref names \\label{{{}}}, and the text never names {}.".format(
                labels[0], _q(name))
        out.append(_check("float_unreferenced", "{} · not referenced".format(name), detail,
                          "{} is never referenced in the text.".format(name), [_place(page, [box], name)],
                          ident=labels[0] if labels else None, per_round=not labels))  # a number is renumbered
    return out


def _float_pages(p, code):
    out = []
    for k, noun, number, labels in _floats(p):
        pages, first = _cited_pages(p, k)
        if not pages or k >= p.appendix_start:  # an appendix's float is far from the text that cites it by design
            continue
        page, box = p.parts(p.blocks[k])[0]
        name, cited = "{} {}".format(noun, number), pages[0]
        if code == "float_before" and not (page < cited and page > 0):  # a float on p.1 before it is cited: a teaser
            continue
        if code == "float_far" and page < cited + FAR:
            continue
        gap = cited - page if code == "float_before" else page - cited
        detail = "{} is on p.{}, {} {} {} the text first refers to it on p.{}.".format(
            name, page + 1, gap, "page" if gap == 1 else "pages", "before" if code == "float_before" else "after",
            cited + 1)
        note = "{} appears on p.{}, {} its first reference on p.{}; place it {}.".format(
            name, page + 1, "before" if code == "float_before" else "{} pages after".format(gap), cited + 1,
            "after the paragraph that first cites it" if code == "float_before" else "nearer to that paragraph")
        places = [_place(page, [box], name), _place(first["page"], first["rects"], first["text"])]
        text = "{} · before its first citation".format(name) if code == "float_before" else \
            "{} · {} pages after its first citation".format(name, gap)  # the pages are the row's (its places)
        out.append(_check(code, text, detail, note, places, ident=labels[0] if labels else None,
                          per_round=not labels))  # its \label; a number alone is renumbered
    return out


def float_before(p):
    """A float on an earlier page than its first reference (PDF pages of the table's links), not on p.1."""
    return _float_pages(p, "float_before")


def float_far(p):
    """A float FAR (2) or more pages after its first reference."""
    return _float_pages(p, "float_far")


# --- the bibliography --------------------------------------------------------------------------------------------

def _bib_entries(text):
    """{key: (type, {field: value})} of a .bib file's entries (@string, @comment and @preamble left out); a value
    without its outer delimiters, inner braces kept; a macro or a # join kept as written."""
    out, i = {}, 0
    for m in re.finditer(r"@\s*(\w+)\s*([{(])", text):
        if m.start() < i:
            continue
        typ = m.group(1).lower()
        close = "}" if m.group(2) == "{" else ")"
        end = prose._group_end(text, m.end() - 1, len(text)) if close == "}" else text.find(")", m.end()) + 1
        end = len(text) if end <= 0 else end
        i = end
        if typ in ("string", "comment", "preamble"):
            continue
        body = text[m.end():end - 1]
        key, _, rest = body.partition(",")
        fields, j = {}, 0
        while True:
            f = re.compile(r"\s*([A-Za-z][\w:.+-]*)\s*=\s*").match(rest, j)
            if not f:
                break
            j, parts = f.end(), []
            while j < len(rest):
                c = rest[j]
                if c == "{":
                    e = prose._group_end(rest, j, len(rest))
                    parts.append(rest[j + 1:e - 1])
                elif c == '"':
                    e = j + 1
                    depth = 0
                    while e < len(rest) and not (rest[e] == '"' and depth == 0):
                        depth += (rest[e] == "{") - (rest[e] == "}")
                        e += 1
                    parts.append(rest[j + 1:e])
                    e += 1
                else:
                    t = re.compile(r"[^\s,#}]+").match(rest, j)
                    e = t.end() if t else j + 1
                    parts.append(rest[j:e])
                j = e
                s = re.compile(r"\s*#\s*").match(rest, j)
                if not s:
                    break
                j = s.end()
            fields[f.group(1).lower()] = "".join(parts).strip()
            c = re.compile(r"\s*,").match(rest, j)
            if not c:
                break
            j = c.end()
        if key.strip():
            out.setdefault(key.strip(), (typ, fields))
    return out


def _entry(p, code, key, text, detail, note, rects=None, place_text=None, ident=None):
    """A check of one .bib entry, known by its key (its printed label is renumbered)."""
    at = p.entry_place(key)
    places = [_place(at[0], rects or [at[1]], place_text)] if at else []
    return _check(code, text, detail, note, places, ident=ident or key)


def same_work(p):
    """One work under two keys: two cited entries whose titles are the same, letters and digits only, or that one
    source's look-up found as one record (refs.json's results: an arXiv entry and its published one)."""
    groups = {}
    for key in p.cited:
        title = p.title(key)
        n = _norm(_plain_tex(title)) if title else ""
        if len(n) >= 10:
            groups.setdefault(n, []).append(key)
    out, seen = [], []
    for n, keys in groups.items():
        if len(keys) < 2:
            continue
        title = _plain_tex(p.title(keys[0]))
        seen.append(set(keys))
        out.append(_same(p, keys, "The entries {} have the same title, {}: the references list one work {}.".format(
            " and ".join(keys), _q(title), "twice" if len(keys) == 2 else "{} times".format(len(keys))), title))
    for source, name in refs.SOURCES.items():
        records = {}
        for key in p.cited:
            r = p.result(source, key)
            record = r.get("record") if r and r.get("found") is True else None
            if isinstance(record, (str, int)) and str(record):
                records.setdefault(str(record), []).append(key)
        for record, keys in records.items():
            if len(keys) < 2 or any(set(keys) <= s for s in seen):
                continue
            seen.append(set(keys))
            title = _text(p.result(source, keys[0]).get("title")) or _plain_tex(p.title(keys[0]) or keys[0])
            out.append(_same(p, keys, "{} finds the entries {} as one work, {}: the references list it {}.".format(
                name, " and ".join(keys), _q(title), "twice" if len(keys) == 2 else "{} times".format(len(keys))),
                title))
    return out


def _same(p, keys, detail, title):
    """A same_work check of the keys of one work."""
    labels = [p.cite_label(k) for k in keys]
    places = []
    for k in keys:
        at = p.entry_place(k)
        if at:
            places.append(_place(at[0], [at[1]], p.cite_label(k)))
    return _check("same_work", "Same work {} · {}".format(
                      "twice" if len(keys) == 2 else "{}×".format(len(keys)), " · ".join(labels)), detail,
                  "The references list {} more than once ({}); cite one entry.".format(_q(title), " and ".join(labels)),
                  _sorted(p, places), ident=" ".join(sorted(keys)))


def _text(v):
    """A result's text field, stripped, or None (not a string, or empty)."""
    return v.strip() if isinstance(v, str) and v.strip() else None


def _lowered(title):
    """The words of a .bib title outside braces with a capital after their first letter ("BERT", "ImageNet")."""
    flat, depth = [], 0
    for c in re.sub(r"\\[A-Za-z@]+", " ", title):
        depth += (c == "{") - (c == "}")
        flat.append(c if depth == 0 and c not in "{}" else " ")
    return [w for w in WORD.findall("".join(flat)) if any(ch.isupper() for ch in w[1:])]


def lowered_caps(p):
    """A cited .bib entry's title word with an inner capital, unbraced, that its printed entry (the .bbl's TeX, else
    the PDF's words of the entry) has only in other case: the style lowered it ("BERT" printed "Bert")."""
    out = []
    for key in p.cited:
        if key not in p.bib or not p.bib[key][1].get("title"):
            continue
        words = _lowered(p.bib[key][1]["title"])
        if not words:
            continue
        at = p.entry_place(key)
        if key in p.bibitems:
            printed = WORD.findall(re.sub(r"\\[A-Za-z@]+", " ", p.bibitems[key][1]))
        elif at:
            printed = [w for _, x in p.words_in(at[0], [at[1]]) for w in WORD.findall(x[4])]
        else:
            continue
        lowered = []
        for w in words:
            if w in printed:
                continue
            other = next((x for x in printed if x.lower() == w.lower()), None)
            if other:
                lowered.append((w, other))
        if not lowered:
            continue
        label = p.cite_label(key)
        w, shown = lowered[0]
        rects = [x[:4] for _, x in p.words_in(at[0], [at[1]]) if shown in WORD.findall(x[4])][:1] if at else None
        pairs = ", ".join("{} as {}".format(_q(a), _q(b)) for a, b in lowered)
        out.append(_entry(p, "lowered_caps", key, "{} prints as {} · {}".format(_q(w), _q(shown), label),
                          "The .bib title of {} has {} unbraced, and the bibliography style prints {}."
                          .format(key, " and ".join(_q(a) for a, _ in lowered), pairs),
                          "Reference {} prints {} as {}: put braces around it in the .bib title ({{{}}}).".format(
                              label, _q(w), _q(shown), w), rects or None, shown if rects else label,
                          ident="{}|{}".format(key, w)))
    return out


def no_year(p):
    """A cited .bib entry without a year (or a biblatex date)."""
    out = []
    for key in p.cited:
        typ, fields = p.bib.get(key, (None, {}))
        if typ is None or fields.get("year", "").strip() or fields.get("date", "").strip():
            continue
        label = p.cite_label(key)
        out.append(_entry(p, "no_year", key, "No year · {}".format(label),
                          "The .bib entry {} (@{}) has no year.".format(key, typ),
                          "Reference {} has no year.".format(label), place_text=label))
    return out


def no_venue(p):
    """A cited .bib entry without the field that says where it appeared, by its type (VENUES)."""
    out = []
    for key in p.cited:
        typ, fields = p.bib.get(key, (None, {}))
        if typ not in VENUES or any(fields.get(f, "").strip() for f in VENUES[typ]):
            continue
        label = p.cite_label(key)
        wanted = VENUE_NAMES.get(VENUES[typ][0], "a howpublished, url, eprint, note or publisher")
        out.append(_entry(p, "no_venue", key, "No venue · {}".format(label),
                          "The .bib entry {} is an @{} without {}.".format(key, typ, wanted),
                          "Reference {} does not say where it appeared.".format(label), place_text=label))
    return out


# --- the references' format (refs.py's entries: what the PDF prints, so a style that makes a field uniform reports
# nothing) -------------------------------------------------------------------------------------------------------

def _minority(ways):
    """The ways of writing that are a clear minority ({way: [entries]}): every way but the most frequent (the first of
    equals), when the entries compared are FEW or more and those at most MINORITY of them; else None."""
    total = sum(len(es) for es in ways.values())
    if sum(1 for es in ways.values() if es) < 2 or total < FEW:
        return None
    top = max(ways, key=lambda w: len(ways[w]))
    rest = {w: es for w, es in ways.items() if w != top and es}
    return rest if sum(len(es) for es in rest.values()) <= total * MINORITY else None


def _entries(p, code, es, text, detail, note, ident):
    """A check of several entries, each its place in the references list (its printed label the place's text)."""
    places = []
    for e in es:
        at = p.entry_place(e["key"])
        if at:
            places.append(_place(at[0], [at[1]], e["label"]))
    return _check(code, text, detail, note, _sorted(p, places), ident=ident)


def _ways(k):
    return "two ways" if k == 2 else "{} ways".format(k)


def _and(items):
    items = list(items)
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1] if items else ""


def _bib_printed(p):
    """The entries with a .bib entry whose PDF words are found."""
    return [e for e in p.entries if e["key"] in p.bib and e["printed"]]


def _venue(e):
    """An entry's venue when the PDF prints it and it is not a preprint's, else None."""
    v = e["venue"]
    return v if v and not e["preprint"] and _norm(v) and _norm(v) in _norm(e["printed"]) else None


def _shown_venue(v):
    """A venue as a check names it: without its years."""
    return " ".join(re.sub(r"\b(?:19|20)\d{2}\b|'\d{2}\b", " ", v).split()).strip(" ,;:") or v


def venue_forms(p):
    """One venue written several ways: printed venues whose folded forms differ (case, years, ordinals, "Proceedings
    of", "In" and punctuation aside) but name one venue (refs.VENUES joins short and long names)."""
    venues = {}
    for e in p.entries:
        v = _venue(e)
        folded = refs.fold_venue(v) if v else ""
        if folded:
            venues.setdefault(refs.venue_name(folded), {}).setdefault(folded, []).append(e)
    out = []
    for name, ways in venues.items():
        minority = _minority(ways)
        if not minority:
            continue
        order = sorted(ways, key=lambda w: -len(ways[w]))
        shown = [_q(_shown_venue(ways[w][0]["venue"])) for w in order]
        out.append(_entries(p, "venue_forms", [e for w in order if w in minority for e in ways[w]],
                            "One venue written {} · {}".format(_ways(len(ways)), " · ".join(s[1:-1] for s in shown)),
                            "The references write one venue {}: {}.".format(_ways(len(ways)), _and(
                                "{} ({}×)".format(s, len(ways[w])) for s, w in zip(shown, order))),
                            "The references name one venue {} ({}); write it one way.".format(
                                _ways(len(ways)), _and(shown)), name.lower()))
    return out


def venue_style(p):
    """Venues printed as short names ("ICLR", "NeurIPS 2021") beside venues printed in words."""
    forms = {"short": [], "full": []}
    # conference papers only: short conference names beside journals in full is one usual style (review 2026-11-01)
    for e in p.entries:
        if (e.get("type") or "").lower() not in ("inproceedings", "conference"):
            continue
        v = _venue(e)
        form = refs.venue_form(v) if v else None
        if form:
            forms[form].append(e)
    minority = _minority(forms)
    if not minority:
        return []
    s, f = len(forms["short"]), len(forms["full"])
    return [_entries(p, "venue_style", next(iter(minority.values())), "Venues: {} short, {} in full".format(s, f),
                     "{} entries print their venue's short name ({}) and {} its full name ({}).".format(
                         s, _q(_shown_venue(forms["short"][0]["venue"])), f,
                         _q(_shown_venue(forms["full"][0]["venue"]))),
                     "The references give {} venues as short names and {} in full; write them one way.".format(s, f),
                     "venues")]


def _name_kind(words):
    """"initials" when every first name is initials ("A.", "J.-P."), "full" when every one is a word, else None."""
    if all(re.fullmatch(r"(?:[^\W\d_][.‐-]*)+", w) and not re.search(r"[^\W\d_]{2}", w) for w in words):
        return "initials"
    return "full" if all("." not in w and sum(c.isalpha() for c in w) >= 2 for w in words) else None


def _first_names(p, e):
    """How an entry prints its authors' first names: "full", "initials", or None (mixed, none, or not found)."""
    raw = [w.strip(",;:") for w in e["printed"].split()]
    norms = [_norm(w) for w in raw]
    kinds = set()
    for name in refs.names(p.bib[e["key"]][1].get("author", "")):
        first, last = refs.name_parts(name) if name.lower() != "others" else ("", "")
        words = p.ctx.plain(first).split()
        kind = _name_kind(words) if words else None
        if kind == "full" and not all(_norm(w) in norms for w in words):  # the style may print initials: beside the
            # last name ("J. Smith", "Smith, J.")
            at = [k for k, n in enumerate(norms) if n and n == _norm((p.ctx.plain(last).split() or [""])[-1])]
            kind = "initials" if any(k and raw[k - 1] == words[-1][0] + "." or k + 1 < len(raw) and
                                     raw[k + 1] == words[0][0] + "." for k in at) else None
        if words and kind is None:
            return None
        kinds |= {kind} if kind else set()
    return kinds.pop() if len(kinds) == 1 else None


def author_names(p):
    """Entries printing their authors' first names in full beside entries printing initials."""
    forms = {"full": [], "initials": []}
    for e in _bib_printed(p):
        form = _first_names(p, e)
        if form:
            forms[form].append(e)
    minority = _minority(forms)
    if not minority:
        return []
    f, i = len(forms["full"]), len(forms["initials"])
    return [_entries(p, "author_names", next(iter(minority.values())),
                     "Authors: {} entries with full first names, {} with initials".format(f, i),
                     "{} entries print their authors' first names in full and {} as initials.".format(f, i),
                     "The references give first names in full in {} entries and as initials in {}; write them one "
                     "way.".format(f, i), "first names")]


def author_case(p):
    """An author's name printed all in lower case ("kaiming he"); one per entry."""
    out = []
    for e in _bib_printed(p):
        words = p.entry_words(e["key"])
        printed = [re.sub(r"^\W+|\W+$", "", w[4]) for _, w in words]
        for name in refs.names(p.bib[e["key"]][1].get("author", "")):
            plain = " ".join(p.ctx.plain(name).split())
            parts = re.findall(r"[^\W\d_]+", plain)
            last = re.findall(r"[^\W\d_]+", p.ctx.plain(refs.name_parts(name)[1]))
            if not parts or not last or not all(w.islower() for w in parts) or all(w in PARTICLES for w in parts) \
                    or last[-1] not in printed:  # the last name printed so: no style changes a name's case
                continue
            k = printed.index(last[-1])
            rects = [w[:4] for j, (page, w) in enumerate(words) if page == words[k][0] and
                     abs(j - k) < len(parts) and printed[j] in parts]
            out.append(_entry(p, "author_case", e["key"],
                              "Author name in lower case · {} · {}".format(plain, e["label"]),
                              "The .bib entry {} writes the author {} in lower case, and the references print it so."
                              .format(e["key"], _q(plain)),
                              "Reference {} prints the author {} in lower case.".format(e["label"], _q(plain)),
                              rects, plain))
            break
    return out


def _title_words(title, printed):
    """[(title word, printed word)] of a title found in an entry's printed words (case aside; a word a line's end
    breaks is joined again), or None."""
    want, have = TOKEN.findall(title or ""), TOKEN.findall(printed)
    keys, norms = [_norm(w) for w in want], [_norm(w) for w in have]
    for i in range(len(have)) if want else ():
        j, out = i, []
        for w, k in zip(want, keys):
            if j < len(have) and norms[j] == k:
                out.append((w, have[j]))
                j += 1
            elif j + 1 < len(have) and norms[j] + norms[j + 1] == k:
                out.append((w, have[j]))
                j += 2
            else:
                break
        if len(out) == len(want):
            return out
    return None


def _title_style(p, e):
    """How an entry prints its title: "title" (most words of four letters or more begin with a capital), "sentence"
    (none after the first does but names the .bib protects), else None; the first word, a subtitle's, and a word with a
    capital inside (an acronym) do not count, and two must."""
    tex = p.bib[e["key"]][1].get("title")
    found = _title_words(e["title"], e["printed"]) if tex else None
    if not found:
        return None
    flat, depth = [], 0
    for c in tex:
        depth += (c == "{") - (c == "}")
        flat.append(c if depth > 0 and c not in "{}" else " ")
    protected = {_norm(w) for w in TOKEN.findall(_plain_tex("".join(flat)))}
    starts = {k for k, m in enumerate(TOKEN.finditer(e["title"])) if k == 0 or
              re.search(r"[:?!.]\s*$", e["title"][:m.start()])}
    words = [(w, shown) for k, (w, shown) in enumerate(found) if k not in starts and
             sum(c.isalpha() for c in w) >= 4 and not any(c.isupper() for c in w[1:])]
    if len(words) < 2:
        return None
    caps = [w for w, shown in words if shown[:1].isupper()]
    if 2 * len(caps) > len(words):
        return "title"
    return "sentence" if all(_norm(w) in protected for w in caps) else None


def title_case(p):
    """Titles printed in title case beside titles printed in sentence case (the PDF's words of the .bib titles)."""
    forms = {"title": [], "sentence": []}
    for e in _bib_printed(p):
        form = _title_style(p, e)
        if form:
            forms[form].append(e)
    minority = _minority(forms)
    if not minority:
        return []
    t, s = len(forms["title"]), len(forms["sentence"])
    return [_entries(p, "title_case", next(iter(minority.values())),
                     "Titles: {} in title case, {} in sentence case".format(t, s),
                     "{} entries print their titles in title case and {} in sentence case.".format(t, s),
                     "The references give {} titles in title case and {} in sentence case; write them one way."
                     .format(t, s), "titles")]


def etal_by_hand(p):
    """A .bib author list cut to "and others" while every other entry of more than three authors prints them all."""
    cut, full = [], []
    for e in _bib_printed(p):
        written = refs.names(p.bib[e["key"]][1].get("author", ""))
        if written and written[-1].lower() == "others":
            cut.append(e)
        elif len(written) > 3:
            full.append((e, written))
    if not cut or not full or not all(_norm(p.ctx.plain(refs.name_parts(n)[1])) in _norm(e["printed"])
                                      for e, written in full for n in written):
        return []
    return [_entry(p, "etal_by_hand", e["key"], "Author list cut to “et al.” · {}".format(e["label"]),
                   "The .bib entry {} ends its authors with “and others”, while every other entry of more than three "
                   "authors prints them all.".format(e["key"]),
                   "Reference {} cuts its authors to “et al.”; list them all, as the other references do.".format(
                       e["label"]), place_text=e["label"]) for e in cut]


def leftovers(p):
    """TeX the PDF prints in an entry: a "{", "}" or "\\", "..", ", ,", "()" or a spacing accent alone (a URL's words
    aside); one per entry and leftover, each word holding it a place."""
    out = []
    for e in p.entries:
        found = {}
        words = [(page, w) for page, w in p.entry_words(e["key"]) if not re.search(r"https?:|www\.|/", w[4])]
        text, starts = "", []
        for page, w in words:
            starts.append(len(text))
            text += w[4] + " "
        for m in LEFTOVER.finditer(text):
            at = [k for k, s in enumerate(starts) if s < m.end() and m.start() < s + len(words[k][1][4])]
            found.setdefault(LEFTOVER_SHOWN[m.group()[0]], []).extend(words[k] for k in at)
        for page, w in words:
            if any(c in ACCENTS for c in w[4]):
                for c in p.detached(page, w[:4]):
                    found.setdefault(c, []).append((page, w))
        for shown, at in found.items():
            places = [_place(page, [w[:4]], w[4]) for page, w in dict.fromkeys((page, w) for page, w in at)]
            out.append(_check("leftovers", "Stray {} · {}".format(_q(shown), e["label"]),
                              "The printed entry of {} holds {} ({}), a leftover of its .bib entry.".format(
                                  e["key"], _q(shown), _pages(places)),
                              "Reference {} prints a stray {}; fix its .bib entry.".format(e["label"], _q(shown)),
                              places, ident="{}|{}".format(e["key"], shown)))
    return out


def _prints(p, e, field):
    """Whether an entry's PDF words hold a .bib field's value: its words, or (8 letters and digits or more) its
    letters and digits run together (a URL or DOI broken across lines)."""
    raw = p.bib[e["key"]][1].get(field, "").strip()
    value = raw if field in ("url", "doi") else p.ctx.plain(raw)
    words = [_norm(w) for w in re.findall(r"[^\W_]+", value)]
    if not raw or not any(words):
        return False
    printed = {_norm(w) for w in re.findall(r"[^\W_]+", e["printed"])}
    return all(w in printed for w in words if w) or len(_norm(value)) >= 8 and _norm(value) in _norm(e["printed"])


def field_mix(p):
    """A field most conference papers (or journal articles) print and a few lack, or the reverse: DOI, pages, URL,
    publisher, and an article's volume and number (TYPE_FIELDS; preprints aside)."""
    out = []
    for typ, noun in TYPE_NOUNS.items():
        es = [e for e in _bib_printed(p) if FIELD_TYPES.get(e["type"]) == typ and not e["preprint"]]
        for field in TYPE_FIELDS[typ]:
            name = FIELDS[field]
            ways = {"has": [], "lacks": []}
            for e in es:
                ways["has" if _prints(p, e, field) else "lacks"].append(e)
            minority = _minority(ways)
            if not minority:
                continue
            has, lacks, shown = len(ways["has"]), len(ways["lacks"]), name[0].upper() + name[1:]
            if "has" in minority:
                text = "{} on {} of {} {}".format(shown, has, len(es), noun)
                detail = "{} of {} {} print their {}; the other {} do not.".format(has, len(es), noun, name, lacks)
            else:
                text = "{} missing on {} of {} {}".format(shown, lacks, len(es), noun)
                detail = "{} of {} {} print no {}; the other {} do.".format(lacks, len(es), noun, name, has)
            out.append(_entries(p, "field_mix", next(iter(minority.values())), text, detail,
                                "Give all the {} their {}, or none.".format(noun, name), "{}|{}".format(typ, field)))
    return out


def page_dash(p):
    """Page ranges printed with a dash beside ranges printed with a hyphen (the entry's pages found in its words)."""
    ways = {"dash": [], "hyphen": []}
    for e in p.entries:
        numbers = re.findall(r"\d+", e["pages"] or "")
        m = re.search(r"(?<!\d){}\s*([-‐–])\s*{}(?!\d)".format(numbers[0], numbers[-1]), e["printed"]) \
            if len(numbers) >= 2 else None
        if m:
            ways["dash" if m.group(1) == "–" else "hyphen"].append(e)
    minority = _minority(ways)
    if not minority:
        return []
    d, h = len(ways["dash"]), len(ways["hyphen"])
    return [_entries(p, "page_dash", next(iter(minority.values())),
                     "Page ranges: {} with a dash, {} with a hyphen".format(d, h),
                     "{} entries print their page range with a dash (–) and {} with a hyphen (-).".format(d, h),
                     "The references print {} page ranges with a dash and {} with a hyphen; write them one way (“--” "
                     "in the .bib gives the dash).".format(d, h), "pages")]


def _arxiv_form(e):
    """How an entry prints its arXiv id: "CoRR" ("CoRR, abs/…"), "arXiv" ("arXiv:…"), "url" (arxiv.org/… only), or
    None."""
    t = e["printed"]
    if re.search(r"\bCoRR\b", t) and "abs/" in t:
        return "CoRR"
    if re.search(r"arXiv:\s*\S", t, re.I):
        return "arXiv"
    return "url" if re.search(r"arxiv\.org/", t, re.I) else None


def arxiv_forms(p):
    """arXiv ids printed in two ways or more: arXiv:2010.11929, CoRR abs/2010.11929, an arxiv.org URL alone."""
    ways = {}
    for e in p.entries:
        form = _arxiv_form(e) if e["arxiv"] else None
        if form:
            ways.setdefault(form, []).append(e)
    minority = _minority(ways)
    if not minority:
        return []
    order = sorted(ways, key=lambda w: -len(ways[w]))
    shown = [ARXIV_FORMS[w].format(ways[w][0]["arxiv"]) for w in order]
    return [_entries(p, "arxiv_forms", [e for w in order if w in minority for e in ways[w]],
                     "arXiv written {} · {}".format(_ways(len(ways)), " · ".join(shown)),
                     "The references print arXiv ids {}: {}.".format(_ways(len(ways)), _and(
                         "{} ({}×)".format(_q(s), len(ways[w])) for s, w in zip(shown, order))),
                     "The references give arXiv ids {} ({}); write them one way.".format(
                         _ways(len(ways)), _and(_q(s) for s in shown)), "arxiv")]


# --- the references' look-ups (refs.json's results, stored by the app; the engine fetches nothing) ---------------

def _year(v):
    m = re.search(r"\b(\d{4})\b", str(v)) if isinstance(v, (str, int)) else None
    return int(m.group(1)) if m else None


def _last_name(name):
    """The last word of a name's last name ("Dosovitskiy, Alexey", "Laurens van der Maaten"), letters only."""
    last = refs.name_parts(name)[1].split() if isinstance(name, str) and name.strip() else []
    return _norm(last[-1]) if last else ""


def published_preprint(p):
    """A preprint entry (refs.PREPRINT) whose Semantic Scholar record was published at a venue."""
    out = []
    for e in p.entries:
        r = p.result("semantic_scholar", e["key"])
        venue = _text(r.get("published")) if r and r.get("found") is True else None
        if not e["preprint"] or not venue:
            continue
        if refs.fold_venue(venue) and refs.fold_venue(venue) in refs.fold_venue(e["printed"] or ""):
            continue  # the entry prints that venue already
        what = "{} preprint".format(refs.server(e)) if refs.server(e) else "preprint"
        out.append(_entry(p, "published_preprint", e["key"], "{} {} · published at {}".format(e["label"], what, venue),
                          "Semantic Scholar's record of {} was published at {}; the entry cites the {}.".format(
                              _q(e["title"] or e["key"]), venue, what),
                          "Cite the published version ({}).".format(venue), place_text=e["label"]))
    return out


def no_record(p):
    """An entry that every source looked up for it found nothing for, Semantic Scholar at least; the closest match in
    the detail."""
    out = []
    for e in p.entries:
        found = {s: p.result(s, e["key"]) for s in refs.SOURCES}
        found = {s: r for s, r in found.items() if r}
        if "semantic_scholar" not in found or any(r.get("found") is not False for r in found.values()):
            continue
        if (e.get("type") or "").lower() in ("misc", "online", "software", "dataset", "electronic", "www") and e["url"]:
            continue  # a web page, a repository or a dataset: no paper to find
        closest = next((r["closest"] for r in found.values() if isinstance(r.get("closest"), dict)), None)
        detail = "{} {} no record of {}.".format(_and(refs.SOURCES[s] for s in found), "finds" if len(found) == 1
                                                 else "find", _q(e["title"] or e["key"]))
        if closest:
            authors = closest.get("authors") if isinstance(closest.get("authors"), list) else []
            shown = [str(v) for v in (_text(closest.get("title")), closest.get("year"),
                                      authors[0] if authors else None) if isinstance(v, (str, int)) and str(v)]
            detail += " Closest: {}.".format(" · ".join(shown)) if shown else ""
        out.append(_entry(p, "no_record", e["key"], "{} · no record".format(e["label"]), detail,
                          "Check that this work exists and that its title is right.", place_text=e["label"]))
    return out


def record_differs(p):
    """An entry whose year (by more than one, a preprint's aside), title (case, TeX, accents and punctuation aside) or
    first author's last name differs from its Semantic Scholar record; one check each."""
    out = []
    for e in p.entries:
        r = p.result("semantic_scholar", e["key"])
        if not r or r.get("found") is not True:
            continue
        label, title = e["label"], _q(e["title"] or e["key"])
        year, published = _year(e["year"]), _year(r.get("year"))
        if year and published and not e["preprint"] and abs(year - published) > 1:
            out.append(_entry(p, "record_differs", e["key"],
                              "{} · year {}, published {}".format(label, year, published),
                              "The entry gives {} the year {}; Semantic Scholar's record has {}.".format(
                                  title, year, published),
                              "Reference {} gives the year {}; the work was published in {}.".format(
                                  label, year, published), place_text=label, ident="{}|year".format(e["key"])))
        named = _text(r.get("title"))
        if named and e["title"] and _norm(named.replace("&", "and")) != _norm(e["title"].replace("&", "and")):
            out.append(_entry(p, "record_differs", e["key"], "{} · title differs".format(label),
                              "The entry's title, {}, is not Semantic Scholar's, {}.".format(title, _q(named)),
                              "Check the title of reference {}: the published work has {}.".format(label, _q(named)),
                              place_text=label, ident="{}|title".format(e["key"])))
        authors = r.get("authors") if isinstance(r.get("authors"), list) else []
        first = authors[0] if authors and isinstance(authors[0], str) else None
        if first and e["authors"] and _last_name(first) and _last_name(e["authors"][0]) \
                and _last_name(first) != _last_name(e["authors"][0]):
            out.append(_entry(p, "record_differs", e["key"], "{} · first author differs".format(label),
                              "The entry's first author is {}; Semantic Scholar's record has {}.".format(
                                  _q(e["authors"][0]), _q(first)),
                              "Check the authors of reference {}: the published work's first author is {}.".format(
                                  label, _q(first)), place_text=label, ident="{}|first author".format(e["key"])))
    return out


# --- consistency -----------------------------------------------------------------------------------------------

def _tokens(seq):
    """[(token, raw word, page, word)] of a block's words, without the words a hyphen at a line's end breaks (the
    PDF cannot tell "pre-" "training" from "pretrain-" "ing"), URLs, addresses and abbreviations (/ @ x.y)."""
    out, broken = [], False
    for j, (page, i, w) in enumerate(seq):
        nxt = seq[j + 1] if j + 1 < len(seq) else None
        ends = nxt is None or nxt[0] != page or (nxt[2][5], nxt[2][6]) != (w[5], w[6])
        if broken:
            broken = False
            out.append(None)
            continue
        if w[4].endswith("-") and ends:
            broken = True
            out.append(None)
            continue
        tok = re.sub(r"^[^\w]+|[^\w]+$", "", w[4])
        out.append(None if not tok or SKIP_TOKEN.search(w[4]) else (tok, w[4], page, w))
    return out


def _fold(form):
    """A spelling's family: lower case, -ise as -ize, British as American, a plural's s dropped, without hyphens or
    spaces; and its style (the separator, -ise, British)."""
    low = form.lower()
    sep = "-" if "-" in low else " " if " " in low else ""
    joined = low.replace("-", "").replace(" ", "")
    us = BRITISH.get(joined, joined)
    ize = ISE.sub(r"iz\1", us)
    key = ize[:-1] if ize.endswith("s") and not ize.endswith("ss") and len(ize) > 4 else ize
    return key, (sep, ize != us, us != joined)


def _differ(styles):
    """Whether the styles of one word's spellings differ other than by a hyphen against a space."""
    styles = list(styles)
    for a in styles:
        for b in styles:
            if a[1] != b[1] or a[2] != b[2] or (a[0] != b[0] and "" in (a[0], b[0])):
                return True
    return False


def spelling(p):
    """One word spelt two ways in the text before the references, both forms in the paper: British and American
    (BRITISH), -ise and -ize, hyphenated and joined (parts of 2 and 3 letters at least), two words and joined (both
    of 3 letters at least, no stopword); never a hyphen against a space; a plural's s folded."""
    occurrences = []  # (family, style, form as printed, place)
    blocks = [_tokens(seq) for _, seq in p.body_words]
    joined = set()
    for toks in blocks:
        for t in toks:
            if t and re.fullmatch(r"[A-Za-z]+(?:-[A-Za-z]+)?", t[0]):
                parts = t[0].split("-")
                if len(parts) == 1 or (len(parts[0]) >= 2 and len(parts[1]) >= 3):
                    key, style = _fold(t[0])
                    occurrences.append((key, style, t[0].lower(), _place(t[2], [t[3][:4]], t[3][4])))
                    if len(parts) == 1:
                        joined.add(key)
    for toks in blocks:
        for a, b in zip(toks, toks[1:]):
            if not a or not b or a[1] != a[0] or not b[1].startswith(b[0]) or a[2] != b[2]:
                continue
            if not (re.fullmatch(r"[A-Za-z]{3,}", a[0]) and re.fullmatch(r"[A-Za-z]{3,}", b[0])) or \
                    a[0].lower() in STOPWORDS or b[0].lower() in STOPWORDS:
                continue
            form = "{} {}".format(a[0], b[0])
            key, style = _fold(form)
            if key in joined:
                rects = anchor._line_rects([a[3], b[3]])
                occurrences.append((key, style, form.lower(), _place(a[2], rects, "{} {}".format(a[3][4], b[3][4]))))
    families = {}
    for key, style, form, place in occurrences:
        families.setdefault(key, {}).setdefault(style, []).append((form, place))
    out = []
    for key, styles in families.items():
        if len(styles) < 2 or not _differ(styles):
            continue
        forms = sorted(styles.values(), key=lambda v: (-len(v), p.reading_key(v[0][1])))
        shown = [max(set(f for f, _ in v), key=lambda f: sum(x == f for x, _ in v)) for v in forms]
        text = " · ".join("{} {}×".format(_q(s), len(v)) for s, v in zip(shown, forms))
        places = _sorted(p, [pl for v in forms for _, pl in v])
        out.append(_check("spelling", text, "The text writes {}.".format(
            " and ".join("{} {} {}".format(_q(s), len(v), "time" if len(v) == 1 else "times")
                         for s, v in zip(shown, forms))),
            "Spell {} one way throughout (the paper also writes {}).".format(
                _q(shown[0]), " and ".join(_q(s) for s in shown[1:])), places, ident=key))  # the word, not its counts
    return out


def _sentence_start(prev):
    """Whether a word after `prev` (a PDF word, or None at a block's start) starts a sentence."""
    if prev is None:
        return True
    raw = prev[4].rstrip("”’\")]")
    return raw.endswith((".", "?", "!")) and raw.lower() not in ABBREVIATIONS


def _named_before(seq, j):
    """Whether word j of a block's words ends a list of formula numbers after a name ("Eq." in "Eqs. (2) and (3)",
    "Eqs. (2), (3) and (4)"): back over numbers and "and", "or", "to" to the word before them."""
    for k in range(j - 1, -1, -1):
        w = seq[k][2][4].lower().rstrip(",;:~")
        if REF_NAMES.get(w) == "equation":
            return True
        if not (EQ_NUMBER.fullmatch(seq[k][2][4]) or w in ("and", "or", "to", "&", "-", "–")):
            return False
    return False


def ref_style(p):
    """One kind of reference written two ways in mid-sentence, in the text before the references: "Fig. 3" and
    "Figure 3", a lower-case "figure 3" beside "Figure 3", "Eq. (2)" and a bare "(2)" (only a link to a formula, never
    raw text). A capitalised form starting a sentence (or an item, after its label) is left out (IEEE's "Figure 3"
    there beside "Fig. 3"), so a family written one way throughout, cleveref's "fig." too, is fine."""
    eq_rects = {}
    for e in p.links:
        if e["targets"] and p.targets[e["targets"][0]]["kind"] == "equation":
            eq_rects.setdefault(e["page"], []).extend(e["rects"])
    families = {}  # family: {style: [(printed, place)]}
    for k, seq in p.body_words:
        # an item's first word after its label ("•", "1)", "(a)") starts a sentence too
        lead = int(p.blocks[k]["kind"] == "item" and bool(ITEM_LABEL.fullmatch(seq[0][2][4])))
        for j, (page, i, w) in enumerate(seq):
            prev = seq[j - 1][2] if j > lead else None
            name = w[4].lower().rstrip(",;:")
            nxt = seq[j + 1] if j + 1 < len(seq) else None
            if name in REF_NAMES and nxt and NUMBER.fullmatch(nxt[2][4]) and any(c.isdigit() or c.isupper()
                                                                                 for c in nxt[2][4]):
                if _sentence_start(prev):
                    continue
                singular = w[4].rstrip(",;:")
                singular = SINGULAR.get(singular.lower(), singular.lower())
                style = singular if w[4][0].islower() else singular[:1].upper() + singular[1:]
                printed = "{} {}".format(style, nxt[2][4].rstrip(",;:"))
                rects = anchor._line_rects([w, nxt[2]]) if nxt[0] == page else [w[:4]]
                families.setdefault(REF_NAMES[name], {}).setdefault(style, []).append(
                    (printed, _place(page, rects, "{} {}".format(w[4], nxt[2][4]))))
            elif EQ_NUMBER.fullmatch(w[4]) and page in eq_rects and _covered([_place(page, eq_rects[page])], page, w):
                if _sentence_start(prev) or _named_before(seq, j):
                    continue
                families.setdefault("equation", {}).setdefault("bare", []).append(
                    (w[4].rstrip(",;:.)") + (")" if w[4].rstrip(",;:.)").startswith("(") else ""),
                     _place(page, [w[:4]], w[4])))
    out = []
    for family, styles in families.items():
        if len(styles) < 2:
            continue
        ordered = sorted(styles.values(), key=lambda v: (-len(v), p.reading_key(v[0][1])))
        shown = [v[0][0] for v in ordered]
        places = _sorted(p, [pl for v in ordered for _, pl in v])
        out.append(_check("ref_style", " · ".join(_q(s) for s in shown),
                          "In mid-sentence the text writes {} as {}.".format(
                              FAMILY_NOUNS[family], " and ".join("{} ({}×)".format(_q(s), len(v))
                                                                 for s, v in zip(shown, ordered))),
                          "Refer to {} one way throughout ({} or {}).".format(
                              FAMILY_NOUNS[family], _q(shown[0]), " or ".join(_q(s) for s in shown[1:])), places,
                          ident=family))  # its order follows the counts
    return out


# --- typesetting -----------------------------------------------------------------------------------------------

def _letters(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s) if c.isalnum()).lower()


def _input_line(p, file, child):
    """The line of file whose \\input (or \\include) reads child, the last one, or None."""
    t = p.text(file) or ""
    at = [m.start() for m in texdiff.INCLUDE.finditer(t) if texdiff.include_file(m, [child]) == child]
    return p.line_of(file, at[-1]) if at else None


def overfull(p):
    """An Overfull \\hbox over OVERFULL (1 pt) from the .log: its source lines (the log's file) give the PDF lines
    they typeset, and the box's text (the log's next line) picks the line. A paragraph that began in a file TeX has
    closed since (the last paragraph of an \\input file without a blank line at its end) and ended in the log's file
    has its first line in the one and its last in the other."""
    out, seen = [], set()
    for kind, m, file, box, closed in p.log:
        if kind != "over" or float(m.group("over")) <= OVERFULL:
            continue
        amount = float(m.group("over"))
        l1 = int(m.group("l1"))
        l2 = int(m.group("l2") or l1)
        spans = [(file, l1, l2)]
        at = _input_line(p, file, closed) if closed and file and closed != file else None
        if at is not None and l1 <= at < l2 and PAR_END.search("\n" + "\n".join(
                (p.text(file) or "").split("\n")[l1 - 1:at - 1]) + "\n"):
            # file's lines l1..at hold a paragraph's end, so the paragraph began in closed, at its line l1
            spans = [(closed, l1, (p.text(closed) or "").count("\n") + 1), (file, at, l2)]
        candidates = list(dict.fromkeys((page, tuple(r)) for f, a, b in spans for line in range(a, min(b, a + 200) + 1)
                                        for page, r in p.boxes(f, line)))
        if not candidates:
            continue
        shown = _letters(re.sub(r"\\[A-Za-z0-9]+/[^\s]*\s?|\[\]|\\[A-Za-z@]+|[|$]", " ", box))[:300]
        best = None
        for page, r in candidates:
            words = [w for _, w in p.words_in(page, [[r[0], r[1], r[2] + amount + 20, r[3]]])]
            text = _letters("".join(w[4] for w in words))
            matched = sum(b.size for b in SequenceMatcher(None, shown, text, autojunk=False).get_matching_blocks()) \
                if shown and text else 0
            key = (matched / len(shown) if shown else 0.0, max([w[2] for w in words] + [r[2]]), r[2] - r[0])
            if best is None or key > best[0]:
                best = key, page, r, words
        _, page, r, words = best
        if (page, r) in seen:
            continue
        seen.add((page, r))
        rect = [min([r[0]] + [w[0] for w in words]), min([r[1]] + [w[1] for w in words]),
                max([r[2] + amount] + [w[2] for w in words]), max([r[3]] + [w[3] for w in words])]
        lines = "{}, line {}".format(file, l1) if l1 == l2 else "{}, lines {}–{}".format(file, l1, l2)
        if len(spans) == 2:
            lines = "{} line {} to {} line {}".format(closed, l1, file, l2)
        out.append(_check("overfull", "Overfull line · {} pt too wide".format(_points(amount)),
                          "TeX set this line {} pt wider than the text ({}).".format(_points(amount), lines),
                          "This line runs {} pt into the margin.".format(_points(amount)),
                          [_place(page, [rect], comments.join_words(words) or None)], per_round=True))
    return out


def _points(v):
    return "{:.1f}".format(v).rstrip("0").rstrip(".")


def _quote_free(p):
    """Whether a straight " is meant in this source: csquotes' \\MakeOuterQuote{"} or babel's German shorthands."""
    t = p.preamble
    if re.search(r'\\MakeOuterQuote\s*\{"\}', t):
        return True
    german = r"\b(?:n?german|n?austrian|n?swissgerman)\b"
    babel = re.search(r"\\usepackage\s*(?:\[([^\]]*)\])?\s*\{[^{}]*\bbabel\b[^{}]*\}", t)
    cls = re.search(r"\\documentclass\s*\[([^\]]*)\]", t)
    return bool(babel and (re.search(german, babel.group(1) or "") or (cls and re.search(german, cls.group(1)))))


def _quotes(t, lo):
    """The offsets of the straight " in TeX text t from lo, outside verbatim, math, \\verb, accents (\\"o) and the
    arguments of ARG_COMMANDS."""
    i, n = lo, len(t)
    while True:
        m = SOURCE_TOKEN.search(t, i)
        if not m:
            return
        tok, end = m.group(), m.end()
        if tok == '"':
            yield m.start()
        elif re.fullmatch(r"\\[vV]erb\*?", tok):
            if tok[1] == "V" and end < n and t[end] == "[":  # fancyvrb's \Verb[options]|…|
                end = prose._bracket_end(t, end, n)
            close = t.find(t[end], end + 1) if end < n else -1
            end = close + 1 if close >= 0 else n
        elif m.group(1) is not None:
            if m.group(1).strip() in SKIP_ENVS:
                e = re.compile(r"\\end\s*\{" + re.escape(m.group(1).strip()) + r"\}").search(t, end)
                end = e.end() if e else n
        elif tok in ("$$", "$", "\\(", "\\["):
            close = {"$$": "$$", "$": "$", "\\(": "\\)", "\\[": "\\]"}[tok]
            j = end
            while True:
                j = t.find(close, j)
                if j < 0 or t[j - 1] != "\\":
                    break
                j += 1
            end = j + len(close) if j >= 0 else n
        elif m.group(2) and (m.group(2) in ARG_COMMANDS or m.group(2).startswith(("cite", "Cite"))):
            j = end
            while True:
                s = re.compile(r"\s*").match(t, j).end()
                if s < n and t[s] == "[":
                    j = prose._bracket_end(t, s, n)
                else:
                    j = s
                    break
            if j < n and t[j] == "{":
                end = prose._group_end(t, j, n)
                if m.group(2) in TWO_ARGS:  # and the code after the language
                    j = re.compile(r"\s*").match(t, end).end()
                    if j < n and t[j] == "{":
                        end = prose._group_end(t, j, n)
                    elif j < n:
                        close = t.find(t[j], j + 1)
                        end = close + 1 if close >= 0 else n
            elif m.group(2) == "lstinline" and j < n:
                close = t.find(t[j], j + 1)
                end = close + 1 if close >= 0 else n
        i = max(end, m.start() + 1)


def straight_quotes(p):
    """A straight " in the body's source (QUOTE rules: _quotes), one per source line, placed by synctex; none when
    the paper makes " a quote or a shorthand (_quote_free)."""
    if _quote_free(p):
        return []
    out = []
    for f, t, lo in p.sources:
        lines = []
        for pos in _quotes(t, lo):
            line = p.line_of(f, pos)
            if line not in lines:
                lines.append(line)
                at = "{}:{}".format(f, line)
                place = p.source_place(f, pos, at)
                if place:  # the words a straight " opens (”word in OT1) or holds (T1), when the line shows them
                    shown = [w for r in place["rects"] for _, w in p.words_in(place["page"], [r])
                             if w[4].startswith("”") or '"' in w[4]]
                    if shown:
                        place = _place(place["page"], [w[:4] for w in dict.fromkeys(shown)],
                                       comments.join_words(list(dict.fromkeys(shown))))
                out.append(_check("straight_quotes", "Straight quotes · {}".format(at),
                                  "Line {} of {} types a straight \", which TeX prints as a closing quote (”) "
                                  "at both ends; `` and '' print “ and ”.".format(line, f),
                                  "The quotation marks here are typed as \" in the source, so both print as ”; use "
                                  "`` and '' instead.", [place] if place else [], per_round=True))
    return out


def doubled_word(p):
    """The same word twice in a row in a paragraph or item, case aside: the first alphabetic, of 2 letters at least,
    not "that" or "had" ("had had", "that that" may be meant)."""
    out = []
    for _, seq in p.block_words(("paragraph", "item")):
        for (pa, _, a), (pb, _, b) in zip(seq, seq[1:]):
            if not re.fullmatch(r"[A-Za-z]{2,}", a[4]) or a[4].lower() in DOUBLED_OK:
                continue
            if re.sub(r"[^\w]+$", "", b[4]).lower() != a[4].lower():
                continue
            pair = "{} {}".format(a[4], re.sub(r"[^\w]+$", "", b[4]))
            rects = anchor._line_rects([a, b]) if pa == pb else [a[:4]]
            out.append(_check("doubled_word", _q(pair), "{} on p.{}: the same word twice in a row.".format(
                _q(pair), pa + 1), "{}: a word is doubled here.".format(_q(pair)), [_place(pa, rects, pair)],
                per_round=True))
    return out


# --- submission ------------------------------------------------------------------------------------------------

def _fonts(p):
    """{xref: (type, ext, name without a subset prefix, [pages])} of the PDF's fonts."""
    out = {}
    for page in range(p.pages):
        for xref, ext, typ, base, *_ in p.doc[page].get_fonts(full=True):
            name = re.sub(r"^[A-Z]{6}\+", "", base or "") or "(unnamed)"
            out.setdefault(xref, (typ, ext, name, []))[3].append(page)
    return out


def _font_check(p, code):
    """type3_font / unembedded_font: a font (by xref; fonts of one name joined) and the spans set in it, page by
    page."""
    by_name = {}
    for xref, (typ, ext, name, pages) in _fonts(p).items():
        if (typ == "Type3") if code == "type3_font" else (ext == "n/a" and typ != "Type3"):
            by_name.setdefault(name, set()).update(pages)
    out = []
    for name, pages in by_name.items():
        places = []
        for page in sorted(pages):
            spans = [(r, t) for r, t, font, _, _ in p.spans(page) if re.sub(r"^[A-Z]{6}\+", "", font) == name or
                     code == "type3_font" and font.startswith("Unnamed-T3")]  # PyMuPDF's name for one it cannot name
            lines = anchor._line_rects([r for r, _ in spans])  # one rect a line of spans
            rects = anchor._union_boxes([tuple(round(v, 2) for v in r) for r in lines])
            places.append(_place(page, rects, _excerpt(" ".join(t for _, t in spans)) if spans else None))
        where = _pages(places)
        if code == "type3_font":
            out.append(_check(code, "Type 3 font · {}".format(name),
                              "{} on {} is a Type 3 font, which many venues do not accept; it usually comes from a "
                              "figure's PDF.".format(name, where),
                              "The font {} here is a Type 3 font; make the figure again with Type 1 or TrueType fonts "
                              "(matplotlib: pdf.fonttype 42).".format(name), places))
        else:
            out.append(_check(code, "Font not embedded · {}".format(name),
                              "{} on {} is not embedded in the PDF; many venues require every font embedded."
                              .format(name, where),
                              "The font {} here is not embedded; make the PDF (or the figure) again with its fonts "
                              "embedded.".format(name), places))
    return out


def type3_font(p):
    return _font_check(p, "type3_font")


def unembedded_font(p):
    return _font_check(p, "unembedded_font")


def draft_marker(p):
    """A PDF word TODO, FIXME, XXX, TBD or TBA (case as written) in a block of the body (not the references)."""
    out = []
    for _, seq in p.block_words(("title", "heading", "paragraph", "item", "figure", "table", "code", "picture",
                                 "math")):
        for page, _, w in seq:
            m = MARKER.fullmatch(w[4])
            if m:
                out.append(_check("draft_marker", "{} left in".format(_q(m.group(1))),
                                  "The PDF prints {} on p.{}: a draft marker.".format(_q(m.group(1)), page + 1),
                                  "A draft marker ({}) is left in the text here.".format(_q(m.group(1))),
                                  [_place(page, [w[:4]], w[4])], per_round=True))
    return out


def todo_note(p):
    """A \\todo or \\missingfigure in the body's source (comments blanked) that the PDF prints, placed at its note's
    words: only what a reader of the PDF sees is reported (the advisor, 2026-10-31). Not printed: todonotes loaded with
    disable, a command defined to print nothing (in the preamble, or in the body before the note), neither inside a
    conditional (a draft switch's other branch). A todonotes margin note is looked for outside the text's columns on
    the pages its line prints; an inline one (its option or todonotes' default, \\missingfigure, or a command of the
    paper's own) on the PDF lines its line prints, past the times its words are in the line's own text. The words
    looked for are the note's first words without a command, accent or math in them (`_todo_words`); a note without
    such words prints todonotes' box (at the line) or "Missing figure"."""
    pre = _unconditional(p.preamble)
    if TODO_DISABLE.search(pre):
        return []
    hidden = {m.group(1) or m.group(2) for m in TODO_HIDDEN.finditer(pre)}
    later = [(k, m.start(), m.group(1) or m.group(2))  # hidden in the body: from there on
             for k, (_, t, lo) in enumerate(p.sources) for m in TODO_HIDDEN.finditer(_unconditional(t), lo)]
    defs = pre + "".join(_unconditional(t[lo:]) for _, t, lo in p.sources)
    own = {m.group(1) or m.group(2) for m in TODO_DEFINED.finditer(defs)}  # the paper's own, not a branch's
    todonotes = bool(re.search(r"\\usepackage\s*(?:\[[^\]]*\])?\s*\{[^{}]*\btodonotes\b", p.preamble))
    inline_default = bool(TODO_INLINE.search(pre))
    out, used = [], set()
    for k, (f, t, lo) in enumerate(p.sources):
        for m in TODO.finditer(t, lo):
            cmd = m.group(1)
            if cmd in hidden or any(c == cmd and (kk, at) < (k, m.start()) for kk, at, c in later):
                continue
            j, options = m.end(), ""
            o = re.match(r"\s*\[", t[j:])
            if o:
                e = prose._bracket_end(t, j + o.end() - 1, len(t))
                options, j = t[j + o.end():e - 1], e
            o = re.match(r"\s*\{", t[j:])
            raw = t[j + o.end():prose._group_end(t, j + o.end() - 1, len(t)) - 1] if o else ""
            note = _plain_tex(re.sub(r"\}\s*\{", "} {", raw))  # \textcolor{blue}{Revise}: "blue Revise"
            line = p.line_of(f, m.start())
            boxes = p.boxes(f, line)
            opts = {o.split("=")[0].strip() for o in options.split(",")}
            inline = "inline" in opts or (inline_default and "noinline" not in opts)
            margin = cmd == "todo" and todonotes and cmd not in own and not inline
            if margin:
                pages = [b[0] for b in boxes] or (range(p.pages) if todonotes else [])

                def keep(page, w):  # outside the columns: the margin's note, not the paragraph's words
                    return not p.text_columns or p.in_margin(w)
            else:
                pages = [b[0] for b in boxes]

                def keep(page, w, boxes=boxes):  # on the PDF lines the source line prints
                    cx, cy = (w[0] + w[2]) / 2, (w[1] + w[3]) / 2
                    return any(b[0] == page and b[1][0] - 2 <= cx <= b[1][2] + 2 and b[1][1] - 2 <= cy <= b[1][3] + 2
                               for b in boxes)
            words = _todo_words(raw)
            skip = 0
            if words and not margin:  # the line's own text may hold the same words: those are not the note's
                a, b = t.rfind("\n", 0, m.start()) + 1, t.find("\n", m.start())
                end = j + o.end() + len(raw) + 1 if o else j
                around = _plain_tex(t[a:m.start()] + " " + t[end:b if b >= 0 else len(t)])
                skip = "".join(_norm(w) for w in around.split()).count("".join(_norm(w) for w in words.split()))
            place = _find_words(p, words, pages, used, keep, skip) if words else None
            if not place and not words and todonotes and cmd not in own:
                if cmd == "missingfigure":
                    place = _find_words(p, "Missing figure", [b[0] for b in boxes] or range(p.pages), used)
                elif boxes:
                    page = boxes[0][0]
                    place = _place(page, anchor._union_boxes([tuple(r) for q, r in boxes if q == page]),
                                   "{}:{}".format(f, line))
            if not place:
                continue
            what = "\\" + cmd
            name = "Todo note" if cmd == "todo" else "Missing figure"
            if note:
                out.append(_check("todo_note", "{} · {}".format(name, _q(_excerpt(note))),
                                  "{} on {}:{} prints a draft note: {}.".format(what, f, line, _q(note)),
                                  "A draft note is left in the paper here: {}.".format(_q(note)), [place]))
            else:
                out.append(_check("todo_note", "{} · {}:{}".format(name, f, line),
                                  "{} on {}:{} prints an empty draft note.".format(what, f, line),
                                  "A draft note is left in the paper here.", [place], per_round=True))
    return out


def _unconditional(t):
    """t with the text inside conditionals (\\if… to its \\fi, nested) blanked, offsets kept; \\newif opens none."""
    out, depth, at = [], 0, 0
    for m in CONDITIONAL.finditer(t):
        g = m.group(0)
        if g.startswith("\\newif"):
            continue
        if depth:
            out.append(re.sub(r"\S", " ", t[at:m.end()]))
        else:
            out.append(t[at:m.start()] + " " * (m.end() - m.start()))
        at = m.end()
        depth = max(depth + (-1 if g == "\\fi" else 1), 0)
    out.append(re.sub(r"\S", " ", t[at:]) if depth else t[at:])
    return "".join(out)


def _todo_words(raw):
    """The words of a note to look for in the PDF: its longest run of words without a command, accent, brace or math
    (\\ref prints a number, \\"o an ö), its first 4; "" for none."""
    runs, run = [], []
    for w in raw.replace("~", " ").split():
        if re.search(r"[\\${}]", w) or not _norm(w):
            if not re.search(r"[\\${}]", w):
                continue  # a dash or a symbol alone: printed, but no letters to match
            runs.append(run)
            run = []
        else:
            run.append(w)
    runs.append(run)
    return " ".join(max(runs, key=len)[:4])


def _find_words(p, text, pages, used, keep=None, skip=0):
    """The place of the first run of PDF words spelling text's first 4 words (letters and digits only, compared
    joined: a word hyphenated across lines, or a dash between, still matches; the first word may carry a prefix,
    "[TODO:Check") on these pages, past `skip` such runs, of words not used by an earlier run (its words then are);
    `keep(page, word)`: whether a word may be part of it."""
    key = "".join(n for n in (_norm(w) for w in text.split()[:4]) if n)
    if not key:
        return None
    for page in dict.fromkeys(pages):
        words = p.words(page)
        norms, _ = p.norms(page)
        for i, n in enumerate(norms):
            if not n or (page, i) in used or (keep and not keep(page, words[i])):
                continue
            got = next((n[x:] for x in range(len(n)) if key.startswith(n[x:])), None)
            if got is None:
                continue
            k = i + 1
            while len(got) < len(key) and k < len(norms):
                if norms[k]:
                    if (page, k) in used or (keep and not keep(page, words[k])):
                        break
                    got += norms[k]
                k += 1
            if got == key:
                if skip:
                    skip -= 1
                    continue
                used.update((page, x) for x in range(i, k))
                run = words[i:k]
                return _place(page, anchor._line_rects(run), comments.join_words(run))
    return None


def _colour(c):
    return (c >> 16) & 255, (c >> 8) & 255, c & 255


def _colour_name(rgb):
    return min(COLOURS, key=lambda k: sum((a - b) ** 2 for a, b in zip(COLOURS[k], rgb)))


def coloured_text(p):
    """Spans of a paragraph or item in a colour that is not black or grey, outside link rects LINK_HEIGHT (5 pt) high
    or more (hyperref's colorlinks); one per run of a colour in a block."""
    link_rects = {}
    out = []
    for k, b in enumerate(p.blocks):
        if b["kind"] not in ("paragraph", "item"):
            continue
        runs = []
        for page, r in p.parts(b):
            if page not in link_rects:
                try:
                    link_rects[page] = [list(l["from"]) for l in p.doc[page].get_links()
                                        if l["from"].height >= LINK_HEIGHT]
                except Exception:
                    link_rects[page] = []
            for box, text, _, colour, _ in p.spans(page):
                cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
                if not (r[0] - 1 <= cx <= r[2] + 1 and r[1] - 1 <= cy <= r[3] + 1):
                    continue
                rgb = _colour(colour)
                plain = max(rgb) - min(rgb) <= GREY or any(a[0] <= cx <= a[2] and a[1] <= cy <= a[3]
                                                           for a in link_rects[page])
                if p.text_area and not p.text_area[0] - 2 <= cx <= p.text_area[1] + 2:
                    continue  # a margin note beside the paragraph (todonotes)
                last = runs[-1] if runs else None
                if plain:
                    runs.append(None)
                elif last and last[0] == colour and last[1] == page:
                    last[2].append((box, text))
                else:
                    runs.append((colour, page, [(box, text)]))
        for k, run in enumerate(runs):
            if not run:
                continue
            colour, page, spans = run
            text = " ".join(" ".join(t for _, t in spans).split())
            if not re.search(r"\w", text) or k == 0 and re.fullmatch(r"(?:\S+\s+){0,5}\S+[.:]", text):
                continue  # nothing to read, or a run-in heading the style colours ("Contributions.")
            name = _colour_name(_colour(colour))
            rects = anchor._line_rects([s[0] + [None] for s in spans])
            out.append(_check("coloured_text", "{} text · {}".format(name, _q(_excerpt(text))),
                              "On p.{}, {} is set in {} (#{:06X}), not in the text's black.".format(
                                  page + 1, _q(_excerpt(text, 12)), name.lower(), colour),
                              "This text is printed in {}; remove the colour if it is not meant for the reader."
                              .format(name.lower()), [_place(page, rects, text)]))
    return out


def pdf_author(p):
    """An anonymous paper's PDF metadata naming an author (the info dictionary's or the XMP's), not "anonymous"."""
    if not p.anonymous:
        return []
    names = [(p.doc.metadata or {}).get("author") or ""]
    try:
        xmp = p.doc.get_xml_metadata() or ""
    except Exception:
        xmp = ""
    for m in re.finditer(r"<dc:creator>(.*?)</dc:creator>", xmp, re.S):
        names.append(" ".join(re.sub(r"<[^>]+>", " ", m.group(1)).split()))
    out = []
    for name in dict.fromkeys(n.strip() for n in names if n.strip()):
        if "anonymous" in name.lower():
            continue
        out.append(_check("pdf_author", "PDF author · {}".format(name),
                          "The PDF's metadata names its author, {}, though the paper is meant to be anonymous."
                          .format(_q(name)),
                          "The PDF's properties name the author ({}); clear them for the anonymous submission "
                          "(\\hypersetup{{pdfauthor={{}}}}).".format(_q(name)), []))
        break
    return out


def _author_names(t):
    """The names, affiliations and addresses in the source's author commands (AUTHOR_CMD)."""
    out = []
    for m in AUTHOR_CMD.finditer(t):
        e = prose._group_end(t, m.end(), len(t))
        s = t[m.end() + 1:e - 1]
        s = re.sub(r"\\(?:thanks|footnote|IEEEauthorrefmark|footnotemark)\s*(?:\[[^\]]*\])?\s*\{[^{}]*\}", " ", s)
        s = re.sub(r"\\\\|\\(?:and|AND|And|quad|qquad|hfill|newline|IEEEauthorblock[NA])\b|,|\$[^$]*\$", "\n", s)
        for piece in re.split(r"\n|\band\b", s):
            piece = _plain_tex(piece)
            if "anonymous" in piece.lower() or len(_norm(piece)) < 3:
                continue
            if "@" in piece or len(re.findall(r"[A-Za-z]{2,}", piece)) >= 2:
                out.append(piece)
    return list(dict.fromkeys(out))


def author_block(p):
    """An anonymous paper's page 1 printing a name from its author commands (\\author, \\icmlauthor,
    \\IEEEauthorblockN, \\affiliation, \\institute, \\email)."""
    if not p.anonymous or not p.pages:
        return []
    names = list(dict.fromkeys(n for f, t, lo in p.sources for n in _author_names(p.text(f) or "")))
    words = p.words(0)
    norms = [_norm(w[4]) for w in words]
    found, places = [], []
    for name in names:
        want = [n for n in (_norm(w) for w in name.split()) if n]
        for i in range(len(words) - len(want) + 1):
            if want and norms[i:i + len(want)] == want:
                run = words[i:i + len(want)]
                found.append(name)
                places.append(_place(0, anchor._line_rects(run), comments.join_words(run)))
                break
    if not found:
        return []
    return [_check("author_block", "Author named · {}".format(_q(found[0])),
                   "Page 1 prints {} from the author block, though the paper is meant to be anonymous.".format(
                       " and ".join(_q(n) for n in found)),
                   "Page 1 names the authors ({}); the anonymous submission must not.".format(
                       ", ".join(found)), _sorted(p, places))]


def acknowledgements(p):
    """An anonymous paper's heading (or a paragraph starting) Acknowledg(e)ment(s)."""
    if not p.anonymous:
        return []
    out = []
    for b in p.blocks:
        if b["kind"] not in ("heading", "paragraph") or not ACKNOWLEDGEMENTS.match(b.get("text") or ""):
            continue
        parts = p.parts(b)
        if not parts:
            continue
        page, r = parts[0]
        word = next((w for _, w in p.words_in(page, [r]) if re.match(r"acknowledge?ments?", w[4], re.I)), None)
        out.append(_check("acknowledgements", "Acknowledgements in an anonymous paper",
                          "The paper has acknowledgements, though it is meant to be anonymous; they may name people "
                          "or grants.",
                          "Leave the acknowledgements out of the anonymous submission; they can return in the final "
                          "version.", [_place(page, [word[:4] if word else r], word[4] if word else None)]))
        break
    return out


def _account(url):
    """The account a URL names ("github.com/linzhou", "linzhou.github.io", "example.edu/~lin"), or None for an
    organisation's (ORGS), a reserved path, a Hugging Face dataset, model or space without an owner, or a placeholder
    (PLACEHOLDER: "XXX", "anonymous", "username")."""
    m = HOSTED.search(url)
    if m:
        host, user = m.group(1).lower(), m.group(2)
        if host == "huggingface.co" and user.lower() in ("datasets", "spaces", "models", "collections"):
            # an owner's repository (datasets/linzhou/trace), not a canonical one without an owner (datasets/squad)
            tail = (m.group(4) or "").lstrip("/").lower()
            user = m.group(3) if tail and tail not in HF_PAGES else ""
        elif user.lower() in ("users", "groups", "organizations"):
            user = m.group(3) or ""  # github.com/users/linzhou
        user = (user or "").rstrip(".")
        if user.endswith("-"):  # a name cut at a line's end ("nyu-"): no name ends so
            return None
        if user and user.lower() not in RESERVED and user.lower() not in ORGS and not PLACEHOLDER.fullmatch(user):
            return "{}/{}".format(host, user.lower())  # GitHub's, GitLab's and Hugging Face's names ignore case
        return None
    m = PAGES_URL.search(url)
    if m and m.group(1).lower() not in ORGS and not PLACEHOLDER.fullmatch(m.group(1)):
        return "{}.github.io".format(m.group(1).lower())
    m = TILDE.search(url)
    if m and not PLACEHOLDER.fullmatch(m.group(2)):
        host = m.group(1).lower()
        return "{}/~{}".format(host[4:] if host.startswith("www.") else host, m.group(2))
    return None


def personal_url(p):
    """An anonymous paper's links and words in the body (not the references) naming a person's account: GitHub,
    GitLab, Bitbucket or Hugging Face user paths, <user>.github.io, /~user; organisations (ORGS) and
    anonymous.4open.science are fine. A word under a URL link is the link's (judged by its whole URL). Nothing is
    guessed beyond (a dataset's home on a personal path, a URL broken across lines, a link's words naming another
    account): a check is a reminder the advisor may mark OK (the advisor, 2026-10-31)."""
    if not p.anonymous:
        return []
    found, linked = {}, []  # account: (url, [places]); the URL links' places (their whole URL judged)
    for e in p.links:
        t = p.targets[e["targets"][0]]
        if t["kind"] != "url" or not t["url"] or any(p.in_references(e["page"], r) for r in e["rects"]):
            continue
        linked.append(_place(e["page"], e["rects"], e["text"]))
        account = _account(t["url"])
        if account:
            found.setdefault(account, (t["url"], []))[1].append(_place(e["page"], e["rects"], e["text"]))
    for page in range(p.pages):
        words = p.words(page)
        for w in words:
            if p.in_references(page, w) or _covered(linked, page, w):
                continue
            url = w[4].strip("()[],;.:<>\"'")
            account = _account(url)
            if account and not _covered(found.get(account, (None, []))[1], page, w):
                found.setdefault(account, (url, []))[1].append(_place(page, [w[:4]], w[4]))
    out = []
    for account, (url, places) in found.items():
        places = _sorted(p, places)
        out.append(_check("personal_url", "Link may name an author · {}".format(account),
                          "{} on {} names the account {}, which may identify an author of an anonymous paper."
                          .format(url, _pages(places), _q(account)),
                          "This link may reveal who wrote the paper; for the anonymous submission use an anonymised "
                          "repository (such as anonymous.4open.science).", places))
    return out


RUNS = [("undefined_ref", undefined_ref), ("undefined_cite", undefined_cite), ("label_twice", label_twice),
        ("float_unreferenced", float_unreferenced), ("float_before", float_before), ("float_far", float_far),
        ("same_work", same_work), ("lowered_caps", lowered_caps), ("no_year", no_year), ("no_venue", no_venue),
        ("venue_forms", venue_forms), ("venue_style", venue_style), ("author_names", author_names),
        ("author_case", author_case), ("title_case", title_case), ("etal_by_hand", etal_by_hand),
        ("leftovers", leftovers), ("field_mix", field_mix), ("page_dash", page_dash), ("arxiv_forms", arxiv_forms),
        ("published_preprint", published_preprint), ("no_record", no_record), ("record_differs", record_differs),
        ("spelling", spelling), ("ref_style", ref_style), ("overfull", overfull),
        ("straight_quotes", straight_quotes), ("doubled_word", doubled_word), ("type3_font", type3_font),
        ("unembedded_font", unembedded_font), ("draft_marker", draft_marker), ("todo_note", todo_note),
        ("coloured_text", coloured_text), ("pdf_author", pdf_author), ("author_block", author_block),
        ("acknowledgements", acknowledgements), ("personal_url", personal_url)]
