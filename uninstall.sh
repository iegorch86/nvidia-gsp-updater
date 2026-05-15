#!/usr/bin/env bash
#
# uninstall.sh — remover for nvidia-gsp-updater
#
# Run as root:
#   sudo ./uninstall.sh
#
# Reverses what install.sh did:
#   1. Verifies it is running as root
#   2. Detects whether the system uses DNF4 or DNF5
#   3. Removes the hook file
#   4. Removes the runtime script
#   5. Optionally removes the dracut config the runtime
#      script created, and regenerates the initramfs
#      (asks for consent first)
#
# What this does NOT do:
#   - It does not uninstall the DNF actions plugin package.
#     The plugin is harmless to leave installed and may be
#     used by other automations. If you want it gone, remove
#     it yourself:
#       DNF4: sudo dnf remove python3-dnf-plugin-post-transaction-actions
#       DNF5: sudo dnf remove libdnf5-plugin-actions

set -euo pipefail

# ─────────────────────────────────────────────────────────
# Constants — must match install.sh.
# ─────────────────────────────────────────────────────────
readonly DST_SCRIPT="/usr/local/bin/nvidia-gsp-update.sh"
readonly DRACUT_CONFIG="/etc/dracut.conf.d/nvidia-gsp.conf"

readonly DNF4_HOOK="/etc/dnf/plugins/post-transaction-actions.d/nvidia-gsp.action"
readonly DNF5_HOOK="/etc/dnf/libdnf5-plugins/actions.d/nvidia-gsp.actions"

# ─────────────────────────────────────────────────────────
# Step 1 — Root check.
# ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This uninstaller must be run as root." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

echo "=== nvidia-gsp-updater uninstaller ==="
echo

# ─────────────────────────────────────────────────────────
# Step 2 — Detect DNF version, to know which hook path to
# remove. We remove whichever hook file we find regardless,
# but detecting first keeps the messaging clear.
# ─────────────────────────────────────────────────────────
DNF_MAJOR=""
if command -v dnf >/dev/null 2>&1; then
    DNF_VERSION_LINE="$(dnf --version 2>/dev/null | head -1)"
    DNF_MAJOR="${DNF_VERSION_LINE%%.*}"
fi

# ─────────────────────────────────────────────────────────
# Step 3 — Remove the hook file(s).
#
# We check and remove both possible hook locations. On a
# normal system only one will exist, but removing both is
# safe and covers systems that had both DNF versions.
# ─────────────────────────────────────────────────────────
removed_hook=0
for hook in "$DNF4_HOOK" "$DNF5_HOOK"; do
    if [[ -f "$hook" ]]; then
        echo "Removing hook: $hook"
        rm -f "$hook"
        removed_hook=1
    fi
done
if [[ "$removed_hook" -eq 0 ]]; then
    echo "No hook file found (already removed, or never installed)."
fi
echo

# ─────────────────────────────────────────────────────────
# Step 4 — Remove the runtime script.
# ─────────────────────────────────────────────────────────
if [[ -f "$DST_SCRIPT" ]]; then
    echo "Removing runtime script: $DST_SCRIPT"
    rm -f "$DST_SCRIPT"
else
    echo "Runtime script not found (already removed, or never installed)."
fi
echo

# ─────────────────────────────────────────────────────────
# Step 5 — Optionally remove the dracut config.
#
# This file is what the runtime script manages. Removing it
# means the next initramfs regeneration won't include the
# NVIDIA GSP firmware — which is fine if you are ALSO
# removing the NVIDIA driver, but NOT what you want if you
# are keeping the driver and only removing this tool.
#
# Because of that ambiguity, we ask. Default is to KEEP it.
# ─────────────────────────────────────────────────────────
if [[ -f "$DRACUT_CONFIG" ]]; then
    echo "The dracut config still exists: $DRACUT_CONFIG"
    echo
    echo "  KEEP it   if you are keeping the NVIDIA driver installed"
    echo "            (your GSP firmware stays in initramfs)."
    echo "  REMOVE it if you are also removing the NVIDIA driver, or"
    echo "            want to fully undo everything this tool did."
    echo
    read -r -p "Remove the dracut config and regenerate initramfs? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS])
            echo
            echo "Removing $DRACUT_CONFIG"
            rm -f "$DRACUT_CONFIG"
            echo "Regenerating initramfs for kernel $(uname -r)..."
            dracut --force --kver "$(uname -r)"
            echo "Done. Reboot to apply."
            ;;
        *)
            echo
            echo "Keeping $DRACUT_CONFIG. Initramfs not changed."
            ;;
    esac
else
    echo "No dracut config found (already removed, or never created)."
fi
echo

# ─────────────────────────────────────────────────────────
# Step 6 — Summary.
# ─────────────────────────────────────────────────────────
echo "=== Uninstall complete ==="
echo
echo "The DNF actions plugin was NOT removed — it is harmless to"
echo "leave installed. To remove it yourself:"
if [[ "$DNF_MAJOR" == "5" ]]; then
    echo "  sudo dnf remove libdnf5-plugin-actions"
else
    echo "  sudo dnf remove python3-dnf-plugin-post-transaction-actions"
fi
