"""A round's paragraphs for reading in the PDF (CONTRACT.md amendments "Prose view and reading" and "Reading in the
PDF view", mac/UX.md §18).

A round's LaTeX in reading order as blocks of readable text: exact source ranges, a map from the display text back
to the source, a content hash per block for read state, a place in the PDF (`parts`: one rect per column it is set
in; `box` and `clip` for a float, formula or listing), and the student's word edits against the previous round (they
decide which blocks were edited). `build` writes it to rN/prose.json, a cache (analysis.json is primary). Read state
is the ledger's top-level `read` map {hash: round}.
The prose view that showed these blocks as text is gone (2026-10-16); the advisor reads in the PDF.

The block rules (splitting at blank lines, headings, items, list and wrapper environments and one-line commands; one
block per formula, float, listing or picture) and the table of text commands follow the design of Paper Pal's
parseBlocks and TEXT_COMMANDS (github.com/Claire1217/paper-pal, MIT licence), as CONTRACT.md describes them, written
in Python for code-point offsets, the paper's \\input order and a source map.
"""
import bisect
import contextlib
import functools
import hashlib
import json
import os
import posixpath
import re
import sys
import traceback
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path

from . import EngineError, analysis, anchor, cards, comments, ledger, texdiff

# stored in prose.json; a file with another value is stale (2: \subref as printed, a move holding all of a block's
# words marks it moved, listings have role "listing", float crops leave out the caption; 3: formula crops of their
# own lines, \label/\vspace/\noindent… lines inside a paragraph and out of the hash, \end on a text line, `%` in
# listings, split and joined paragraphs, blocks' "since"; 4: "parts" for reading in the PDF, no KaTeX macros; 5: an
# item's parts without the lines of the block before, text parts without a margin ruler's numbers; 6: a last line
# holding a single word is in its block's parts, _tails; 7: a text block's parts print its own text, _own_text; 8:
# "previous", where each block of the round before is in this round, for the overview's sections, _previous; 9: no
# display opened by \\[2pt] or \verb, \chapter and \part headings, a one-line command that may print text inside a
# paragraph, ICML's front matter hidden, a float's "inputs", a paragraph's part in the next column its text rather
# than its footnote, placeholder change ids, no "since", "role", item "label"/"depth", formula "number" or text
# blocks' "box"; texdiff: `%` in \url printed)
PARSER = 9
SCHEMA = 1
MAX_DEPTH, MAX_EXPANSIONS = 6, 1500  # user macros: nesting depth, and expansions a block

# levels; in a source with \chapter (a report, book or thesis) chapters are level 1 and the others one lower
# (_Reader.heading); a \part is level 1 and unnumbered
HEADINGS = {"part": 1, "chapter": 1, "section": 1, "subsection": 2, "subsubsection": 3, "paragraph": 4}
MATH = {"equation", "align", "gather", "multline", "flalign", "alignat", "eqnarray", "displaymath"}
KATEX = {"align": "align*", "alignat": "alignat*", "gather": "gather*", "multline": "gather*", "flalign": "align*",
         "eqnarray": "align*"}  # display environments as KaTeX takes them (equation and displaymath: the body alone)
FIGURES = {"figure", "wrapfigure", "sidewaysfigure"}
TABLES = {"table", "wraptable", "sidewaystable"}
ALGORITHMS = {"algorithm", "algorithmic", "algorithm2e"}
CODE = {"verbatim", "Verbatim", "lstlisting", "minted"}
PICTURES = {"tikzpicture", "pgfpicture"}
TABULARS = {"tabular", "tabularx", "tabulary", "longtable"}
ONE_BLOCK = MATH | FIGURES | TABLES | ALGORITHMS | CODE | PICTURES | TABULARS | {"thebibliography"}
LISTS = {"itemize", "enumerate", "description", "compactitem", "compactenum", "compactdesc", "asparaitem",
         "asparaenum", "inparaitem", "inparaenum"}
IMAGE_KINDS = {"figure", "table", "math", "code", "picture"}
READABLE = {"title", "heading", "paragraph", "item", "bibitem"}  # kinds dropped when they print nothing
READ = {"paragraph", "item", "bibitem", "math", "figure", "table", "code", "picture"}  # kinds read in the PDF (readable)
ENV_ARGS = {"minipage": 1, "multicols": 1, "adjustbox": 1, "subfigure": 1, "subtable": 1, "spacing": 1, "list": 2,
            "CJK": 2, "otherlanguage": 1, "boxedminipage": 1, "wrapfigure": 2, "wraptable": 2}
CLUSTER = 24.0  # points: a block's boxes further apart down the page than this are not one run (_cluster)
HEAD_GAP = 12.0  # points: a running head or foot is at least this far from the page's other lines (_running)
LINE = 14.0  # points: a box at most this high is one line of text
TALL = 40.0  # points: a box this high in a text block is a column's or a page's (the output routine's), not a line
TAIL_GAP = 6.0  # points: a last line given to a later source line is at most this far below the line above (_tails)
OWN_GRAM = 6  # letters: the shortest piece of a block's text that its boxes' text is made of (_own_text)
OWN_SHARE = 0.6  # share of a box's letters and digits that must lie in such pieces (_own_text)
OWN_LETTERS = 12  # letters and digits that a box needs to tell by itself whether it prints the block's text
OWN_BODY = 0.3  # share of them in pieces of the text outside footnotes that makes a part the block's own text

STYLES = {"emph": "em", "textit": "em", "textsl": "em", "textbf": "bf", "texttt": "tt", "textsc": "sc",
          "underline": "u", "uline": "u", "textsuperscript": "sup", "textsubscript": "sub"}
DECLS = {"em": "em", "it": "em", "itshape": "em", "sl": "em", "slshape": "em", "bf": "bf", "bfseries": "bf",
         "tt": "tt", "ttfamily": "tt", "sc": "sc", "scshape": "sc"}
PLAIN = {"textrm": 0, "textsf": 0, "textnormal": 0, "textup": 0, "textmd": 0, "mbox": 0, "hbox": 0, "text": 0,
         "fbox": 0, "makecell": 0, "centerline": 0, "sout": 0, "st": 0, "hl": 0, "makebox": 0, "framebox": 0,
         "textcolor": 1, "colorbox": 1, "fcolorbox": 2, "raisebox": 1, "resizebox": 2, "scalebox": 1,
         "rotatebox": 1, "adjustbox": 1, "parbox": 1, "multicolumn": 2, "multirow": 2, "foreignlanguage": 1,
         "captionof": 1}
NOTES = {"footnote", "footnotetext", "thanks"}
CITES = {"cite", "citep", "citet", "citealp", "citealt", "citeauthor", "citeyear", "citeyearpar", "citenum",
         "Cite", "Citep", "Citet", "Citealp", "Citealt", "Citeauthor", "parencite", "Parencite", "textcite",
         "Textcite", "autocite", "Autocite", "footcite"}
REFS = {"ref", "pageref", "eqref", "autoref", "Autoref", "cref", "Cref", "vref", "nameref", "subref", "labelcref",
        "cpageref", "Cpageref"}
SYMBOLS = {"ldots": "…", "dots": "…", "textellipsis": "…", "textendash": "–", "textemdash": "—",
           "textquoteleft": "‘", "textquoteright": "’", "textquotedblleft": "“", "textquotedblright": "”",
           "ss": "ß", "o": "ø", "O": "Ø", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "aa": "å", "AA": "Å",
           "l": "ł", "L": "Ł", "i": "ı", "j": "ȷ", "copyright": "©", "textcopyright": "©", "textregistered": "®",
           "texttrademark": "™", "S": "§", "textsection": "§", "P": "¶", "textparagraph": "¶", "dag": "†",
           "textdagger": "†", "ddag": "‡", "textdaggerdbl": "‡", "textbullet": "•", "textdegree": "°",
           "textasciitilde": "~", "textasciicircum": "^", "textbackslash": "\\", "textbar": "|", "textless": "<",
           "textgreater": ">", "textunderscore": "_", "textdollar": "$", "pounds": "£", "textsterling": "£",
           "euro": "€", "texteuro": "€", "textmu": "µ", "textpm": "±", "texttimes": "×",
           "textperiodcentered": "·", "checkmark": "✓", "LaTeX": "LaTeX", "TeX": "TeX", "LaTeXe": "LaTeX2ε",
           "slash": "/", "textquotesingle": "'", "textasteriskcentered": "*", "guillemotleft": "«",
           "guillemotright": "»", "textcent": "¢", "textyen": "¥"}
SPACES = {"quad", "qquad", "enspace", "enskip", "newline", "linebreak", "par", "thinspace", "space", "item"}
ACCENTS = {"'": "\u0301", "`": "\u0300", "^": "\u0302", '"': "\u0308", "~": "\u0303", "=": "\u0304", ".": "\u0307",
           "u": "\u0306", "v": "\u030c", "H": "\u030b", "c": "\u0327", "d": "\u0323", "b": "\u0331", "r": "\u030a",
           "k": "\u0328", "t": "\u0361"}
DINGS = {"51": "✓", "52": "✔", "55": "✗", "56": "✘", "72": "★", "108": "●"}
DINGS.update({str(first + k): chr(code + k) for first, code in ((172, 0x2460), (182, 0x2776), (192, 0x2780),
                                                                 (202, 0x278A)) for k in range(10)})  # ① ❶ ➀ ➊
HIDDEN = set("noindent indent centering raggedright raggedleft smallskip medskip bigskip clearpage newpage "
             "cleardoublepage pagebreak nopagebreak maketitle appendix protect relax xspace hfill vfill hss null "
             "leavevmode nobreak allowbreak sloppy fussy normalfont rmfamily sffamily upshape mdseries selectfont "
             "tiny scriptsize footnotesize small normalsize large Large LARGE huge Huge frenchspacing hline toprule "
             "midrule bottomrule FloatBarrier balance onecolumn twocolumn ignorespaces unskip makeatletter "
             "makeatother begingroup endgroup bgroup egroup footnotemark tableofcontents listoffigures "
             "listoftables phantomsection strut mathstrut global nointerlineskip suppressfloats arraybackslash "
             "crcr cr hrule vrule iclrfinalcopy aclfinalcopy newblock displaystyle textstyle scriptstyle "
             "boldmath unboldmath normalcolor justifying flushbottom raggedbottom printindex abovedisplayskip "
             "belowdisplayskip fi else expandafter noexpand nonumber notag tcbbreak".split())
HIDDEN_ARGS = {"label": 1, "vspace": 1, "hspace": 1, "addvspace": 1, "index": 1, "glossary": 1, "nocite": 1,
               "bibliographystyle": 1, "setlength": 2, "addtolength": 2, "setcounter": 2, "addtocounter": 2,
               "stepcounter": 1, "refstepcounter": 1, "pagestyle": 1, "thispagestyle": 1, "linespread": 1,
               "captionsetup": 1, "color": 1, "definecolor": 3, "colorlet": 2, "graphicspath": 1,
               "includegraphics": 1, "enlargethispage": 1, "fontsize": 2, "usepackage": 1, "RequirePackage": 1,
               "input": 1, "include": 1, "subfile": 1, "lhead": 1, "rhead": 1, "chead": 1, "lfoot": 1, "cfoot": 1,
               "rfoot": 1, "fancyhead": 1, "fancyfoot": 1, "newlength": 1, "settowidth": 2, "tcbuselibrary": 1,
               "usetikzlibrary": 1, "hypersetup": 1, "urlstyle": 1, "phantom": 1, "hphantom": 1, "vphantom": 1,
               "newcounter": 1, "newenvironment": 3, "renewenvironment": 3, "rowcolor": 1, "cellcolor": 1,
               "arrayrulecolor": 1, "author": 1, "date": 1, "title": 1, "markboth": 2, "markright": 1,
               "cmidrule": 1, "addlinespace": 0, "specialrule": 3, "bibliography": 1,
               "pdfbookmark": 2, "hyphenation": 1, "selectlanguage": 1, "theoremstyle": 1, "newtheorem": 2,
               "crefname": 3, "Crefname": 3, "newfloat": 3, "floatname": 2, "sethlcolor": 1, "affiliation": 1,
               "address": 1, "email": 1, "keywords": 1, "institute": 1, "printAffiliationsAndNotice": 1,
               "icmltitle": 1, "icmltitlerunning": 1, "icmlsetsymbol": 2, "icmlauthor": 2, "icmlaffiliation": 2,
               "icmlcorrespondingauthor": 2, "icmlkeywords": 1}  # ICML's title and author block (D4: not read)
DIMENS = {"vskip", "hskip", "kern", "mskip", "penalty", "vspace*", "hspace*"}  # take a dimension or number
DEFINES = {"newcommand", "renewcommand", "providecommand", "DeclareMathOperator", "def", "gdef", "edef", "xdef",
           "let", "DeclareRobustCommand", "newif"}
TYPE_NAMES = {"section": "Section", "subsection": "Section", "subsubsection": "Section", "paragraph": "Section",
              "appendix": "Appendix", "subappendix": "Appendix", "subsubappendix": "Appendix", "figure": "Figure",
              "subfigure": "Figure", "table": "Table", "subtable": "Table", "equation": "Equation",
              "algorithm": "Algorithm", "line": "Line", "theorem": "Theorem", "lemma": "Lemma",
              "definition": "Definition", "chapter": "Chapter", "listing": "Listing", "footnote": "Footnote",
              "enumi": "Item"}
PREFIXES = {"fig": "Figure", "tab": "Table", "sec": "Section", "subsec": "Section", "eq": "Equation",
            "app": "Appendix", "appendix": "Appendix", "alg": "Algorithm", "thm": "Theorem", "lem": "Lemma",
            "def": "Definition", "lst": "Listing"}

