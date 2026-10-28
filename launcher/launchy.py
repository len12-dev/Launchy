#!/usr/bin/env python3
"""Launchy : interface graphique (tkinter) au-dessus de launchy_core.

Lancement : python3 launchy.py   (ou via scripts/install_linux.sh).
"""

import base64
import datetime
import json
import os
import queue
import threading
import traceback
import tkinter as tk
from tkinter import ttk

import launchy_core as core

BG = "#1b1d22"
CARD = "#25282f"
TEXT = "#f2f3f5"
MUTED = "#9aa0ab"
ACCENT = "#3ba55d"
ACCENT_HOVER = "#2f8a4c"
DANGER = "#ed4245"
SKIN_URL = "https://auth-launchy.neo-verse.net/skins/{name}.png"
CONFIG_FILE = os.path.join(core.ROOT, "launchy.json")
LOG_FILE = os.path.join(core.ROOT, "launchy.log")


def log_error(message):
    # Trace complète dans un fichier, pour pouvoir diagnostiquer un poste sans console (pythonw / .exe).
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"[{datetime.datetime.now().isoformat(timespec='seconds')}] {message}\n")
            f.write(traceback.format_exc() + "\n")
    except OSError:
        pass


def load_config():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_config(config):
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f)


class LaunchyApp:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()
        self.process = None
        self.busy = False
        self.config_data = load_config()
        self.avatar = None

        root.title("Launchy")
        root.geometry("560x600")
        root.minsize(520, 560)
        root.configure(bg=BG)
        self.style()

        header = tk.Frame(root, bg=BG)
        header.pack(fill="x", padx=32, pady=(28, 8))
        tk.Label(header, text="Launchy", font=("Sans", 28, "bold"), fg=TEXT, bg=BG).pack(anchor="w")
        tk.Label(header, text="Ultra · Minecraft 1.21.1 · NeoForge 21.1.248",
                 font=("Sans", 11), fg=MUTED, bg=BG).pack(anchor="w")

        card = tk.Frame(root, bg=CARD, padx=28, pady=24)
        card.pack(fill="x", padx=32, pady=16)

        top = tk.Frame(card, bg=CARD)
        top.pack(fill="x")
        self.avatar_label = tk.Label(top, bg=CARD, width=128, height=128)
        self.avatar_label.pack(side="left")

        form = tk.Frame(top, bg=CARD)
        form.pack(side="left", fill="x", expand=True, padx=(20, 0))
        tk.Label(form, text="Pseudo", font=("Sans", 11, "bold"), fg=MUTED, bg=CARD).pack(anchor="w")
        self.username = tk.StringVar(value=self.config_data.get("username", ""))
        entry = tk.Entry(form, textvariable=self.username, font=("Sans", 16), bg=BG, fg=TEXT,
                         insertbackground=TEXT, relief="flat", highlightthickness=1,
                         highlightbackground=BG, highlightcolor=ACCENT)
        entry.pack(fill="x", ipady=8, pady=(6, 0))
        entry.bind("<Return>", lambda _event: self.play())
        entry.bind("<FocusOut>", lambda _event: self.refresh_avatar())
        self.username.trace_add("write", lambda *_args: self.on_name_changed())
        tk.Label(form, text="3 à 16 caractères : lettres, chiffres et _",
                 font=("Sans", 9), fg=MUTED, bg=CARD).pack(anchor="w", pady=(6, 0))

        self.play_button = tk.Button(card, text="JOUER", font=("Sans", 16, "bold"), bg=ACCENT,
                                     fg="white", activebackground=ACCENT_HOVER, activeforeground="white",
                                     relief="flat", cursor="hand2", command=self.play, bd=0)
        self.play_button.pack(fill="x", ipady=12, pady=(24, 0))
        self.play_button.bind("<Enter>", lambda _event: self.hover(True))
        self.play_button.bind("<Leave>", lambda _event: self.hover(False))

        self.progress = ttk.Progressbar(root, style="Launchy.Horizontal.TProgressbar", maximum=1.0)
        self.progress.pack(fill="x", padx=32, pady=(8, 4))
        self.status = tk.Label(root, text="Prêt à jouer", font=("Sans", 11), fg=MUTED, bg=BG,
                               wraplength=480, justify="center")
        self.status.pack(pady=(4, 0))

        footer = tk.Label(root, text="Les mods et Java sont installés automatiquement.",
                          font=("Sans", 9), fg=MUTED, bg=BG)
        footer.pack(side="bottom", pady=12)

        self.refresh_avatar()
        root.after(100, self.poll)

    def style(self):
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Launchy.Horizontal.TProgressbar", troughcolor=CARD, background=ACCENT,
                        bordercolor=CARD, lightcolor=ACCENT, darkcolor=ACCENT, thickness=10)

    def hover(self, inside):
        if self.play_button["state"] == "disabled":
            return
        self.play_button.configure(bg=ACCENT_HOVER if inside else ACCENT)

    def on_name_changed(self):
        # Le skin est rechargé quand le pseudo est complet ; évite les requêtes à chaque lettre.
        if core_valid(self.username.get()):
            self.refresh_avatar()

    def refresh_avatar(self):
        name = self.username.get().strip()
        if not core_valid(name):
            self.set_avatar(None)
            return
        threading.Thread(target=self.load_skin, args=(name,), daemon=True).start()

    def load_skin(self, name):
        try:
            with core.open_url(SKIN_URL.format(name=name), 10) as response:
                data = response.read()
            self.events.put(("skin", name, data))
        except Exception:
            self.events.put(("skin", name, None))

    def set_avatar(self, data):
        if data is None:
            self.avatar = None
            self.avatar_label.configure(image="", text="Aucun skin", fg=MUTED, font=("Sans", 10))
            return
        try:
            image = tk.PhotoImage(data=base64.b64encode(data).decode())
            # Affiche le visage (8x8 à partir de 8,8) agrandi x12 : n'utilise que la partie visible.
            face = tk.PhotoImage(width=8, height=8)
            face.tk.call(face, "copy", image, "-from", 8, 8, 16, 16, "-to", 0, 0)
            self.avatar = face.zoom(12, 12)
        except tk.TclError:
            # Skin illisible (format inattendu) : on garde le texte à la place de l'image.
            log_error("Skin non décodable")
            self.set_avatar(None)
            return
        self.avatar_label.configure(image=self.avatar, text="")

    def play(self):
        name = self.username.get().strip()
        if not core_valid(name):
            self.set_status("Pseudo invalide : 3 à 16 caractères, lettres, chiffres et _.", DANGER)
            return
        save_config({"username": name})
        self.busy = True
        self.play_button.configure(state="disabled", bg=MUTED, text="INSTALLATION…")
        self.progress.configure(value=0)
        threading.Thread(target=self.worker, args=(name,), daemon=True).start()

    def worker(self, name):
        try:
            params = core.prepare(lambda label, fraction: self.events.put(("progress", label, fraction)))
            self.events.put(("launching",))
            self.events.put(("started", core.launch(params, name)))
        except Exception as error:
            log_error("Échec de l'installation ou du lancement")
            self.events.put(("error", f"{error}. Détails dans {LOG_FILE}"))

    def set_status(self, text, color=MUTED):
        self.status.configure(text=text, fg=color)

    def handle(self, event):
        kind = event[0]
        if kind == "progress":
            self.progress.configure(value=event[2])
            self.set_status(event[1])
        elif kind == "launching":
            self.set_status("Lancement de Minecraft…")
        elif kind == "started":
            self.process = event[1]
            self.play_button.configure(text="EN JEU", bg=ACCENT)
            self.set_status("Minecraft est lancé. Bon jeu !", ACCENT)
        elif kind == "error":
            self.busy = False
            self.play_button.configure(state="normal", bg=ACCENT, text="JOUER")
            self.set_status(event[1], DANGER)
        elif kind == "skin":
            if event[1] == self.username.get().strip():
                self.set_avatar(event[2])

    def poll(self):
        # Chaque événement est isolé : une erreur d'affichage ne doit pas arrêter la boucle,
        # sinon le bouton reste bloqué.
        while True:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                break
            try:
                self.handle(event)
            except Exception:
                log_error(f"Erreur d'affichage pour l'événement {event[0]}")

        try:
            if self.process is not None and self.process.poll() is not None:
                self.process = None
                self.busy = False
                self.play_button.configure(state="normal", bg=ACCENT, text="JOUER")
                self.set_status("Minecraft s'est fermé.")
        except Exception:
            log_error("Erreur lors de la surveillance de Minecraft")
        self.root.after(100, self.poll)


def core_valid(name):
    return core.USERNAME_RE.match(name) is not None


def main():
    root = tk.Tk()
    LaunchyApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
