#!/usr/bin/env bash
# Génère une ISO SystemRescue personnalisée avec tous les outils pc-diag.
#
# Prérequis : Docker installé et daemon actif.
# Usage     : ./build-iso.sh /chemin/vers/systemrescue-x.y.z.iso
#
# Résultat  : systemrescue-pcdiag.iso dans le répertoire courant.
set -euo pipefail

INPUT_ISO="${1:-}"
if [ -z "$INPUT_ISO" ] || [ ! -f "$INPUT_ISO" ]; then
    echo "Usage : $0 /chemin/vers/systemrescue-x.y.z.iso" >&2
    echo "Télécharger l'ISO sur https://www.system-rescue.org/Download/" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_ISO="$(pwd)/systemrescue-pcdiag.iso"
YAML="${SCRIPT_DIR}/sysrescue-custom.yaml"

echo "=== Build ISO SystemRescue + outils pc-diag ==="
echo "  Entrée : $INPUT_ISO"
echo "  Sortie : $OUTPUT_ISO"
echo "  Config : $YAML"
echo

docker run --rm \
    -v "$(pwd)":/work \
    -v "${INPUT_ISO}":/input.iso:ro \
    -v "${YAML}":/sysrescue-custom.yaml:ro \
    registry.gitlab.com/systemrescue/sysrescue-customize \
    --input  /input.iso \
    --output /work/systemrescue-pcdiag.iso \
    --yaml   /sysrescue-custom.yaml

echo
echo "=== Terminé ==="
echo "  ISO générée : $OUTPUT_ISO"
echo
echo "Étapes suivantes :"
echo "  1. Copier systemrescue-pcdiag.iso sur la clé Ventoy (remplacer l'ancienne)"
echo "  2. Copier pc-diag.sh sur la clé (ex: /Ventoy/outils/pc-diag.sh)"
echo "  3. Régénérer le hash : ../update-hash.sh ../pc-diag.sh"
echo "     puis copier pc-diag.sh.sha256 à côté du script sur la clé"