INLINE = {"label", "vspace", "hspace", "noindent", "indent", "hfill", "smallskip", "medskip", "bigskip", "index",
          "nocite", "nobreak", "allowbreak", "linebreak", "newline"}  # alone on a line: the paragraph goes on (TeX)
UNPRINTED = INLINE - {"linebreak", "newline"}  # left out of the hash (_unprinted)
KNOWN = set(STYLES) | set(DECLS) | set(PLAIN) | NOTES | CITES | REFS | set(SYMBOLS) | SPACES | HIDDEN \
    | set(HIDDEN_ARGS) | {"url", "href", "nolinkurl", "path", "verb", "ding"}
SILENT = HIDDEN | set(HIDDEN_ARGS) | SPACES | DIMENS | DEFINES  # known to print no text: a line of one ends a paragraph
CMD = re.compile(r"\\([A-Za-z@]+)(\*?)|\\(.)", re.S)
ORDINARY = re.compile(r"[^\\{}$~`'\-\s%&#^_]+")
BEGIN = re.compile(r"\\begin\s*\{([^{}]*)\}")
END = re.compile(r"\\end\s*\{([^{}]*)\}")
# a line break (\\[2pt]) and \verb|…| are matched first: the \[ in them opens no display (text_line)
ENV_TOKEN = re.compile(r"\\\\|\\verb\*?([^\sA-Za-z*])[^\n]*?\1|\\(begin|end)\s*\{([^{}]*)\}|\\\[|\\\]")
INPUT = re.compile(r"\\(input|include|subfile)\s*\{([^{}]*)\}|\\(?:sub)?import\s*\{([^{}]*)\}\s*\{([^{}]*)\}|"
                   r"\\input[ \t]+([^\s{}\\%]+)")
REFERENCES = re.compile(r"(?:\\bibliographystyle\s*\{[^{}]*\}\s*)?\\(?:bibliography\s*\{[^{}]*\}|"
                        r"printbibliography\b(?:\s*\[[^\]]*\])?)")
HEADING = re.compile(r"\\(part|chapter|section|subsection|subsubsection|paragraph)(?![A-Za-z@])(\*?)")
_UNIT = r"(?:\s*(?:true)?(?:(?:pt|em|ex|mm|cm|in|bp|sp|pc|dd|cc|mu|fil+)(?![A-Za-z])|\\[A-Za-z@]+))?"
DIMEN = re.compile(r"\s*=?\s*-?(?:\d+\.?\d*|\.\d+)?" + _UNIT + r"(?:\s*(?:plus|minus)\s*-?(?:\d+\.?\d*|\.\d+)?"
                   + _UNIT + r")*")
LABEL = re.compile(r"\\label\s*\{[^{}]*\}|\\nonumber\b|\\notag\b")


# --- reading the source ----------------------------------------------------------------------------------------

def _group_end(t, i, hi):
    """The index after the one {group} starting at t[i] (at most hi)."""
    depth, j = 0, i
    while j < hi:
        c = t[j]
        if c == "\\":
            j += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return hi


def _bracket_end(t, i, hi):
    """The index after the [option] starting at t[i]: the first ] outside braces (at most hi)."""
    depth, j = 0, i + 1
    while j < hi:
        c = t[j]
        if c == "\\":
            j += 2
            continue
        depth += (c == "{") - (c == "}")
        if c == "]" and depth <= 0:
            return j + 1
        j += 1
    return hi


def _groups(s):
    """The top-level {…} groups of s, as strings."""
    out, i = [], 0
    while i < len(s):
        if s[i] == "{":
            e = _group_end(s, i, len(s))
            out.append(s[i + 1:e - 1])
            i = e
        else:
            i += 1
    return out


def _env_end(t, start, name, hi):
    """The end of the \\end{name} matching the \\begin{name} at start (environments of the same name nest), or hi."""
    depth = 0
    for m in _env_pattern(name).finditer(t, start, hi):
        depth += 1 if m.group(1) == "begin" else -1
        if depth == 0:
            return m.end()
    return hi


@functools.lru_cache(maxsize=64)
def _env_pattern(name):
    return re.compile(r"\\(begin|end)\s*\{" + re.escape(name) + r"\}")


def _definitions(t, defs):
    """Add the \\newcommand, \\def and \\DeclareMathOperator definitions of source t (comments blanked) to defs:
    {name: (number of arguments, default of the optional first one or None, body)}."""
    for m in re.finditer(r"\\(newcommand|renewcommand|providecommand|DeclareRobustCommand|DeclareMathOperator|"
                         r"g?def|edef|xdef)\b(\*?)", t):
        kind, j = m.group(1), m.end()
        while j < len(t) and t[j].isspace():
            j += 1
        if kind.endswith("def"):
            name = CMD.match(t, j)
            if not name or not name.group(1):
                continue
            j = name.end()
            params = re.match(r"(?:#\d)*", t[j:]).group()
            j += len(params)
            if j >= len(t) or t[j] != "{":
                continue
            e = _group_end(t, j, len(t))
            defs[name.group(1)] = (len(params) // 2, None, t[j + 1:e - 1])
            continue
        if j < len(t) and t[j] == "{":
            e = _group_end(t, j, len(t))
            name = CMD.match(t[j + 1:e - 1].strip())
            j = e
        else:
            name = CMD.match(t, j)
            j = name.end() if name else j
        if not name or not name.group(1):
            continue
        nargs, default = 0, None
        o = re.match(r"\s*\[(\d)\]", t[j:])
        if o:
            nargs, j = int(o.group(1)), j + o.end()
            o = re.match(r"\s*\[", t[j:])
            if o:
                e = _bracket_end(t, j + o.end() - 1, len(t))
                default, j = t[j + o.end():e - 1], e
        while j < len(t) and t[j].isspace():
            j += 1
        if j >= len(t) or t[j] != "{":
            continue
        e = _group_end(t, j, len(t))
        body = t[j + 1:e - 1]
        if kind == "DeclareMathOperator":
            body, nargs = "\\operatorname{}{{{}}}".format("*" if m.group(2) else "", body), 0
        if kind == "providecommand" and (name.group(1) in defs or name.group(1) in KNOWN):
            continue  # a .bbl's \\providecommand{\\url} does not replace the \\url handled here
        defs[name.group(1)] = (nargs, default, body)


def _aux(build, stem):
    """({key: (number, year, short authors)}, {label: [number, page, title]}, {label: cleveref type}) from the
    build's .aux files. year and authors are None for a citation written without natbib."""
    cites, labels, types, seen = {}, {}, {}, set()

    def read(path):
        if path in seen or not path.is_file():
            return
        seen.add(path)
        t = path.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"\\bibcite\{([^{}]*)\}\{", t):
            e = _group_end(t, m.end() - 1, len(t))
            g = _groups(t[m.end():e - 1])
            cites[m.group(1)] = (g[0], g[1], g[2]) if len(g) >= 3 else (t[m.end():e - 1], None, None)
        for m in re.finditer(r"\\newlabel\{([^{}]*)\}\{", t):
            e = _group_end(t, m.end() - 1, len(t))
            g = _groups(t[m.end():e - 1])
            if m.group(1).endswith("@cref") and g:
                kind = re.match(r"\[([^\]]*)\]", g[0])
                if kind:
                    types[m.group(1)[:-5]] = kind.group(1)
            elif g:
                labels[m.group(1)] = (g + ["", "", ""])[:3]
        for m in re.finditer(r"\\@input\{([^{}]*)\}", t):
            read(Path(build) / m.group(1))
    read(Path(build) / (stem + ".aux"))
    return cites, labels, types


class _Ctx:
    """What converting a block needs: the paper's definitions and its .aux data."""

    def __init__(self, defs, aux, authoryear):
        self.defs, (self.cites, self.labels, self.types), self.authoryear = defs, aux, authoryear
        self.expansions = 0
        self._plain = {}

    def plain(self, tex):
        """The display text of a piece of TeX (an author list, a label's number), without marks or map."""
        if tex not in self._plain:
            c = _Conv(self, tex, tex)
            c.run(0, len(tex))
            self._plain[tex] = c.finish()[0]
        return self._plain[tex]

    def cite(self, name, keys, notes):
        """The printed form of a citation command (natbib author-year or numeric; [?] when unresolved)."""
        found = [self.cites.get(k) for k in keys]
        if not any(found):
            return "[?]"
        pre, post = (notes + ["", ""])[:2] if len(notes) == 2 else ("", notes[0] if notes else "")
        pre, post = self.plain(pre), self.plain(post)
        nums = [self.plain(f[0]) if f else "?" for f in found]
        years = [self.plain(f[1]) if f and f[1] is not None else "?" for f in found]
        names = [self.plain(f[2]) if f and f[2] is not None else "?" for f in found]
        base = name.lower()
        if base == "citenum":
            out = ", ".join(nums)
        elif base == "citeauthor":
            out = "; ".join(names)
        elif base == "citeyear":
            out = ", ".join(years)
        elif base == "citeyearpar":
            out = "(" + ", ".join(years) + ")"
        elif self.authoryear:
            if base in ("citet", "cite", "textcite"):
                out = "; ".join("{} ({})".format(a, y) for a, y in zip(names, years))
                out = out[:-1] + ", " + post + ")" if post else out
            elif base == "citealt":
                out = "; ".join("{} {}".format(a, y) for a, y in zip(names, years))
            else:
                inner = "; ".join("{}, {}".format(a, y) for a, y in zip(names, years))
                inner = (pre + " " if pre else "") + inner + (", " + post if post else "")
                out = inner if base == "citealp" else "(" + inner + ")"
        elif base in ("citet", "textcite") and found[0] and found[0][2] is not None:
            out = "; ".join("{} [{}]".format(a, k) for a, k in zip(names, nums))
        elif base == "citealp":
            out = ", ".join(nums)
        else:
            out = "[" + ", ".join(nums) + (", " + post if post else "") + "]"
        return out[:1].upper() + out[1:] if name[0].isupper() else out

    def ref(self, name, keys):
        """The printed form of a reference command: the \\newlabel number, with a type name for \\cref, \\Cref and
        \\autoref; ?? for an unknown label."""
        def num(k):
            if name == "subref":
                v = self.labels.get("sub@" + k) or self.labels.get(k)
                return self.plain(v[0]) if v else "??"  # the sub@ label holds the printed form
            v = self.labels.get(k)
            if v is None:
                return "??"
            return self.plain(v[{"pageref": 1, "cpageref": 1, "Cpageref": 1, "nameref": 2}.get(name, 0)])
        nums = [num(k) for k in keys]
        if name == "eqref":
            return ", ".join("(" + n + ")" for n in nums)
        if name not in ("cref", "Cref", "autoref", "Autoref", "labelcref", "cpageref", "Cpageref") \
                or name == "labelcref":
            return ", ".join(nums)
        if name in ("cpageref", "Cpageref"):
            return ("Page " if len(nums) == 1 else "Pages ") + _join(nums)
        runs = []
        for k, n in zip(keys, nums):
            typ = TYPE_NAMES.get(self.types.get(k, ""), PREFIXES.get(k.split(":")[0].lower()) if ":" in k else None)
            if typ == "Equation" and name != "autoref":
                n = "(" + n + ")"
            if runs and runs[-1][0] == typ:
                runs[-1][1].append(n)
            else:
                runs.append((typ, [n]))
        return " and ".join((typ + ("s " if len(ns) > 1 else " ") if typ else "") + _join(ns) for typ, ns in runs)


def _join(items):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


