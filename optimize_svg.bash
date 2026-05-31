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
Usage: $(basename "$0") <folder>

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
    - Fits canvas to drawing (removes empty margins)

  Step 2 - Python (parallel, all CPU cores):
    - Reads fill values from CSS classes in <style> block
    - Applies fill inline on each element
    - Removes class attributes and the entire <style> block

  Step 3 - scour (parallel, all CPU cores):
    - Reduces decimal precision to 5 significant digits
    - Shortens colour values
    - Converts CSS attributes to XML attributes
    - Collapses nested groups
    - Removes the XML declaration, metadata and comments
    - Enables viewBox
    - Removes unused IDs and shortens the remaining ones

# IMPORTANT
  - Original files are copied to FOLDER_NAME_backup before being modified.
  - If the backup folder already exists, the script stops for safety.

REQUIREMENTS
  - Inkscape 1.4 or higher  (auto-installed via apt if missing)
  - Python 3               (auto-installed via apt if missing)
  - scour                   (auto-installed via apt if missing)

ARGUMENTS
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
EOF
}

# Argument check (help)
if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

# Resolve absolute path of the folder
DIR=$(realpath "$1")

# Check that the folder exists
if [[ ! -d "$DIR" ]]; then
  echo "Error: '$1' is not a valid folder." >&2
  exit 1
fi

# Check that Inkscape is available, install if missing
if ! command -v inkscape &>/dev/null; then
  echo "Inkscape not found. Installing..."
  sudo apt install -y inkscape
fi

# Check that Python 3 is available, install if missing
if ! command -v python3 &>/dev/null; then
  echo "Python 3 not found. Installing..."
  sudo apt install -y python3
fi

# Check that scour is available, install if missing
if ! command -v scour &>/dev/null; then
  echo "scour not found. Installing..."
  sudo apt install -y scour
fi


# scour options matching the "Optimised SVG Output" extension settings:
#
# [Options]
#   Significant digits: 5
#   Shorten colour values: yes
#   Convert CSS attributes to XML attributes: yes
#   Collapse groups: yes
#   Work around renderer bugs: yes
#
# [SVG Output]
#   Remove the XML declaration: yes
#   Remove metadata: yes
#   Remove comments: yes
#   Enable viewboxing: yes
#   Pretty-printing: yes, Space, depth 1
#
# [IDs]
#   Remove unused IDs: yes
#   Shorten IDs: yes

SCOUR_OPTS=(
  "--set-precision=5"          # 5 significant digits for coordinates
  "--strip-xml-prolog"         # remove the XML declaration
  "--remove-metadata"          # remove metadata
  "--enable-comment-stripping" # remove comments
  "--enable-viewboxing"        # enable viewBox
  "--indent=space"             # indent with spaces
  "--nindent=1"                # indentation depth: 1
  "--enable-id-stripping"      # remove unused IDs
  "--shorten-ids"              # shorten IDs
  "--renderer-workaround"      # work around renderer bugs
)

