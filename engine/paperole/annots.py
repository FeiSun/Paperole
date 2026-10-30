"""Read an annotated PDF into comment records (the core of the engine's `import` step).

Every annotation either becomes a comment, joins another comment (reply or group),
is a Popup (part of its parent), or is listed in "ignored" with its type.
Quotes come from a copy of the document with all annotations removed, because MuPDF
page text otherwise includes the text of FreeText boxes.
"""
import argparse
import html
import json
import re
import unicodedata
from collections import defaultdict
from pathlib import Path

import pymupdf

KINDS = {
    "Highlight": "highlight", "Underline": "underline", "StrikeOut": "strikeout", "Squiggly": "squiggly",
    "Text": "note", "FreeText": "textbox", "Caret": "caret", "Ink": "ink",
    "Square": "shape", "Circle": "shape", "Line": "shape", "Polygon": "shape", "PolyLine": "shape",
}
TEXT_MARKUP = ("highlight", "underline", "strikeout", "squiggly")
CONTEXT = 40  # characters of prefix and suffix
HALF_LINE = 6  # points: a box's first line of text is centred about this far below its top
LEVEL = 5  # points: lines this much farther away in height than the nearest line still count as level with it


def extract(pdf_path):
    """Return {"comments": [...], "ignored": [...]} for the annotations in pdf_path."""
    doc = pymupdf.open(pdf_path)
    clean = pymupdf.open(pdf_path)
    for i in range(clean.page_count):
        clean.xref_set_key(clean.page_xref(i), "Annots", "null")

    found, ignored = {}, []
    for page in doc:
        # The page's own /Annots list: page.annot_xrefs() leaves out subtypes MuPDF does not know.
        for xref in (int(n) for n in re.findall(r"(\d+) \d+ R", _key(doc, page.xref, "Annots"))):
            subtype = _key(doc, xref, "Subtype").lstrip("/") or "(none)"
            if subtype == "Popup":
                continue
            if subtype in KINDS:
                found[xref] = _read(doc, page, xref, subtype)
            else:
                ignored.append({"page": page.number + 1, "annot_type": subtype, "xref": xref})

    # Replies (/RT R or no /RT) join the thread of the annotation they answer; /RT Group merges into it.
    roots = {x: _root(found, x) for x in found}
    for xref, a in found.items():
        root = roots[xref]
        if root == xref or found[root]["irt"] in found:  # not a reply, or a reply chain that loops
            continue
        if a["rt"] == "Group":
            found[root]["quads"] += a["quads"]
            found[root]["rect"] = list(pymupdf.Rect(found[root]["rect"]) | pymupdf.Rect(a["rect"]))
            found[root]["merged"].append(xref)
        else:
            found[root]["thread"].append({"author": a["author"], "text": a["note"], "date": a["created"] or a["modified"]})
        a["joined"] = True

    comments, pages = [], {}
    for c in (a for a in found.values() if "joined" not in a):
        page = doc[c["page"] - 1]
        if page.number not in pages:
            words = _words(clean[page.number])
            pages[page.number] = (words,) + _join(words)
        words, text, spans = pages[page.number]
        # PDF coordinates to those of the words: unrotated, origin at the CropBox's top left.
        # (page.transformation_matrix ignores the CropBox offset on rotated pages.)
        m = pymupdf.Matrix(1, 0, 0, -1, -page.cropbox.x0, page.mediabox.y1 - page.cropbox.y0)
        idx, guessed = _anchor(c, m, words)
        quote = _join([words[i] for i in idx])[0]
        if c["kind"] in TEXT_MARKUP:
            c["note"] = _strip_copied_quote(c["note"], quote)
        start, end = (spans[idx[0]][0], spans[idx[-1]][1]) if idx else (0, 0)
        box = pymupdf.Rect(c["rect"]) * m
        comments.append(((c["page"], round(box.y0), box.x0), {
            "id": None, "page": c["page"], "kind": c["kind"], "annot_type": c["annot_type"], "xref": c["xref"],
            "rect": c["rect"], "quads": c["quads"], "color": c["color"], "note": c["note"], "quote": quote,
            "prefix": text[max(0, start - CONTEXT):start].strip() if idx else "",
            "suffix": text[end:end + CONTEXT].strip() if idx else "",
            "author": c["author"], "created": c["created"], "modified": c["modified"],
            "thread": c["thread"], "merged": c["merged"],
            "flags": {"position_guessed": guessed, "mark_only": not c["note"]},
        }))

    comments = [c for _, c in sorted(comments, key=lambda kc: kc[0])]
    per_page = defaultdict(int)
    for c in comments:
        per_page[c["page"]] += 1
        c["id"] = "P{}-{:02d}".format(c["page"], per_page[c["page"]])
    return {"comments": comments, "ignored": ignored}


