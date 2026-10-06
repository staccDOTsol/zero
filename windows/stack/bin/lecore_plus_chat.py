"""Zero chat launcher (service "lecore-chat", run by WinSW as LOCAL SERVICE).

Runs leCore's own chat_server.py (pinned commit, unmodified) on 127.0.0.1:7860 and wires its model rung
to the local llama-server through LECORE_LLM_URL (default http://127.0.0.1:8080/v1).

Why a launcher: at the pinned leCore commit chat_server.py boots memory-only and never reads
LECORE_LLM_URL itself (only lecore.agent_boot() does, via holographic_remotellm.remote_llm). This file
attaches exactly that remote_llm callable as the rung, guarded so the chat keeps working memory-only:
  * no model configured in C:\\ProgramData\\leCore+\\model.txt -> the rung answers "" (escalate), no call made;
  * llama-server down or still loading -> remote_llm raises, the rung answers "" (escalate);
  * "none" chosen in the chat's Settings -> the rung answers "".
It sends the per-machine llama-server API key (LECORE_PLUS_LLM_KEY_FILE) as the rung's Bearer token, serves
the chat page with the window title "Zero" (LECORE_PLUS_TITLE) and adds GET /zero/status.

LECORE_PLUS_EGRESS_GUARD=1 (CI smoke test) makes every non-loopback connect / DNS lookup from this
process fail and records it in logs\\egress-guard.log, which proves the chat itself never reaches out.
"""
import json
import os
import re
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("LECORE_PLUS_ROOT") or os.path.dirname(HERE)
LECORE = os.path.join(ROOT, "lecore")
DATA = os.environ.get("LECORE_PLUS_DATA") or os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "leCore+")
MODELS = os.path.join(DATA, "models")
MODEL_TXT = os.path.join(DATA, "model.txt")
HOST = "127.0.0.1"
PORT = int(os.environ.get("LECORE_PLUS_CHAT_PORT", "7860"))
TITLE = os.environ.get("LECORE_PLUS_TITLE", "Zero")
LLM_URL = os.environ.get("LECORE_LLM_URL", "")
LLM_TIMEOUT = float(os.environ.get("LECORE_PLUS_LLM_TIMEOUT", "300"))
LLM_KEY_FILE = os.environ.get("LECORE_PLUS_LLM_KEY_FILE") or os.path.join(DATA, "secret", "llama-api-key")


