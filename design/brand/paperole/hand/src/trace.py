# Proust's "Longtemps, je me suis / couché de bonne heure", traced from a photo into filled vector paths.
#
# Source: Wikimedia Commons, "Autographe Proust longtemps.JPG" (photo by Warburg, 2013, CC BY-SA 3.0 / GFDL), a
# corrected proof of Du côté de chez Swann with Proust's handwritten insertion inside a drawn balloon. The handwriting
# is Proust's (public domain); the traced paths are shared under CC BY-SA 4.0 (see ../SOURCE.md).
#
# usage: python3 -I trace.py <Autographe_Proust_longtemps.JPG> <out dir> [<check dir>]
#   writes <out>/proust-longtemps.svg (groups line1 and line2), proust-longtemps-line1.svg, proust-longtemps-line2.svg;
#   with a check dir also assign.png (which ink went to which line) and strokes.txt.
#
# How (a potrace-like trace written here with numpy, scipy and scikit-image):
#   1. darkness D = 1 - grey / paper (the paper by a 25 px grey closing and a blur, so the light and the paper tone
#      drop out); TV denoising and a 0.8 px blur against the JPEG and the paper grain;
#   2. flow smoothing: D is averaged along each stroke (a line-integral convolution along the stroke direction from
#      the structure tensor, following the stroke's curve), not across it, so the edges stop wobbling with the grain
#      while each stroke keeps its width, its thick and thin, its curves and the counters between strokes;
#   3. only the two handwritten lines: exclusion polygons for the balloon, the margin bracket, the printed text and the
#      struck "me coucher" (soft-edged, so a cut stroke ends round); boost polygons where Proust's pen ran faint (the
#      L's hairline, the turn of the C, the c of couché, the bowl of the d of de) so those strokes stay joined;
#   4. hysteresis threshold (edge LOW, core HIGH) keeps strokes with a dark core and drops paper specks; islands under
#      MIN_AREA go; small holes and ink-pool holes inside thick strokes are filled; letter counters stay;
#   5. each connected stroke goes to line 1 or line 2 (its centroid against MID; a seed for the return stroke of the
#      g's descender loop, which hangs into line 2; one cut where the p of Longtemps runs into the d of de);
#   6. per line, D x membership is upsampled 3x (cubic) and contoured at LOW (marching squares): sub-pixel edges,
#      outer contours clockwise and holes counter-clockwise (fill-rule nonzero);
#   7. each contour is resampled, split at corners (turn > CORNER_DEG), smoothed by SMOOTH px between corners and fitted
#      with cubic Béziers by Schneider's algorithm (least squares, Newton reparameterisation, max error FIT_TOL px).
# The combined file lets the two halves of the p/d stroke overlap by REACH px, so it shows no seam; the single-line
# files cut it cleanly. Units: 1 SVG unit = 1 photo pixel (the hand's x-height is about 40 units).
import math, os, sys
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi
from skimage.filters import apply_hysteresis_threshold
from skimage.measure import find_contours
from skimage.restoration import denoise_tv_chambolle

ROI = (100, 420, 1480, 900)              # x0, y0, x1, y1 in photo pixels: the balloon's inside, both lines
LOW, HIGH = 0.24, 0.32                   # edge level and core level of the darkness D
DENOISE, BLUR = 0.06, 0.8                # TV denoising weight; Gaussian blur, px
FLOW, FLOW_RHO, FLOW_COH = 5.0, 3.0, 0.5   # px along the stroke; structure scale, px; coherence for full smoothing
MIN_AREA = 40                            # px, smaller ink islands are paper noise
FILL_HOLE = (12, 0.30)                   # fill a hole smaller than this many px, or darker than this mean D
UP = 3                                   # contour upsampling
STEP = 0.35                              # px, contour resampling step
SMOOTH = 1.2                             # px, Gaussian smoothing of the outline along its length, corners kept
FIT_TOL = 0.40                           # px, max Bézier error
CORNER_DEG, CORNER_ARM = 58.0, 1.6       # a corner turns more than this over +- this many px
REACH = 4                                # px, overlap of the two lines at a cut in the combined file

