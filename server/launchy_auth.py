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
import smtplib
import sqlite3
import ssl
import struct
import threading
import time
import urllib.error
import urllib.request
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote
import uuid as uuidlib

HOST = os.environ.get("LAUNCHY_AUTH_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAUNCHY_AUTH_PORT", "8090"))
DB_PATH = os.environ.get("LAUNCHY_AUTH_DB", "/var/lib/launchy-auth/accounts.db")
ADMIN_TOKEN = os.environ.get("LAUNCHY_AUTH_ADMIN_TOKEN", "")
# Vérification des pseudos premium auprès de Mojang. Désactivable avec LAUNCHY_AUTH_PREMIUM_CHECK=off.
PREMIUM_CHECK = os.environ.get("LAUNCHY_AUTH_PREMIUM_CHECK", "on").lower() != "off"
SMTP_HOST = os.environ.get("LAUNCHY_SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("LAUNCHY_SMTP_PORT", "587"))
SMTP_USER = os.environ.get("LAUNCHY_SMTP_USER", "")
SMTP_PASSWORD = os.environ.get("LAUNCHY_SMTP_PASSWORD", "")
SMTP_FROM = os.environ.get("LAUNCHY_SMTP_FROM", "")

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,16}$")
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")
RESET_CODE_TTL = 15 * 60
RESET_MAX_ATTEMPTS = 5
# Pseudos très connus : refusés sauf approbation explicite de l'administrateur.
RESERVED_NAMES = {"notch", "technoblade", "dream", "jeb_", "dls", "grian", "skeppy", "sapnap", "mumbo_jumbo", "xisumavoid"}
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
        CREATE TABLE IF NOT EXISTS reset_codes (
            email_key   TEXT PRIMARY KEY,
            code_hash   TEXT NOT NULL,
            expires_at  INTEGER NOT NULL,
            attempts    INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS approved_names (
            username_key TEXT PRIMARY KEY,
            approved_at  INTEGER NOT NULL
        );
        """
    )
    columns = {row[1] for row in conn.execute("PRAGMA table_info(accounts)")}
    if "email" not in columns:
        # Les anciens comptes n'ont pas d'email : ils devront l'ajouter pour récupérer leur mot de passe.
        conn.execute("ALTER TABLE accounts ADD COLUMN email TEXT")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS accounts_email ON accounts(email)")
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


def send_email(to: str, subject: str, body: str) -> None:
    if not (SMTP_HOST and SMTP_USER and SMTP_PASSWORD and SMTP_FROM):
        raise RuntimeError("SMTP non configuré")
    message = EmailMessage()
    message["From"] = SMTP_FROM
    message["To"] = to
    message["Subject"] = subject
    message.set_content(body)
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as smtp:
        smtp.starttls(context=ssl.create_default_context())
        smtp.login(SMTP_USER, SMTP_PASSWORD)
        smtp.send_message(message)


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
        email = data.get("email", "")
        if not isinstance(username, str) or not isinstance(password, str) or not isinstance(email, str):
            return None
        return username, password, email.strip()

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
        path = self.path.split("?", 1)[0]
        if path == "/auth/forgot":
            return self._forgot()
        if path == "/auth/reset":
            return self._reset()
        if path == "/admin/approve-name":
            return self._approve_name()
        if path not in ("/auth/register", "/auth/login"):
            return self._json(404, {"error": "not_found"})

        if rate_limited(self.client_address[0]):
            return self._json(429, {"error": "too_many_requests"})

        creds = self._read_credentials()
        if creds is None:
            return self._json(400, {"error": "bad_request"})
        username, password, email = creds

        if not USERNAME_RE.match(username):
            return self._json(400, {"error": "invalid_username"})
        if not (MIN_PASSWORD <= len(password) <= MAX_PASSWORD):
            return self._json(400, {"error": "invalid_password"})

        if self.path == "/auth/register":
            if not email or not EMAIL_RE.match(email) or len(email) > 254:
                return self._json(400, {"error": "invalid_email"})
            return self._register(username, password, email.lower())
        return self._login(username, password)

    def _forgot(self):
        """Envoie un code de réinitialisation. Répond toujours pareil pour éviter de révéler les comptes."""
        email = self._read_email()
        if email is None:
            return self._json(400, {"error": "invalid_email"})
        with _db_lock:
            row = db.execute("SELECT 1 FROM accounts WHERE email = ?", (email,)).fetchone()
        if row is not None:
            code = f"{secrets.randbelow(1000000):06d}"
            with _db_lock:
                db.execute(
                    "INSERT INTO reset_codes (email_key, code_hash, expires_at, attempts) VALUES (?, ?, ?, 0) "
                    "ON CONFLICT(email_key) DO UPDATE SET code_hash = excluded.code_hash, "
                    "expires_at = excluded.expires_at, attempts = 0",
                    (email, hashlib.sha256(code.encode()).hexdigest(), int(time.time()) + RESET_CODE_TTL),
                )
                db.commit()
            try:
                send_email(email, "Réinitialisation de votre mot de passe Launchy",
                           f"Votre code de réinitialisation : {code}\n\n"
                           "Il est valable 15 minutes. Si vous n'êtes pas à l'origine de cette demande, ignorez ce message.")
            except Exception as error:
                print(f"envoi email échoué : {error}")
                return self._json(503, {"error": "email_unavailable"})
        self._json(200, {"status": "sent_if_account_exists"})

    def _reset(self):
        body = self._read_body(MAX_BODY)
        try:
            data = json.loads(body or b"{}")
        except (json.JSONDecodeError, UnicodeDecodeError):
            return self._json(400, {"error": "bad_request"})
        email = str(data.get("email", "")).strip().lower()
        code = str(data.get("code", "")).strip()
        password = str(data.get("password", ""))
        if not EMAIL_RE.match(email) or not re.fullmatch(r"\d{6}", code):
            return self._json(400, {"error": "bad_request"})
        if not (MIN_PASSWORD <= len(password) <= MAX_PASSWORD):
            return self._json(400, {"error": "invalid_password"})

        with _db_lock:
            row = db.execute(
                "SELECT code_hash, expires_at, attempts FROM reset_codes WHERE email_key = ?", (email,)
            ).fetchone()
            if row is None or row[2] >= RESET_MAX_ATTEMPTS or row[1] < time.time():
                return self._json(400, {"error": "invalid_or_expired_code"})
            if not hmac.compare_digest(hashlib.sha256(code.encode()).hexdigest(), row[0]):
                db.execute("UPDATE reset_codes SET attempts = attempts + 1 WHERE email_key = ?", (email,))
                db.commit()
                return self._json(400, {"error": "invalid_or_expired_code"})
            account = db.execute("SELECT username_key FROM accounts WHERE email = ?", (email,)).fetchone()
            if account is None:
                return self._json(400, {"error": "invalid_or_expired_code"})
            salt = os.urandom(16)
            db.execute("UPDATE accounts SET salt = ?, pw_hash = ? WHERE username_key = ?",
                       (salt, hash_password(password, salt), account[0]))
            # Déconnecte toutes les sessions de ce compte et consomme le code.
            db.execute("DELETE FROM tokens WHERE username_key = ?", (account[0],))
            db.execute("DELETE FROM reset_codes WHERE email_key = ?", (email,))
            db.commit()
        self._json(200, {"status": "password_changed"})

    def _approve_name(self):
        """Autorise un pseudo réservé. Réservé à l'administrateur (jeton LAUNCHY_AUTH_ADMIN_TOKEN)."""
        auth = self.headers.get("Authorization", "")
        if not ADMIN_TOKEN or not hmac.compare_digest(auth, f"Bearer {ADMIN_TOKEN}"):
            return self._json(401, {"error": "unauthorized"})
        body = self._read_body(MAX_BODY)
        try:
            username = str(json.loads(body or b"{}").get("username", ""))
        except (json.JSONDecodeError, UnicodeDecodeError, AttributeError):
            return self._json(400, {"error": "bad_request"})
        if not USERNAME_RE.match(username):
            return self._json(400, {"error": "invalid_username"})
        with _db_lock:
            db.execute("INSERT OR REPLACE INTO approved_names (username_key, approved_at) VALUES (?, ?)",
                       (username.lower(), int(time.time())))
            db.commit()
        self._json(200, {"approved": username})

    def _read_email(self):
        body = self._read_body(MAX_BODY)
        try:
            email = str(json.loads(body or b"{}").get("email", "")).strip().lower()
        except (json.JSONDecodeError, UnicodeDecodeError, AttributeError):
            return None
        return email if EMAIL_RE.match(email) else None

    def _register(self, username: str, password: str, email: str):
        with _db_lock:
            approved = db.execute("SELECT 1 FROM approved_names WHERE username_key = ?",
                                  (username.lower(),)).fetchone()
        if username.lower() in RESERVED_NAMES and approved is None:
            return self._json(403, {"error": "reserved_name"})
        if PREMIUM_CHECK:
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
                    "INSERT INTO accounts (username_key, username, uuid, salt, pw_hash, created_at, email) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (username.lower(), username, account_uuid, salt,
                     hash_password(password, salt), int(time.time()), email),
                )
                db.commit()
            except sqlite3.IntegrityError as error:
                if "email" in str(error):
                    return self._json(409, {"error": "email_taken"})
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
