"""Hermes's profiles, as the CI stand-in (fake_hermes.py) serves them, for BotsTests.

Shaped like the routes Shion's assistant pages use, with their refusals:

  socket   profiles.list       gateway/session_group_controls.py: the gateway's own profile first,
                               then the others, metadata only (model and provider empty)
           profiles.create     tui_gateway/methods_profiles.py (the canonical socket's fallback to
           profiles.configure  the sidecar's handlers): extra keys are refused (4000), a bad or taken
                               name is 4062, ui_meta is per-section compare-and-swap, a model the
                               server warns about needs confirm_expensive_model
  REST     /api/profiles, /api/profiles/{name} (DELETE: the default profile is refused with 400,
           as hermes_cli/profiles.py delete_profile does), …/soul, …/description, …/model,
           /api/model/options, /api/mcp/servers (+ /{name}, /enabled, /test, /auth),
           /api/mcp/oauth/flows/{id}, /api/mcp/catalog (+ /install), /api/skills (+ /toggle,
           /lock), /api/tools/toolsets (+ /{name}), /api/config?profile= (mcp_servers merged the way
           hermes_cli/config.py _deep_merge does), /api/config/defaults, /api/actions/{name}/status
  socket   profiles.get_asset / set_asset (the avatar), mcp.servers.add / remove / set_api_key
           (tui_gateway/methods_tools.py), cli.exec (only `hermes profile purge-identity` is played)

Fixtures for the second round: archive-ci is hidden by Bot Mode (ui_meta hidden: true); 通勤 has an
avatar picture; deleting mail-ci leaves its identity unsettled (settlement_pending) until the fourth
purge-identity; the catalog's slow-ci installs in the background; the second read of 通勤's SOUL finds
it changed by another client.

Stricter than Hermes in one way, on purpose: a per-profile REST route without ?profile= is refused
here (400), where Hermes would quietly act on the gateway's own profile. Shion must always name the
profile it means. Secrets (MCP env values, bearer tokens, catalog keys) are never logged. Stdlib only.
"""
import base64
import copy
import json
import struct
import zlib
import re
import secrets
import threading
import urllib.parse

lock = threading.Lock()
_log = print
_valid = None

PROFILE_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
RESERVED = {"hermes", "default", "test", "tmp", "root", "sudo"}
# the gateway runs as 詩音's profile: a REST call that names no profile acts on her home
LAUNCH = "shion"
DEFAULT_SOUL = "You are Hermes Agent, an intelligent AI assistant created by Nous Research.\n"