# Not Proust's two lines: removed before thresholding (polygons in photo px).
EXCLUDE = [
    [(985, 380), (1480, 380), (1480, 452), (985, 452)],                  # struck "me coucher" above "suis"
    [(95, 380), (160, 380), (128, 452), (95, 476)],                       # the balloon, top left
    [(1438, 400), (1480, 400), (1480, 905), (1449, 905), (1449, 760), (1438, 760)],   # margin bracket, print
    [(1352, 905), (1480, 905), (1480, 834), (1449, 834), (1437, 842)],    # the balloon running under "heure"
]
# Faint pen: D is raised here (factor) so the hairline stays joined. Polygons in photo px.
BOOST = [
    ([(203, 472), (213, 474), (204, 500), (202, 520), (190, 520), (194, 496)], 1.5),   # the L's hairline
    ([(143, 782), (157, 782), (153, 806), (140, 808), (138, 800)], 1.5),               # the C's turn
    ([(364, 806), (382, 806), (380, 824), (362, 824)], 1.3),                           # the c of couché
    ([(658, 796), (675, 796), (668, 845), (652, 857), (643, 850)], 1.5),               # the bowl of the d (de)
]
# Line membership: strokes whose centroid lies above MID (photo y) are line 1, below are line 2, except:
MID = 735
SEEDS = {1: [(375, 745)], 2: []}         # the return stroke of the g's descender loop (Longtemps) hangs into line 2
# Strokes that touch across the lines: (a point on the line-1 part, a point on the line-2 part, line-2 polygon)
SPLITS = [((632, 700), (668, 770), [(600, 727), (725, 727), (725, 895), (600, 895)])]   # p of Longtemps / d of de


def poly_mask(shape, poly, off):
    im = Image.new("L", (shape[1], shape[0]), 0)
    ImageDraw.Draw(im).polygon([(x - off[0], y - off[1]) for x, y in poly], fill=1)
    return np.asarray(im, bool)


def darkness(src):
    g = np.asarray(Image.open(src).convert("L")).astype(float)
    paper = ndi.gaussian_filter(ndi.grey_closing(g, size=(25, 25)), 8)
    return np.clip(1 - g / np.maximum(paper, 1), 0, 1)


def label_at(lab, x, y, off, r=4):
    """The label of the stroke at photo (x, y), or the nearest within r px."""
    j, i = int(round(x - off[0])), int(round(y - off[1]))
    win = lab[max(i - r, 0):i + r + 1, max(j - r, 0):j + r + 1]
    if not win.any():
        raise SystemExit(f"no stroke near seed {(x, y)}")
    ii, jj = np.nonzero(win)
    k = np.argmin((ii + max(i - r, 0) - i) ** 2 + (jj + max(j - r, 0) - j) ** 2)
    return win[ii[k], jj[k]]


