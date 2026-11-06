"""Mockup of the Finish Round sheet with final.pdf's summary page beside the round's card (design only).

Builds on design/stats-card/src/build.py (its tokens, fonts, rows, buttons and the compact card) and on a summary
page drawn by make_mockup.py. Synthetic data only.

    swiftc -O design/logo/final/src/snapsvg.swift -o <scratch>/snapsvg
    engine/.venv/bin/python design/summary-page/make_sheet.py <mockup-b.pdf> <review copy> <snapsvg> <out dir>
"""
import json
import pathlib
import subprocess
import sys

import pymupdf

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "stats-card" / "src"))
import build as card  # noqa: E402
from make_mockup import add_overall  # noqa: E402

W, H = 1120, 760  # points; the sheet grows from 920 x 640 so the page reads near its own size
PREVIEW_W = 600  # points: the summary page drawn at 98% (612 pt wide)


def card_data(paper, n=2):
    """The card's numbers for round n of the synthetic review, so the card and the preview agree."""
    lg = json.loads((pathlib.Path(paper) / "ledger.json").read_text())
    add_overall(lg, n)  # as the summary page shows
    cs = [c for c in lg["comments"] if str(n) in c["rounds"]]
    new = [c for c in cs if c["created_round"] == n]
    carried = [c for c in cs if c["created_round"] < n]
    verdict = lambda v: [c for c in carried if c["rounds"][str(n)]["verdict"] == v]  # noqa: E731
    written = [c["note"] for c in new] + [c["rounds"][str(n)]["verdict_note"] or "" for c in carried]
    names = {"structure": "Structure", "evidence": "Evidence & citations", "logic": "Logic & claims"}
    tags = {}
    for c in new:
        for t in c.get("tags") or []:
            tags[names.get(t["id"], t["id"])] = tags.get(names.get(t["id"], t["id"]), 0) + 1
    marks = []
    for c in new + verdict("reopened"):
        a = c["rounds"][str(n)]["anchor"]
        if not a:  # on the whole paper: no mark on a page
            continue
        marks.append((a["page"], a["rects"][0][1] / 792, 0 if a["rects"][0][0] < 306 else 1,
                      "b" if c["kind"] == "box" else ("n" if c in new else "f")))
    return dict(round=n, start="Oct 21", end="Nov 5", year=2026, days=15, pages=8,
                words="{:,}".format(sum(len(w.split()) for w in written)), new=len(new),
                followUps=len(verdict("reopened")), resolved=len(verdict("verified")), kept=len(verdict("wontfix")),
                carried=len(carried), left=len(verdict(None)), tags=list(tags.items()), praise=0, untagged=0,
                marks=marks, facts=["{} of {} earlier comments answered, every follow-up with a note.".format(
                    len(carried) - len(verdict(None)), len(carried))])


def left_column(t, d):
    left = ('<div style="font:600 12px/1 Sans;color:%s;margin-bottom:8px">Left for you <span style="font-weight:400;'
            'color:%s">· you can still finish</span></div>'
            '<div style="background:%s;border-radius:10px;box-shadow:0 0 0 .5px %s">'
            '<div style="display:flex;align-items:center;min-height:38px;padding:6px 14px">'
            '<span style="width:22px;color:%s;font:500 14px/1 Sans">○</span><div style="flex:1">'
            '<div style="font:400 13px/1.3 Sans;color:%s">Comments still to check</div>'
            '<div style="font:400 11px/1.3 Sans;color:%s">They go out as “still open”.</div></div>%s'
            '<span style="font:600 13px/1 Sans;color:%s;margin-left:12px">1</span></div></div>'
            % (t["ink2"], t["sec"], t["group"], t["groupLine"], t["red"], t["ink"], t["sec"],
               small_button("Review", t), t["ink"]))
    mine = ('<div style="font:600 12px/1 Sans;color:%s;margin:18px 0 8px">This round <span style="font-weight:400;'
            'color:%s">· your card when you finish</span></div>%s' % (t["ink2"], t["sec"], card.compact(d, t)))
    return left + mine