SKILLS = [
    ("arxiv", "Search arXiv and summarize papers", "research"),
    ("email-inbox-triage", "Sort an inbox and pick out what needs a reply", "email"),
    ("himalaya", "Read and send email over IMAP and SMTP", "email"),
    ("obsidian", "Read and write Obsidian notes", "note-taking"),
    ("weekly-review-planning", "Weekly review and next week's plan", "productivity"),
]
TOOLSETS = [
    ("kanban", "📋 Kanban", "Create cards, hand them to assistants, follow up", ["kanban_create", "kanban_show"]),
    ("memory", "🧠 Memory", "Persistent memory across sessions", ["memory"]),
    ("web", "🔍 Web Search", "Search and read the web", ["web_search", "web_extract"]),
    ("terminal", "💻 Terminal", "Run commands on the server", ["terminal"]),
]
PROVIDERS = [
    {"slug": "nous", "name": "Nous Portal", "models": ["hermes-4-405b", "hermes-4-70b"], "authenticated": True},
    {"slug": "openrouter", "name": "OpenRouter", "models": ["ci-cheap", "ci-pricey"], "authenticated": True},
    {"slug": "anthropic", "name": "Anthropic", "models": ["claude-ci"], "authenticated": False},
]
# a pick model_selection_guards would warn about
PRICEY = "ci-pricey"
CATALOG = [
    {"name": "github", "description": "GitHub repositories, issues and pull requests", "transport": "stdio",
     "auth_type": "env", "required_env": [{"name": "GITHUB_TOKEN", "prompt": "GitHub token", "required": True}],
     "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "url": None, "needs_install": False},
    {"name": "fetch", "description": "Fetch a web page as markdown", "transport": "stdio", "auth_type": "none",
     "required_env": [], "command": "uvx", "args": ["mcp-server-fetch"], "url": None, "needs_install": False},
    {"name": "slow-ci", "description": "Cloned from git before it runs (CI)", "transport": "stdio", "auth_type": "none",
     "required_env": [], "command": "uvx", "args": ["slow-ci-server"], "url": None, "needs_install": True},
]
DEFAULTS = {
    "approvals": {"mode": "smart", "timeout": 300, "cron_mode": "deny"},
    "memory": {"memory_enabled": True, "user_profile_enabled": True, "memory_char_limit": 2200},
    "agent": {"max_turns": None, "gateway_timeout": 1800},
    "kanban": {"max_in_progress": None, "max_in_progress_per_profile": None},
}
CREATE_KEYS = {"profile", "name", "description", "clone_from", "clone_all", "clone_channels", "no_skills", "no_alias",
               "soul", "model", "provider", "share_auth", "mirror_credentials"}
CONFIGURE_KEYS = {"profile", "name", "ui_meta", "ui_meta_expected_revisions", "soul", "description", "model",
                  "provider", "confirm_expensive_model", "disabled_skills", "enabled_toolsets", "enabled_mcp_servers"}

profiles = {}  # name -> state, in the roster's order
flows = {}  # MCP OAuth flow id -> its state
assets = {}  # profile -> its avatar as a data URL
actions = {}  # background catalog install -> its state
unsettled = {}  # deleted profile whose identity is not purged yet -> purge attempts
soul_reads = {}  # profile -> GETs of its SOUL
UNSETTLED = {"mail-ci"}


def profile(name, display_name="", description="", default=False, ui_meta=None, revisions=None, soul=None,
            plugins=()):
    return {"name": name, "is_default": default, "display_name": display_name, "description": description,
            "ui_meta": ui_meta or {}, "revisions": revisions or {}, "soul": DEFAULT_SOUL if soul is None else soul,
            "model": {"provider": "nous", "default": "hermes-4-405b"}, "mcp": {}, "mcp_tokens": set(),
            "disabled_skills": set(), "locked_skills": {"obsidian"}, "toolsets": {"memory", "web"}, "config": {},
            "plugins": set(plugins), "secrets": set()}


def seed():
    shion = profile("shion", "詩音", soul="# 詩音（CI）\n\n你是詩音，带着课程和通勤两个助手。\n", plugins={"shion"})
    shion["toolsets"].add("kanban")
    shion["mcp"]["notion-ci"] = {"url": "https://mcp.notion.example/mcp", "auth": "oauth"}
    study = profile("study", "study", "课程", ui_meta={"hermes-bots": {"title": "课程（CI）", "color": "#4f8a5b"}},
                    revisions={"hermes-bots": 3})
    commute = profile("commute", "通勤（CI）", "通勤")
    # Bot Mode hid this one: Shion starts it hidden the first time it sees it
    archive = profile("archive-ci", "archive-ci", "归档",
                      ui_meta={"hermes-bots": {"title": "归档（CI）", "hidden": True, "color": "#8b5cf6", "shape": "hexagon"}},
                      revisions={"hermes-bots": 1})
    # Hermes's own default profile (~/.hermes): it cannot be deleted
    default = profile("default", "Hermes（CI）", default=True)
    for p in (shion, study, commute, archive, default):
        profiles[p["name"]] = p
    assets["commute"] = "data:image/png;base64," + base64.b64encode(tile((79, 138, 91))).decode()


def tile(rgb, size=32):
    """A plain PNG of one colour, for an avatar picture."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


seed()


def setup(log, valid_access):
    global _log, _valid
    _log, _valid = log, valid_access


def has_plugin(name, plugin):
    with lock:
        p = profiles.get(name)
        return p is not None and plugin in p["plugins"]


def redact(body):
    """A request body as the log shows it: the names of secrets, never their values."""
    shown = copy.deepcopy(body) if isinstance(body, dict) else body
    if isinstance(shown, dict):
        if "bearer_token" in shown:
            shown["bearer_token"] = "***"
        if isinstance(shown.get("env"), dict):
            shown["env"] = {k: "***" for k in shown["env"]}
    return json.dumps(shown, ensure_ascii=False)[:200]


# ---- the socket ------------------------------------------------------------------------------

def roster():
    """profiles.list: the gateway's own profile first with its model, the others metadata only."""
    with lock:
        rows = []
        for name, p in profiles.items():
            own = name == LAUNCH
            row = {"name": name, "path": f"/ci/.hermes/profiles/{name}" if not p["is_default"] else "/ci/.hermes",
                   "is_default": p["is_default"], "model": p["model"]["default"] if own else "",
                   "provider": p["model"]["provider"] if own else "", "description": p["description"],
                   "display_name": p["display_name"], "skill_count": len(SKILLS), "has_avatar": name in assets,
                   "ui_meta_revisions": dict(p["revisions"])}
            if p["ui_meta"]:
                row["ui_meta"] = copy.deepcopy(p["ui_meta"])
            rows.append(row)
        rows.sort(key=lambda r: r["name"] != LAUNCH)
        return {"profiles": rows, "bot_mode_protocol": True, "install_id": "ci"}


def handles_rpc(method):
    return method in ("profiles.create", "profiles.configure", "profiles.describe") or method in MORE


def rpc(conn, method, params, rid):
    """A sidecar profile method reached through the canonical socket's fallback."""
    if method in MORE:
        keys, handler = MORE[method]
        unknown = sorted(set(params) - keys)
        if unknown:
            _log(f"    {method} refused: unknown keys {unknown}")
            return error(conn, rid, 4000, f"invalid params: unknown key(s) {', '.join(unknown)}")
        with lock:
            outcome = handler(params)
        if isinstance(outcome, tuple):
            code, message = outcome
            _log(f"    {method} refused: {code} {message}")
            return error(conn, rid, code, message)
        return conn.send_json({"jsonrpc": "2.0", "id": rid, "result": outcome})
    allowed = CREATE_KEYS if method == "profiles.create" else CONFIGURE_KEYS
    if method == "profiles.describe":
        allowed = {"profile", "name"}
    unknown = sorted(set(params) - allowed)
    if unknown:
        _log(f"    {method} refused: unknown keys {unknown}")
        return error(conn, rid, 4000, f"invalid params: unknown key(s) {', '.join(unknown)}")
    if method == "profiles.create":
        return create(conn, params, rid)
    if method == "profiles.configure":
        return configure(conn, params, rid)
    name = str(params.get("name") or "").strip()
    with lock:
        p = profiles.get(name)
        if p is None:
            return error(conn, rid, 4064, f"profile '{name}' not found")
        result = {"name": name, "description": p["description"], "soul": p["soul"],
                  "model": {"provider": p["model"]["provider"], "default": p["model"]["default"]},
                  "skills": [{"name": s, "enabled": s not in p["disabled_skills"]} for s, _, _ in SKILLS],
                  "toolsets": [], "toolsets_pinned": False,
                  "mcp_servers": [{"name": n, "enabled": c.get("enabled", True),
                                   "transport": "http" if c.get("url") else "stdio"} for n, c in p["mcp"].items()]}
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})


