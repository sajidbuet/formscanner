#!/usr/bin/env python3
"""
Axis-fit OMR alignment (no shear):
  X-axis -> header line endpoints (length + position)
  Y-axis -> dash column top/bottom centers (span + position)

Transform = diag([sx, sy]) + translation; no shear, no homography.
Pages are first deskewed by the header line angle, then scaled/translated to the template.
Output is exactly the template size, with white background.

Usage:
  pip install opencv-python numpy colorama
  python align_omr_axisfit_noshear.py --input "C:/OMR/in" --output "C:/OMR/out" \
      --template "C:/OMR/omr1-10212025125307_Page1.jpg" --write-debug --keep-debug
"""

from __future__ import annotations
import argparse, sys, hashlib
from pathlib import Path
from dataclasses import dataclass
import numpy as np
import cv2

# ---------- colored logs ----------
try:
    from colorama import Fore, Style, init as colorama_init
    colorama_init(autoreset=True)
    class C:
        OK=Fore.GREEN+Style.BRIGHT; INFO=Fore.CYAN+Style.BRIGHT
        WARN=Fore.YELLOW+Style.BRIGHT; ERR=Fore.RED+Style.BRIGHT; END=Style.RESET_ALL
except Exception:
    class C: OK=INFO=WARN=ERR=END=""

def log_ok(m):   print(C.OK+m+C.END)
def log_info(m): print(C.INFO+m+C.END)
def log_warn(m): print(C.WARN+m+C.END)
def log_err(m):  print(C.ERR+m+C.END)

# ---------- data ----------
@dataclass
class AxisFids:
    line_L: tuple[float,float]      # header line LEFT endpoint (as detected)
    line_R: tuple[float,float]      # header line RIGHT endpoint
    dash_top: tuple[float,float]    # top of dash column (center)
    dash_bottom: tuple[float,float] # bottom of dash column (center)

# ---------- helpers ----------
def to_gray(bgr): return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

def otsu(gray, invert=False):
    mode = cv2.THRESH_BINARY_INV if invert else cv2.THRESH_BINARY
    _, bw = cv2.threshold(gray, 0, 255, mode | cv2.THRESH_OTSU)
    return bw

def list_images(folder: Path, exts: tuple[str,...]) -> list[Path]:
    return sorted([p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in exts])

def clamp(v, lo, hi): return max(lo, min(hi, v))

# ---------- detection ----------
def detect_header_line(gray, y0_frac=0.02, y1_frac=0.22, slope_thresh=0.08):
    """Cluster many Hough segments into the single long header line and fit it."""
    H, W = gray.shape
    y0, y1 = int(H*y0_frac), int(H*y1_frac)
    band = gray[y0:y1, :]

    edges = cv2.Canny(cv2.GaussianBlur(band,(5,5),0), 50, 150, apertureSize=3)
    segs = cv2.HoughLinesP(edges, 1, np.pi/180, threshold=120,
                           minLineLength=int(0.15*W), maxLineGap=20)
    if segs is None:
        row = int(np.argmin(band.mean(axis=1)))
        y = y0 + row
        return (10.0, float(y)), (float(W-10), float(y))

    S = []
    for x1,y1p,x2,y2p in segs.reshape(-1,4):
        dx, dy = x2-x1, y2p-y1p
        if dx == 0: 
            continue
        if abs(dy/float(dx)) < slope_thresh:
            S.append((x1, y1p+y0, x2, y2p+y0))

    if not S:
        row = int(np.argmin(band.mean(axis=1)))
        y = y0 + row
        return (10.0, float(y)), (float(W-10), float(y))

    clusters = []
    for (x1,y1a,x2,y2a) in S:
        m = (y2a - y1a) / float((x2 - x1) + 1e-6)
        b = y1a - m*x1
        found = False
        for Cc in clusters:
            if abs(m - Cc["m"]) < 0.03 and abs(b - Cc["b"]) < 15:
                Cc["segs"].append((x1,y1a,x2,y2a))
                Cc["m_list"].append(m); Cc["b_list"].append(b)
                found = True
                break
        if not found:
            clusters.append({"m":m, "b":b, "segs":[(x1,y1a,x2,y2a)], "m_list":[m], "b_list":[b]})

    best = None; best_len = -1
    for Cc in clusters:
        Lsum = 0.0
        for (x1,y1a,x2,y2a) in Cc["segs"]:
            Lsum += np.hypot(x2-x1, y2a-y1a)
        if Lsum > best_len:
            best_len = Lsum; best = Cc

    pts = []; xs = []
    for (x1,y1a,x2,y2a) in best["segs"]:
        pts += [[x1,y1a],[x2,y2a]]
        xs  += [x1,x2]
    P = np.array(pts, dtype=np.float32)
    X = P[:,0]; Y = P[:,1]
    A = np.vstack([X, np.ones_like(X)]).T
    m_fit, b_fit = np.linalg.lstsq(A, Y, rcond=None)[0]

    xL = float(max(10, min(xs)))
    xR = float(min(W-10, max(xs)))
    yL = float(m_fit*xL + b_fit)
    yR = float(m_fit*xR + b_fit)
    if xL > xR: xL, xR, yL, yR = xR, xL, yR, yL
    return (xL, yL), (xR, yR)

