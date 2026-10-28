#!/usr/bin/env bash
# Launchy pour Linux (Pop!_OS) : télécharge le launcher puis le lance.
# Usage : bash launchy.sh
set -euo pipefail

LAUNCHER_URL="https://github.com/len12-dev/Launchy/releases/latest/download/launchy_linux.py"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Launchy/bin"
LAUNCHER="$INSTALL_DIR/launchy_linux.py"

die() {
    echo "Erreur : $*" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || die "python3 est introuvable. Installez-le avec : sudo apt install python3"
python3 -c "import tkinter" 2>/dev/null || die "tkinter est absent. Installez-le avec : sudo apt install python3-tk"
command -v curl >/dev/null 2>&1 || die "curl est introuvable. Installez-le avec : sudo apt install curl"

mkdir -p "$INSTALL_DIR"
echo "Téléchargement de Launchy…"
curl -fsSL "$LAUNCHER_URL" -o "$LAUNCHER.tmp" || die "téléchargement impossible : $LAUNCHER_URL"
mv "$LAUNCHER.tmp" "$LAUNCHER"

exec python3 "$LAUNCHER"
