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

### 1. Démarrer sur la clé

`F12` / `F2` / `Suppr` selon le constructeur → sélectionner la clé dans le menu Ventoy.

### 2. Installer les outils manquants (SystemRescue / Arch)

```bash
pacman -Sy --noconfirm smartmontools dmidecode lm_sensors ntfs-3g hivex memtester
sensors-detect --auto
```

> Sur d'autres distros live (Ubuntu, Debian) : remplacer `pacman` par `apt-get install`.

### 3. Lancer le diagnostic

```bash
cd /run/media/*/<nom_clé>/outils/
chmod +x pc-diag.sh
sudo ./pc-diag.sh
```

Le rapport HTML s'ouvre automatiquement dans Firefox ou Chromium à la fin (si session graphique disponible).

### 4. Récupérer les rapports

Deux fichiers sont générés dans `./rapports/` :
- `rapport_YYYYMMDD_HHMMSS.html` — rapport complet avec dark mode, imprimable en PDF
- `rapport_YYYYMMDD_HHMMSS.txt` — résumé texte pour les archives de l'association

### 5. Exporter en PDF

Firefox → **Fichier > Imprimer > Enregistrer en PDF**

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
