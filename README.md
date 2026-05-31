# optimize-svg-png

Batch optimisers for SVG and PNG files on Debian / WSL2 (Windows Subsystem for Linux).

---

## optimize-svg

Converts text to path, inlines CSS styles and optimises all SVG files in a folder.
Inkscape runs in shell mode (single launch), Python and scour run in parallel on all CPU cores.

### What it does

- **Step 1 – Inkscape:** converts `<text>` to `<path>`, fits canvas to drawing
- **Step 2 – Python:** inlines CSS `fill` values, removes `<style>` block
- **Step 3 – scour:** cleans and compresses SVG (metadata, comments, IDs, precision, viewBox)

Original files are backed up to `<folder>_backup_svg` before any modification.

### Requirements

Inkscape, Python 3 and scour — installed automatically if missing.

### Installation

```bash
mkdir -p ~/.local/bin
cp optimize_svg.bash ~/.local/bin/optimize_svg
chmod +x ~/.local/bin/optimize_svg
```

### Usage

```bash
optimize_svg <folder>
```

For full documentation see [README_SVG.md](README_SVG.md).

---

## optimize-png

Trims excess uniform background and strips unnecessary embedded data from all PNG files in a folder.
ImageMagick runs in parallel on all available CPU cores.

### What it does

- **ImageMagick:** trims uniform background pixels with zero colour tolerance, removes ICC profiles, EXIF data and PNG metadata chunks

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
optimize_png <folder>
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
