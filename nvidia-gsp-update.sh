#!/usr/bin/env bash
# /usr/local/bin/nvidia-gsp-update.sh
#
# Auto-manage GSP firmware path in dracut config for AlmaLinux 10.x
# (and likely RHEL 10 / Rocky 10 / other EL10 derivatives).
#
# Handles all five states automatically:
#   1. NVIDIA installed, config missing       -> create config
#   2. NVIDIA installed, wrong version        -> update config
#   3. NVIDIA installed, version correct      -> do nothing (idempotent)
#   4. NVIDIA NOT installed, config present   -> remove orphan config
#   5. NVIDIA NOT installed, config absent    -> do nothing
#
# Tested on AlmaLinux 10.1, NVIDIA driver 595.x, Ampere GPU (RTX A2000).
# Designed to work on any NVIDIA GPU family that uses GSP firmware.
# GSP (GPU System Processor) is present from the Turing generation
# onward; the open NVIDIA kernel module requires it. So this covers
# Turing, Ampere, Ada, Hopper, Blackwell, etc. — via gsp_*.bin glob
# matching, no per-family code.
#
# Usage:
#   Automatic (recommended): triggered by DNF5 actions plugin hook
#                            on any NVIDIA package transaction.
#   Manual:                  sudo /usr/local/bin/nvidia-gsp-update.sh

set -euo pipefail

# ─────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────
readonly CONFIG="/etc/dracut.conf.d/nvidia-gsp.conf"
readonly FW_DIR="/lib/firmware/nvidia"

# ─────────────────────────────────────────────────────────
# Root check
#
# Script writes to /etc/ and runs dracut, both require root.
# DNF hooks already run as root so this passes silently in
# the automated path. The check exists to catch manual
# testing without sudo, giving a clear error instead of
# cryptic permission-denied failures mid-execution.
# ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────
# Detect newest installed NVIDIA firmware version.
#
# If FW_DIR doesn't exist at all (NVIDIA never installed),
# the 2>/dev/null on ls silently suppresses the error and
# the pipeline produces an empty result. The || echo ""
# fallback prevents set -e from killing the script on
# empty grep matches.
#
# sort -V ensures version-aware ordering (so 595.9 < 595.71
# < 595.100). tail -1 picks the newest.
# ─────────────────────────────────────────────────────────
NEW=$(ls -1 "$FW_DIR" 2>/dev/null | grep -E '^[0-9]+\.' | sort -V | tail -1 || echo "")

if [[ -z "$NEW" ]]; then
    # No firmware version dirs found — NVIDIA driver not installed
    # (or fully removed). Handle states 4 and 5.
    if [[ -f "$CONFIG" ]]; then
        echo "No NVIDIA firmware found, removing orphan config $CONFIG"
        rm -f "$CONFIG"
        dracut --force --kver "$(uname -r)"
        echo "Done. Reboot to apply."
    else
        echo "No NVIDIA firmware found, no config to clean. Nothing to do."
    fi
    exit 0
fi

# ─────────────────────────────────────────────────────────
# Find all GSP firmware files for the newest version.
#
# Glob matches every gsp_*.bin file — works across all GPU
# families that use GSP firmware (Turing onward):
#   gsp_tu10x.bin  (Turing — RTX 20xx, GTX 16xx)
#   gsp_ga10x.bin  (Ampere — RTX 30xx, RTX Axxxx)
#   gsp_ad10x.bin  (Ada — RTX 40xx)
#   gsp_gh100.bin  (Hopper — data center)
#   gsp_gb20x.bin  (Blackwell — RTX 50xx) and future families
#
# When the glob matches nothing, bash leaves the literal
# unexpanded pattern as GSP_FILES[0]. The -e test catches
# that case: real files exist, the literal pattern does not.
# ─────────────────────────────────────────────────────────
GSP_FILES=("$FW_DIR/$NEW"/gsp_*.bin)
if [[ ! -e "${GSP_FILES[0]}" ]]; then
    echo "No gsp_*.bin files in $FW_DIR/$NEW"
    echo "Your GPU may not need GSP firmware (pre-Turing GPUs do not"
    echo "use GSP; the open NVIDIA driver requires Turing or newer)."
    exit 0
fi

# ─────────────────────────────────────────────────────────
# Extract version from existing config (if any).
#
# head -1 because grep -oE returns one match per line, and
# we write multiple firmware paths (all referencing the
# same version directory). Without head -1, $OLD would be
# multi-line and break the comparison in the next section.
#
# The three-segment version regex matches NVIDIA's current
# format (e.g., 595.71.05). If NVIDIA ever changes the
# segment count, this would need updating — failure mode
# is benign (unnecessary updates, not data corruption).
# ─────────────────────────────────────────────────────────
OLD=""
if [[ -f "$CONFIG" ]]; then
    OLD=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$CONFIG" 2>/dev/null | head -1 || echo "")
fi

# ─────────────────────────────────────────────────────────
# Decision tree: states 1, 2, 3.
# ─────────────────────────────────────────────────────────
if [[ "$NEW" == "$OLD" ]]; then
    echo "Config already current: $NEW"
    exit 0
fi

if [[ -z "$OLD" ]]; then
    echo "Creating new config for version $NEW"
else
    echo "Updating config: $OLD -> $NEW"
fi
# Fall through to write/regenerate.

# ─────────────────────────────────────────────────────────
# Write config and regenerate initramfs.
#
# Truncate the config file, then append one install_items+=
# line per GSP firmware path. Multiple lines is dracut-
# supported syntax; chosen over a single space-separated
# line for human readability when inspecting the file.
#
# The --kver flag is required on AlmaLinux 10.x because of
# the dracut-ng EL10 bug (issue #1606) where
# --regenerate-all does not work. Specify the running
# kernel version explicitly.
# ─────────────────────────────────────────────────────────
: > "$CONFIG"
for f in "${GSP_FILES[@]}"; do
    printf 'install_items+=" %s "\n' "$f" >> "$CONFIG"
done

dracut --force --kver "$(uname -r)"
echo "Done. Reboot to apply new initramfs."