def small_button(label, t):
    return ('<span style="display:inline-flex;align-items:center;height:22px;padding:0 10px;border-radius:6px;'
            'background:%s;box-shadow:0 0 0 .5px %s,0 .5px 1px rgba(0,0,0,.08);font:400 12px/1 Sans;color:%s">%s</span>'
            % (t["btn"], t["btnLine"], t["ink"], label))


def preview(t, png, hover):
    """final.pdf's first page in a scrolling box; the pointer over a to-do row: its fill and the row's help tag."""
    x0, y0, x1, y1 = hover
    s = PREVIEW_W / 612
    over = ('<div style="position:absolute;left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx;border-radius:3px;'
            'background:rgba(86,107,88,.13);box-shadow:inset 0 0 0 1px rgba(86,107,88,.45)"></div>'
            % (x0 * s, y0 * s, (x1 - x0) * s, (y1 - y0) * s))
    scroller = ('<div style="position:absolute;right:3px;top:4px;width:6px;height:%dpx;border-radius:3px;'
                'background:rgba(0,0,0,.28)"></div>' % 300)
    return ('<div style="font:600 12px/1 Sans;color:%s;margin-bottom:8px">final.pdf<span style="color:%s"></span></div>'
            '<div style="position:relative;height:560px;overflow:hidden;border-radius:10px;background:#FFFFFF;'
            'box-shadow:0 0 0 .5px %s">'
            '<div style="position:absolute;left:0;top:-8px;width:%dpx">'
            '<img src="file://%s" style="display:block;width:%dpx">%s</div>%s</div>'
            % (t["ink2"], t["sec"], t["groupLine"], PREVIEW_W, png, PREVIEW_W, over, scroller))


def sheet(t, png, hover, d):
    return ('<div style="background:%s;width:%dpx;height:%dpx;padding:20px 22px 18px;box-sizing:border-box;'
            'display:flex;flex-direction:column"><div style="font:700 19px/1.2 Sans;color:%s">Finish Round 2</div>'
            '<div style="font:400 12.5px/1.3 Sans;color:%s;margin-top:4px">This writes final.pdf, then closes Round 2. '
            'A closed round is read only.</div>'
            '<div style="display:flex;gap:22px;margin-top:16px;flex:1"><div style="width:430px">%s</div>'
            '<div style="width:%dpx">%s</div></div>'
            '<div style="display:flex;align-items:center;justify-content:flex-end;gap:10px">%s%s</div></div>'
            % (t["sheet"], W, H, t["ink"], t["sec"], left_column(t, d), PREVIEW_W, preview(t, png, hover),
               card.button("Cancel", t, w=80), card.button("Finish Round", t, True)))


def main():
    pdf, paper, snap, out = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], pathlib.Path(sys.argv[4])
    d = card_data(paper)
    (out / "png").mkdir(parents=True, exist_ok=True)
    page = pymupdf.open(str(pdf))[0]
    png = out / "png" / "preview-page.png"
    page.get_pixmap(dpi=200).save(str(png))
    chip = page.search_for("R1-05")[0]  # the first to-do row
    hover = (pymupdf.Rect(page.rect.x0 + 44, chip.y0 - 5, page.rect.x1 - 44, chip.y1 + 5))
    jobs = []
    for theme in ("light", "dark"):
        t = card.THEMES[theme]
        html = out / "finish-sheet-{}.html".format(theme)
        html.write_text(card.PAGE % (card.FONTS, t["sheet"], W, H, sheet(t, png, tuple(hover), d), W))
        jobs.append("{}\t{}\t{}\t{}".format(html, out / "png" / "finish-sheet-{}.png".format(theme), W * 2, H * 2))
    (out / "jobs.txt").write_text("\n".join(jobs) + "\n")
    subprocess.run([snap, str(out / "jobs.txt")], check=True)


if __name__ == "__main__":
    main()
