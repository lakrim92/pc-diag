# PC-DIAG v4.1

Outil de diagnostic PC professionnel, autonome, sans IA, sans réseau.
Conçu pour les bénévoles de Repair Cafés et associations de réparation informatique.

Génère un **rapport HTML complet** (imprimable en PDF) + **export TXT** en moins de 3 minutes.

---

## Ce que ça diagnostique — 11 modules + Recommandations

| # | Module | Ce qui est analysé |
|---|--------|--------------------|
| 1 | Outils système | Vérifie la présence de tous les outils nécessaires |
| 2 | Carte mère & BIOS/UEFI | Fabricant, modèle, **numéro de série**, UUID, version BIOS, date, UEFI vs Legacy, **état Secure Boot** |
| 3 | Processeur (CPU) | Modèle, cœurs, fréquence max, température (seuils 75°C / 90°C) |
| 4 | Mémoire vive (RAM) | Capacité, utilisation, barrettes détectées (slot, fréquence, fabricant) |
| 5 | Test intégrité RAM | `memtester` dynamique (25% RAM libre, min 64 Mo, max 512 Mo) — détecte les erreurs bit à bit |
| 6 | Disques (SMART + vitesse) | SSD/HDD/NVMe, santé SMART, secteurs réalloués, **secteurs en attente (Current_Pending)**, **heures de fonctionnement** (âge estimé), **température disque**, vitesse lecture séquentielle calibrée par type |
| 7 | Carte graphique (GPU) | Modèle, température si accessible |
| 8 | Stress-test CPU | 30s de charge totale — température max, delta thermique, **détection throttling** |
| 9 | Batterie | Usure réelle vs capacité d'origine, cycles de charge (alertes >20% / >40%) |
| 10 | Réseau / USB / Bluetooth | Interfaces réseau, Wi-Fi, Bluetooth, périphériques USB |
| 11 | Table des partitions | Vue complète de la structure disque (`parted` ou `fdisk`) |
| OS | Systèmes installés | Windows (version, build, Defender, **BitLocker**), Linux (distro, noyaux, journaux), macOS |
| ★ | **Recommandations** | Section synthèse priorisée : URGENT / IMPORTANT / CONSEILLÉ / INFO |

---

## Préparer la clé USB

