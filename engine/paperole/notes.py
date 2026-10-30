"""Students' notes (CONTRACT.md amendment "Student notes"): a LaTeX comment whose text starts with a comment's ID,
"% R1-05 kept as is because the reviewer asked for this definition". At ingest, the notes added or edited since the
previous round go to the comments they name, the changes next to them are attached to those comments, and the notes
that cannot be used are warnings with their file and line (`find`)."""
import bisect
import re

from . import ledger, texdiff

_DASH = "\\-\u2010\u2011\u2012\u2013\u2014\u2212\uff0d"  # - and its Unicode and full-width look-alikes
_OPEN, _CLOSE = "\\[(\uff08\uff3b\u3010", "\\])\uff09\uff3d\u3011"  # [ ( and ] ) with their full-width forms
_R = "Rr\uff32\uff52"
# a comment's ID: R<round>-<number> in any case, R1-3 for R1-03, in brackets ([R1-03]), in full-width forms
ID = re.compile(r"[{o}]?\s*[{r}](\d+)[{d}](\d+)(?![0-9A-Za-z\uff10-\uff19\uff21-\uff3a\uff41-\uff5a])\s*[{c}]?"
                .format(o=_OPEN, r=_R, d=_DASH, c=_CLOSE))
JOIN = re.compile(r"\s*(?:(?:[,\uff0c\u3001;\uff1b/&+]|and\b|\u548c|\u4e0e|\u53ca)\s*)?")  # , ， 、 ; ； / & + and 和 与 及
SEP = re.compile(r"\s*[:\uff1a\-\u2013\u2014\u00b7.,\uff0c\u3002]?\s*")  # : ： - – — · . , ， 。
# what starts like an ID but is none: R1.03, R1_03, R1 - 03, R-03, R1-03a, R103
MALFORMED = re.compile(r"[{o}]?\s*[{r}](?:\s*\d+\s*[{d}_.\uff0e]+\s*\d|\s*[{d}_]+\s*\d|\d{{3,4}}(?![0-9A-Za-z]))"
                       .format(o=_OPEN, r=_R, d=_DASH))
NEAR = 3  # lines: how far a note on a line of its own looks for the change next to it
# Lines a note on a line of its own does not look past (_Source.walled): a sectioning command and the end of a float,
# either way, and the beginning of a float upwards (a note just above a float reaches into it, one inside does not
# reach out of it)
WALL = re.compile(r"\\(?:part|chapter|(?:sub)*section|(?:sub)?paragraph)\b|"
                  r"\\(begin|end)\s*\{(?:figure|table|wrapfigure|wraptable|sidewaysfigure|sidewaystable|algorithm)\*?\}")
OTHER = ("*.bib", "*.sty", "*.cls")  # files whose notes are not read: a note there is a warning (not_tex)
CLOSED_AS = {"verified": "resolved", "wontfix": "kept as is"}  # the app's words for a closed comment


def comments_in(text):
    """[(offset of the %, the comment's text after it)] of the LaTeX comments of a source (texdiff.COMMENT)."""
    return [(m.start(), m.group()[1:]) for m in texdiff.COMMENT.finditer(text) if m.group()[0] == "%"]


def parse(body):
    """A comment's text (after its %) read as a note: (ids, text), with ids as the ledger writes them ("R1-03") and
    text the note after the IDs and a separator; ([], text) when it starts like an ID but is none (MALFORMED); None
    when it is no note."""
    i = len(body) - len(body.lstrip("% \t"))
    m = ID.match(body, i)
    if m is None:
        return ([], " ".join(body[i:].split())) if MALFORMED.match(body, i) else None
    ids = []
    while m is not None:
        cid = "R{}-{:02d}".format(int(m.group(1)), int(m.group(2)))
        if cid not in ids:
            ids.append(cid)
        i = m.end()
        m = ID.match(body, JOIN.match(body, i).end())
    return ids, " ".join(body[SEP.match(body, i).end():].split())


