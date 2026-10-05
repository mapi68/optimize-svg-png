#!/bin/bash

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--trim] [--clean-edges [--solid]] [--keep-icc] <folder>

Optimizes all PNG files in the specified folder by stripping unnecessary
embedded data. With --trim, also removes empty or uniform margins.
With --clean-edges, also cleans the edges of rounded-corner logos/icons.

DESCRIPTION
  Processes all .png files in the given folder.
  Removes profiles, comments, and unnecessary PNG chunks (oxipng --strip all;
  with --keep-icc: --strip safe, which keeps the ICC profile).
  Processing runs in parallel across all available CPU cores.
  Without --trim the work is done by oxipng alone (lossless, and it never
  makes a file larger). With --trim, ImageMagick crops the margins first and
  oxipng runs automatically afterwards.

IMPORTANT
  - Original files are copied to FOLDER_backup_png before being modified.
  - If the backup folder already exists, the script stops for safety.

REQUIREMENTS
  - ImageMagick (uses the 'magick' command on v7+, or 'convert' on v6,
    e.g. Ubuntu 18.04)
  If missing, the script attempts to install it automatically via apt.
  ImageMagick is only needed with --trim (oxipng cannot crop), or as a
  fallback when oxipng cannot be installed.
  - oxipng (lossless PNG optimiser). If missing, the latest release is
    downloaded from https://github.com/oxipng/oxipng/releases/latest/download
    for the current architecture (x86_64 or aarch64, static musl build) and
    installed in /usr/local/bin (sudo is used when needed).
    If it cannot be installed, the script warns and falls back to ImageMagick.
  - python3 with Pillow and NumPy: only needed with --clean-edges. If missing,
    the script attempts to install python3-pil and python3-numpy via apt.

ARGUMENTS
  --trim     Trim excess uniform background pixels at edges (0% colour
             tolerance, only perfectly identical pixels are removed).
             Default: preserve original canvas dimensions.

  --clean-edges
             Clean the edge of logos/icons (e.g. picons) shaped like a
             rounded rectangle with transparent corners:
               - removes the light 1-4 px halo along the border (the edge
                 pixels get the colour of the pixels just inside)
               - redraws the corners as smooth anti-aliased curves
               - leaves the inside of the logo unchanged
             Files without transparent pixels are skipped, and so are shapes
             that are not a rounded rectangle. Not meant for photos. The
             result is 8-bit RGBA and always replaces the original (the
             original stays in the backup folder).

  --solid    Only with --clean-edges: also make the inside of the logo fully
             opaque (alpha 255). Use it when the logo is slightly see-through
             by mistake. Without it the inside is left unchanged.

  --keep-icc Keep the embedded ICC colour profile (strip everything else).
             Default: the ICC profile is removed too, which can shift colours
             on images that are not plain sRGB (Display P3, Adobe RGB...).

  <folder>   Path to the folder containing the .png files
             Accepts both absolute and relative paths

EXAMPLES
  $(basename "$0") ./my_pngs
  $(basename "$0") --trim ./my_pngs
  $(basename "$0") --clean-edges ./my_pngs
  $(basename "$0") --clean-edges --solid ./my_pngs
  $(basename "$0") /home/user/projects/images

NOTES
  - Without --trim: oxipng -o 4 --strip all -p (ImageMagick is not used).
  - With --trim: ImageMagick "-fuzz 0% -trim +repage -strip", then oxipng.
  - With --clean-edges: a built-in Python helper cleans the edges first, then
    the other steps run as usual. The edge width scales with the image size.
  - If oxipng is unavailable: ImageMagick "+repage -strip" (or with --trim).
  - The ImageMagick stage only replaces a file if the result is strictly
    smaller. Otherwise the original is kept (re-encoding an already optimised PNG can make it larger).
  - With --trim, images that would collapse to a single pixel are left as is.
  - File permissions are preserved. Extensions are matched case-insensitively.
  - Exit status is 1 if at least one file failed.
  - oxipng runs on every file ImageMagick did not fail on. It only rewrites
    a file when the result is smaller and keeps permissions (-p).
  - The -strip flag removes embedded ICC profiles, comments, and EXIF chunks.
  - The -fuzz 0% ensures only perfectly uniform pixels at edges are trimmed.