def flow_smooth(F, sig_a):
    """Smooth along the strokes, not across them: a line-integral convolution of F along the stroke direction (the
    structure tensor's minor eigenvector, followed as a streamline so it bends with the stroke), weighted by how
    clearly a direction exists (coherence), so crossings and blobs are left nearly as they are. The paper grain makes
    the stroke edges wobble along the stroke; this removes that and keeps the stroke's cross-section and its curves."""
    if sig_a <= 0:
        return F
    g = ndi.gaussian_filter(F, 1.2)
    gy, gx = np.gradient(g)
    jxx, jxy, jyy = (ndi.gaussian_filter(a, FLOW_RHO) for a in (gx * gx, gx * gy, gy * gy))
    c2, s2 = -(jxx - jyy), -2 * jxy                  # doubled angle of the stroke direction
    n = np.hypot(c2, s2)
    coh = n / (jxx + jyy + 1e-9)
    c2, s2 = c2 / (n + 1e-12), s2 / (n + 1e-12)
    H, W = F.shape
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    acc, wsum = F.copy(), np.ones_like(F)
    h = 0.5
    th0 = 0.5 * np.arctan2(s2, c2)
    for sign in (1, -1):
        px, py = xx.copy(), yy.copy()
        dx, dy = sign * np.cos(th0), sign * np.sin(th0)
        for k in range(1, int(3 * sig_a / h) + 1):
            cc = ndi.map_coordinates(c2, [py, px], order=1, mode="nearest")
            ss = ndi.map_coordinates(s2, [py, px], order=1, mode="nearest")
            th = 0.5 * np.arctan2(ss, cc)
            vx, vy = np.cos(th), np.sin(th)
            flip = vx * dx + vy * dy < 0
            vx[flip] *= -1
            vy[flip] *= -1
            px, py = px + h * vx, py + h * vy
            dx, dy = vx, vy
            w = math.exp(-(k * h) ** 2 / (2 * sig_a ** 2))
            acc += w * ndi.map_coordinates(F, [py, px], order=1, mode="nearest")
            wsum += w
    a = np.clip(coh / FLOW_COH, 0, 1)
    return a * (acc / wsum) + (1 - a) * F


def masks(D):
    x0, y0, x1, y1 = ROI
    off = (x0, y0)
    F = D[y0 - 20:y1 + 20, x0 - 20:x1 + 20]
    if DENOISE:
        F = denoise_tv_chambolle(F, weight=DENOISE)
    F = flow_smooth(ndi.gaussian_filter(F, BLUR), FLOW)[20:-20, 20:-20].copy()
    keep = np.ones(F.shape, bool)
    for p in EXCLUDE:
        keep &= ~poly_mask(F.shape, p, off)
    keep_s = np.clip(2 * ndi.gaussian_filter(keep.astype(float), 1.2), 0, 1)
    F *= keep_s
    for p, k in BOOST:
        b = ndi.gaussian_filter(poly_mask(F.shape, p, off).astype(float), 2.0)
        F *= 1 + (k - 1) * b
    M = apply_hysteresis_threshold(F, LOW, HIGH)
    lab, n = ndi.label(M, structure=np.ones((3, 3)))
    area = ndi.sum(M, lab, range(1, n + 1))
    M &= np.isin(lab, 1 + np.nonzero(area >= MIN_AREA)[0])
    # holes: counters stay; specks of paper and ink pools inside thick strokes are filled
    holes = ndi.binary_fill_holes(M) & ~M
    hl, hn = ndi.label(holes)
    if hn:
        ha = ndi.sum(holes, hl, range(1, hn + 1))
        hd = ndi.mean(F, hl, range(1, hn + 1))
        fill = np.isin(hl, 1 + np.nonzero((ha < FILL_HOLE[0]) | (hd > FILL_HOLE[1]))[0])
        M |= fill
        F = np.maximum(F, 0.7 * ndi.gaussian_filter(fill.astype(float), 0.7))
    # line membership
    lab, n = ndi.label(M, structure=np.ones((3, 3)))
    A = np.zeros(F.shape, np.uint8)
    forced = {}
    for k, pts in SEEDS.items():
        for x, y in pts:
            forced[label_at(lab, x, y, off)] = k
    split, S = {}, np.zeros(F.shape, bool)
    for s1, s2, poly in SPLITS:
        l1, l2 = label_at(lab, *s1, off), label_at(lab, *s2, off)
        if l1 != l2:
            raise SystemExit(f"split {s1}/{s2}: the strokes no longer touch; drop the split")
        split[l1] = poly_mask(F.shape, poly, off)
        S |= lab == l1
    cy = ndi.center_of_mass(M, lab, range(1, n + 1))
    report = []
    for l in range(1, n + 1):
        sel = lab == l
        if l in split:
            A[sel & split[l]] = 2
            A[sel & ~split[l]] = 1
            k = "split"
        else:
            k = forced.get(l, 1 if cy[l - 1][0] + y0 < MID else 2)
            A[sel] = k
        ii, jj = np.nonzero(sel)
        report.append((l, k, int(sel.sum()), jj.min() + x0, jj.max() + x0, ii.min() + y0, ii.max() + y0))
    return F, M, A, S, report


