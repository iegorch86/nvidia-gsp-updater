#!/usr/bin/env bash
#
# install.sh — bootstrapper for nvidia-gsp-updater
#
# Run ONCE, manually, as root:
#   sudo ./install.sh
#
# This script is run standalone by the user — NOT inside a dnf
# transaction — so it can safely call `dnf install`. The runtime
# script (nvidia-gsp-update.sh) must never do that, because it
# runs inside dnf transactions and would deadlock on the dnf lock.
#
# What this does:
#   1. Verifies it is running as root
#   2. Detects whether the system uses DNF4 or DNF5
#   3. Checks whether the matching actions plugin is installed;
#      if not, shows the user exactly what it wants to install
#      and asks for consent before running `dnf install`
#   4. Copies nvidia-gsp-update.sh to /usr/local/bin/
#   5. Copies the correct hook file to the correct directory
#   6. Verifies the plugin is enabled (DNF4)
#   7. Runs nvidia-gsp-update.sh once as a sanity check
#   8. Prints a summary

set -euo pipefail

# ─────────────────────────────────────────────────────────
# Constants — source paths (relative to this script) and
# destination paths on the system.
# ─────────────────────────────────────────────────────────
# Resolve the directory this script lives in, so it works
# regardless of where the user runs it from.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly SRC_SCRIPT="$SCRIPT_DIR/nvidia-gsp-update.sh"
readonly SRC_HOOK_DNF4="$SCRIPT_DIR/hooks/dnf4/nvidia-gsp.action"
readonly SRC_HOOK_DNF5="$SCRIPT_DIR/hooks/dnf5/nvidia-gsp.actions"

readonly DST_SCRIPT="/usr/local/bin/nvidia-gsp-update.sh"

readonly DNF4_PLUGIN_PKG="python3-dnf-plugin-post-transaction-actions"
readonly DNF4_HOOK_DIR="/etc/dnf/plugins/post-transaction-actions.d"
readonly DNF4_PLUGIN_CONF="/etc/dnf/plugins/post-transaction-actions.conf"

readonly DNF5_PLUGIN_PKG="libdnf5-plugin-actions"
readonly DNF5_HOOK_DIR="/etc/dnf/libdnf5-plugins/actions.d"

# ─────────────────────────────────────────────────────────
# Step 1 — Root check.
# Every operation below (dnf install, writing to /usr/local/
# bin and /etc) requires root.
# ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────
# Pre-flight — confirm the files we need to deploy are
# actually present next to this script. Catches the case
# of running install.sh outside the unpacked repo.
# ─────────────────────────────────────────────────────────
if [[ ! -f "$SRC_SCRIPT" ]]; then
    echo "ERROR: cannot find nvidia-gsp-update.sh next to this installer." >&2
    echo "Run install.sh from inside the unpacked nvidia-gsp-updater directory." >&2
    exit 1
fi

echo "=== nvidia-gsp-updater installer ==="
echo

# ─────────────────────────────────────────────────────────
# Step 2 — Detect DNF version.
#
# `dnf --version` prints the version on its first line. We
# read the major number from it. DNF4 prints 4.x.y, DNF5
# prints 5.x.y. We set DNF_MAJOR accordingly and pick the
# matching plugin package, hook directory, and source hook.
# ─────────────────────────────────────────────────────────
if ! command -v dnf >/dev/null 2>&1; then
    echo "ERROR: 'dnf' command not found. This system does not appear to" >&2
    echo "be a DNF-based distribution." >&2
    exit 1
fi

DNF_VERSION_LINE="$(dnf --version 2>/dev/null | head -1)"
DNF_MAJOR="${DNF_VERSION_LINE%%.*}"

case "$DNF_MAJOR" in
    4)
        echo "Detected: DNF4 (dnf $DNF_VERSION_LINE)"
        PLUGIN_PKG="$DNF4_PLUGIN_PKG"
        HOOK_DIR="$DNF4_HOOK_DIR"
        SRC_HOOK="$SRC_HOOK_DNF4"
        HOOK_NAME="nvidia-gsp.action"
        ;;
    5)
        echo "Detected: DNF5 (dnf $DNF_VERSION_LINE)"
        PLUGIN_PKG="$DNF5_PLUGIN_PKG"
        HOOK_DIR="$DNF5_HOOK_DIR"
        SRC_HOOK="$SRC_HOOK_DNF5"
        HOOK_NAME="nvidia-gsp.actions"
        ;;
    *)
        echo "ERROR: could not determine DNF major version." >&2
        echo "  'dnf --version' first line was: $DNF_VERSION_LINE" >&2
        echo "  Expected it to start with 4 or 5." >&2
        exit 1
        ;;
