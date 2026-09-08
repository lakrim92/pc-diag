#!/usr/bin/env bash
# Commandes pour construire l'ISO SystemRescue personnalisée pc-diag
# Exécuter depuis n'importe quel dossier sur une machine avec Docker

set -euo pipefail

ISO_VERSION="11.03"
ISO_FILE="systemrescue-${ISO_VERSION}-amd64.iso"
ISO_URL="https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/${ISO_VERSION}/${ISO_FILE}/download"
PCDIAG_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Répertoire pc-diag détecté : $PCDIAG_DIR ==="

# Télécharger l'ISO dans le dossier pc-diag si elle n'existe pas déjà
ISO_PATH="${PCDIAG_DIR}/${ISO_FILE}"
if [ -f "$ISO_PATH" ]; then
    echo "=== ISO déjà présente : $ISO_PATH — téléchargement ignoré ==="
else
    echo "=== Étape 1 : téléchargement ISO SystemRescue ${ISO_VERSION} ==="
    wget -O "$ISO_PATH" "$ISO_URL"
fi

echo "=== Étape 2 : build ISO personnalisée ==="
cd "${PCDIAG_DIR}/build"
./build-iso.sh "$ISO_PATH"

echo "=== Étape 3 : résultat ==="
ls -lh "${PCDIAG_DIR}/build/systemrescue-pcdiag.iso"