def _key(doc, xref, key):
    """A key of a PDF dictionary as text ("" when absent); PyMuPDF decodes PDF strings.

    An indirect value is read through a scratch dictionary that holds it directly, so that it is
    decoded the same way."""
    kind, value = doc.xref_get_key(xref, key)
    if kind == "xref":
        scratch = pymupdf.open()
        n = scratch.get_new_xref()
        scratch.update_object(n, "<</V {}>>".format(doc.xref_object(int(value.split()[0]))))
        kind, value = scratch.xref_get_key(n, "V")
    return "" if kind == "null" else value


def _read(doc, page, xref, subtype):
    """The raw fields of one annotation, with rect and quads in the PDF's own page coordinates."""
    r = [float(v) for v in _key(doc, xref, "Rect").strip("[]").split()]
    q = [float(v) for v in _key(doc, xref, "QuadPoints").strip("[]").split()]
    rich = re.sub(r"</p>|<br\s*/?>", "\n", _key(doc, xref, "RC"))  # keep rich-text paragraphs apart
    rich = html.unescape(re.sub(r"<[^>]*>", "", rich))
    kind, irt = doc.xref_get_key(xref, "IRT")
    return {
        "page": page.number + 1, "kind": KINDS[subtype], "annot_type": subtype, "xref": xref,
        "rect": [min(r[0], r[2]), min(r[1], r[3]), max(r[0], r[2]), max(r[1], r[3])],
        "quads": [q[i:i + 8] for i in range(0, len(q) - 7, 8)],
        "color": [float(v) for v in _key(doc, xref, "C").strip("[]").split()],
        "note": (_key(doc, xref, "Contents") or rich).strip(),
        "author": _key(doc, xref, "T"),
        "created": _key(doc, xref, "CreationDate"), "modified": _key(doc, xref, "M"),
        "irt": int(irt.split()[0]) if kind == "xref" else None, "rt": _key(doc, xref, "RT").lstrip("/"),
        "thread": [], "merged": [],
    }


def _root(found, xref):
    """Follow /IRT links to the annotation that is not itself answering another found one."""
    seen = {xref}
    while found[xref]["irt"] in found and found[xref]["irt"] not in seen:
        xref = found[xref]["irt"]
        seen.add(xref)
    return xref


def _words(page):
    """Words of an annotation-free page in extraction order, as (rect, text, visual line number, block)."""
    words, line, prev = [], -1, None
    for x0, y0, x1, y1, text, block, _, _ in page.get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP):
        rect = pymupdf.Rect(x0, y0, x1, y1)
        if not (prev and prev[0] == block and prev[1].y0 <= (y0 + y1) / 2 <= prev[1].y1):
            line += 1
        prev = (block, rect)
        words.append((rect, text, line, block))
    return words


def _join(words):
    """Join words with spaces; a word ending its line in a hyphen joins the next line's word.

    Returns the text and each word's (start, end) in it."""
    text, spans = "", []
    for i, (_, word, line, _) in enumerate(words):
        nxt = words[i + 1] if i + 1 < len(words) else None
        if nxt and nxt[2] != line and len(word) > 1 and word.endswith("-"):
            word, sep = word[:-1], ""
        else:
            sep = " " if nxt else ""
        spans.append((len(text), len(text) + len(word)))
        text += word + sep
    return text, spans