class _Source:
    """A .tex file of the new tree as find reads it: its lines, its changes (the indexes of diff.hunks with their
    first and last lines, white space aside, and for one that took out a paragraph or more, the gap where it was:
    from its point to the next token) and the lines of its walls (WALL), worked out once."""

    def __init__(self, diff, file, text):
        self.text = text
        self.starts = [0] + [m.end() for m in re.finditer("\n", text)]
        self.hunks = []
        toks = diff.new_tokens.get(file)
        for k, h in enumerate(diff.hunks):
            if h["new_file"] == file:
                s, e = texdiff.trim(text, h["new_start"], h["new_end"])
                gap = h["new_end"]
                if s == e and toks is not None and re.search(r"\n[^\S\n]*\n", h["old_text"] or ""):
                    j = bisect.bisect_left(toks.starts, s)
                    while j < len(toks.texts) and toks.texts[j] == texdiff.PAR:
                        j += 1
                    gap = toks.starts[j] if j < len(toks.texts) else len(text)
                self.hunks.append((k, h["new_start"], h["new_end"], gap, self.line(s), self.line(max(s, e - 1))))
        self.walls, self.begins = [], []
        for m in WALL.finditer(texdiff.blank_comments(text)):
            (self.begins if m.group(1) == "begin" else self.walls).append(self.line(m.start()))

    def line(self, offset):
        """The 1-based line of an offset."""
        return bisect.bisect_right(self.starts, offset)

    def walled(self, a, b):
        """Whether a wall lies between lines a and b (both left out) for a note on line a: going up, the beginning of a
        float is one too."""
        lo, hi = min(a, b), max(a, b)
        for lines in (self.walls, self.begins) if b < a else (self.walls,):
            k = bisect.bisect_right(lines, lo)
            if k < len(lines) and lines[k] < hi:
                return True
        return False

    def nearest(self, p):
        """The indexes of diff.hunks next to a note whose % is at offset p. A note after text on its line: the changes
        in the sentences on that line (texdiff.sentence). A note on a line of its own: the nearest change within NEAR
        lines, not past a wall, in its paragraph (texdiff.paragraph; a comment line is no blank line), or below it when
        that paragraph holds only comments (a note between paragraphs); a note where a change took out a paragraph or
        more takes it. At the same distance one on or after the note's line goes before one above it, and changes
        still level are all taken."""
        text, line = self.text, self.line(p)
        ls = self.starts[line - 1]
        if text[ls:p].strip():  # the % at p is the line's first comment: what is before it is text
            ss, se = texdiff.sentence(text, *texdiff.trim(text, ls, p))
            return [k for k, s, e, _, _, _ in self.hunks if s <= se and e >= ss]
        ps, pe = texdiff.paragraph(text, p, p)
        alone = not texdiff.blank_comments(text[ps:pe]).strip()
        found = []
        for k, s, e, gap, first, last in self.hunks:
            if e < p <= gap:  # where the paragraphs it took out were
                found.append(((0, False), k))
                continue
            above = last < line
            d = line - last if above else max(first - line, 0)
            if d > NEAR or (alone and above) or not (alone or s <= pe and e >= ps) \
                    or d and self.walled(line, last if above else first):
                continue
            found.append(((d, above), k))
        best = min((key for key, _ in found), default=None)
        return [k for key, k in found if key == best]


def _joined(lines):
    """The texts of a note's lines [(file, line, text)] in source order: lines next to each other joined by a space,
    others by a line break; empty texts (a bare "% R1-03") and texts said before (a note copied) left out."""
    out, last, said = "", None, set()
    for f, n, text in lines:
        if text and text not in said:
            out += ("" if last is None else " " if last == (f, n - 1) else "\n") + text
            last = (f, n)
            said.add(text)
    return out


def _warning(kind, ids, file, line, comment, message):
    return {"kind": kind, "ids": ids, "file": file, "line": line, "text": comment, "message": message}


def _others(diff):
    """Warnings (not_tex) for the notes added or edited in round n in files whose notes are not read (OTHER: .bib,
    .sty, .cls), compared with the same file in round n−1's source."""
    out = []
    new_src, old_src = getattr(diff, "new_src", None), getattr(diff, "old_src", None)
    if new_src is None:  # a stand-in diff
        return out
    for path in sorted({p for pattern in OTHER for p in new_src.rglob(pattern) if p.is_file()}):
        rel = path.relative_to(new_src).as_posix()
        old = old_src / rel if old_src is not None else None
        seen = {tuple(got[0]) + (got[1],) for got in
                (parse(body) for _, body in comments_in(old.read_text(encoding="utf-8", errors="replace")))
                if got is not None and got[0]} if old is not None and old.is_file() else set()
        text = path.read_text(encoding="utf-8", errors="replace")
        starts = [0] + [m.end() for m in re.finditer("\n", text)]
        for p, body in comments_in(text):
            got = parse(body)
            if got is not None and got[0] and tuple(got[0]) + (got[1],) not in seen:
                out.append(_warning("not_tex", got[0], rel, bisect.bisect_right(starts, p), "%" + body.rstrip(),
                                    "Notes are read only in .tex files, so this note in {} is ignored.".format(rel)))
    return out


