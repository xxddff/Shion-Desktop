"""Pictures and files for the CI stand-in (fake_hermes.py), for MediaTests. Shaped like Hermes
(main 927dba28): hermes_cli/web_routers/files.py and uploads.py, gateway/session_ancillary.py
(file.attach), gateway/session_ingress_media.py (prompt.submit's attachments):

  POST     /api/chat/image-upload?profile=      {data_url, filename} -> {ok, path, name, bytes, mime_type};
                                                  sniffed PNG/JPEG/GIF/WebP/BMP, 25 MiB, into <home>/cache/images/
  POST     /api/chat/file-upload?profile=       multipart `file` -> {ok, path, size, staged_upload}; 16 MiB,
                                                  into <home>/uploads/web-<16 hex>-<ASCII name>
  GET      /api/fs/read-data-url?path=&profile=&session_id=   -> {dataUrl}; 16 MiB, else 413; ETag
  GET|HEAD /api/fs/download?path=&profile=&session_id=        -> the file, as an attachment
  rpc      file.attach {session_id, profile, name, data_url | staged_upload | path}
           -> {attached, name, path, ref_path, ref_text, uploaded}; the session must be resumed on
           this connection (permission_denied otherwise), unknown keys are invalid_params
  prompt.submit's attachments: [{path, mime}] exactly, mime PNG/JPEG/GIF/WebP, at most 10, each a
           file directly in the profile's cache/images/ (invalid_params otherwise); taken in as
           cache/documents/native-inputs/<sha256>/<name>, and the user row stored as Hermes stores it:
           the words (or its own caption), a blank line, "[Image attached at: <path>]" a line each,
           then "[screenshot]" per picture

Server paths are under the stand-in's Hermes home, as fake_profiles.py names it: the default
profile at /ci/.hermes, the others (詩音 among them) at /ci/.hermes/profiles/<name>; the bytes live in
a temporary folder. Every route checks the bearer.

Turns, by the words sent:
  - pictures arrive: the reply says what each is (format, size, whether it holds a location or other
    EXIF metadata), so the test sees what Shion made of the picture before sending it
  - @file: references: the reply names each file and its size, as the server has it; the same words
    again (a retry, once 重试 has rewound the turn) get a reply marked 「（重试）」
  - 「截个图（CI）」: a browser call whose tool.complete carries image_path; once Shion has read the
    screenshot, the stand-in clears it, as Hermes's 24-hour sweep would, so later the chat can only
    show the Mac's copy
  - 「把课件发给我（CI）」: MEDIA: tags for a PDF and a picture, a path written in the words, and a web
    picture, W3C's logo (its old address redirects within w3.org): Shion fetches it from the web
    itself, never through here, and only once it is clicked
Stdlib only.
"""
import base64
import hashlib
import itertools
import json
import os
import re
import secrets
import shutil
import struct
import tempfile
import threading
import time
import urllib.parse
import zlib

ROOT = "/ci/.hermes"
INSTALL_ID = "ci-install"
STORE = tempfile.mkdtemp(prefix="fake-hermes-media-")
PICTURE_LIMIT = 25 * 1024 * 1024
FILE_LIMIT = 16 * 1024 * 1024
DATA_URL_LIMIT = 16 * 1024 * 1024
MIMES = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp"}
POSTS = {"/api/chat/image-upload", "/api/chat/file-upload"}
ATTACH_KEYS = {"session_id", "profile", "path", "data_url", "name", "staged_upload"}
DEFAULT_CAPTION = "What do you see in this image?"

lock = threading.Lock()
_log = print
_valid = lambda token: False  # noqa: E731
# fake_hermes.py's transcripts and their lock: it runs as __main__, so importing it would make a
# second copy of them
_transcripts, _transcript_lock = {}, threading.Lock()
failed_once = set()  # files whose first file.attach was refused
sent_texts = set()  # words with @file: lines seen before: a retry sends them again
row_ids = itertools.count(2001)  # never one twice, rewound or not, as a database's ids
# The files MediaTests pastes (names and sizes as MediaTests.swift expects them). The stand-in
# makes them: the UI test runner is sandboxed and cannot write outside its own container, and
# Shion would have to ask before reading another app's container. /tmp needs neither.
PASTED = "/tmp/shion-media-ci"
PASTED_FILES = (("ci-报告（CI）.pdf", 40_000), ("ci-大文件（CI）.pdf", 3 * 1024 * 1024), ("ci-重试（CI）.txt", 1_200))