def error(conn, rid, code, message):
    conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


def asset_profile(params):
    """The profile an asset call names (``name``, else ``profile``), or an error."""
    name = str(params.get("name") or params.get("profile") or "").strip()
    if not name:
        return None, (4063, "name required")
    if name not in profiles:
        return None, (4064, f"profile '{name}' not found")
    if str(params.get("asset") or "avatar").strip().lower() != "avatar":
        return None, (4066, f"unknown asset '{params.get('asset')}' (supported: avatar)")
    return name, None


def get_asset(params):
    name, problem = asset_profile(params)
    if problem:
        return problem
    data = assets.get(name)
    if data is None:
        return {"found": False}
    blob = base64.b64decode(data.split(",", 1)[1])
    return {"found": True, "mime": "image/png", "size": len(blob), "data": data}


def set_asset(params):
    """methods_profiles.py profiles.set_asset: a data URL or bare base64 (PNG/JPEG/WebP, at most 2MB),
    or clear."""
    name, problem = asset_profile(params)
    if problem:
        return problem
    if params.get("clear") in (True, "true", "1"):
        removed = 1 if assets.pop(name, None) else 0
        _log(f"    avatar of {name} cleared")
        return {"ok": True, "asset": "avatar", "size": 0, "removed": removed}
    data = str(params.get("data") or "")
    if not data:
        return 4067, "data required (data URL or base64)"
    match = re.match(r"^data:(image/(?:png|jpeg|webp));base64,(.*)$", data, re.DOTALL)
    try:
        blob = base64.b64decode(match.group(2) if match else data, validate=True)
    except Exception:
        return 4068, "data is not valid base64"
    if len(blob) > 2_000_000:
        return 4069, f"asset too large ({len(blob)} bytes; max 2MB)"
    if not (blob.startswith(b"\x89PNG") or blob.startswith(b"\xff\xd8\xff") or blob[8:12] == b"WEBP"):
        return 4070, "unsupported image format (PNG/JPEG/WebP only)"
    assets[name] = "data:image/png;base64," + base64.b64encode(blob).decode()
    _log(f"    avatar of {name}: {len(blob)} bytes")
    return {"ok": True, "asset": "avatar", "size": len(blob)}


def mcp_profile(params):
    """The profile an mcp.servers call is scoped to: Shion always names it."""
    name = str(params.get("profile") or "").strip()
    if not name:
        return None, (4000, "stand-in: profile missing — Hermes would act on the connection's own profile")
    p = profiles.get(name)
    if p is None:
        return None, (4064, "profile unavailable")
    return p, None


def env_key(server):
    """mcp_config._env_key_for_server"""
    return "MCP_" + re.sub(r"[^A-Za-z0-9_]", "_", server.upper()).strip("_") + "_API_KEY"


def mcp_add(params):
    """methods_tools.py mcp.servers.add: a duplicate is 4090, no url/command 4063; a bearer_token goes
    to .env and only the header template stays."""
    p, problem = mcp_profile(params)
    if problem:
        return problem
    name = str(params.get("name") or "").strip()
    if not name:
        return 4063, "name required"
    if name in p["mcp"]:
        return 4090, f"server '{name}' already exists"
    config = dict(params.get("config") or {})
    if not config.get("url") and not config.get("command"):
        return 4063, "config must specify a 'url' (http) or 'command' (stdio), or a valid 'preset'"
    if params.get("bearer_token"):
        p["secrets"].add(env_key(name))
        config["headers"] = {"Authorization": "Bearer ${" + env_key(name) + "}"}
    p["mcp"][name] = config
    _log(f"    mcp.servers.add {name} on {p['name']}: {redact(config)}"
         f"{' + bearer token to .env as ' + env_key(name) if params.get('bearer_token') else ''}")
    return {"ok": True, "name": name, "server": summary(name, config)}


