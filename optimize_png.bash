#!/bin/bash

usage() {
  cat <<USAGE
Usage: $(basename "$0") <folder>

Optimizes all PNG files in the specified folder by removing empty or white
margins and stripping unnecessary embedded data.

DESCRIPTION
  Processes all .png files in the given folder.
  Trims excess uniform background (with 0% tolerance to preserve logo details).
  Also removes profiles, comments, and unnecessary PNG chunks via the -strip flag.
  Processing runs in parallel across all available CPU cores.

IMPORTANT
  - Original files are copied to FOLDER_backup before being modified.
  - If the backup folder already exists, the script stops for safety.

REQUIREMENTS
  - ImageMagick ('magick' command)
  If missing, the script attempts to install it automatically via apt.

ARGUMENTS
  <folder>   Path to the folder containing the .png files
             Accepts both absolute and relative paths

EXAMPLES
  $(basename "$0") ./my_pngs
  $(basename "$0") /home/user/projects/images

NOTES
  - Runs ImageMagick with the following options:
    "-trim -fuzz 0% +repage -strip"
  - The -strip flag removes embedded ICC profiles, comments, and EXIF chunks.
  - The -fuzz 0% ensures only perfectly uniform pixels at edges are trimmed.
USAGE
}

# Argument check (help)
if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

# Resolve absolute path of the folder
DIR=$(realpath "$1")

# Verify the folder exists
if [[ ! -d "$DIR" ]]; then
  echo "Error: '$1' is not a valid folder." >&2
  exit 1
fi

# Automatic dependency installation function
install_dependency() {
  local cmd="$1"
  local package="$2"

  if ! command -v "$cmd" &>/dev/null; then
    echo "Missing dependency: '$cmd'. Attempting installation..."
    sudo apt update -qq && sudo apt install -y "$package"

    # Verify installation succeeded
    if ! command -v "$cmd" &>/dev/null; then
      echo "Error: installation of '$package' failed. Please install it manually." >&2
      exit 1
    fi

    echo "  ✓ '$cmd' installed successfully."
  fi
}

install_dependency "magick" "imagemagick"

# Build the list of PNG files
mapfile -t FILES < <(find "$DIR" -maxdepth 1 -name "*.png" | sort)
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

# Parallel optimization with safe write via temporary file
MAGICK_BIN=$(command -v magick)
export MAGICK_BIN

printf '%s\n' "${FILES[@]}" | xargs -P "$CORES" -I {} bash -c '
  f="$1"
  TMP=$(mktemp --suffix=".png")
  if "$MAGICK_BIN" "$f" -trim -fuzz 0% +repage -strip "$TMP" 2>/dev/null; then
    mv "$TMP" "$f"
    echo "  ✓ $(basename "$f")"
  else
    rm -f "$TMP"
    echo "  ✗ Error: $(basename "$f")" >&2
  fi
' _ {}

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

# Adaptive unit based on the largest file
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

fmt_size() {
  local bytes=$1
  if [[ $DIVISOR -eq 1 ]]; then
    printf "%d B" "$bytes"
  else
    awk "BEGIN { printf \"%.2f $UNIT\", $bytes / $DIVISOR }"
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