def setup(log, valid_access, transcripts, transcript_lock):
    global _log, _valid, _transcripts, _transcript_lock
    _log, _valid = log, valid_access
    _transcripts, _transcript_lock = transcripts, transcript_lock
    shutil.rmtree(PASTED, ignore_errors=True)
    os.makedirs(PASTED)
    for name, size in PASTED_FILES:
        with open(os.path.join(PASTED, name), "wb") as handle:
            handle.write(b"x" * size)


# ---- paths ---------------------------------------------------------------------------------

def home(profile):
    """A profile's home on the server, as Hermes names it in a container."""
    if profile in (None, "", "current", "default"):
        return ROOT
    return f"{ROOT}/profiles/{profile}"


def real(path):
    """The stand-in's file for a server path under ROOT."""
    if not path.startswith(ROOT + "/"):
        return None
    return os.path.join(STORE, os.path.relpath(path, ROOT))


def server_path(profile, *parts):
    return "/".join([home(profile), *parts])


def write(path, data):
    target = real(path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "wb") as handle:
        handle.write(data)
    return path


def resolve(raw, profile, session_id, conn):
    """A request's path as files.py resolves it: absolute, or relative to the session's directory
    (the profile's home here); `..` refused, and a session_id must be the profile's."""
    if not raw or ".." in raw.split("/"):
        return None, (400, "Invalid path")
    if session_id is not None and session_id != f"sess-{profile}":
        return None, (404, "Session not found")
    path = raw if raw.startswith("/") else f"{home(profile)}/{raw}"
    name = os.path.basename(path)
    if name.startswith(".env") or name in ("auth.json", "config.yaml"):
        return None, (403, "Access to credential files is not allowed")
    target = real(path)
    if target is None or not os.path.isfile(target):
        return None, (404, "File not found")
    return (path, target), None


# ---- pictures and files the turns hand over --------------------------------------------------