def mcp_remove(params):
    p, problem = mcp_profile(params)
    if problem:
        return problem
    name = str(params.get("name") or "").strip()
    if name not in p["mcp"]:
        return 4064, f"server '{name}' not found"
    p["mcp"].pop(name)
    _log(f"    mcp.servers.remove {name} on {p['name']}")
    return {"ok": True, "removed": True}


def mcp_set_api_key(params):
    """mcp.servers.set_api_key: the secret to .env, a ${…} reference in config (a Bearer header for
    http, an env entry for stdio)."""
    p, problem = mcp_profile(params)
    if problem:
        return problem
    name = str(params.get("name") or "").strip()
    entry = p["mcp"].get(name)
    if entry is None:
        return 4064, f"server '{name}' not found"
    if not str(params.get("value") or "").strip():
        return 4002, "value required"
    variable = str(params.get("env_var") or "").strip() or env_key(name)
    p["secrets"].add(variable)
    if entry.get("url"):
        entry["headers"] = {"Authorization": "Bearer ${" + variable + "}"}
    else:
        entry.setdefault("env", {})[variable] = "${" + variable + "}"
    _log(f"    mcp.servers.set_api_key {name} on {p['name']}: {variable} to .env (value not logged)")
    return {"ok": True, "name": name, "env_var": variable, "server": summary(name, entry)}


def cli_exec(params):
    """cli.exec: `hermes <argv>` on the server. Only the retry of a delete's identity purge is played;
    an unsettled name goes through on the fourth try (Shion's third retry, some thirty-five seconds
    after the delete), as when the gateway answers late, so BotsTests sees the name held back first."""
    argv = params.get("argv")
    if not isinstance(argv, list) or not all(isinstance(x, str) for x in argv):
        return 4003, "argv must be list[str]"
    if argv[:2] != ["profile", "purge-identity"] or len(argv) != 3:
        _log(f"    cli.exec {argv}: not played by the stand-in")
        return {"blocked": False, "code": 2, "output": "stand-in: only `hermes profile purge-identity` is played"}
    name = argv[2]
    if name in profiles:
        return {"blocked": False, "code": 1,
                "output": f"Error: Profile '{name}' exists; purge-identity only settles the identity of a delete "
                          "that has already completed."}
    if name in unsettled:
        unsettled[name] += 1
        if unsettled[name] < 4:
            _log(f"    cli.exec purge-identity {name}: not yet (try {unsettled[name]})")
            return {"blocked": False, "code": 1,
                    "output": f"Error: session identity was not purged. Restart or stop the gateway, then run:\n"
                              f"    hermes profile purge-identity {name}"}
        unsettled.pop(name)
    _log(f"    cli.exec purge-identity {name}: purged")
    return {"blocked": False, "code": 0, "output": f"✓ Session/routing identity purged: {name}"}


MORE = {
    "profiles.get_asset": ({"profile", "name", "asset"}, get_asset),
    "profiles.set_asset": ({"profile", "name", "asset", "data", "clear"}, set_asset),
    "mcp.servers.add": ({"profile", "name", "preset", "config", "bearer_token"}, mcp_add),
    "mcp.servers.remove": ({"profile", "name"}, mcp_remove),
    "mcp.servers.set_api_key": ({"profile", "name", "value", "env_var"}, mcp_set_api_key),
    "cli.exec": ({"argv", "timeout", "profile"}, cli_exec),
}


def create(conn, params, rid):
    name = str(params.get("name") or "").strip()
    if not name:
        return error(conn, rid, 4061, "name required")
    canon = name.lower()
    clone_from = str(params.get("clone_from") or "").strip() or None
    with lock:
        if canon == "default":
            problem = "Cannot create a profile named 'default' — it is the built-in profile (~/.hermes)."
        elif not PROFILE_ID.fullmatch(canon):
            problem = (f"{name!r} is not a valid profile name. Use lowercase letters, numbers, '-' or '_', "
                       "starting with a letter or number, up to 64 characters")
        elif canon in RESERVED:
            problem = f"Profile name {canon!r} is reserved — pick a different name."
        elif canon in profiles:
            problem = f"A profile named '{canon}' already exists. Switch to it with `hermes profile use {canon}`."
        elif clone_from is not None and clone_from not in profiles:
            problem = f"Profile '{clone_from}' does not exist. Create it with: hermes profile create {clone_from}"
        else:
            problem = None
        if problem:
            _log(f"    profiles.create refused: {problem}")
            return error(conn, rid, 4062, problem)
        fresh = profile(canon, description=str(params.get("description") or "").strip())
        if clone_from:
            # config, .env, SOUL, skills, memories and plugins; not profile.yaml, not channels
            source = profiles[clone_from]
            for key in ("soul", "model", "mcp", "disabled_skills", "toolsets", "config", "plugins"):
                fresh[key] = copy.deepcopy(source[key])
        else:
            # mirror_credentials: the launch profile's keys and model
            fresh["model"] = copy.deepcopy(profiles[LAUNCH]["model"])
        soul = params.get("soul")
        soul_written = isinstance(soul, str) and bool(soul.strip())
        if soul_written:
            fresh["soul"] = soul
        model, provider = str(params.get("model") or "").strip(), str(params.get("provider") or "").strip()
        model_set = bool(model and provider)
        if model_set:
            fresh["model"] = {"provider": provider, "default": model}
        profiles[canon] = fresh
    _log(f"    created profile {canon} (clone of {clone_from or 'nothing'}; soul {'set' if soul_written else 'default'};"
         f" model {fresh['model']['provider']}/{fresh['model']['default']})")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {
        "ok": True, "name": name, "path": f"/ci/.hermes/profiles/{canon}", "soul_written": soul_written,
        "model_set": model_set, "mirrored": {"env": not clone_from, "auth": False,
                                             "model_inherited": not clone_from and not model_set, "voice": False}}})


