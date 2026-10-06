#!/bin/bash
#
# optimize_svg - Batch SVG optimiser with text-to-path conversion
# Optimised for Debian / WSL2 Debian
#
# INSTALLATION (after downloading optimize_svg.bash):
#   mkdir -p ~/.local/bin
#   cp optimize_svg.bash ~/.local/bin/optimize_svg
#   chmod +x ~/.local/bin/optimize_svg

usage() {
  cat <<EOF
Usage: $(basename "$0") [--trim] [--keep-ids] <folder>

Converts text to path, inlines CSS styles and optimises all SVG files
in the specified folder. Equivalent to Inkscape's "Optimised SVG Output"
extension applied to every file.
Inkscape runs in shell mode (single launch), Python and scour run in
parallel using all available CPU cores.

DESCRIPTION
  Processes all .svg files in the given folder applying:

  Step 1 - Inkscape (sequential, single launch via --shell):
    - Converts <text> and <tspan> elements to <path>
    - Files are no longer dependent on locally installed fonts
    - By default preserves the original canvas (viewBox/width/height)
    - With --trim: fits canvas to drawing (removes empty margins)

  Step 2 - Python + lxml (parallel, all CPU cores):
    - Parses SVG with lxml for reliable XML handling
    - Inlines presentation properties (fill, stroke, opacity...) of simple
      .class rules on each element, then removes the class attributes
    - Class rules override presentation attributes, as in a browser
    - Files whose CSS cannot be inlined faithfully (@media, @keyframes,
      :hover, tag or compound selectors...) are left untouched, so dark mode,
      animations and hover effects are never lost

  Step 3 - scour (parallel, all CPU cores):
    - Reduces decimal precision to 5 significant digits
    - Shortens colour values
    - Converts CSS attributes to XML attributes
    - Collapses nested groups
    - Removes the XML declaration, metadata and comments
    - Never drops width/height, so the intrinsic size of the image is preserved
    - Removes unused IDs and shortens the remaining ones (see --keep-ids)
    - Removes xml:space="preserve" and the whitespace-only text nodes it
      protects (otherwise blank lines and tabs from the source file survive)
    - No pretty-printing (smallest output)

  Step 4 - Integrity check (parallel, all CPU cores):
    - Parses each output file with lxml: valid XML with an <svg> root
    - On failure: restores the original from backup and flags the file

# IMPORTANT
  - Original files are copied to FOLDER_NAME_backup_svg before being modified.
  - Not suitable for animated or interactive SVG (SMIL, CSS animations, scripts).
  - File permissions are preserved. Extensions are matched case-insensitively.
  - Exit status is 1 if at least one file failed or was restored.
  - If the backup folder already exists, the script stops for safety.

REQUIREMENTS
  - Inkscape 1.4 or higher  (auto-installed via apt if missing)
  - Python 3               (auto-installed via apt if missing)
  - python3-lxml           (auto-installed via apt if missing)
  - scour                   (auto-installed via apt if missing)

ARGUMENTS
  --trim     Fit canvas to drawing content (removes empty margins).
             Warning: may clip edges on files with strokes near the border.
             Default: preserve the original canvas dimensions.

  --keep-ids Do not remove/shorten IDs. Use it when IDs are referenced from
             outside the file (JavaScript, external CSS, links to #anchors).

  <folder>   Path to the folder containing the .svg files
             Accepts both absolute and relative paths

INSTALLATION
  The file is downloaded as: optimize_svg.bash

  mkdir -p ~/.local/bin
  cp optimize_svg.bash ~/.local/bin/optimize_svg
  chmod +x ~/.local/bin/optimize_svg

EXAMPLES (after installation)
  optimize_svg ./my_svgs
  optimize_svg /home/user/projects/logos
  optimize_svg /mnt/c/Users/user/Desktop/svg
  optimize_svg --trim ./my_svgs
EOF
}

# Argument check (help)
if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

# Parse arguments
TRIM=0
KEEP_IDS=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --trim) TRIM=1 ;;
    --keep-ids) KEEP_IDS=1 ;;
    -*) echo "Error: unknown option '$arg'" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
  echo "Error: exactly one folder argument required." >&2
  usage
  exit 1
