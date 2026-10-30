# The two 2x previews of the traced hand: ../proust-longtemps-cream@2x.png (ink #3B2F27 on cream #FDF8EE) and
# ../proust-longtemps-vermilion@2x.png (#FBF0DC on the icon's vermilion #C04734). ../proust-longtemps.svg's paths
# with a 24-unit margin, rendered offscreen by design/logo/final/src/snapsvg (it never shows a window).
#
# usage: SNAPSVG=<snapsvg> PAPEROLE_WORK=<scratch dir> python3 preview.py
#        (snapsvg: swiftc -O ../../../../logo/final/src/snapsvg.swift -o <path>)
import os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "logo", "final", "src")))
import render                                                     # noqa: E402

render.SNAP = os.environ.get("SNAPSVG", render.SNAP)
render.WORK = os.environ.get("PAPEROLE_WORK", os.path.join(tempfile.gettempdir(), "papercollab-paperole"))
os.makedirs(render.WORK, exist_ok=True)
M = 24                                                            # margin, hand units (1 unit = 1 photo px)
LOOKS = {"cream": ("#FDF8EE", "#3B2F27"), "vermilion": ("#C04734", "#FBF0DC")}     # (ground, ink)

src = open(os.path.join(OUT, "proust-longtemps.svg")).read()
w, h = (float(v) for v in re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', src).groups())
paths = "".join(re.findall(r"<path [^>]*/>", src))
W, H = w + 2 * M, h + 2 * M
jobs = []
for name, (ground, ink) in LOOKS.items():
    p = os.path.join(render.WORK, f"hand-preview-{name}.svg")
    with open(p, "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-M} {-M} {W:g} {H:g}">'
                f'<rect x="{-M}" y="{-M}" width="{W:g}" height="{H:g}" fill="{ground}"/>'
                f'<g fill="{ink}" fill-rule="nonzero">{paths}</g></svg>')
    jobs.append((p, os.path.join(OUT, f"proust-longtemps-{name}@2x.png"), round(2 * W), round(2 * H)))
render.snap(jobs)
print("wrote", ", ".join(os.path.basename(j[1]) for j in jobs))