def png(width, height, colour):
    """A PNG of one colour with a darker band across the middle."""
    r, g, b = colour
    rows = []
    for y in range(height):
        band = height // 3 <= y < 2 * height // 3
        pixel = bytes((r // 2, g // 2, b // 2) if band else (r, g, b))
        rows.append(b"\x00" + pixel * width)
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


PDF = (b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 0/Kids[]>>endobj\n"
       b"trailer<</Root 1 0 R>>\n%%EOF\n") + b"%" * 12000


def seed(profile):
    """What 「把课件发给我」 hands over, in that profile's home."""
    slides = server_path(profile, "attachments", "第8回课件（CI）.pdf")
    chart = server_path(profile, "cache", "generated", "images", "ci-chart.png")
    data = server_path(profile, "attachments", "ci-data.csv")
    write(slides, PDF)
    write(chart, png(480, 300, (70, 120, 210)))
    write(data, "日期,站,延误（分）\n11-09,新宿,8\n".encode())
    return slides, chart, data


# ---- what a picture holds -------------------------------------------------------------------

def sniff(data):
    """files.py's magic: the extension the bytes really are."""
    head = data[:16]
    if head.startswith(b"RIFF") and head[8:12] == b"WEBP":
        return ".webp"
    for magic, ext in ((b"\x89PNG\r\n\x1a\n", ".png"), (b"\xff\xd8\xff", ".jpg"), (b"GIF87a", ".gif"),
                       (b"GIF89a", ".gif"), (b"BM", ".bmp")):
        if head.startswith(magic):
            return ext
    return None


def describe(data):
    """(format, width, height, has a location, says when or with what it was taken), from the headers."""
    if data.startswith(b"\x89PNG"):
        width, height = struct.unpack(">II", data[16:24])
        return "PNG", width, height, False, b"eXIf" in data[:4096]
    if data.startswith(b"\xff\xd8"):
        width = height = 0
        gps = shot = False
        index = 2
        while index + 4 <= len(data):
            if data[index] != 0xFF:
                break
            marker = data[index + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                index += 2
                continue
            length = struct.unpack(">H", data[index + 2:index + 4])[0]
            segment = data[index + 4:index + 2 + length]
            if marker == 0xE1 and segment.startswith(b"Exif\x00\x00"):
                gps, shot = exif_tags(segment[6:])
            if marker in (0xC0, 0xC1, 0xC2):
                height, width = struct.unpack(">HH", segment[1:5])
            if marker == 0xDA:
                break
            index += 2 + length
        return "JPEG", width, height, gps, shot
    if data[:6] in (b"GIF87a", b"GIF89a"):
        width, height = struct.unpack("<HH", data[6:10])
        return "GIF", width, height, False, False
    return "其他", 0, 0, False, False


def ifd_tags(tiff, order, offset):
    """{tag: value field} of the IFD at `offset`."""
    if offset + 2 > len(tiff):
        return {}
    tags = {}
    count = struct.unpack(order + "H", tiff[offset:offset + 2])[0]
    for entry in range(count):
        start = offset + 2 + entry * 12
        if start + 12 <= len(tiff):
            tag = struct.unpack(order + "H", tiff[start:start + 2])[0]
            tags[tag] = struct.unpack(order + "I", tiff[start + 8:start + 12])[0]
    return tags


def exif_tags(tiff):
    """(a GPS block, when or with what it was taken: Make, Model, DateTime, DateTimeOriginal)."""
    if len(tiff) < 8:
        return False, False
    order = "<" if tiff[:2] == b"II" else ">"
    first = ifd_tags(tiff, order, struct.unpack(order + "I", tiff[4:8])[0])
    exif = ifd_tags(tiff, order, first[0x8769]) if 0x8769 in first else {}
    shot = bool({0x010F, 0x0110, 0x0132} & set(first) or {0x9003, 0x9004} & set(exif))
    return 0x8825 in first, shot


# ---- HTTP -----------------------------------------------------------------------------------

def respond(conn, status, body=b"", content_type="application/json", headers=(), head=False):
    if isinstance(body, (dict, list)):
        body = json.dumps(body, ensure_ascii=False).encode()
    conn.send_response(status)
    conn.send_header("Content-Type", content_type)
    conn.send_header("Content-Length", str(len(body)))
    for name, value in headers:
        conn.send_header(name, value)
    conn.end_headers()
    if not head:
        conn.wfile.write(body)
    _log(f"  -> {status}")


def authorized(conn):
    bearer = conn.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    return _valid(bearer)


def route(conn, method, url, query):
    """Every request under /api/fs/ and the two upload routes."""
    if not authorized(conn):
        return respond(conn, 401, {"detail": "Unauthorized"}, head=method == "HEAD")
    if method == "POST" and url.path == "/api/chat/image-upload":
        return upload_picture(conn, query)
    if method == "POST" and url.path == "/api/chat/file-upload":
        return upload_file(conn, query)
    if url.path == "/api/fs/read-data-url" and method == "GET":
        return read_data_url(conn, query)
    if url.path == "/api/fs/download" and method in ("GET", "HEAD"):
        return download(conn, query, head=method == "HEAD")
    respond(conn, 404, {"detail": "Not Found"}, head=method == "HEAD")


def read_body(conn):
    length = int(conn.headers.get("Content-Length") or 0)
    data = b""
    while len(data) < length:
        chunk = conn.rfile.read(length - len(data))
        if not chunk:
            break
        data += chunk
    return data


def upload_picture(conn, query):
    body = read_body(conn)
    if len(body) > 4 * -(-PICTURE_LIMIT // 3) + 64 * 1024:
        return respond(conn, 413, {"detail": "Image is too large; cap is 25 MB"})
    try:
        payload = json.loads(body)
    except ValueError:
        return respond(conn, 422, {"detail": "body is not JSON"})
    if set(payload) - {"data_url", "filename"} or not isinstance(payload.get("data_url"), str):
        return respond(conn, 422, {"detail": "expected {data_url, filename}"})
    text = payload["data_url"].strip()
    if not text.startswith("data:") or "," not in text:
        return respond(conn, 400, {"detail": "Upload payload must be a data URL"})
    header, encoded = text.split(",", 1)
    mime = header[5:].split(";", 1)[0] or "application/octet-stream"
    if ";base64" not in header:
        return respond(conn, 400, {"detail": "Upload payload must be base64 encoded"})
    try:
        data = base64.b64decode(encoded, validate=True)
    except ValueError:
        return respond(conn, 400, {"detail": "Upload payload is not valid base64"})
    if not mime.lower().startswith("image/"):
        return respond(conn, 400, {"detail": "Upload payload must be an image"})
    if len(data) > PICTURE_LIMIT:
        return respond(conn, 413, {"detail": "Image is too large; cap is 25 MB"})
    ext = sniff(data)
    if ext is None:
        return respond(conn, 400, {"detail": "Unsupported image type"})
    stem = os.path.splitext(os.path.basename(str(payload.get("filename") or "")))[0]
    stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", stem).strip("._-") or "pasted-image"
    profile = query.get("profile")
    name = f"dashboard_{time.strftime('%Y%m%d_%H%M%S')}_{secrets.token_hex(4)}_{stem}{ext}"
    path = write(server_path(profile, "cache", "images", name), data)
    kind, width, height, gps, shot = describe(data)
    _log(f"    image-upload for {profile}: {kind} {width}x{height}, {len(data)} bytes, "
         f"location={'yes' if gps else 'no'} camera/time={'yes' if shot else 'no'}, sent as {mime}")
    respond(conn, 200, {"ok": True, "path": path, "name": name, "bytes": len(data), "mime_type": mime})


def multipart_file(conn):
    """The `file` part of a multipart body: (filename, bytes), or None."""
    match = re.search(r'boundary="?([^";]+)"?', conn.headers.get("Content-Type", ""))
    if not match:
        return None
    boundary = b"--" + match.group(1).encode()
    for part in read_body(conn).split(boundary):
        head, _, data = part.partition(b"\r\n\r\n")
        disposition = head.decode("utf-8", "replace")
        if 'name="file"' not in disposition:
            continue
        name = re.search(r'filename="([^"]*)"', disposition)
        return (name.group(1) if name else "attachment"), data[:-2] if data.endswith(b"\r\n") else data
    return None


def safe_ascii(value):
    """staged_uploads.py's _safe_filename: ASCII letters, digits and ._- only."""
    stem, suffix = os.path.splitext(value or "attachment")
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip(".-") or "attachment"
    suffix = re.sub(r"[^A-Za-z0-9._-]+", "-", suffix).rstrip(".-")[:119]
    return stem[:120 - len(suffix)] + suffix


def upload_file(conn, query):
    if int(conn.headers.get("Content-Length") or 0) > FILE_LIMIT + 64 * 1024:
        read_body(conn)
        return respond(conn, 413, {"detail": "File is too large; cap is 16 MiB"})
    found = multipart_file(conn)
    if found is None:
        return respond(conn, 422, {"detail": "no file part"})
    filename, data = found
    if len(data) > FILE_LIMIT:
        return respond(conn, 413, {"detail": "File is too large; cap is 16 MiB"})
    profile = query.get("profile")
    path = write(server_path(profile, "uploads", f"web-{secrets.token_hex(8)}-{safe_ascii(filename)}"), data)
    _log(f"    file-upload for {profile}: {filename!r} -> {os.path.basename(path)}, {len(data)} bytes")
    respond(conn, 200, {"ok": True, "path": path, "size": len(data),
                        "staged_upload": {"install_id": INSTALL_ID, "path": path, "profile_home": home(profile)}})


def read_data_url(conn, query):
    found, problem = resolve(query.get("path", ""), query.get("profile"), query.get("session_id"), conn)
    if problem:
        return respond(conn, problem[0], {"detail": problem[1]})
    path, target = found
    size = os.path.getsize(target)
    if size > DATA_URL_LIMIT:
        return respond(conn, 413, {"detail": "File too large"})
    with open(target, "rb") as handle:
        data = handle.read()
    etag = '"' + hashlib.sha256(f"{path}\0{size}\0{os.path.getmtime(target)}".encode()).hexdigest()[:32] + '"'
    if etag in conn.headers.get("If-None-Match", ""):
        return respond(conn, 304, headers=[("ETag", etag), ("Cache-Control", "private, no-cache")])
    mime = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
            ".webp": "image/webp"}.get(os.path.splitext(target)[1].lower(), "application/octet-stream")
    _log(f"    read-data-url {path} ({size} bytes) for {query.get('profile')} in {query.get('session_id')}")
    respond(conn, 200, {"dataUrl": f"data:{mime};base64,{base64.b64encode(data).decode()}"},
            headers=[("ETag", etag), ("Cache-Control", "private, no-cache")])
    if "/cache/screenshots/" in path:
        # Hermes clears its screenshots after a day; here, once Shion has its copy
        with lock:
            if os.path.exists(target):
                os.remove(target)
        _log(f"    cleared {path}: from now on only the Mac has it")


def download(conn, query, head=False):
    found, problem = resolve(query.get("path", ""), query.get("profile"), query.get("session_id"), conn)
    if problem:
        return respond(conn, problem[0], {"detail": problem[1]}, head=head)
    path, target = found
    with open(target, "rb") as handle:
        data = handle.read()
    name = os.path.basename(target)
    _log(f"    download{' (HEAD)' if head else ''} {path} ({len(data)} bytes) for {query.get('profile')}")
    respond(conn, 200, data, "application/octet-stream", head=head, headers=[
        ("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(name))])


# ---- the socket -----------------------------------------------------------------------------

def refuse(conn, rid, reason, fields=()):
    _log(f"    {reason} {list(fields)}")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {
        "code": 4001, "message": reason, "data": {"reason": reason, "fields": list(fields)}}})


def ref_value(value):
    """prompt_attachments.py's _format_ref_value: quoted when it holds spaces, brackets or quotes."""
    if not re.search(r"""[\s()\[\]{}<>"'`]""", value):
        return value
    for quote in ("`", '"', "'"):
        if quote not in value:
            return f"{quote}{value}{quote}"
    return value


def attach(conn, rid, params):
    """file.attach, as gateway/session_ancillary.py takes it."""
    staged = params.get("staged_upload")
    if (set(params) - ATTACH_KEYS or not params.get("session_id")
            or any(not isinstance(v, str) for k, v in params.items() if k != "staged_upload")
            or (staged is not None and not isinstance(staged, dict))):
        return refuse(conn, rid, "invalid_params", sorted(set(params) - ATTACH_KEYS))
    if params["session_id"] not in getattr(conn, "subscribed", set()):
        return refuse(conn, rid, "permission_denied")
    profile = params.get("profile")
    if "重试" in params.get("name", ""):
        # a file whose first try fails, as a full disk would (storage_unavailable): Shion offers a retry
        with lock:
            first = params["name"] not in failed_once
            failed_once.add(params["name"])
        if first:
            return refuse(conn, rid, "storage_unavailable")
    if staged is not None:
        if staged.get("install_id") != INSTALL_ID or staged.get("profile_home") != home(profile):
            return refuse(conn, rid, "invalid_params", ["staged_upload"])
        source = real(staged.get("path", ""))
        if source is None or not os.path.isfile(source):
            return refuse(conn, rid, "invalid_params", ["staged_upload"])
        with open(source, "rb") as handle:
            data = handle.read()
        # the staged copy's own name: Hermes reads it from the path, not from `name`
        name = os.path.basename(source)
        how = "staged upload"
    elif params.get("path"):
        return refuse(conn, rid, "invalid_params", ["path: Shion sends the bytes, never a server path"])
    else:
        match = re.match(r"^data:[^;,]*(?:;[^;,=]+=[^;,]+)*;base64,(.*)$", params.get("data_url", ""), re.S | re.I)
        if not match:
            return refuse(conn, rid, "invalid_params", ["data_url"])
        data = base64.b64decode(match.group(1))
        name = re.sub(r"[\x00-\x1f]+", "_", os.path.basename(params.get("name", "").strip())).strip().strip(".")
        name = name or "attachment"
        how = "data_url"
    stem, suffix = os.path.splitext(name)
    candidate, number = name, 2
    while os.path.exists(real(server_path(profile, "attachments", candidate))):
        candidate = f"{stem}-{number}{suffix}"
        number += 1
    path = write(server_path(profile, "attachments", candidate), data)
    ref_path = f"attachments/{candidate}"
    _log(f"    file.attach ({how}) {params.get('name')!r} -> {ref_path}, {len(data)} bytes")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {
        "attached": True, "name": candidate, "path": path, "ref_path": ref_path,
        "ref_text": f"@file:{ref_value(ref_path)}", "uploaded": True}})


def take_in(attachments, profile):
    """prompt.submit's attachments, as session_ingress_media.py admits them: (paths, error fields)."""
    if attachments is None:
        return [], None
    if (not isinstance(attachments, list) or not attachments or len(attachments) > 10
            or any(not isinstance(a, dict) or set(a) != {"path", "mime"} or not isinstance(a["path"], str)
                   or a["mime"] not in MIMES for a in attachments)):
        return None, ["attachments"]
    staging = server_path(profile, "cache", "images")
    taken = []
    for item in attachments:
        path = item["path"]
        target = real(path)
        if not path.startswith("/") or os.path.dirname(path) != staging or target is None or not os.path.isfile(target):
            return None, ["attachments.path"]
        with open(target, "rb") as handle:
            data = handle.read()
        digest = hashlib.sha256(data).hexdigest()
        kept = write(server_path(profile, "cache", "documents", "native-inputs", digest, os.path.basename(path)), data)
        taken.append((kept, data))
    return taken, None


REF = re.compile(r"""^@(file|folder):(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)$""")


def refs(text, profile):
    """The @file: lines the words start with, and the rest."""
    lines, files = text.split("\n"), []
    while lines and REF.match(lines[0].rstrip()):
        value = REF.match(lines.pop(0).rstrip()).group(2)
        if value[:1] in "`\"'" and value[-1:] == value[:1]:
            value = value[1:-1]
        files.append(value if value.startswith("/") else f"{home(profile)}/{value}")
    return files, "\n".join(lines).strip()


def submit(conn, rid, params):
    """Takes prompt.submit when it carries pictures or files, or asks for this module's turns."""
    text = params.get("text", "")
    attachments = params.get("attachments")
    if attachments is None and not text.startswith("@file:") and "截个图（CI）" not in text and "把课件发给我（CI）" not in text:
        return False
    session_id, profile = params.get("session_id"), params.get("profile")
    taken, bad = take_in(attachments, profile)
    if bad:
        refuse(conn, rid, "invalid_params", bad)
        return True
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {"accepted": True}})
    if "截个图（CI）" in text:
        threading.Thread(target=screenshot_turn, args=(conn, session_id, profile, params), daemon=True).start()
        return True
    if "把课件发给我（CI）" in text:
        threading.Thread(target=media_turn, args=(conn, session_id, profile, params), daemon=True).start()
        return True
    files, words = refs(text, profile)
    again = bool(files) and text in sent_texts
    if files:
        sent_texts.add(text)
    stored = text
    lines = []
    if taken:
        caption = text or DEFAULT_CAPTION
        stored = f"{caption}\n\n" + "\n".join(f"[Image attached at: {path}]" for path, _ in taken) \
            + "".join("\n[screenshot]" for _ in taken)
        for path, data in taken:
            kind, width, height, gps, shot = describe(data)
            lines.append(f"{kind} {width}×{height}，{'有' if gps else '没有'}位置信息，{'有' if shot else '没有'}拍摄信息")
        lines.insert(0, f"收到 {len(taken)} 张图：")
    for path in files:
        target = real(path)
        size = os.path.getsize(target) if target and os.path.isfile(target) else None
        lines.append(f"收到文件：{os.path.basename(path)}（{size} 字节）" if size is not None
                     else f"找不到文件：{path}")
    if words and words != DEFAULT_CAPTION:
        lines.append(f"你说：{words}")
    reply = "\n\n".join(lines) if lines else "收到。"
    if again:
        reply = "（重试）" + reply
    ids = store_turn(session_id, [{"role": "user", "text": stored}, {"role": "assistant", "text": reply}])
    _log(f"    stored the user row as {stored!r}")
    conn.event("message.start", session_id, {})
    conn.event("message.delta", session_id, {"text": reply})
    conn.event("message.complete", session_id, {"text": reply, "status": "complete",
                                                "persisted_turn": persisted(params, ids)})
    return True


