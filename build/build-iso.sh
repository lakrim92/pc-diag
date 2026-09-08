#!/usr/bin/env bash
# Génère une ISO SystemRescue personnalisée avec tous les outils pc-diag,
# en utilisant l'outil officiel `sysrescue-customize` en mode --auto.
# Référence : https://www.system-rescue.org/scripts/sysrescue-customize/
#
# Prérequis : Docker installé et daemon actif.
# Usage     : ./build-iso.sh /chemin/vers/systemrescue-x.y.z.iso
#
# Résultat  : systemrescue-pcdiag.iso dans le répertoire courant.
#
# loadsrm : sysrescue-customize active automatiquement le chargement du
# module SRM au démarrage (global: loadsrm: true), aucune action manuelle
# n'est nécessaire au boot.
set -euo pipefail

INPUT_ISO="${1:-}"
if [ -z "$INPUT_ISO" ] || [ ! -f "$INPUT_ISO" ]; then
    echo "Usage : $0 /chemin/vers/systemrescue-x.y.z.iso" >&2
    echo "Télécharger l'ISO sur https://www.system-rescue.org/Download/" >&2
    exit 1
fi
INPUT_ISO="$(cd "$(dirname "$INPUT_ISO")" && pwd)/$(basename "$INPUT_ISO")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE_DIR="${SCRIPT_DIR}/recipe-dir"
OUTPUT_ISO="$(pwd)/systemrescue-pcdiag.iso"
SYSRESCUE_CUSTOMIZE_URL="https://gitlab.com/systemrescue/systemrescue-sources/-/raw/main/airootfs/usr/share/sysrescue/bin/sysrescue-customize"

echo "=== Étape 1/2 : construction du module SRM (paquets pc-diag) ==="
"${SCRIPT_DIR}/build-srm.sh"

echo
echo "=== Étape 2/2 : build ISO SystemRescue + outils pc-diag ==="
echo "  Entrée : $INPUT_ISO"
echo "  Sortie : $OUTPUT_ISO"
echo "  Recette : $RECIPE_DIR"
echo

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker run --rm \
    -v "${OUTPUT_ISO%/*}":/work \
    -v "${INPUT_ISO}":/input.iso:ro \
    -v "${RECIPE_DIR}":/recipe-dir:ro \
    -e HOST_UID="$HOST_UID" -e HOST_GID="$HOST_GID" \
    debian:stable-slim bash -euc "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq xorriso squashfs-tools wget patch rsync >/dev/null
        wget -q -O /usr/local/bin/sysrescue-customize '${SYSRESCUE_CUSTOMIZE_URL}'
        chmod +x /usr/local/bin/sysrescue-customize
        sysrescue-customize --auto \
            --source=/input.iso \
            --dest=/work/$(basename "$OUTPUT_ISO") \
            --recipe-dir=/recipe-dir \
            --overwrite
        chown \"\${HOST_UID}:\${HOST_GID}\" /work/$(basename "$OUTPUT_ISO")
    "

echo
echo "=== Terminé ==="
echo "  ISO générée : $OUTPUT_ISO"
echo
echo "Étapes suivantes :"
echo "  1. Copier systemrescue-pcdiag.iso sur la clé Ventoy (remplacer l'ancienne)"
echo "  2. Copier pc-diag.sh sur la clé (ex: /Ventoy/outils/pc-diag.sh)"
echo "  3. Régénérer le hash : ../update-hash.sh ../pc-diag.sh"
echo "     puis copier pc-diag.sh.sha256 à côté du script sur la clé"
