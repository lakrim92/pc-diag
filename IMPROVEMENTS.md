# PC-DIAG — Points d'amélioration identifiés

Évaluation réalisée le 2026-09-07 sur la version 4.1.

---

## 1. `dd` sans timeout — risque de blocage (priorité haute)

**Fichier :** `pc-diag.sh` ligne ~776  
**Problème :** Sur un disque défaillant ou très lent, `dd if=/dev/$dev count=128` peut se bloquer plusieurs minutes sans feedback.  
**Correction :**
```bash
# Avant
dd_out="$(dd if="$dev" of=/dev/null bs=4M count=128 iflag=direct 2>&1)" || true

# Après
dd_out="$(timeout 60 dd if="$dev" of=/dev/null bs=4M count=128 iflag=direct 2>&1)" || true
```

---

## 2. `OUTDIR` relatif au CWD — rapport dans un mauvais dossier

**Fichier :** `pc-diag.sh` ligne ~22  
**Problème :** Si le script est lancé depuis `/` ou un dossier inattendu, `./rapports/` crée le rapport hors de `/root/`. Le workflow `cp ~/pc-diag.sh ~/ && sudo ~/pc-diag.sh` contourne le problème, mais le risque reste silencieux.  
**Correction :**
```bash
# Avant
OUTDIR="${OUTDIR:-./rapports}"

# Après
OUTDIR="${OUTDIR:-/root/rapports}"
```

---

## 3. Recommandation `pacman` hardcodée dans le rapport HTML

**Fichier :** `pc-diag.sh` ligne ~330 (fonction `check_tools`)  
**Problème :** La note affichée dans le rapport HTML recommande `pacman -Sy ...` même si la distro live utilisée est Ubuntu ou Debian.  
**Correction :** Détecter le gestionnaire de paquets disponible et adapter la note :
```bash
if need_cmd pacman; then
    PKG_CMD="pacman -Sy --noconfirm"
elif need_cmd apt-get; then
    PKG_CMD="apt-get install -y"
fi
```

---

## 4. Module GPU trop limité ✅ corrigé

**Fichier :** `pc-diag.sh` fonction `check_gpu`  
**Problème initial :** Le module se limitait à un `lspci` — pas de VRAM, pas de driver chargé, pas de température NVIDIA.  
**Corrections apportées :**
- Driver kernel chargé : `lsmod` filtré sur `nvidia`, `amdgpu`, `i915`, `nouveau`, `radeon`
- Température AMD/générique : `sensors` sur les capteurs `edge`/`junction`/`GPU`
- GPU Intel intégré : fréquence courante lue dans `/sys/class/drm/card*/gt_cur_freq_mhz`
- GPU NVIDIA : tableau complet via `nvidia-smi` — nom, version driver, température, VRAM utilisée/totale, charge GPU (%)

---

## 5. Absence de vérification d'intégrité du script

**Problème :** Dans un contexte associatif, la clé USB circule entre bénévoles. Une corruption partielle du script (bit flip, copie incomplète) peut passer inaperçue et produire un diagnostic erroné.  
**Correction possible :** Embarquer un hash SHA256 du script dans un fichier `pc-diag.sh.sha256` sur la clé, et vérifier au démarrage :
```bash
sha256sum -c /mnt/ventoy/outils/pc-diag.sh.sha256 2>/dev/null || {
    echo "⚠ Intégrité du script non vérifiée — continuer ? (Entrée / Ctrl+C)"
    read -r
}
```

---

## 6. ISO SystemRescue personnalisée — usage intensif (plusieurs fois par jour)

**Contexte :** Par défaut, SystemRescue ne contient pas tous les outils nécessaires (`hivex`, `stress-ng`, `nvme-cli`…). Ils doivent être installés via `pacman` à chaque redémarrage, ce qui est inutilisable en usage quotidien intensif.

**Solution :** Générer une ISO SystemRescue personnalisée avec tous les outils pré-intégrés via `sysrescue-customize` (outil officiel).

