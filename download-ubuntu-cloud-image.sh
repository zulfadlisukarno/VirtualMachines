#!/bin/bash
# Download Ubuntu Cloud Image (QCow2 UEFI/GPT Bootable disk image)
# Source: https://cloud-images.ubuntu.com/

BASE_URL="https://cloud-images.ubuntu.com"
ARCH="amd64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${SCRIPT_DIR}/images"

echo "========================================"
echo "  Ubuntu Cloud Image Downloader"
echo "========================================"
echo ""
echo "Fetching available versions..."
echo ""

# Fetch and parse available Ubuntu Server versions from the main index page
VERSIONS_RAW=$(python3 - <<'PYEOF'
import urllib.request, re, sys

try:
    with urllib.request.urlopen("https://cloud-images.ubuntu.com/", timeout=15) as r:
        html = r.read().decode("utf-8", errors="replace")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

# Each entry is on one line: href="focal/">focal/</a> ... Ubuntu Server 20.04 LTS (Focal Fossa)...
# Filter only versioned releases (have X.XX LTS), exclude "minimal", "server", etc.
pattern = re.compile(
    r'href="([a-z]+)/".*?Ubuntu Server (\d+\.\d+ LTS \([^)]+\))([^<]*)'
)
results = []
for m in pattern.finditer(html):
    codename = m.group(1)
    version  = m.group(2)
    suffix   = m.group(3).strip()
    eol      = " [END OF STANDARD SUPPORT]" if "END OF STANDARD SUPPORT" in suffix else ""
    # Extract version number for sorting
    ver_num  = float(re.match(r'(\d+\.\d+)', version).group(1))
    results.append((ver_num, codename, f"Ubuntu Server {version}{eol}"))

for _, codename, label in sorted(results):
    print(f"{codename}|{label}")
PYEOF
)

if [[ -z "$VERSIONS_RAW" ]]; then
    echo "Error: Could not fetch version list. Check your internet connection."
    exit 1
fi

declare -a CODENAMES
declare -a LABELS

idx=1
while IFS='|' read -r codename label; do
    CODENAMES[$idx]="$codename"
    LABELS[$idx]="$label"
    idx=$((idx + 1))
done <<< "$VERSIONS_RAW"

TOTAL=${#CODENAMES[@]}

echo "Available versions:"
echo ""
for i in $(seq 1 "$TOTAL"); do
    printf "  [%d] %s (%s)\n" "$i" "${LABELS[$i]}" "${CODENAMES[$i]}"
done
echo ""

while true; do
    read -rp "Select version [1-${TOTAL}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$TOTAL" ]]; then
        break
    fi
    echo "  Invalid choice. Please enter a number between 1 and ${TOTAL}."
done

CODENAME="${CODENAMES[$choice]}"
LABEL="${LABELS[$choice]}"
DIR_URL="${BASE_URL}/${CODENAME}/current/"

echo ""
echo "  Version : ${LABEL}"
echo "  Looking up QCow2 UEFI/GPT image..."

# Fetch the version directory and find the file described as exactly
# "QCow2 UEFI/GPT Bootable disk image" (excludes the linux-kvm variant)
FILENAME=$(python3 - "$DIR_URL" "$ARCH" <<'PYEOF'
import urllib.request, re, sys

url  = sys.argv[1]
arch = sys.argv[2]

try:
    with urllib.request.urlopen(url, timeout=15) as r:
        html = r.read().decode("utf-8", errors="replace")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

# Each file entry is on one line:
# <a href="FILENAME">FILENAME</a>   DATE   SIZE   DESCRIPTION
# Match files for the requested arch whose description is exactly
# "QCow2 UEFI/GPT Bootable disk image" (no extra words after)
pattern = re.compile(
    r'href="([^"]*' + re.escape(arch) + r'[^"]*)"[^>]*>[^<]+</a>[^\n]*QCow2 UEFI/GPT Bootable disk image\s*\n'
)
matches = pattern.findall(html)
if matches:
    print(matches[0])
else:
    sys.exit(1)
PYEOF
)

if [[ -z "$FILENAME" ]]; then
    echo "Error: Could not find 'QCow2 UEFI/GPT Bootable disk image' for ${ARCH} in ${DIR_URL}"
    exit 1
fi

URL="${DIR_URL}${FILENAME}"

echo "  File    : ${FILENAME}"
echo "  URL     : ${URL}"
echo ""

read -rp "Download to images/ folder? [Y/n]: " confirm
confirm="${confirm:-Y}"
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Downloading ${FILENAME}..."
echo ""

if command -v wget &>/dev/null; then
    wget --progress=bar:force -O "${DEST_DIR}/${FILENAME}" "${URL}"
elif command -v curl &>/dev/null; then
    curl -L --progress-bar -o "${DEST_DIR}/${FILENAME}" "${URL}"
else
    echo "Error: Neither wget nor curl is available. Please install one."
    exit 1
fi

if [[ $? -eq 0 ]]; then
    SIZE=$(du -sh "${DEST_DIR}/${FILENAME}" 2>/dev/null | cut -f1)
    echo ""
    echo "Download complete: images/${FILENAME} (${SIZE})"
else
    echo ""
    echo "Download failed."
    rm -f "${DEST_DIR}/${FILENAME}"
    exit 1
fi