def line_fields(F, M, A, S, reach):
    """D restricted to each line's strokes. Pixels off the ink go to the nearer line. Where a stroke was cut between
    the lines (S), each side reaches `reach` px into the other along the ink; with 0 the cut ends round within ~1 px."""
    out = {}
    for k in (1, 2):
        own, other = A == k, (A != k) & M
        if reach:
            own = own | (ndi.binary_dilation(own, iterations=reach) & S)
        dk, do = ndi.distance_transform_edt(~own), ndi.distance_transform_edt(~other)
        w = (own | ((dk <= 3) & (dk <= do) & ~M)).astype(float)
        out[k] = F * np.clip(2 * ndi.gaussian_filter(w, 1.0), 0, 1)
    return out


def contours(Fk):
    x0, y0 = ROI[:2]
    U = ndi.zoom(np.pad(Fk, 4), UP, order=3, grid_mode=True, mode="grid-constant")
    res = []
    for c in find_contours(U, LOW):
        if len(c) < 8 or not np.allclose(c[0], c[-1]):
            continue
        x = (c[:, 1] + 0.5) / UP - 4 + x0                # photo px, pixel edges at integers
        y = (c[:, 0] + 0.5) / UP - 4 + y0
        P = np.stack([x, y], 1)[:-1]
        a = 0.5 * np.sum(P[:, 0] * np.roll(P[:, 1], -1) - np.roll(P[:, 0], -1) * P[:, 1])
        if abs(a) < (MIN_AREA / 4 if a > 0 else 8.0):
            continue
        res.append(P)
    return res


# ---- Bézier fitting (P. J. Schneider, "An algorithm for automatically fitting digitized curves", Graphics Gems 1990)
def _bez(b, t):
    t = t[:, None]
    mt = 1 - t
    return mt ** 3 * b[0] + 3 * mt ** 2 * t * b[1] + 3 * mt * t ** 2 * b[2] + t ** 3 * b[3]


def _bez1(b, t):
    t = t[:, None]
    mt = 1 - t
    return 3 * mt ** 2 * (b[1] - b[0]) + 6 * mt * t * (b[2] - b[1]) + 3 * t ** 2 * (b[3] - b[2])


def _bez2(b, t):
    t = t[:, None]
    return 6 * (1 - t) * (b[2] - 2 * b[1] + b[0]) + 6 * t * (b[3] - 2 * b[2] + b[1])


def _unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def _generate(P, u, t1, t2):
    p0, p3 = P[0], P[-1]
    b0, b1, b2, b3 = (1 - u) ** 3, 3 * u * (1 - u) ** 2, 3 * u ** 2 * (1 - u), u ** 3
    A1, A2 = t1[None] * b1[:, None], t2[None] * b2[:, None]
    C = np.array([[np.sum(A1 * A1), np.sum(A1 * A2)], [np.sum(A1 * A2), np.sum(A2 * A2)]])
    tmp = P - (p0[None] * (b0 + b1)[:, None] + p3[None] * (b2 + b3)[:, None])
    X = np.array([np.sum(A1 * tmp), np.sum(A2 * tmp)])
    det = C[0, 0] * C[1, 1] - C[0, 1] * C[1, 0]
    seg = np.linalg.norm(p3 - p0)
    if abs(det) > 1e-12:
        al = (X[0] * C[1, 1] - X[1] * C[0, 1]) / det
        ar = (C[0, 0] * X[1] - C[1, 0] * X[0]) / det
    else:
        al = ar = seg / 3
    if al < 1e-6 * seg or ar < 1e-6 * seg or al > 3 * seg + 2 or ar > 3 * seg + 2:
        al = ar = seg / 3
    return np.array([p0, p0 + t1 * al, p3 + t2 * ar, p3])


def _chord(P):
    d = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    return d / d[-1]