class _Conv:
    """Converts LaTeX source (text: comments blanked; raw: as written, for \\url and \\verb) to display text, marks
    and a map back to the source: entries [d, n, s, m] pair the display text [d, d+n) with the source [s, s+m); when
    n == m they pair one by one, otherwise (or with a fifth element) the entry is atomic."""

    def __init__(self, ctx, text, raw, depth=0):
        self.ctx, self.t, self.raw, self.depth = ctx, text, raw, depth
        self.parts, self.n, self.marks, self.map = [], 0, [], []

    def put(self, s, a, b, atomic=False):
        if not s:
            return
        last = self.map[-1] if self.map else None
        if not atomic and len(s) == b - a and last and len(last) == 4 and last[1] == last[3] \
                and last[0] + last[1] == self.n and last[2] + last[3] == a:
            last[1] += len(s)
            last[3] += len(s)
        else:
            self.map.append([self.n, len(s), a, b - a] + ([1] if atomic and len(s) == b - a else []))
        self.parts.append(s)
        self.n += len(s)

    def space(self, a, b):
        if self.n and not self.parts[-1][-1].isspace():
            self.put(" ", a, b, atomic=b - a != 1)

    def mark(self, start, kind, *extra):
        if self.n > start:
            self.marks.append([start, self.n, kind] + list(extra))

    def finish(self):
        """(text, marks, map) with trailing spaces trimmed."""
        text = "".join(self.parts)
        cut = len(text) - len(text.rstrip())
        while cut and self.map:
            e = self.map[-1]
            k = min(cut, e[1])
            e[1] -= k
            if len(e) == 4 and e[1] + k == e[3]:
                e[3] -= k
            if e[1] <= 0:
                self.map.pop()
            cut -= k
        text = text.rstrip()
        marks = [[s, min(e, len(text))] + rest for s, e, *rest in self.marks if s < len(text)]
        return text, marks, self.map

    def skip_ws(self, j, hi):
        while j < hi and self.t[j].isspace():
            j += 1
        return j

    def arg(self, j, hi):
        """(start, end, next) of the argument at j: the inside of a {group}, or one token."""
        k = self.skip_ws(j, hi)
        if k >= hi:
            return k, k, k
        if self.t[k] == "{":
            e = _group_end(self.t, k, hi)
            return k + 1, max(e - 1, k + 1), e
        m = CMD.match(self.t, k)
        e = m.end() if m else k + 1
        return k, e, e

    def opt(self, j, hi):
        k = self.skip_ws(j, hi)
        if k < hi and self.t[k] == "[":
            e = _bracket_end(self.t, k, hi)
            return k + 1, e - 1, e
        return None

    def opts(self, j, hi):
        out = []
        o = self.opt(j, hi)
        while o:
            out.append(self.t[o[0]:o[1]])
            j = o[2]
            o = self.opt(j, hi)
        return out, j

    def run(self, i, hi):
        t, opened = self.t, []
        while i < hi:
            c = t[i]
            if c.isspace():
                j = i + 1
                while j < hi and t[j].isspace():
                    j += 1
                self.space(i, j)
                i = j
                continue
            m = ORDINARY.match(t, i, hi)
            if m:
                self.put(m.group(), i, m.end())
                i = m.end()
            elif c == "{":
                j = _group_end(t, i, hi)
                self.run(i + 1, max(j - 1, i + 1))
                i = j
            elif c == "}":
                i += 1
            elif c == "$":
                i = self.dollar(i, hi)
            elif c == "~":
                self.put("\u00a0", i, i + 1)
                i += 1
            elif c in "`'":
                double = t.startswith(c * 2, i)
                self.put({"`": "‘“", "'": "’”"}[c][double], i, i + 1 + double)
                i += 1 + double
            elif c == "-":
                k = 3 if t.startswith("---", i) else 2 if t.startswith("--", i) else 1
                self.put({1: "-", 2: "–", 3: "—"}[k], i, i + k)
                i += k
            elif c == "%":
                j = t.find("\n", i, hi)
                i = hi if j < 0 else j
            elif c == "&":
                self.space(i, i + 1)
                i += 1
            elif c == "\\":
                i = self.command(i, hi, opened)
            else:
                self.put(c, i, i + 1)
                i += 1
        for start, kind in opened:
            self.mark(start, kind)

    def dollar(self, i, hi):
        t = self.t
        if t.startswith("$$", i):
            close = t.find("$$", i + 2, hi)
            if close < 0:
                return i + 2
            self.math(i + 2, close, i, close + 2)
            return close + 2
        j = i + 1
        while j < hi and t[j] != "$":
            j += 2 if t[j] == "\\" else 1
        if j >= hi:
            self.put("$", i, i + 1)
            return i + 1
        self.math(i + 1, j, i, j + 1)
        return j + 1

    def math(self, bs, be, a, b):
        tex = " ".join(LABEL.sub("", self.t[bs:be]).split())
        start = self.n
        self.put(tex, a, b, atomic=True)
        self.mark(start, "math")

    def accent(self, i, j, mark, hi):
        a, b, k = self.arg(j, hi)
        base = self.ctx.plain(self.t[a:b]) or " "
        self.put(base[0] + mark + base[1:], i, k, atomic=True)
        return k

    def chip(self, a, b):
        start = self.n
        self.put(" ".join(self.t[a:b].split()), a, b, atomic=True)
        self.mark(start, "tex")

    def command(self, i, hi, opened):
        t = self.t
        m = CMD.match(t, i)
        if not m:
            self.put("\\", i, i + 1)
            return i + 1
        j = m.end()
        if m.group(3) is not None:
            return self.symbol(i, m.group(3), j, hi)
        name, star = m.group(1), m.group(2)
        if name in self.ctx.defs:
            return self.macro(i, j, self.ctx.defs[name], hi)
        if name in ("begin", "end"):
            return self.env(i, name, hi)
        if name in STYLES or name in NOTES:
            _, j = self.opts(j, hi)
            a, b, k = self.arg(j, hi)
            start = self.n
            self.run(a, b)
            self.mark(start, STYLES.get(name, "fn"))
            return k
        if name in DECLS:
            opened.append((self.n, DECLS[name]))
            return self.skip_ws(j, hi)
        if name in PLAIN:
            for _ in range(PLAIN[name]):
                _, j = self.opts(j, hi)
                j = self.arg(j, hi)[2]
            _, j = self.opts(j, hi)
            a, b, k = self.arg(j, hi)
            self.run(a, b)
            return k
        if name in ("url", "nolinkurl", "path", "href"):
            k = self.skip_ws(j, hi)  # the URL as written: a % in it is no comment
            a, b, k = (k + 1, _group_end(self.raw, k, hi) - 1, _group_end(self.raw, k, hi)) \
                if self.raw[k:k + 1] == "{" else self.arg(j, hi)
            url = self.raw[a:b].strip()
            start = self.n
            if name == "href":
                a, b, k = self.arg(k, hi)
                self.run(a, b)
            else:
                self.put(self.raw[a:b], a, b)
            self.mark(start, "url", url)
            return k
        if name in CITES or name in REFS:
            notes, j = self.opts(j, hi)
            a, b, k = self.arg(j, hi)
            keys = [s.strip() for s in t[a:b].split(",") if s.strip()]
            text = self.ctx.cite(name, keys, notes) if name in CITES else self.ctx.ref(name, keys)
            start = self.n
            self.put(text, i, k, atomic=True)
            self.mark(start, "cite" if name in CITES else "ref", ",".join(keys))
            return k
        if name in ("ensuremath",):
            a, b, k = self.arg(j, hi)
            self.math(a, b, i, k)
            return k
        if name in SYMBOLS:
            self.put(SYMBOLS[name], i, j, atomic=True)
            return self.skip_ws(j, hi)
        if name in SPACES:
            if name == "item":
                _, j = self.opts(j, hi)
            self.space(i, j)
            return self.skip_ws(j, hi)
        if name in ACCENTS and len(name) == 1:
            return self.accent(i, j, ACCENTS[name], hi)
        if name in HIDDEN:
            return self.skip_ws(j, hi)
        if name in HIDDEN_ARGS:
            for _ in range(HIDDEN_ARGS[name]):
                _, j = self.opts(j, hi)
                if name == "cmidrule" and t.startswith("(", self.skip_ws(j, hi)):
                    j = t.find(")", j, hi) + 1 or hi
                j = self.arg(j, hi)[2]
            return self.opts(j, hi)[1]
        if name == "penalty":
            return re.compile(r"\s*-?\d*").match(t, j, hi).end()
        if name in DIMENS or name + star in DIMENS or "@" in name:  # \\@… are internals (\\@dbltopnum=0)
            return DIMEN.match(t, j, hi).end()
        if name in DEFINES:
            return self.definition(name, j, hi)
        if name == "verb":
            d = self.raw[j:j + 1]
            e = self.raw.find(d, j + 1, hi) if d else -1
            if e < 0:
                return j
            start = self.n
            self.put(self.raw[j + 1:e], j + 1, e)
            self.mark(start, "tt")
            return e + 1
        if name == "ding":
            a, b, k = self.arg(j, hi)
            if t[a:b].strip() in DINGS:
                self.put(DINGS[t[a:b].strip()], i, k, atomic=True)
            else:
                self.chip(i, k)
            return k
        if name == "iffalse":
            f = re.compile(r"\\fi\b").search(t, j, hi)
            return f.end() if f else hi
        # an unknown command keeps the text of its braced arguments; one that prints nothing is a tex chip
        start, k = self.n, j
        while True:
            o = self.opt(k, hi)
            if o:
                k = o[2]
                continue
            q = self.skip_ws(k, hi)
            if q < hi and t[q] == "{":
                a, b, k = self.arg(q, hi)
                self.run(a, b)
                continue
            break
        if self.n == start:
            self.chip(i, k)
            return self.skip_ws(k, hi) if k == j else k
        return k

    def symbol(self, i, ch, j, hi):
        t = self.t
        if ch in ACCENTS:
            return self.accent(i, j, ACCENTS[ch], hi)
        if ch == "\\":
            if j < hi and t[j] == "*":
                j += 1
            o = self.opt(j, hi)
            j = o[2] if o else j
            self.space(i, j)
            return j
        if ch in "%&$#_{}":
            self.put(ch, i, j, atomic=True)
        elif ch.isspace() or ch in ";:>":
            self.space(i, j)
        elif ch == ",":
            self.put("\u2009", i, j, atomic=True)
        elif ch in "([":
            close = t.find("\\)" if ch == "(" else "\\]", j, hi)
            if close < 0:
                return j
            self.math(j, close, i, close + 2)
            return close + 2
        elif ch not in "!-/@)]":
            self.put(ch, i, j, atomic=True)
        return j

    def env(self, i, which, hi):
        t = self.t
        m = (BEGIN if which == "begin" else END).match(t, i)
        if not m:
            return i + len(which) + 1
        if which == "end":
            return m.end()
        name = m.group(1).strip()
        base = name.rstrip("*")
        if base in MATH or base == "math":
            end = _env_end(t, i, name, hi)
            close = t.rfind("\\end", m.end(), end)
            self.math(m.end(), close if close >= 0 else end, i, end)
            return end
        if base in ONE_BLOCK or base == "comment":
            return _env_end(t, i, name, hi)
        _, j = self.opts(m.end(), hi)
        for _ in range(ENV_ARGS.get(base, 0)):
            j = self.arg(j, hi)[2]
        return j

    def definition(self, name, j, hi):
        """The index after a definition in the text (it prints nothing)."""
        t = self.t
        if name == "let":
            j = self.arg(j, hi)[2]
            k = self.skip_ws(j, hi)
            return self.arg(k + (t[k:k + 1] == "="), hi)[2]
        if name == "newif":
            return self.arg(j, hi)[2]
        if name.endswith("def"):
            m = CMD.match(t, self.skip_ws(j, hi))
            j = m.end() if m else j
            while j < hi and t[j] != "{":
                j += 1
            return _group_end(t, j, hi) if j < hi else hi
        if t.startswith("*", j):
            j += 1
        j = self.arg(j, hi)[2]
        _, j = self.opts(j, hi)
        return self.arg(j, hi)[2]

    def macro(self, i, j, d, hi):
        nargs, default, body = d
        args = []
        if default is not None:
            o = self.opt(j, hi)
            args.append(self.t[o[0]:o[1]] if o else default)
            j = o[2] if o else j
        for _ in range(nargs - len(args)):
            a, b, j = self.arg(j, hi)
            args.append(self.t[a:b])
        if self.depth >= MAX_DEPTH or self.ctx.expansions >= MAX_EXPANSIONS:
            self.chip(i, j)
            return j
        self.ctx.expansions += 1
        text = re.sub(r"#(#|[1-9])", lambda m: "#" if m.group(1) == "#" else
                      (args[int(m.group(1)) - 1] if int(m.group(1)) <= len(args) else ""), body)
        sub = _Conv(self.ctx, text, text, self.depth + 1)
        sub.run(0, len(text))
        out, marks, _ = sub.finish()
        start = self.n
        self.put(out, i, j, atomic=True)
        self.marks += [[s + start, e + start] + rest for s, e, *rest in marks]
        if nargs == 0 and not body.rstrip().endswith("\\xspace"):
            return self.skip_ws(j, hi)  # TeX skips the spaces after a control word
        return j


# --- blocks ----------------------------------------------------------------------------------------------------

def _graphic_digest(path):
    """sha1 of what a graphics file draws: for a PDF its pages' content streams and images (a plot saved again
    differs only in its dates and ID), otherwise its bytes."""
    st = os.stat(path)
    return _digest(str(path), st.st_mtime_ns, st.st_size)


@functools.lru_cache(maxsize=256)
def _digest(path, mtime, size):
    h = hashlib.sha1()
    if path.lower().endswith(".pdf"):
        import pymupdf
        try:
            with pymupdf.open(path) as doc:
                for page in doc:
                    h.update(page.read_contents())
                    for img in page.get_images():
                        h.update(doc.xref_stream_raw(img[0]) or b"")
            return h.hexdigest()[:16]
        except Exception:
            pass
    h.update(Path(path).read_bytes())
    return h.hexdigest()[:16]


