#!/usr/bin/env bash
# Construit l'arborescence de fichiers à embarquer dans le module
# SystemRescue (SRM) qui apportera les outils pc-diag à l'ISO.
#
# Principe : on installe les paquets pacman listés dans packages.txt
# dans un conteneur Arch Linux jetable, puis on ne récupère QUE les
# fichiers appartenant aux paquets nouvellement installés (pas ceux
# déjà présents dans l'image de base). Cette arborescence est ensuite
# transformée en module .srm par sysrescue-customize (voir build-iso.sh).
#
# Prérequis : Docker installé et daemon actif.
# Usage     : ./build-srm.sh
# Résultat  : ./recipe-dir/build_into_srm/ rempli avec les fichiers des paquets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="${SCRIPT_DIR}/packages.txt"
RECIPE_DIR="${SCRIPT_DIR}/recipe-dir"
SRM_ROOT="${RECIPE_DIR}/build_into_srm"

if [ ! -f "$PACKAGES_FILE" ]; then
    echo "Introuvable : $PACKAGES_FILE" >&2
    exit 1
fi

PACKAGES="$(grep -v '^\s*#' "$PACKAGES_FILE" | grep -v '^\s*$' | tr '\n' ' ')"
echo "Paquets à intégrer : $PACKAGES"

# Le conteneur écrit en tant que root : si un run précédent a laissé des
# fichiers root:root, un rm -rf normal échoue, on repasse alors par Docker.
rm -rf "$SRM_ROOT" 2>/dev/null || docker run --rm -v "${RECIPE_DIR}:/recipe-dir" alpine:latest rm -rf /recipe-dir/build_into_srm
mkdir -p "$SRM_ROOT"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker run --rm -v "${SRM_ROOT}:/srm-root" -e HOST_UID="$HOST_UID" -e HOST_GID="$HOST_GID" archlinux:latest bash -euc "
    pacman -Sy --noconfirm >/dev/null
    pacman -S --noconfirm --needed cpio >/dev/null

    pacman -Qq | sort > /tmp/before.txt
    pacman -S --noconfirm --needed ${PACKAGES}
    pacman -Qq | sort > /tmp/after.txt

    comm -13 /tmp/before.txt /tmp/after.txt > /tmp/newpkgs.txt
    echo '--- Nouveaux paquets (incl. dépendances) ---'
    cat /tmp/newpkgs.txt

    : > /tmp/files.txt
    while read -r pkg; do
        pacman -Ql \"\$pkg\" | cut -d' ' -f2-
    done < /tmp/newpkgs.txt >> /tmp/files.txt

    cd /
    # NoExtract (pacman.conf) omet man/doc/info du système de base : les
    # lister quand même via pacman -Ql est normal, on ne garde que ce qui
    # existe réellement sur disque.
    : > /tmp/files_existing.txt
    while read -r f; do
        if [ -e \"\$f\" ]; then echo \"\$f\"; fi
    done < <(grep -v '/\$' /tmp/files.txt) > /tmp/files_existing.txt
    cpio -pdm --quiet /srm-root < /tmp/files_existing.txt

    chown -R \"\${HOST_UID}:\${HOST_GID}\" /srm-root
"

# -no-xattrs : évite qu'un mksquashfs récent écrive une table xattr
# "présente mais vide", ce qui fait planter le driver squashfs de certains
# noyaux au montage ("unable to read xattr id index table") — bug constaté
# au boot avec le module généré par sysrescue-customize.
echo "-no-xattrs" > "${SRM_ROOT}/.squashfs-options"

echo "=== Arborescence SRM prête : $SRM_ROOT ==="
du -sh "$SRM_ROOT"
