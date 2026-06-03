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
Usage: $(basename "$0") [--trim] <folder>

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
  - python3-lxml           (auto-installed via apt if missing)
  - scour                   (auto-installed via apt if missing)

ARGUMENTS
  --trim     Fit canvas to drawing content (removes empty margins).
             Warning: may clip edges on files with strokes near the border.
             Default: preserve the original canvas dimensions.

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
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --trim) TRIM=1 ;;
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

# Check that python3-lxml is available, install if missing
if ! python3 -c "import lxml" &>/dev/null; then
  echo "python3-lxml not found. Installing..."
  sudo apt install -y python3-lxml
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

# STEP 1: text-to-path with Inkscape
# --shell mode: single Inkscape launch for all files.
# Inkscape writes <name>_out.svg when input and output type are both SVG.
# We rename them back immediately after.
#
# export-area-page preserves the original canvas (viewBox/width/height).
# export-area-drawing is intentionally avoided: it recalculates the bounding
# box without accounting for strokes that extend outside path geometry,
# which causes edges (typically the top) to be clipped.
# Use --trim to enable export-area-drawing when you need to remove large
# empty margins and are certain no stroke will be cut.
if [[ $TRIM -eq 1 ]]; then
  EXPORT_AREA="export-area-drawing"
  echo "[1/3] Inkscape: converting text to path, trimming canvas (sequential)..."
else
  EXPORT_AREA="export-area-page"
  echo "[1/3] Inkscape: converting text to path, preserving canvas (sequential)..."
fi
for f in "${FILES[@]}"; do
  printf 'file-open:%s; select-all; export-text-to-path; %s; export-plain-svg; export-filename:%s; export-do; file-close\n' "$f" "$EXPORT_AREA" "$f"
done | inkscape --shell 2>/dev/null
for f in "${FILES[@]}"; do
  OUT="${f%.svg}_out.svg"
  [[ -f "$OUT" ]] && mv "$OUT" "$f"
done
echo "      Done."
echo "--------------------------------------------------------"

# STEP 2: inline CSS class styles and remove <style> block (Python + lxml, parallel)
#
# Uses lxml for proper XML parsing instead of regex, ensuring correct handling
# of SVG files from any source (Inkscape, Figma, Illustrator, etc.).
#
# The script:
#   - Parses CSS class fill values from the <style> block using the css module
#     (simple property extraction, no full CSS engine needed)
#   - Walks the element tree with lxml to apply fill inline on each element
#   - Removes class attributes once fills are applied
#   - Removes the <style> block if no class attributes remain
#   - Preserves namespace declarations and XML structure exactly

INLINE_PY=$(mktemp --suffix=".py")
trap 'rm -f "$INLINE_PY"' EXIT
cat > "$INLINE_PY" << 'PYEOF'
import sys
import re
from lxml import etree

SVG_NS = "http://www.w3.org/2000/svg"

# Tags that can carry a fill attribute (mirrors the original script's scope)
FILL_TAGS = {
  f"{{{SVG_NS}}}{tag}"
  for tag in ("path", "rect", "circle", "ellipse", "polygon", "polyline", "line", "g")
}

path = sys.argv[1]

parser = etree.XMLParser(remove_comments=False, recover=True)
tree = etree.parse(path, parser)
root = tree.getroot()

# --- Extract fill values from CSS <style> block ---
# Looks for rules of the form:  .classname { ... fill: value; ... }
# Uses a simple regex on the text content of <style> elements only,
# which is safe and reliable (CSS text is not nested XML).
class_fills: dict[str, str] = {}

for style_el in root.iter(f"{{{SVG_NS}}}style"):
  css_text = style_el.text or ""
  for m in re.finditer(
    r"\.([\w-]+)\s*\{[^}]*?fill\s*:\s*([^;}/]+)", css_text, re.DOTALL
  ):
    class_fills[m.group(1)] = m.group(2).strip()

if not class_fills:
  # Nothing to do: no CSS classes with fill definitions found
  sys.exit(0)

# --- Apply fill inline and strip class attributes ---
for el in root.iter():
  if el.tag not in FILL_TAGS:
    continue

  cls_attr = el.get("class")
  if not cls_attr:
    continue

  classes = cls_attr.split()
  fill = next((class_fills[c] for c in classes if c in class_fills), None)
  if fill is None:
    continue

  # Set or overwrite fill
  el.set("fill", fill)

  # Remove class attribute
  del el.attrib["class"]

# --- Remove <style> block if no class attributes remain anywhere ---
has_class = any(el.get("class") is not None for el in root.iter())
if not has_class:
  for style_el in root.findall(f".//{{{SVG_NS}}}style"):
    parent = style_el.getparent()
    if parent is not None:
      parent.remove(style_el)
  # Also check direct children of root
  for style_el in root.findall(f"{{{SVG_NS}}}style"):
    root.remove(style_el)

tree.write(path, pretty_print=True, xml_declaration=False, encoding="unicode")
PYEOF

export INLINE_PY

inline_css_file() {
  python3 "$INLINE_PY" "$1"
}
export -f inline_css_file

echo "[2/3] Inlining CSS class styles and removing <style> block (lxml)..."
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