esac
echo

# ─────────────────────────────────────────────────────────
# Step 3 — Ensure the actions plugin is installed.
#
# rpm -q exits 0 if the package is installed, non-zero if
# not. If it's missing, we tell the user exactly what we
# want to install and why, then ask for explicit consent
# before running `dnf install`. No silent package installs.
# ─────────────────────────────────────────────────────────
if rpm -q "$PLUGIN_PKG" >/dev/null 2>&1; then
    echo "Actions plugin already installed: $PLUGIN_PKG"
else
    echo "The DNF actions plugin is required for the hook to fire."
    echo "It is not currently installed."
    echo
    echo "  Package to install: $PLUGIN_PKG"
    echo
    read -r -p "Install it now with dnf? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS])
            echo
            dnf install -y "$PLUGIN_PKG"
            echo
            ;;
        *)
            echo
            echo "Plugin not installed. Cannot continue — the hook would" >&2
            echo "never fire without it. Re-run install.sh when ready to" >&2
            echo "install the plugin." >&2
            exit 1
            ;;
    esac
fi
echo

# ─────────────────────────────────────────────────────────
# Step 4 — Deploy the runtime script.
# Copy into place, set ownership to root, mode 755
# (executable by all, writable only by root).
# ─────────────────────────────────────────────────────────
echo "Installing runtime script -> $DST_SCRIPT"
cp "$SRC_SCRIPT" "$DST_SCRIPT"
chown root:root "$DST_SCRIPT"
chmod 755 "$DST_SCRIPT"

# ─────────────────────────────────────────────────────────
# Step 5 — Deploy the hook file.
#
# The plugin install (Step 3) creates HOOK_DIR. In the rare
# case it doesn't exist (e.g. plugin was already installed
# but the directory was removed), create it so the copy
# does not fail.
# ─────────────────────────────────────────────────────────
echo "Installing hook -> $HOOK_DIR/$HOOK_NAME"
mkdir -p "$HOOK_DIR"
cp "$SRC_HOOK" "$HOOK_DIR/$HOOK_NAME"
chown root:root "$HOOK_DIR/$HOOK_NAME"
chmod 644 "$HOOK_DIR/$HOOK_NAME"
echo

# ─────────────────────────────────────────────────────────
# Step 6 — Verify the plugin is enabled (DNF4 only).
#
# The DNF4 post-transaction-actions plugin has a .conf file
# with an enabled flag. The plugin install normally sets
# enabled=1, but we check and warn if not. DNF5's actions
# plugin has no equivalent enable/disable conf file, so we
# skip this check there.
# ─────────────────────────────────────────────────────────
if [[ "$DNF_MAJOR" == "4" ]]; then
    if [[ -f "$DNF4_PLUGIN_CONF" ]] && grep -qE '^\s*enabled\s*=\s*1' "$DNF4_PLUGIN_CONF"; then
        echo "Plugin is enabled in $DNF4_PLUGIN_CONF"
    else
        echo "WARNING: plugin may not be enabled."
        echo "  Check $DNF4_PLUGIN_CONF and ensure it contains: enabled=1"
    fi
    echo
fi

# ─────────────────────────────────────────────────────────
# Step 7 — Sanity check: run the runtime script once.
#
# This exercises the script's state-detection logic on the
# current system and shows the user its output. On a system
# with NVIDIA already installed and a correct config, this
# prints "Config already current". On a fresh system with
# NVIDIA installed but no config yet, it creates the config.
# On a system with no NVIDIA, it prints "nothing to do".
# All of these are valid — the point is to confirm the
# script runs cleanly.
# ─────────────────────────────────────────────────────────
echo "Running a one-time sanity check ($DST_SCRIPT):"
echo "---"
"$DST_SCRIPT"
echo "---"
echo

# ─────────────────────────────────────────────────────────
# Step 8 — Summary.
# ─────────────────────────────────────────────────────────
echo "=== Installation complete ==="
echo
echo "  Runtime script : $DST_SCRIPT"
echo "  Hook file      : $HOOK_DIR/$HOOK_NAME"
echo "  Actions plugin : $PLUGIN_PKG (installed)"
echo
echo "The hook will now fire automatically on any NVIDIA package"
echo "transaction (install, upgrade, downgrade, remove)."
echo
echo "If the sanity check above created or changed the dracut config,"
echo "reboot to apply the new initramfs."
echo
echo "To remove everything later, run: sudo ./uninstall.sh"
