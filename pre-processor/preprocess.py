#!/usr/bin/env python3
"""
Robust OMR alignment:
  1) Coarse deskew by the header band (Hough) to make the top line horizontal.
  2) Template-anchored detection of 4 fiducials:
      • top dash (left dashed margin – topmost block center)
      • bottom dash (left dashed margin – bottommost block center)
      • top line (header band)    -> y at right edge
      • thin rule (above grids)   -> y at right edge
  3) Homography with sanity checks; fallback to affine, then to similarity.
  4) Draw bullseyes in 4 corners; keep one *_final.jpg per input.

Install:  pip install opencv-python numpy colorama
Run:
  python align_omr_robust.py --input "C:/OMR/in" --output "C:/OMR/out" \
     --template "C:/OMR/in/omr1-10212025125307_Page1.jpg" --write-debug
"""

from __future__ import annotations
import argparse, sys
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

def log_info(m): print(f"{C.INFO}{m}{C.END}")
def log_ok(m):   print(f"{C.OK}{m}{C.END}")
def log_warn(m): print(f"{C.WARN}{m}{C.END}")
def log_err(m):  print(f"{C.ERR}{m}{C.END}")

# ---------- datatypes ----------
@dataclass
class FourFids:
    top_dash: tuple[float,float]
    bottom_dash: tuple[float,float]
    top_line_right: tuple[float,float]
    thin_line_right: tuple[float,float]

@dataclass
class FourFidsNorm:
    top_dash: tuple[float,float]
    bottom_dash: tuple[float,float]
    top_line_right: tuple[float,float]
    thin_line_right: tuple[float,float]

# ---------- utils ----------
def list_images(folder: Path, exts: tuple[str,...]) -> list[Path]:
    return sorted([p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in exts])

def to_gray(img): return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

def otsu(gray, invert=False):
    mode = cv2.THRESH_BINARY_INV if invert else cv2.THRESH_BINARY
    _, bw = cv2.threshold(gray, 0, 255, mode | cv2.THRESH_OTSU)
    return bw

# REPLACE your align step with this function
def compute_affine_and_warp(mov_bgr, templ_bgr, mov_fids, templ_fids):
    Ht, Wt = templ_bgr.shape[:2]
    src3 = np.float32([mov_fids.top_dash,
                       mov_fids.bottom_dash,
                       mov_fids.top_line_right])   # 3rd point: top band @ right edge
    dst3 = np.float32([templ_fids.top_dash,
                       templ_fids.bottom_dash,
                       templ_fids.top_line_right])

    A = cv2.getAffineTransform(src3, dst3)
    warped = cv2.warpAffine(mov_bgr, A, (Wt, Ht),
                            flags=cv2.INTER_LINEAR,
                            borderMode=cv2.BORDER_REPLICATE)
    return warped, A

# OPTIONAL: only if you explicitly pass --allow-homography
def try_homography_safe(mov_bgr, templ_bgr, mov_fids, templ_fids):
    Ht, Wt = templ_bgr.shape[:2]
    S = np.float32([mov_fids.top_dash, mov_fids.bottom_dash,
                    mov_fids.top_line_right, mov_fids.thin_line_right])
    D = np.float32([templ_fids.top_dash, templ_fids.bottom_dash,
                    templ_fids.top_line_right, templ_fids.thin_line_right])
    H = cv2.getPerspectiveTransform(S, D)

    # sanity: reject flips/extreme shear
    def sane(H):
        corners = np.float32([[0,0],[Wt,0],[0,Ht],[Wt,Ht]]).reshape(-1,1,2)
        warped  = cv2.perspectiveTransform(corners, H).reshape(-1,2)
        top_y = (warped[0,1]+warped[1,1])/2.0; bot_y = (warped[2,1]+warped[3,1])/2.0
        left_x= (warped[0,0]+warped[2,0])/2.0; right_x= (warped[1,0]+warped[3,0])/2.0
        if not (top_y < bot_y and left_x < right_x): return False
        # side balance
        d = lambda a,b: np.hypot(*(a-b))
        w1, w2 = d(warped[0],warped[1]), d(warped[2],warped[3])
        h1, h2 = d(warped[0],warped[2]), d(warped[1],warped[3])
        if max(w1,w2)/max(1.0,min(w1,w2)) > 2.0: return False
        if max(h1,h2)/max(1.0,min(h1,h2)) > 2.0: return False
        return True

    if sane(H):
        warped = cv2.warpPerspective(mov_bgr, H, (Wt, Ht),
                                     flags=cv2.INTER_LINEAR,
                                     borderMode=cv2.BORDER_REPLICATE)
        return warped, H
    return None, None

