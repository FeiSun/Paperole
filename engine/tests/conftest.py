"""Shared fixtures for the engine tests: a round-1 paper built from the fixture paper, PDF selections, and an
`rpc` engine process."""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pymupdf
import pytest

# The engine tested is this checkout's (engine/paperole), not one installed in the Python that runs the tests, here and
# in the engines the tests start (`-m paperole.cli`).
ENGINE = str(Path(__file__).resolve().parent.parent)
sys.path.insert(0, ENGINE)
os.environ["PYTHONPATH"] = os.pathsep.join([ENGINE] + [p for p in [os.environ.get("PYTHONPATH")] if p])

from paperole import api  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "paper"
TITLE = "Predictive Warm Pools for Serverless Cold-Start Reduction"


def quiet(message):
    pass


def select(pdf, page, phrase):
    """Rects of the consecutive PDF words spelling phrase, one per text line (like PDFKit's selectionsByLine)."""
    words = pymupdf.open(pdf)[page].get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP)
    target = phrase.split()
    for i in range(len(words) - len(target) + 1):
        if [w[4] for w in words[i:i + len(target)]] == target:
            lines = {}
            for x0, y0, x1, y1, _, block, line, _ in words[i:i + len(target)]:
                r = lines.get((block, line), [x0, y0, x1, y1])
                lines[(block, line)] = [min(r[0], x0), min(r[1], y0), max(r[2], x1), max(r[3], y1)]
            return [[round(v, 2) for v in r] for r in lines.values()]
    raise AssertionError("not in the PDF: " + phrase)


def burned(page, rects, dx=0):
    """The comment marks burned into a final.pdf page over an anchor's rects (moved right by dx, a left margin):
    {(kind, colour)}, kind highlight (a filled rect), underline or strikeout (a line low in or across a rect), box
    (a stroked rect), note (a filled dot) or cross (diagonal lines: a deletion); colour rounded to 2 decimals.
    final.pdf has no comment annotations, so this is how a test reads a mark's kind and colour."""
    out = set()
    for r in rects:
        r = pymupdf.Rect(r) + (dx - 1, -1, dx + 1, 1)
        for d in page.get_drawings():
            b = d["rect"]
            if b.x1 < r.x0 or b.x0 > r.x1 or b.y1 < r.y0 or b.y0 > r.y1:
                continue
            ops = {item[0] for item in d["items"]}
            colour = d.get("fill") if d["type"] == "f" else d.get("color")
            if not colour:
                continue
            if d["type"] == "f":
                kind = "note" if "c" in ops else "highlight"
            elif ops == {"re"}:
                kind = "box"
            elif ops == {"l"}:
                kind = ("cross" if b.height > 1 else
                        "underline" if b.y0 > r.y0 + 0.75 * r.height else "strikeout")
            else:
                continue
            out.add((kind, tuple(round(v, 2) for v in colour)))
    return out


def history(c):
    """A state comment's history without the per-round page and context."""
    return [{k: h[k] for k in ("round", "anchor_state", "verdict", "verdict_note")} for h in c["history"]]


def equation_rect(pdf, page, first_word):
    """The box around the words on the baseline of first_word (a display equation line)."""
    words = pymupdf.open(pdf)[page].get_text("words", flags=pymupdf.TEXT_MEDIABOX_CLIP)
    w0 = next(w for w in words if w[4] == first_word)
    line = [w for w in words if abs((w[1] + w[3]) / 2 - (w0[1] + w0[3]) / 2) < 6]
    return [round(min(w[0] for w in line), 2), round(min(w[1] for w in line), 2),
            round(max(w[2] for w in line), 2), round(max(w[3] for w in line), 2)]


@pytest.fixture(scope="session")
def round1_template(tmp_path_factory):
    """A paper with round 1 (fixture v1) ingested and no comments. Copy it before changing it."""
    paper = tmp_path_factory.mktemp("template") / "paper"
    api.new({"paper": str(paper), "title": TITLE, "student": "Lin Zhou"}, quiet)
    api.ingest({"paper": str(paper), "source": str(FIXTURE / "v1")}, quiet)
    return paper


@pytest.fixture
def paper(round1_template, tmp_path):
    dest = tmp_path / "paper"
    shutil.copytree(round1_template, dest)
    return dest


class Engine:
    def __init__(self):
        self.proc = subprocess.Popen([sys.executable, "-m", "paperole.cli", "rpc"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.next_id = 0
        self.events = []

    def send(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def reply(self, rid):
        while True:
            msg = json.loads(self.proc.stdout.readline())  # every stdout line is protocol JSON
            if msg.get("event") == "progress":
                assert msg["id"] == rid and isinstance(msg["message"], str)
                self.events.append(msg["message"])
                continue
            assert msg["id"] == rid
            return msg

    def call(self, method, **params):
        self.next_id += 1
        self.send(json.dumps({"id": self.next_id, "method": method, "params": params}, ensure_ascii=False))
        msg = self.reply(self.next_id)
        assert "result" in msg, msg
        assert "state" in msg["result"]
        return msg["result"]

    def error(self, method, **params):
        self.next_id += 1
        self.send(json.dumps({"id": self.next_id, "method": method, "params": params}, ensure_ascii=False))
        msg = self.reply(self.next_id)
        assert set(msg) == {"id", "error"}, msg
        return msg["error"]["message"]

    def close(self):
        self.proc.stdin.close()
        rest = self.proc.stdout.read()
        code = self.proc.wait(timeout=30)
        self.proc.stderr.close()
        self.proc.stdout.close()
        return code, rest