def _error(P, b, u):
    d = np.sum((_bez(b, u) - P) ** 2, axis=1)
    i = int(np.argmax(d[1:-1])) + 1 if len(P) > 2 else len(P) // 2
    return math.sqrt(d[i]), i


def _newton(P, b, u):
    q, q1, q2 = _bez(b, u), _bez1(b, u), _bez2(b, u)
    num = np.sum((q - P) * q1, axis=1)
    den = np.sum(q1 * q1, axis=1) + np.sum((q - P) * q2, axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        nu = np.where(np.abs(den) > 1e-12, u - num / den, u)
    nu = np.clip(nu, 0, 1)
    nu[0], nu[-1] = 0, 1
    return np.maximum.accumulate(nu)


def fit_cubic(P, t1, t2, tol):
    if len(P) == 2:
        d = np.linalg.norm(P[1] - P[0]) / 3
        return [np.array([P[0], P[0] + t1 * d, P[1] + t2 * d, P[1]])]
    u = _chord(P)
    b = _generate(P, u, t1, t2)
    err, i = _error(P, b, u)
    if err < tol:
        return [b]
    if err < 4 * tol:
        for _ in range(12):
            u = _newton(P, b, u)
            b = _generate(P, u, t1, t2)
            err, i = _error(P, b, u)
            if err < tol:
                return [b]
    i = min(max(i, 1), len(P) - 2)
    tc = _unit(P[i - 1] - P[i + 1])
    return fit_cubic(P[:i + 1], t1, tc, tol) + fit_cubic(P[i:], -tc, t2, tol)


def resample(P, h):
    Q = np.vstack([P, P[:1]])
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(Q, axis=0), axis=1))])
    n = max(12, int(round(s[-1] / h)))
    t = np.linspace(0, s[-1], n, endpoint=False)
    return np.stack([np.interp(t, s, Q[:, 0]), np.interp(t, s, Q[:, 1])], 1)


def corners(P, h):
    k = max(2, int(round(CORNER_ARM / h)))
    v1 = P - np.roll(P, k, axis=0)
    v2 = np.roll(P, -k, axis=0) - P
    cr = v1[:, 0] * v2[:, 1] - v1[:, 1] * v2[:, 0]
    dt = np.sum(v1 * v2, axis=1)
    ang = np.degrees(np.abs(np.arctan2(cr, dt)))
    idx = []
    for i in np.nonzero(ang > CORNER_DEG)[0]:
        w = ang[np.arange(i - k, i + k + 1) % len(P)]
        if ang[i] >= w.max() and not (idx and i - idx[-1] <= k):
            idx.append(int(i))
    return idx, ang


def smooth_open(Q, sig):
    """Gaussian smoothing of an open run with its two ends pinned (point reflection about each end)."""
    k = min(len(Q) - 1, int(3 * sig) + 1)
    if k < 1 or sig <= 0:
        return Q
    ext = np.vstack([2 * Q[0] - Q[k:0:-1], Q, 2 * Q[-1] - Q[-2:-k - 2:-1]])
    return ndi.gaussian_filter1d(ext, sig, axis=0, mode="nearest")[k:k + len(Q)]


def fit_closed(P):
    P = resample(P, STEP)
    n = len(P)
    cs, ang = corners(ndi.gaussian_filter1d(P, 1.0, axis=0, mode="wrap"), STEP)
    sig = SMOOTH / STEP
    arm = max(2, int(round(1.0 / STEP)))
    segs = []
    if not cs:
        P = ndi.gaussian_filter1d(P, sig, axis=0, mode="wrap")
        s = int(np.argmin(ang))                              # start where the outline is straightest
        Q = np.vstack([np.roll(P, -s, axis=0), np.roll(P, -s, axis=0)[:1]])
        t = _unit(Q[1] - Q[-2])
        segs = fit_cubic(Q, t, -t, FIT_TOL)
    else:
        for a, b in zip(cs, cs[1:] + [cs[0] + n]):
            Q = smooth_open(P[np.arange(a, b + 1) % n], sig)
            if len(Q) < 2:
                continue
            m = min(arm, len(Q) - 1)
            segs += fit_cubic(Q, _unit(Q[m] - Q[0]), _unit(Q[-1 - m] - Q[-1]), FIT_TOL)
    return segs