class _Reader:
    """Reads a round's source in reading order and splits it into blocks (prose.json's, without box, clip and diff
    marks; internal keys start with an underscore)."""

    def __init__(self, src, build, main):
        self.src, self.build, self.main = Path(src), Path(build), main
        self.stem = main[:-4] if main.endswith(".tex") else main
        self.files, self.tokens = {}, {}
        self.blocks, self.para, self.stack = [], None, []
        self.counters, self.appendix, self.floats = [0, 0, 0, 0], False, {"figure": 0, "table": 0, "algorithm": 0}
        self.defs = {}
        self.dirs = []
        self.chapters = False  # whether the source uses \chapter (read)
        self.disk = texdiff.spellings(self.src)  # the files' names as on disk, as texdiff names them (target)

    def path(self, file):
        p = self.src / file
        if file.endswith(".bbl") and not p.is_file():
            return self.build / file
        return p

    def load(self, file):
        """(raw text, text with comments blanked) of a source file, or None."""
        if file not in self.files:
            p = self.path(file)
            raw = p.read_text(encoding="utf-8", errors="replace") if p.is_file() else None
            self.files[file] = (raw, texdiff.blank_comments(raw)) if raw is not None else None
        return self.files[file]

    def target(self, m):
        """The file an \\input-like command reads, relative to src (with .tex added when that file exists; "./" and
        "a/../" resolved, and spelled as on disk, as texdiff names files: \\input{Sections/Intro} reads
        sections/intro.tex)."""
        name = _input_name(m)
        for cand in (name, name + ".tex"):
            if (self.src / cand).is_file():
                return self.disk.get(texdiff.name_key(cand), cand), True
        return (name if name.endswith(".tex") else name + ".tex"), False

    def collect(self, file, seen):
        """Definitions in a file and the files it reads (preamble and body)."""
        if file in seen or self.load(file) is None:
            return
        seen.add(file)
        t = self.load(file)[1]
        _definitions(t, self.defs)
        self.dirs += texdiff._graphics_dirs({file: self.load(file)[0]})
        for m in INPUT.finditer(t):
            name, ok = self.target(m)
            if ok:
                self.collect(name, seen)

    def read(self, ctx_for):
        main = self.load(self.main)
        if main is None:
            raise EngineError("The main file {} is missing.".format(self.main))
        self.collect(self.main, set())
        self.chapters = any(re.search(r"\\chapter(?![A-Za-z@])", f[1]) for f in self.files.values() if f)
        self.ctx = ctx_for(self)
        raw, t = main
        b, e = re.search(r"\\begin\s*\{document\}", t), re.search(r"\\end\s*\{document\}", t)
        lo, hi = (b.end() if b else 0), (e.start() if e else len(t))
        title = re.search(r"\\title\s*(?:\[[^\]]*\])?\s*\{", t)
        if title:
            end = _group_end(t, title.end() - 1, len(t))
            mt = re.search(r"\\maketitle\b", t)
            extra = [(self.main, _line(t, mt.start()), _line(t, mt.start()) + 1)] if mt else []  # the title is
            # set at \\maketitle; synctex gives it that line or the next
            self.emit("title", self.main, title.start(), end, (title.end(), end - 1), _extra=extra)
        self.split(self.main, lo, hi)
        self.close()
        return self.blocks

    # splitting
    def split(self, file, lo, hi):
        raw, t = self.load(file)
        pos = lo
        while pos < hi:
            eol = t.find("\n", pos, hi)
            eol = hi if eol < 0 else eol
            seg = t[pos:eol]
            s = seg.lstrip(" \t")
            ls = pos + len(seg) - len(s)
            if not s.strip():
                if (pos == 0 or t[pos - 1] == "\n") and not raw[pos:eol].strip():
                    self.close()  # a blank line (a line with only a % comment is not one, as in TeX)
                pos = eol + 1
                continue
            pos = self.line(file, raw, t, ls, eol, hi)

    def line(self, file, raw, t, ls, eol, hi):
        """Handle the source at ls (the first character of a line, or after a construct on it); the next position."""
        m = BEGIN.match(t, ls)
        if m:
            name = m.group(1).strip()
            base = name.rstrip("*")
            if base == "document":
                return m.end()
            self.close()
            if base == "comment":
                return _env_end(t, ls, name, hi)
            if base in ONE_BLOCK:
                end = _env_end(t, ls, name, hi)
                self.one_block(file, base, ls, end, m.end())
                return end
            j = m.end()
            while True:
                o = re.match(r"\s*\[", t[j:hi])
                if not o:
                    break
                j = _bracket_end(t, j + o.end() - 1, hi)
            for _ in range(ENV_ARGS.get(base, 0)):
                o = re.match(r"\s*\{", t[j:hi])
                j = _group_end(t, j + o.end() - 1, hi) if o else j
            if base in LISTS:
                self.stack.append({"list": base, "start": ls})
            else:
                self.stack.append({"env": base, "start": ls, "blocks": len(self.blocks), "body": j, "file": file})
            return j
        m = END.match(t, ls)
        if m:
            self.close()
            name = m.group(1).strip().rstrip("*")
            k = next((k for k in range(len(self.stack) - 1, -1, -1)
                      if self.stack[k].get("list", self.stack[k].get("env")) == name), None)
            if k is not None:
                top = self.stack[k]
                del self.stack[k:]
                if "env" in top and top["file"] == file and len(self.blocks) == top["blocks"] and \
                        re.search(r"\\(?:includegraphics|input|include|begin|tikz|fbox|resizebox|scalebox)\b",
                                  t[top["body"]:ls]):
                    self.emit("picture", file, top["start"], m.end(), None)  # a wrapper that prints no text
            return m.end()
        m = re.match(r"\\item\b", t[ls:hi])
        if m:
            self.close()
            j = ls + m.end()
            o = re.match(r"\s*\[", t[j:hi])
            if o:
                j = _bracket_end(t, j + o.end() - 1, hi)
            self.para = {"kind": "item", "file": file, "start": ls, "body": j}
            return self.text_line(file, t, j, eol, hi)
        m = HEADING.match(t, ls)
        if m:
            self.close()
            j = m.end()
            o = re.match(r"\s*\[", t[j:hi])
            if o:
                j = _bracket_end(t, j + o.end() - 1, hi)
            o = re.match(r"\s*\{", t[j:hi])
            if not o:
                return self.text_line(file, t, ls, eol, hi)
            end = _group_end(t, j + o.end() - 1, hi)
            self.heading(file, m.group(1), bool(m.group(2)), ls, end, (j + o.end(), end - 1))
            return end
        if t.startswith("\\[", ls) or t.startswith("$$", ls):
            close = t.find("\\]" if t[ls + 1] == "[" else "$$", ls + 2, hi)
            if close >= 0:
                self.close()
                self.one_block(file, "\\[", ls, close + 2, ls + 2)
                return close + 2
        if re.match(r"\\iffalse\b", t[ls:hi]):
            self.close()
            f = re.compile(r"\\fi\b").search(t, ls, hi)
            return f.end() if f else hi
        m = INPUT.match(t, ls)
        if m:
            self.close()
            name, ok = self.target(m)
            if ok and self.load(name) is not None:
                st = self.load(name)[1]
                lo, end = 0, len(st)
                if m.group(1) == "subfile":
                    b, e = re.search(r"\\begin\s*\{document\}", st), re.search(r"\\end\s*\{document\}", st)
                    lo, end = (b.end() if b else 0), (e.start() if e else end)
                self.split(name, lo, end)
                self.close()
            else:
                self.emit("missing", file, ls, m.end(), None, _text=name)
            return m.end()
        m = REFERENCES.match(t, ls)
        if m:
            self.close()
            self.references(file, ls, m.end())
            return m.end()
        m = re.match(r"\\appendix\b", t[ls:hi])
        if m:
            self.close()
            self.appendix, self.counters = True, [0, 0, 0, 0]
            return ls + m.end()
        end = self.command_line(t, ls, eol)
        if end is not None:
            name = CMD.match(t, ls).group(1)
            if self.para is not None and (name in INLINE or name not in SILENT and "@" not in name):
                # \label, \vspace, …, and a command that may print text (a package's \gls{llm} or \SI{5}{ms}): TeX
                # goes on with the paragraph
                return self.text_line(file, t, ls, eol, hi)
            self.close()
            self.emit("paragraph", file, ls, end, (ls, end))
            return end
        return self.text_line(file, t, ls, eol, hi)

    def command_line(self, t, ls, eol):
        """The end of a line that holds one command that prints no text (\\label, \\vspace, \\maketitle, a
        definition, an unknown command) and its arguments, else None."""
        m = CMD.match(t, ls)
        if not m or not m.group(1):
            return None
        name = m.group(1)
        if name in STYLES or name in NOTES or name in PLAIN or name in CITES or name in REFS or name in SYMBOLS \
                or name in self.defs or name in DECLS or name in ACCENTS \
                or name in ("url", "href", "nolinkurl", "path", "verb", "ding", "ensuremath", "item"):
            return None
        j = m.end()
        while j < eol:
            k = j
            while k < eol and t[k] in " \t":
                k += 1
            if k < eol and t[k] in "[{":
                j = _bracket_end(t, k, eol) if t[k] == "[" else _group_end(t, k, eol)
            else:
                break
        return j if not t[j:eol].strip() else None

    def text_line(self, file, t, ls, eol, hi):
        """Add the text from ls to the line's end to the paragraph (starting one). An environment or display opened
        on the line and not closed on it runs on: the paragraph takes it whole. An \\end on the line that closes an
        environment opened before it (`…text.\\end{abstract}`) ends the paragraph: the next position is the \\end."""
        if self.para is None:
            self.para = {"kind": "paragraph", "file": file, "start": ls, "body": ls}
        q = self.closing(t, ls, eol)
        if q is not None:
            if t[ls:q].strip():
                self.para["end"] = ls + len(t[ls:q].rstrip())
            return q
        end, j = eol, ls
        while True:
            stack = []
            for m in ENV_TOKEN.finditer(t, j, end):
                if m.group(0) == "\\\\" or m.group(1):
                    continue
                key = "\\[" if m.group(0) in ("\\[", "\\]") else m.group(3)
                if m.group(2) == "begin" or m.group(0) == "\\[":
                    stack.append((key, m.start()))
                elif stack and stack[-1][0] == key:
                    stack.pop()
            if not stack:
                break
            key, at = stack[0]
            close = (t.find("\\]", at, hi) + 2 if key == "\\[" else _env_end(t, at, key, hi)) if key else hi
            if close <= 1 or close >= hi:
                break
            j = close
            nl = t.find("\n", close, hi)
            end = hi if nl < 0 else nl
        self.para["end"] = ls + len(t[ls:end].rstrip()) if t[ls:end].strip() else self.para.get("end", ls)
        return end + 1

    def closing(self, t, ls, eol):
        """The offset of an \\end in t[ls:eol] closing an environment or list opened before the line, or None."""
        names = {x.get("list", x.get("env")) for x in self.stack}
        for m in END.finditer(t, ls, eol):
            name = m.group(1).strip().rstrip("*")
            if name in names and not re.search(r"\\begin\s*\{%s\*?\}" % re.escape(name), t[ls:m.start()]):
                return m.start()
        return None

    def close(self):
        p, self.para = self.para, None
        if p is None or "end" not in p:
            return
        self.emit(p["kind"], p["file"], p["start"], p["end"], (p["body"], p["end"]))

    def heading(self, file, command, starred, start, end, body):
        level = HEADINGS[command] + (self.chapters and command not in ("part", "chapter"))
        number = None
        if not starred and command != "part" and level <= 3:  # sections within their chapter: 1.1
            self.counters[level - 1] += 1
            for k in range(level, 4):
                self.counters[k] = 0
            first = chr(64 + self.counters[0]) if self.appendix and self.counters[0] <= 26 else str(self.counters[0])
            number = ".".join([first] + [str(c) for c in self.counters[1:level]])
        t = self.load(file)[1]
        nxt = _line(t, end) + 1  # a run-in \\paragraph heading is set with the line after it
        self.emit("heading", file, start, end, body, level=level, number=number,
                  _extra=[(file, nxt, nxt)] if command == "paragraph" else ())

    def references(self, file, start, end):
        """A References heading and one bibitem block per \\bibitem of the .bbl that TeX read."""
        bbl = self.stem + ".bbl"
        loaded = self.load(bbl)
        self.emit("heading", file, start, end, None, level=1, _text="References", _hash=False)
        if loaded is None or "\\bibitem" not in loaded[1]:
            return
        _definitions(loaded[1], self.defs)
        self.bibitems(bbl, 0, len(loaded[1]))

    def bibitems(self, file, lo, hi):
        raw, t = self.load(file)
        marks = [m.start() for m in re.finditer(r"\\bibitem\b|\\end\s*\{thebibliography\}", t[:hi]) if m.start() >= lo]
        for a, b in zip(marks, marks[1:] + [hi]):
            if not t.startswith("\\bibitem", a):
                continue
            j = a + len("\\bibitem")
            o = re.match(r"\s*\[", t[j:b])
            if o:
                j = _bracket_end(t, j + o.end() - 1, b)
            o = re.match(r"\s*\{", t[j:b])
            if o:
                j = _group_end(t, j + o.end() - 1, b)
            s, e = texdiff.trim(raw, a, b)  # as written: BibTeX copies a URL's % (no comment in \\url)
            self.emit("bibitem", file, s, e, (j, e))

    def one_block(self, file, base, start, end, body):
        t = self.load(file)[1]
        raw = self.load(file)[0]
        if base == "thebibliography":
            self.emit("heading", file, start, body, None, level=1, _text="References", _hash=False)
            self.bibitems(file, start, end)
            return
        inner = (body, t.rfind("\\end", body, end) if t.rfind("\\end", body, end) >= 0 else end)
        includes = []
        for m in INPUT.finditer(t, start, end):
            name, ok = self.target(m)
            if ok and self.load(name) is not None:
                includes.append(name)
        extra = [(f, 1, self.load(f)[1].count("\n") + 1) for f in includes]
        if base in MATH or base == "\\[":
            tex = " ".join(LABEL.sub("", t[body:end - 2] if base == "\\[" else t[inner[0]:inner[1]]).split())
            env = KATEX.get(base)
            if env:
                tex = "\\begin{%s}%s\\end{%s}" % (env, tex, env)
            self.emit("math", file, start, end, None, _text=tex, _extra=extra)
            return
        if base in CODE:
            o = re.match(r"\s*\[[^\]]*\]", t[body:end])
            s = body + (o.end() if o else 0)
            if base == "minted":
                o = re.match(r"\s*\{[^{}]*\}", t[s:end])
                s += o.end() if o else 0
            s, e = texdiff.trim(raw, s, inner[1])
            self.emit("code", file, start, end, None, _text=raw[s:e], _code=(s, e))  # text as written
            return
        kind = "figure" if base in FIGURES else "table" if base in TABLES or base in TABULARS else \
            "code" if base in ALGORITHMS else "picture"
        cap = comments.caption_span(raw, start, end) if kind != "picture" else None
        prefix = None
        if cap:
            counter = "figure" if kind == "figure" else "table" if kind == "table" else "algorithm"
            self.floats[counter] += 1
            label = comments.env_label(raw, start, end)
            num = self.ctx.plain(self.ctx.labels[label][0]) if label in self.ctx.labels else str(self.floats[counter])
            name = {"figure": "Figure", "table": "Table"}.get(kind, "Algorithm")
            cmd = t.rfind("\\caption", start, cap[0])
            prefix = ("{} {}: ".format(name, num), cmd, cmd + len("\\caption"))
        b = self.emit(kind, file, start, end, cap, _prefix=prefix, _extra=extra)
        if b is not None:
            b["_narrow"] = kind in ("figure", "table") and not BEGIN.match(t, start).group(1).strip().endswith("*")
            if cap:
                b["_caption"] = (file, _line(t, prefix[1]), _line(t, cap[1]))

    def emit(self, kind, file, start, end, body, _text=None, _prefix=None, _extra=(), _hash=True, _code=None,
             **extra):
        raw, t = self.load(file)
        self.ctx.expansions = 0
        if _code is not None:
            text, marks, cmap = _text, [], [[0, len(_text), _code[0], _code[1] - _code[0]]] if _text else []
        elif _text is not None:
            text, marks = _text, []
            cmap = [[0, len(text), start, end - start] + ([1] if len(text) == end - start else [])] if text else []
        else:
            conv = _Conv(self.ctx, t, raw)
            if _prefix:
                conv.put(_prefix[0], _prefix[1], _prefix[2], atomic=True)
            if body:
                conv.run(*body)
            text, marks, cmap = conv.finish()
        if not text and kind in READABLE:
            return None
        lines = [_line(t, start), _line(t, max(start, end - 1))]
        block = {"kind": kind, "file": file, "start": start, "end": end, "lines": lines,
                 "hash": self.hash(kind, file, start, end, _extra) if _hash and kind != "missing" else None,
                 "section": None, "level": extra.pop("level", None), "number": extra.pop("number", None),
                 "text": text, "marks": marks, "map": cmap, "box": None, "clip": None,
                 "ins": [], "del": [], "added": None, "moved": None, "before": None}
        block.update(extra)
        inputs = [f for f, _, _ in _extra if f != file]
        if inputs:  # the files a float or formula \inputs (a tabular, a tikz picture): their comments are in it
            block["inputs"] = inputs
        block["_ranges"] = [(file, lines[0], lines[1])] + list(_extra)
        self.blocks.append(block)
        return block

    def hash(self, kind, file, start, end, extra):
        """sha1 (16 hex digits) of the kind and the texdiff tokens of the block (and of files it \\inputs), and the
        digests of the graphics files it includes."""
        def toks(f, a, b):
            if f not in self.tokens:
                tk = texdiff.Tokens(self.load(f)[0])
                self.tokens[f] = tk, _unprinted(tk.texts)
            tk, skip = self.tokens[f]
            i1, i2 = bisect.bisect_left(tk.starts, a), bisect.bisect_right(tk.ends, b)
            return [x for i, x in enumerate(tk.texts[i1:i2], i1) if x != texdiff.PAR and i not in skip]
        parts = [kind] + toks(file, start, end)
        for f, _, _ in extra:
            if f != file:
                parts += toks(f, 0, len(self.load(f)[0]))
        for f, a, b in [(file, start, end)] + [(f, 0, None) for f, _, _ in extra if f != file]:
            for m in texdiff.GRAPHICS.finditer(self.load(f)[1], a, b if b is not None else len(self.load(f)[1])):
                g = texdiff._graphic(self.src, m.group(1), self.dirs)
                if g is not None:
                    parts.append(_graphic_digest(g))
        return hashlib.sha1(" ".join(parts).encode("utf-8")).hexdigest()[:16]


