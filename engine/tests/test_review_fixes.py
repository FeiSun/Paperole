"""Fixes from the engine and visual reviews of 2026-10-17, each on a small synthetic paper: \\input lines next to each
other (restored, added, dropped last or merged with an edit), sections replaced or taken out in other ways, sentence
ends after words like "ms." and "Appendix A.", carried click notes on re-wrapped text, leaders and chips beside a
dense margin ruler, and words that macros print."""
import pymupdf

from conftest import select
from paperole import anchor, cards, ledger, prose, render, texdiff
from test_backlog_accuracy import (INPUTS, PARAGRAPHS, SECTIONS, _build, _call, _carry, _item, _paper, _unread,
                                   _versions, pytestmark)  # noqa: F401  (pytestmark: needs latexmk and synctex)


def _point_at_start(rect, page, word):
    """Whether a change or gone comment's rect is a point at the start of the line that starts with `word`."""
    hit = page.search_for(word)[0]
    return rect[2] - rect[0] == anchor.POINT_WIDTH and abs(rect[0] - hit.x0) < 1 and abs(rect[1] - hit.y0) < 4


def _three_rounds(tmp_path, bodies, phrase):
    """A review over three versions of main.tex (with SECTIONS; the verbatim package for its comment environment)
    and a comment on `phrase` in round 1: (paper, state of round 2, state of round 3)."""
    paper, sources = _paper(tmp_path, bodies, "\\documentclass{article}\n\\usepackage{verbatim}\n",
                            files=[SECTIONS] * len(bodies))
    _call(paper, "ingest", source=str(sources[0]))
    pdf = paper / "r1" / "build" / "main.pdf"
    _call(paper, "comment", page=0, rects=select(pdf, 0, phrase), text=phrase, note="Cite them.", kind="highlight")
    _call(paper, "finish")
    s2 = _call(paper, "ingest", source=str(sources[1]))["state"]
    _call(paper, "finish")
    s3 = _call(paper, "ingest", source=str(sources[2]))["state"] if len(sources) > 2 else None
    return paper, s2, s3


def test_a_section_put_back_between_two_inputs_comes_back(tmp_path):
    """A section whose \\input sits between two others, commented out in round 2 and put back in round 3: the change
    is the whole \\input line, a point at the start of the section; its paragraphs are unread; and its comment is
    back on its sentence (was: the hunk "related} \\input{sections/" was drawn over the page number, the section got
    no bar, and the comment stayed changed on that line)."""
    dropped = INPUTS.replace("\\input{sections/related}", "% \\input{sections/related}")
    paper, s2, s3 = _three_rounds(tmp_path, [INPUTS, dropped, INPUTS], "Prior work keeps every instance")
    [c2], [ch2] = s2["comments"], s2["changes"]
    assert (c2["anchor_state"], c2["file"], c2["page"]) == ("gone", "main.tex", 0)
    assert ch2["old_text"] == "\\input{sections/related}"
    [c3], [ch3] = s3["comments"], s3["changes"]
    assert (c3["anchor_state"], c3["file"], c3["text"]) == ("moved", "sections/related.tex",
                                                            "Prior work keeps every instance")
    assert ch3["new_text"] == "\\input{sections/related}" and ch3["attached_to"] == [c3["id"]]
    page = pymupdf.open(paper / "r3" / "build" / "main.pdf")[0]
    [r] = ch3["rects"]
    assert _point_at_start(r, page, "Related Work")
    data = prose.load(paper, 3)
    assert {data["blocks"][k]["file"] for k in _unread(s3)} == {"sections/related.tex"} and not ch3["read"]


def test_a_section_dropped_in_one_hunk_with_a_renamed_input_comes_back(tmp_path):
    """The \\input of a section commented out while the next \\input is renamed (one hunk, "related}
    \\input{sections/method" → "method2"): its comment is gone at the start of the next section, and back on its
    sentence when the \\input is put back before the renamed one (was: changed on the \\input line)."""
    renamed = dict(SECTIONS, **{"sections/method2.tex": SECTIONS["sections/method.tex"]})
    del renamed["sections/method.tex"]
    body = INPUTS.replace("sections/method", "sections/method2")
    paper, sources = _paper(tmp_path, [INPUTS, body.replace("\\input{sections/related}", "% \\input{sections/related}"),
                                       body], files=[SECTIONS, renamed, renamed])
    _call(paper, "ingest", source=str(sources[0]))
    phrase = "Prior work keeps every instance"
    _call(paper, "comment", page=0, rects=select(paper / "r1" / "build" / "main.pdf", 0, phrase), text=phrase,
          note="Cite them.", kind="highlight")
    states = []
    for src in sources[1:]:
        _call(paper, "finish")
        states.append(_call(paper, "ingest", source=str(src))["state"])
    [c2], [c3] = states[0]["comments"], states[1]["comments"]
    assert (c2["anchor_state"], c2["page"]) == ("gone", 0)
    assert _point_at_start(c2["rects"][0], pymupdf.open(paper / "r2" / "build" / "main.pdf")[0], "Method")
    assert (c3["anchor_state"], c3["file"], c3["text"]) == ("moved", "sections/related.tex", phrase)


