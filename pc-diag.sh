#!/usr/bin/env bash
###############################################################################
# PC-DIAG v4.1 — Outil de diagnostic matériel et système professionnel
#
# Usage : sudo ./pc-diag.sh
#
# Conçu pour tourner depuis un Linux live (clé USB Ventoy + SystemRescue).
# Diagnostique le matériel indépendamment de l'OS installé, puis analyse
# les partitions trouvées (Windows / Linux / macOS).
#
# 100% local — aucun réseau, aucune IA, aucune donnée ne quitte la machine.
###############################################################################

set -uo pipefail

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
VERSION="4.1"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-/root/rapports}"
MOUNT_ROOT="/tmp/pcdiag_mnt"
REPORT_FILE="${OUTDIR}/rapport_${TIMESTAMP}.html"
TXT_FILE="${OUTDIR}/rapport_${TIMESTAMP}.txt"
HOSTNAME_DIAG="$(hostname 2>/dev/null || echo inconnu)"

mkdir -p "$OUTDIR" "$MOUNT_ROOT"

# Compteurs synthèse
declare -i COUNT_OK=0 COUNT_WARN=0 COUNT_CRIT=0 COUNT_INFO=0

# PIDs des processus de stress (nettoyage sur EXIT/INT/TERM)
declare -a _STRESS_PIDS=()
_cleanup() {
    for _p in "${_STRESS_PIDS[@]:-}"; do
        kill "$_p" 2>/dev/null || true
    done
}
trap _cleanup EXIT INT TERM

# Recommandations collectées pendant le diagnostic
declare -a RECOMMENDATIONS=()
add_reco() {
    # add_reco "URGENT|IMPORTANT|CONSEILLÉ|INFO" "texte"
    RECOMMENDATIONS+=("${1}:::${2}")
}

# ---------------------------------------------------------------------------
# PRÉ-REQUIS
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "⚠  Ce script nécessite les droits root : sudo $0" >&2
    exit 1
fi

# Vérification d'intégrité SHA256 (optionnelle — ne bloque que si le fichier
# .sha256 existe et que le hash ne correspond pas).
_check_integrity() {
    local script_real
    script_real="$(realpath "$0" 2>/dev/null || echo "$0")"
    local script_dir
    script_dir="$(dirname "$script_real")"

    local hash_file=""
    for _candidate in \
        "${script_dir}/pc-diag.sh.sha256" \
        "/mnt/ventoy/outils/pc-diag.sh.sha256" \
        "/run/archiso/bootmnt/outils/pc-diag.sh.sha256"
    do
        [ -f "$_candidate" ] && { hash_file="$_candidate"; break; }
    done

    [ -z "$hash_file" ] && return 0   # pas de fichier → vérification ignorée

    local expected actual
    expected="$(awk '{print $1}' "$hash_file")"
    actual="$(sha256sum "$script_real" | awk '{print $1}')"

    if [ "$expected" != "$actual" ]; then
        printf "\n⚠  INTÉGRITÉ DU SCRIPT NON VÉRIFIÉE\n"
        printf "   Attendu  : %s\n" "$expected"
        printf "   Calculé  : %s\n" "$actual"
        printf "   Source   : %s\n\n" "$hash_file"
        printf "   Le script a peut-être été modifié ou corrompu.\n"
        printf "   Appuyer sur Entrée pour continuer quand même, ou Ctrl+C pour annuler : "
        read -r
    fi
}
_check_integrity

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Format a value with unit, or a fallback string if the value is empty
_fmtval() { [ -n "$1" ] && printf '%s%s' "$1" "$2" || printf '%s' "${3:-?}"; }

MISSING_TOOLS=()
for _t in lsblk smartctl lscpu free lspci lsusb dmidecode sensors ip dd stress-ng hivexget memtester parted nvme; do
    need_cmd "$_t" || MISSING_TOOLS+=("$_t")
done

if need_cmd pacman; then
    PKG_CMD="pacman -Sy --noconfirm"
elif need_cmd apt-get; then
    PKG_CMD="apt-get install -y"
elif need_cmd dnf; then
    PKG_CMD="dnf install -y"
else
    PKG_CMD=""
fi

# ---------------------------------------------------------------------------
# UTILITAIRES HTML
# ---------------------------------------------------------------------------
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

status_label() {
    case "$1" in
        ok)   echo "OK"       ;;
        warn) echo "ATTENTION";;
        crit) echo "CRITIQUE" ;;
        *)    echo "INFO"     ;;
    esac
}

bump() {
    case "$1" in
        ok)   COUNT_OK+=1   ;;
        warn) COUNT_WARN+=1 ;;
        crit) COUNT_CRIT+=1 ;;
        *)    COUNT_INFO+=1 ;;
    esac
}

add_section() {
    local title="$1" status="$2" content="$3"
    bump "$status"
    cat >> "$REPORT_FILE" <<HTML
<div class="section">
  <div class="section-head status-${status}">
    <h2>${title}</h2>
    <span class="badge badge-${status}">$(status_label "$status")</span>
  </div>
  <div class="section-body">${content}</div>
</div>
HTML
}

kv_open()  { echo '<table class="kv">'; }
kv_close() { echo '</table>'; }
kv_row() {
    local k v
    k="$(printf '%s' "$1" | html_escape)"
    v="$(printf '%s' "$2" | html_escape)"
    printf '<tr><td class="k">%s</td><td class="v">%s</td></tr>\n' "$k" "$v"
}
note()      { printf '<p class="note">💡 %s</p>\n' "$1"; }
warn_note() { printf '<p class="warn-note">⚠️  %s</p>\n' "$1"; }

# Comparaison numérique (float-safe via awk)
num_gt()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }
num_lte() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0<=b+0)}'; }

# ---------------------------------------------------------------------------
# EN-TÊTE HTML
# ---------------------------------------------------------------------------
write_html_header() {
cat > "$REPORT_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Diagnostic PC — ${HOSTNAME_DIAG} — ${TIMESTAMP}</title>
<style>
/* ── Tokens light (défaut) ── */
:root {
  --ok:       #1a6b39;
  --warn:     #b05209;
  --crit:     #b91c1c;
  --info:     #1d4ed8;
  --bg:       #eef0f4;
  --surface:  #ffffff;
  --surfalt:  #f6f7f9;
  --border:   #dde0e6;
  --text:     #111827;
  --muted:    #6b7280;
  --code-bg:  #0d1117;
  --code-fg:  #c9d1d9;
}
/* ── Dark (préférence système) ── */
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg:      #0d1117;
    --surface: #161b22;
    --surfalt: #1c2128;
    --border:  #30363d;
    --text:    #e6edf3;
    --muted:   #8b949e;
    --ok:      #3fb950;
    --warn:    #e3b341;
    --crit:    #f85149;
    --info:    #58a6ff;
    --code-bg: #0a0d12;
    --code-fg: #c9d1d9;
  }
}
/* ── Dark (toggle explicite) ── */
:root[data-theme="dark"] {
  --bg:      #0d1117;
  --surface: #161b22;
  --surfalt: #1c2128;
  --border:  #30363d;
  --text:    #e6edf3;
  --muted:   #8b949e;
  --ok:      #3fb950;
  --warn:    #e3b341;
  --crit:    #f85149;
  --info:    #58a6ff;
  --code-bg: #0a0d12;
  --code-fg: #c9d1d9;
}

*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif;
     background:var(--bg);color:var(--text);font-size:14px;
     line-height:1.6;padding-bottom:64px}