def _unprinted(texts):
    """Indexes of the tokens of commands that print nothing (UNPRINTED, with their [options] and {argument}): left out
    of the hash, so moving `\\noindent` or a `\\label` onto or off a text line keeps it."""
    skip, i = set(), 0
    while i < len(texts):
        if texts[i].rstrip("*")[1:] in UNPRINTED and texts[i][0] == "\\":
            j = i + 1
            for close in ("[]", "{}") if texts[i].rstrip("*")[1:] in HIDDEN_ARGS else ():
                if j < len(texts) and texts[j] == close[0]:
                    depth = 0
                    while j < len(texts):
                        depth += (texts[j] == close[0]) - (texts[j] == close[1])
                        j += 1
                        if depth == 0:
                            break
            skip.update(range(i, j))
            i = j
        else:
            i += 1
    return skip


def _line(t, offset):
    return bisect.bisect_left(_newlines(t), offset) + 1


@functools.lru_cache(maxsize=16)
def _newlines(t):
    """The offsets of the newlines in t (_line: a file's lines found by bisection, not counted for each block)."""
    return [m.start() for m in re.finditer("\n", t)]


def _context(reader):
    """The conversion context of a reader: its definitions, the build's .aux, and the citation style (natbib
    author-year unless loaded with the numbers option)."""
    aux = _aux(reader.build, reader.stem)
    texts = " ".join(f[1] for f in reader.files.values() if f)
    for p in reader.src.glob("*.sty"):
        texts += p.read_text(encoding="utf-8", errors="replace")
    numbers = re.search(r"\\(?:usepackage|RequirePackage)\s*\[[^\]]*numbers[^\]]*\]\s*\{natbib\}|"
                        r"\\setcitestyle\s*\{[^}]*numbers", texts)
    authoryear = any(v[1] is not None for v in aux[0].values()) and not numbers
    return _Ctx(reader.defs, aux, authoryear)


# --- places in the PDF -----------------------------------------------------------------------------------------

def _places(blocks, pdf, columns=None, text_x=None):
    """Each block's parts ([[page, rect]]: where it is read in the PDF, one rect per column it is set in; _parts) and,
    for figures, tables, formulas, listings and pictures, its box ([page, rect]: the union of the synctex boxes of its
    lines on the page holding most of them; its one part) and clip ([page, rect], as card image clips)."""
    boxes = anchor.line_boxes(pdf)
    founds, claims = [], {}  # claims: (page, rect) -> the blocks whose lines hold that box
    for k, b in enumerate(blocks):
        found = [(p, (f, line), r) for f, l1, l2 in b["_ranges"] for line in range(l1, l2 + 1)
                 for p, r in boxes.get((f, line), ()) if r[0] > 0 and r[1] > 0]
        founds.append(found)
        for p, _, r in found:
            claims.setdefault((p, r), set()).add(k)
    doc = anchor._doc(anchor._stamp(pdf))
    running = _running(founds, [page.rect.height for page in doc])
    tails = _tails(blocks, founds, claims, boxes, running, pdf, text_x)
    given = {(p, r) for tail in tails.values() for p, _, r in tail}
    for k, (b, found) in enumerate(zip(blocks, founds)):
        b["parts"] = []
        if b["kind"] not in IMAGE_KINDS and b["kind"] != "title":
            # synctex gives the line TeX reads at a shipout the page's running head and foot and, in two columns,
            # the boxes of the columns; a margin ruler's numbers are outside the text; a last line given to a later
            # line is its own block's (_tails)
            text = [f for f in found if (f[0], f[2]) not in running and f[2][3] - f[2][1] <= TALL
                    and _in_text(f, text_x) and (f[0], f[2]) not in given]
            if b["kind"] == "heading":  # a paragraph ended by the heading's \par gives the heading's line its lines
                text = [f for f in text if claims[(f[0], f[2])] == {k}] or text
            elif b["kind"] in ("item", "bibitem"):
                # TeX ends the item before (or the paragraph leading into the list) while it reads this one's \item
                # line, so synctex gives that line the earlier block's last lines
                text = [f for f in text if min(claims[(f[0], f[2])]) == k] or text
            elif b["kind"] == "paragraph":
                # and TeX ships a page out while it reads a line, so synctex gives that line the boxes of the page's
                # earlier blocks, such as a float's cells (a heading on the paragraph's first line keeps that line)
                text = [f for f in text if min((j for j in claims[(f[0], f[2])] if blocks[j]["kind"] != "heading"),
                                               default=k) == k] or text
            keep, score = _own_text(b, pdf, text_x)
            b["parts"] = _parts(keep(text) + tails.get(k, []), columns, score)
        if b["kind"] not in IMAGE_KINDS:
            continue
        if b["kind"] == "math":
            found = _display_boxes(k, found, claims, columns, text_x)
        if not found:
            continue
        narrow = b.get("_narrow")  # a float one column wide: it does not go on in the other column
        run = _cluster(found, across=not narrow)
        page = run[0][0]
        gap = (columns[page] or [None])[0] if narrow and columns and page < len(columns) else None
        if gap is not None:
            run = _one_column(run, gap)
        run = _scaled(run)
        rects = [r for _, _, r in run]
        box = [min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects)]
        b["box"] = [page, [round(v, 2) for v in box]]
        cap = b.get("_caption")  # the caption follows as text, so its lines are left out of the crop
        body = [r for _, (f, line), r in run if not (cap and f == cap[0] and cap[1] <= line <= cap[2])]
        b["clip"] = [page, cards.block_clip(pdf, page, body or rects, columns)]
        b["parts"] = [b["box"]]  # a float, formula or listing is read where its box is


def _tails(blocks, founds, claims, boxes, running, pdf, text_x):
    """The last lines of text blocks that synctex gives to a later source line, {block: [(page, line, rect)]}. A last
    line holding a single word has no glue or kern of the paragraph's own lines, only the \\parfillskip of the \\par
    that a later line ends it with (the blank line after it, \\end{itemize}, the next \\item), so its box is that
    line's, and the block's bar was a line short. Such a box is one of the lines after the block's last one, up to the
    first line a block holds: not held by the block or an earlier one, a line high, in the text, directly below one of
    the block's boxes (at most TAIL_GAP points lower, overlapping it across), and holding the last letters of the
    block's text (the PDF words inside it, comments._fold)."""
    held = {(f, line) for b in blocks for f, l1, l2 in b["_ranges"] for line in range(l1, l2 + 1)}
    out, taken, stamp = {}, set(), anchor._stamp(pdf)
    for k, (b, found) in enumerate(zip(blocks, founds)):
        if b["kind"] not in ("paragraph", "item", "bibitem") or not b["_ranges"]:
            continue
        own = [(p, r) for p, _, r in found if (p, r) not in running and r[3] - r[1] <= TALL
               and _in_text((p, None, r), text_x)]
        if not own:
            continue
        f, _, last = b["_ranges"][0]
        letters = None
        for line in range(last + 1, last + 4):
            for p, r in boxes.get((f, line), ()):
                if (p, r) in taken or any(j <= k for j in claims.get((p, r), ())) or r[0] <= 0 or r[1] <= 0 \
                        or r[3] - r[1] > LINE or not _in_text((p, None, r), text_x) \
                        or not any(q == p and o[0] < r[2] and r[0] < o[2] and -1 <= r[1] - o[3] <= TAIL_GAP
                                   for q, o in own):
                    continue
                inside = "".join(w[4] for w in anchor._words(stamp, p)
                                 if r[0] - 1 <= (w[0] + w[2]) / 2 <= r[2] + 1 and r[1] - 1 <= (w[1] + w[3]) / 2 <= r[3] + 1)
                got = comments._fold(inside)
                letters = comments._fold(b["text"]) if letters is None else letters
                if got and letters.endswith(got):
                    out.setdefault(k, []).append((p, (f, line), r))
                    taken.add((p, r))
            if (f, line) in held:
                break
    return out


def _running(founds, heights):
    """The boxes of running heads and feet, {(page, rect)}: synctex gives them the line TeX is reading when it ships
    the page out, which can be a line of any block. Such a box is at most a line high, in the top or bottom eighth of
    its page, at least HEAD_GAP points from the page's other lines there, and in the same place on another page."""
    lines = {}
    for found in founds:
        for p, _, r in found:
            if r[3] - r[1] <= LINE:
                lines.setdefault(p, set()).add(r)
    seen = {}
    for p, rs in lines.items():
        h = heights[p] if p < len(heights) else 0
        for r in rs:
            if h / 8 < r[1] and r[3] < h * 7 / 8:
                continue
            if any(o != r and o[1] < r[3] + HEAD_GAP and r[1] < o[3] + HEAD_GAP and o[0] < r[2] and r[0] < o[2]
                   for o in rs):
                continue
            seen.setdefault(tuple(round(v) for v in r), set()).add((p, r))
    return {x for found in seen.values() if len({p for p, _ in found}) > 1 for x in found}


@functools.lru_cache(maxsize=64)
def _page_letters(stamp, page):
    """(centre heights, [(reading order, centre x, folded text)] in the same order) of a page's words, by height
    (anchor._words, so without margin line numbers)."""
    ws = sorted(((w[1] + w[3]) / 2, k, (w[0] + w[2]) / 2, comments._fold(w[4]))
                for k, w in enumerate(anchor._words(stamp, page)))
    return [w[0] for w in ws], [(w[1], w[2], w[3]) for w in ws]