USAGE
}

# Argument check (help)
if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

# Parse arguments
TRIM=0
CLEAN_EDGES=0
SOLID=0
KEEP_ICC=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --trim) TRIM=1 ;;
    --clean-edges) CLEAN_EDGES=1 ;;
    --solid) SOLID=1 ;;
    --keep-icc) KEEP_ICC=1 ;;
    -*) echo "Error: unknown option '$arg'" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

if [[ $SOLID -eq 1 && $CLEAN_EDGES -eq 0 ]]; then
  echo "Error: --solid can only be used together with --clean-edges." >&2
  exit 1
fi

if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
  echo "Error: exactly one folder argument required." >&2
  usage
  exit 1
fi

# Resolve absolute path of the folder
DIR=$(realpath "${POSITIONAL[0]}")

# Verify the folder exists
if [[ ! -d "$DIR" ]]; then
  echo "Error: '${POSITIONAL[0]}' is not a valid folder." >&2
  exit 1
fi

# Detect ImageMagick binary: 'magick' (IM7+) or fallback to 'convert' (IM6,
# e.g. Ubuntu 18.04, which ships ImageMagick 6.9.7 without the 'magick' command).
detect_or_install_imagemagick() {
  if command -v magick &>/dev/null; then
    IM_BIN=$(command -v magick)
    return
  fi
  if command -v convert &>/dev/null; then
    IM_BIN=$(command -v convert)
    return
  fi

  echo "Missing dependency: ImageMagick. Attempting installation..."
  sudo apt update -qq && sudo apt install -y imagemagick

  if command -v magick &>/dev/null; then
    IM_BIN=$(command -v magick)
  elif command -v convert &>/dev/null; then
    IM_BIN=$(command -v convert)
  else
    echo "Error: installation of 'imagemagick' failed. Please install it manually." >&2
    exit 1
  fi

  echo "  ✓ ImageMagick installed successfully."
}

# oxipng: use the one in PATH, otherwise download the latest release for this
# architecture from GitHub and install it in /usr/local/bin.
# The asset name contains the version (oxipng-<ver>-<target>.tar.gz), so the
# version is read from the redirect of /releases/latest (no API rate limits).
OXIPNG_RELEASES="https://github.com/oxipng/oxipng/releases"
OXIPNG_DEST="/usr/local/bin"