def configure(conn, params, rid):
    name = str(params.get("name") or "").strip()
    if not name:
        return error(conn, rid, 4063, "name required")
    applied, extra = {}, {}
    with lock:
        p = profiles.get(name)
        if p is None:
            return error(conn, rid, 4064, f"profile '{name}' not found")
        incoming = params.get("ui_meta")
        if isinstance(incoming, dict):
            expected = params.get("ui_meta_expected_revisions")
            conflicts = {}
            if isinstance(expected, dict):
                for key in incoming:
                    wanted, actual = expected.get(key), p["revisions"].get(key, 0)
                    if not isinstance(wanted, int) or isinstance(wanted, bool) or wanted != actual:
                        conflicts[key] = {"expected": wanted, "actual": actual}
            if conflicts:
                applied.update(ui_meta=False, ui_meta_conflicts=conflicts,
                               ui_meta_revisions={k: p["revisions"].get(k, 0) for k in incoming})
            else:
                for key, value in incoming.items():
                    if value is None:
                        p["ui_meta"].pop(key, None)
                    else:
                        p["ui_meta"][key] = value
                    p["revisions"][key] = p["revisions"].get(key, 0) + 1
                applied.update(ui_meta=True, ui_meta_revisions={k: p["revisions"][k] for k in incoming})
            _log(f"    ui_meta of {name}: {json.dumps(p['ui_meta'], ensure_ascii=False)}"
                 f"{' CONFLICT ' + json.dumps(conflicts) if conflicts else ''}")
        if isinstance(params.get("soul"), str):
            p["soul"] = params["soul"]
            applied["soul"] = True
        if isinstance(params.get("description"), str):
            p["description"] = params["description"].strip()
            applied["description"] = True
        model, provider = str(params.get("model") or "").strip(), str(params.get("provider") or "").strip()
        if model and provider:
            if model == PRICEY and params.get("confirm_expensive_model") is not True:
                extra = {"confirm_required": True,
                         "confirm_message": f"{model} costs about five times the default per token. Switch anyway?"}
                _log(f"    model {provider}/{model} for {name}: needs confirm_expensive_model")
            else:
                p["model"] = {"provider": provider, "default": model}
                applied["model"] = True
                _log(f"    model of {name}: {provider}/{model}")
    ok = all(applied.values()) if applied else True
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {"ok": ok, "applied": applied, **extra}})


# ---- REST ------------------------------------------------------------------------------------

PREFIXES = ("/api/profiles", "/api/model/options", "/api/mcp/", "/api/skills", "/api/tools/toolsets",
            "/api/config", "/api/actions/")


def handles(path, query):
    """Routes this module answers; /api/config without ?profile= stays fake_hermes.py's own."""
    if path == "/api/config" and "profile" not in query:
        return False
    return path.startswith(PREFIXES)


def route(handler, method, url, query, body):
    """One REST request; returns after answering."""
    path = url.path
    if path.startswith("/api/mcp/oauth/callback/") or path == "/api/config/defaults":
        status, reply = public(path)
        return handler.answer(status, reply)
    bearer = handler.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if not _valid(bearer):
        return handler.answer(401, {"detail": "Unauthorized"})
    with lock:
        status, reply = dispatch(method, path, query, body)
    if method != "GET":
        _log(f"    {method} {path} {redact(body)} -> {status}")
    return handler.answer(status, reply)


def public(path):
    if path == "/api/config/defaults":
        return 200, DEFAULTS
    return 404, {"detail": "OAuth flow expired"}


def scoped(query):
    """(profile state, error): the profile ?profile= names."""
    name = query.get("profile")
    if not name:
        return None, (400, {"detail": "stand-in: ?profile= missing — Hermes would act on the gateway's own profile"})
    return named(name)


def named(name):
    if name != "default" and not PROFILE_ID.fullmatch(name):
        return None, (400, {"detail": f"{name!r} is not a valid profile name."})
    p = profiles.get(name)
    if p is None:
        return None, (404, {"detail": f"Profile '{name}' does not exist."})
    return p, None