def _own_text(b, pdf, text_x=None):
    """(keep, score) for text block b: keep(found) is the block's boxes ((page, line, rect) list) that print its text,
    and score(run) is 2 for a run of them ((page, rect) list) that holds the block's own text, 1 for one that holds
    only its footnotes'.

    synctex gives the line TeX reads when it ships a page out the boxes the output routine sets: the page's foot and
    head (taller than a line under fancyhdr), the last footnote lines, the cells of a float, a proof's end mark,
    lineno's numbers and acmart's whole title block. Such a box is no part of the block (it gave a stray or page-high
    bar). A box prints the block's text when at least OWN_SHARE of its letters and digits (of the words in it, in
    the PDF's order) lie in pieces of OWN_GRAM or more of the block's text, or when it ends with the block's first
    OWN_LETTERS or more (a line that starts with a run-in heading) or starts with its last ones. A box with fewer than
    OWN_LETTERS (a word or two, such as a table's cell that names the method a paragraph is about, or a list item's
    label) is kept when it is the line directly above or below one that does (a last line of a short word or two),
    or level with one and inside the page's text (text_x; not lineno's numbers), else dropped. When no box prints
    the block's text, all are kept. A footnote longer than its paragraph is not where the paragraph is read: a run
    holds the block's own text when OWN_BODY of its letters lie in pieces of the text outside footnotes."""
    text = b.get("text") or ""
    notes = sorted((m[0], m[1]) for m in b.get("marks") or () if m[2] == "fn")
    body, at = "", 0
    for s, e in notes:
        body += text[at:s] + " "
        at = max(at, e)
    body += text[at:]

    def grams(t):
        t = comments._fold(t)
        return {t[i:i + OWN_GRAM] for i in range(len(t) - OWN_GRAM + 1)}
    every, own_text = grams(text), grams(body)
    whole = comments._fold(text)
    stamp = anchor._stamp(pdf)

    def letters(page, rs):  # of the words whose centres lie in rects rs, in reading order
        ys, ws = _page_letters(stamp, page)
        out = set()
        for r in rs:
            out.update(k for k in range(bisect.bisect_left(ys, r[1] - 1), bisect.bisect_right(ys, r[3] + 1))
                       if r[0] - 1 <= ws[k][1] <= r[2] + 1)
        return "".join(ws[k][2] for k in sorted(out, key=lambda k: ws[k][0]))

    def share(t, pieces):  # of the letters of t, the share in pieces of OWN_GRAM of the block's text
        covered = [False] * len(t)
        for i in range(len(t) - OWN_GRAM + 1):
            if t[i:i + OWN_GRAM] in pieces:
                covered[i:i + OWN_GRAM] = [True] * OWN_GRAM
        return sum(covered) / len(t) if t else 0.0

    def edges(t):  # the box ends with the block's first letters, or starts with its last ones
        n = min(len(t), len(whole))
        return any(t.endswith(whole[:k]) or t.startswith(whole[-k:]) for k in range(n, OWN_LETTERS - 1, -1))

    def keep(found):
        kinds = []
        for f in found:
            t = letters(f[0], [f[2]])
            kinds.append("short" if len(t) < OWN_LETTERS else
                         "own" if share(t, every) >= OWN_SHARE or edges(t) else "foreign")
        own = [f for f, k in zip(found, kinds) if k == "own"]
        if not own:
            return found

        def next_to(f):  # directly above or below a box that prints the block's text, across it, or level with one
            r = f[2]
            tx = text_x[f[0]] if text_x and f[0] < len(text_x) else None
            inside = not tx or tx[0] - 1 <= r[0] and r[2] <= tx[1] + 1
            gap = LINE  # the next line
            return any(g[0] == f[0] and g[2][0] < r[2] and r[0] < g[2][2] and
                       (-1 <= r[1] - g[2][3] <= gap or -1 <= g[2][1] - r[3] <= gap) or
                       g[0] == f[0] and inside and min(r[3], g[2][3]) - max(r[1], g[2][1]) > (r[3] - r[1]) / 2
                       for g in own)
        return [f for f, k in zip(found, kinds) if k == "own" or k == "short" and next_to(f)]

    def score(run):
        t = "".join(letters(page, [r for p, r in run if p == page]) for page in sorted({p for p, _ in run}))
        return 2 if share(t, own_text) >= OWN_BODY else 1
    return keep, score


def _parts(found, columns, own=None):
    """Where a text block is read in the PDF: [[page, rect]] in reading order, one rect per column it is set in. Its
    boxes are grouped by page and column and cut into runs down the column (gaps of at most CLUSTER points); the run
    holding most of its lines (then most boxes), and of the runs in the column before and after it in reading order
    (the page's other column, or the page before or after) the one that continues it: its lines start no later
    (end no earlier) than the main run's, and of those the one on the same page, then with the most lines, then
    nearest the break. So a paragraph across a column or page break has a part in each, and a footnote or a stray
    box elsewhere on the page has none (running heads and feet are left out before: _running, and boxes that print
    another block's text: _own_text). With several runs, the main one is one that `own` (_own_text's score) finds to
    hold the block's own text rather than only its footnotes, if any does."""
    def side(p, r):
        gap = (columns[p] or [None])[0] if columns and p < len(columns) and columns[p] else None
        return 1 if gap is not None and r[0] >= gap - 3 else 0  # 0: the left column (or across both), or one column
    groups = {}
    for f in found:
        groups.setdefault((f[0], side(f[0], f[2])), []).append(f)
    runs = []
    for key in sorted(groups):
        bottom = None
        for f in sorted(groups[key], key=lambda f: f[2][1]):
            if bottom is not None and f[2][1] - bottom <= CLUSTER:
                runs[-1][1].append(f)
                bottom = max(bottom, f[2][3])
            else:
                runs.append((key, [f]))
                bottom = f[2][3]
    if not runs:
        return []
    score = {id(run): own([(p, r) for p, _, r in run[1]]) for run in runs} if own and len(runs) > 1 else {}

    def weight(run):
        return len({ln for _, ln, _ in run[1]}), len(run[1])
    best = max(runs, key=lambda run: (score.get(id(run), 0),) + weight(run))  # its text before its footnotes
    (page, col), lines = best[0], [ln for _, ln, _ in best[1]]
    kept = [best]
    for before in (True, False):
        def near(key):  # the column before (after) the main run's: the page's other one, or on the page before (after)
            return key[0] == page and key[1] == (col - 1 if before else col + 1) or \
                key[0] == (page - 1 if before else page + 1)
        cands = [run for run in runs if run is not best and near(run[0]) and
                 (min(ln for _, ln, _ in run[1]) <= min(lines) if before else
                  max(ln for _, ln, _ in run[1]) >= max(lines))]
        if cands:  # the nearest column, then its own text (not its footnotes), the most lines, nearest the break
            kept.append(max(cands, key=lambda run: (run[0][0] == page, score.get(id(run), 0), weight(run),
                                                    run[1][-1][2][3] if before else -run[1][0][2][1])))
    out = []
    for key, run in sorted(kept, key=lambda run: (run[0], run[1][0][2][1])):
        rs = [r for _, _, r in run]
        out.append([key[0], [round(min(r[0] for r in rs), 2), round(min(r[1] for r in rs), 2),
                             round(max(r[2] for r in rs), 2), round(max(r[3] for r in rs), 2)]])
    return out


def _in_text(f, text_x):
    """Whether box f ((page, line, rect)) reaches into its page's text (text_x): a margin ruler's numbers do not."""
    tx = text_x[f[0]] if text_x and f[0] < len(text_x) else None
    return not tx or (f[2][0] < tx[1] - 1 and f[2][2] > tx[0] + 1)


def _display_boxes(k, found, claims, columns, text_x):
    """The boxes of display formula k's own lines. synctex gives the lines of the paragraph leading into a display
    (broken when the display starts) the display's first line, a margin ruler's numbers the line being read, and a
    page shipped out while the display is read that page's boxes. So boxes another block's lines hold and boxes
    outside the page's text are left out, and the formula is the first of the rest after the lead-in's last line."""
    def order(f):  # page, then column, then height down the page
        gap = (columns[f[0]] or [None])[0] if columns and f[0] < len(columns) else None
        return f[0], gap is not None and f[2][0] >= gap

    own = [f for f in found if claims[(f[0], f[2])] == {k} and _in_text(f, text_x)]
    lead = [f for f in found if any(j < k for j in claims[(f[0], f[2])])]
    if lead and own:
        last = max(lead, key=lambda f: order(f) + (f[2][3],))
        after = [f for f in own if order(f) > order(last) or (order(f) == order(last) and f[2][1] >= last[2][3] - 2)]
        if after:
            page = min(f[0] for f in after)
            return [f for f in after if f[0] == page]
    return own or found


def _scaled(run):
    """The boxes without those synctex gives an included picture at its natural size: larger than the box of the
    picture as scaled on the same line, with the same left and bottom edges. They can reach into the other column or
    off the page."""
    def natural(ln, r):
        return any(l2 == ln and abs(o[0] - r[0]) < 0.5 and abs(o[3] - r[3]) < 0.5
                   and (o[2] < r[2] - 1 or o[1] > r[1] + 1) for _, l2, o in run)
    return [f for f in run if not natural(f[1], f[2])] or run


def _one_column(run, gap):
    """The boxes of a float one column wide on a two-column page, cut to the column most of them start in: synctex
    gives an included picture a box at its natural size, which can reach into the other column or off the page."""
    left = 2 * sum(r[0] < gap for _, _, r in run) >= len(run)
    kept = [(p, ln, [r[0], r[1], min(r[2], gap), r[3]] if left else [max(r[0], gap), r[1], r[2], r[3]])
            for p, ln, r in run if (r[0] < gap if left else r[2] > gap)]
    return kept or run


def _cluster(found, across=True):
    """Of a block's boxes [(page, line, rect)], the run of boxes following each other down a page (gaps of at most
    CLUSTER points) that holds most of its lines (then most boxes), with (when `across`) the runs on that page in
    another column (a paragraph continued at the top of the next column). TeX gives the line it is reading when a
    page is shipped out to that page's running head and foot, which may be on another page or far from the block."""
    runs = []
    for page in sorted({f[0] for f in found}):
        bottom = None
        for f in sorted((f for f in found if f[0] == page), key=lambda f: f[2][1]):
            if bottom is not None and runs[-1][0][0] == page and f[2][1] - bottom <= CLUSTER:
                runs[-1].append(f)
                bottom = max(bottom, f[2][3])
            else:
                runs.append([f])
                bottom = f[2][3]

    def weight(run):
        return len({ln for _, ln, _ in run}), len(run)

    def other(a, b):  # x extents overlapping by less than half the narrower one: another column
        a0, a1 = min(f[2][0] for f in a), max(f[2][2] for f in a)
        b0, b1 = min(f[2][0] for f in b), max(f[2][2] for f in b)
        return min(a1, b1) - max(a0, b0) < 0.5 * min(a1 - a0, b1 - b0)
    best = max(runs, key=weight)
    return best + [f for run in runs if run is not best and run[0][0] == best[0][0] and other(run, best)
                   for f in run] if across else best


# --- diff marks ------------------------------------------------------------------------------------------------

def _display(b, a, z):
    """Display spans [[d0, d1]] of the source range [a, z) of block b (an atomic entry it touches whole)."""
    spans = []
    for d, n, s, m, *at in b["map"]:
        if s + m <= a or s >= z:
            continue
        if n == m and not at:
            d0, d1 = d + max(a - s, 0), d + min(z, s + m) - s
        else:
            d0, d1 = d, d + n
        if spans and d0 <= spans[-1][1]:
            spans[-1][1] = max(spans[-1][1], d1)
        else:
            spans.append([d0, d1])
    out = []
    for d0, d1 in spans:  # no spaces at a span's edges
        while d0 < d1 and b["text"][d0].isspace():
            d0 += 1
        while d1 > d0 and b["text"][d1 - 1].isspace():
            d1 -= 1
        if d1 > d0:
            out.append([d0, d1])
    return out


def _point(b, p):
    """The display offset of the source offset p in block b."""
    best = 0
    for d, n, s, m, *at in b["map"]:
        if s > p:
            break
        if p >= s + m:
            best = d + n
        elif n == m and not at:
            return d + p - s
        else:
            return d if p == s else d + n
    return best


def _inside(b, a, z):
    return a <= b["start"] and b["end"] <= z


def _covers(b, a, z):
    """Whether the source range [a, z) holds every letter and digit of block b's text: a moved paragraph whose
    move leaves out only its formatting or its final period."""
    left = list(b["text"])
    spans = _display(b, a, z)
    for d0, d1 in spans:
        left[d0:d1] = " " * (d1 - d0)
    return bool(spans) and not any(ch.isalnum() for ch in left)


def _overlapping(by_file, f, a, z):
    return [b for b in by_file.get(f, ()) if b["start"] < z and a < b["end"]]


def _marks_in(b, d0, d1):
    return [[max(s, d0) - d0, min(e, d1) - d0] + rest for s, e, *rest in b["marks"] if s < d1 and e > d0]


