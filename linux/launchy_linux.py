#!/usr/bin/env python3
"""Launchy pour Linux (Pop!_OS) : version hors ligne, sans vérification des pseudos.

Installe Minecraft 1.21.1 + NeoForge 21.1.248, synchronise les mods depuis
mods.neo-verse.net, puis lance le jeu directement sur ultra.neo-verse.net.

Dépendances : Python 3 et tkinter (inclus dans Pop!_OS, sinon `sudo apt install python3-tk`).
Java n'est pas nécessaire : Launchy télécharge le runtime Java 21 de Mojang.
"""

import hashlib
import json
import os
import platform
import queue
import re
import shutil
import subprocess
import threading
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
import tkinter as tk
from tkinter import ttk

MC_VERSION = "1.21.1"
NEOFORGE = "21.1.248"
LOADER_ID = f"neoforge-{NEOFORGE}"
SERVER = "ultra.neo-verse.net"
MODS_MANIFEST = "https://mods.neo-verse.net/ultra/lastest"
NEOFORGE_INSTALLER = (
    f"https://maven.neoforged.net/releases/net/neoforged/neoforge/{NEOFORGE}/neoforge-{NEOFORGE}-installer.jar"
)
RUNTIME_INDEX = "https://launchermeta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json"
VERSION_LIST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
ASSET_BASE = "https://resources.download.minecraft.net"
LIBRARY_BASE = "https://libraries.minecraft.net/"
ROOT = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "Launchy", "minecraft")
USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,16}$")


# --- Téléchargements -------------------------------------------------------

def get_json(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def sha1_of(path):
    digest = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, dest, sha1=None):
    if os.path.exists(dest) and (sha1 is None or sha1_of(dest) == sha1):
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    with urllib.request.urlopen(url, timeout=60) as response, open(tmp, "wb") as f:
        shutil.copyfileobj(response, f)
    if sha1 and sha1_of(tmp) != sha1:
        os.remove(tmp)
        raise RuntimeError(f"Fichier corrompu : {os.path.basename(url)}")
    os.replace(tmp, dest)


def download_all(items, report, label, low, high):
    """items : liste de (url, sha1 ou None, destination). Téléchargement en parallèle."""
    total = len(items)
    if total == 0:
        report(label, high)
        return
    done = 0
    lock = threading.Lock()

    def work(item):
        nonlocal done
        download(item[0], item[2], item[1])
        with lock:
            done += 1
            count = done
        report(f"{label} {count}/{total}", low + (high - low) * count / total)

    with ThreadPoolExecutor(max_workers=16) as pool:
        list(pool.map(work, items))


# --- Règles Mojang et arguments -------------------------------------------

def rule_matches(rule):
    os_rule = rule.get("os")
    if os_rule:
        if os_rule.get("name") and os_rule["name"] != "linux":
            return False
        if os_rule.get("arch") == "x86":
            return False
    features = rule.get("features")
    if features and any(features.values()):
        return False
    return True


def allowed(rules):
    if not rules:
        return True
    result = False
    for rule in rules:
        if rule_matches(rule):
            result = rule["action"] == "allow"
    return result


def resolve_arguments(arguments, values):
    raw = []
    for argument in arguments:
        if isinstance(argument, str):
            raw.append(argument)
        elif allowed(argument.get("rules")):
            value = argument["value"]
            raw.extend([value] if isinstance(value, str) else value)
    resolved = []
    for text in raw:
        for key, value in values.items():
            text = text.replace("${" + key + "}", value)
        resolved.append(text)
    return resolved


# --- Bibliothèques ---------------------------------------------------------

def maven_key(name):
    parts = name.split(":")
    if len(parts) < 3:
        return None
    return f"{parts[0]}:{parts[1]}" + (f":{parts[3]}" if len(parts) > 3 else "")


def maven_path(name):
    parts = name.split(":")
    if len(parts) < 3:
        return None
    classifier = f"-{parts[3]}" if len(parts) > 3 else ""
    return f"{parts[0].replace('.', '/')}/{parts[1]}/{parts[2]}/{parts[1]}-{parts[2]}{classifier}.jar"


def library_files(vanilla, loader):
    """Fusionne vanilla et NeoForge (NeoForge gagne en cas de doublon) et garde ce qui concerne Linux."""
    chosen, order = {}, []
    for library in vanilla + loader:
        key = maven_key(library["name"])
        if key is None:
            continue
        if key not in chosen:
            order.append(key)
        chosen[key] = library

    files = []
    for key in order:
        library = chosen[key]
        if not allowed(library.get("rules")) or "natives" in library:
            continue
        artifact = (library.get("downloads") or {}).get("artifact")
        if artifact and artifact.get("path"):
            path, url, sha1 = artifact["path"], artifact["url"], artifact.get("sha1")
        else:
            path = maven_path(library["name"])
            url, sha1 = library.get("url", LIBRARY_BASE) + path, None
        if path:
            files.append((url, sha1, path))
    return files