def extract_dash_patch_from_template(templ_gray,
                                     x_left_frac=0.03, x_right_frac=0.18):
    """Find a typical dash in the template's left strip and return a cropped patch."""
    H, W = templ_gray.shape
    x0 = int(W * x_left_frac); x1 = int(W * x_right_frac)
    roi = templ_gray[:, x0:x1]

    bw = cv2.threshold(roi, 0, 255, cv2.THRESH_BINARY_INV | cv2.THRESH_OTSU)[1]
    bw = cv2.morphologyEx(bw, cv2.MORPH_OPEN, np.ones((3,3), np.uint8), 1)
    bw = cv2.morphologyEx(bw, cv2.MORPH_CLOSE, np.ones((3,3), np.uint8), 1)

    cnts, _ = cv2.findContours(bw, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    comps = []
    for c in cnts:
        x, y, w, h = cv2.boundingRect(c)
        if w*h < 30: 
            continue
        ar = w/float(h) if h else 0.0
        if 0.4 <= ar <= 2.5:
            cx = x + w/2.0; cy = y + h/2.0
            comps.append((cx, cy, x, y, w, h))

    if not comps:
        # fallback: tiny square near center of ROI
        patch = roi[max(0, H//2-6):min(H, H//2+6), max(0, (x1-x0)//2-6):min(x1-x0, (x1-x0)//2+6)]
        return patch.copy()

    ws = np.array([c[4] for c in comps]); hs = np.array([c[5] for c in comps])
    med_w = int(np.median(ws)); med_h = int(np.median(hs))
    ys = np.array([c[1] for c in comps])
    y_lo, y_hi = np.percentile(ys, [15, 85])
    candidates = [c for c in comps if y_lo <= c[1] <= y_hi] or comps
    best = min(candidates, key=lambda c: abs(c[4]-med_w)+abs(c[5]-med_h))
    _, _, x, y, w, h = best

    pad = 2
    y0 = max(0, y - pad); y1 = min(roi.shape[0], y + h + pad)
    x0p = max(0, x - pad); x1p = min(roi.shape[1], x + w + pad)
    patch = roi[y0:y1, x0p:x1p]
    return patch.copy()

def detect_dash_top_bottom(gray,
                           dash_patch: np.ndarray,
                           x_left_frac=0.03, x_right_frac=0.18,
                           match_thresh=0.55, min_sep_frac=0.04):
    """Template-match dashes, keep well-separated peaks, return top & bottom centers."""
    H, W = gray.shape
    x0 = int(W * x_left_frac); x1 = int(W * x_right_frac)
    roi = gray[:, x0:x1]

    t = dash_patch
    if t is None or t.size == 0 or t.shape[0] < 3 or t.shape[1] < 3:
        cx = (x0 + x1)/2.0
        return (float(cx), float(int(H*0.08))), (float(cx), float(int(H*0.92)))

    res = cv2.matchTemplate(roi, t, cv2.TM_CCOEFF_NORMED)
    ys, xs = np.where(res >= match_thresh)
    if len(xs) == 0:
        ys, xs = np.where(res >= (match_thresh*0.9))
        if len(xs) == 0:
            cx = (x0 + x1)/2.0
            return (float(cx), float(int(H*0.08))), (float(cx), float(int(H*0.92)))

    hT, wT = t.shape[:2]
    cand = [[rx + wT/2.0, ry + hT/2.0, float(res[ry,rx])] for (ry,rx) in zip(ys,xs)]

    # NMS on Y
    cand.sort(key=lambda c: c[2], reverse=True)
    sep = max(6, int(H * min_sep_frac))
    keep = []
    for c in cand:
        if all(abs(c[1]-k[1]) >= sep for k in keep):
            keep.append(c)
        if len(keep) > 30: break

    if len(keep) < 2:
        keep.sort(key=lambda c: c[1])
        top, bot = keep[0], keep[-1]
    else:
        keep.sort(key=lambda c: c[1])
        top, bot = keep[0], keep[-1]

    cx_avg = (top[0] + bot[0]) / 2.0 + x0
    return (float(cx_avg), float(top[1])), (float(cx_avg), float(bot[1]))

def detect_axis_fids(gray, dash_patch: np.ndarray) -> AxisFids:
    """Find both sets of fiducials using the dash template provided."""
    L, R = detect_header_line(gray)
    dt, db = detect_dash_top_bottom(gray, dash_patch)
    if dt[1] > db[1]: dt, db = db, dt
    if L[0] > R[0]:   L, R = R, L
    return AxisFids(L, R, dt, db)

# ---------- deskew ----------
def deskew_by_header(gray):
    (x1,y1),(x2,y2) = detect_header_line(gray)
    angle = np.degrees(np.arctan2((y2-y1),(x2-x1)))
    H,W = gray.shape
    M = cv2.getRotationMatrix2D((W/2,H/2), -angle, 1.0)
    rot = cv2.warpAffine(gray, M, (W,H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    return rot, M, angle

def apply_affine_color(img, M):
    H,W = img.shape[:2]
    return cv2.warpAffine(img, M, (W,H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)

# ---------- fit noshear transform ----------
def fit_scale_translate(page, templ, sx_clamp=(0.85,1.20), sy_clamp=(0.85,1.20)):
    # X-scale from header lengths
    Lp = np.hypot(page.line_R[0]-page.line_L[0], page.line_R[1]-page.line_L[1]) + 1e-6
    Lt = np.hypot(templ.line_R[0]-templ.line_L[0], templ.line_R[1]-templ.line_L[1]) + 1e-6
    sx = clamp(Lt / Lp, *sx_clamp)

    # Y-scale from dash span
    Sp = abs(page.dash_bottom[1] - page.dash_top[1]) + 1e-6
    St = abs(templ.dash_bottom[1] - templ.dash_top[1]) + 1e-6
    sy = clamp(St / Sp, *sy_clamp)

    # Robust offsets: compute from all four corresponding points, take median
    tx_candidates = np.array([
        templ.line_L[0]     - sx*page.line_L[0],
        templ.line_R[0]     - sx*page.line_R[0],
        templ.dash_top[0]   - sx*page.dash_top[0],
        templ.dash_bottom[0]- sx*page.dash_bottom[0],
    ], dtype=np.float32)
    ty_candidates = np.array([
        templ.line_L[1]     - sy*page.line_L[1],
        templ.line_R[1]     - sy*page.line_R[1],
        templ.dash_top[1]   - sy*page.dash_top[1],
        templ.dash_bottom[1]- sy*page.dash_bottom[1],
    ], dtype=np.float32)

    tx = float(np.median(tx_candidates))
    ty = float(np.median(ty_candidates))

    M = np.array([[sx, 0.0, tx],
                  [0.0, sy, ty]], dtype=np.float32)
    return M, sx, sy, tx, ty

# ---------- drawing ----------
def draw_debug(img, f: AxisFids):
    # line endpoints in blue, dashes in red
    for pt in [f.line_L, f.line_R]:
        cv2.drawMarker(img,(int(pt[0]),int(pt[1])),(255,0,0),cv2.MARKER_TILTED_CROSS,22,3)
    for pt in [f.dash_top, f.dash_bottom]:
        cv2.drawMarker(img,(int(pt[0]),int(pt[1])),(0,0,255),cv2.MARKER_CROSS,22,3)

def add_bullseyes(img, margin=22, radius=16):
    H,W = img.shape[:2]
    for (x,y) in [(margin,margin),(W-margin,margin),(margin,H-margin),(W-margin,H-margin)]:
        for col,r in [((0,0,0),radius),((255,255,255),int(radius*0.55)),((0,0,0),int(radius*0.25))]:
            cv2.circle(img,(x,y),r,col,-1,cv2.LINE_AA)
        cv2.circle(img,(x,y),max(1,radius//10),(255,255,255),-1,cv2.LINE_AA)

# ---------- optional: dash patch cache ----------
def _templ_fingerprint(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1<<16), b""):
            h.update(chunk)
    return h.hexdigest()[:16]

def load_or_build_dash_patch(templ_gray, templ_path: str, user_patch_path: str, cache_dir: str):
    if user_patch_path:
        patch = cv2.imread(user_patch_path, cv2.IMREAD_GRAYSCALE)
        if patch is None or patch.size == 0:
            raise RuntimeError(f"Cannot read dash patch: {user_patch_path}")
        return patch
    fp = _templ_fingerprint(templ_path)
    cache = Path(cache_dir); cache.mkdir(parents=True, exist_ok=True)
    cache_path = cache / f"dash_{fp}.png"
    if cache_path.exists():
        patch = cv2.imread(str(cache_path), cv2.IMREAD_GRAYSCALE)
        if patch is not None and patch.size > 0:
            return patch
    patch = extract_dash_patch_from_template(templ_gray)
    if patch is None or patch.size == 0:
        raise RuntimeError("Failed to build dash patch from template.")
    cv2.imwrite(str(cache_path), patch)
    return patch

# ---------- main ----------
def main():
    ap=argparse.ArgumentParser("Axis-fit OMR alignment without shear")
    ap.add_argument("--input",  default=str(Path.cwd()/"in"))
    ap.add_argument("--output", default=str(Path.cwd()/"out"))
    ap.add_argument("--template", default=str(Path.cwd()/"omr1-10212025125307_Page1.jpg"))
    ap.add_argument("--extensions", default="jpg,jpeg,png,tif,tiff,bmp")
    ap.add_argument("--write-debug", action="store_true")
    ap.add_argument("--keep-debug", action="store_true")
    ap.add_argument("--clean-before", action="store_true")
    ap.add_argument("--bull-margin", type=int, default=22)
    ap.add_argument("--bull-radius", type=int, default=16)
    ap.add_argument("--sx-range", type=str, default="0.8,1.25",
                    help="Clamp for X scale ratio Lt/Lp, e.g. 0.85,1.2")
    ap.add_argument("--sy-range", type=str, default="0.8,1.25",
                    help="Clamp for Y scale ratio St/Sp, e.g. 0.85,1.2")
    # NEW: dash-patch persistence (optional)
    ap.add_argument("--dash-patch", default="", help="Optional path to a saved dash-patch PNG.")
    ap.add_argument("--dash-cache-dir", default=".dash_cache", help="Folder to cache auto-built dash patches.")
    args=ap.parse_args()

    sx_lo, sx_hi = [float(x) for x in args.sx_range.split(",")]
    sy_lo, sy_hi = [float(x) for x in args.sy_range.split(",")]

    in_dir, out_dir = Path(args.input), Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.clean_before:
        for q in out_dir.glob("*"):
            try: q.unlink()
            except Exception: pass
        log_warn(f"Cleaned: {out_dir}")

    exts=tuple("."+e.strip(". ").lower() for e in args.extensions.split(",") if e.strip())
    files=list_images(in_dir, exts)
    if not files:
        log_err(f"No images with {exts} in {in_dir}"); sys.exit(1)

    # Template
    templ=cv2.imread(str(args.template))
    if templ is None:
        log_err(f"Cannot read template: {args.template}"); sys.exit(1)
    templ_gray = to_gray(templ)

    # Build or load dash patch ONCE, then keep it in memory
    dash_patch = load_or_build_dash_patch(templ_gray, args.template, args.dash_patch, args.dash_cache_dir)

    # Detect fiducials on template (with same dash patch)
    t_fids = detect_axis_fids(templ_gray, dash_patch)
    Ht, Wt = templ_gray.shape

    if args.write_debug:
        td = templ.copy(); draw_debug(td, t_fids)
        cv2.imwrite(str(out_dir/"_template_debug.jpg"), td)
        cv2.imwrite(str(out_dir/"_dash_patch.png"), dash_patch)

    total=len(files)
    log_info(f"Found {total} file(s). Output → {out_dir.resolve()}")

    for i,p in enumerate(files, start=1):
        prefix=f"[file {i}/{total}]"
        bgr=cv2.imread(str(p))
        if bgr is None:
            log_warn(f"{prefix} skip: cannot read {p.name}")
            continue

        g = to_gray(bgr)

        # 1) Deskew (rotate only) using header line
        g_rot, Mrot, angle = deskew_by_header(g)
        if abs(angle) > 0.1:
            bgr = apply_affine_color(bgr, Mrot)
            g   = g_rot

        # 2) Detect fiducials on deskewed page (using SAME dash patch)
        p_fids = detect_axis_fids(g, dash_patch)

        # 3) Fit no-shear SX/SY + translation to template
        Mst, sx, sy, tx, ty = fit_scale_translate(p_fids, t_fids,
                                                  sx_clamp=(sx_lo, sx_hi),
                                                  sy_clamp=(sy_lo, sy_hi))

        # 4) Warp directly to template canvas (uniform size), white background
        warped = cv2.warpAffine(bgr, Mst, (Wt, Ht),
                                flags=cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_CONSTANT,
                                borderValue=(255,255,255))

        # 5) Add bullseyes
        add_bullseyes(warped, margin=args.bull_margin, radius=args.bull_radius)

        # 6) Save
        out_final = out_dir / f"{p.stem}_final.jpg"
        cv2.imwrite(str(out_final), warped)

        if args.write_debug:
            sd = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
            draw_debug(sd, p_fids)
            cv2.line(sd, (int(p_fids.line_L[0]),int(p_fids.line_L[1])),
                         (int(p_fids.line_R[0]),int(p_fids.line_R[1])), (255,0,0), 2)
            cv2.imwrite(str(out_dir / f"{p.stem}_debug.jpg"), sd)
            log_info(f"{prefix} sx={sx:.4f} sy={sy:.4f} tx={tx:.1f} ty={ty:.1f} angle={angle:.2f}")

        # keep only final unless --keep-debug
        for q in out_dir.glob(f"{p.stem}_*.*"):
            if q.name == out_final.name: continue
            if args.keep_debug and q.name.endswith("_debug.jpg"): continue
            try: q.unlink()
            except Exception: pass

        log_ok(f"{prefix} {p.name} → {out_final.name}")

    # cleanup pass
    for q in out_dir.glob("*"):
        if q.suffix.lower()==".jpg" and not q.name.endswith("_final.jpg"):
            if args.keep_debug and q.name.endswith("_debug.jpg"):
                continue
            try: q.unlink()
            except Exception: pass

    log_info("Done. All outputs are the same pixel size as the template.")

if __name__=="__main__":
    main()
