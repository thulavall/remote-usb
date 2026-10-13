# PrintDrop



PrintDrop automates the flashing and configuration of a Raspberry Pi OS image to turn a Raspberry Pi Zero W into a networked, virtual USB stick for 3D printers. 



It allows you to push G-code to the Pi over SSH. The Pi automatically detects the upload, temporarily unmounts the virtual USB drive from the printer, transfers the file, and remounts it.



## Prerequisites

* A Linux host with `root` privileges.

* A Raspberry Pi OS Lite **32-bit** image (Trixie, Nov 2025 or newer; must include `cloud-init`).

* An SSH public key (e.g., `~/.ssh/id_ed25519.pub`).

* A microSD card (minimum size: `USB_SIZE` + 3GB for the OS).



## Usage

Execute the `install.sh` script to securely wipe the target device, write the OS, and pre-seed the `cloud-init` configuration.



```bash

sudo ./install.sh [options] DEVICE IMAGE PUBKEY USB_SIZE

```



### Arguments

* **DEVICE**: The target SD card block device (e.g., `/dev/sdX` or `/dev/mmcblk0`). **WARNING: All data will be permanently erased.**

* **IMAGE**: Path to the Raspberry Pi OS `.img` or `.img.xz` file.

* **PUBKEY**: Path to your SSH public key. The Pi is configured for key-only SSH access.

* **USB_SIZE**: The allocated size for the virtual FAT32 USB drive (e.g., `512M`, `2G`, `4G`). Do not exceed 32G, as many printers cannot read larger volumes.



### Options

* `--hostname NAME`  : Set the Pi's hostname (default: `printpi`).

* `--user NAME`      : Set the login user (default: `pi`).

* `--wifi-ssid SSID` : 2.4 GHz Wi-Fi network name (prompted if omitted).

* `--wifi-country CC`: Two-letter country code for Wi-Fi regulations (e.g., `US`, `SE`).



*Note: The Wi-Fi passphrase will be prompted securely without echo, or can be passed via the `$WIFI_PASS` environment variable.*



## Hardware Setup

1. Insert the flashed SD card into the Pi Zero W.

2. Provide power via the outer **PWR** micro-USB port.

3. Connect the inner **USB** micro-USB port to your 3D printer using a standard data cable.



## Operating Workflow

The initial boot takes several minutes while `cloud-init` configures the network and `printdrop-setup` installs necessary packages (`inotify-tools`, `rsync`, etc.) and formats the virtual drive. 



Once initialized, upload G-code files to the inbox directory using `rsync` (recommended for partial-transfer safety), `scp`, or `sftp`:



```bash

rsync -v --progress --partial-dir=/srv/printdrop/tmp FILE.gcode pi@printpi.local:/srv/printdrop/inbox/

```