/* Header */
header{background:#0d1117;color:#f0f6fc;padding:26px 40px;
       border-bottom:3px solid #238636}
.header-inner{max-width:960px;margin:0 auto;display:flex;
              justify-content:space-between;align-items:flex-end;
              gap:16px;flex-wrap:wrap}
header h1{font-size:21px;font-weight:700;letter-spacing:-.3px}
header .meta{font-size:12px;color:#8b949e;margin-top:3px}
.ver{font-size:11px;color:#3fb950;font-family:ui-monospace,monospace;
     background:rgba(63,185,80,.14);padding:3px 9px;border-radius:6px;
     letter-spacing:.04em}

/* Container */
.container{max-width:960px;margin:0 auto;padding:24px 20px}

/* Summary */
.summary{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;
         margin-bottom:28px}
.tile{background:var(--surface);border:1px solid var(--border);
      border-radius:10px;padding:18px 14px;text-align:center}
.tile .num{font-size:34px;font-weight:800;line-height:1;
           font-variant-numeric:tabular-nums}
.tile .lbl{font-size:10px;color:var(--muted);text-transform:uppercase;
           letter-spacing:.1em;margin-top:5px}
.tile.ok   .num{color:var(--ok)}
.tile.warn .num{color:var(--warn)}
.tile.crit .num{color:var(--crit)}
.tile.info .num{color:var(--info)}

/* Sections */
.section{background:var(--surface);border:1px solid var(--border);
         border-radius:10px;margin-bottom:12px;overflow:hidden}
.section-head{display:flex;justify-content:space-between;align-items:center;
              padding:12px 18px;background:var(--surfalt);
              border-left:4px solid var(--muted)}
.section-head h2{font-size:13.5px;font-weight:600}
.section-head.status-ok  {border-left-color:var(--ok)}
.section-head.status-warn{border-left-color:var(--warn)}
.section-head.status-crit{border-left-color:var(--crit)}
.section-head.status-info{border-left-color:var(--info)}
.section-body{padding:10px 18px 18px}

/* Badges */
.badge{font-size:10px;font-weight:700;padding:2px 8px;border-radius:999px;
       color:#fff;letter-spacing:.05em;white-space:nowrap}
.badge-ok  {background:var(--ok)}
.badge-warn{background:var(--warn)}
.badge-crit{background:var(--crit)}
.badge-info{background:var(--info)}

/* KV table */
table.kv{width:100%;border-collapse:collapse;margin:8px 0}
table.kv td{padding:5px 4px;border-bottom:1px solid var(--border);
            vertical-align:top}
table.kv tr:last-child td{border-bottom:none}
table.kv td.k{color:var(--muted);width:38%;font-size:13px}
table.kv td.v{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}

/* Sub-disk heading */
.disk-head{display:flex;align-items:center;gap:10px;
           margin:14px 0 6px;font-size:13px;font-weight:600}

/* Code */
pre{background:var(--code-bg);color:var(--code-fg);padding:12px 14px;
    border-radius:8px;overflow-x:auto;font-size:11.5px;
    line-height:1.55;margin:8px 0}

/* Notes */
p.note{background:rgba(29,78,216,.07);border-left:3px solid var(--info);
       padding:7px 11px;border-radius:0 6px 6px 0;
       margin:10px 0 4px;font-size:13px}
p.warn-note{background:rgba(176,82,9,.07);border-left:3px solid var(--warn);
            padding:7px 11px;border-radius:0 6px 6px 0;
            margin:10px 0 4px;font-size:13px}

/* Speed bar */
.speed-wrap{display:flex;align-items:center;gap:10px;margin:6px 0}
.speed-bg{flex:1;height:7px;background:var(--border);border-radius:4px;overflow:hidden}
.speed-fill{height:100%;border-radius:4px;background:var(--info)}
.speed-label{font-size:12px;font-family:monospace;color:var(--muted);
             min-width:90px;text-align:right}

/* Footer */
footer{text-align:center;color:var(--muted);font-size:11px;margin-top:32px}

/* Print */
@media print{
  body{background:#fff;color:#000}
  .section{box-shadow:none;border:1px solid #ccc;page-break-inside:avoid}
  header{background:#000;-webkit-print-color-adjust:exact;print-color-adjust:exact}
  pre{border:1px solid #ddd}
}
@media(max-width:600px){
  .summary{grid-template-columns:repeat(2,1fr)}
  header{padding:18px 16px}
  .container{padding:14px 10px}
}
</style>
</head>
<body>
<header>
  <div class="header-inner">
    <div>
      <h1>Rapport de diagnostic PC</h1>
      <div class="meta">Hôte : ${HOSTNAME_DIAG} &nbsp;·&nbsp; $(date '+%d/%m/%Y à %H:%M:%S')</div>
    </div>
    <span class="ver">PC-DIAG v${VERSION}</span>
  </div>
</header>
<div class="container">
HTMLEOF
}

write_html_footer() {
cat >> "$REPORT_FILE" <<HTML
  <footer>
    PC-DIAG v${VERSION} — 100% local · sans réseau · sans intelligence artificielle<br>
    Aucune donnée n'a quitté cette machine.
  </footer>
</div>
</body>
</html>
HTML
}

write_summary_block() {
cat <<HTML
<div class="summary">
  <div class="tile ok">  <div class="num">${COUNT_OK}</div>  <div class="lbl">OK</div></div>
  <div class="tile warn"><div class="num">${COUNT_WARN}</div><div class="lbl">Attention</div></div>
  <div class="tile crit"><div class="num">${COUNT_CRIT}</div><div class="lbl">Critique</div></div>
  <div class="tile info"><div class="num">${COUNT_INFO}</div><div class="lbl">Info</div></div>
</div>
HTML
}

# ---------------------------------------------------------------------------
# MODULE 1 — OUTILS DISPONIBLES
# ---------------------------------------------------------------------------
check_tools() {
    if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
        local list="${MISSING_TOOLS[*]}"
        list="${list// /, }"
        local pkg_note
        if [ -n "$PKG_CMD" ]; then
            pkg_note="$(note "Installer les outils manquants : <code>${PKG_CMD} smartmontools dmidecode lm_sensors ntfs-3g hivex</code>")"
        else
            pkg_note="$(note 'Gestionnaire de paquets non détecté — installer manuellement les outils manquants.')"
        fi
        add_section "Outils système" "warn" \
            "<p>Outils absents (tests concernés limités) : <code>${list}</code></p>
             ${pkg_note}"
    else
        add_section "Outils système" "ok" \
            "<p>Tous les outils de diagnostic sont disponibles.</p>"
    fi
}

# ---------------------------------------------------------------------------
# MODULE 2 — CARTE MÈRE & BIOS
# ---------------------------------------------------------------------------
check_motherboard() {
    if ! need_cmd dmidecode; then
        add_section "Carte mère & BIOS/UEFI" "info" \
            "<p><code>dmidecode</code> absent — informations carte mère non disponibles.</p>"
        return
    fi

    local mb_mfr mb_product mb_ver bios_vendor bios_ver bios_date uefi_mode status="ok"
    local sys_mfr sys_product sys_serial sys_uuid

    # Informations système (type 1 = System)
    sys_mfr="$(    dmidecode -t 1 2>/dev/null | awk -F: '/Manufacturer:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    sys_product="$(dmidecode -t 1 2>/dev/null | awk -F: '/Product Name:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    sys_serial="$( dmidecode -t 1 2>/dev/null | awk -F: '/Serial Number:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    sys_uuid="$(   dmidecode -t 1 2>/dev/null | awk -F: '/UUID:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"

    # Informations carte mère (type 2 = Base Board)
    mb_mfr="$(    dmidecode -t 2 2>/dev/null | awk -F: '/Manufacturer:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    mb_product="$(dmidecode -t 2 2>/dev/null | awk -F: '/Product Name:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    mb_ver="$(    dmidecode -t 2 2>/dev/null | awk -F: '/^[[:space:]]*Version:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    bios_vendor="$(dmidecode -t 0 2>/dev/null | awk -F: '/Vendor:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    bios_ver="$(  dmidecode -t 0 2>/dev/null | awk -F: '/Version:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    bios_date="$( dmidecode -t 0 2>/dev/null | awk -F: '/Release Date:/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"

    local secure_boot="non applicable (Legacy)"
    if [ -d /sys/firmware/efi ]; then
        local sb_val
        sb_val="$(cat /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | od -An -tu1 | awk '{print $NF}' | tail -1)"
        if [ "$sb_val" = "1" ]; then
            uefi_mode="UEFI — Secure Boot ACTIVÉ"
            secure_boot="Activé"
        else
            uefi_mode="UEFI — Secure Boot désactivé"
            secure_boot="Désactivé"
        fi
    else
        uefi_mode="Legacy BIOS (MBR)"
    fi

    local bios_year
    bios_year="$(echo "$bios_date" | grep -oE '[0-9]{4}' | tail -1)"
    if [ -n "$bios_year" ] && [ "$bios_year" -lt 2015 ]; then
        status="warn"
    fi

    local content
    content="$(kv_open)
    $(kv_row 'Fabricant système'      "${sys_mfr:-inconnu}")
    $(kv_row 'Modèle système'         "${sys_product:-inconnu}")
    $(kv_row 'Numéro de série'        "${sys_serial:-inconnu}")
    $(kv_row 'UUID machine'           "${sys_uuid:-inconnu}")
    $(kv_row 'Fabricant carte mère'   "${mb_mfr:-inconnu}")
    $(kv_row 'Modèle carte mère'      "${mb_product:-inconnu}")
    $(kv_row 'Révision carte mère'    "${mb_ver:-inconnu}")
    $(kv_row 'BIOS/UEFI — Éditeur'   "${bios_vendor:-inconnu}")
    $(kv_row 'BIOS/UEFI — Version'   "${bios_ver:-inconnu}")
    $(kv_row 'BIOS/UEFI — Date'      "${bios_date:-inconnue}")
    $(kv_row 'Mode démarrage'         "$uefi_mode")
    $(kv_row 'Secure Boot'            "$secure_boot")
    $(kv_close)"

    [ "$status" = "warn" ] && {
        content+="$(warn_note 'BIOS/UEFI antérieur à 2015 : mises à jour firmware probablement indisponibles, vulnérabilités connues non corrigées.')"
        add_reco "CONSEILLÉ" "BIOS/UEFI ancien (${bios_date:-date inconnue}) — vérifier les mises à jour disponibles sur le site du fabricant (${bios_vendor:-inconnu})"
    }

    add_section "Carte mère & BIOS/UEFI" "$status" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 3 — PROCESSEUR
# ---------------------------------------------------------------------------
check_cpu() {
    local model cores threads maxfreq temp status="ok"

    model="$(  lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    cores="$(  lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
    threads="$(nproc 2>/dev/null || echo '?')"
    maxfreq="$(lscpu 2>/dev/null | awk -F: '/CPU max MHz/{gsub(/^[ \t]+/,"",$2);printf "%.0f",$2;exit}')"
    [ -n "$maxfreq" ] && maxfreq="${maxfreq} MHz" || maxfreq="?"

    temp="non disponible"
    if need_cmd sensors; then
        # Initialisation silencieuse (évite un blocage)
        if need_cmd sensors-detect; then
            timeout 10 sensors-detect --auto >/dev/null 2>&1 || true
        fi
        local raw_temp
        raw_temp="$(sensors 2>/dev/null | grep -Ei 'Package id 0|Tctl|Tdie|CPU Temp|temp1' | \
                    grep -oE '[+-]?[0-9]+\.[0-9]+°C' | head -1)"
        [ -z "$raw_temp" ] && raw_temp="$(sensors 2>/dev/null | grep -oE '[+-]?[0-9]+\.[0-9]+°C' | head -1)"
        [ -n "$raw_temp" ] && temp="$raw_temp" || temp="non détecté (sensors-detect requis ?)"
    fi

    local temp_num
    temp_num="$(echo "$temp" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
    if [ -n "$temp_num" ]; then
        num_gt "$temp_num" "90" && status="crit"
        num_gt "$temp_num" "75" && num_lte "$temp_num" "90" && status="warn"
    fi

    local content
    content="$(kv_open)
    $(kv_row 'Modèle'            "${model:-inconnu}")
    $(kv_row 'Cœurs physiques'   "${cores:-?}")
    $(kv_row 'Threads logiques'  "${threads}")
    $(kv_row 'Fréquence max'     "$maxfreq")
    $(kv_row 'Température'       "$temp")
    $(kv_close)"

    [ "$status" = "crit" ] && {
        content+="$(warn_note 'Température critique (>90°C) : pasta thermique à renouveler, vérifier ventilateur et accumulation de poussière.')"
        add_reco "URGENT" "Température CPU critique (${temp}) — renouveler la pasta thermique et nettoyer le refroidissement immédiatement"
    }
    [ "$status" = "warn" ] && {
        content+="$(warn_note 'Température élevée (>75°C) : nettoyage conseillé.')"
        add_reco "IMPORTANT" "Température CPU élevée (${temp}) — nettoyage ventilateurs et renouvellement pasta thermique conseillé"
    }

    add_section "Processeur (CPU)" "$status" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 4 — MÉMOIRE VIVE
# ---------------------------------------------------------------------------
check_ram() {
    local total used avail total_mb status="ok" dimm_info=""

    total="$(  free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
    used="$(   free -h 2>/dev/null | awk '/^Mem:/{print $3}')"
    avail="$(  free -h 2>/dev/null | awk '/^Mem:/{print $7}')"
    total_mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"

    if [ -n "$total_mb" ]; then
        [ "$total_mb" -lt 1024 ] && status="crit"
        [ "$total_mb" -ge 1024 ] && [ "$total_mb" -lt 2048 ] && status="warn"
    fi

    if need_cmd dmidecode; then
        dimm_info="$(dmidecode -t 17 2>/dev/null | awk '
            /^\tSize:/ && $2!="No"   { size=$0; gsub(/^\t/,"",size) }
            /^\tSpeed:/ && $2!="Unknown" { speed=$0; gsub(/^\t/,"",speed) }
            /^\tManufacturer:/       { manuf=$0; gsub(/^\t/,"",manuf) }
            /^\tLocator:/ && !/Bank/ { loc=$0; gsub(/^\t/,"",loc) }
            /^\tPart Number:/        { part=$0; gsub(/^\t/,"",part) }
            /^$/ && size {
                printf "%s | %s | %s | %s\n", loc, size, speed, part
                size=""
            }' | sed '/^[[:space:]]*$/d')"
    fi

    local content
    content="$(kv_open)
    $(kv_row 'RAM totale'     "${total:-?}")
    $(kv_row 'RAM utilisée'   "${used:-?}")
    $(kv_row 'RAM disponible' "${avail:-?}")
    $(kv_close)"

    if [ -n "$dimm_info" ]; then
        content+="<p><strong>Barrettes mémoire :</strong></p><pre>$(echo "$dimm_info" | html_escape)</pre>"
    fi

    [ "$status" = "crit" ] && {
        content+="$(warn_note 'Mémoire insuffisante (<1 Go) : performances très dégradées pour tout usage moderne.')"
        add_reco "IMPORTANT" "RAM insuffisante (${total:-?}) — ajouter au minimum 4 Go pour un usage Windows 10/11 moderne"
    }
    [ "$status" = "warn" ] && {
        content+="$(warn_note 'Mémoire faible (<2 Go) : Windows 10/11 nécessite 4 Go minimum.')"
        add_reco "CONSEILLÉ" "RAM faible (${total:-?}) — extension à 4 Go minimum recommandée pour de meilleures performances"
    }
    content+="$(note 'Test intégrité bit à bit : lancer <code>memtest86+</code> depuis le menu Ventoy — prévoir plusieurs passes (20-60 min).')"

    add_section "Mémoire vive (RAM)" "$status" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 5 — TEST INTÉGRITÉ RAM (memtester rapide)
# ---------------------------------------------------------------------------
check_ram_test() {
    if ! need_cmd memtester; then
        add_section "Test intégrité RAM (rapide)" "info" \
            "<p><code>memtester</code> absent — test actif non disponible.</p>
             $(note 'Lancer <code>memtest86+</code> depuis le menu Ventoy pour un test complet (plusieurs passes, 20-60 min).')"
        return
    fi

    # Dynamic size: 25% of free RAM, between 64MB and 512MB
    local avail_mb test_mb
    avail_mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')"
    test_mb=$(( ${avail_mb:-256} / 4 ))
    [ "$test_mb" -lt 64  ] && test_mb=64
    [ "$test_mb" -gt 512 ] && test_mb=512

    local status="ok" content="" output="" errors=0
    printf "  [memtester] Test rapide %d Mo, 1 passe...\n" "$test_mb"

    output="$(memtester "${test_mb}M" 1 2>&1)" || true
    errors="$(echo "$output" | grep -c -E 'FAILURE|Error' 2>/dev/null)" || errors=0

    content="$(kv_open)
    $(kv_row 'Taille testée'     "${test_mb} Mo (25% RAM disponible)")
    $(kv_row 'Nombre de passes'  '1')
    $(kv_row 'Erreurs détectées' "${errors}")
    $(kv_close)"

    if [ "${errors}" -gt 0 ]; then
        status="crit"
        content+="<pre>$(echo "$output" | grep -E 'FAILURE|Error' | head -20 | html_escape)</pre>"
        content+="$(warn_note 'Erreurs mémoire détectées. Tester les barrettes une par une pour isoler la défaillante. NE PAS remettre en service sans remplacement.')"
        add_reco "URGENT" "Erreurs RAM détectées (${errors} erreur(s) sur ${test_mb} Mo) — tester chaque barrette individuellement, remplacer la défaillante avant remise en service"
    else
        content+="$(note 'Test rapide passé sans erreur. Pour une validation complète (toute la RAM, plusieurs passes) : lancer memtest86+ depuis Ventoy.')"
    fi

    add_section "Test intégrité RAM (rapide)" "$status" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 6 — DISQUES (SMART + VITESSE)
# ---------------------------------------------------------------------------
check_disks() {
    local overall_status="ok" content=""

    # Exclusion des pseudo-disques (zram, loop, dm, md, ram)
    local disks
    disks="$(lsblk -dno NAME,TYPE 2>/dev/null | \
             awk '$2=="disk" && $1 !~ /^(zram|loop|ram[0-9]|dm-|md[0-9])/{print $1}')"

    if [ -z "$disks" ]; then
        add_section "Disques de stockage" "warn" \
            "<p>Aucun disque physique détecté par lsblk.</p>"
        return
    fi

    for d in $disks; do
        local dev="/dev/$d"
        local model size rotation type_label disk_status="info"
        local health="Non vérifié" smart_block="" speed_block="" disk_temp="" poh_display=""

        model="$(    lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/ *$//')"
        size="$(     lsblk -dno SIZE  "$dev" 2>/dev/null)"
        rotation="$( lsblk -dno ROTA  "$dev" 2>/dev/null)"
        local tran
        tran="$(     lsblk -dno TRAN  "$dev" 2>/dev/null)"

        if [ "$tran" = "usb" ]; then
            type_label="Clé/Disque USB"
        elif [ "$rotation" = "1" ]; then
            type_label="HDD (mécanique)"
        elif [ "$rotation" = "0" ]; then
            echo "$d" | grep -qi 'nvme' && type_label="NVMe SSD" || type_label="SATA SSD"
        else
            type_label="Inconnu"
        fi

        # SMART
        if need_cmd smartctl; then
            local smart_extra=""
            echo "$d" | grep -qi 'nvme' && smart_extra="--device=nvme"

            if smartctl -H $smart_extra "$dev" >/dev/null 2>&1; then
                local smart_h
                smart_h="$(smartctl -H $smart_extra "$dev" 2>/dev/null)"

                if echo "$smart_h" | grep -qi "PASSED\|OK"; then
                    health="PASSED ✓"
                    disk_status="ok"

                    # Secteurs réalloués
                    local realloc
                    realloc="$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                               awk '/Reallocated_Sector_Ct|Reallocated_Event_Count/{print $NF;exit}')"
                    if [ -n "$realloc" ] && [ "$realloc" -gt 0 ]; then
                        health="PASSED — ${realloc} secteur(s) réalloué(s)"
                        disk_status="warn"
                        add_reco "IMPORTANT" "${dev} — ${realloc} secteur(s) réalloué(s) : disque en fin de vie, sauvegarder les données et planifier le remplacement"
                    fi

                    # Secteurs en attente de réallocation (indicateur précoce de défaillance)
                    local pending
                    pending="$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                               awk '/Current_Pending_Sector/{print $NF;exit}')"
                    if [ -n "$pending" ] && [ "$pending" -gt 0 ]; then
                        health="${health} / ${pending} secteur(s) en attente"
                        [ "$disk_status" = "ok" ] && disk_status="warn"
                        add_reco "IMPORTANT" "${dev} — ${pending} secteur(s) en attente de réallocation : signe précoce de défaillance, sauvegarder les données immédiatement"
                    fi

                    # Power On Hours → age estimation (SATA/HDD)
                    local poh
                    poh="$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                           awk '/Power_On_Hours/{print $10; exit}')"
                    poh="${poh//[^0-9]/}"
                    if [ -n "$poh" ] && [ "$poh" -gt 0 ]; then
                        local poh_y poh_d
                        poh_y=$(( poh / 8760 ))
                        poh_d=$(( (poh % 8760) / 24 ))
                        poh_display="${poh}h (~${poh_y} an(s) et ${poh_d} jour(s))"
                        [ "$poh" -gt 35040 ] && {
                            [ "$disk_status" = "ok" ] && disk_status="warn"
                            add_reco "CONSEILLÉ" "${dev} — ${poh_y} ans de fonctionnement (${poh}h) : disque vieillissant, surveiller de près et planifier remplacement"
                        }
                    fi
                elif echo "$smart_h" | grep -qi "FAILED"; then
                    health="FAILED ✗ — REMPLACEMENT URGENT"
                    disk_status="crit"
                    add_reco "URGENT" "${dev} — SMART FAILED : disque défaillant, remplacer immédiatement avant perte de données"
                fi

                # Température disque (attribut SATA ou ligne NVMe)
                disk_temp="$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                             awk '/Temperature_Celsius|Airflow_Temperature_Cel/{print $10; exit}')"
                [ -z "$disk_temp" ] && disk_temp="$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                             awk '/^Temperature:/{print $2; exit}')"
                if [ -n "$disk_temp" ]; then
                    # HDD seuil 55°C, SSD/NVMe seuil 70°C
                    local temp_thresh=55
                    echo "$type_label" | grep -qi 'ssd\|nvme' && temp_thresh=70
                    if [ "$disk_temp" -gt "$temp_thresh" ] 2>/dev/null; then
                        [ "$disk_status" = "ok" ] && disk_status="warn"
                        add_reco "IMPORTANT" "${dev} — température disque élevée (${disk_temp}°C, seuil ${temp_thresh}°C) : vérifier ventilation du boîtier"
                    fi
                fi

                # NVMe : spare + usure en plus des attributs classiques
                if echo "$d" | grep -qi 'nvme'; then
                    local nvme_spare nvme_used
                    nvme_spare="$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                                  awk '/Available Spare:/{gsub(/%/,"",$3);print $3;exit}')"
                    nvme_used="$( smartctl -A $smart_extra "$dev" 2>/dev/null | \
                                  awk '/Percentage Used:/{gsub(/%/,"",$3);print $3;exit}')"
                    nvme_spare="${nvme_spare//[^0-9]/}"
                    nvme_used="${nvme_used//[^0-9]/}"
                    if [ -n "$nvme_spare" ] && [ "$nvme_spare" -lt 10 ]; then
                        health="CRITIQUE — spare réservé <10% (${nvme_spare}%)"
                        disk_status="crit"
                        add_reco "URGENT" "${dev} NVMe — spare réservé critique (${nvme_spare}%) : SSD en fin de vie, remplacer immédiatement"
                    elif [ -n "$nvme_used" ] && [ "$nvme_used" -gt 90 ]; then
                        health="ATTENTION — usure ${nvme_used}%"
                        [ "$disk_status" = "ok" ] && disk_status="warn"
                        add_reco "IMPORTANT" "${dev} NVMe — usure ${nvme_used}% : prévoir remplacement à moyen terme"
                    fi

                    # Power On Hours NVMe → age estimation
                    local nvme_poh
                    nvme_poh="$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                                awk '/Power On Hours:/{print $4; exit}')"
                    nvme_poh="${nvme_poh//[^0-9]/}"
                    if [ -n "$nvme_poh" ] && [ "$nvme_poh" -gt 0 ]; then
                        local nvme_poh_y nvme_poh_d
                        nvme_poh_y=$(( nvme_poh / 8760 ))
                        nvme_poh_d=$(( (nvme_poh % 8760) / 24 ))
                        poh_display="${nvme_poh}h (~${nvme_poh_y} an(s) et ${nvme_poh_d} jour(s))"
                    fi
                    smart_block="<pre>$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                        grep -E 'Temperature:|Available Spare:|Percentage Used:|Data Units Written:|Power On Hours:|Unsafe Shutdowns:' | \
                        head -12 | html_escape)</pre>"
                else
                    smart_block="<pre>$(smartctl -A $smart_extra "$dev" 2>/dev/null | \
                        grep -E 'Reallocated|Pending|Uncorrect|Power_On|Wear_Level|Media_Wearout|Temperature|Load_Cycle|Data_Read|Runtime_Bad' | \
                        head -15 | html_escape)</pre>"
                fi
            else
                # smartctl failed — try nvme-cli fallback + detect Intel VMD
                local vmd_active=0
                if [ "$tran" != "usb" ]; then
                    lsmod 2>/dev/null | grep -qi '^vmd ' && vmd_active=1
                    lspci  2>/dev/null | grep -qi 'volume management device\|VMD' && vmd_active=1
                fi

                if [ "$tran" = "usb" ]; then
                    health="Non interrogeable — périphérique USB"
                    disk_status="info"
                elif echo "$d" | grep -qi 'nvme' && need_cmd nvme; then
                    local nvme_smart
                    nvme_smart="$(nvme smart-log "$dev" 2>/dev/null)"

                    if [ -n "$nvme_smart" ]; then
                        # Parse nvme smart-log output
                        local nvme_spare nvme_used nvme_temp_raw nvme_poh
                        nvme_spare="$(   echo "$nvme_smart" | awk -F'[: %]+' '/avail_spare[^_]/{gsub(/[^0-9]/,"",$2);print $2+0;exit}')"
                        nvme_used="$(    echo "$nvme_smart" | awk -F'[: %]+' '/percent_used/{gsub(/[^0-9]/,"",$2);print $2+0;exit}')"
                        nvme_temp_raw="$(echo "$nvme_smart" | awk '/temperature/{match($0,/[0-9]+/);if(RSTART)print substr($0,RSTART,RLENGTH);exit}')"
                        nvme_poh="$(     echo "$nvme_smart" | awk -F'[: ,]+' '/power_on_hours/{gsub(/[^0-9]/,"",$2);print $2+0;exit}')"

                        # Health assessment
                        if [ -n "$nvme_spare" ] && [ "$nvme_spare" -lt 10 ] 2>/dev/null; then
                            health="CRITIQUE — spare réservé <10% (${nvme_spare}%)"
                            disk_status="crit"
                            add_reco "URGENT" "${dev} NVMe — spare réservé critique (${nvme_spare}%) : SSD en fin de vie, remplacer immédiatement"
                        elif [ -n "$nvme_used" ] && [ "$nvme_used" -gt 90 ] 2>/dev/null; then
                            health="ATTENTION — usure ${nvme_used}%"
                            disk_status="warn"
                            add_reco "IMPORTANT" "${dev} NVMe — usure ${nvme_used}% : prévoir remplacement à moyen terme"
                        else
                            health="PASSED ✓ (via nvme-cli)"
                            disk_status="ok"
                        fi
                        [ "$vmd_active" = "1" ] && health="${health} — Intel VMD détecté"

                        # Power On Hours
                        if [ -n "$nvme_poh" ] && [ "$nvme_poh" -gt 0 ] 2>/dev/null; then
                            local nvme_poh_y nvme_poh_d
                            nvme_poh_y=$(( nvme_poh / 8760 ))
                            nvme_poh_d=$(( (nvme_poh % 8760) / 24 ))
                            poh_display="${nvme_poh}h (~${nvme_poh_y} an(s) et ${nvme_poh_d} jour(s))"
                        fi
                        [ -n "$nvme_temp_raw" ] && disk_temp="$nvme_temp_raw"

                        smart_block="<pre>$(echo "$nvme_smart" | \
                            grep -Ei 'temperature|avail_spare|percent_used|data_units_written|power_on_hours|unsafe_shutdowns|media_errors' | \
                            head -12 | html_escape)</pre>"
                    else
                        # nvme-cli present but failed too
                        health="Non interrogeable (contrôleur RAID/VMD, USB ou VM)"
                        disk_status="warn"
                        [ "$vmd_active" = "1" ] && {
                            health="Non interrogeable — Intel VMD actif"
                            add_reco "CONSEILLÉ" "${dev} NVMe — Intel VMD/RST actif : SMART inaccessible via smartctl et nvme-cli. Pour activer le SMART : BIOS → SATA Operation → passer de 'RAID On' à 'AHCI' (attention : peut nécessiter réinstallation de Windows)"
                        }
                    fi
                else
                    health="Non interrogeable (contrôleur RAID, USB ou VM)"
                    disk_status="warn"
                    [ "$vmd_active" = "1" ] && {
                        health="Non interrogeable — Intel VMD actif (installer nvme-cli pour tenter l'accès SMART)"
                        add_reco "CONSEILLÉ" "${dev} NVMe — Intel VMD/RST actif : installer nvme-cli (pacman -Sy nvme-cli) pour tenter la lecture SMART malgré le VMD"
                    }
                fi
            fi
        else
            health="smartctl absent — santé non vérifiable"
            disk_status="warn"
        fi

        # Vitesse de lecture séquentielle (safe: read-only, limité à 512 Mo)
        if need_cmd dd; then
            local dd_out speed_str=""
            dd_out="$(timeout 60 dd if="$dev" of=/dev/null bs=4M count=128 iflag=direct 2>&1)" || true
            speed_str="$(echo "$dd_out" | grep -oE '[0-9]+(\.[0-9]+)? (MB|GB)/s' | head -1)"

            if [ -n "$speed_str" ]; then
                # Référence réaliste par type : HDD≈150, SATA SSD≈550, NVMe≈3500
                local max_ref=550
                echo "$type_label" | grep -qi 'nvme'            && max_ref=3500
                echo "$type_label" | grep -qi 'hdd\|mécanique'  && max_ref=150
                local speed_num pct
                speed_num="$(echo "$speed_str" | grep -oE '^[0-9]+(\.[0-9]+)?')"
                # Convertir GB/s en MB/s si nécessaire
                echo "$speed_str" | grep -qi 'GB/s' && \
                    speed_num="$(awk -v s="$speed_num" 'BEGIN{printf "%.0f",s*1000}')"
                pct="$(awk -v s="$speed_num" -v m="$max_ref" \
                    'BEGIN{v=int(s/m*100);print (v>100?100:v)}')"
                speed_block="<div class='speed-wrap'>
                  <span style='font-size:12px;color:var(--muted);min-width:130px'>Vitesse lecture seq. :</span>
                  <div class='speed-bg'><div class='speed-fill' style='width:${pct}%'></div></div>
                  <span class='speed-label'>${speed_str}</span>
                </div>"
                # HDD lent = signe de défaillance ou fin de vie
                if echo "$type_label" | grep -qi 'hdd\|mécanique'; then
                    if [ "$(echo "$speed_num" | awk '{print ($1<60)}')" = "1" ] 2>/dev/null; then
                        add_reco "CONSEILLÉ" "${dev} HDD — vitesse lecture faible (${speed_str}) : disque mécanique très lent, vérifier santé SMART, envisager remplacement par SSD"
                    fi
                fi
            fi
        fi

        [ "$disk_status" = "crit" ] && overall_status="crit"
        [ "$disk_status" = "warn" ] && [ "$overall_status" != "crit" ] && overall_status="warn"

        content+="<div class='disk-head'>${dev} — ${model:-modèle inconnu}
                    <span class='badge badge-${disk_status}'>$(status_label "$disk_status")</span></div>
                  $(kv_open)
                  $(kv_row 'Taille'                  "${size:-?}")
                  $(kv_row 'Type'                    "$type_label")
                  $(kv_row 'Santé SMART'             "$health")
                  $(kv_row 'Température'             "$(_fmtval "$disk_temp" '°C' 'non disponible')")
                  ${poh_display:+$(kv_row 'Heures de fonctionnement' "$poh_display")}
                  $(kv_close)
                  ${speed_block}${smart_block}"
    done

    content+="$(warn_note 'Secteurs réalloués > 0 ou statut FAILED = disque à remplacer en priorité. Sauvegarder les données avant toute manipulation.')"

    add_section "Disques de stockage (SMART + vitesse)" "$overall_status" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 6 — CARTE GRAPHIQUE
# ---------------------------------------------------------------------------
check_gpu() {
    local gpu_info="" gpu_temp="" driver_info="" content rows=""

    # Détection GPU via lspci
    if need_cmd lspci; then
        gpu_info="$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display controller' | \
                    sed 's/^[0-9a-f:.]* //')"
    fi

    # Driver(s) kernel chargé(s)
    if need_cmd lsmod; then
        driver_info="$(lsmod 2>/dev/null | awk '{print $1}' | \
                       grep -E '^(nvidia|amdgpu|i915|nouveau|radeon)$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    fi

    # Température via sensors (AMD edge/junction, générique GPU)
    if need_cmd sensors; then
        gpu_temp="$(sensors 2>/dev/null | grep -Ei 'GPU|edge|junction' | \
                    grep -oE '[+-]?[0-9]+\.[0-9]+°C' | head -1)"
    fi

    # Fréquence courante GPU Intel intégré (sysfs)
    local intel_freq=""
    for _f in /sys/class/drm/card*/gt_cur_freq_mhz; do
        [ -f "$_f" ] || continue
        intel_freq="$(cat "$_f" 2>/dev/null) MHz"
        break
    done

    # --- Construction du contenu ---
    if [ -z "$gpu_info" ]; then
        content="<p>Aucun GPU détecté via lspci (outil absent, GPU intégré non listé, ou VM).</p>"
    else
        content="<pre>$(echo "$gpu_info" | html_escape)</pre>"

        rows=""
        [ -n "$driver_info" ] && rows+="$(kv_row 'Driver(s) chargé(s)' "$driver_info")"
        [ -n "$gpu_temp"    ] && rows+="$(kv_row 'Température'          "$gpu_temp")"
        [ -n "$intel_freq"  ] && rows+="$(kv_row 'Fréq. Intel GPU'      "$intel_freq")"
        [ -n "$rows"        ] && content+="$(kv_open)${rows}$(kv_close)"
    fi

    # NVIDIA — nvidia-smi (température précise, VRAM, driver, utilisation)
    if need_cmd nvidia-smi; then
        local nv_raw
        nv_raw="$(nvidia-smi \
                    --query-gpu=name,driver_version,temperature.gpu,memory.used,memory.total,utilization.gpu \
                    --format=csv,noheader,nounits 2>/dev/null)" || true
        if [ -n "$nv_raw" ]; then
            content+="<p><strong>NVIDIA — nvidia-smi :</strong></p>"
            content+='<table class="kv"><tr>'
            content+='<th>GPU</th><th>Driver</th><th>Temp.</th><th>VRAM utilisée</th><th>VRAM totale</th><th>Charge</th>'
            content+='</tr>'
            while IFS=',' read -r _name _drv _temp _mu _mt _util; do
                _name="$(echo "$_name" | xargs)"
                _drv="$( echo "$_drv"  | xargs)"
                _temp="$(echo "$_temp" | xargs)"
                _mu="$(  echo "$_mu"   | xargs)"
                _mt="$(  echo "$_mt"   | xargs)"
                _util="$(echo "$_util" | xargs)"
                content+="<tr>"
                content+="<td>$(printf '%s' "$_name" | html_escape)</td>"
                content+="<td>${_drv}</td>"
                content+="<td>${_temp} °C</td>"
                content+="<td>${_mu} MiB</td>"
                content+="<td>${_mt} MiB</td>"
                content+="<td>${_util} %</td>"
                content+="</tr>"
            done <<< "$nv_raw"
            content+="</table>"
        fi
    fi

    add_section "Carte graphique (GPU)" "info" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 7 — STRESS-TEST CPU
# ---------------------------------------------------------------------------
check_stress_cpu() {
    local duration=30 content="" status="ok"

    # Helper : lit la température CPU (sensors > /sys/thermal)
    _cpu_temp() {
        local t=""
        if need_cmd sensors; then
            t="$(sensors 2>/dev/null | \
                 grep -Ei 'Package id 0|Tctl|Tdie|CPU Temp|temp1' | \
                 grep -oE '[+-]?[0-9]+\.[0-9]+' | head -1)"
        fi
        if [ -z "$t" ] && [ -f /sys/class/thermal/thermal_zone0/temp ]; then
            t="$(awk '{printf "%.1f",$1/1000}' \
                 /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
        fi
        echo "$t"
    }

    local temp_before
    temp_before="$(_cpu_temp)"

    if [ -z "$temp_before" ]; then
        add_section "Stress-test CPU" "info" \
            "<p>Aucun capteur thermique accessible — test d'échauffement non réalisable
             (<code>sensors</code> ou <code>/sys/class/thermal</code> requis).</p>"
        return
    fi

    printf "  [stress] Temp. initiale : %s°C — lancement %ds sur %d thread(s)...\n" \
           "$temp_before" "$duration" "$(nproc)"

    # Lancement du générateur de charge (PIDs stockés globalement pour trap EXIT)
    _STRESS_PIDS=()
    local stress_method=""
    if need_cmd stress-ng; then
        stress_method="stress-ng"
        stress-ng --cpu "$(nproc)" --timeout "${duration}s" --quiet &
        _STRESS_PIDS=($!)
    elif need_cmd stress; then
        stress_method="stress"
        stress --cpu "$(nproc)" --timeout "${duration}s" &
        _STRESS_PIDS=($!)
    else
        stress_method="yes (fallback natif — stress-ng absent)"
        local _i
        for _i in $(seq 1 "$(nproc)"); do
            nice -n 19 yes > /dev/null &
            _STRESS_PIDS+=($!)
        done
    fi

    # Monitoring pendant la durée du test
    local temp_max="$temp_before"
    local elapsed=0
    while [ "$elapsed" -lt "$duration" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        local t_now
        t_now="$(_cpu_temp)"
        if [ -n "$t_now" ]; then
            num_gt "$t_now" "${temp_max:-0}" && temp_max="$t_now"
            printf "  [stress] %02ds — %s°C  (max : %s°C)\n" \
                   "$elapsed" "$t_now" "$temp_max"
        fi
    done

    # Arrêt propre via les PIDs globaux
    for _pid in "${_STRESS_PIDS[@]}"; do
        kill "$_pid" 2>/dev/null || true
    done
    wait "${_STRESS_PIDS[@]}" 2>/dev/null || true
    _STRESS_PIDS=()  # Nettoyé : le trap EXIT n'a plus rien à faire

    sleep 3
    local temp_after
    temp_after="$(_cpu_temp)"

    local delta=""
    [ -n "$temp_before" ] && [ -n "$temp_max" ] && \
        delta="$(awk -v b="$temp_before" -v m="$temp_max" \
                 'BEGIN{printf "%.1f",m-b}')"

    # Statut selon température maximale atteinte
    num_gt "${temp_max:-0}" "90" && status="crit"
    num_gt "${temp_max:-0}" "75" && num_lte "${temp_max:-0}" "90" && status="warn"

    # Détection throttling (fréquence en fin de charge)
    local throttle_line="non disponible"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        local max_f cur_f throttle_pct
        max_f="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
        cur_f="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)"
        if [ -n "$max_f" ] && [ -n "$cur_f" ] && [ "$max_f" -gt 0 ]; then
            throttle_pct="$(awk -v c="$cur_f" -v m="$max_f" \
                            'BEGIN{printf "%.0f",(c/m)*100}')"
            throttle_line="$(awk -v f="$cur_f" \
                             'BEGIN{printf "%.0f MHz",f/1000}') (${throttle_pct}% du max)"
            if [ "$throttle_pct" -lt 75 ]; then
                throttle_line="${throttle_line} — THROTTLING DÉTECTÉ"
                [ "$status" != "crit" ] && status="warn"
            fi
        fi
    fi

    content="$(kv_open)
    $(kv_row 'Méthode stress'        "$stress_method")
    $(kv_row 'Durée / Threads'       "${duration}s sur $(nproc) thread(s)")
    $(kv_row 'Température initiale'  "${temp_before}°C")
    $(kv_row 'Température maximale'  "$(_fmtval "$temp_max" '°C' '?')")
    $(kv_row 'Température post-test' "$(_fmtval "$temp_after" '°C' '?')")
    $(kv_row 'Delta (repos → max)'   "$(_fmtval "$delta" '°C' '?')")
    $(kv_row 'Fréquence fin de test' "$throttle_line")
    $(kv_close)"

    case "$status" in
        crit)
            content+="$(warn_note 'Température critique (>90°C) sous charge : pasta thermique défaillante ou refroidissement insuffisant — à traiter avant remise en service.')"
            add_reco "URGENT" "Température critique sous charge (${temp_max}°C max) — renouveler la pasta thermique, nettoyer le refroidissement avant remise en service"
            ;;
        warn)
            content+="$(warn_note 'Température élevée (>75°C) ou throttling détecté (<75% fréquence max) : nettoyage et remplacement pasta thermique conseillés.')"
            add_reco "IMPORTANT" "Température élevée ou throttling sous charge (${temp_max}°C max) — nettoyage ventilateurs et pasta thermique conseillés"
            ;;
        ok)
            content+="$(note 'Comportement thermique correct sous charge totale — refroidissement en bon état.')"
            ;;
    esac

    add_section "Stress-test CPU (${duration}s charge totale)" "$status" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 8 — BATTERIE
# ---------------------------------------------------------------------------
check_battery() {
    local bat_path status="info"
    bat_path="$(find /sys/class/power_supply -maxdepth 1 -iname 'BAT*' 2>/dev/null | sort | head -1)"

    if [ -z "$bat_path" ]; then
        add_section "Batterie" "info" \
            "<p>Aucune batterie détectée (ordinateur fixe ou capteur non exposé).</p>"
        return
    fi

    local ef efd cycle cap_pct charge_status wear_pct=""

    ef="$(         cat "$bat_path/energy_full"        2>/dev/null || \
                   cat "$bat_path/charge_full"         2>/dev/null)"
    efd="$(        cat "$bat_path/energy_full_design"  2>/dev/null || \
                   cat "$bat_path/charge_full_design"   2>/dev/null)"
    cycle="$(      cat "$bat_path/cycle_count"         2>/dev/null)"
    cap_pct="$(    cat "$bat_path/capacity"            2>/dev/null)"
    charge_status="$(cat "$bat_path/status"            2>/dev/null)"

    if [ -n "$ef" ] && [ -n "$efd" ] && [ "$efd" -gt 0 ]; then
        wear_pct="$(awk -v f="$ef" -v d="$efd" 'BEGIN{printf "%.1f",(1-(f/d))*100}')"
        num_gt "$wear_pct" "40" && status="crit"
        num_gt "$wear_pct" "20" && num_lte "$wear_pct" "40" && status="warn"
        num_lte "$wear_pct" "20" && status="ok"
    fi

    # Conversion µWh → Wh
    local ef_wh efd_wh
    ef_wh="$( awk -v v="${ef:-0}"  'BEGIN{printf "%.1f Wh",v/1000000}' 2>/dev/null)"
    efd_wh="$(awk -v v="${efd:-0}" 'BEGIN{printf "%.1f Wh",v/1000000}' 2>/dev/null)"

    local content
    content="$(kv_open)
    $(kv_row 'État'                    "${charge_status:-inconnu}")
    $(kv_row 'Charge actuelle'         "${cap_pct:-?}%")
    $(kv_row 'Capacité pleine (actuelle)' "$ef_wh")
    $(kv_row "Capacité pleine (origine)"  "$efd_wh")
    $(kv_row 'Usure estimée'           "$(_fmtval "$wear_pct" '%' 'inconnue')")
    $(kv_row 'Cycles de charge'        "${cycle:-inconnu}")
    $(kv_close)"

    [ "$status" = "crit" ] && {
        content+="$(warn_note 'Usure > 40% : autonomie fortement dégradée, remplacement conseillé.')"
        add_reco "IMPORTANT" "Batterie très usée (${wear_pct}% d'usure) — autonomie fortement dégradée, remplacement conseillé"
    }
    [ "$status" = "warn" ] && {
        content+="$(warn_note 'Usure > 20% : autonomie réduite, à surveiller.')"
        add_reco "CONSEILLÉ" "Batterie usée (${wear_pct}% d'usure) — autonomie réduite, à surveiller"
    }

    add_section "Batterie" "$status" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 8 — RÉSEAU, BLUETOOTH, USB
# ---------------------------------------------------------------------------
check_peripherals() {
    local net_info="" wifi_info="" bt_info="" usb_info="" content

    need_cmd ip    && net_info="$( ip -brief link show 2>/dev/null)"
    need_cmd lspci && wifi_info="$(lspci 2>/dev/null | grep -Ei 'wireless|wi-fi|wifi|network|ethernet' | sed 's/^[0-9a-f:.]* //')"
    need_cmd lspci && bt_info="$( lspci 2>/dev/null | grep -i bluetooth)"
    need_cmd lsusb && {
        usb_info="$(lsusb 2>/dev/null)"
        [ -z "$bt_info" ] && bt_info="$(lsusb 2>/dev/null | grep -i bluetooth)"
    }
    [ -z "$bt_info" ] && bt_info="Aucun contrôleur Bluetooth détecté"

    content="<p><strong>Interfaces réseau :</strong></p>
    <pre>$([ -n "$net_info" ] && echo "$net_info" | html_escape || echo "aucune")</pre>
    <p><strong>Wi-Fi / Ethernet (PCI) :</strong></p>
    <pre>$([ -n "$wifi_info" ] && echo "$wifi_info" | html_escape || echo "non détecté ou lspci absent")</pre>
    <p><strong>Bluetooth :</strong></p>
    <pre>$(echo "$bt_info" | html_escape)</pre>
    <p><strong>Périphériques USB :</strong></p>
    <pre>$([ -n "$usb_info" ] && echo "$usb_info" | html_escape || echo "aucun ou lsusb absent")</pre>"

    add_section "Réseau, Bluetooth & USB" "info" "$content"
}

# ---------------------------------------------------------------------------
# MODULE 11 — TABLE DES PARTITIONS
# ---------------------------------------------------------------------------
check_partitions() {
    local content="" ptable=""

    if need_cmd parted; then
        ptable="$(parted -l 2>/dev/null)"
    elif need_cmd fdisk; then
        ptable="$(fdisk -l 2>/dev/null)"
    fi

    if [ -z "$ptable" ]; then
        content="<p>Outils absents (<code>parted</code> ou <code>fdisk</code>) — table des partitions non lisible.</p>"
    else
        content="<pre>$(echo "$ptable" | html_escape)</pre>"
    fi

    add_section "Table des partitions" "info" "$content"
}

# ---------------------------------------------------------------------------
# ANALYSE OS — WINDOWS
# ---------------------------------------------------------------------------
analyze_windows() {
    local mp="$1" dev="$2" status="ok" content="" usage_pct

    usage_pct="$(df -h "$mp" 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')"
    if [ -n "$usage_pct" ]; then
        if [ "$usage_pct" -ge 90 ]; then
            status="crit"
            add_reco "URGENT" "Disque Windows (${dev}) presque plein (${usage_pct}%) — nettoyer les fichiers temporaires, Windows.old et le cache Windows Update"
        elif [ "$usage_pct" -ge 75 ]; then
            status="warn"
            add_reco "IMPORTANT" "Disque Windows (${dev}) rempli à ${usage_pct}% — libérer de l'espace (fichiers temp, corbeille, cache)"
        fi
    fi

    content="$(kv_open)
    $(kv_row 'Partition'         "$dev")
    $(kv_row 'Occupation disque' "${usage_pct:-?}%")
    $(kv_close)"

    # Lecture registre Windows hors-ligne via hivex
    local hive_soft="$mp/Windows/System32/config/SOFTWARE"
    local hive_sys="$mp/Windows/System32/config/SYSTEM"

    if [ -f "$hive_soft" ]; then
        local ver="" build="" ubr="" owner="" install_ts="" install_date=""
        local defender_status="inconnu" bl_status="inconnu"
        local nt_path="Microsoft\\Windows NT\\CurrentVersion"

        if need_cmd hivexget; then
            # hivexget : lecture directe d'une valeur (API la plus simple)
            ver="$(          hivexget "$hive_soft" "$nt_path" ProductName      2>/dev/null | tr -d '"')"
            build="$(        hivexget "$hive_soft" "$nt_path" CurrentBuild     2>/dev/null | tr -d '"')"
            ubr="$(          hivexget "$hive_soft" "$nt_path" UBR              2>/dev/null)"
            owner="$(        hivexget "$hive_soft" "$nt_path" RegisteredOwner  2>/dev/null | tr -d '"')"
            install_ts="$(   hivexget "$hive_soft" "$nt_path" InstallDate      2>/dev/null)"
            [ -n "$install_ts" ] && \
                install_date="$(date -d "@$install_ts" '+%d/%m/%Y' 2>/dev/null)"

            # Windows Defender + BitLocker (ruche SYSTEM)
            if [ -f "$hive_sys" ]; then
                # Résolution dynamique du ControlSet actif (évite le bug ControlSet001 codé en dur)
                local cs_num cs_path
                cs_num="$(hivexget "$hive_sys" 'Select' Current 2>/dev/null)"
                if [ -n "$cs_num" ] && [ "$cs_num" -gt 0 ] 2>/dev/null; then
                    cs_path="$(printf 'ControlSet%03d\\Services' "$cs_num")"
                else
                    cs_path="ControlSet001\\Services"
                fi

                local def_start
                def_start="$(hivexget "$hive_sys" "${cs_path}\\WinDefend" Start 2>/dev/null)"
                case "$def_start" in
                    2) defender_status="Activé (démarrage automatique)" ;;
                    3) defender_status="Manuel (potentiellement désactivé)" ;;
                    4) defender_status="Désactivé" ;;
                    *) defender_status="Inconnu (clé non trouvée)" ;;
                esac

                # BitLocker (service BDESVC)
                local bde_start
                bde_start="$(hivexget "$hive_sys" "${cs_path}\\BDESVC" Start 2>/dev/null)"
                case "$bde_start" in
                    2) bl_status="Service actif (auto) — chiffrement probable" ;;
                    3) bl_status="Service manuel" ;;
                    4) bl_status="Service désactivé" ;;
                    *) bl_status="Non installé ou clé absente" ;;
                esac
            fi

        elif need_cmd hivexregedit; then
            # Fallback : export de la clé complète
            local _hx_dump
            _hx_dump="$(hivexregedit --export "$hive_soft" \
                         'Microsoft\Windows NT\CurrentVersion' 2>/dev/null)"
            ver="$(   echo "$_hx_dump" | grep -i 'ProductName'   | sed 's/.*= "//;s/".*//' | head -1)"
            build="$( echo "$_hx_dump" | grep -i 'CurrentBuild'  | sed 's/.*= "//;s/".*//' | head -1)"
            ubr="$(   echo "$_hx_dump" | grep -i '^"UBR"'        | grep -oE '[0-9]+$'       | head -1)"
            owner="$( echo "$_hx_dump" | grep -i 'RegisteredOwner' | sed 's/.*= "//;s/".*//' | head -1)"
        fi

        if [ -n "$ver" ]; then
            content+="$(kv_open)
            $(kv_row 'Version Windows'     "$ver")
            $(kv_row 'Build'               "${build:-?}${ubr:+.${ubr}}")
            $(kv_row 'Propriétaire'        "${owner:-inconnu}")
            $(kv_row 'Date installation'   "${install_date:-inconnue}")
            $(kv_row 'Windows Defender'    "$defender_status")
            $(kv_row 'BitLocker (service)' "$bl_status")
            $(kv_close)"

            echo "$bl_status" | grep -qi "actif\|probable" && {
                content+="$(warn_note 'BitLocker potentiellement actif : certaines données peuvent être chiffrées — clé de récupération nécessaire pour analyse complète.')"
                [ "$status" = "ok" ] && status="warn"
            }
        else
            content+="$(note 'Ruches registre trouvées mais lecture échouée — hive peut-être verrouillé ou corrompu.')"
        fi
    else
        content+="$(note 'Installer <code>hivex</code> (<code>hivexget</code>) pour lire version Windows, Defender, BitLocker et date d'\''installation hors-ligne.')"
    fi

    # Windows.old (place gaspillée)
    if [ -d "$mp/Windows.old" ]; then
        local wo_sz
        wo_sz="$(du -sh "$mp/Windows.old" 2>/dev/null | cut -f1)"
        content+="<p><strong>Windows.old</strong> détecté (${wo_sz:-?}) — ancienne installation non purgée, espace récupérable via Nettoyage de disque.</p>"
        [ "$status" = "ok" ] && status="warn"
        add_reco "CONSEILLÉ" "Windows (${dev}) — dossier Windows.old de ${wo_sz:-taille inconnue} détecté : supprimer via Nettoyage de disque pour récupérer de l'espace"
    fi

    # Cache Windows Update
    if [ -d "$mp/Windows/SoftwareDistribution/Download" ]; then
        local sd_sz
        sd_sz="$(du -sh "$mp/Windows/SoftwareDistribution/Download" 2>/dev/null | cut -f1)"
        content+="<p>Cache Windows Update : ${sd_sz:-?}</p>"
    fi

    # pagefile / hiberfil
    [ -f "$mp/pagefile.sys" ] && \
        content+="<p>Fichier d'échange : $(du -h "$mp/pagefile.sys" 2>/dev/null | cut -f1)</p>"
    [ -f "$mp/hiberfil.sys" ] && \
        content+="<p>Fichier d'hibernation : $(du -h "$mp/hiberfil.sys" 2>/dev/null | cut -f1)</p>"

    # Marqueurs BitLocker (clé de récupération ou dossier spécifique)
    if find "$mp" -maxdepth 2 -name '*BitLocker*' 2>/dev/null | grep -q .; then
        content+="$(warn_note 'Marqueurs BitLocker trouvés — certaines données peuvent être chiffrées.')"
        [ "$status" = "ok" ] && status="warn"
    fi

    content+="$(note 'Antivirus, pilotes et journaux d'\''événements nécessitent un démarrage normal de Windows pour une analyse complète.')"

    add_section "OS détecté : Windows (${dev})" "$status" "$content"
}

# ---------------------------------------------------------------------------
# ANALYSE OS — LINUX
# ---------------------------------------------------------------------------
analyze_linux() {
    local mp="$1" dev="$2" status="ok" content="" usage_pct distro="" kernels="" pkg_count=""

    usage_pct="$(df -h "$mp" 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')"
    [ -n "$usage_pct" ] && [ "$usage_pct" -ge 90 ] && status="crit"
    [ -n "$usage_pct" ] && [ "$usage_pct" -ge 75 ] && [ "$usage_pct" -lt 90 ] && status="warn"

    [ -f "$mp/etc/os-release" ] && \
        distro="$(grep -E '^PRETTY_NAME=' "$mp/etc/os-release" | cut -d= -f2 | tr -d '"')"

    kernels="$(find "$mp/boot" -maxdepth 1 -name 'vmlinuz*' -printf '%f\n' 2>/dev/null | sort -V | tr '\n' ' ')"

    if [ -d "$mp/var/lib/dpkg/info" ]; then
        pkg_count="$(find "$mp/var/lib/dpkg/info" -maxdepth 1 -name '*.list' 2>/dev/null | wc -l) paquets (APT)"
    elif [ -d "$mp/var/lib/rpm" ]; then
        pkg_count="$(find "$mp/var/lib/rpm" -maxdepth 1 -name '*.db' 2>/dev/null | wc -l) bases RPM"
    fi

    content="$(kv_open)
    $(kv_row 'Partition'          "$dev")
    $(kv_row 'Distribution'       "${distro:-inconnue}")
    $(kv_row 'Occupation disque'  "${usage_pct:-?}%")
    $(kv_row 'Noyaux installés'   "${kernels:-non trouvé dans /boot}")
    $(kv_row 'Paquets'            "${pkg_count:-non détecté}")
    $(kv_close)"

    if need_cmd journalctl && [ -d "$mp/var/log/journal" ]; then
        local errcount
        errcount="$(journalctl -D "$mp/var/log/journal" -p err -b -1 2>/dev/null | wc -l)" || errcount=0
        content+="<p>Erreurs journal (dernier démarrage connu) : <strong>${errcount}</strong></p>"
        if [ "${errcount:-0}" -gt 20 ]; then
            [ "$status" = "ok" ] && status="warn"
            add_reco "CONSEILLÉ" "Linux (${dev}) — ${errcount} erreurs dans le journal système : analyser avec journalctl -p err après démarrage"
        fi
    fi

    # LUKS/chiffrement
    if find "$mp/etc" -maxdepth 1 -name 'crypttab' 2>/dev/null | grep -q .; then
        content+="$(note 'Fichier crypttab trouvé : volumes chiffrés (LUKS) présents sur ce système.')"
    fi

    add_section "OS détecté : Linux (${dev})" "$status" "$content"
}

# ---------------------------------------------------------------------------
# ANALYSE OS — macOS
# ---------------------------------------------------------------------------
analyze_macos() {
    local mp="$1" dev="$2" content="" usage_pct

    usage_pct="$(df -h "$mp" 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')"

    content="$(kv_open)
    $(kv_row 'Partition'          "$dev")
    $(kv_row 'Occupation disque'  "$(_fmtval "$usage_pct" '%' 'non lisible')")
    $(kv_close)
    $(warn_note 'Support APFS depuis Linux limité. FileVault (chiffrement macOS, très répandu) bloque toute analyse hors-ligne. Sur Apple Silicon (M1/M2/M3+) : démarrage USB externe verrouillé par défaut — utiliser le diagnostic Apple natif (⌘+D au démarrage).')"

    add_section "OS détecté : macOS (${dev})" "info" "$content"
}

# ---------------------------------------------------------------------------
# DÉTECTION ET MONTAGE DES PARTITIONS OS
# ---------------------------------------------------------------------------
detect_os_partitions() {
    local found=0

    while IFS= read -r line; do
        local name fstype
        name="$(  echo "$line" | awk '{print $1}')"
        fstype="$(echo "$line" | awk '{print $2}')"
        [ -z "$name" ] || [ -z "$fstype" ] && continue

        local dev="/dev/${name}"
        local mp="${MOUNT_ROOT}/${name}"
        mkdir -p "$mp"

        case "$fstype" in
            ntfs|ntfs3)
                if mount -t ntfs3 -o ro,force "$dev" "$mp" 2>/dev/null || \
                   mount -t ntfs-3g -o ro,force "$dev" "$mp" 2>/dev/null; then
                    found=1
                    analyze_windows "$mp" "$dev"
                    umount "$mp" 2>/dev/null || true
                fi
                ;;
            ext2|ext3|ext4|xfs|btrfs|f2fs)
                if mount -o ro "$dev" "$mp" 2>/dev/null; then
                    if [ -f "$mp/etc/os-release" ]; then
                        found=1
                        analyze_linux "$mp" "$dev"
                    fi
                    umount "$mp" 2>/dev/null || true
                fi
                ;;
            hfsplus)
                if mount -t hfsplus -o ro "$dev" "$mp" 2>/dev/null; then
                    found=1
                    analyze_macos "$mp" "$dev"
                    umount "$mp" 2>/dev/null || true
                fi
                ;;
            apfs)
                found=1
                add_section "OS détecté : macOS/APFS (${dev})" "warn" \
                    "<p>Partition APFS détectée. Le pilote <code>apfs-fuse</code> est nécessaire pour la monter — absent de cet environnement live par défaut.</p>
                     $(warn_note 'Mac Apple Silicon (M1/M2/M3+) : boot USB verrouillé par Secure Boot. Diagnostic Apple natif recommandé (⌘+D au démarrage).')"
                ;;
        esac
    done < <(lsblk -rno NAME,FSTYPE 2>/dev/null | awk 'NF==2 && $2!=""')

    if [ "$found" -eq 0 ]; then
        add_section "Détection des systèmes d'exploitation" "warn" \
            "<p>Aucune partition OS reconnue n'a pu être montée (disque chiffré, vierge, ou système de fichiers non pris en charge par cet environnement live).</p>"
    fi
}

# ---------------------------------------------------------------------------
# SECTION RECOMMANDATIONS
# ---------------------------------------------------------------------------
write_recommendations_section() {
    [ "${#RECOMMENDATIONS[@]}" -eq 0 ] && return

    local content="<p style='margin-bottom:12px;font-size:13px;color:var(--muted)'>
        Classées par priorité décroissante — à communiquer au propriétaire.</p>"

    # Itération dans l'ordre de priorité (sans tableaux associatifs pour compatibilité bash 4.0)
    local prio col lbl
    for prio in URGENT IMPORTANT CONSEILLÉ INFO; do
        case "$prio" in
            URGENT)    col="crit" ; lbl="URGENT"    ;;
            IMPORTANT) col="warn" ; lbl="IMPORTANT" ;;
            CONSEILLÉ) col="info" ; lbl="CONSEILLÉ" ;;
            INFO)      col="ok"   ; lbl="INFO"       ;;
        esac

        local items=()
        local r
        for r in "${RECOMMENDATIONS[@]}"; do
            local p t
            p="${r%%:::*}"
            t="${r#*:::}"
            [ "$p" = "$prio" ] && items+=("$t")
        done
        [ "${#items[@]}" -eq 0 ] && continue

        content+="<div style='margin:10px 0 4px'>
            <span class='badge badge-${col}' style='font-size:11px'>${lbl}</span>
        </div><ul style='margin:4px 0 8px 18px;font-size:13px;line-height:1.7'>"
        local item
        for item in "${items[@]}"; do
            content+="<li>$(printf '%s' "$item" | html_escape)</li>"
        done
        content+="</ul>"
    done

    bump "warn"
    cat >> "$REPORT_FILE" <<HTML
<div class="section">
  <div class="section-head status-warn">
    <h2>Recommandations</h2>
    <span class="badge badge-warn">${#RECOMMENDATIONS[@]} point(s)</span>
  </div>
  <div class="section-body">${content}</div>
</div>
HTML
}

# ---------------------------------------------------------------------------
# EXPORT TXT
# ---------------------------------------------------------------------------
write_txt_summary() {
    {
        printf "PC-DIAG v%s — Rapport diagnostic\n" "$VERSION"
        printf "Hôte : %s — %s\n" "$HOSTNAME_DIAG" "$(date '+%d/%m/%Y %H:%M:%S')"
        printf "═%.0s" {1..60}; printf "\n"
        printf "RÉSUMÉ : %d OK / %d Attention(s) / %d Critique(s) / %d Info\n\n" \
               "$COUNT_OK" "$COUNT_WARN" "$COUNT_CRIT" "$COUNT_INFO"

        if [ "${#RECOMMENDATIONS[@]}" -gt 0 ]; then
            printf "RECOMMANDATIONS :\n"
            local r
            for r in "${RECOMMENDATIONS[@]}"; do
                local p t
                p="${r%%:::*}"
                t="${r#*:::}"
                printf "  [%s] %s\n" "$p" "$t"
            done
            printf "\n"
        fi

        printf "Rapport HTML complet : %s\n" "$REPORT_FILE"
        printf "═%.0s" {1..60}; printf "\n"
        printf "100%% local — aucune donnée n'a quitté cette machine.\n"
    } > "$TXT_FILE"

    echo "  Résumé TXT : ${TXT_FILE}"
}

# ---------------------------------------------------------------------------
# COPIE DU RAPPORT SUR LA CLÉ USB
# ---------------------------------------------------------------------------
# Détecte le point de montage Ventoy/USB et y copie les rapports HTML+TXT.
# Override possible : USB_RAPPORTS_DIR=/chemin/vers/dossier sudo ./pc-diag.sh
detect_usb_mount() {
    # 1. Override explicite
    if [ -n "${USB_RAPPORTS_DIR:-}" ]; then
        echo "$USB_RAPPORTS_DIR"
        return
    fi

    # 2. Points de montage Ventoy courants
    for _mp in /mnt/ventoy /run/archiso/bootmnt /media/ventoy; do
        if mountpoint -q "$_mp" 2>/dev/null && [ -w "$_mp" ]; then
            echo "${_mp}/rapports"
            return
        fi
    done

    # 3. Fallback : premier FS FAT/exFAT monté rw sur un périphérique amovible
    while read -r _dev _mp _fs _opts _rest; do
        [[ "$_fs" =~ ^(vfat|fat|exfat|msdos)$ ]] || continue
        [[ "$_opts" == *rw* ]]                    || continue
        [[ "$_mp"  =~ ^/(proc|sys|dev|run|tmp) ]] && continue
        local _bdev
        _bdev="$(basename "$_dev")"
        # Remonter au disque parent (sdb1 → sdb) pour lire removable
        local _parent="${_bdev%%[0-9]*}"
        local _removable="/sys/class/block/${_parent}/removable"
        [ "$(cat "$_removable" 2>/dev/null)" = "1" ] || continue
        echo "${_mp}/rapports"
        return
    done < /proc/mounts
}

copy_report_to_usb() {
    local usb_dir
    usb_dir="$(detect_usb_mount)"

    if [ -z "$usb_dir" ]; then
        printf "  ⚠ Clé USB non détectée — rapport uniquement dans %s\n" "$OUTDIR"
        printf "    (monter la clé puis : cp '%s' /mnt/ventoy/rapports/)\n" "$REPORT_FILE"
        return
    fi

    if ! mkdir -p "$usb_dir" 2>/dev/null; then
        printf "  ⚠ Impossible de créer %s (clé en lecture seule ?)\n" "$usb_dir"
        return
    fi

    local ok=true
    cp "$REPORT_FILE" "$usb_dir/" 2>/dev/null || ok=false
    cp "$TXT_FILE"    "$usb_dir/" 2>/dev/null || ok=false

    if $ok; then
        printf "  Copie USB  : %s/\n" "$usb_dir"
    else
        printf "  ⚠ Copie partielle vers %s — vérifier l'espace disponible\n" "$usb_dir"
    fi
}

# ---------------------------------------------------------------------------
# ORCHESTRATION
# ---------------------------------------------------------------------------
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  PC-DIAG v${VERSION} — Diagnostic professionnel PC"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    write_html_header

    printf "   [1/11] Outils système\n"               ; check_tools
    printf "   [2/11] Carte mère & BIOS\n"            ; check_motherboard
    printf "   [3/11] Processeur (CPU)\n"             ; check_cpu
    printf "   [4/11] Mémoire vive (RAM)\n"           ; check_ram
    printf "   [5/11] Test intégrité RAM (rapide)\n"  ; check_ram_test
    printf "   [6/11] Disques (SMART+vitesse)\n"      ; check_disks
    printf "   [7/11] Carte graphique\n"              ; check_gpu
    printf "   [8/11] Stress-test CPU (30s)\n"        ; check_stress_cpu
    printf "   [9/11] Batterie\n"                     ; check_battery
    printf "  [10/11] Réseau, USB, Bluetooth\n"       ; check_peripherals
    printf "  [11/11] Table des partitions\n"         ; check_partitions
    echo
    printf "  [OS]  Détection et analyse des systèmes installés...\n"
    detect_os_partitions

    write_recommendations_section
    write_html_footer

    # Injection du bloc de synthèse après <div class="container">
    local summary_tmp
    summary_tmp="$(mktemp)"
    write_summary_block > "$summary_tmp"
    awk -v sf="$summary_tmp" '
        { print }
        /<div class="container">/ && !done {
            while ((getline line < sf) > 0) print line
            done=1
        }
    ' "$REPORT_FILE" > "${REPORT_FILE}.tmp" \
        && mv "${REPORT_FILE}.tmp" "$REPORT_FILE"
    rm -f "$summary_tmp"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Diagnostic terminé ✓"
    echo "  Rapport : ${REPORT_FILE}"
    echo "  Résumé  : ${COUNT_OK} OK / ${COUNT_WARN} attention(s) / ${COUNT_CRIT} critique(s) / ${COUNT_INFO} info"
    echo
    echo "  → Imprimer en PDF : Firefox > Fichier > Imprimer > Enregistrer en PDF"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    write_txt_summary
    copy_report_to_usb

    # Ouverture automatique du rapport uniquement si session graphique disponible
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        for _browser in firefox chromium chromium-browser; do
            if need_cmd "$_browser"; then
                printf "\n  → Ouverture automatique dans %s...\n" "$_browser"
                "$_browser" "$REPORT_FILE" >/dev/null 2>&1 &
                break
            fi
        done
    else
        printf "\n  → Pas de session graphique (X11/Wayland) — ouvrir manuellement :\n"
        printf "      firefox '%s'\n" "$REPORT_FILE"
    fi
}

main "$@"
