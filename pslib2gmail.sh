#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd $SCRIPT_DIR

source "$SCRIPT_DIR/config"


# ============================================================
# Kontrola závislostí
# ============================================================

for cmd in jq flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Program '$cmd' nebyl nalezen." >&2
        exit 1
    fi
done


# ============================================================
# Lock
#
# Zabrání tomu, aby se při pomalém imapsync spustila druhá
# instance.
# ============================================================

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Synchronizace už běží."
    exit 2
fi


# ============================================================
# Log
# ============================================================

exec >>"$LOG_FILE" 2>&1

echo
echo "============================================================"
echo "$(date '+%Y-%m-%d %H:%M:%S') - START synchronizace"
echo "============================================================"


# ============================================================
# Obnovení O365 access tokenu
#
# Skript sám rozhodne, zda je refresh potřeba.
# ============================================================

echo
echo "------------------------------------------------------------"
echo "$(date '+%Y-%m-%d %H:%M:%S') - START refreh token scripts"
echo "------------------------------------------------------------"
"$O365_REFRESH_TOKEN_SCRIPT"
"$GMAIL_REFRESH_TOKEN_SCRIPT"


# ============================================================
# Synchronizace O365 -> Gmail
# ============================================================

echo
echo "------------------------------------------------------------"
echo "$(date '+%Y-%m-%d %H:%M:%S') - START e-mail sync"
echo "------------------------------------------------------------"

"$SYNC_EMAILS"

RESULT=$?


# ============================================================
# Výsledek
# ============================================================

if [[ "$RESULT" -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Synchronizace OK."
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $SYNC_EMAILS skončil s kódem $RESULT."
fi


echo
echo "============================================================"
echo "$(date '+%Y-%m-%d %H:%M:%S') - KONEC"
echo "============================================================"

exit "$RESULT"