def test_a_file_read_by_a_section_put_back_comes_back_too(tmp_path):
    """A comment in a file that a dropped section reads (a figure's or a subsection's file) comes back with the section,
    on the words it was on (was: changed, drawn on the \\input line's synctex place)."""
    files = dict(SECTIONS, **{"sections/related.tex": SECTIONS["sections/related.tex"] + "\\input{sections/nested}\n",
                              "sections/nested.tex": "A nested paragraph reuses idle instances across tenants.\n"})
    dropped = INPUTS.replace("\\input{sections/related}", "% \\input{sections/related}")
    paper, sources = _paper(tmp_path, [INPUTS, dropped, INPUTS], files=[files] * 3)
    _call(paper, "ingest", source=str(sources[0]))
    pdf = paper / "r1" / "build" / "main.pdf"
    phrase = "reuses idle instances across tenants."
    _call(paper, "comment", page=0, rects=select(pdf, 0, phrase), text=phrase, note="Which ones?", kind="highlight")
    for src in sources[1:]:
        _call(paper, "finish")
        [c] = _call(paper, "ingest", source=str(src))["state"]["comments"]
    assert (c["anchor_state"], c["file"], c["text"]) == ("moved", "sections/nested.tex", phrase)


def test_a_new_input_between_two_others_is_a_point_at_its_section(tmp_path):
    """An \\input of a new section file added between two \\input lines is one change, a point at the start of the
    new section (was: drawn over the page number)."""
    files = dict(SECTIONS, **{"sections/background.tex": "\\section{Background}\nA new background section explains "
                              "how platforms keep instances warm today.\n"})
    added = INPUTS.replace("\\input{sections/related}", "\\input{sections/background}\n\\input{sections/related}")
    old, new = _versions(tmp_path, [(INPUTS, SECTIONS), (added, files)])
    _, changes = _carry(old, new, [])
    [line] = [c for c in changes if c["file"] == "main.tex"]
    assert line["new_text"] == "\\input{sections/background}"
    assert line["page"] == 0 and _point_at_start(line["rects"][0], pymupdf.open(new[1])[0], "Background")


TAIL = "\\appendix\n\\section{Extra}\nAn appendix paragraph.\n"


def _end_of_related(rect, pdf):
    """Whether a rect is a point just after "idle times." (the last line of the Related Work section)."""
    hit = pymupdf.open(pdf)[0].search_for("idle times.")[0]
    return rect[2] - rect[0] == anchor.POINT_WIDTH and abs(rect[0] - hit.x1) < 1.5 and abs(rect[1] - hit.y0) < 4


def test_a_gone_point_where_the_last_section_was(tmp_path):
    """A comment in the last section, dropped with its \\input (nothing after it, or only \\appendix), is a gone
    point after the end of the section before it; so is one whose \\input's removal merged with an edit of the
    \\input before it into one hunk (was: a highlight over the page number, the appendix heading or an unrelated
    line)."""
    renamed = dict(SECTIONS, **{"sections/background.tex": SECTIONS["sections/related.tex"]})
    del renamed["sections/related.tex"]
    for k, (old_body, new_body, files) in enumerate([
            (INPUTS, INPUTS.replace("\\input{sections/method}", "% \\input{sections/method}"), SECTIONS),
            (INPUTS + TAIL, INPUTS.replace("\\input{sections/method}", "% \\input{sections/method}") + TAIL, SECTIONS),
            (INPUTS, INPUTS.replace("related}\n\\input{sections/method}", "background}\n"), renamed)]):
        old, new = _versions(tmp_path / str(k), [(old_body, SECTIONS), (new_body, files)])
        records, changes = _carry(old, new, [_item(old[0], "sections/method.tex", "sizes the warm pool")])
        r = records["R1-01"]
        assert r["anchor_state"] == "gone" and r["anchor"]["page"] == 0, (k, r)
        [rect] = r["anchor"]["rects"]
        assert _end_of_related(rect, new[1]), (k, rect)
    # the merged hunk says what happened to each file it reads
    diff = texdiff.diff_trees(old[0], new[0], old[1].parent, new[1].parent)
    [line] = [c for c in cards.describe(old[0], old[1], new[0], new[1], diff, changes) if c["file"] == "main.tex"]
    assert line["about"]["text"] == "Section file sections/related.tex renamed to sections/background.tex; " \
                                    "Section file sections/method.tex removed"