fi

# Resolve absolute path of the folder
DIR=$(realpath "${POSITIONAL[0]}")

# Check that the folder exists
if [[ ! -d "$DIR" ]]; then
  echo "Error: '${POSITIONAL[0]}' is not a valid folder." >&2
  exit 1
fi

# Temporary files: cleaned up on any exit
# WORK is created in $HOME (not /tmp) because a snap-installed Inkscape has
# its own private /tmp and could not read the command list written there.
# The name must not start with a dot: snap apps cannot read hidden folders
# in $HOME.
WORK=$(mktemp -d -p "$HOME")
CORRUPTED_LIST=$(mktemp)
SCOUR_FAILED_LIST=$(mktemp)
INLINE_PY=$(mktemp --suffix=".py")
trap 'rm -rf "$WORK" "$CORRUPTED_LIST" "$SCOUR_FAILED_LIST" "$INLINE_PY"' EXIT

# Check dependencies, install if missing
APT_UPDATED=0
apt_install() {
  if [[ $APT_UPDATED -eq 0 ]]; then sudo apt update -qq; APT_UPDATED=1; fi
  sudo apt install -y "$@"
}

if ! command -v inkscape &>/dev/null; then
  echo "Inkscape not found. Installing..."
  apt_install inkscape
fi
if ! command -v inkscape &>/dev/null; then
  echo "Error: Inkscape is not available. Please install it manually." >&2
  exit 1