# ---------- coarse deskew ----------
def coarse_deskew_by_header(gray, max_rotate=25.0):
    """Find the longest near-horizontal line in the top 25% and rotate the page to make it horizontal."""
    H,W=gray.shape
    band=gray[:int(H*0.25), :]
    edges=cv2.Canny(cv2.GaussianBlur(band,(5,5),0), 50,150,apertureSize=3)
    lines=cv2.HoughLines(edges, 1, np.pi/180, 180)
    angle=0.0
    if lines is not None:
        best=None; bestw=0
        for rho,theta in lines[:,0,:]:
            # prefer lines near horizontal (theta ~ 0 or pi)
            dev=min(abs(theta-0), abs(theta-np.pi))
            w=1.0/(1e-6+dev)
            if w>bestw:
                bestw=w; best=theta
        if best is not None:
            # rotation angle in degrees to make header horizontal
            delta = min(best, np.pi-best)
            angle = -(delta*180/np.pi) if best < np.pi/2 else (delta*180/np.pi)
            angle = np.clip(angle, -max_rotate, max_rotate)
    M=cv2.getRotationMatrix2D((W/2,H/2), angle, 1.0)
    rot=cv2.warpAffine(gray, M, (W,H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    return rot, angle, M

# ---------- measurements ----------
def avg_y_of_longest_horizontal(gray_band, min_len_px, strict=True):
    blur=cv2.GaussianBlur(gray_band,(5,5),0)
    edges=cv2.Canny(blur,50,150,apertureSize=3)
    th=180 if strict else 120
    mg=20 if strict else 30
    ml=int(min_len_px if strict else 0.7*min_len_px)
    lines=cv2.HoughLinesP(edges,1,np.pi/180, threshold=th, minLineLength=ml, maxLineGap=mg)
    if lines is not None:
        best=None; Lbest=-1
        for x1,y1,x2,y2 in lines.reshape(-1,4):
            if x2==x1: continue
            slope=abs((y2-y1)/float(x2-x1))
            if slope<0.08:
                L=np.hypot(x2-x1,y2-y1)
                if L>Lbest: Lbest=L; best=(y1,y2)
        if best is not None: return (best[0]+best[1])/2.0
    return float(np.argmin(blur.mean(axis=1)))

def detect_dashes_tight(gray, x_center_frac, x_half_frac, y_top_frac, y_bot_frac):
    H,W=gray.shape
    x0=max(0,int((x_center_frac-x_half_frac)*W)); x1=min(W,int((x_center_frac+x_half_frac)*W))
    y0=max(0,int(y_top_frac*H)); y1=min(H,int(y_bot_frac*H))
    roi=gray[y0:y1, x0:x1]
    bw=otsu(roi, invert=True)
    bw=cv2.morphologyEx(bw, cv2.MORPH_OPEN, np.ones((3,3),np.uint8), iterations=1)
    cnts,_=cv2.findContours(bw, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cand=[]
    areaR=roi.shape[0]*roi.shape[1]
    for c in cnts:
        x,y,w,h=cv2.boundingRect(c)
        area=w*h
        if area < 0.001*areaR: continue
        ar=w/float(h) if h else 0
        if 0.4<=ar<=2.5:
            cx=x+w/2.0; cy=y+h/2.0
            cand.append((cy,(cx,cy)))
    if not cand:
        # fallback to ROI extremes
        top=(x0+0.5*(x1-x0), y0+0.05*(y1-y0))
        bot=(x0+0.5*(x1-x0), y0+0.95*(y1-y0))
        return (float(top[0]),float(top[1])), (float(bot[0]),float(bot[1]))
    cand.sort(key=lambda t:t[0])
    top=(cand[0][1][0]+x0, cand[0][1][1]+y0)
    bot=(cand[-1][1][0]+x0, cand[-1][1][1]+y0)
    # enforce roughly same x
    mx=(top[0]+bot[0])/2.0
    top=(mx, top[1]); bot=(mx, bot[1])
    return (float(top[0]),float(top[1])), (float(bot[0]),float(bot[1]))

def detect_line_at_right(gray, y_center_frac, band_half_frac, min_len_frac=0.55):
    H,W=gray.shape
    y0=int(max(0,(y_center_frac-band_half_frac)*H))
    y1=int(min(H,(y_center_frac+band_half_frac)*H))
    band=gray[y0:y1,:]
    y_in=avg_y_of_longest_horizontal(band, min_len_px=min_len_frac*W, strict=True)
    y=y0+y_in; xr=float(W-10)
    return (xr, float(y))

# ---------- template anchored detection ----------
def norm_fids(f: FourFids, W, H) -> FourFidsNorm:
    return FourFidsNorm(
        (f.top_dash[0]/W, f.top_dash[1]/H),
        (f.bottom_dash[0]/W, f.bottom_dash[1]/H),
        (f.top_line_right[0]/W, f.top_line_right[1]/H),
        (f.thin_line_right[0]/W, f.thin_line_right[1]/H),
    )

def detect_four_on_image(gray, tpl_norm: FourFidsNorm, tight=0.05):
    H,W=gray.shape
    # dashes
    x_center=tpl_norm.top_dash[0]; x_hw=max(0.02, tight)
    y_top= max(0.02, tpl_norm.top_dash[1]-0.12)
    y_bot= min(0.98, tpl_norm.bottom_dash[1]+0.12)
    top_dash, bottom_dash = detect_dashes_tight(gray, x_center, x_hw, y_top, y_bot)
    # lines
    band_hw=max(0.015, tight)
    top_line_right  = detect_line_at_right(gray, tpl_norm.top_line_right[1],  band_hw, min_len_frac=0.60)
    thin_line_right = detect_line_at_right(gray, tpl_norm.thin_line_right[1], band_hw, min_len_frac=0.55)
    # enforce ordering
    if top_line_right[1] > thin_line_right[1]:
        top_line_right, thin_line_right = thin_line_right, top_line_right
    return FourFids(top_dash, bottom_dash, top_line_right, thin_line_right)

# ---------- transforms & checks ----------
def getH(src: FourFids, dst: FourFids):
    S=np.float32([src.top_dash, src.bottom_dash, src.top_line_right, src.thin_line_right])
    D=np.float32([dst.top_dash, dst.bottom_dash, dst.top_line_right, dst.thin_line_right])
    return cv2.getPerspectiveTransform(S, D)

def H_is_reasonable(H, W, Ht):
    if H is None or not np.isfinite(H).all(): return False
    corners=np.float32([[0,0],[W,0],[0,Ht],[W,Ht]]).reshape(-1,1,2)
    warped=cv2.perspectiveTransform(corners, H).reshape(-1,2)
    # orientation
    top_y=(warped[0,1]+warped[1,1])/2.0; bot_y=(warped[2,1]+warped[3,1])/2.0
    left_x=(warped[0,0]+warped[2,0])/2.0; right_x=(warped[1,0]+warped[3,0])/2.0
    if not (top_y < bot_y and left_x < right_x): return False
    # side balance
    def dist(a,b): return np.hypot(*(a-b))
    w1=dist(warped[0],warped[1]); w2=dist(warped[2],warped[3])
    h1=dist(warped[0],warped[2]); h2=dist(warped[1],warped[3])
    if max(w1,w2)/max(1.0,min(w1,w2)) > 2.2: return False
    if max(h1,h2)/max(1.0,min(h1,h2)) > 2.2: return False
    return True

def getA(src: FourFids, dst: FourFids):
    S=np.float32([src.top_dash, src.bottom_dash, src.top_line_right])
    D=np.float32([dst.top_dash, dst.bottom_dash, dst.top_line_right])
    return cv2.getAffineTransform(S, D)

def getSimilarity(src: FourFids, dst: FourFids):
    # Use two lines: vector between dashes gives scale on Y; top_line gives Y offset; dash x gives X offset.
    sY = (dst.bottom_dash[1]-dst.top_dash[1]) / max(1e-6, (src.bottom_dash[1]-src.top_dash[1]))
    sX = sY
    R = np.eye(2, dtype=np.float32)
    T = np.array([dst.top_dash[0]-sX*src.top_dash[0], dst.top_dash[1]-sY*src.top_dash[1]], dtype=np.float32)
    M = np.hstack([R*np.array([[sX],[sY]], dtype=np.float32), T.reshape(2,1)])
    return M  # affine 2x3

# ---------- drawing ----------
def draw_bullseye(img, center, radius=16):
    x,y=int(center[0]),int(center[1])
    for col,r in [((0,0,0),radius),((255,255,255),int(radius*0.55)),((0,0,0),int(radius*0.25))]:
        cv2.circle(img,(x,y),r,col,-1,cv2.LINE_AA)
    cv2.circle(img,(x,y),max(1,radius//10),(255,255,255),-1,cv2.LINE_AA)

def add_corner_bullseyes(img, margin=22, radius=16):
    H,W=img.shape[:2]
    for pt in [(margin,margin),(W-margin,margin),(margin,H-margin),(W-margin,H-margin)]:
        draw_bullseye(img, pt, radius)

def draw_points(img, f: FourFids, color=(0,0,255)):
    for pt in [f.top_dash,f.bottom_dash,f.top_line_right,f.thin_line_right]:
        cv2.drawMarker(img,(int(pt[0]),int(pt[1])),color,cv2.MARKER_CROSS,18,2)

# ---------- main ----------
def main():
    ap=argparse.ArgumentParser("Robust OMR alignment with deskew + anchored search + safe fallbacks")
    ap.add_argument("--input",  default=str(Path.cwd()/"in"))
    ap.add_argument("--output", default=str(Path.cwd()/"out"))
    ap.add_argument("--template", default=str(Path.cwd()/"in"/"omr1-10212025125307_Page1.jpg"))
    ap.add_argument("--extensions", default="jpg,jpeg,png,tif,tiff,bmp")
    ap.add_argument("--tight", type=float, default=0.05, help="±fraction search tolerance (default 0.05)")
    ap.add_argument("--write-debug", action="store_true")
    ap.add_argument("--clean-before", action="store_true")
    ap.add_argument("--bull-margin", type=int, default=22)
    ap.add_argument("--bull-radius", type=int, default=16)
    ap.add_argument("--keep-debug", action="store_true",
                help="Keep *_debug.jpg (do not delete after processing)")
    ap.add_argument("--allow-homography", action="store_true",
                help="Try homography; otherwise always use affine (default).")
    args=ap.parse_args()

    in_dir, out_dir = Path(args.input), Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.clean_before:
        for q in out_dir.glob("*"):
            try: q.unlink()
            except Exception: pass
        log_warn(f"Cleaned: {out_dir}")

    exts=tuple("." + e.strip(". ").lower() for e in args.extensions.split(",") if e.strip())
    files=list_images(in_dir, exts)
    if not files:
        log_err(f"No images with extensions {exts} in {in_dir}"); sys.exit(1)

    templ=cv2.imread(str(args.template))
    if templ is None:
        log_err(f"Cannot read template: {args.template}"); sys.exit(1)

    # Deskew the template (should be minimal, but makes normalized positions stable)
    tgray=to_gray(templ)
    tgray_rot, tangle, _ = coarse_deskew_by_header(tgray)
    if abs(tangle) > 0.1:
        templ = cv2.cvtColor(tgray_rot, cv2.COLOR_GRAY2BGR)
    Ht,Wt = templ.shape[:2]

    # Detect template fiducials broadly, then normalize
    def detect_template_fids(gray):
        # generous bands
        top_line_right  = detect_line_at_right(gray, 0.10, 0.10, min_len_frac=0.60)
        thin_line_right = detect_line_at_right(gray, 0.24, 0.08, min_len_frac=0.55)
        # dashes: left 14% ± 5%
        top_dash, bottom_dash = detect_dashes_tight(gray, 0.14, 0.05, 0.02, 0.98)
        # enforce order
        if top_line_right[1] > thin_line_right[1]:
            top_line_right, thin_line_right = thin_line_right, top_line_right
        return FourFids(top_dash, bottom_dash, top_line_right, thin_line_right)

    templ_f = detect_template_fids(to_gray(templ))
    templ_norm = norm_fids(templ_f, Wt, Ht)

    if args.write_debug:
        td = templ.copy(); draw_points(td, templ_f, (255,0,0))
        cv2.imwrite(str(out_dir / "_template_debug.jpg"), td)

    total=len(files); log_info(f"Found {total} file(s). Output → {out_dir.resolve()}")

    for i,p in enumerate(files, start=1):
        prefix=f"[file {i}/{total}]"
        img=cv2.imread(str(p))
        if img is None:
            log_warn(f"{prefix} skip: cannot read {p.name}")
            continue

        # 1) coarse deskew
        g=to_gray(img)
        g_rot, angle, M = coarse_deskew_by_header(g)
        if abs(angle)>0.1:
            img_rot=cv2.warpAffine(img, M, (img.shape[1], img.shape[0]),
                                   flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        else:
            img_rot=img.copy()
            g_rot=g

        # 2) anchored detection (on deskewed image)
        fids = detect_four_on_image(to_gray(img_rot), templ_norm, tight=args.tight)

        # 3) homography → checks → fallbacks
        Hproj = getH(fids, templ_f)
        if not H_is_reasonable(Hproj, img_rot.shape[1], img_rot.shape[0]):
            log_warn(f"{prefix} homography unstable; trying affine.")
            A = getA(fids, templ_f)
            warped = cv2.warpAffine(img_rot, A, (Wt, Ht), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            mode="affine"
        else:
            warped = cv2.warpPerspective(img_rot, Hproj, (Wt, Ht),
                                         flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            mode="homography"

        # if still looks tiny/tilted (extreme), try similarity as last resort
        if min(warped.shape[:2]) < min(Ht,Wt)*0.3:
            log_warn(f"{prefix} warp looks bad; using similarity fallback.")
            S = getSimilarity(fids, templ_f)
            warped = cv2.warpAffine(img_rot, S, (Wt, Ht), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            mode="similarity"

        # 4) bullseyes + save final
        add_corner_bullseyes(warped, margin=args.bull_margin, radius=args.bull_radius)
        out_final = out_dir / f"{p.stem}_final.jpg"
        cv2.imwrite(str(out_final), warped)

        if args.write_debug:
            sd = img_rot.copy(); draw_points(sd, fids, (0,0,255))
            cv2.imwrite(str(out_dir / f"{p.stem}_debug.jpg"), sd)

        # keep only final (unless --keep-debug)
        for q in out_dir.glob(f"{p.stem}_*.*"):
            if q.name == out_final.name:
                continue
            if args.keep_debug and q.name.endswith("_debug.jpg"):
                continue
            try:
                q.unlink()
            except Exception:
                pass

        log_ok(f"{prefix} {p.name} → {out_final.name} ({mode})")

    # global cleanup
    for q in out_dir.glob("*"):
        if q.suffix.lower() == ".jpg" and not q.name.endswith("_final.jpg"):
            if args.keep_debug and q.name.endswith("_debug.jpg"):
                continue
            try:
                q.unlink()
            except Exception:
                pass
    log_info("All done. Only *_final.jpg kept.")
if __name__=="__main__":
    main()