def test_to_pdf_draws_a_point_that_prints_nothing_as_a_point(tmp_path):
    """A point on a line that prints nothing and has no word before it is a point, not the line's boxes (synctex
    gives the line of an \\input at the end of a page the page number)."""
    src, pdf = _build(tmp_path, INPUTS, files=SECTIONS)
    text = (src / "main.tex").read_text()
    at = text.index("\\input{sections/method}") + len("\\input{sections/method}")
    page, rects, _ = anchor.to_pdf(src, pdf, "main.tex", at, at)
    assert page is not None and all(r[2] - r[0] <= anchor.POINT_WIDTH for r in rects)


LIMITS = ("\\section{Limitations}\nOur forecaster assumes that the arrival process of each function is stationary "
          "over a few minutes.\nIt also needs a trace of at least one day before it can size the pool well.\n"
          "We did not evaluate the controller on functions that are called less than once per hour.\n")
ETHICS = ("\\section{Ethics Statement}\nThis work uses only traces that the provider released for research, and no "
          "trace holds personal data of the users of the platform.\nWe release our code so that others can check the "
          "results and use the controller on their own platforms.\nThe energy that the experiments used is small "
          "compared with the energy that the warm pools of a large provider use in a day, and the controller reduces "
          "that energy when it sizes the pool well.\nWe see no risk that the work could be used to harm the users of a "
          "platform, since it only changes how many instances are kept warm for each function.\n")


def test_a_section_replaced_by_another_at_its_input_is_no_rename(tmp_path):
    """A section file replaced by a different, longer one at the same \\input shares half its words with it (any two
    sections of a paper do) but few runs of four: it is no rename, and comments on the old one are gone (was:
    "renamed", and the comments changed on unrelated sentences of the new file)."""
    files = [dict(SECTIONS, **{"sections/limits.tex": LIMITS}), dict(SECTIONS, **{"sections/ethics.tex": ETHICS})]
    body = INPUTS.replace("sections/related", "sections/limits")
    old, new = _versions(tmp_path, [(body, files[0]), (body.replace("sections/limits", "sections/ethics"), files[1])])
    diff = texdiff.diff_trees(old[0], new[0], old[1].parent, new[1].parent)
    assert diff.renamed == {}
    records, changes = _carry(old, new, [_item(old[0], "sections/limits.tex", "arrival process of each function")])
    assert records["R1-01"]["anchor_state"] == "gone"
    assert any("replaced by" in (c.get("about") or {}).get("text", "") for c in
               cards.describe(old[0], old[1], new[0], new[1], diff, changes))


DROPS = {  # how the student takes the Related Work section out: (round 1 and 3 main body, round 2 main body)
    "./ in the name": (INPUTS.replace("{sections/", "{./sections/"),
                       INPUTS.replace("{sections/", "{./sections/").replace("\\input{./sections/related}",
                                                                            "% \\input{./sections/related}")),
    "no braces": (INPUTS.replace("\\input{", "\\input ").replace("}", ""),
                  INPUTS.replace("\\input{", "\\input ").replace("}", "").replace("\\input sections/related",
                                                                                  "% \\input sections/related")),
    "iffalse": (INPUTS, INPUTS.replace("\\input{sections/related}", "\\iffalse\n\\input{sections/related}\n\\fi")),
    "comment environment": (INPUTS, INPUTS.replace("\\input{sections/related}",
                                                   "\\begin{comment}\n\\input{sections/related}\n\\end{comment}")),
}