def _diff_marks(blocks, old_blocks, diff, ids, n):
    """Mark the round's changes on its blocks (ins, del, added, moved, before) and return (the blocks with the
    previous round's deleted blocks in place, {change id: the blocks it touches})."""
    new_by, old_by = {}, {}
    for b in blocks:
        new_by.setdefault(b["file"], []).append(b)
    old = [b for b in old_blocks if b["kind"] not in ("deleted", "missing")]
    for b in old:
        old_by.setdefault(b["file"], []).append(b)
    touched, deleted = {}, []
    for h, cid in zip(diff.hunks, ids):
        hit = touched.setdefault(cid, []) if cid else []
        nf, ns, ne, of, os_, oe = h["new_file"], h["new_start"], h["new_end"], h["old_file"], h["old_start"], \
            h["old_end"]
        if h.get("figure"):
            for b in _overlapping(new_by, nf, ns, max(ne, ns + 1)):
                hit.append(b)
                _before(b, old_by, of, os_, oe)
            continue
        nb = _overlapping(new_by, nf, ns, ne) if nf and ne > ns else []
        ob = _overlapping(old_by, of, os_, oe) if of and oe > os_ else []
        if h["kind"] == "move":
            gap = _break_only(diff, h)
            if gap:  # a paragraph split or joined: the blocks at the break, unmarked
                hit += nb + _touching(new_by, nf, *gap)
                continue
            for b in nb:
                if _inside(b, ns, ne) or _covers(b, ns, ne):
                    b["moved"] = cid
                else:
                    b["ins"] += [[s, e, cid] for s, e in _display(b, ns, ne)]
                hit.append(b)
            for o in ob:
                if not (_inside(o, os_, oe) or _covers(o, os_, oe)):
                    hit += _del(o, os_, oe, diff, h, new_by, cid, moved=cid)
            continue
        hits = len(hit)
        if nf and ne == ns:  # a deletion inside a figure, table, formula or listing (a table row): its old crop
            for b in _overlapping(new_by, nf, ns, ns + 1):
                if b["kind"] in IMAGE_KINDS:
                    hit.append(b)
                    _before(b, old_by, of, os_, oe)
        whole_old = [o for o in ob if _inside(o, os_, oe)]
        part_old = [o for o in ob if o not in whole_old]
        for name in _inputs_of(diff.old_texts, of, os_, oe, h.get("old_text")):  # a removed \input: the blocks of
            name = next((f for f in (name, name + ".tex") if f in old_by), None)  # the file it read
            if name and name not in new_by and name not in diff.renamed:
                whole_old += old_by[name]
        for name in _inputs_of(diff.new_texts, nf, ns, ne, h.get("new_text")) + \
                (texdiff.hidden_reads(diff.old_texts, of, os_, oe) if of else []):  # an added \input (or one TeX
            name = next((f for f in (name, name + ".tex") if f in new_by), None)  # skipped before): its blocks, added
            if name and name not in old_by and name not in diff.renamed.values():
                for b in new_by[name]:  # new text here, though a block may read as one read before (restored)
                    b["added"] = b["added"] or cid
                    hit.append(b)
        part_new = [b for b in nb if not _inside(b, ns, ne)]
        for b in nb:
            if b not in part_new:
                b["added"] = cid
            hit.append(b)
            if b["kind"] in IMAGE_KINDS:
                _before(b, old_by, of, os_, oe)
        for o in whole_old:
            deleted.append((o, h, cid))
        if h["kind"] == "replace" and len(part_old) == 1 and len(part_new) == 1:
            _refine(part_old[0], part_new[0], (os_, oe), (ns, ne), cid)
        else:
            for b in part_new:
                b["ins"] += [[s, e, cid] for s, e in _display(b, ns, ne)]
            for o in part_old:
                hit += _del(o, os_, oe, diff, h, new_by, cid)
        if len(hit) == hits and nf and not whole_old:  # a paragraph break or a hidden command between blocks
            hit += _touching(new_by, nf, ns, ne)
    out = _place_deleted(blocks, old, deleted, new_by, n, touched)
    index = {id(b): k for k, b in enumerate(out)}
    changes = {cid: sorted({index[id(b)] for b in bs if id(b) in index}) for cid, bs in touched.items() if cid}
    for b in out:
        b["ins"].sort()
        b["del"].sort(key=lambda d: d[0])
    return out, {cid: ks for cid, ks in changes.items() if ks}


def _input_name(m):
    """The file name an INPUT match reads, "./" and "a/../" resolved."""
    name = (m.group(2) if m.group(2) is not None else m.group(5) if m.group(5) is not None else
            m.group(3).rstrip("/") + "/" + m.group(4)).strip()
    return posixpath.normpath(name) if name else name


def _inputs_of(texts, f, s, e, text):
    """The names of the files that the \\input-like commands in a hunk's side read: those in its text, and the whole
    commands its range [s, e) of file f touches (texdiff.reads; a hunk can start inside one: "b} \\input{")."""
    names = [_input_name(m) for m in INPUT.finditer(text or "")]
    names += texdiff.reads(texts, f, s, e)[0] if f and e > s else []
    return list(dict.fromkeys(n[:-4] if n.endswith(".tex") and n[:-4] in names else n for n in names))


def _before(b, old_by, of, os_, oe):
    """A figure, table, formula, listing or picture block touched by a change: the previous round's crop."""
    if b["kind"] not in IMAGE_KINDS or not of:
        return
    o = next((o for o in _overlapping(old_by, of, os_, max(oe, os_ + 1)) if o["kind"] in IMAGE_KINDS and o["clip"]),
             None)
    if o:
        b["before"] = {"page": o["clip"][0], "clip": o["clip"][1]}


def _break_only(diff, h):
    """For a move that only puts a paragraph break in or takes one out (a split or a joined paragraph): the new
    range [a, b) between the moved text and where it was, holding only white space and comments; else None."""
    nf, ns, ne = h["new_file"], h["new_start"], h["new_end"]
    toks = diff.new_tokens.get(nf)
    for at, edge in ((diff.map_offset(h["old_file"], h["old_start"], "right"), ns),
                     (diff.map_offset(h["old_file"], h["old_end"], "left"), ne)):
        if toks is not None and at and at[0] == nf:
            a, b = min(at[1], edge), max(at[1], edge)
            if not texdiff.blank_comments(toks.text[a:b]).strip():
                return a, b
    return None


def _touching(by_file, f, a, z):
    """The blocks of file f overlapping or touching the range [a, z]."""
    return [b for b in by_file.get(f, ()) if b["start"] <= z and a <= b["end"]]


def _del(o, os_, oe, diff, h, new_by, cid, moved=None):
    """Place the words of old block o in [os_, oe) as deleted at their place in the new block that follows o:
    before the first word after them, or after the last word before them (not in a block marked moved by `moved`:
    the words themselves). Returns the blocks marked."""
    spans = _display(o, os_, oe)
    if not spans:
        return []
    d0, d1 = spans[0][0], spans[-1][1]
    at = diff.map_offset(o["file"], oe, "left") if oe < o["end"] else diff.map_offset(o["file"], os_, "right")
    if at is None:
        at = (h["new_file"], h["new_start"])
    cands = [b for b in new_by.get(at[0], ()) if b["start"] <= at[1]]  # the block holding the point, or before it
    if not cands:
        return []
    b = next((b for b in cands if at[1] <= b["end"]), cands[-1])
    if moved and b["moved"] == moved:
        return []
    b["del"].append([_point(b, at[1]), o["text"][d0:d1], _marks_in(o, d0, d1), cid])
    return [b]


def _refine(o, b, old, new, cid):
    """A replace inside one block on each side: the words of the two display texts are diffed again (as
    cards.changed splits them), so equal words in the hunk are not marked."""
    os_, ns = _display(o, *old), _display(b, *new)
    if not os_ or not ns:
        for s, e in ns:
            b["ins"].append([s, e, cid])
        if os_:
            b["del"].append([_point(b, new[0]), o["text"][os_[0][0]:os_[-1][1]],
                             _marks_in(o, os_[0][0], os_[-1][1]), cid])
        return
    o0, o1, n0, n1 = os_[0][0], os_[-1][1], ns[0][0], ns[-1][1]
    a, z = cards._tokens(o["text"][o0:o1]), cards._tokens(b["text"][n0:n1])
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, [x for x, _, _ in a], [x for x, _, _ in z],
                                               autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if i2 > i1:
            p = n0 + (z[j1][1] if j2 > j1 else z[j1 - 1][2] if j1 else 0)
            s, e = o0 + a[i1][1], o0 + a[i2 - 1][2]
            b["del"].append([p, o["text"][s:e], _marks_in(o, s, e), cid])
        if j2 > j1:
            b["ins"].append([n0 + z[j1][1], n0 + z[j2 - 1][2], cid])


def _place_deleted(blocks, old, deleted, new_by, n, touched):
    """The new blocks with a `deleted` block for each wholly deleted old block, at the deletion point."""
    after = {}  # index of the new block a deleted block follows (-1: before all) -> [(old index, block)]
    order = {id(o): k for k, o in enumerate(old)}
    position = {id(b): k for k, b in enumerate(blocks)}
    hashes = {b["hash"]: k for k, b in enumerate(blocks) if b["hash"]}
    for o, h, cid in deleted:
        k = None
        if h["new_file"] and new_by.get(h["new_file"]):
            before = [b for b in new_by[h["new_file"]] if b["start"] < h["new_start"]]
            k = position[id(before[-1])] if before else position[id(new_by[h["new_file"]][0])] - 1
        if k is None:  # no place in the new file (a deleted file): after the nearest earlier block still there
            k = next((hashes[p["hash"]] for p in reversed(old[:order[id(o)]]) if p["hash"] in hashes), -1)
        d = {"kind": "deleted", "file": o["file"], "start": o["start"], "end": o["end"], "lines": o["lines"],
             "hash": "d" + o["hash"] if o["hash"] else None, "section": None, "level": None, "number": None,
             "text": o["text"], "marks": o["marks"], "map": [], "box": None, "clip": None,
             "ins": [], "del": [], "added": None, "moved": None,
             "before": {"page": o["clip"][0], "clip": o["clip"][1]} if o["clip"] else None,
             "round": n - 1, "was": o["kind"]}
        after.setdefault(k, []).append((order[id(o)], d))
        if cid:
            touched.setdefault(cid, []).append(d)
    out = [d for _, d in sorted(after.get(-1, []), key=lambda x: x[0])]
    for k, b in enumerate(blocks):
        out.append(b)
        out += [d for _, d in sorted(after.get(k, []), key=lambda x: x[0])]
    return out


def _previous(blocks, old_blocks, diff):
    """Where each block of round n-1 (old_blocks, as its prose.json lists them) is in this round: the index in
    `blocks` (diff-marked, _diff_marks) of the block that continues it, or None (wholly deleted: _diff_marks put a
    `deleted` block for it; a `deleted` or `missing` block of round n-1). Tried in this order: a hash that one block
    has on each side (a moved or re-wrapped paragraph, also one too short for texdiff to see the move); texdiff's
    mapping of the block's first token (else its last) into a block of the same file; a hash that a block not taken
    yet has, in order. The overview matches each round's sections to the round before's by these (CONTRACT.md
    amendment "Overview")."""
    live = [(k, b) for k, b in enumerate(blocks) if b["kind"] not in ("deleted", "missing")]
    gone = {(b["file"], b["start"], b["end"]) for b in blocks if b["kind"] == "deleted"}
    olds = [(j, o) for j, o in enumerate(old_blocks) if o["kind"] not in ("deleted", "missing")]
    by_file, first = {}, {}
    for k, b in live:
        by_file.setdefault(b["file"], []).append((k, b))
        if b["hash"]:
            first.setdefault(b["hash"], []).append(k)
    old_count = Counter(o["hash"] for _, o in olds if o["hash"])
    out = [None] * len(old_blocks)
    for j, o in olds:
        if o["hash"] and old_count[o["hash"]] == 1 and len(first.get(o["hash"], ())) == 1:
            out[j] = first[o["hash"]][0]
    for j, o in olds:
        if out[j] is None and (o["file"], o["start"], o["end"]) not in gone:
            out[j] = _mapped(diff, by_file, o)
    taken = set(out)
    for j, o in olds:
        if out[j] is None and o["hash"] and (o["file"], o["start"], o["end"]) not in gone:
            k = next((k for k in first.get(o["hash"], ()) if k not in taken), None)
            if k is not None:
                out[j] = k
                taken.add(k)
    return out


def _mapped(diff, by_file, o):
    """The index of the new block that holds texdiff's image of old block o's first token, else of its last."""
    for offset, bias in ((o["start"], "left"), (o["end"], "right")):
        at = diff.map_offset(o["file"], offset, bias) if o["file"] else None
        if at is None:
            continue
        f, p = at
        k = next((k for k, b in by_file.get(f, ())
                  if (b["start"] <= p < b["end"] if bias == "left" else b["start"] < p <= b["end"])), None)
        if k is not None:
            return k
    return None


def _sections(blocks):
    """Each block's section: the index of the innermost heading of level 1 or 2 at or above it (-1: front matter)."""
    current = -1
    for k, b in enumerate(blocks):
        if b["kind"] == "heading" and (b["level"] or 1) <= 2:
            current = k
        b["section"] = current


# --- building and loading prose.json ---------------------------------------------------------------------------

def path(paper, n):
    return Path(paper) / "r{}".format(n) / "prose.json"


def _blocks(paper, lg, n):
    """(blocks without places and diff marks, the build PDF) of round n."""
    rnd = _round(lg, n)
    rdir = Path(paper) / "r{}".format(n)
    blocks = _Reader(rdir / "src", rdir / "build", lg["paper"]["main"]).read(_context)
    return blocks, Path(paper) / rnd["build"]["pdf"]


def _round(lg, n):
    rnd = next((r for r in lg["rounds"] if r["n"] == n), None)
    if rnd is None:
        raise EngineError("There is no round {}.".format(n))
    if not rnd["build"]["pdf"]:
        raise EngineError("Round {} has no build PDF.".format(n))
    return rnd