def log(msg):
    print("[zero-chat %s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


# ---------------------------------------------------------------------------------------------------
# CI egress guard
# ---------------------------------------------------------------------------------------------------
def _loopback(host):
    if host in ("localhost", "localhost.", "ip6-localhost"):
        return True
    try:
        import ipaddress
        return ipaddress.ip_address(str(host).split("%")[0]).is_loopback
    except ValueError:
        return False


def install_egress_guard():
    path = os.path.join(DATA, "logs", "egress-guard.log")

    def record(kind, target):
        line = json.dumps({"t": time.time(), "kind": kind, "target": str(target)})
        log("EGRESS BLOCKED %s %s" % (kind, target))
        try:
            with open(path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass

    real_connect, real_connect_ex = socket.socket.connect, socket.socket.connect_ex
    real_getaddrinfo = socket.getaddrinfo

    def check(sock, address):
        if sock.family in (socket.AF_INET, socket.AF_INET6) and isinstance(address, tuple):
            if not _loopback(address[0]):
                record("connect", address)
                raise PermissionError("zero egress: connection to %r refused by the leCore+ egress guard" % (address,))

    def connect(self, address):
        check(self, address)
        return real_connect(self, address)

    def connect_ex(self, address):
        check(self, address)
        return real_connect_ex(self, address)

    def getaddrinfo(host, *a, **k):
        if host is not None and not _loopback(host if isinstance(host, str) else host.decode()):
            record("dns", host)
            raise socket.gaierror(socket.EAI_NONAME, "zero egress: DNS lookup of %r refused by the leCore+ egress guard" % (host,))
        return real_getaddrinfo(host, *a, **k)

    socket.socket.connect = connect
    socket.socket.connect_ex = connect_ex
    socket.getaddrinfo = getaddrinfo
    log("egress guard ON (non-loopback connects and DNS lookups are refused and logged to %s)" % path)


# ---------------------------------------------------------------------------------------------------
# model rung
# ---------------------------------------------------------------------------------------------------
def configured_model():
    """Path of the model named in model.txt, or None when none is configured / the file is missing."""
    try:
        with open(MODEL_TXT, encoding="utf-8-sig") as f:
            name = f.readline().strip()
    except OSError:
        return None
    if not name:
        return None
    path = name if os.path.isabs(name) else os.path.join(MODELS, name)
    return path if os.path.isfile(path) else None


def llm_api_key():
    """The per-machine llama-server API key (install.ps1), read on every call; None if unreadable."""
    try:
        with open(LLM_KEY_FILE, encoding="ascii") as f:
            return f.read().strip() or None
    except OSError as e:
        log("cannot read the model server key %s (%s)" % (LLM_KEY_FILE, e))
        return None


def make_rung(chat_state):
    from holographic.io_and_interop.holographic_remotellm import remote_llm

    def rung(prompt, **kw):
        if chat_state.get("llm") in (None, "none"):
            return ""
        model = configured_model()
        if model is None:
            return ""
        alias = os.path.splitext(os.path.basename(model))[0]
        try:
            return remote_llm(url=LLM_URL, model=alias, api_key=llm_api_key(), timeout=LLM_TIMEOUT)(prompt, **kw)
        except Exception as e:  # llama-server down / loading: memory-only answer instead of a 500
            log("model rung unavailable: %s" % e)
            return ""

    rung.__name__ = "llama_cpp_rung"
    rung.endpoint = LLM_URL.rstrip("/") + "/chat/completions"
    return rung


def main():
    if os.environ.get("LECORE_PLUS_EGRESS_GUARD") == "1":
        install_egress_guard()
    os.environ.setdefault("LECORE_PARTITION", os.path.join(DATA, "memory"))
    sys.path.insert(0, LECORE)
    t0 = time.time()
    import chat_server  # leCore, unmodified
    from flask import Response, jsonify

    def home():
        with open(os.path.join(LECORE, "chat_ui.html"), encoding="utf-8") as f:
            html = f.read()
        html = re.sub(r"<title>.*?</title>", "<title>%s</title>" % TITLE, html, count=1, flags=re.S)
        return Response(html, mimetype="text/html")

    chat_server.APP.view_functions["home"] = home

    def status():
        m = configured_model()
        return jsonify({"product": TITLE, "chat": "http://%s:%d" % (HOST, PORT), "llm_url": LLM_URL or None,
                        "model": os.path.basename(m) if m else None, "rung": chat_server.STATE.get("llm"),
                        "partition": os.environ.get("LECORE_PARTITION")})

    chat_server.APP.add_url_rule("/zero/status", "zero_status", status)

    # Model containment at the HTTP layer (the browser is online now):
    #  * Host allow-list: a web page that DNS-rebinds its own name to 127.0.0.1 is refused, so no site
    #    can read the chat's answers or memory;
    #  * cross-site POSTs (Origin header from anywhere else) are refused;
    #  * Content-Security-Policy: the chat page can load nothing and send nothing outside 127.0.0.1, so
    #    text the model writes (e.g. an <img src=https://...>) cannot carry it off the machine.
    from flask import request as _req, abort as _abort
    allowed_hosts = {"127.0.0.1:%d" % PORT, "localhost:%d" % PORT, "[::1]:%d" % PORT}
    allowed_origins = {"http://" + h for h in allowed_hosts}

    def contain():
        if _req.host.lower() not in allowed_hosts:
            _abort(403)
        if _req.method not in ("GET", "HEAD", "OPTIONS"):
            origin = _req.headers.get("Origin")
            if origin and origin.lower() not in allowed_origins:
                _abort(403)

    def headers(resp):
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; media-src 'self' data: blob:; "
            "object-src 'none'; frame-src 'none'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["Referrer-Policy"] = "no-referrer"
        resp.headers["X-Frame-Options"] = "DENY"
        return resp

    chat_server.APP.before_request(contain)
    chat_server.APP.after_request(headers)

    m = chat_server._mind()
    log("leCore mind booted in %.1fs (partition %s)" % (time.time() - t0, os.environ.get("LECORE_PARTITION")))
    if LLM_URL:
        rung = make_rung(chat_server.STATE)
        m.zoo_attach(rung)
        m._zoo_llm = rung
        chat_server.STATE["llm"] = "llama.cpp"
        chat_server.STATE["llm_detail"] = LLM_URL
        cm = configured_model()
        log("model rung -> %s (model: %s)" % (LLM_URL, os.path.basename(cm) if cm else "none configured, memory-only"))
    else:
        log("LECORE_LLM_URL not set: memory-only")
    log("serving %s on http://%s:%d" % (TITLE, HOST, PORT))
    chat_server.APP.run(host=HOST, port=PORT, debug=False, use_reloader=False, threaded=True)


if __name__ == "__main__":
    main()
