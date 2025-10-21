#!/usr/bin/env python3
"""
Add four bullseyes to every image in a folder (no alignment, no deskewing).

Usage:
  pip install opencv-python colorama
  python add_bullseyes.py --input "C:/OMR/in" --output "C:/OMR/out" --clean-before
"""

from __future__ import annotations
import argparse, sys
from pathlib import Path
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

# ---------- helpers ----------
def list_images(folder: Path, exts: tuple[str,...]) -> list[Path]:
    return sorted([p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in exts])

def add_bullseyes(img, margin=22, radius=16):
    """Draws black/white/black concentric circles in all 4 corners."""
    H, W = img.shape[:2]
    corners = [(margin, margin), (W - margin, margin),
               (margin, H - margin), (W - margin, H - margin)]
    for (x, y) in corners:
        for col, r in [((0, 0, 0), radius),
                       ((255, 255, 255), int(radius * 0.55)),
                       ((0, 0, 0), int(radius * 0.25))]:
            cv2.circle(img, (int(x), int(y)), max(1, int(r)), col, -1, lineType=cv2.LINE_AA)
        cv2.circle(img, (int(x), int(y)), max(1, radius // 10), (255, 255, 255), -1, lineType=cv2.LINE_AA)

# ---------- main ----------
def main():
    ap = argparse.ArgumentParser("Add four bullseyes to images")
    ap.add_argument("--input",  default=str(Path.cwd() / "in"),  help="Input folder with images")
    ap.add_argument("--output", default=str(Path.cwd() / "out"), help="Output folder")
    ap.add_argument("--extensions", default="jpg,jpeg,png,tif,tiff,bmp", help="Comma-separated list")
    ap.add_argument("--bull-margin", type=int, default=22, help="Pixels from each edge")
    ap.add_argument("--bull-radius", type=int, default=16, help="Outer radius of bullseye (px)")
    ap.add_argument("--suffix", default="_final", help="Suffix added before extension for outputs")
    ap.add_argument("--clean-before", action="store_true", help="Clear output folder before writing")
    args = ap.parse_args()

    in_dir, out_dir = Path(args.input), Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.clean_before:
        for f in out_dir.glob("*"):
            try: f.unlink()
            except Exception: pass
        log_warn(f"Cleaned: {out_dir}")

    exts = tuple("." + e.strip(". ").lower() for e in args.extensions.split(",") if e.strip())
    files = list_images(in_dir, exts)
    if not files:
        log_err(f"No images with {exts} in {in_dir}")
        sys.exit(1)

    total = len(files)
    log_info(f"Found {total} file(s). Output → {out_dir.resolve()}")

    for i, p in enumerate(files, start=1):
        prefix = f"[file {i}/{total}]"
        img = cv2.imread(str(p), cv2.IMREAD_COLOR)
        if img is None:
            log_warn(f"{prefix} skip: cannot read {p.name}")
            continue

        # Add bullseyes in-place
        add_bullseyes(img, margin=args.bull_margin, radius=args.bull_radius)

        # Save
        out_path = out_dir / f"{p.stem}{args.suffix}{p.suffix}"
        ok = cv2.imwrite(str(out_path), img)
        if not ok:
            log_warn(f"{prefix} failed to write {out_path.name}")
        else:
            log_ok(f"{prefix} {p.name} → {out_path.name}")

    log_info("Done.")

if __name__ == "__main__":
    main()