def test_a_section_taken_out_in_other_ways_is_gone_and_comes_back(tmp_path):
    """A section taken out with "./" in its \\input's name, an \\input without braces, \\iffalse … \\fi or a comment
    environment: its comment is gone at the start of the section after it, and back on its sentence when the
    section is put back (was: unchanged, without a page)."""
    for k, (name, (body, dropped)) in enumerate(DROPS.items()):
        root = tmp_path / str(k)
        root.mkdir()
        paper, s2, s3 = _three_rounds(root, [body, dropped, body], "Prior work keeps every instance")
        [c2] = s2["comments"]
        assert (c2["anchor_state"], c2["file"], c2["page"]) == ("gone", "main.tex", 0), name
        assert _point_at_start(c2["rects"][0], pymupdf.open(paper / "r2" / "build" / "main.pdf")[0], "Method"), name
        [c3] = s3["comments"]
        assert (c3["anchor_state"], c3["file"]) == ("moved", "sections/related.tex"), name
        data = prose.load(paper, 3)
        assert {data["blocks"][k]["file"] for k in _unread(s3)} == {"sections/related.tex"}, name


def test_a_comment_in_a_dropped_section_is_not_matched_elsewhere(tmp_path):
    """A comment in a section the student drops is gone even when another section has a sentence much like it (was:
    a fuzzy match moved it there as changed); an edit inside the dropped file prints nothing and is no change to
    check."""
    files = dict(SECTIONS, **{"sections/related.tex": "\\section{Related Work}\nOur controller sizes the warm pool "
                              "from a forecast of the requests.\nOthers predict the next request from idle times.\n"})
    edited = dict(files, **{"sections/related.tex": files["sections/related.tex"].replace("Others", "Many others")})
    old, new = _versions(tmp_path, [(INPUTS, files), (INPUTS.replace("\\input{sections/related}",
                                                                     "% \\input{sections/related}"), edited)])
    records, changes = _carry(old, new, [_item(old[0], "sections/related.tex", "Our controller sizes the warm pool "
                                               "from a forecast of the requests.")])
    assert records["R1-01"]["anchor_state"] == "gone"
    assert [c["file"] for c in changes] == ["main.tex"]


def test_sentence_ends_after_words_that_can_end_one():
    """In the source, "12 ms.", "Appendix A.", "app.", "no." and "variant B." end a sentence before the next one
    (was: taken for abbreviations, so an edit in the next sentence changed a comment on them); "Sect. 3", "J.
    Smith", "Fig. 2", "e.g. BERT", "Sec. 4" and "et al. (2020)" do not."""
    for text, phrase, sentence in [
            ("The tail latency stays below 12 ms. It resizes the pool.", "tail", "The tail latency stays below 12 ms."),
            ("The proofs are in Appendix A. The controller resizes.", "proofs", "The proofs are in Appendix A."),
            ("We used a small mobile app. The traces are public.", "small", "We used a small mobile app."),
            ("Our answer is no. The controller resizes.", "answer", "Our answer is no."),
            ("We call it variant B. The controller resizes.", "call", "We call it variant B."),
            ("See Sect. 3 and the work of J. Smith on pools. Next.", "See", "See Sect. 3 and the work of J. Smith on "
                                                                           "pools."),
            ("As Fig. 2 shows, models such as e.g. BERT help. Next.", "As", "As Fig. 2 shows, models such as e.g. "
                                                                            "BERT help."),
            ("Lee et al. (2020) and Sec. 4 say so. Next.", "Lee", "Lee et al. (2020) and Sec. 4 say so."),
            ("This follows Lee et al. We go on.", "follows", "This follows Lee et al.")]:
        s = text.index(phrase)
        assert text[slice(*texdiff.sentence(text, s, s + len(phrase)))] == sentence, text
    for word, nxt, ends in [("ms.", "It", True), ("J.", "Smith", False), ("A.", "The", True), ("Sec.", "3", False),
                            ("App.", "B", False), ("al.", "We", True), ("al.", "(2020)", False)]:
        assert cards._ends(word, nxt) == ends, (word, nxt)


SENTENCES = ["Serverless platforms start a fresh sandbox for every cold invocation of a function.",
             "The delay this adds is the main complaint of developers who run latency sensitive services on them.",
             "Keeping instances warm hides the delay but costs memory that other tenants could use instead.",
             "A simple keepalive policy holds every instance for a fixed window after its last request.",
             "It is cheap to run and easy to explain to the operators of the platform and to its users.",
             "Yet it wastes memory on functions that are called rarely and still misses many cold starts.",
             "Our controller sizes the warm pool from a short forecast of the arrival rate instead."]
ADDED = ["An opening sentence that the student added pushes the rest of the paragraph down by about a line.",
         "A second added sentence moves it down again by roughly another full line of text on the page."]