def dispatch(method, path, query, body):
    parts = [urllib.parse.unquote(part) for part in path.split("/")[2:]]  # after "/api/"
    if parts == ["profiles"] and method == "GET":
        return 200, {"profiles": [
            {"name": n, "path": "/ci/.hermes" if p["is_default"] else f"/ci/.hermes/profiles/{n}",
             "is_default": p["is_default"], "model": p["model"]["default"], "provider": p["model"]["provider"],
             "has_env": True, "skill_count": len(SKILLS), "gateway_running": True, "description": p["description"],
             "description_auto": False, "display_name": p["display_name"],
             "bot_title": (p["ui_meta"].get("hermes-bots") or {}).get("title", ""), "distribution_name": None,
             "distribution_version": None, "distribution_source": None, "has_alias": False}
            for n, p in profiles.items()]}
    if parts[:1] == ["profiles"] and len(parts) >= 2:
        return profile_route(method, parts[1], parts[2:], body)
    if parts == ["model", "options"] and method == "GET":
        p, problem = scoped(query) if query.get("profile") else (profiles[LAUNCH], None)
        if problem:
            return problem
        current = p["model"]
        return 200, {"providers": [{**row, "is_current": row["slug"] == current["provider"]} for row in PROVIDERS],
                     "model": current["default"], "provider": current["provider"]}
    if parts[:1] == ["mcp"]:
        return mcp_route(method, parts[1:], query, body)
    if parts[:1] == ["skills"]:
        return skills_route(method, parts[1:], query, body)
    if parts[:2] == ["tools", "toolsets"]:
        return toolsets_route(method, parts[2:], query, body)
    if parts == ["config"]:
        return config_route(method, query, body)
    if parts[:1] == ["actions"] and len(parts) == 3 and parts[2] == "status" and method == "GET":
        return action_status(parts[1])
    return 404, {"detail": "Not Found"}


def action_status(name):
    """actions.py get_action_status: a background catalog install runs for three polls, then ends and
    its server is in the profile's config."""
    action = actions.get(name)
    if action is None:
        return 404, {"detail": f"Unknown action: {name}"}
    action["polls"] += 1
    if action["polls"] < 3:
        return 200, {"name": name, "running": True, "exit_code": None, "pid": 4242,
                     "lines": [f"Cloning {action['entry']}…"]}
    if action["polls"] == 3:
        p = profiles.get(action["profile"])
        if p is not None:
            p["mcp"][action["entry"]] = {"command": "uvx", "args": [action["entry"] + "-server"], "enabled": True}
        _log(f"    background install of {action['entry']} on {action['profile']} finished")
    return 200, {"name": name, "running": False, "exit_code": 0, "pid": 4242,
                 "lines": [f"Cloning {action['entry']}…", "✓ installed"]}


def profile_route(method, name, rest, body):
    if method == "DELETE" and not rest:
        # hermes_cli/profiles.py delete_profile: the default profile stays (ValueError -> 400)
        if name.lower() == "default":
            return 400, {"detail": "Cannot delete the default profile (~/.hermes).\nTo remove everything, use: hermes uninstall"}
        if name not in profiles:
            return 404, {"detail": f"No profile named '{name}'. See your profiles with: hermes profile list"}
        profiles.pop(name)
        assets.pop(name, None)
        if name in UNSETTLED:
            # profiles.py ProfileIdentitySettlementPending: the directory is gone, the identity is not
            unsettled[name] = 0
            _log(f"    deleted profile {name}; its identity settlement is pending")
            return 200, {"ok": True, "path": f"/ci/.hermes/profiles/{name}", "identity_settled": False,
                         "settlement_pending": True, "retry_command": f"hermes profile purge-identity {name}"}
        _log(f"    deleted profile {name}")
        return 200, {"ok": True, "path": f"/ci/.hermes/profiles/{name}"}
    p, problem = named(name)
    if problem:
        return problem
    if rest == ["soul"] and method == "GET":
        soul_reads[name] = soul_reads.get(name, 0) + 1
        if name == "commute" and soul_reads[name] == 2:
            p["soul"] = "# 通勤（CI）\n\n别处改过的 SOUL。\n"
            _log("    another client changed commute's SOUL")
        return 200, {"content": p["soul"], "exists": True}
    if rest == ["soul"] and method == "PUT":
        if not isinstance(body.get("content"), str):
            return 422, {"detail": [{"loc": ["body", "content"], "msg": "Field required", "type": "missing"}]}
        p["soul"] = body["content"]
        return 200, {"ok": True}
    if rest == ["description"] and method == "PUT":
        p["description"] = str(body.get("description") or "").strip()
        return 200, {"ok": True, "description": p["description"], "description_auto": False}
    if rest == ["model"] and method == "PUT":
        provider, model = str(body.get("provider") or "").strip(), str(body.get("model") or "").strip()
        if not provider or not model:
            return 400, {"detail": "provider and model are required"}
        p["model"] = {"provider": provider, "default": model}
        return 200, {"ok": True, "provider": provider, "model": model}
    return 404, {"detail": "Not Found"}


def summary(name, cfg):
    transport = "http" if cfg.get("url") else ("stdio" if cfg.get("command") else "unknown")
    auth = cfg.get("auth") or ("header" if any(k.lower() == "authorization" for k in cfg.get("headers") or {}) else None)
    return {"name": name, "transport": transport, "url": cfg.get("url"), "command": cfg.get("command"),
            "args": list(cfg.get("args") or []), "env": {k: "***" for k in cfg.get("env") or {}}, "auth": auth,
            "enabled": cfg.get("enabled", True), "tools": cfg.get("tools"), "source": "config", "plugin": None}


