"""Service d'authentification Launchy pour les comptes cracks.

Bibliothèque standard uniquement. Écoute en local ; un reverse proxy (nginx)
doit exposer le service en HTTPS.

Routes :
  POST /auth/register  {"username": "...", "password": "..."}  -> 200 / 403 / 409
  POST /auth/login     {"username": "...", "password": "..."}  -> 200 / 401
"""

import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("LAUNCHY_AUTH_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAUNCHY_AUTH_PORT", "8090"))
DB_PATH = os.environ.get("LAUNCHY_AUTH_DB", "/var/lib/launchy-auth/accounts.db")

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,16}$")
MAX_BODY = 4096
MIN_PASSWORD = 8
MAX_PASSWORD = 256

# Limitation simple des tentatives : 10 requêtes d'auth par minute et par IP.
RATE_LIMIT = 10
RATE_WINDOW = 60
_hits: dict[str, list[float]] = {}
_hits_lock = threading.Lock()

_db_lock = threading.Lock()


def db_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute(
        """CREATE TABLE IF NOT EXISTS accounts (
               username_key TEXT PRIMARY KEY,
               username     TEXT NOT NULL,
               uuid         TEXT NOT NULL UNIQUE,
               salt         BLOB NOT NULL,
               pw_hash      BLOB NOT NULL,
               created_at   INTEGER NOT NULL
           )"""
    )
    conn.commit()
    return conn


def hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)


def offline_uuid(username: str) -> str:
    """UUID identique à celui que Minecraft attribue aux comptes hors ligne."""
    return str(uuid.UUID(bytes=hashlib.md5(f"OfflinePlayer:{username}".encode()).digest(), version=3))


def is_premium_name(username: str) -> bool:
    """Demande à Mojang si le pseudo appartient à un compte premium."""
    url = f"https://api.mojang.com/users/profiles/minecraft/{username}"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as err:
        if err.code in (204, 404):
            return False
        raise
    # Une erreur réseau lève une exception : on refuse alors l'inscription.


def rate_limited(ip: str) -> bool:
    now = time.monotonic()
    with _hits_lock:
        recent = [t for t in _hits.get(ip, []) if now - t < RATE_WINDOW]
        recent.append(now)
        _hits[ip] = recent
        return len(recent) > RATE_LIMIT


class Handler(BaseHTTPRequestHandler):
    server_version = "LaunchyAuth/1.0"

    def log_message(self, fmt, *args):
        # Ne jamais journaliser les corps de requête (mots de passe).
        print(f"{self.client_address[0]} {self.command} {self.path} {args[1]}")

    def _send(self, status: int, payload: dict | None = None) -> None:
        body = json.dumps(payload or {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_credentials(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            data = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None
        username = data.get("username")
        password = data.get("password")
        if not isinstance(username, str) or not isinstance(password, str):
            return None
        return username, password

    def do_POST(self):
        if self.path not in ("/auth/register", "/auth/login"):
            return self._send(404, {"error": "not_found"})

        if rate_limited(self.client_address[0]):
            return self._send(429, {"error": "too_many_requests"})

        creds = self._read_credentials()
        if creds is None:
            return self._send(400, {"error": "bad_request"})
        username, password = creds

        if not USERNAME_RE.match(username):
            return self._send(400, {"error": "invalid_username"})
        if not (MIN_PASSWORD <= len(password) <= MAX_PASSWORD):
            return self._send(400, {"error": "invalid_password"})

        if self.path == "/auth/register":
            return self._register(username, password)
        return self._login(username, password)

    def _register(self, username: str, password: str):
        try:
            if is_premium_name(username):
                return self._send(403, {"error": "premium_name"})
        except Exception:
            return self._send(503, {"error": "premium_check_unavailable"})

        salt = os.urandom(16)
        account_uuid = offline_uuid(username)
        with _db_lock:
            try:
                db.execute(
                    "INSERT INTO accounts (username_key, username, uuid, salt, pw_hash, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (username.lower(), username, account_uuid, salt,
                     hash_password(password, salt), int(time.time())),
                )
                db.commit()
            except sqlite3.IntegrityError:
                return self._send(409, {"error": "username_taken"})
        self._send(200, {"username": username, "uuid": account_uuid})

    def _login(self, username: str, password: str):
        with _db_lock:
            row = db.execute(
                "SELECT username, uuid, salt, pw_hash FROM accounts WHERE username_key = ?",
                (username.lower(),),
            ).fetchone()

        # Toujours calculer le hash, même si le compte n'existe pas (temps constant).
        if row is None:
            hash_password(password, os.urandom(16))
            return self._send(401, {"error": "invalid_credentials"})

        stored_name, stored_uuid, salt, pw_hash = row
        if not hmac.compare_digest(hash_password(password, salt), pw_hash):
            return self._send(401, {"error": "invalid_credentials"})
        self._send(200, {"username": stored_name, "uuid": stored_uuid})


def main() -> None:
    global db
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db = db_connect()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Launchy auth en écoute sur {HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