def test_a_carried_click_note_follows_its_line_when_the_text_rewraps(tmp_path):
    """A note clicked in the margin beside a line of a paragraph written a sentence per line stays in the margin,
    level with the words of that line, after sentences are inserted before it and the paragraph wraps anew (was: as
    far from the end of the range's k-th rect as before, on top of words or beside another line)."""
    paper, (v1, v2) = _paper(tmp_path, ["\n".join(SENTENCES) + "\n", "\n".join(ADDED + SENTENCES) + "\n"])
    _call(paper, "ingest", source=str(v1))
    page = pymupdf.open(paper / "r1" / "build" / "main.pdf")[0]
    hit = page.search_for("wastes memory on functions")[0]
    y = (hit.y0 + hit.y1) / 2
    _call(paper, "comment", page=0, rects=[[545, y, 545, y]], text="", note="Which ones?", kind="note")
    last = page.search_for("rate instead.")[0]  # a click just after the paragraph's last word, inside the column
    _call(paper, "comment", page=0, rects=[[last.x1 + 10, last.y0 + 4, last.x1 + 10, last.y0 + 4]], text="",
          note="Say how often.", kind="note")
    _call(paper, "finish")
    c, d = _call(paper, "ingest", source=str(v2))["state"]["comments"]
    [r] = c["rects"]
    now = pymupdf.open(paper / "r2" / "build" / "main.pdf")[0]
    line = [w for w in now.get_text("words") if w[1] - 0.5 <= r[1] <= w[3] + 0.5]
    assert r[0] == r[2] == 545 and line and any(w[4] == "wastes" for w in line), (r, [w[4] for w in line])
    end = now.search_for("rate instead.")[0]  # as far from the line's end as it was (the line is shorter or longer)
    assert end.x1 != last.x1 and abs(d["rects"][0][0] - (end.x1 + 10)) < 1 and end.y0 <= d["rects"][0][1] <= end.y1


# A dense margin ruler close to the text, as ICML's submission mode and ACM's review mode set it: numbers about 2 pt
# apart, 14 pt from the text on both sides of the page (a twocolumn article with eso-pic).
DENSE = r"""\usepackage{eso-pic}
\newcount\rulerline
\AddToShipoutPicture{\AtTextUpperLeft{\rulerline=0
  \loop\ifnum\rulerline<55
    \put(-14,-\the\numexpr12*\rulerline+9\relax){\makebox(0,0)[r]{\normalsize\the\numexpr100+\rulerline\relax}}%
    \put(\the\numexpr\textwidth/65536+14\relax,-\the\numexpr12*\rulerline+9\relax){\makebox(0,0)[l]{%
      \normalsize\the\numexpr200+\rulerline\relax}}%
    \advance\rulerline 1
  \repeat}}
"""
ZONES = "amber basalt cedar dune ember fjord garnet harbor indigo jasper kelp lagoon".split()
ZONE = ("In the {0} zone, serverless platforms start a fresh sandbox for every cold invocation. Requests in the {0} "
        "zone are short and arrive in bursts. A keep-alive policy for the {0} zone holds each instance for a fixed "
        "window after its last request.")


