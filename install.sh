#!/usr/bin/env bash
#
# printdrop-flash.sh
#
# Flash Raspberry Pi OS to an SD card and pre-seed it with cloud-init so that a
# Pi Zero W boots up as a "USB stick" for a 3D printer:
#
#   * you push G-code over SSH (rsync / sftp / scp) into /srv/printdrop/inbox
#   * a watcher moves it onto a FAT32 disk image that the Pi exports to the
#     printer through the USB gadget (g_mass_storage), "replugging" the stick
#     so the printer sees the new files
#
# Requirements: Linux host, root, and a Raspberry Pi OS Lite *32-bit* image
# (the Zero W is ARMv6) built on Trixie with cloud-init, i.e. released on or
# after 24 Nov 2025. The script checks for cloud-init before writing anything.
#
# Usage: sudo ./printdrop-flash.sh [options] DEVICE IMAGE PUBKEY USB_SIZE
#
set -euo pipefail

SELF=${0##*/}
ORIG_ARGS=("$@")

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need_value() { [ "$2" -ge 2 ] || die "option $1 needs a value"; }   # OPTION ARGC

usage() {
  cat <<EOF
Usage: sudo $SELF [options] DEVICE IMAGE PUBKEY USB_SIZE

  DEVICE    whole SD card device, e.g. /dev/sdX or /dev/mmcblk0  (will be ERASED)
  IMAGE     Raspberry Pi OS Lite 32-bit image, .img or .img.xz (Trixie, Nov 2025+)
  PUBKEY    SSH public key file, e.g. ~/.ssh/id_ed25519.pub (several keys: one per line)
  USB_SIZE  size of the virtual USB stick: 512M, 2G, 4G, ... (128M to 32G)

Options:
  --hostname NAME      hostname of the Pi            (default: printpi)
  --user NAME          login user, key-only SSH      (default: pi)
  --wifi-ssid SSID     2.4 GHz Wi-Fi network         (prompted if omitted)
  --wifi-country CC    two-letter country code, e.g. SE, US, DE (prompted if omitted)
  -y, --yes            do not ask for confirmation before erasing DEVICE
  -h, --help           show this help

Wi-Fi passphrase: read from \$WIFI_PASS if set (empty = open network),
otherwise prompted without echo.
EOF
}

# ---------------------------------------------------------------------------
# Files that end up on the Pi. Each emit_* function prints exactly one file.
# ---------------------------------------------------------------------------

emit_conf() {
  cat <<EOF
USB_SIZE=$USB_SIZE
SVC_USER=$PI_USER
EOF
}

emit_modprobe() {
  echo 'options g_mass_storage file=/piusb.img removable=1 ro=0 stall=0'
}

emit_modules_load() {
  echo 'dwc2'   # g_mass_storage is loaded by printdrop-watch once /piusb.img exists
}

# Unplug the "stick", copy finished uploads onto it, plug it back in.
emit_ingest() {
  cat <<'EOF'
#!/bin/bash
IMG=/piusb.img
INBOX=/srv/printdrop/inbox
MNT=/mnt/printdrop
OFFSET=1048576   # partition start: 2048 sectors * 512 bytes
MIN_UNPLUG=5     # seconds the stick stays "unplugged"; slow printer firmware needs this

log() { echo "printdrop-ingest: $*"; }

exec 9>/run/printdrop.lock
flock 9

# Skip dotfiles (rsync temp files) and anything modified in the last 5 s.
mapfile -d '' files < <(find "$INBOX" -maxdepth 1 -type f ! -name '.*' ! -newermt '5 seconds ago' -print0)
[ ${#files[@]} -eq 0 ] && exit 0

copy_files() {
  local loop f
  loop=$(losetup -f --show -o "$OFFSET" "$IMG") || { log "losetup failed"; return 1; }
  fsck.vfat -a "$loop" >/dev/null 2>&1 || true   # the printer may have left it dirty
  if mount -t vfat -o iocharset=utf8 "$loop" "$MNT"; then
    for f in "${files[@]}"; do
      cp -f -- "$f" "$MNT/" && rm -f -- "$f" || log "could not copy $f"
    done
    sync
    umount "$MNT"
  else
    log "mount failed; files stay in the inbox"
  fi
  losetup -d "$loop"
}

replug() {
  local i state=""
  modprobe g_mass_storage || { sleep 2; modprobe g_mass_storage; }   # retry once
  # Wait for the printer to enumerate the stick ("configured" = it did).
  for i in $(seq 1 15); do
    state=$(cat /sys/class/udc/*/state 2>/dev/null | head -n1)
    [ "$state" = configured ] && break
    sleep 1
  done
  log "stick replugged, USB state: ${state:-unknown}"
}

log "unplugging stick, ${#files[@]} file(s) to copy"
modprobe -r g_mass_storage
start=$SECONDS
copy_files
left=$(( MIN_UNPLUG - (SECONDS - start) ))
[ "$left" -gt 0 ] && sleep "$left"
replug
EOF
}

# Run the ingest once at start-up, then again after each burst of uploads.
emit_watch() {
  cat <<'EOF'
#!/bin/bash
INBOX=/srv/printdrop/inbox

# Wait for the USB device controller (dwc2), then plug the stick in.
for _ in $(seq 1 30); do
  [ -n "$(ls -A /sys/class/udc 2>/dev/null)" ] && break
  sleep 1
done
modprobe g_mass_storage || echo "printdrop-watch: could not load g_mass_storage (see dmesg)"

/usr/local/bin/printdrop-ingest
inotifywait -m -q -e close_write -e moved_to --format x "$INBOX" | while read -r _; do
  while read -r -t 5 _; do :; done   # wait for 5 s of quiet so a batch shares one replug
  /usr/local/bin/printdrop-ingest
done
EOF
}

# First-boot setup. Idempotent; systemd retries it until it succeeds.
emit_setup() {
  cat <<'EOF'
#!/bin/bash
set -euo pipefail
. /etc/printdrop.conf    # USB_SIZE, SVC_USER

IMG=/piusb.img
OFFSET=1048576           # 2048 sectors * 512 bytes

echo "printdrop-setup: installing packages"
export DEBIAN_FRONTEND=noninteractive
# The Zero W has no RTC, so its clock can be years off before NTP kicks in.
apt-get -o Acquire::Check-Date=false update
apt-get -o Acquire::Check-Date=false install -y --no-install-recommends \
  inotify-tools rsync dosfstools fdisk avahi-daemon

install -d /srv/printdrop /srv/printdrop/inbox /srv/printdrop/tmp /mnt/printdrop
chown -R "$SVC_USER:" /srv/printdrop

if [ ! -f "$IMG" ]; then
  need=$(numfmt --from=iec "$USB_SIZE")
  avail=$(df --output=avail -B1 / | tail -n1 | tr -d ' ')
  if [ "$avail" -lt $((need + 256 * 1024 * 1024)) ]; then
    echo "printdrop-setup: not enough free space on / for a $USB_SIZE image ($avail bytes free)" >&2
    exit 1
  fi
  echo "printdrop-setup: creating $USB_SIZE USB image"
  rm -f "$IMG.new"
  fallocate -l "$USB_SIZE" "$IMG.new"
  echo 'start=2048, type=c' | sfdisk --quiet --label dos "$IMG.new"
  loop=$(losetup -f --show -o "$OFFSET" "$IMG.new")
  mkfs.vfat -I -F 32 -h 2048 -n PRINTER "$loop" || { losetup -d "$loop"; exit 1; }
  losetup -d "$loop"
  mv "$IMG.new" "$IMG"
fi

systemctl daemon-reload
systemctl enable --now printdrop-watch.service
modprobe dwc2 || true
modprobe g_mass_storage || true   # printer now sees the stick (no-op if already loaded)

install -d /var/lib/printdrop
touch /var/lib/printdrop/setup.done
echo "printdrop-setup: done"
EOF
}

emit_unit_watch() {
  cat <<'EOF'
[Unit]
Description=Move uploaded G-code onto the USB gadget image
After=local-fs.target

[Service]
ExecStart=/usr/local/bin/printdrop-watch
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

emit_unit_setup() {
  cat <<'EOF'
[Unit]
Description=printdrop first-boot setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/printdrop/setup.done
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/printdrop-setup
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# cloud-init rendering
# ---------------------------------------------------------------------------

# Quote a string as a YAML double-quoted scalar.
yaml_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# write_files entry: PATH MODE GENERATOR-FUNCTION
write_file_entry() {
  printf '  - path: %s\n    permissions: "%s"\n    content: |\n' "$1" "$2"
  "$3" | sed 's/^/      /'
}

# Writes user-data, meta-data and network-config into DIR.
render_cloud_init() {
  local dir=$1 k

  {
    cat <<EOF
#cloud-config
hostname: $HOSTNAME_PI
manage_etc_hosts: true
enable_ssh: true
ssh_pwauth: false

users:
  - name: $PI_USER
    groups: users,adm,sudo,netdev,plugdev,dialout
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
EOF
    for k in "${KEYS[@]}"; do
      printf '      - %s\n' "$(yaml_quote "$k")"
    done
    echo
    echo "write_files:"
    write_file_entry /etc/printdrop.conf                   0644 emit_conf
    write_file_entry /etc/modprobe.d/printdrop.conf        0644 emit_modprobe
    write_file_entry /etc/modules-load.d/printdrop.conf    0644 emit_modules_load
    write_file_entry /usr/local/bin/printdrop-ingest       0755 emit_ingest
    write_file_entry /usr/local/bin/printdrop-watch        0755 emit_watch
    write_file_entry /usr/local/sbin/printdrop-setup       0755 emit_setup
    write_file_entry /etc/systemd/system/printdrop-watch.service 0644 emit_unit_watch
    write_file_entry /etc/systemd/system/printdrop-setup.service 0644 emit_unit_setup
    cat <<'EOF'

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, --no-block, printdrop-setup.service ]
EOF
  } > "$dir/user-data"

  # A fresh instance-id makes cloud-init treat this card as a new machine.
  printf 'instance_id: printdrop-%s\n' "$(date +%s)" > "$dir/meta-data"

  {
    cat <<EOF
network:
  version: 2
  wifis:
    renderer: NetworkManager
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: "$WIFI_COUNTRY"
      access-points:
EOF
    if [ -n "$WIFI_PASS" ]; then
      printf '        %s:\n          password: %s\n' "$(yaml_quote "$WIFI_SSID")" "$(yaml_quote "$WIFI_PASS")"
    else
      printf '        %s: {}\n' "$(yaml_quote "$WIFI_SSID")"
    fi
  } > "$dir/network-config"
}

# ---------------------------------------------------------------------------
# Host side
# ---------------------------------------------------------------------------

ask() { # VAR PROMPT [-s]
  local __var=$1 __prompt=$2 __val
  [ -t 0 ] || die "$__var not provided and stdin is not a terminal"
  if [ "${3:-}" = "-s" ]; then
    read -r -s -p "$__prompt" __val; echo
  else
    read -r -p "$__prompt" __val
  fi
  printf -v "$__var" '%s' "$__val"
}

partdev() { # N -> path of partition N on $DEV
  case $DEV in
    *[0-9]) echo "${DEV}p$1" ;;
    *)      echo "${DEV}$1" ;;
  esac
}

WORK=""
cleanup() {
  set +e
  if [ -n "$WORK" ]; then
    local m
    for m in boot root; do
      mountpoint -q "$WORK/$m" && umount "$WORK/$m"
    done
    # rmdir (never rm -rf): refuses to touch anything that is still mounted
    rmdir "$WORK/boot" "$WORK/root" "$WORK" 2>/dev/null
  fi
}

parse_args() {
  HOSTNAME_PI=printpi
  PI_USER=pi
  WIFI_SSID=""
  WIFI_COUNTRY=""
  ASSUME_YES=0
  POS=()

  while [ $# -gt 0 ]; do
    case $1 in
      --hostname)     need_value "$1" $#; HOSTNAME_PI=$2;  shift 2 ;;
      --user)         need_value "$1" $#; PI_USER=$2;      shift 2 ;;
      --wifi-ssid)    need_value "$1" $#; WIFI_SSID=$2;    shift 2 ;;
      --wifi-country) need_value "$1" $#; WIFI_COUNTRY=$2; shift 2 ;;
      -y|--yes)       ASSUME_YES=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      --)             shift; POS+=("$@"); break ;;
      -*)             die "unknown option: $1 (see --help)" ;;
      *)              POS+=("$1"); shift ;;
    esac
  done

  [ ${#POS[@]} -eq 4 ] || { usage >&2; exit 1; }
  DEV=${POS[0]}
  IMG=${POS[1]}
  PUBKEY=${POS[2]}
  USB_SIZE=${POS[3]^^}
}

validate_inputs() {
  local t k re

  for t in dd lsblk blkid blockdev mount umount mountpoint findmnt numfmt mktemp sync; do
    need "$t"
  done
  [[ $IMG == *.xz ]] && need xz

  [[ $HOSTNAME_PI =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid hostname: $HOSTNAME_PI"
  [[ $PI_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]                 || die "invalid user name: $PI_USER"
  [[ $USB_SIZE =~ ^[0-9]+[MG]$ ]]                            || die "USB_SIZE must look like 512M or 2G"

  USB_BYTES=$(numfmt --from=iec "$USB_SIZE")
  [ "$USB_BYTES" -ge $((128 * 1024 * 1024)) ] || die "USB_SIZE must be at least 128M"
  [ "$USB_BYTES" -le $((32 * 1024 * 1024 * 1024)) ] ||
    echo "warning: many printers cannot read USB sticks larger than 32G" >&2

  [ -f "$IMG" ]    || die "image not found: $IMG"
  [ -r "$PUBKEY" ] || die "public key not readable: $PUBKEY"

  # SSH keys: one public key per line, comments and blank lines ignored.
  mapfile -t KEYS < <(grep -Ev '^[[:space:]]*(#|$)' "$PUBKEY" || true)
  [ ${#KEYS[@]} -gt 0 ] || die "no keys found in $PUBKEY"
  re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'
  for k in "${KEYS[@]}"; do
    case $k in *"PRIVATE KEY"*) die "$PUBKEY contains a PRIVATE key; pass the .pub file" ;; esac
    [[ $k =~ $re ]] || die "not a valid SSH public key line: ${k:0:40}"
  done
}

gather_wifi() {
  # Wi-Fi (the Zero W's only USB data port is busy being a USB stick, so Wi-Fi is the way in).
  [ -n "$WIFI_SSID" ]    || ask WIFI_SSID "Wi-Fi SSID (2.4 GHz network): "
  [ -n "$WIFI_SSID" ]    || die "Wi-Fi SSID is required"
  [ -n "$WIFI_COUNTRY" ] || ask WIFI_COUNTRY "Wi-Fi country code (e.g. SE, US, DE): "
  WIFI_COUNTRY=${WIFI_COUNTRY^^}
  [[ $WIFI_COUNTRY =~ ^[A-Z]{2}$ ]] || die "Wi-Fi country must be a two-letter code"
  [ -n "${WIFI_PASS+x}" ] || ask WIFI_PASS "Wi-Fi passphrase (empty for an open network): " -s
  WIFI_PASS=${WIFI_PASS-}
  if [ -n "$WIFI_PASS" ] && { [ ${#WIFI_PASS} -lt 8 ] || [ ${#WIFI_PASS} -gt 63 ]; }; then
    die "WPA passphrases are 8 to 63 characters"
  fi
}

validate_device() {
  local root_src dev_bytes img_bytes

  DEV=$(readlink -f -- "$DEV")
  [ -b "$DEV" ] || die "not a block device: $DEV"
  case $(lsblk -dno TYPE "$DEV") in
    disk|loop) ;;
    *) die "$DEV is not a whole disk (did you pass a partition?)" ;;
  esac

  root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
  root_src=${root_src%%\[*}
  if [ -b "$root_src" ] && lsblk -nrso NAME "$root_src" 2>/dev/null | grep -qx "${DEV##*/}"; then
    die "refusing to touch $DEV: it holds the running system"
  fi

  dev_bytes=$(blockdev --getsize64 "$DEV")
  if [[ $IMG == *.xz ]]; then
    img_bytes=$(xz --robot --list "$IMG" | awk -F'\t' '$1=="totals"{print $5}')
  else
    img_bytes=$(stat -c %s "$IMG")
  fi
  if [ -n "${img_bytes:-}" ] && [ "$img_bytes" -gt "$dev_bytes" ]; then
    die "image ($img_bytes bytes) is larger than $DEV ($dev_bytes bytes)"
  fi
  # OS + apt headroom on top of the USB image.
  [ "$dev_bytes" -ge $((USB_BYTES + 3 * 1024 * 1024 * 1024)) ] ||
    die "$DEV is too small for a $USB_SIZE USB stick plus the OS (need USB_SIZE + ~3G)"
}

confirm() {
  local nkeys=${#KEYS[@]} reply
  echo
  echo "About to ERASE and rewrite $DEV:"
  lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL "$DEV"
  echo
  echo "  image     : $IMG"
  echo "  hostname  : $HOSTNAME_PI"
  echo "  login     : $PI_USER (key-only SSH, $nkeys key(s))"
  echo "  Wi-Fi     : $WIFI_SSID (country $WIFI_COUNTRY)"
  echo "  USB stick : $USB_SIZE, FAT32"
  echo
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "refusing to erase $DEV without a terminal to confirm on (use --yes)"
    read -r -p "Type $DEV to confirm: " reply
    [ "$reply" = "$DEV" ] || die "aborted"
  fi
}

flash() {
  local p
  while read -r p; do
    umount "$p" 2>/dev/null || true
  done < <(lsblk -nrpo NAME "$DEV" | tail -n +2)
  [ -z "$(lsblk -nro MOUNTPOINT "$DEV" | tr -d '[:space:]')" ] || die "$DEV still has mounted partitions"

  info "Writing $(basename "$IMG") to $DEV"
  if [[ $IMG == *.xz ]]; then
    xz -dc -- "$IMG" | dd of="$DEV" bs=4M iflag=fullblock conv=fsync status=progress
  else
    dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
  fi
  sync

  partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
  command -v udevadm >/dev/null 2>&1 && udevadm settle
  local i
  for i in $(seq 1 30); do
    [ -b "$(partdev 1)" ] && [ -b "$(partdev 2)" ] && break
    sleep 1
  done
  { [ -b "$(partdev 1)" ] && [ -b "$(partdev 2)" ]; } || die "partitions did not appear on $DEV"
}

# True if config.txt already loads dwc2 for every model. Stock Pi OS images carry
# "dtoverlay=dwc2,dr_mode=host" under [cm5]; that must not count, so only
# lines before the first section header or inside [all] are considered.
dwc2_enabled() {
  awk '/^[[:space:]]*\[/ { sec=$0; gsub(/[[:space:]]/, "", sec); next }
       /^[[:space:]]*dtoverlay=dwc2/ && (sec=="" || sec=="[all]") { found=1 }
       END { exit !found }' "$1"
}


provision() {
  WORK=$(mktemp -d)
  trap cleanup EXIT
  mkdir "$WORK/boot" "$WORK/root"

  # The image must ship cloud-init, or user-data would be silently ignored.
  mount -o ro -t ext4 "$(partdev 2)" "$WORK/root" || die "cannot mount the root partition"
  if [ ! -e "$WORK/root/usr/bin/cloud-init" ]; then
    die "this image has no cloud-init. Use a Raspberry Pi OS Lite (32-bit) image released 24 Nov 2025 or later. $DEV has already been written, just flash a newer image."
  fi
  umount "$WORK/root"

  mount -t vfat "$(partdev 1)" "$WORK/boot" || die "cannot mount the boot partition"
  [ -f "$WORK/boot/config.txt" ] || die "no config.txt on the boot partition; is this a Raspberry Pi OS image?"

  info "Enabling USB gadget (dwc2) in config.txt"
  if ! dwc2_enabled "$WORK/boot/config.txt"; then
    [ -n "$(tail -c1 "$WORK/boot/config.txt")" ] && echo >> "$WORK/boot/config.txt"
    printf '\n# printdrop: act as a USB device on the OTG port\n[all]\ndtoverlay=dwc2,dr_mode=peripheral\n' >> "$WORK/boot/config.txt"
  fi


  info "Writing cloud-init files (user-data, meta-data, network-config)"
  render_cloud_init "$WORK/boot"

  sync
  umount "$WORK/boot"
}

print_next_steps() {
  cat <<EOF

Done. Card is ready.

  1. Insert it in the Pi Zero W and power it through the PWR port (the outer
     micro-USB port). The middle port, marked USB, is the one that goes to the
     printer, and it must be a data cable.
  2. The first boot takes a few minutes: cloud-init sets up the user and Wi-Fi,
     then printdrop-setup installs packages and creates the $USB_SIZE stick.
  3. Log in and watch the progress:
       ssh $PI_USER@$HOSTNAME_PI.local
       journalctl -u printdrop-setup -f
  4. Upload G-code (lands on the stick a few seconds after the transfer ends):
       rsync -v --progress --partial-dir=/srv/printdrop/tmp FILE.gcode \\
             $PI_USER@$HOSTNAME_PI.local:/srv/printdrop/inbox/

Do not upload while the printer is printing: the stick is unplugged and replugged
for every upload, which aborts a print that reads from it.
EOF
}

main() {
  parse_args "$@"

  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E "$0" "${ORIG_ARGS[@]}"
  fi

  validate_inputs
  validate_device
  gather_wifi
  confirm
  flash
  provision
  print_next_steps
}

# Allow `source printdrop-flash.sh` for testing without running anything.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