def bbox(paths):
    pts = []
    t = np.linspace(0, 1, 33)
    for segs in paths:
        for b in segs:
            pts.append(_bez(b, t))
    a = np.vstack(pts)
    return a.min(0), a.max(0)


def path_d(segs, o):
    f = lambda v: f"{v:.2f}".rstrip("0").rstrip(".")
    p = segs[0][0] - o
    out = [f"M{f(p[0])} {f(p[1])}"]
    for b in segs:
        c = b[1:] - o
        out.append("C" + " ".join(f"{f(x)} {f(y)}" for x, y in c))
    return "".join(out) + "Z"


CREDIT = ("Handwriting: Marcel Proust (public domain); traced from a photo by Warburg, Wikimedia Commons, "
          "CC BY-SA 3.0")


def svg(groups, lo, hi, title, origin):
    w, h = hi - lo
    body = []
    for gid, paths in groups:
        d = "".join(path_d(s, lo) for s in paths)
        body.append(f'  <g id="{gid}">\n    <path d="{d}"/>\n  </g>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:g} {h:g}" width="{w:g}" '
            f'height="{h:g}" fill="#2B2420" fill-rule="nonzero" '
            f'data-photo-origin="{origin[0]:.1f} {origin[1]:.1f}">\n'
            f'  <title>{title}</title>\n'
            f'  <desc>{CREDIT}. These traced paths: CC BY-SA 4.0. 1 unit = 1 pixel of the photo.</desc>\n'
            + "\n".join(body) + "\n</svg>\n")


def main():
    src, out = sys.argv[1], sys.argv[2]
    chk = sys.argv[3] if len(sys.argv) > 3 else None
    os.makedirs(out, exist_ok=True)
    F, M, A, S, report = masks(darkness(src))
    traced = {}
    for reach in (REACH, 0):
        fields = line_fields(F, M, A, S, reach)
        traced[reach] = {k: [fit_closed(P) for P in contours(fields[k])] for k in (1, 2)}
    if chk:
        os.makedirs(chk, exist_ok=True)
        rgb = np.full(A.shape + (3,), 255, np.uint8)
        rgb[A == 1] = (40, 90, 200)
        rgb[A == 2] = (200, 60, 40)
        Image.fromarray(rgb).save(os.path.join(chk, "assign.png"))
        with open(os.path.join(chk, "strokes.txt"), "w") as f:
            for r in report:
                f.write("label %d line %s area %d x %d-%d y %d-%d\n" % r)
    name = "proust-longtemps"
    both = traced[REACH]
    lo, hi = bbox(both[1] + both[2])
    lo, hi = np.floor(lo * 2) / 2, np.ceil(hi * 2) / 2
    with open(os.path.join(out, name + ".svg"), "w") as f:
        f.write(svg([("line1", both[1]), ("line2", both[2])], lo, hi,
                    "Longtemps, je me suis couché de bonne heure (Proust's hand)", lo))
    print(f"both: origin {lo} size {hi - lo}, {sum(len(s) for s in both[1] + both[2])} cubic segments")
    for k, txt in ((1, "Longtemps, je me suis"), (2, "couché de bonne heure")):
        one = traced[0][k]
        l, h = bbox(one)
        l, h = np.floor(l * 2) / 2, np.ceil(h * 2) / 2
        with open(os.path.join(out, f"{name}-line{k}.svg"), "w") as f:
            f.write(svg([(f"line{k}", one)], l, h, f"{txt} (Proust's hand)", l))
        print(f"line{k}: {len(one)} contours, {sum(len(s) for s in one)} cubic segments, origin {l} size {h - l}")


if __name__ == "__main__":
    main()