1. Formater une clé USB **≥ 8 Go** avec **[Ventoy](https://www.ventoy.net/)** (une seule fois)
2. Télécharger **[SystemRescue](https://www.system-rescue.org/)** et copier l'ISO sur la clé
3. Copier `pc-diag.sh` sur la clé dans un dossier `outils/`

---

## Utilisation

### 1. Démarrer sur la clé USB

Accéder au menu de démarrage avec `F12` / `F2` / `Suppr` selon le constructeur, puis sélectionner la clé USB.

Le menu **Ventoy** s'affiche → choisir **Normal Mode**.

Une deuxième page apparaît → appuyer sur **Entrée** sur l'option :
> `Boot SystemRescue using default option`

### 2. Lancer l'interface graphique

Une fois le système démarré, une invite de commande apparaît. Taper :

```bash
startx
```

L'environnement graphique XFCE démarre.

### 3. Régler le clavier en AZERTY (utilisateurs francophones)

Dans le bureau XFCE : **Settings > Keyboard > Layout** → ajouter `French (AZERTY)` et supprimer la disposition par défaut.

### 4. Monter la clé Ventoy

Ouvrir un terminal et identifier le périphérique de la clé :

```bash
lsblk
```

La clé Ventoy apparaît généralement sous le nom `sda`, `sdb` ou `sdc`. La partition de données (FAT32, contenant les ISOs et le dossier `outils/`) est la **première partition** (ex. `sda1`).

```bash
mkdir -p /mnt/ventoy
mount /dev/sda1 /mnt/ventoy   # Remplacer sda1 par le bon périphérique si nécessaire
```

> **Note** : si `sda1` n'est pas le bon périphérique, vérifier avec `lsblk` et adapter la commande.

### 5. Copier et lancer le diagnostic

```bash
cp /mnt/ventoy/outils/pc-diag.sh ~/
chmod +x ~/pc-diag.sh
sudo ~/pc-diag.sh
```

Le diagnostic s'exécute et génère un rapport HTML dans `~/rapports/`.

### 6. Consulter le rapport

Une fois le diagnostic terminé, ouvrir **Firefox** et saisir dans la barre d'adresse :

```
file:///root/rapports/rapport_YYYYMMDD_HHMMSS.html
```

Remplacer `YYYYMMDD_HHMMSS` par l'horodatage affiché à la fin du diagnostic.

### 7. Copier le rapport sur la clé USB

Pour récupérer le rapport sur un autre poste, le copier sur la clé Ventoy :

```bash
cp ~/rapports/rapport_YYYYMMDD_HHMMSS.html /mnt/ventoy/
```

La clé Ventoy étant montée sur `/mnt/ventoy`, le fichier HTML sera accessible directement depuis la clé sur n'importe quel système.

### 8. Redémarrer et exploiter le rapport

Redémarrer le PC normalement, récupérer la clé USB et ouvrir le rapport HTML dans un navigateur.

Pour l'archiver ou le transmettre au client :

Firefox → **Fichier > Imprimer > Enregistrer en PDF**

---

## Fichiers générés

Deux fichiers sont créés dans `~/rapports/` à chaque diagnostic :
- `rapport_YYYYMMDD_HHMMSS.html` — rapport complet avec dark mode, imprimable en PDF
- `rapport_YYYYMMDD_HHMMSS.txt` — résumé texte pour les archives de l'association

---

## Rapport généré

Le rapport HTML inclut :
- Synthèse visuelle en 4 tuiles (OK / Attention / Critique / Info)
- Code couleur par section avec badge de statut
- **Section Recommandations** priorisée (URGENT → IMPORTANT → CONSEILLÉ → INFO)
- Dark mode automatique selon le thème du navigateur
- Compatible impression PDF (mise en page dédiée)
- Export TXT parallèle pour les archives de l'association

---

## Limites à communiquer aux bénévoles

**BitLocker (Windows) / FileVault (macOS)** — si le disque est chiffré, l'analyse du contenu OS est impossible sans le mot de passe ou la clé de récupération. Le diagnostic matériel reste entièrement disponible.

**Apple Silicon (M1/M2/M3+)** — le démarrage sur clé USB externe est verrouillé par Secure Boot par défaut. Utiliser le diagnostic Apple natif : redémarrer en maintenant **⌘+D**.

**APFS (macOS récent)** — nécessite le pilote `apfs-fuse`, absent des distros live par défaut. La partition est détectée mais non montée.

**Test mémoire complet** — `memtester` fait un test rapide (25% RAM disponible, 1 passe). Pour une validation exhaustive (toute la RAM, plusieurs passes), lancer **memtest86+** depuis le menu Ventoy (compter 20 à 60 min).

**Session graphique** — si le diagnostic tourne en console pure (sans X11/Wayland), le navigateur ne s'ouvre pas automatiquement. Le rapport reste disponible dans `./rapports/`.

**Environnement virtuel (VM / cloud)** — les disques virtuels (`vda`, `vdb`, `vdc`...) ne supportent pas SMART. Le diagnostic matériel reste partiel ; l'analyse OS fonctionne normalement.

**Outils réseau / PCI / USB absents** — `lspci`, `lsusb` et `ip` sont pré-installés sur SystemRescue mais peuvent manquer sur d'autres live CD. Les installer si besoin :
```bash
# Arch/SystemRescue
pacman -Sy --noconfirm pciutils usbutils iproute2
# Debian/Ubuntu live
apt-get install -y pciutils usbutils iproute2
```

---

## Dépendances

Toutes optionnelles — le script signale les outils absents et adapte le rapport.

| Outil | Usage | Paquet |
|-------|-------|--------|
| `smartmontools` | Santé SMART des disques, heures de fonctionnement | `smartmontools` |
| `dmidecode` | Infos carte mère, RAM, numéro de série | `dmidecode` |
| `lm-sensors` | Températures CPU/GPU | `lm_sensors` |
| `stress-ng` | Stress-test CPU | `stress-ng` |
| `memtester` | Test intégrité RAM rapide | `memtester` |
| `ntfs-3g` | Montage partitions Windows | `ntfs-3g` |
| `hivex` | Lecture registre Windows hors-ligne | `hivex` |
| `parted` | Table des partitions | `parted` |

---

## Licence

MIT — libre d'utilisation, de modification et de redistribution.
