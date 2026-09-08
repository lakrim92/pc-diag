#!/usr/bin/env bash
# Régénère pc-diag.sh.sha256 après chaque mise à jour du script.
# Usage : ./update-hash.sh [chemin/vers/pc-diag.sh]
set -euo pipefail

SCRIPT="${1:-$(dirname "$0")/pc-diag.sh}"
HASH_FILE="$(dirname "$SCRIPT")/pc-diag.sh.sha256"

if [ ! -f "$SCRIPT" ]; then
    echo "Erreur : $SCRIPT introuvable" >&2
    exit 1
fi

sha256sum "$SCRIPT" > "$HASH_FILE"
echo "Hash mis à jour : $HASH_FILE"
cat "$HASH_FILE"
