# PC-DIAG v2.0

Outil de diagnostic PC professionnel, autonome, sans IA, sans réseau.
Conçu pour les bénévoles de Repair Cafés et associations de réparation.

---

## Ce que ça diagnostique

| Catégorie | Détails |
|-----------|---------|
| Carte mère | Fabricant, modèle, BIOS/UEFI version + date, mode démarrage |
| CPU | Modèle, cœurs, fréquence max, température avec seuils d'alerte |
| RAM | Capacité totale, barrettes détectées (via dmidecode), alertes <2 Go |
| Disques | Type SSD/HDD/NVMe, santé SMART complète, vitesse lecture séquentielle |
| GPU | Modèle, température si accessible |
| Batterie | Usure réelle vs capacité d'origine, cycles de charge, alertes >20%/>40% |
| Réseau/USB/BT | Interfaces réseau, Wi-Fi, Bluetooth, périphériques USB |
| OS installés | Windows (espace, Windows.old, BitLocker) / Linux (distro, noyaux, journaux) / macOS |

---

## Préparer la clé USB

1. Formater une clé USB ≥8 Go avec **[Ventoy](https://www.ventoy.net/)**
2. Télécharger **[SystemRescue](https://www.system-rescue.org/)** (ISO recommandé)
3. Copier l'ISO sur la clé (glisser-déposer)
4. Copier `pc-diag.sh` sur la clé dans un dossier `outils/`

---

## Utilisation

### 1. Démarrer sur la clé USB

F12 / F2 / Suppr selon le constructeur → choisir la clé dans le menu Ventoy.

### 2. Installer les outils si nécessaires (SystemRescue / Arch)

```bash
pacman -Sy --noconfirm smartmontools dmidecode lm_sensors ntfs-3g hivex
sensors-detect --auto
```

### 3. Lancer le diagnostic

```bash
cd /run/media/*/<nom_clé>/outils/   # adapter le chemin
chmod +x pc-diag.sh
sudo ./pc-diag.sh
```

### 4. Exporter le rapport en PDF

Ouvrir `rapports/rapport_XXXXXX.html` dans Firefox → **Fichier > Imprimer > Enregistrer en PDF**

---

## Limites importantes à communiquer aux bénévoles

- **BitLocker (Windows) / FileVault (macOS)** : si le disque est chiffré, l'analyse du contenu OS est impossible sans le mot de passe ou la clé de récupération. Le diagnostic matériel reste disponible.

- **Apple Silicon (M1/M2/M3+)** : le démarrage sur clé USB externe est bloqué par Secure Boot par défaut. Utiliser le diagnostic Apple natif : redémarrer en maintenant **⌘+D**.

- **APFS (macOS récent)** : nécessite le pilote `apfs-fuse`, absent de la plupart des distros live. La partition est détectée mais non montée.

- **Memtest86+** : le script ne remplace pas un test mémoire approfondi. Lancer memtest86+ séparément depuis le menu Ventoy (plusieurs passes, 20-60 min).

---

## Améliorations possibles (v3)

- Stress-test CPU court (`stress-ng --cpu 4 --timeout 60s`) avec relevé températures
- Lecture registre Windows hors-ligne via `hivex` (version, licence, BitLocker)
- Support `apfs-fuse` pour macOS complet
- Export PDF natif via `wkhtmltopdf` (sans passer par Firefox)
- Interface TUI interactive (ncurses)