install_oxipng() {
  local target tag ver url tmp bin sudo_cmd=""
  case "$(uname -m)" in
    x86_64|amd64)  target="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
    *) echo "  ✗ oxipng: no prebuilt Linux binary for architecture '$(uname -m)'." >&2; return 1 ;;
  esac

  if ! command -v curl &>/dev/null; then
    echo "  curl not found. Installing..."
    sudo apt update -qq && sudo apt install -y curl || return 1
  fi

  tag=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$OXIPNG_RELEASES/latest") || {
    echo "  ✗ oxipng: cannot reach GitHub." >&2; return 1; }
  tag=${tag##*/}
  ver=${tag#v}
  if [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    echo "  ✗ oxipng: cannot determine the latest version (got '$tag')." >&2
    return 1
  fi

  url="$OXIPNG_RELEASES/latest/download/oxipng-${ver}-${target}.tar.gz"
  echo "  Downloading oxipng $ver ($target)..."
  OXIPNG_TMP=$(mktemp -d)   # removed by the EXIT trap too (Ctrl+C, kill)
  tmp="$OXIPNG_TMP"
  if ! curl -fsSL "$url" -o "$tmp/oxipng.tar.gz" || ! tar -xzf "$tmp/oxipng.tar.gz" -C "$tmp"; then
    echo "  ✗ oxipng: download or extraction failed ($url)." >&2
    rm -rf "$tmp"; return 1
  fi
  bin=$(find "$tmp" -type f -name oxipng | head -n1)
  if [[ -z "$bin" ]]; then
    echo "  ✗ oxipng: binary not found in the archive." >&2
    rm -rf "$tmp"; return 1
  fi

  [[ -w "$OXIPNG_DEST" ]] || sudo_cmd="sudo"
  if ! $sudo_cmd install -m 0755 "$bin" "$OXIPNG_DEST/oxipng"; then
    echo "  ✗ oxipng: cannot install into $OXIPNG_DEST." >&2
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  echo "  ✓ oxipng $ver installed in $OXIPNG_DEST"
}

OXIPNG_BIN=""
OXIPNG_WARNING=""
OXIPNG_TMP=""
# Always clean up temporary files (download, extracted archive, error list),
# also when the script is interrupted.
trap 'rm -rf "${OXIPNG_TMP:-}" "${FAILED_LIST:-}" "${CE_PY_DIR:-}"' EXIT
trap 'exit 130' INT TERM
if command -v oxipng &>/dev/null; then
  OXIPNG_BIN=$(command -v oxipng)
else
  echo "Missing dependency: oxipng. Attempting installation..."
  if install_oxipng && [[ -x "$OXIPNG_DEST/oxipng" ]]; then
    OXIPNG_BIN="$OXIPNG_DEST/oxipng"
  else
    OXIPNG_WARNING="oxipng is not available: falling back to ImageMagick only."
    echo "Warning: $OXIPNG_WARNING" >&2
  fi
fi

# ImageMagick is only needed for --trim (oxipng cannot crop), or as a fallback
# when oxipng is unavailable.
USE_IM=0
if [[ $TRIM -eq 1 || -z "$OXIPNG_BIN" ]]; then
  USE_IM=1
  detect_or_install_imagemagick
fi

# --clean-edges needs python3 with Pillow and NumPy.
python_deps_ok() { python3 -c 'import numpy, PIL' &>/dev/null; }

detect_or_install_python_deps() {
  python_deps_ok && return
  echo "Missing dependency: python3 with Pillow and NumPy. Attempting installation..."
  sudo apt update -qq && sudo apt install -y python3 python3-pil python3-numpy

  if ! python_deps_ok; then
    echo "Error: installation of 'python3-pil' and 'python3-numpy' failed. Please install them manually." >&2
    exit 1
  fi

  echo "  ✓ Python dependencies installed successfully."
}

# The edge-cleaning helper is embedded so that the script stays a single file.
write_clean_edges_helper() {
  cat > "$1" <<'PYEOF'
"""Edge clean-up for rounded-rectangle logos/icons (helper of optimize_png.bash).

usage: clean_edges.py SRC DST SOLID(0|1)
exit:  0 cleaned | 2 no transparent pixels | 3 not usable (too small, or not a
       rounded rectangle) | 1 error
"""
import sys

import numpy as np
from PIL import Image


def erode(mask, radius):
    """Erode with a disk; the area outside the canvas counts as empty."""
    h, w = mask.shape
    p = np.zeros((h + 2 * radius, w + 2 * radius), bool)
    p[radius:radius + h, radius:radius + w] = mask
    out = mask.copy()
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            if dx * dx + dy * dy <= radius * radius:
                out &= p[radius + dy:radius + dy + h, radius + dx:radius + dx + w]
    return out


def rounded_rect(bw, bh, r):
    """Pixel-centre mask of a bw x bh rounded rectangle with corner radius r."""
    x = np.arange(bw) + 0.5
    y = (np.arange(bh) + 0.5)[:, None]
    dx = x - np.clip(x, r, bw - r)
    dy = y - np.clip(y, r, bh - r)
    return dx * dx + dy * dy <= r * r


def fit_radius(crop):
    """Corner radius of the rounded rectangle that best matches the mask."""
    bh, bw = crop.shape
    rmax = min(bw, bh) / 2.0

    def miss(r):
        return int((rounded_rect(bw, bh, r) != crop).sum())

    step = max(1.0, rmax / 100.0)
    best = min(np.arange(0.0, rmax + step, step), key=miss)
    best = min(np.arange(max(0.0, best - step), min(rmax, best + step) + 0.05, 0.1), key=miss)
    return float(best), miss(best)


def coverage(bw, bh, r):
    """Anti-aliased coverage (0..1) of a bw x bh rounded rectangle: the straight
    parts are exact, each corner is supersampled."""
    cov = np.ones((bh, bw), np.float32)
    k = min(int(np.ceil(r)), bw // 2, bh // 2)
    if k > 0:
        ss = int(max(2, min(16, 2048 // k)))
        p = (np.arange(k * ss) + 0.5) / ss
        inside = np.minimum(p[None, :] - r, 0) ** 2 + np.minimum(p[:, None] - r, 0) ** 2 <= r * r
        c = inside.reshape(k, ss, k, ss).mean(axis=(1, 3))
        cov[:k, :k] = c
        cov[:k, bw - k:] = c[:, ::-1]
        cov[bh - k:, :k] = c[::-1, :]
        cov[bh - k:, bw - k:] = c[::-1, ::-1]
    return cov


def fill_halo(rgb, core, halo):
    """Give every pixel outside `core` the average colour of nearby core pixels."""
    h, w = core.shape
    valid = core.copy()
    out = np.where(core[..., None], rgb, 0).astype(np.float32)
    for _ in range(halo + 2):
        pv = np.zeros((h + 2, w + 2), bool)
        pv[1:-1, 1:-1] = valid
        po = np.zeros((h + 2, w + 2, 3), np.float32)
        po[1:-1, 1:-1] = out
        n = np.zeros((h, w), np.float32)
        s = np.zeros((h, w, 3), np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx or dy:
                    n += pv[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]
                    s += po[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]
        new = ~valid & (n > 0)
        out[new] = s[new] / n[new][:, None]
        valid |= new
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


def main(src, dst, solid):
    im = Image.open(src)
    icc = im.info.get("icc_profile")
    a = np.array(im.convert("RGBA"))
    h, w = a.shape[:2]
    alpha = a[..., 3]

    shape = alpha >= 128  # the silhouette
    if shape.all():
        return 2
    ys, xs = np.nonzero(shape)
    if len(ys) == 0:
        return 3
    x0, x1, y0, y1 = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    if min(bw, bh) < 8:
        return 3

    # the silhouette must be a rounded rectangle
    r, miss = fit_radius(shape[y0:y1 + 1, x0:x1 + 1])
    if miss > 0.03 * 2 * (bw + bh) + 8:
        return 3
    # the light halo comes from resizing, so its width grows with the image: 2-4 px
    halo = int(min(4, max(2, round(min(w, h) / 200.0))))
    core = erode(shape, halo)
    if not core.any():
        return 3

    # new anti-aliased edge: the exact rounded rectangle
    mask = np.zeros((h, w), np.float32)
    mask[y0:y1 + 1, x0:x1 + 1] = 255.0 * coverage(bw, bh, r)

    if solid:  # fully opaque inside, anti-aliased only on the edge
        new_alpha = mask
    else:  # keep the original interior alpha, only the edge is rebuilt
        new_alpha = np.where(core, alpha, mask * float(alpha.max()) / 255.0)

    new_alpha = np.clip(np.rint(new_alpha), 0, 255).astype(np.uint8)
    rgb = fill_halo(a[..., :3], core, halo)
    rgb[new_alpha == 0] = 0  # fully transparent pixels carry no colour
    out = np.dstack([rgb, new_alpha])
    # no extra compression here: oxipng (or ImageMagick) does that afterwards
    Image.fromarray(out).save(dst, "PNG", **({"icc_profile": icc} if icc else {}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3] == "1"))
    except Exception as e:  # noqa: BLE001
        print("clean_edges: %s" % e, file=sys.stderr)
        sys.exit(1)
PYEOF
}

CE_PY_DIR=""
CE_PY_FILE=""
if [[ $CLEAN_EDGES -eq 1 ]]; then
  detect_or_install_python_deps
  CE_PY_DIR=$(mktemp -d)
  CE_PY_FILE="$CE_PY_DIR/clean_edges.py"
  write_clean_edges_helper "$CE_PY_FILE"
fi

# Build the list of PNG files
mapfile -d '' -t FILES < <(find "$DIR" -maxdepth 1 -type f -iname "*.png" -print0 | sort -z)
TOTAL=${#FILES[@]}

if [[ $TOTAL -eq 0 ]]; then
  echo "Error: no PNG files found in '$DIR'." >&2
  exit 1
fi

# Create backup folder (after file check, to avoid creating empty folders)
BACKUP_DIR="${DIR}_backup_png"
if [[ -d "$BACKUP_DIR" ]]; then
  echo "Error: backup folder '$BACKUP_DIR' already exists." >&2
  echo "       Rename or delete it before proceeding." >&2
  exit 1
fi
mkdir -p "$BACKUP_DIR"
cp -- "${FILES[@]}" "$BACKUP_DIR"/
echo "Backup saved to: $BACKUP_DIR"
echo "--------------------------------------------------------"

CORES=$(nproc)
echo "Starting PNG optimization in: $DIR"
echo "Files found: $TOTAL  |  CPU cores: $CORES"
echo "--------------------------------------------------------"

TIME_START=$(date +%s)

FAILED_LIST=$(mktemp)

# oxipng strip mode: "all" removes every non-critical chunk including the ICC
# profile (same result as ImageMagick -strip); "safe" keeps rendering-related
# chunks such as the ICC profile (--keep-icc).
if [[ $KEEP_ICC -eq 1 ]]; then OX_STRIP="safe"; else OX_STRIP="all"; fi

# --clean-edges pass: runs first, in parallel. The cleaned file replaces the
# original (the original is in the backup folder). Helper exit codes:
# 0 = cleaned, 2 = no transparent pixels, 3 = too small or not a rounded
# rectangle, anything else = error.
clean_edges_one() {
  local f="$1" name tmp rc err
  name=$(basename "$f")
  tmp=$(mktemp --suffix=".png")
  err=$(python3 "$CE_PY_FILE" "$f" "$tmp" "$SOLID" 2>&1 >/dev/null); rc=$?
  err=${err##*$'\n'}   # last line of the message only
  case $rc in
    0) if [[ -s "$tmp" ]] && cp -- "$tmp" "$f"; then
         echo "  ✓ $name (edges cleaned)"
       else
         echo "  ✗ Error writing: $name" >&2
         printf '%s\n' "$name" >> "$FAILED_LIST"
       fi ;;
    2) echo "  = $name (no transparent pixels, edge cleaning skipped)" ;;
    3) echo "  = $name (not a rounded rectangle or too small, edge cleaning skipped)" ;;
    *) echo "  ✗ Error: $name${err:+ ($err)}" >&2
       printf '%s\n' "$name" >> "$FAILED_LIST" ;;
  esac
  rm -f "$tmp"
}

if [[ $CLEAN_EDGES -eq 1 ]]; then
  if [[ $SOLID -eq 1 ]]; then echo "Step: clean edges (solid inside)"; else echo "Step: clean edges"; fi
  echo "--------------------------------------------------------"
  export CE_PY_FILE SOLID FAILED_LIST
  export -f clean_edges_one
  printf '%s\0' "${FILES[@]}" | xargs -0 -P "$CORES" -I {} bash -c 'clean_edges_one "$1"' _ {}
  echo "--------------------------------------------------------"
fi

if [[ $USE_IM -eq 1 ]]; then
  # Build ImageMagick options
  # NOTE: -fuzz must come BEFORE -trim to have any effect.
  if [[ $KEEP_ICC -eq 1 ]]; then
    STRIP_OPTS="+profile !icc,*"
    STRIP_LABEL="strip metadata (ICC profile kept)"
  else
    STRIP_OPTS="-strip"
    STRIP_LABEL="strip metadata"
  fi
  if [[ $TRIM -eq 1 ]]; then
    MAGICK_OPTS="-fuzz 0% -trim +repage $STRIP_OPTS"
    echo "Mode: trim uniform margins + $STRIP_LABEL${OXIPNG_BIN:+, then oxipng}"
  else
    MAGICK_OPTS="+repage $STRIP_OPTS"
    echo "Mode: $STRIP_LABEL only (oxipng unavailable)"
  fi
  echo "--------------------------------------------------------"

  MAGICK_BIN="$IM_BIN"
  # identify is "magick identify" on IM7, plain "identify" on IM6
  if [[ "$(basename "$IM_BIN")" == "magick" ]]; then IDENT_CMD="$IM_BIN identify"; else IDENT_CMD="identify"; fi
  export MAGICK_BIN MAGICK_OPTS FAILED_LIST IDENT_CMD

  # Worker: optimise one file. The result replaces the original (via cp, so mode,
  # owner and timestamps semantics of the existing file are kept) only if it is
  # valid and strictly smaller.
  optimize_one() {
    local f="$1" name tmp before after dim orig_dim
    name=$(basename "$f")
    tmp=$(mktemp --suffix=".png")
    local -a opts
    read -ra opts <<< "$MAGICK_OPTS"
    if ! "$MAGICK_BIN" "$f" "${opts[@]}" "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
      rm -f "$tmp"
      echo "  ✗ Error: $name" >&2
      printf '%s\n' "$name" >> "$FAILED_LIST"
      return
    fi
    before=$(stat -c '%s' "$f")
    after=$(stat -c '%s' "$tmp")
    # Guard: trim that collapses a larger image to 1x1 is never wanted
    dim=$($IDENT_CMD -format '%w %h' "$tmp" 2>/dev/null)
    orig_dim=$($IDENT_CMD -format '%w %h' "${f}[0]" 2>/dev/null)
    if [[ "$dim" == "1 1" && -n "$orig_dim" && "$orig_dim" != "1 1" ]]; then
      rm -f "$tmp"
      echo "  = $name (uniform image, trim skipped, original kept)"
      return
    fi
    if [[ $after -lt $before ]]; then
      cp -- "$tmp" "$f" && echo "  ✓ $name" || { echo "  ✗ Error writing: $name" >&2; printf '%s\n' "$name" >> "$FAILED_LIST"; }
    else
      echo "  = $name (already optimal, original kept)"
    fi
    rm -f "$tmp"
  }
  export -f optimize_one

  # Parallel optimization (NUL-separated: safe for quotes, spaces, unicode)
  printf '%s\0' "${FILES[@]}" | xargs -0 -P "$CORES" -I {} bash -c 'optimize_one "$1"' _ {}
else
  echo "Mode: oxipng only, lossless (use --trim to also trim margins)"
  echo "--------------------------------------------------------"
fi

# oxipng pass (lossless recompression). Without --trim it is the only pass.
# Files ImageMagick failed on are skipped, so the same error is not reported twice.
# -p preserves permissions/timestamps, files are rewritten only if the result
# is smaller. oxipng is multi-threaded by itself.
OXIPNG_FAILED=0
if [[ -n "$OXIPNG_BIN" ]]; then
  OX_FILES=()
  for f in "${FILES[@]}"; do
    grep -Fxq -- "$(basename "$f")" "$FAILED_LIST" || OX_FILES+=("$f")
  done
  echo "--------------------------------------------------------"
  echo "Running oxipng ($("$OXIPNG_BIN" --version 2>/dev/null | head -n1)) on ${#OX_FILES[@]} file(s)..."
  if [[ ${#OX_FILES[@]} -gt 0 ]]; then
    "$OXIPNG_BIN" -o 4 --strip "$OX_STRIP" -p -q -t "$CORES" -- "${OX_FILES[@]}" || OXIPNG_FAILED=1
  fi
  if [[ $OXIPNG_FAILED -eq 1 ]]; then
    echo "  ✗ oxipng reported errors on some files (see messages above)." >&2
  else
    echo "  ✓ oxipng done."
  fi
fi

echo "--------------------------------------------------------"
TIME_END=$(date +%s)
ELAPSED=$((TIME_END - TIME_START))
echo "Processing completed in ${ELAPSED}s using $CORES cores."

echo ""
echo "========================================================"
echo "                        REPORT"
echo "========================================================"

SIZE_BEFORE=0
SIZE_AFTER=0

# Dynamic column width based on longest filename
MAX_NAME=0
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  [[ ${#name} -gt $MAX_NAME ]] && MAX_NAME=${#name}
done
TOTAL_LABEL="TOTAL ($TOTAL files)"
[[ ${#TOTAL_LABEL} -gt $MAX_NAME ]] && MAX_NAME=${#TOTAL_LABEL}
COL=$((MAX_NAME + 2))

fmt_size() {
  local bytes=$1
  if   [[ $bytes -ge 1048576 ]]; then
    awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b / 1048576 }'
  elif [[ $bytes -ge 1024 ]]; then
    awk -v b="$bytes" 'BEGIN { printf "%.2f KB", b / 1024 }'
  else
    printf "%d B" "$bytes"
  fi
}

SEP=$(printf '%*s' "$((COL + 36))" '' | tr ' ' '-')
echo "$SEP"

for f in "${FILES[@]}"; do
  name=$(basename "$f")
  backup="$BACKUP_DIR/$name"

  before=$(stat -c '%s' "$backup" 2>/dev/null || echo 0)
  after=$(stat -c '%s' "$f" 2>/dev/null || echo 0)

  SIZE_BEFORE=$((SIZE_BEFORE + before))
  SIZE_AFTER=$((SIZE_AFTER + after))

  if [[ $before -gt 0 ]]; then
    saved=$((before - after))
    pct=$(awk -v s="$saved" -v b="$before" 'BEGIN { printf "%.1f", (s / b) * 100 }')
  else
    pct="0.0"
  fi

  printf "  %-${COL}s  %10s  →  %10s  (%s%%)\n" \
    "$name" "$(fmt_size "$before")" "$(fmt_size "$after")" "$pct"
done

echo "$SEP"
TOTAL_SAVED=$((SIZE_BEFORE - SIZE_AFTER))
if [[ $SIZE_BEFORE -gt 0 ]]; then
  TOTAL_PCT=$(awk -v s="$TOTAL_SAVED" -v b="$SIZE_BEFORE" 'BEGIN { printf "%.1f", (s / b) * 100 }')
else
  TOTAL_PCT="0.0"
fi

printf "  %-${COL}s  %10s  →  %10s\n" \
  "$TOTAL_LABEL" "$(fmt_size "$SIZE_BEFORE")" "$(fmt_size "$SIZE_AFTER")"
printf "  Space saved: %s  (%s%%)\n" "$(fmt_size "$TOTAL_SAVED")" "$TOTAL_PCT"
echo "========================================================"

[[ -n "$OXIPNG_WARNING" ]] && echo "Warning: $OXIPNG_WARNING" >&2

FAILED_COUNT=$(wc -l < "$FAILED_LIST")
if [[ $FAILED_COUNT -gt 0 ]]; then
  echo "Warning: $FAILED_COUNT file(s) failed:" >&2
  sed 's/^/  - /' "$FAILED_LIST" >&2
fi
if [[ $FAILED_COUNT -gt 0 || $OXIPNG_FAILED -eq 1 ]]; then
  exit 1
fi