def build(paper, lg, n, diff=None, progress=None):
    """Build round n's prose.json (round n-1's first when it is missing or stale) and return it. `diff` is the
    round's TreeDiff (ingest has it); without it the diff is made again, and change ids are kept only when its hunks
    give analysis.json's kinds and files in order (else the marks carry placeholder ids, "?01", and `changes` is
    empty). Also writes each change's block hashes into analysis.cache.json. When round n-1's paragraphs cannot be
    found, that is noted (record_failure) and round n is built without diff marks, as round 1 is."""
    paper = Path(paper)
    blocks, pdf = _blocks(paper, lg, n)
    build_ = _round(lg, n)["build"]
    _places(blocks, pdf, build_.get("columns"), build_.get("text_x"))
    changes, against, previous, before = {}, None, None, None
    rnd_prev = next((r for r in lg["rounds"] if r["n"] == n - 1), None)
    if n > 1 and rnd_prev and rnd_prev["build"]["pdf"]:
        try:
            before = load(paper, n - 1) or build(paper, lg, n - 1, progress=progress)
        except Exception as e:  # else every later round would fail too, and be tried again on every call
            traceback.print_exc(file=sys.stderr)
            record_failure(paper, n - 1, e)
    if before is not None:
        against = n - 1
        old, new = paper / "r{}".format(n - 1), paper / "r{}".format(n)
        analysis = _analysis(paper, n)
        if diff is None:
            diff = texdiff.diff_trees(old / "src", new / "src", old / "build", new / "build")
        stored = [(ch["kind"], ch["file"]) for ch in analysis] if analysis is not None else None
        same = stored is not None and stored == [(h["kind"], h["new_file"] or h["old_file"]) for h in diff.hunks]
        ids = [("c{:02d}" if same else "?{:02d}").format(i + 1) for i in range(len(diff.hunks))]
        blocks, changes = _diff_marks(blocks, before["blocks"], diff, ids, n)
        previous = _previous(blocks, before["blocks"], diff)
        if same:
            _store_hashes(paper, n, blocks, changes)
        else:  # the marks keep their placeholder ids (an added block is fresh, a moved one moved), but no change of
            changes = {}  # the round is known to touch a block
    _sections(blocks)
    for b in blocks:
        for k in ("_ranges", "_caption", "_narrow"):
            b.pop(k, None)
    data = {"schema": SCHEMA, "parser": PARSER, "round": n, "against": against, "blocks": blocks, "changes": changes,
            "previous": previous}
    out = path(paper, n)
    tmp = out.with_name("prose.json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, out)
    with contextlib.suppress(OSError):
        failure_path(paper, n).unlink()
    return data


def failure_path(paper, n):
    return Path(paper) / "r{}".format(n) / "prose.failed"


def record_failure(paper, n, error):
    """Note in rN/prose.failed that finding round n's paragraphs failed with this PARSER, so the overview says the
    round's sections are unavailable instead of waiting for them (a later build that succeeds removes it). Writing it
    may fail too: the note is a convenience."""
    with contextlib.suppress(OSError):
        p = failure_path(paper, n)
        tmp = p.with_name("prose.failed.tmp")
        tmp.write_text(json.dumps({"parser": PARSER, "error": str(error)}, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, p)


def failed(paper, n):
    """Whether finding round n's paragraphs failed with this PARSER (record_failure)."""
    try:
        return json.loads(failure_path(paper, n).read_text(encoding="utf-8")).get("parser") == PARSER
    except (OSError, ValueError, AttributeError):
        return False


def _analysis(paper, n):
    data = analysis.read(paper, n)
    return data["changes"] if data is not None else None


def _store_hashes(paper, n, blocks, changes):
    """The hashes of the readable blocks each change touches ("hashes", and "fresh": whether each block shows the
    round's edits) in analysis.cache.json, so the papers list reads them without prose.json (analysis.changes); a
    cache, never written into analysis.json, which a finished round's checksums cover."""
    entries = {}
    for ch in analysis.read(paper, n)["changes"]:
        ks = [k for k in changes.get(ch["id"], []) if readable(blocks[k])]
        entries[ch["id"]] = {"hashes": [blocks[k]["hash"] for k in ks], "fresh": [fresh(blocks[k]) for k in ks]}
    analysis.store_cache(paper, n, entries)


def load(paper, n):
    """Round n's prose.json when it exists and is current (cached by path and modification time), else None."""
    p = path(paper, n)
    try:
        st = p.stat()
    except OSError:
        return None
    data = _load(str(p), st.st_mtime_ns, st.st_size)
    return data if data and data.get("parser") == PARSER and data.get("schema") == SCHEMA else None


def follow(paper, frm, block, to):
    """Round `frm`'s block `block` in round `to` (the reader's place across rounds, design/pdf-reader/PLAN.md P1.1),
    through each round's `previous`, which puts the round before's blocks in its own: forward the block that continues
    it, backward the first block it continues. None when a round on the way has no current prose.json or a `previous`
    that does not fit the round before, or the block is gone on the way (deleted, new, out of range)."""
    idx, step = block, (1 if to > frm else -1)
    for j in range(frm, to, step):
        later = j + 1 if step > 0 else j
        d, dp = load(paper, later), load(paper, later - 1)
        if not d or not dp or d.get("against") != later - 1 or d.get("previous") is None \
                or len(d["previous"]) != len(dp["blocks"]):
            return None
        prev = d["previous"]
        if step > 0:
            idx = prev[idx] if 0 <= idx < len(prev) else None
        else:
            idx = next((i for i, k in enumerate(prev) if k == idx), None)
        if idx is None:
            return None
    return idx


@functools.lru_cache(maxsize=8)
def _load(p, mtime, size):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def ensure(paper, lg, n, progress=None):
    """Round n's prose, built when missing or stale."""
    data = load(paper, n)
    if data is None:
        if progress:
            progress("Finding the paragraphs…")
        data = build(paper, lg, n, progress=progress)
    return data


# --- read state ------------------------------------------------------------------------------------------------

@functools.lru_cache(maxsize=32)
def _hashes_of(paper, n, stamp):
    data = load(paper, n)
    if data is None:
        lg = ledger.load(paper)
        blocks = _blocks(paper, lg, n)[0]  # no places: every block with a hash
    else:
        blocks = data["blocks"]
    return frozenset(b["hash"] for b in blocks if b["hash"])


def round_hashes(paper, lg, n):
    """The hashes of round n's blocks (from prose.json, else worked out from its source once per process)."""
    rnd = next(r for r in lg["rounds"] if r["n"] == n)
    return _hashes_of(str(paper), n, (rnd["created"], rnd["build"]["pdf"]))


def read_map(paper, lg):
    """The ledger's read map {hash: round}. A ledger from before read state has none: every closed round's hashes
    count as read (review folders made before this were reviewed round by round). Closing a round marks its
    paragraphs read (close_read); when the round before the open one was closed before that rule (the ledger's
    read_through is lower), its hashes count as read as of that round, so the open round's bars are the paragraphs
    changed since then."""
    if "read" not in lg:
        out = {}
        for r in lg["rounds"]:
            if r["closed"] and r["build"]["pdf"]:
                for h in sorted(round_hashes(paper, lg, r["n"])):
                    out.setdefault(h, r["n"])
        return out
    prev = _unmarked(lg)
    if prev is None:
        return lg["read"]
    out = dict(lg["read"])
    try:
        hashes = round_hashes(paper, lg, prev["n"])
    except Exception:  # its paragraphs still cannot be found: the review goes on without them
        traceback.print_exc(file=sys.stderr)
        hashes = ()
    for h in sorted(hashes):
        out.setdefault(h, close_value(prev["n"]))
    return out


def _unmarked(lg):
    """The closed round before the open one when closing it did not mark its paragraphs read (a ledger whose
    read_through, 1 when missing, is lower), else None."""
    rnd = ledger.latest_round(lg)
    if rnd is None or rnd["closed"] or rnd["n"] - 1 <= lg.get("read_through", 1):
        return None
    prev = next((r for r in lg["rounds"] if r["n"] == rnd["n"] - 1), None)
    return prev if prev and prev["closed"] and prev["build"]["pdf"] else None


def close_value(n):
    """The value closing round n gives the hashes it marks read: n - 1 (1 for round 1). They are read from round n + 1
    on, while a paragraph edited in round n and not confirmed there keeps its bar when round n is viewed later
    (is_read needs read[hash] >= n for it)."""
    return max(n - 1, 1)


def close_read(lg, n, data):
    """Closing round n (finish, after final.pdf): every block of round n with a hash (not deleted ones) is read, so
    in round n + 1 the bars are exactly the paragraphs changed since round n. Sets the ledger's read_through to n.
    Without the round's blocks (finding them failed) nothing is marked and read_through stays below n, so the next
    round counts round n's paragraphs as read once they can be found (read_map). Returns the hashes it marked (those
    not in the map before), sorted: Resume takes them off again (open_read)."""
    if data is None:
        lg["read_through"] = min(lg.get("read_through", 1), n - 1)
        return []
    read, marked = lg["read"], set()
    for b in data["blocks"]:
        if b["hash"] and b["kind"] != "deleted" and b["hash"] not in read:
            read[b["hash"]] = close_value(n)
            marked.add(b["hash"])
    lg["read_through"] = n
    return sorted(marked)


def open_read(lg, n, marked):
    """Resuming round n (api.resume_round): close_read undone, so the round reads as before Finish. The hashes that
    Finish marked (marked: close_read's list; None for a Finish by an engine before it, whose marks stay) leave the
    map while they still have Finish's value, and read_through goes back to n − 1 (1 for round 1), as it was before
    Finish."""
    if marked is None:
        return
    read = lg["read"]
    for h in marked:
        if read.get(h) == close_value(n):
            del read[h]
    lg["read_through"] = max(n - 1, 1)


def materialize(paper, lg):
    """The ledger's read map, stored in it first when it has none (the first write of an older ledger) or lacks the
    round before the open one (read_map); read_through is then the latest closed round."""
    if "read" not in lg or _unmarked(lg) is not None:
        lg["read"] = read_map(paper, lg)
        closed = [r["n"] for r in lg["rounds"] if r["closed"]]
        if closed:
            lg["read_through"] = max(closed)
    return lg["read"]


def readable(b):
    """Whether block b is one the advisor reads (and confirms) in the PDF: a paragraph, list item, reference entry,
    formula, float, listing or picture with a hash and a place in the PDF. Headings, the title and deleted blocks
    are not, nor is a paragraph or item whose text has no letter or digit (the "]" that closes ICML's
    \\twocolumn[…] title block, which synctex gives the author line)."""
    return bool(b["hash"]) and b["kind"] in READ and bool(b.get("parts")) and \
        (b["kind"] not in ("paragraph", "item") or "text" not in b or any(ch.isalnum() for ch in b["text"]))


def fresh(b):
    """Whether block b shows its round's edits (inserted or deleted words, added, a changed picture, deleted). Such a
    block is read only once marked read in its round or later: text like a block read before (a new heading worded
    as another, a paragraph back to an older text) is still the advisor's to read."""
    return bool(b["ins"] or b["del"] or b["added"] or b["before"]) or b["kind"] == "deleted"


def is_read(h, fresh_, read, n):
    """Whether a block of round n with hash h is read (fresh_: fresh(block)) in the read map."""
    return bool(h) and h in read and (not fresh_ or read[h] >= n)


def change_read(ch, blocks, read, n):
    """Whether change ch of round n is handled by reading: not a move, and every readable block it touches read
    (blocks: [(hash, fresh)], change_hashes). A change that touches none (a heading, a deleted paragraph) is not."""
    return ch["kind"] != "move" and bool(blocks) and all(is_read(h, f, read, n) for h, f in blocks)


def change_hashes(data, ch):
    """[(hash, fresh)] of the readable blocks a change touches: from prose.json, else analysis.json's "hashes" and
    "fresh"."""
    if data is not None:
        return [(data["blocks"][k]["hash"], fresh(data["blocks"][k])) for k in data["changes"].get(ch["id"], [])
                if readable(data["blocks"][k])]
    return list(zip(ch.get("hashes", []), ch.get("fresh", [False] * len(ch.get("hashes", [])))))


# --- comments' places in the blocks ----------------------------------------------------------------------

def block_of(data, anchor_):
    """The index of the block a source anchor of the round is in (comments[].paragraph): the first block of its file
    that its range overlaps (a point, a gone comment: that holds it), not deleted or missing, else the first block
    that \\inputs its file (a float's tabular or picture file); None when there is none. A float's block holds its
    whole environment, so a comment on a table cell or on text in a figure is in it. Files match in any case or
    Unicode form (texdiff.name_key): an older ledger's anchor has synctex's spelling, the \\input's."""
    if data is None or not anchor_ or anchor_.get("start") is None:
        return None
    a, z, f = anchor_["start"], anchor_["end"], texdiff.name_key(anchor_["file"] or "")
    index, inputs = _by_file(data)
    k = next((k for k, b in index.get(f, ())
              if (b["start"] < z and a < b["end"] if z > a else b["start"] <= a <= b["end"])), None)
    return inputs.get(f) if k is None else k


def _by_file(data):
    """({name_key of a file: [(index, block)]}, {name_key of a file: the index of the first block that \\inputs it})
    of prose data's blocks, not deleted or missing."""
    key = id(data)
    if _BY_FILE.get("key") != key:
        index, inputs = {}, {}
        for k, b in enumerate(data["blocks"]):
            if b["kind"] not in ("deleted", "missing"):
                index.setdefault(texdiff.name_key(b["file"]), []).append((k, b))
                for f in b.get("inputs", ()):
                    inputs.setdefault(texdiff.name_key(f), k)
        _BY_FILE.clear()
        _BY_FILE.update(key=key, index=(index, inputs), data=data)
    return _BY_FILE["index"]


_BY_FILE = {}