def store_turn(session_id, rows):
    """The rows a turn stores; the ids it gave the ones that have one (tool rows have none)."""
    ids = []
    with _transcript_lock:
        stored = _transcripts.setdefault(session_id, [])
        for row in rows:
            if row.get("role") != "tool":
                row["row_id"] = next(row_ids)
                ids.append(row["row_id"])
            stored.append({"row_kind": "message", "timestamp": time.time(), **row})
    return ids


def persisted(params, ids):
    """message.complete's persisted_turn, as Hermes ends a turn (agent/persisted_turn_receipt.py):
    the rows it stored, the prompt's first, and the submitter's own id for it."""
    return {"row_ids": ids, "complete": True, "user_row_id": ids[0], "user_row_ids": ids[:1],
            "final_assistant_row_id": ids[-1], "submission_id": params.get("submission_id")}


def screenshot_turn(conn, session_id, profile, params):
    """A browser call that took a screenshot: image_path on tool.complete, as a local viewer turn has
    it (gateway/local_viewer_events.py); the transcript keeps the call without it."""
    call, name, context = "call-ci-shot", "browser_navigate", "ci.example/login（CI）"
    shot = write(server_path(profile, "cache", "screenshots", "ci-login.png"), png(640, 400, (230, 140, 60)))
    reply = "截好了：登录页上写着要两步验证。"
    ids = store_turn(session_id, [
        {"role": "user", "text": params.get("text", "")},
        {"role": "tool", "name": name, "context": context, "args": {"url": "https://ci.example/login"},
         "tool_call_id": call},
        {"role": "assistant", "text": reply},
    ])
    try:
        conn.event("message.start", session_id, {})
        time.sleep(0.4)
        conn.event("tool.start", session_id, {"tool_id": call, "name": name, "context": context,
                                              "args": {"url": "https://ci.example/login"}})
        time.sleep(0.4)
        conn.event("tool.complete", session_id, {
            "tool_id": call, "name": name, "image_path": shot,
            "result": json.dumps({"ok": True, "screenshot_path": shot})})
        conn.event("message.delta", session_id, {"text": reply})
        conn.event("message.complete", session_id, {"text": reply, "status": "complete",
                                                    "persisted_turn": persisted(params, ids)})
        _log(f"  -> screenshot turn on {session_id}: image_path {shot}")
    except OSError:
        pass