def find(diff, lg, n, changes):
    """Round n's notes ({comment id: note}) and warnings, from `diff` (texdiff, round n−1's source against round
    n's). A note counts when it is new in round n (below), and names a comment carried into round n in a .tex file the
    build reads; then {"text", "file", "line", "changes", "elsewhere", "lines"}: its lines in source order (_joined),
    where the first is, the ids of the changes next to its lines (_Source.nearest), those of them the comment had not
    been given by carry (outside its sentence), and each line with its changes. Those changes (`changes`: the round's,
    one per hunk of diff, in its order) are attached to the comment, which is also listed in their "student_notes".
    Any other note new in round n is a warning: {"kind": unknown, closed, malformed, unread or not_tex, "ids", "file",
    "line", "text": the comment as written, "message"}, in order of file and line.

    New in round n: a note (an ID and its text) that round n−1's tree did not hold in a file its build read, or held
    elsewhere (moved, or written again at a new place: texdiff's same_place) when it has a change next to it and names
    a carried comment. A note left where it was is not round n's, nor is one moved with no change next to it; their
    problems are not listed again. A note that was in a file the build did not read counts once it is in one it reads."""
    old_read = diff.old_read
    before, seen, bad_before = {}, set(), set()  # before: (id, text) -> [(file, offset)] in the files read
    for f, text in diff.old_texts.items():
        if not f.endswith(".tex"):
            continue
        read = old_read is None or f in old_read
        for p, body in comments_in(text):
            got = parse(body)
            if got is None:
                continue
            if not got[0] and read:
                bad_before.add(got[1])
            for cid in got[0]:
                seen.add((cid, got[1]))
                if read:
                    before.setdefault((cid, got[1]), []).append((f, p))
    carried = {c["id"] for c in ledger.carried_into(lg, n)}
    known = {c["id"]: c for c in lg["comments"]}
    lines, warnings = {}, []  # lines: comment id -> [(file, line, text, hunk indexes)]
    for f, text in sorted(diff.new_texts.items()):
        if not f.endswith(".tex"):
            continue
        src = None
        for p, body in comments_in(text):
            got = parse(body)
            if got is None:
                continue
            ids, note = got
            src = src or _Source(diff, f, text)
            line, comment = src.line(p), "%" + body.rstrip()
            if f in diff.unread:
                fresh = [cid for cid in ids if (cid, note) not in seen]
                if fresh:
                    warnings.append(_warning("unread", fresh, f, line, comment, "The paper does not use {} (the "
                                             "build does not read it), so this note is ignored.".format(f)))
                continue
            if not ids:
                if note not in bad_before:
                    warnings.append(_warning("malformed", [], f, line, comment, "This note's ID is not in the form "
                                             "R1-03, so it is ignored."))
                continue
            near = None
            for cid in ids:
                old = before.get((cid, note), [])
                if old and (cid not in carried or any(diff.same_place(of, q, f, p) for of, q in old)):
                    continue  # left as it was in an earlier round (or moved: its problems are not repeated)
                if cid in carried:
                    near = src.nearest(p) if near is None else near
                    if old and not near:
                        continue  # moved, with no change next to it
                    lines.setdefault(cid, []).append((f, line, note, near))
                elif cid in known:
                    k = max(known[cid]["rounds"], key=int)
                    verdict = known[cid]["rounds"][k]["verdict"]
                    warnings.append(_warning("closed", [cid], f, line, comment, "{} was closed in Round {}{}, so this "
                                             "note is ignored.".format(cid, k, " ({})".format(CLOSED_AS[verdict])
                                                                       if verdict in CLOSED_AS else "")))
                else:
                    warnings.append(_warning("unknown", [cid], f, line, comment,
                                             "There is no comment {}, so this note is ignored.".format(cid)))
    warnings = sorted(warnings + _others(diff), key=lambda w: (w["file"], w["line"]))
    notes = {}
    for cid, entries in lines.items():
        near = sorted({k for *_, ks in entries for k in ks})
        notes[cid] = {"text": _joined([e[:3] for e in entries]), "file": entries[0][0], "line": entries[0][1],
                      "changes": [changes[k]["id"] for k in near],
                      "elsewhere": [changes[k]["id"] for k in near if cid not in changes[k]["attached_to"]],
                      "lines": [{"file": f, "line": line, "changes": [changes[k]["id"] for k in ks]}
                                for f, line, _, ks in entries]}
        for k in near:
            ch = changes[k]
            ch["attached_to"] = sorted(set(ch["attached_to"]) | {cid}, key=ledger.id_key)
            ch["unrequested"] = False
            ch["student_notes"] = sorted(set(ch.get("student_notes", [])) | {cid}, key=ledger.id_key)
    return notes, warnings
