# optimize-svg-png

Batch optimisers for SVG and PNG files on Debian / WSL2 (Windows Subsystem for Linux).

---

## optimize-svg

Converts text to path, inlines CSS styles and optimises all SVG files in a folder.
Inkscape runs in shell mode (single launch), Python (lxml) and scour run in parallel on all CPU cores.

### What it does

- **Step 1 – Inkscape:** converts `<text>` to `<path>`, preserves original canvas (use `--trim` to fit canvas to drawing)
- **Step 2 – Python + lxml:** parses SVG with lxml, inlines CSS `fill` values, removes `<style>` block
- **Step 3 – scour:** cleans and compresses SVG (metadata, comments, IDs, precision, viewBox)
- **Step 4 – Python + lxml:** verifies each output file is valid XML; restores from backup and marks `[RESTORED]` in the report if corrupted

Original files are backed up to `<folder>_backup_svg` before any modification.

### Requirements

Inkscape, Python 3, python3-lxml and scour — installed automatically if missing.

### Installation

```bash
mkdir -p ~/.local/bin
cp optimize_svg.bash ~/.local/bin/optimize_svg
chmod +x ~/.local/bin/optimize_svg
```

### Usage

```bash
optimize_svg [--trim] <folder>
```

For full documentation see [README_SVG.md](README_SVG.md).

---

## optimize-png

Strips unnecessary embedded data from all PNG files in a folder.
With `--trim`, also removes excess uniform margins.
ImageMagick runs in parallel on all available CPU cores.

### What it does

- **ImageMagick:** removes ICC profiles, EXIF data and PNG metadata chunks; with `--trim`, also trims uniform background pixels at edges with zero colour tolerance

Original files are backed up to `<folder>_backup_png` before any modification.

### Requirements

ImageMagick (`magick` command) — installed automatically if missing.

### Installation

```bash
mkdir -p ~/.local/bin
cp optimize_png.bash ~/.local/bin/optimize_png
chmod +x ~/.local/bin/optimize_png
```

### Usage

```bash
optimize_png [--trim] <folder>
```

For full documentation see [README_PNG.md](README_PNG.md).

---

## Common features

Both scripts share the same design principles:

- process all files in a folder with a single command
- run in parallel on all available CPU cores
- create a backup of originals before making any change
- stop safely if the backup folder already exists
- print a per-file size report with total space saved at the end
- install missing dependencies automatically via `apt`

## Windows users (WSL2)

Both scripts run on Windows via **WSL2** with a Debian distribution.

```powershell
wsl --install -d Debian
```

Windows drives are accessible under `/mnt/`:

```bash
optimize_svg /mnt/c/Users/YourName/Desktop/svg
optimize_png /mnt/c/Users/YourName/Desktop/png
```