# Build list of SVG files
mapfile -t FILES < <(find "$DIR" -maxdepth 1 -name "*.svg" | sort)
TOTAL=${#FILES[@]}

if [[ $TOTAL -eq 0 ]]; then
  echo "Error: no SVG files found in '$DIR'." >&2
  exit 1
fi

# Create backup folder (after file check, to avoid creating an empty folder)
# Uses array expansion to correctly handle filenames with spaces
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
echo "Files found: $TOTAL  |  CPU cores: $CORES"
echo "--------------------------------------------------------"

TIME_START=$(date +%s)

# STEP 1: text-to-path + fit canvas to drawing with Inkscape
# --shell mode: single Inkscape launch for all files.
# Inkscape writes <name>_out.svg when input and output type are both SVG.
# We rename them back immediately after.
echo "[1/3] Inkscape: converting text to path and fitting canvas (sequential)..."
for f in "${FILES[@]}"; do
  printf 'file-open:%s; select-all; export-text-to-path; export-area-drawing; export-plain-svg; export-filename:%s; export-do; file-close\n' "$f" "$f"
done | inkscape --shell 2>/dev/null
for f in "${FILES[@]}"; do
  OUT="${f%.svg}_out.svg"
  [[ -f "$OUT" ]] && mv "$OUT" "$f"
done
echo "      Done."
echo "--------------------------------------------------------"

# STEP 2: inline CSS class styles and remove <style> block (Python, parallel)
# After text-to-path, Inkscape keeps class="lettere" etc. on the generated paths.
# This script reads fill from each CSS class, applies it inline, then removes
# the class attribute and the <style> block.
# Written to a temp file to avoid heredoc quoting issues with single/double quotes.

INLINE_PY=$(mktemp --suffix=".py")
cat > "$INLINE_PY" << 'PYEOF'
import sys, re

# NOTE: this step uses regex on XML, which works well for SVG produced by
# Inkscape but may be unreliable on complex SVG from Figma, Illustrator, etc.
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    svg = fh.read()

# Extract fill values from CSS classes: .classname { ... fill: value; ... }
class_fills = {}
for m in re.finditer(r"\.([\w-]+)\s*\{[^}]*?fill\s*:\s*([^;}/]+)", svg, re.DOTALL):
    class_fills[m.group(1)] = m.group(2).strip()

if not class_fills:
    sys.exit(0)

# Apply fill inline and remove class attribute
def replace_elem(m):
    tag = m.group(0)
    cls_match = re.search(r'class="([^"]+)"', tag)
    if not cls_match:
        cls_match = re.search(r"class='([^']+)'", tag)
    if not cls_match:
        return tag
    classes = cls_match.group(1).split()
    fill = None
    for c in classes:
        if c in class_fills:
            fill = class_fills[c]
            break
    if fill is None:
        return tag
    tag = re.sub(r'\s*class="[^"]*"', "", tag)
    tag = re.sub(r"\s*class='[^']*'", "", tag)
    if re.search(r'\bfill=', tag):
        tag = re.sub(r'fill="[^"]*"', 'fill="' + fill + '"', tag)
        tag = re.sub(r"fill='[^']*'", 'fill="' + fill + '"', tag)
    else:
        tag = tag.rstrip(">").rstrip("/").rstrip() + ' fill="' + fill + '"' + ("/>" if m.group(0).rstrip().endswith("/>") else ">")
    return tag

svg = re.sub(r"<(?:path|rect|circle|ellipse|polygon|polyline|line|g)\b[^>]*>", replace_elem, svg)

# Remove <style> block if no class attributes remain
if not re.search(r'class=', svg):
    svg = re.sub(r"\s*<style[^>]*>.*?</style>", "", svg, flags=re.DOTALL)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(svg)
PYEOF

export INLINE_PY

inline_css_file() {
  python3 "$INLINE_PY" "$1"
}
export -f inline_css_file

echo "[2/3] Inlining CSS class styles and removing <style> block..."
echo "      (processing in parallel, order may vary)"
printf '%s\n' "${FILES[@]}" | xargs -P "$CORES" -I {} bash -c 'inline_css_file "$@"' _ {}
echo "      Done."
echo "--------------------------------------------------------"

# STEP 3: optimise with scour in parallel (all cores)
SCOUR_OPTS_STR="${SCOUR_OPTS[*]}"
SCOUR_PATH="$PATH"
export SCOUR_OPTS_STR SCOUR_PATH

echo "[3/3] scour: optimising $TOTAL files using $CORES cores..."
echo "      (processing in parallel, order may vary)"

printf '%s\n' "${FILES[@]}" | xargs -P "$CORES" -I {} bash -c '
  f="$1"
  TMP=$(mktemp --suffix=".svg")
  read -ra opts <<< "$SCOUR_OPTS_STR"
  if scour "${opts[@]}" -i "$f" -o "$TMP" 2>/dev/null; then
    mv "$TMP" "$f"
  else
    rm -f "$TMP"
    echo "  ✗ Warning: scour failed on $(basename "$f")" >&2
    exit 1
  fi
' _ {}
SCOUR_EXIT=$?

rm -f "$INLINE_PY"

echo "--------------------------------------------------------"
TIME_END=$(date +%s)
ELAPSED=$((TIME_END - TIME_START))

echo "Done! Processed $TOTAL files in ${ELAPSED}s using $CORES cores."
[[ $SCOUR_EXIT -ne 0 ]] && echo "Warning: some files failed during scour. Check output above."

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

# Choose display unit based on the largest file size
MAX_SIZE=0
for f in "${FILES[@]}"; do
  backup="$BACKUP_DIR/$(basename "$f")"
  sz=$(stat -c '%s' "$backup" 2>/dev/null || echo 0)
  [[ $sz -gt $MAX_SIZE ]] && MAX_SIZE=$sz
done
if   [[ $MAX_SIZE -ge 1048576 ]]; then UNIT="MB"; DIVISOR=1048576
elif [[ $MAX_SIZE -ge 1024 ]];    then UNIT="KB"; DIVISOR=1024
else                                    UNIT="B";  DIVISOR=1
fi

# Helper: format bytes in chosen unit (2 decimal places unless B)
fmt_size() {
  local bytes=$1
  if [[ $DIVISOR -eq 1 ]]; then
    printf "%d B" "$bytes"
  else
    awk "BEGIN { printf \"%.2f $UNIT\", $bytes / $DIVISOR }"
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
    pct=$(awk "BEGIN { printf \"%.1f\", ($saved / $before) * 100 }")
  else
    pct="0.0"
  fi

  printf "  %-${COL}s  %10s  →  %10s  (%s%%)\n" \
    "$name" "$(fmt_size "$before")" "$(fmt_size "$after")" "$pct"
done

echo "$SEP"
TOTAL_SAVED=$((SIZE_BEFORE - SIZE_AFTER))
if [[ $SIZE_BEFORE -gt 0 ]]; then
  TOTAL_PCT=$(awk "BEGIN { printf \"%.1f\", ($TOTAL_SAVED / $SIZE_BEFORE) * 100 }")
else
  TOTAL_PCT="0.0"
fi

printf "  %-${COL}s  %10s  →  %10s\n" \
  "$TOTAL_LABEL" "$(fmt_size "$SIZE_BEFORE")" "$(fmt_size "$SIZE_AFTER")"
printf "  Space saved: %s  (%s%%)\n" "$(fmt_size "$TOTAL_SAVED")" "$TOTAL_PCT"
echo "========================================================"