def media_turn(conn, session_id, profile, params):
    """A reply handing files over as a desktop session's assistant is told to (MEDIA:<path>, a line
    each), with a path written in passing and a web picture (a real one: the test clicks it)."""
    slides, chart, data = seed(profile)
    reply = (f"第8回的课件和这周的延误图都在这里：\n\nMEDIA:{slides}\nMEDIA:{chart}\n\n"
             f"原始数据我放在 {data} 了。\n\n![网上找的示例图](https://www.w3.org/Icons/w3c_home.png)")
    ids = store_turn(session_id, [{"role": "user", "text": params.get("text", "")},
                                  {"role": "assistant", "text": reply}])
    try:
        conn.event("message.start", session_id, {})
        for part in reply.split("\n\n"):
            time.sleep(0.2)
            conn.event("message.delta", session_id, {"text": part + "\n\n"})
        conn.event("message.complete", session_id, {"text": reply, "status": "complete",
                                                    "persisted_turn": persisted(params, ids)})
        _log(f"  -> media turn on {session_id}: {os.path.basename(slides)}, {os.path.basename(chart)}, written path")
    except OSError:
        pass


def cleanup():
    shutil.rmtree(STORE, ignore_errors=True)
    shutil.rmtree(PASTED, ignore_errors=True)