fi
INK_VER=$(inkscape --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
if [[ "${INK_VER%%.*}" -lt 1 ]]; then
  echo "Error: Inkscape $INK_VER is too old (1.x required, shell actions are not supported)." >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "Python 3 not found. Installing..."
  apt_install python3
fi
if ! python3 -c "import lxml" &>/dev/null; then
  echo "python3-lxml not found. Installing..."
  apt_install python3-lxml
fi
if ! command -v scour &>/dev/null; then
  echo "scour not found. Installing..."
  apt_install scour
fi
for dep in python3 scour; do
  command -v "$dep" &>/dev/null || { echo "Error: '$dep' is not available." >&2; exit 1; }
done

# scour options (based on the Inkscape "Optimised SVG Output" extension):
# - No --enable-viewboxing: it drops width/height and with them the intrinsic
#   size of the image.
# - No pretty-printing: indentation only makes files bigger.
SCOUR_OPTS=(
  "--set-precision=5"          # 5 significant digits for coordinates
  "--strip-xml-prolog"         # remove the XML declaration
  "--remove-metadata"          # remove metadata
  "--enable-comment-stripping" # remove comments
  "--indent=none"              # smallest output
  "--strip-xml-space"          # drop xml:space="preserve" so that the blank
                               # lines/tabs left by the source editor are removed
  "--renderer-workaround"      # work around renderer bugs
)
if [[ $KEEP_IDS -eq 0 ]]; then
  SCOUR_OPTS+=("--enable-id-stripping" "--shorten-ids")
fi

# Build list of SVG files (NUL-separated, case-insensitive extension)
mapfile -d '' -t FILES < <(find "$DIR" -maxdepth 1 -type f -iname "*.svg" -print0 | sort -z)
TOTAL=${#FILES[@]}

if [[ $TOTAL -eq 0 ]]; then
  echo "Error: no SVG files found in '$DIR'." >&2
  exit 1
fi

# Create backup folder (after file check, to avoid creating an empty folder)
BACKUP_DIR="${DIR}_backup_svg"
if [[ -d "$BACKUP_DIR" ]]; then
  echo "Error: backup folder '$BACKUP_DIR' already exists." >&2
  echo "       Rename or delete it before proceeding." >&2
  exit 1
fi
mkdir -p "$BACKUP_DIR"
cp -- "${FILES[@]}" "$BACKUP_DIR"/
echo "Backup saved to: $BACKUP_DIR"

CORES=$(nproc)
echo "Starting SVG optimisation in: $DIR"
echo "Files found: $TOTAL  |  CPU cores: $CORES  |  Inkscape: $INK_VER"
echo "--------------------------------------------------------"
if [[ $TRIM -eq 1 ]]; then CANVAS_LABEL="trim canvas to drawing"; else CANVAS_LABEL="preserve canvas"; fi
if [[ $KEEP_IDS -eq 1 ]]; then IDS_LABEL="keep IDs"; else IDS_LABEL="shorten IDs"; fi
echo "Mode: text to path + $CANVAS_LABEL + inline CSS, then scour (strip metadata, $IDS_LABEL)"
echo "--------------------------------------------------------"

TIME_START=$(date +%s)

# STEP 1: text-to-path with Inkscape
# Every file is copied to a temporary name without spaces or ';' (a ';' in a
# file name breaks the Inkscape shell and can even crash it, which would
# silently skip all the following files). Inkscape reads WORK/in_N.svg and
# writes WORK/out_N.svg; the result is copied over the original only if it
# exists and is not empty. If a session dies, the missing files are retried
# one by one in a fresh session.
if [[ $TRIM -eq 1 ]]; then
  EXPORT_AREA="export-area-drawing"
  echo "[1/4] Inkscape: converting text to path, trimming canvas (sequential)..."
else
  EXPORT_AREA="export-area-page"
  echo "[1/4] Inkscape: converting text to path, preserving canvas (sequential)..."
fi

: > "$WORK/commands.txt"
for i in "${!FILES[@]}"; do
  cp -- "${FILES[$i]}" "$WORK/in_$i.svg"
  printf 'file-open:%s; select-all; export-text-to-path; %s; export-plain-svg; export-filename:%s; export-do; file-close\n' \
    "$WORK/in_$i.svg" "$EXPORT_AREA" "$WORK/out_$i.svg" >> "$WORK/commands.txt"
done
inkscape --shell < "$WORK/commands.txt" >/dev/null 2>"$WORK/inkscape.log"

INK_FAILED=0
for i in "${!FILES[@]}"; do
  if [[ ! -s "$WORK/out_$i.svg" ]]; then
    sed -n "$((i + 1))p" "$WORK/commands.txt" | inkscape --shell >/dev/null 2>>"$WORK/inkscape.log"
  fi
  if [[ -s "$WORK/out_$i.svg" ]]; then
    cp -- "$WORK/out_$i.svg" "${FILES[$i]}"   # cp onto the file keeps its permissions
  else
    echo "  ✗ Warning: Inkscape failed on $(basename "${FILES[$i]}"): text not converted" >&2
    INK_FAILED=$((INK_FAILED + 1))
  fi
done
echo "      Done."
echo "--------------------------------------------------------"

# STEP 2: inline CSS class styles (Python + lxml, parallel)
#
# Only rules whose selector is a single plain class (.a) and whose properties
# are all presentation properties are inlined. Anything else (@media,
# @keyframes, @font-face, :hover, tag/id/compound selectors, unknown
# properties) makes the script leave the <style> block and the involved
# classes untouched, so nothing is lost or frozen into a wrong state.
# Class rules win over presentation attributes (like in a browser) but not
# over an inline style="" attribute. Invalid XML is reported, not "recovered".
cat > "$INLINE_PY" << 'PYEOF'
import re
import sys
from lxml import etree

SVG_NS = "http://www.w3.org/2000/svg"

PRESENTATION_PROPS = {
  "fill", "fill-opacity", "fill-rule",
  "stroke", "stroke-width", "stroke-opacity", "stroke-linecap",
  "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
  "opacity", "display", "visibility",
  "font-family", "font-size", "font-style", "font-weight",
  "color", "stop-color", "stop-opacity",
}

path = sys.argv[1]

try:
  tree = etree.parse(path)
except etree.XMLSyntaxError as e:
  sys.stderr.write(f"{path}: invalid XML: {e}\n")
  sys.exit(2)
root = tree.getroot()

style_els = list(root.iter(f"{{{SVG_NS}}}style"))
if not style_els:
  sys.exit(0)

class_rules = {}   # class -> [(rule_order, {prop: value})]
unsafe = set()     # classes involved in rules we cannot inline
css_classes = set()
keep_style = False
order = 0

for style_el in style_els:
  css_text = "".join(style_el.itertext())
  css_text = re.sub(r"/\*.*?\*/", "", css_text, flags=re.DOTALL)
  if (
    "@" in css_text
    or style_el.get("type") not in (None, "", "text/css")
    or style_el.get("media") not in (None, "", "all")
  ):
    sys.exit(0)  # not safely inlinable: leave the file as it is
  for m in re.finditer(r"([^{}]+)\{([^{}]*)\}", css_text):
    props, has_other = {}, False
    for decl in m.group(2).split(";"):
      if ":" not in decl:
        continue
      prop, value = decl.split(":", 1)
      prop = prop.strip()
      value = re.sub(r"\s*!important\s*$", "", value.strip())
      if prop in PRESENTATION_PROPS:
        props[prop] = value
      elif prop:
        has_other = True
    for sel in (s.strip() for s in m.group(1).split(",")):
      classes = re.findall(r"\.([\w-]+)", sel)
      css_classes.update(classes)
      simple = re.fullmatch(r"\.([\w-]+)", sel)
      if simple and not has_other:
        order += 1
        class_rules.setdefault(simple.group(1), []).append((order, props))
      else:
        keep_style = True
        unsafe.update(classes)

def inline_style_props(el):
  st = el.get("style") or ""
  return {d.split(":", 1)[0].strip() for d in st.split(";") if ":" in d}

changed = False
for el in root.iter():
  if not isinstance(el.tag, str) or not el.tag.startswith(f"{{{SVG_NS}}}"):
    continue
  cls_attr = el.get("class")
  if not cls_attr:
    continue
  classes = cls_attr.split()
  if any(c in unsafe for c in classes):
    continue
  rules = [r for c in classes for r in class_rules.get(c, [])]
  if not rules:
    continue
  merged = {}
  for _, props in sorted(rules, key=lambda r: r[0]):  # stylesheet order wins
    merged.update(props)
  skip = inline_style_props(el)
  for prop, value in merged.items():
    if prop not in skip:
      el.set(prop, value)
  remaining = [c for c in classes if c not in class_rules]
  if remaining:
    el.set("class", " ".join(remaining))
  else:
    del el.attrib["class"]
  changed = True

if not keep_style:
  still_used = any(
    c in css_classes
    for el in root.iter() if isinstance(el.tag, str)
    for c in (el.get("class") or "").split()
  )
  if not still_used:
    for style_el in style_els:
      parent = style_el.getparent()
      if parent is not None:
        parent.remove(style_el)
        changed = True

if changed:
  tree.write(path, pretty_print=True, xml_declaration=False, encoding="utf-8")
PYEOF

inline_css_file() {
  python3 "$INLINE_PY" "$1" || echo "  ✗ Warning: CSS inlining skipped for $(basename "$1")" >&2
}
export INLINE_PY
export -f inline_css_file

echo "[2/4] Inlining CSS class styles where safe (lxml)..."
echo "      (processing in parallel, order may vary)"
printf '%s\0' "${FILES[@]}" | xargs -0 -P "$CORES" -I {} bash -c 'inline_css_file "$1"' _ {}
echo "      Done."
echo "--------------------------------------------------------"

# STEP 3: optimise with scour in parallel (all cores)
SCOUR_OPTS_STR="${SCOUR_OPTS[*]}"
export SCOUR_OPTS_STR SCOUR_FAILED_LIST

scour_one() {
  local f="$1" name tmp
  local -a opts
  name=$(basename "$f")
  read -ra opts <<< "$SCOUR_OPTS_STR"
  tmp=$(mktemp --suffix=".svg")
  if scour "${opts[@]}" -i "$f" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    cp -- "$tmp" "$f"
  else
    echo "  ✗ Warning: scour failed on $name" >&2
    printf '%s\n' "$name" >> "$SCOUR_FAILED_LIST"
  fi
  rm -f "$tmp"
}
export -f scour_one

echo "[3/4] scour: optimising $TOTAL files using $CORES cores..."
echo "      (processing in parallel, order may vary)"
printf '%s\0' "${FILES[@]}" | xargs -0 -P "$CORES" -I {} bash -c 'scour_one "$1"' _ {}
echo "--------------------------------------------------------"

# STEP 4: integrity check - valid XML with an <svg> root (parallel)
# On failure the original is restored from backup and listed in the report.
export BACKUP_DIR CORRUPTED_LIST

verify_one() {
  local f="$1" name
  name=$(basename "$f")
  if python3 -c 'import sys
from lxml import etree
root = etree.parse(sys.argv[1]).getroot()
sys.exit(0 if etree.QName(root).localname == "svg" else 1)' "$f" 2>/dev/null; then
    echo "  ✓ $name"
  else
    cp -- "$BACKUP_DIR/$name" "$f"
    echo "  ✗ $name: invalid SVG, restored from backup" >&2
    printf '%s\n' "$name" >> "$CORRUPTED_LIST"
  fi
}
export -f verify_one

echo "[4/4] Verifying XML integrity of output files..."
echo "      (processing in parallel, order may vary)"
printf '%s\0' "${FILES[@]}" | xargs -0 -P "$CORES" -I {} bash -c 'verify_one "$1"' _ {}

CORRUPTED_COUNT=$(wc -l < "$CORRUPTED_LIST")
SCOUR_FAILED_COUNT=$(wc -l < "$SCOUR_FAILED_LIST")

echo "      Done."
echo "--------------------------------------------------------"
TIME_END=$(date +%s)
ELAPSED=$((TIME_END - TIME_START))

echo "Done! Processed $TOTAL files in ${ELAPSED}s using $CORES cores."
[[ $INK_FAILED -gt 0 ]] && echo "Warning: Inkscape text-to-path failed on $INK_FAILED file(s), listed above."
[[ $SCOUR_FAILED_COUNT -gt 0 ]] && echo "Warning: scour failed on $SCOUR_FAILED_COUNT file(s), listed above."
[[ $CORRUPTED_COUNT -gt 0 ]] && echo "Warning: $CORRUPTED_COUNT file(s) failed integrity check and were restored from backup."

echo ""
echo "========================================================"
echo "                       REPORT"
echo "========================================================"

SIZE_BEFORE=0
SIZE_AFTER=0

# Determine the longest filename for dynamic column width
MAX_NAME=0
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  [[ ${#name} -gt $MAX_NAME ]] && MAX_NAME=${#name}
done
TOTAL_LABEL="TOTAL ($TOTAL files)"
[[ ${#TOTAL_LABEL} -gt $MAX_NAME ]] && MAX_NAME=${#TOTAL_LABEL}
COL=$((MAX_NAME + 2))

# Helper: format bytes with per-value adaptive unit (2 decimal places unless B)
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

# Print separator sized to content
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

  # Mark files that failed integrity check and were restored from backup
  if grep -qxF "$name" "$CORRUPTED_LIST" 2>/dev/null; then
    printf "  %-${COL}s  %10s  →  %10s  (%s%%)  [RESTORED]\n" \
      "$name" "$(fmt_size "$before")" "$(fmt_size "$after")" "$pct"
  else
    printf "  %-${COL}s  %10s  →  %10s  (%s%%)\n" \
      "$name" "$(fmt_size "$before")" "$(fmt_size "$after")" "$pct"
  fi
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

if [[ ${INK_FAILED:-0} -gt 0 || ${SCOUR_FAILED_COUNT:-0} -gt 0 || ${CORRUPTED_COUNT:-0} -gt 0 ]]; then
  exit 1
fi