def _centre(rect):
    return pymupdf.Point((rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2)


def _anchor(c, m, words):
    """Indices of the words a comment points at, and whether that position is a guess.

    m maps the PDF's page coordinates to those of the words."""
    rect = pymupdf.Rect(c["rect"]) * m
    boxes = [pymupdf.Quad(*(pymupdf.Point(q[i], q[i + 1]) * m for i in range(0, 8, 2))).rect for q in c["quads"]]
    if c["kind"] in ("shape", "ink"):
        boxes = [rect]
    if boxes:
        inside = [i for i, (r, *_) in enumerate(words) if any(_centre(r) in b for b in boxes)]
        if inside:
            return inside, False
    elif c["kind"] == "caret":  # the words on either side of the insertion point
        line = _nearest_line(words, rect, _centre(rect).y)
        before = [i for i in line if _centre(words[i][0]).x < _centre(rect).x]
        after = [i for i in line if i not in before]
        idx = before[-1:] + after[:1]
        return idx, not idx
    return _nearest_line(words, rect, min(rect.y0 + HALF_LINE, _centre(rect).y)), True


def _nearest_line(words, rect, y):
    """Word indices of the body line (one containing a letter) nearest to height y.

    Lines within LEVEL points of the nearest height count as level. Of those, the one whose text
    block is horizontally nearest to rect wins, then the nearer in height, so that a note beside or
    on one column of a two-column page stays with that column."""
    lines, blocks = defaultdict(list), {}
    for i, (r, _, line, block) in enumerate(words):
        lines[line].append(i)
        blocks[block] = blocks[block] | r if block in blocks else pymupdf.Rect(r)

    def height(idx):
        return max(min(words[i][0].y0 for i in idx) - y, y - max(words[i][0].y1 for i in idx), 0)

    def side(idx):
        box = blocks[words[idx[0]][3]]
        return max(box.x0 - rect.x1, rect.x0 - box.x1, 0)

    body = [idx for idx in lines.values() if any(ch.isalpha() for i in idx for ch in words[i][1])]
    if not body:
        return []
    level = min(map(height, body)) + LEVEL
    return min((idx for idx in body if height(idx) <= level), key=lambda idx: (side(idx), height(idx)))


def _strip_copied_quote(note, quote):
    """Drop a copy of the quoted text that ends the note on a line of its own (Acrobat can copy the
    selection into the note), or that is the whole note.

    Spaces, line breaks and hyphens are ignored when comparing. Any other text is kept, including a
    note whose last words merely repeat the quote, such as "不适合叫baseline"."""
    chars = [(i, d) for i, ch in enumerate(note) for d in unicodedata.normalize("NFKC", ch)
             if not (d.isspace() or d == "-")]
    target = [d for d in unicodedata.normalize("NFKC", quote) if not (d.isspace() or d == "-")]
    if target and [d for _, d in chars[-len(target):]] == target:
        head = note[:chars[-len(target)][0]]
        if not head.strip() or re.search(r"[\r\n]\s*$", head):
            return head.rstrip()
    return note


def _cell(text, limit):
    text = " ".join(text.split()).replace("|", "\\|")
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _report(name, result):
    """Markdown summary: one table row per comment, then the ignored annotations by type."""
    out = ["# " + name, "", "{} comments, {} ignored annotations.".format(len(result["comments"]), len(result["ignored"])),
           "", "| id | page | kind | quote | note | flags |", "|---|---|---|---|---|---|"]
    for c in result["comments"]:
        flags = [k for k, v in c["flags"].items() if v]
        if c["thread"]:
            flags.append("{} replies".format(len(c["thread"])))
        out.append("| {} | {} | {} | {} | {} | {} |".format(
            c["id"], c["page"], c["kind"], _cell(c["quote"], 60), _cell(c["note"], 80), ", ".join(flags)))
    out += ["", "## Ignored", ""]
    pages = defaultdict(list)
    for a in result["ignored"]:
        pages[a["annot_type"]].append(a["page"])
    for kind, nums in sorted(pages.items()):
        out.append("- {}: {} (pages {})".format(kind, len(nums), ", ".join(str(p) for p in sorted(set(nums)))))
    if not pages:
        out.append("None.")
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Extract the comments of an annotated PDF.")
    parser.add_argument("pdf")
    parser.add_argument("-o", "--outdir", required=True)
    args = parser.parse_args(argv)
    result = extract(args.pdf)
    out = Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)
    stem = Path(args.pdf).stem
    (out / (stem + ".comments.json")).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    (out / (stem + ".report.md")).write_text(_report(Path(args.pdf).name, result), encoding="utf-8")


if __name__ == "__main__":
    main()