def mcp_route(method, parts, query, body):
    if parts[:2] == ["oauth", "flows"] and len(parts) == 3:
        flow = flows.get(parts[2])
        if flow is None:
            return (200, {"ok": True, "status": "expired"}) if method == "DELETE" else \
                (404, {"detail": "OAuth flow not found or expired"})
        if method == "DELETE":
            flow["status"] = "error"
            flow["error"] = "Cancelled by user"
            return 200, {"ok": True, "status": "error"}
        flow["polls"] += 1
        if flow["polls"] >= 2 and flow["status"] == "authorization_required":
            # the provider sent the browser back: the token is stored
            flow["status"] = "approved"
            profiles[flow["profile"]]["mcp_tokens"].add(flow["server_name"])
        return 200, {k: flow[k] for k in ("flow_id", "server_name", "status", "authorization_url", "error")} | {"tools": []}
    p, problem = scoped(query)
    if problem:
        return problem
    servers = p["mcp"]
    if parts == ["servers"] and method == "GET":
        return 200, {"servers": [summary(n, c) for n, c in sorted(servers.items())]}
    if parts == ["servers"] and method == "POST":
        name = str(body.get("name") or "").strip()
        url, command = str(body.get("url") or "").strip(), str(body.get("command") or "").strip()
        auth = str(body.get("auth") or "none").strip().lower()
        if not name:
            return 400, {"detail": "Server name is required"}
        if bool(url) == bool(command):
            return 400, {"detail": "Provide exactly one of URL (HTTP/SSE) or command (stdio)"}
        if auth not in ("none", "header", "oauth"):
            return 400, {"detail": f"Unsupported auth mode: {auth}"}
        if name in servers:
            return 409, {"detail": f"Server '{name}' already exists"}
        cfg = {}
        if url:
            if body.get("args") or body.get("env"):
                return 400, {"detail": "Arguments and environment variables are only supported for stdio MCP servers"}
            if auth == "header":
                if not str(body.get("bearer_token") or "").strip():
                    return 400, {"detail": "Bearer token is required"}
                # the token goes to the profile's .env; config only refers to it
                cfg["headers"] = {"Authorization": f"Bearer ${{MCP_{name.upper().replace('-', '_')}_API_KEY}}"}
            cfg["url"] = url
            if auth == "oauth":
                cfg["auth"] = "oauth"
        else:
            if auth != "none" or body.get("bearer_token") is not None:
                return 400, {"detail": "HTTP authentication is not supported for stdio MCP servers"}
            cfg["command"] = command
            if body.get("args"):
                cfg["args"] = list(body["args"])
            if body.get("env"):
                cfg["env"] = dict(body["env"])
        servers[name] = cfg
        return 200, summary(name, cfg)
    if parts[:1] == ["servers"] and len(parts) >= 2:
        name, rest = parts[1], parts[2:]
        if name not in servers:
            return 404, {"detail": f"Server '{name}' not found"}
        cfg = servers[name]
        if not rest and method == "DELETE":
            servers.pop(name)
            return 200, {"ok": True}
        if rest == ["enabled"] and method == "PUT":
            cfg["enabled"] = bool(body.get("enabled"))
            return 200, {"ok": True, "name": name, "enabled": cfg["enabled"]}
        if rest == ["test"] and method == "POST":
            if "fail" in (cfg.get("url") or cfg.get("command") or ""):
                return 200, {"ok": False, "error": "Connection refused", "tools": []}
            if cfg.get("auth") == "oauth" and name not in p["mcp_tokens"]:
                return 200, {"ok": False, "error": "OAuth authentication required — no token found.", "tools": []}
            return 200, {"ok": True, "tools": [{"name": "search", "description": "Search (CI)"},
                                               {"name": "read", "description": "Read (CI)"}],
                         "prompts": 0, "resources": 1}
        if rest == ["auth"] and method == "POST":
            if not cfg.get("url"):
                return 400, {"detail": "stdio servers authenticate via env keys, not OAuth"}
            flow_id = secrets.token_urlsafe(12)
            flows[flow_id] = {"flow_id": flow_id, "server_name": name, "profile": p["name"], "polls": 0,
                              "status": "authorization_required", "error": None,
                              "authorization_url": f"https://auth.example.dev/authorize?state={flow_id}"}
            return 200, {k: flows[flow_id][k] for k in ("flow_id", "server_name", "status", "authorization_url", "error")}
    if parts == ["catalog"] and method == "GET":
        return 200, {"entries": [{**entry, "connector_slug": None, "source": "optional-mcps", "install_url": None,
                                  "install_ref": None, "bootstrap": [], "default_enabled": None, "post_install": "",
                                  "suggest": None, "installed": entry["name"] in servers,
                                  "enabled": servers.get(entry["name"], {}).get("enabled", False)}
                                 for entry in CATALOG], "diagnostics": []}
    if parts == ["catalog", "install"] and method == "POST":
        name = str(body.get("name") or "").strip()
        entry = next((e for e in CATALOG if e["name"] == name), None)
        if entry is None:
            return 404, {"detail": f"No catalog entry '{name}'"}
        declared = {e["name"] for e in entry["required_env"]}
        undeclared = sorted(set(body.get("env") or {}) - declared)
        if undeclared:
            return 400, {"detail": f"Catalog entry '{name}' does not declare environment variable(s): {', '.join(undeclared)}"}
        missing = [e["name"] for e in entry["required_env"] if e["required"] and not (body.get("env") or {}).get(e["name"])]
        if missing:
            return 400, {"detail": f"Missing required environment variable(s): {', '.join(missing)}"}
        if entry["needs_install"]:
            # web_routers/mcp.py: a git step runs as a background CLI action, named per entry
            action = "mcp-install-" + name + "-" + secrets.token_hex(4)
            actions[action] = {"polls": 0, "profile": p["name"], "entry": name}
            _log(f"    catalog install of {name} on {p['name']}: background action {action}")
            return 200, {"ok": True, "name": name, "background": True, "action": action}
        cfg = {"command": entry["command"], "args": list(entry["args"]), "enabled": bool(body.get("enable", True))}
        if declared:
            cfg["env"] = {key: "${" + key + "}" for key in declared}
        servers[name] = cfg
        return 200, {"ok": True, "name": name, "background": False}
    return 404, {"detail": "Not Found"}


