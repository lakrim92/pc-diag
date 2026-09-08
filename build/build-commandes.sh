#!/usr/bin/env bash
# Commandes pour construire l'ISO SystemRescue personnalisée pc-diag
# Exécuter depuis n'importe quel dossier sur une machine avec Docker

set -euo pipefail

ISO_VERSION="11.03"
ISO_FILE="systemrescue-${ISO_VERSION}-amd64.iso"
ISO_URL="https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/${ISO_VERSION}/${ISO_FILE}/download"
PCDIAG_DIR="$HOME/workspace/pc-diag"

echo "=== Étape 1 : téléchargement ISO SystemRescue ${ISO_VERSION} ==="
wget -O "$ISO_FILE" "$ISO_URL"

echo "=== Étape 2 : build ISO personnalisée ==="
cd "$PCDIAG_DIR/build"
./build-iso.sh "$OLDPWD/$ISO_FILE"

echo "=== Étape 3 : résultat ==="
ls -lh "$PCDIAG_DIR/build/systemrescue-pcdiag.iso"