Les fichiers nécessaires sont déjà présents dans ce dépôt :
- `build/packages.txt` — liste des paquets pacman à intégrer
- `build/build-srm.sh` — construit le module SRM (installe les paquets dans un conteneur Arch Linux jetable, récupère uniquement les fichiers des paquets nouvellement installés)
- `build/build-iso.sh` — pilote le build complet : appelle `build-srm.sh` puis exécute l'outil officiel `sysrescue-customize` (téléchargé à la volée) dans un conteneur Debian pour recompresser l'ISO avec le module SRM intégré
- `update-hash.sh` — régénère le hash SHA256 après mise à jour du script

Le chargement du module au démarrage (`loadsrm`) est activé automatiquement par `sysrescue-customize`, aucune action manuelle n'est requise sur la clé.

---

### Prérequis

- Docker installé et daemon actif (Linux, macOS ou Windows WSL2)
- ISO SystemRescue officielle téléchargée depuis https://www.system-rescue.org/Download/

---

### Procédure complète

#### Étape 1 — Cloner ou récupérer le dépôt pc-diag

```bash
git clone https://github.com/<ton-repo>/pc-diag.git
cd pc-diag
```

#### Étape 2 — Télécharger l'ISO SystemRescue officielle

```bash
# Exemple avec la version 11.x — adapter selon la dernière version disponible
wget https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/11.01/systemrescue-11.01-amd64.iso
```

#### Étape 3 — Générer l'ISO personnalisée

```bash
cd build/
./build-iso.sh /chemin/vers/systemrescue-11.01-amd64.iso
```

Le script génère `systemrescue-pcdiag.iso` dans le répertoire courant.  
Durée estimée : 5 à 15 minutes selon la connexion (téléchargement des paquets par Docker).

Paquets intégrés (`build/packages.txt`) :

| Paquet | Rôle |
|---|---|
| `smartmontools` | SMART disques SATA/SSD |
| `nvme-cli` | SMART disques NVMe |
| `dmidecode` | Infos carte mère / BIOS / RAM |
| `lm_sensors` | Températures et tensions |
| `ntfs-3g` | Montage partitions Windows |
| `hivex` | Analyse registre Windows offline |
| `memtester` | Test intégrité RAM |
| `stress-ng` | Stress-test CPU/IO |
| `parted` | Analyse table des partitions |

#### Étape 4 — Copier l'ISO sur la clé Ventoy

```bash
# Remplacer l'ancienne ISO sur la clé (adapter le chemin de montage)
cp systemrescue-pcdiag.iso /media/$USER/Ventoy/
```

#### Étape 5 — Copier le script pc-diag sur la clé

```bash
# Créer le dossier outils sur la clé si besoin
mkdir -p /media/$USER/Ventoy/outils/

# Copier le script et son hash
cp pc-diag.sh /media/$USER/Ventoy/outils/
./update-hash.sh pc-diag.sh
cp pc-diag.sh.sha256 /media/$USER/Ventoy/outils/
```

#### Étape 6 — Vérifier

Démarrer sur la clé et lancer :

```bash
startx                                          # démarrer l'interface graphique
mkdir -p ~/outils && cp /mnt/ventoy/outils/pc-diag.sh ~/
sudo ~/pc-diag.sh                               # lancer le diagnostic
```

Aucune installation nécessaire — tous les outils sont déjà dans l'ISO.

---

### Mettre à jour pc-diag sans reconstruire l'ISO

Si seul le script est modifié, il suffit de le recopier sur la clé et de régénérer le hash :

```bash
cp pc-diag.sh /media/$USER/Ventoy/outils/
./update-hash.sh pc-diag.sh
cp pc-diag.sh.sha256 /media/$USER/Ventoy/outils/
```

L'ISO n'a pas à être reconstruite.

---

**Référence :** https://www.system-rescue.org/manual/Customizing_SystemRescue/

---

## Résumé des priorités

| # | Priorité | Effort | Impact | Statut |
|---|----------|--------|--------|--------|
| 1 | Haute    | Faible | Évite blocage sur disque défaillant | ✅ |
| 2 | Haute    | Faible | Rapport toujours dans `/root/rapports/` | ✅ |
| 3 | Moyenne  | Faible | Note d'aide correcte quelle que soit la distro | ✅ |
| 5 | Basse    | Moyen  | Sécurité clé USB partagée | ✅ |
| 6 | Haute    | Moyen  | Clé opérationnelle immédiatement, usage intensif | ✅ |
| 4 | Basse    | Élevé  | Meilleur diagnostic GPU | ✅ |
