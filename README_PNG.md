# optimize-png: Batch PNG Optimiser

**optimize-png** is a bash script that batch-optimises PNG files using ImageMagick.
It trims excess uniform background and strips unnecessary embedded data from every file in a folder, fully automated from the command line.

## Why this script?

Manually trimming and cleaning dozens of PNG files is tedious and error-prone.
This script automates the entire process:

- processes a whole folder in one command
- runs ImageMagick in parallel on all available CPU cores
- automatically backs up original files before making any change
- writes each result to a temporary file first, preventing corruption on error
- installs all missing dependencies on first run

## What it does

| Step | Tool | What happens |
|------|------|-------------|
| 1 | ImageMagick | Trims uniform background pixels at edges with zero colour tolerance |
| 2 | ImageMagick | Strips embedded ICC profiles, EXIF data, comments and unnecessary PNG chunks |

### What `-fuzz 0%` means

The `-fuzz` option defines a colour tolerance for trimming.
A value of `0%` means **only perfectly identical pixels** at the image edges are considered background and removed.
This conservative approach protects logos and designs with intricate borders, gradients or semi-transparent edges — nothing gets trimmed unless it's truly uniform background.

### Why `-trim +repage`?

`-trim` removes the border region of pixels that match the background.
`+repage` resets the canvas size to match the trimmed image, removing any virtual offset that ImageMagick would otherwise keep from the original geometry.
Without `+repage`, downstream tools may see the file as larger than it actually is.

### Why `-strip`?

PNG files often contain embedded metadata that is invisible to the eye but adds weight to the file: ICC colour profiles, EXIF chunks, creation timestamps, comments and software tags.
The `-strip` flag removes all of this, reducing file size without affecting the image content.

## Requirements

- Debian or WSL2 Debian (Windows users: see below)
- ImageMagick (`magick` command)

The dependency is **installed automatically** on first run via `apt`.

## Installation

Save [optimize_png.bash](https://raw.githubusercontent.com/mapi68/optimize-svg-png/refs/heads/master/optimize_png.bash) then run:

```bash
mkdir -p ~/.local/bin
cp optimize_png.bash ~/.local/bin/optimize_png
chmod +x ~/.local/bin/optimize_png
```

The script is now available system-wide as `optimize_png`.

## Usage

```bash
optimize_png <folder>
```

The original files are backed up to `<folder>_backup_png` before processing.
If the backup folder already exists the script stops for safety, preventing accidental overwrites of a previous backup.

### Example

```bash
optimize_png /home/user/picons/png
```

```
Backup saved to: /home/user/picons/png_backup_png
--------------------------------------------------------
Starting PNG optimization in: /home/user/picons/png
Files found: 12  |  CPU cores: 8
--------------------------------------------------------
  ✓ icon_01.png
  ✓ icon_02.png
  ✓ icon_03.png
  ...
--------------------------------------------------------
Processing completed in 3s using 8 cores.

========================================================
                        REPORT
========================================================
------------------------------------------------------------------
  icon_01.png          45.32 KB  →   38.17 KB  (15.8%)
  icon_02.png          12.80 KB  →   10.44 KB  (18.4%)
  icon_03.png          78.55 KB  →   61.20 KB  (22.1%)
  ...
------------------------------------------------------------------
  TOTAL (12 files)    412.80 KB  →  334.55 KB
  Space saved: 78.25 KB  (18.9%)
========================================================
```

### Help

```bash
optimize_png --help
```

## Report

At the end of each run the script prints a per-file report showing:

- original size
- optimised size
- percentage saved

Sizes are displayed in B, KB or MB depending on the largest file in the batch.
The final line shows total space saved across all processed files.

## Safety

- The backup folder is created **after** confirming that PNG files exist in the target folder, so no empty backup is ever created.
- Each file is first written to a temporary file (`mktemp`). The original is overwritten only if ImageMagick succeeds. On failure the temporary file is removed and the original is left untouched.
- If the backup folder already exists the script exits immediately without modifying anything.

## Limitations

- Processes only `.png` files at the top level of the specified folder (not recursive).
- The `-fuzz 0%` setting is very conservative and trims only perfectly uniform background. Files with artwork extending to the edges may not be trimmed at all.
- The script is designed for Debian and Debian-based systems. It may work on other Linux distributions but `apt`-based auto-installation will not function outside Debian/Ubuntu.

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
optimize_png /mnt/c/Users/YourName/Desktop/png
```

### Performance tip

WSL2 I/O is slower when reading and writing files on the Windows filesystem (`/mnt/c/...`).
For large batches, copying files to the Linux filesystem first is significantly faster:

```bash
cp -r /mnt/c/Users/YourName/Desktop/png ~/png
optimize_png ~/png
cp ~/png/*.png /mnt/c/Users/YourName/Desktop/png/
```