def test_leaders_and_chips_beside_a_dense_ruler_close_to_the_text(tmp_path):
    """Beside a ruler whose numbers are 2 pt apart and close to the text, a chip goes past the ruler (it covered a
    number), and every leader stays within a line of its chip and touches no number (was: leaders ran along the
    whole ruler, up to 321 pt, to pass above or below it; chips covered numbers)."""
    paper, (src,) = _paper(tmp_path, ["\n\n".join(ZONE.format(z) for z in ZONES) + "\n"],
                           "\\documentclass[twocolumn]{article}\n" + DENSE)
    pdf = _call(paper, "ingest", source=str(src))["state"]["round"]["build"]["pdf"]
    build = pymupdf.open(pdf)[0]
    numbers = [w for w in build.get_text("words") if w[4].isdigit() and len(w[4]) == 3]
    left = sorted((w for w in numbers if w[0] < 300), key=lambda w: w[1])
    gaps = sorted(b[1] - a[3] for a, b in zip(left, left[1:]))
    assert len(numbers) > 60 and 0 < gaps[len(gaps) // 2] < 2.5, gaps  # numbers set about 2 pt apart
    ids = []
    for z in ZONES:
        try:
            rects = select(pdf, 0, "Requests in the {} zone".format(z))
        except AssertionError:
            continue
        ids.append(_call(paper, "comment", page=0, rects=rects, text="", note="Shorter.", kind="highlight")["id"])
    assert len(ids) >= 8
    placed = [p for p in render.final_pdf(paper, ledger.load(paper), 1, tmp_path / "final.pdf") if p["page"] == 0]
    dx = render.MARGIN
    boxes = [pymupdf.Rect(w[:4]) + (dx - 0.6, -0.6, dx + 0.6, 0.6) for w in numbers]  # 0.3 pt clear of the 0.6 pt line
    for p in placed:
        pts, chip = p["leader"], p["chip"]
        assert not any(_crosses(pts, b) for b in boxes), (p["id"], pts)
        assert all(abs(y - pts[0][1]) <= 12 for _, y in pts[:-1]), (p["id"], pts)
        assert not any(chip.intersects(b) for b in boxes), (p["id"], chip)


def _crosses(points, rect):
    """Whether a polyline comes inside rect (sampled every 0.2 pt)."""
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        steps = max(1, int(max(abs(x1 - x0), abs(y1 - y0)) / 0.2))
        if any(rect.contains(pymupdf.Point(x0 + (x1 - x0) * k / steps, y0 + (y1 - y0) * k / steps))
               for k in range(steps + 1)):
            return True
    return False


def test_gap_between_numbers_set_two_points_apart():
    """render._gap over the ink of line numbers (render._ink): numbers whose boxes are 1.94 pt apart leave a gap
    near the chip (was: the leader went above or below the whole ruler)."""
    words = [(20, 100 + 9.9 * k, 34, 108 + 9.9 * k, "{:03d}".format(k)) for k in range(30)]  # 7.96 high, 1.94 apart
    y = render._gap([(r.y0, r.y1) for r in map(render._ink, words)], 150)
    assert abs(y - 150) < 9.9 and not any(w[1] - 0.3 < y < w[3] + 0.3 for w in words)


CHECKLIST = "\\newcommand{\\answerYes}{[Yes]}\n\\newcommand{\\answerTODO}{[TODO]}\n"


def test_words_a_macro_prints_are_the_change(tmp_path):
    """A checklist answer changed from \\answerTODO to \\answerYes (NeurIPS) prints "[TODO]" and "[Yes]", which the
    source does not have: the change's contexts mark those words, and its line in the summary and the margin says
    them, with no LaTeX (was: "\\answerTODO" → "\\answerYes", and "Same words in the PDF" in the app)."""
    body = PARAGRAPHS + "\n\\paragraph{Checklist.} Does the paper state its claims? Answer: ANSWER\n"
    paper, (v1, v2) = _paper(tmp_path, [body.replace("ANSWER", "\\answerTODO"), body.replace("ANSWER", "\\answerYes")],
                             "\\documentclass{article}\n" + CHECKLIST)
    _call(paper, "ingest", source=str(v1))
    _call(paper, "finish")
    [ch] = _call(paper, "ingest", source=str(v2))["state"]["changes"]
    before, now = ch["context"]["before"], ch["context"]["now"]
    assert [before["text"][a:b] for a, b in before["sel"]] == ["TODO"]
    assert [now["text"][a:b] for a, b in now["sel"]] == ["Yes"]
    line = render._change_text(ch)
    assert "\\" not in line and "TODO" in line and "Yes" in line, line
    render.final_pdf(paper, ledger.load(paper), 2, tmp_path / "final.pdf")
    doc = pymupdf.open(tmp_path / "final.pdf")
    assert "\\" not in "".join(page.get_text() for page in doc), "LaTeX in final.pdf"


def test_a_sentence_after_a_footnote_is_drawn_on_its_own_words(tmp_path):
    """A sentence on the source line after one that closes a footnote is drawn on its own words (was: on the
    footnote's, at the page's foot: synctex gives that line boxes there too, and they were taken as the line's
    neighbours)."""
    body = PARAGRAPHS + ("\nThe predictor is a logistic regression on three features of the draft model, and the "
                         "number of tokens accepted in the previous step.\\footnote{We also tried a two-layer "
                         "network on the model's last hidden state. It was more\naccurate but five times slower, which "
                         "cancelled "
                         "its benefit.}\nThe predictor has seven parameters and is fitted once per model pair on 2,000 "
                         "prompts.\n\nA closing paragraph follows.\n")
    src, pdf = _build(tmp_path, body, "\\documentclass[twocolumn]{article}\n")
    text = (src / "main.tex").read_text()
    sentence = "The predictor has seven parameters and is fitted once per model pair on 2,000 prompts."
    s = text.index(sentence)
    _, rects, words = anchor.to_pdf(src, pdf, "main.tex", s, s + len(sentence))
    assert words == sentence, words
