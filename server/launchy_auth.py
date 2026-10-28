"""Service d'authentification et de skins Launchy pour les comptes cracks.

Bibliothèque standard uniquement. Écoute en local ; un reverse proxy (tunnel Cloudflare)
l'expose en HTTPS.

Routes :
  POST /auth/register   {"username", "password"}      -> 200 {username, uuid, token} / 403 / 409
  POST /auth/login      {"username", "password"}      -> 200 {username, uuid, token} / 401
  PUT  /auth/skin       PNG brut, Authorization: Bearer <token>  -> 200 / 401 / 400
  GET  /skins/<pseudo>.png                            -> skin public, 404 si absent
"""

import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import struct
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote
import uuid as uuidlib

HOST = os.environ.get("LAUNCHY_AUTH_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAUNCHY_AUTH_PORT", "8090"))
DB_PATH = os.environ.get("LAUNCHY_AUTH_DB", "/var/lib/launchy-auth/accounts.db")

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,16}$")
MAX_BODY = 4096
MAX_SKIN = 64 * 1024
MIN_PASSWORD = 8
MAX_PASSWORD = 256
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Limitation simple des tentatives : 10 requêtes d'auth par minute et par IP.
RATE_LIMIT = 10
RATE_WINDOW = 60
_hits: dict[str, list[float]] = {}
_hits_lock = threading.Lock()

_db_lock = threading.Lock()
db: sqlite3.Connection


def db_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS accounts (
            username_key TEXT PRIMARY KEY,
            username     TEXT NOT NULL,
            uuid         TEXT NOT NULL UNIQUE,
            salt         BLOB NOT NULL,
            pw_hash      BLOB NOT NULL,
            created_at   INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tokens (
            token_hash   TEXT PRIMARY KEY,
            username_key TEXT NOT NULL,
            created_at   INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS skins (
            username_key TEXT PRIMARY KEY,
            png          BLOB NOT NULL,
            updated_at   INTEGER NOT NULL
        );
        """
    )
    conn.commit()
    return conn


def hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)


def offline_uuid(username: str) -> str:
    """UUID identique à celui que Minecraft attribue aux comptes hors ligne."""
    return str(uuidlib.UUID(bytes=hashlib.md5(f"OfflinePlayer:{username}".encode()).digest(), version=3))


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


def new_token(username_key: str) -> str:
    token = secrets.token_urlsafe(32)
    with _db_lock:
        db.execute(
            "INSERT INTO tokens (token_hash, username_key, created_at) VALUES (?, ?, ?)",
            (hashlib.sha256(token.encode()).hexdigest(), username_key, int(time.time())),
        )
        db.commit()
    return token


def username_for_token(token: str) -> str | None:
    with _db_lock:
        row = db.execute(
            "SELECT username_key FROM tokens WHERE token_hash = ?",
            (hashlib.sha256(token.encode()).hexdigest(),),
        ).fetchone()
    return row[0] if row else None


def is_png_skin(data: bytes) -> bool:
    """Accepte un PNG 64x64 (ou 64x32, ancien format) qui commence par la signature PNG."""
    if not data.startswith(PNG_SIGNATURE) or data[12:16] != b"IHDR":
        return False
    width, height = struct.unpack(">II", data[16:24])
    return width == 64 and height in (32, 64)


def rate_limited(ip: str) -> bool:
    now = time.monotonic()
    with _hits_lock:
        recent = [t for t in _hits.get(ip, []) if now - t < RATE_WINDOW]
        recent.append(now)
        _hits[ip] = recent
        return len(recent) > RATE_LIMIT


class Handler(BaseHTTPRequestHandler):
    server_version = "LaunchyAuth/1.1"

    def log_message(self, fmt, *args):
        # Ne jamais journaliser les corps de requête (mots de passe, skins).
        print(f"{self.client_address[0]} {self.command} {self.path} {args[1]}")

    def _send(self, status: int, body: bytes = b"", content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        self._send(status, json.dumps(payload).encode())

    def _read_body(self, limit: int) -> bytes | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > limit:
            return None
        return self.rfile.read(length)

    def _read_credentials(self):
        body = self._read_body(MAX_BODY)
        if body is None:
            return None
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None
        username = data.get("username")
        password = data.get("password")
        if not isinstance(username, str) or not isinstance(password, str):
            return None
        return username, password

    def _bearer_user(self) -> str | None:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        return username_for_token(auth[len("Bearer "):])

    def do_GET(self):
        path = unquote(self.path.split("?", 1)[0])
        if path.startswith("/skins/") and path.endswith(".png"):
            name = path[len("/skins/"):-len(".png")]
            if not USERNAME_RE.match(name):
                return self._json(400, {"error": "invalid_username"})
            with _db_lock:
                row = db.execute("SELECT png FROM skins WHERE username_key = ?", (name.lower(),)).fetchone()
            if row is None:
                return self._json(404, {"error": "not_found"})
            return self._send(200, row[0], "image/png")
        self._json(404, {"error": "not_found"})

    def do_PUT(self):
        if self.path.split("?", 1)[0] != "/auth/skin":
            return self._json(404, {"error": "not_found"})
        username_key = self._bearer_user()
        if username_key is None:
            return self._json(401, {"error": "unauthorized"})
        data = self._read_body(MAX_SKIN)
        if data is None or not is_png_skin(data):
            return self._json(400, {"error": "invalid_skin"})
        with _db_lock:
            db.execute(
                "INSERT INTO skins (username_key, png, updated_at) VALUES (?, ?, ?) "
                "ON CONFLICT(username_key) DO UPDATE SET png = excluded.png, updated_at = excluded.updated_at",
                (username_key, data, int(time.time())),
            )
            db.commit()
        self._json(200, {"username": username_key, "size": len(data)})

    def do_POST(self):
        if self.path not in ("/auth/register", "/auth/login"):
            return self._json(404, {"error": "not_found"})

        if rate_limited(self.client_address[0]):
            return self._json(429, {"error": "too_many_requests"})

        creds = self._read_credentials()
        if creds is None:
            return self._json(400, {"error": "bad_request"})
        username, password = creds

        if not USERNAME_RE.match(username):
            return self._json(400, {"error": "invalid_username"})
        if not (MIN_PASSWORD <= len(password) <= MAX_PASSWORD):
            return self._json(400, {"error": "invalid_password"})

        if self.path == "/auth/register":
            return self._register(username, password)
        return self._login(username, password)

    def _register(self, username: str, password: str):
        try:
            if is_premium_name(username):
                return self._json(403, {"error": "premium_name"})
        except Exception:
            return self._json(503, {"error": "premium_check_unavailable"})

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
                return self._json(409, {"error": "username_taken"})
        token = new_token(username.lower())
        self._json(200, {"username": username, "uuid": account_uuid, "token": token})

    def _login(self, username: str, password: str):
        with _db_lock:
            row = db.execute(
                "SELECT username, uuid, salt, pw_hash FROM accounts WHERE username_key = ?",
                (username.lower(),),
            ).fetchone()

        # Toujours calculer le hash, même si le compte n'existe pas (temps constant).
        if row is None:
            hash_password(password, os.urandom(16))
            return self._json(401, {"error": "invalid_credentials"})

        stored_name, stored_uuid, salt, pw_hash = row
        if not hmac.compare_digest(hash_password(password, salt), pw_hash):
            return self._json(401, {"error": "invalid_credentials"})
        token = new_token(username.lower())
        self._json(200, {"username": stored_name, "uuid": stored_uuid, "token": token})


def main() -> None:
    global db
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db = db_connect()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Launchy auth en écoute sur {HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
