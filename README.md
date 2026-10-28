# Launchy

Launcher Minecraft natif pour serveur moddé.

## Objectifs

- Mises à jour et nouveaux mods téléchargés automatiquement
- Comptes premium et cracks, avec authentification et protection des pseudos déjà enregistrés
- Changement de skin (import depuis Launchy)
- Interface la plus native possible

## Plateforme

Première version : macOS (SwiftUI).

## Installation

- **macOS** : `bash scripts/build_macos_app.sh` construit `dist/Launchy.app` (et une archive zip).
- **Windows** : le workflow GitHub Actions `Build Windows` produit `Launchy.exe` (onglet Actions, artefact `Launchy-windows`).
- **Linux (Pop!_OS, Ubuntu…)** :
  ```bash
  curl -fsSL https://raw.githubusercontent.com/len12-dev/Launchy/main/scripts/install_linux.sh | bash
  ```

Le launcher installe Minecraft 1.21.1, Java 21 et NeoForge 21.1.248, synchronise les mods, puis lance le jeu sur `ultra.neo-verse.net`.

## Structure

- `Sources/` : application macOS (SwiftUI).
- `launcher/` : launcher multi-plateforme (Python/tkinter) pour Windows et Linux, aussi utilisable sur macOS.
- `server/` : services d'authentification et de distribution des mods.
- `scripts/` : scripts de build et d'installation.