def skills_route(method, parts, query, body):
    p, problem = scoped(query)
    if problem:
        return problem
    if not parts and method == "GET":
        return 200, [{"name": s, "description": d, "category": c, "locked": s in p["locked_skills"],
                      "enabled": s not in p["disabled_skills"], "usage": 0, "provenance": "bundled"}
                     for s, d, c in SKILLS]
    name = str(body.get("name") or "")
    if parts == ["toggle"] and method == "PUT":
        if body.get("enabled"):
            p["disabled_skills"].discard(name)
        else:
            p["disabled_skills"].add(name)
        return 200, {"ok": True, "name": name, "enabled": bool(body.get("enabled"))}
    if parts == ["lock"] and method == "PUT":
        if name not in {s for s, _, _ in SKILLS}:
            return 404, {"detail": f"Skill '{name}' not found."}
        (p["locked_skills"].add if body.get("locked") else p["locked_skills"].discard)(name)
        return 200, {"ok": True, "name": name, "locked": bool(body.get("locked"))}
    return 404, {"detail": "Not Found"}


def toolsets_route(method, parts, query, body):
    p, problem = scoped(query)
    if problem:
        return problem
    if not parts and method == "GET":
        return 200, [{"name": n, "label": label, "description": d, "platform": "cli", "platform_label": "CLI",
                      "enabled": n in p["toolsets"], "available": n in p["toolsets"], "configured": n != "terminal",
                      "tools": tools} for n, label, d, tools in TOOLSETS]
    if len(parts) == 1 and method == "PUT":
        if parts[0] not in {n for n, _, _, _ in TOOLSETS}:
            return 404, {"detail": f"Unknown toolset: {parts[0]}"}
        (p["toolsets"].add if body.get("enabled") else p["toolsets"].discard)(parts[0])
        return 200, {"ok": True, "name": parts[0], "enabled": bool(body.get("enabled"))}
    return 404, {"detail": "Not Found"}


def merged(base, over):
    out = copy.deepcopy(base)
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merged(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def deep_merge(base, over):
    """hermes_cli/config.py _deep_merge: dict over dict recurses, None over a dict is ignored, anything
    else replaces (a list included). It never deletes a key."""
    out = copy.deepcopy(base)
    for key, value in over.items():
        over_dict = isinstance(out.get(key), dict)
        if over_dict and isinstance(value, dict):
            out[key] = deep_merge(out[key], value)
        elif not (over_dict and value is None):
            out[key] = copy.deepcopy(value)
    return out


def config_route(method, query, body):
    p, problem = scoped(query)
    if problem:
        return problem
    if method == "GET":
        raw = query.get("include_defaults", "true").lower() in ("false", "0", "no")
        whole = copy.deepcopy(p["config"])
        if p["mcp"]:
            whole["mcp_servers"] = copy.deepcopy(p["mcp"])
        return 200, whole if raw else merged(DEFAULTS, whole)
    if method == "PUT":
        if not isinstance(body.get("config"), dict):
            return 422, {"detail": [{"loc": ["body", "config"], "msg": "Field required", "type": "missing"}]}
        incoming = dict(body["config"])
        servers = incoming.pop("mcp_servers", None)
        if isinstance(servers, dict):
            p["mcp"] = deep_merge(p["mcp"], servers)
            _log(f"    mcp_servers of {p['name']}: {json.dumps(p['mcp'], ensure_ascii=False)[:300]}")
        p["config"] = deep_merge(p["config"], incoming)
        _log(f"    config of {p['name']}: {json.dumps(p['config'], ensure_ascii=False)}")
        return 200, {"ok": True}
    return 404, {"detail": "Not Found"}
