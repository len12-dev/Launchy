#!/usr/bin/env bash
# Launchy pour Linux (Pop!_OS, Ubuntu, Debian…) : télécharge le launcher et le lance.
# Usage : curl -fsSL https://raw.githubusercontent.com/len12-dev/Launchy/main/scripts/install_linux.sh | bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/len12-dev/Launchy/main/launcher"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Launchy/bin"

die() {
    echo "Erreur : $*" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || die "python3 est introuvable. Installez-le avec : sudo apt install python3"
python3 -c "import tkinter" 2>/dev/null || die "tkinter est absent. Installez-le avec : sudo apt install python3-tk"
command -v curl >/dev/null 2>&1 || die "curl est introuvable. Installez-le avec : sudo apt install curl"

mkdir -p "$INSTALL_DIR"
for file in launchy_core.py launchy.py; do
    echo "Téléchargement de $file…"
    curl -fsSL "$BASE_URL/$file" -o "$INSTALL_DIR/$file.tmp" || die "téléchargement impossible : $BASE_URL/$file"
    mv "$INSTALL_DIR/$file.tmp" "$INSTALL_DIR/$file"
done

cd "$INSTALL_DIR"
exec python3 launchy.py
