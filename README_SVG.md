# optimize-svg: Batch SVG Optimiser

**optimize-svg** is a bash script that batch-optimises SVG files using Inkscape, Python (lxml) and scour.
It produces the same result as running Inkscape's built-in **Optimised SVG Output** extension on every file, fully automated from the command line.

## Why this script?

Manually running **Optimised SVG Output** on dozens of files in Inkscape is tedious and slow.
This script automates the entire process:

- processes a whole folder in one command
- uses Inkscape in shell mode (single launch for all files, much faster than one launch per file)
- runs Python and scour in parallel on all available CPU cores
- automatically backs up original files before making any change
- installs all missing dependencies on first run

## What it does

| Step | Tool | What happens |
|------|------|-------------|
| 1 | Inkscape | Converts `<text>` and `<tspan>` to `<path>` (removes font dependency), preserves original canvas |
| 2 | Python + lxml | Parses SVG with lxml, reads `fill` values from CSS `<style>` block, applies them inline on each element, removes the `<style>` block |
| 3 | scour | Removes metadata, comments, unused IDs, shortens colour values, reduces coordinate precision, enables viewBox |

### Why convert text to path first?

If SVG files contain text elements with CSS classes defining fonts and colours, converting to path first ensures:

- the file renders correctly on any system without the original fonts installed
- the `<style>` block can be fully removed in step 2
- scour in step 3 finds a clean file with no CSS leftovers to deal with

### Why inline CSS before scour?

After Inkscape converts text to path, the generated `<path>` elements still carry `class="..."` attributes referencing the original CSS. If left as-is, scour keeps the `<style>` block because the classes are still referenced. Step 2 moves the `fill` value directly onto each element so scour can remove everything CSS-related cleanly.

### Why lxml for step 2?

Step 2 uses **lxml** to parse and modify the SVG as a proper XML document rather than with regular expressions.
This approach is correct regardless of the SVG source (Inkscape, Figma, Illustrator, etc.) because it:

- handles namespace declarations and prefixes correctly
- walks the element tree structurally, never pattern-matching raw text
- only applies regex on the text content of `<style>` elements, where it is safe
- preserves the full XML structure and all attributes not explicitly modified

## Requirements

- Debian or WSL2 Debian (Windows users: see below)
- Inkscape 1.4 or higher
- Python 3
- python3-lxml
- scour

All dependencies are **installed automatically** on first run via `apt`.

## Installation

Save [optimize_svg.bash](https://raw.githubusercontent.com/mapi68/optimize-svg/refs/heads/master/optimize_svg.bash) then run:

```bash
mkdir -p ~/.local/bin
cp optimize_svg.bash ~/.local/bin/optimize_svg
chmod +x ~/.local/bin/optimize_svg
```

The script is now available system-wide as `optimize_svg`.

## Usage

```bash
optimize_svg [--trim] <folder>
```

The original files are backed up to `<folder>_backup_svg` before processing.
If the backup folder already exists the script exits immediately without modifying anything.

### Options

`--trim` — fit the canvas to the drawing content after text-to-path conversion, removing empty margins.

> **Warning:** `--trim` uses Inkscape's `export-area-drawing`, which calculates the bounding box without accounting for strokes that extend outside path geometry. This can clip edges (typically the top or sides) on files where strokes run close to the canvas border. Use only when you are sure the files have no such strokes.

Without `--trim` the original canvas dimensions (viewBox, width, height) are preserved exactly.

### Example

```bash
optimize_svg /home/user/picons/svg
```

```
Backup saved to: /home/user/picons/svg_backup_svg
Starting SVG optimisation in: /home/user/picons/svg
Files found: 16  |  CPU cores: 8
--------------------------------------------------------
[1/3] Inkscape: converting text to path, preserving canvas (sequential)...
      Done.
--------------------------------------------------------
[2/3] Inlining CSS class styles and removing <style> block (lxml)...
      (processing in parallel, order may vary)
      Done.
--------------------------------------------------------
[3/3] scour: optimising 16 files using 8 cores...
      (processing in parallel, order may vary)
Scour processed file "icon.svg" in 9 ms: 2119/3388 bytes -> 62.5%
...
--------------------------------------------------------
Done! Processed 16 files in 5s using 8 cores.
```

## Windows users (WSL2)

The script runs on Windows via **WSL2** (Windows Subsystem for Linux) with a Debian distribution.
All dependencies are installed automatically inside the Linux environment — nothing needs to be installed on the Windows side.

### Install WSL2 with Debian

Open PowerShell as Administrator and run:

```powershell
wsl --install -d Debian
```

Reboot if prompted, then open the **Debian** app from the Start menu and complete the first-time user setup.

### Install the script inside WSL2

Open the Debian terminal and follow the [Installation](#installation) steps above.

### Access Windows files from WSL2

Your Windows drives are accessible under `/mnt/`:

```bash
optimize_svg /mnt/c/Users/YourName/Desktop/svg
```

### Performance tip

WSL2 I/O is slower when reading and writing files on the Windows filesystem (`/mnt/c/...`).
For large batches, copying files to the Linux filesystem first is significantly faster:

```bash
cp -r /mnt/c/Users/YourName/Desktop/svg ~/svg
optimize_svg ~/svg
cp ~/svg/*.svg /mnt/c/Users/YourName/Desktop/svg/
```
