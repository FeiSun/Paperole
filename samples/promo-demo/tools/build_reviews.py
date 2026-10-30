"""Rebuild the promo demo's review folders from the student sources, through the engine CLI.

    engine/.venv/bin/python -I samples/promo-demo/tools/build_reviews.py OUT_DIR
    engine/.venv/bin/python -I samples/promo-demo/tools/build_reviews.py --takes DIR

OUT_DIR must not exist. It receives review/ (Maya Chen, open at round 2), others/leo-park/review (open at round 3)
and others/sara-okafor/review (round 1 closed), exactly as tools/reviews.json describes them. Use it to get a fresh
copy before each recording: answering comments in the app writes verdicts into the ledger.

--takes builds the promo's take folders (design/promo/STORYBOARD.md §7) in DIR, each from reviews.json; none of them
may exist yet:
  take-A/review  D1: Maya Chen's round 1 open with only R1-01 placed, so the comment made on camera becomes R1-02.
  take-B/        the three folders as above, but Leo Park's round 3 answered and finished (D3), so nothing waits on
                 the advisor once Maya's round 2 is finished.
  take-C/        take B with Maya's round 2 answered as the take answers it (D4: 10 resolved, 3 followed up, 1 kept
                 as is) and both unrequested edits checked: the state of the done card, right before Finish.
The engine's venv python is needed (PyMuPDF); the CLI runs LaTeX through latexmk as the app does."""
import copy
import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

import pymupdf

HERE = Path(__file__).resolve().parent
DEMO = HERE.parent
ENGINE = DEMO.parent.parent / "engine"
CLI = [str(ENGINE / ".venv" / "bin" / "python"), "-m", "paperole.cli"]  # the checkout's engine, on PYTHONPATH below

# D3: Leo Park's round 3 fixes all three open comments (student/r3), so all three are resolved.
LEO_R3 = [["R1-01", "verified", ""], ["R1-05", "verified", ""], ["R2-01", "verified", ""]]
# D4: Maya Chen's round 2 answered as take B answers it (STORYBOARD §2): R1-02, R1-03 and R1-05's follow-up on camera,
# the rest off camera. The Finish sheet then shows 3 follow-ups and 11 closed.
MAYA_R2 = [["R1-02", "verified", ""], ["R1-03", "verified", ""], ["R1-04", "verified", ""],
           ["R1-05", "reopened", "Still hard to parse. Split it in two."], ["R1-06", "verified", ""],
           ["R1-01", "verified", ""], ["R1-07", "verified", ""], ["R1-08", "verified", ""], ["R1-09", "verified", ""],
           ["R1-12", "verified", ""], ["R1-14", "verified", ""], ["R1-10", "reopened", "Algorithm 1 still uses τ."],
           ["R1-13", "reopened", "Still here, and still untested. Please delete it."], ["R1-11", "wontfix", ""]]


def run(*args):
    res = subprocess.run([*CLI, *map(str, args)], capture_output=True, text=True,
                         env=dict(os.environ, PYTHONPATH=str(ENGINE)))
    if res.returncode:
        raise SystemExit("paperole {} failed:\n{}".format(args[0], res.stderr))
    return json.loads(res.stdout)


def norm(word):
    return re.sub(r"[^0-9a-zͰ-Ͽ%@.+]", "", unicodedata.normalize("NFKC", word).lower()).strip(".")


def phrase_rects(page, phrase, xmin):
    """One rect per text line over the words of `phrase`, which must occur once on the page (the PDF's words; a
    word hyphenated across lines counts as one)."""
    words = [w for w in page.get_text("words") if w[0] > xmin]  # xmin skips the ICLR line-number ruler
    toks, target = [norm(w[4]) for w in words], [norm(t) for t in phrase.split() if norm(t)]
    hits = []
    for i in range(len(toks)):
        j, k = i, 0
        while k < len(target) and j < len(toks):
            if not toks[j]:
                j += 1
            elif toks[j] == target[k]:
                j, k = j + 1, k + 1
            elif j + 1 < len(toks) and toks[j] + toks[j + 1] == target[k]:
                j, k = j + 2, k + 1
            else:
                break
        if k == len(target):
            hits.append((i, j))
    if len(hits) != 1:
        raise SystemExit("{!r} is on page {} {} times".format(phrase, page.number, len(hits)))
    lines = {}
    for w in words[hits[0][0]:hits[0][1]]:
        r = lines.setdefault((w[5], w[6]), list(w[:4]))
        r[:] = [min(r[0], w[0]), min(r[1], w[1]), max(r[2], w[2]), max(r[3], w[3])]
    rects = sorted(lines.values(), key=lambda r: (round(r[1]), r[0]))
    return [[round(v, 2) for v in r] for r in rects], " ".join(w[4] for w in words[hits[0][0]:hits[0][1]])


def line_y(page, start, edge, xmin):
    """The top or bottom of the first text line that starts with `start`."""
    for b in page.get_text("dict")["blocks"]:
        for line in b.get("lines", []):
            if "".join(s["text"] for s in line["spans"]).strip().startswith(start) and line["bbox"][0] > xmin:
                return line["bbox"][3] if edge == "bottom" else line["bbox"][1]
    raise SystemExit("no line starts with {!r} on page {}".format(start, page.number))


