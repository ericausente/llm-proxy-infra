#!/bin/bash
# =============================================================
# Toggle NGINX Plus apt repos on/off
# Use before/after apt operations when repos return 400 errors
#
# Usage:
#   ./scripts/toggle-nginx-repos.sh disable   (before apt update)
#   ./scripts/toggle-nginx-repos.sh enable    (after apt install)
#   ./scripts/toggle-nginx-repos.sh status    (see current state)
# =============================================================

ACTION=$1

case "$ACTION" in

  disable)
    echo "Disabling NGINX Plus repos..."
    sudo find /etc/apt/sources.list.d/ \
        -name "*nginx*" ! -name "*.bak" \
        -exec mv {} {}.bak \;
    echo "Done. Repos disabled. Run: sudo apt update"
    echo ""
    echo "Active repo files remaining:"
    ls /etc/apt/sources.list.d/ | grep -v nginx || echo "  (none with nginx in name)"
    ;;

  enable)
    echo "Re-enabling NGINX Plus repos..."
    sudo find /etc/apt/sources.list.d/ \
        -name "*nginx*.bak" \
        -exec bash -c 'mv "$1" "${1%.bak}"' _ {} \;
    echo "Done. Repos re-enabled. Run: sudo apt update"
    echo ""
    echo "Nginx repo files:"
    ls /etc/apt/sources.list.d/ | grep nginx || echo "  (none found)"
    ;;

  status)
    echo "Current nginx repo files in /etc/apt/sources.list.d/:"
    echo ""
    echo "  ACTIVE (will be used by apt):"
    ls /etc/apt/sources.list.d/ | grep nginx | grep -v ".bak" \
        || echo "    (none active)"
    echo ""
    echo "  DISABLED (.bak files):"
    ls /etc/apt/sources.list.d/ | grep nginx | grep ".bak" \
        || echo "    (none disabled)"
    ;;

  *)
    echo "Usage: $0 [disable|enable|status]"
    echo ""
    echo "  disable  — rename nginx repo files to .bak (stops 400 errors)"
    echo "  enable   — rename .bak files back (restore nginx repo updates)"
    echo "  status   — show current state of all nginx repo files"
    echo ""
    echo "Why this exists:"
    echo "  NGINX Plus apt repos require a valid JWT subscription token."
    echo "  When the token expires, pkgs.nginx.com returns 400 Bad Request,"
    echo "  which blocks ALL apt operations on the server."
    echo "  This script safely disables those repos while you install"
    echo "  other packages, then re-enables them."
    echo "  Your running NGINX Plus instance is completely unaffected."
    ;;

esac