# --- Installation ----------------------------------------------------------

def install_runtime(component, destination, report):
    index = get_json(RUNTIME_INDEX)
    manifest = get_json(index["linux"][component][0]["manifest"]["url"])["files"]
    files, executables, links = [], [], []
    for path, entry in manifest.items():
        target = os.path.join(destination, path)
        if entry["type"] == "directory":
            os.makedirs(target, exist_ok=True)
        elif entry["type"] == "file":
            raw = entry["downloads"]["raw"]
            files.append((raw["url"], raw["sha1"], target))
            if entry.get("executable"):
                executables.append(target)
        elif entry["type"] == "link":
            links.append((target, entry["target"]))
    download_all(files, report, "Java", 0.05, 0.2)
    for path in executables:
        os.chmod(path, 0o755)
    for link, target in links:
        if os.path.lexists(link):
            os.remove(link)
        os.makedirs(os.path.dirname(link), exist_ok=True)
        os.symlink(target, link)


def install_neoforge(java, report):
    profile = os.path.join(ROOT, "versions", LOADER_ID, f"{LOADER_ID}.json")
    if os.path.exists(profile):
        return
    report("Installation de NeoForge", 0.25)
    installer = os.path.join(ROOT, "installers", f"{LOADER_ID}-installer.jar")
    download(NEOFORGE_INSTALLER, installer)
    launcher_profiles = os.path.join(ROOT, "launcher_profiles.json")
    if not os.path.exists(launcher_profiles):
        with open(launcher_profiles, "w") as f:
            f.write('{"profiles":{}}')
    log_path = os.path.join(ROOT, "neoforge-installer.log")
    with open(log_path, "w") as log:
        status = subprocess.run(
            [java, "-jar", installer, "--installClient", ROOT],
            cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        ).returncode
    if status != 0 or not os.path.exists(profile):
        raise RuntimeError(f"Installation de NeoForge échouée, voir {log_path}")


def sync_mods(mods_dir, report):
    manifest = get_json(MODS_MANIFEST)
    os.makedirs(mods_dir, exist_ok=True)
    wanted = {mod["name"] for mod in manifest["mods"]}
    for name in os.listdir(mods_dir):
        if name.endswith(".jar") and name not in wanted:
            os.remove(os.path.join(mods_dir, name))
    files = [(mod["url"], mod["sha1"], os.path.join(mods_dir, mod["name"])) for mod in manifest["mods"]]
    download_all(files, report, "Mods", 0.0, 1.0)


def prepare(report):
    """Installe tout ce qui manque et renvoie les paramètres de lancement."""
    game_dir = os.path.join(ROOT, "game")
    assets_dir = os.path.join(ROOT, "assets")
    library_root = os.path.join(ROOT, "libraries")
    version_dir = os.path.join(ROOT, "versions", MC_VERSION)
    natives_dir = os.path.join(version_dir, "natives")
    for directory in (game_dir, natives_dir):
        os.makedirs(directory, exist_ok=True)

    report(f"Version {MC_VERSION}", 0.0)
    version_list = get_json(VERSION_LIST)
    entry = next(v for v in version_list["versions"] if v["id"] == MC_VERSION)
    version_file = os.path.join(version_dir, f"{MC_VERSION}.json")
    download(entry["url"], version_file, entry["sha1"])
    with open(version_file) as f:
        vanilla = json.load(f)

    client_jar = os.path.join(version_dir, f"{MC_VERSION}.jar")
    report("Client Minecraft", 0.02)
    download(vanilla["downloads"]["client"]["url"], client_jar, vanilla["downloads"]["client"]["sha1"])

    component = vanilla.get("javaVersion", {}).get("component", "jre-legacy")
    runtime_dir = os.path.join(ROOT, "runtime", component)
    java = os.path.join(runtime_dir, "bin", "java")
    if not os.path.exists(java):
        install_runtime(component, runtime_dir, report)
    os.chmod(java, 0o755)

    install_neoforge(java, report)
    with open(os.path.join(ROOT, "versions", LOADER_ID, f"{LOADER_ID}.json")) as f:
        loader = json.load(f)

    libraries = library_files(vanilla["libraries"], loader["libraries"])
    report("Bibliothèques", 0.3)
    download_all([(url, sha1, os.path.join(library_root, path)) for url, sha1, path in libraries],
                 report, "Bibliothèques", 0.3, 0.5)

    index_id = vanilla["assetIndex"]["id"]
    index_file = os.path.join(assets_dir, "indexes", f"{index_id}.json")
    download(vanilla["assetIndex"]["url"], index_file, vanilla["assetIndex"]["sha1"])
    with open(index_file) as f:
        objects = json.load(f)["objects"].values()
    assets = []
    for obj in objects:
        prefix = obj["hash"][:2]
        assets.append((f"{ASSET_BASE}/{prefix}/{obj['hash']}", obj["hash"],
                       os.path.join(assets_dir, "objects", prefix, obj["hash"])))
    download_all(assets, report, "Assets", 0.5, 0.85)

    sync_mods(os.path.join(game_dir, "mods"), report)
    report("Prêt", 1.0)

    classpath = [os.path.join(library_root, path) for _, _, path in libraries]
    classpath.append(client_jar)
    return {
        "java": java,
        "main_class": loader["mainClass"],
        "jvm": vanilla["arguments"]["jvm"] + loader.get("arguments", {}).get("jvm", []),
        "game": vanilla["arguments"]["game"] + loader.get("arguments", {}).get("game", []),
        "asset_index": index_id,
        "classpath": classpath,
        "library_root": library_root,
        "natives_dir": natives_dir,
        "game_dir": game_dir,
        "assets_dir": assets_dir,
    }