def band_rect(page, band, xmin):
    """The box around what a page prints between two lines: text spans and drawings, padded."""
    top = band.get("top")
    y0 = 60.0 if top is None else line_y(page, top[1], "bottom" if top[0] == "after" else "top", xmin) + \
        (1 if top[0] == "after" else -1)
    y1 = line_y(page, band["bottom"], "top", xmin) - band.get("gap", 1)
    x0, x1, right = band.get("x0", 100), band.get("x1", 520), band.get("skip_right")
    boxes = [s["bbox"] for b in page.get_text("dict")["blocks"] for line in b.get("lines", []) for s in line["spans"]
             if s["text"].strip()]
    boxes += [tuple(d["rect"]) for d in page.get_drawings()]
    boxes = [bx for bx in boxes if bx[1] >= y0 and bx[3] <= y1 and bx[0] >= x0 and bx[2] <= x1
             and (right is None or bx[0] < right)]
    if not boxes:
        raise SystemExit("nothing printed between {} and {} on page {}".format(y0, y1, page.number))
    # pad_x: a box drawn wider than what it holds (R1-08: the engine carries a box at its round-1 width, and round 2's
    # Eq. (3) is wider, so a tight box would cut it in round 2's crop)
    pad = band.get("pad", 3.0)
    pad_x = band.get("pad_x", pad)
    return [round(v, 2) for v in (min(b[0] for b in boxes) - pad_x, min(b[1] for b in boxes) - pad,
                                  max(b[2] for b in boxes) + pad_x, max(b[3] for b in boxes) + pad)]


def comment(paper, pdf, c, xmin):
    page = pdf[c["page"]]
    if "phrase" in c:
        rects, words = phrase_rects(page, c["phrase"], xmin)
    else:
        rects, words = [band_rect(page, c["band"], xmin)], ""
    r = run("comment", paper, "--page", c["page"], "--rects", ";".join(",".join(map(str, x)) for x in rects),
            "--text", words, "--note", c["note"], "--kind", c["kind"], "--color", c["color"],
            "--tags", ",".join(c["tags"]))
    return r["id"]


def build(out, specs, label=""):
    for spec in specs:
        paper = out / spec["folder"]
        paper.parent.mkdir(parents=True, exist_ok=True)
        run("new", paper, "--title", spec["title"], "--student", spec["student"])
        for rnd in spec["rounds"]:
            state = run("ingest", paper, DEMO / rnd["source"])["state"]
            for cid, verdict, note in rnd.get("verdicts", []):
                run("verdict", paper, cid, verdict, "-m", note)
            if rnd.get("check_edits"):
                for ch in state["changes"]:
                    if ch["unrequested"]:
                        run("check", paper, ch["id"])
            pdf = pymupdf.open(state["round"]["build"]["pdf"])
            for c in rnd.get("comments", []):
                expected = c.get("id")
                cid = comment(paper, pdf, c, spec.get("xmin", 100))
                if expected and cid != expected:
                    raise SystemExit("{}: got {} for the comment meant to be {}".format(paper, cid, expected))
            if rnd.get("finish"):
                run("finish", paper)
        s = run("state", paper)["state"]
        print("{}{}: round {} {}, {} comments, {} to answer, {} edits to check".format(
            label, spec["folder"], s["round"]["n"], "closed" if s["round"]["closed"] else "open", len(s["comments"]),
            s["summary"]["to_judge"], s["summary"]["to_check"]))


def takes(specs):
    """The take folders' specs (STORYBOARD §7): reviews.json with D1, D3 and D4 applied."""
    def find(group, folder):
        return next(s for s in group if s["folder"] == folder)
    a = copy.deepcopy(find(specs, "review"))
    a["rounds"] = a["rounds"][:1]
    a["rounds"][0]["comments"] = [c for c in a["rounds"][0]["comments"] if c["id"] == "R1-01"]
    a["rounds"][0].pop("finish", None)
    b = copy.deepcopy(specs)
    find(b, "others/leo-park/review")["rounds"][-1].update(verdicts=LEO_R3, finish=True)
    c = copy.deepcopy(b)
    find(c, "review")["rounds"][-1].update(verdicts=MAYA_R2, check_edits=True)
    return {"take-A": [a], "take-B": b, "take-C": c}


def main():
    args = sys.argv[1:]
    specs = json.load(open(HERE / "reviews.json", encoding="utf-8"))
    if len(args) == 2 and args[0] == "--takes":
        root = Path(args[1]).resolve()
        jobs = [(root / name, s, name + "/") for name, s in takes(specs).items()]
    elif len(args) == 1 and not args[0].startswith("-"):
        jobs = [(Path(args[0]).resolve(), specs, "")]
    else:
        raise SystemExit(__doc__)
    for out, _, _ in jobs:
        if out.exists():
            raise SystemExit("{} exists; give a new folder.".format(out))
    for out, s, label in jobs:
        build(out, s, label)


if __name__ == "__main__":
    main()
