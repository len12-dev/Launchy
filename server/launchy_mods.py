"""API de distribution des mods Launchy.

Lecture publique du manifeste et des fichiers ; import réservé (jeton Bearer).

Routes :
  GET  /ultra/lastest                      -> manifeste JSON (liste des mods, SHA-1, URL)
  GET  /ultra/lastest/files/<fichier.jar>  -> téléchargement d'un mod
  POST /ultra/lastest/import               -> import d'un mod (corps = jar brut,
                                              en-tête X-Filename, Authorization: Bearer <jeton>)
"""

import hashlib
import hmac
import json
import os
import re
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

HOST = os.environ.get("LAUNCHY_MODS_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAUNCHY_MODS_PORT", "8092"))
MODS_DIR = os.environ.get("LAUNCHY_MODS_DIR", "/mnt/media/Launchy/Ultra/mods")
PUBLIC_BASE = os.environ.get("LAUNCHY_MODS_PUBLIC_BASE", "https://mods.neo-verse.net/ultra/lastest")
TOKEN = os.environ.get("LAUNCHY_MODS_TOKEN", "")
MAX_UPLOAD = 300 * 1024 * 1024

FILENAME_RE = re.compile(r"^[A-Za-z0-9._+\-]{1,160}\.jar$")

_cache = {"key": None, "manifest": None}


def sha1_of(path):
    digest = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest():
    """Scanne le dossier des mods ; le résultat est mis en cache tant que le dossier ne change pas."""
    files = sorted(n for n in os.listdir(MODS_DIR) if n.endswith(".jar") and FILENAME_RE.match(n))
    key = tuple((n, os.stat(os.path.join(MODS_DIR, n)).st_mtime_ns) for n in files)
    if _cache["key"] == key:
        return _cache["manifest"]

    mods = []
    for name in files:
        path = os.path.join(MODS_DIR, name)
        mods.append({
            "name": name,
            "sha1": sha1_of(path),
            "size": os.path.getsize(path),
            "url": f"{PUBLIC_BASE}/files/{name}",
        })
    manifest = {
        "version": hashlib.sha1(json.dumps(mods, sort_keys=True).encode()).hexdigest()[:12],
        "generatedAt": int(time.time()),
        "mods": mods,
    }
    _cache.update(key=key, manifest=manifest)
    return manifest


class Handler(BaseHTTPRequestHandler):
    server_version = "LaunchyMods/1.0"

    def log_message(self, fmt, *args):
        print(f"{self.client_address[0]} {self.command} {self.path} {args[1]}")

    def _send(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, payload):
        self._send(status, json.dumps(payload).encode())

    def do_GET(self):
        path = unquote(self.path.split("?", 1)[0])
        if path == "/ultra/lastest":
            return self._json(200, build_manifest())
        prefix = "/ultra/lastest/files/"
        if path.startswith(prefix):
            name = path[len(prefix):]
            if not FILENAME_RE.match(name):
                return self._json(400, {"error": "invalid_filename"})
            full = os.path.join(MODS_DIR, name)
            if not os.path.isfile(full):
                return self._json(404, {"error": "not_found"})
            with open(full, "rb") as f:
                body = f.read()
            return self._send(200, body, "application/java-archive")
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/ultra/lastest/import":
            return self._json(404, {"error": "not_found"})
        auth = self.headers.get("Authorization", "")
        if not TOKEN or not hmac.compare_digest(auth, f"Bearer {TOKEN}"):
            return self._json(401, {"error": "unauthorized"})

        name = self.headers.get("X-Filename", "")
        if not FILENAME_RE.match(name):
            return self._json(400, {"error": "invalid_filename"})
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0 or length > MAX_UPLOAD:
            return self._json(413, {"error": "bad_size"})

        data = self.rfile.read(length)
        if not data.startswith(b"PK"):
            return self._json(400, {"error": "not_a_jar"})

        # Écriture atomique : fichier temporaire puis renommage.
        fd, tmp = tempfile.mkstemp(dir=MODS_DIR, prefix=".upload-", suffix=".tmp")
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(MODS_DIR, name))
        self._json(201, {"name": name, "size": len(data), "sha1": hashlib.sha1(data).hexdigest()})


def main():
    os.makedirs(MODS_DIR, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Launchy mods en écoute sur {HOST}:{PORT} ({MODS_DIR})")
    server.serve_forever()


if __name__ == "__main__":
    main()