def offline_uuid(username):
    return uuid.UUID(bytes=hashlib.md5(f"OfflinePlayer:{username}".encode()).digest(), version=3).hex


def launch(params, username):
    values = {
        "auth_player_name": username,
        "version_name": LOADER_ID,
        "game_directory": params["game_dir"],
        "assets_root": params["assets_dir"],
        "assets_index_name": params["asset_index"],
        "auth_uuid": offline_uuid(username),
        "auth_access_token": "0",
        "auth_session": "0",
        "clientid": "",
        "auth_xuid": "",
        "user_type": "legacy",
        "user_properties": "{}",
        "version_type": "release",
        "natives_directory": params["natives_dir"],
        "library_directory": params["library_root"],
        "classpath_separator": ":",
        "launcher_name": "Launchy",
        "launcher_version": "1.0",
        "classpath": ":".join(params["classpath"]),
    }
    command = (
        [params["java"], "-Xms1G", "-Xmx4G"]
        + resolve_arguments(params["jvm"], values)
        + [params["main_class"]]
        + resolve_arguments(params["game"], values)
        + ["--quickPlayMultiplayer", SERVER]
    )
    log = open(os.path.join(params["game_dir"], "launchy-latest.log"), "w")
    return subprocess.Popen(command, cwd=params["game_dir"], stdout=log, stderr=subprocess.STDOUT)


# --- Interface -------------------------------------------------------------

class LaunchyApp:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()
        self.process = None
        self.busy = False

        root.title("Launchy")
        root.geometry("460x330")
        root.resizable(False, False)

        frame = ttk.Frame(root, padding=24)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Launchy", font=("Sans", 26, "bold")).pack()
        ttk.Label(frame, text=f"Minecraft {MC_VERSION} · NeoForge {NEOFORGE}").pack(pady=(0, 16))

        ttk.Label(frame, text="Pseudo").pack(anchor="w")
        self.username = tk.StringVar(value="Joueur")
        ttk.Entry(frame, textvariable=self.username, width=30).pack(fill="x", pady=(4, 12))

        self.button = ttk.Button(frame, text="Jouer", command=self.play)
        self.button.pack(fill="x", ipady=6)

        self.progress = ttk.Progressbar(frame, maximum=1.0)
        self.progress.pack(fill="x", pady=(14, 4))
        self.status = ttk.Label(frame, text="", wraplength=400, justify="center")
        self.status.pack()

        root.after(100, self.poll)

    def play(self):
        name = self.username.get().strip()
        if not USERNAME_RE.match(name):
            self.status.config(text="Pseudo invalide : 3 à 16 caractères, lettres, chiffres et _.")
            return
        self.busy = True
        self.button.config(state="disabled")
        threading.Thread(target=self.worker, args=(name,), daemon=True).start()

    def worker(self, name):
        try:
            params = prepare(lambda label, fraction: self.events.put(("progress", label, fraction)))
            self.events.put(("launching",))
            self.events.put(("started", launch(params, name)))
        except Exception as error:  # l'erreur est affichée dans la fenêtre
            self.events.put(("error", str(error)))

    def poll(self):
        try:
            while True:
                event = self.events.get_nowait()
                if event[0] == "progress":
                    self.progress.config(value=event[2])
                    self.status.config(text=event[1])
                elif event[0] == "launching":
                    self.status.config(text="Lancement de Minecraft…")
                elif event[0] == "started":
                    self.process = event[1]
                    self.button.config(text="En jeu")
                    self.status.config(text="Minecraft est lancé.")
                elif event[0] == "error":
                    self.busy = False
                    self.button.config(state="normal")
                    self.status.config(text=event[1])
        except queue.Empty:
            pass

        if self.process is not None and self.process.poll() is not None:
            self.process = None
            self.busy = False
            self.button.config(text="Jouer", state="normal")
            self.status.config(text="Minecraft s'est fermé.")
        self.root.after(100, self.poll)


def main():
    if platform.system() != "Linux":
        print("Cette version est prévue pour Linux (Pop!_OS).")
    root = tk.Tk()
    LaunchyApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
