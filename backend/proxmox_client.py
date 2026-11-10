import os
from urllib.parse import urlsplit, urlunsplit
from proxmoxer import ProxmoxAPI

def _clean_host(raw):
    h = (raw or "").strip()
    if not h: return ""
    if ("[" in h and "]" not in h) or ("]" in h and "[" not in h):
        raise ValueError("PROXMOX_HOST has unmatched brackets: %r" % h)
    if not h.startswith(("http://","https://")): h = "https://" + h
    parts = urlsplit(h)
    if not parts.hostname: raise ValueError("PROXMOX_HOST has no host: %r" % raw)
    netloc = parts.hostname + (":%d" % parts.port if parts.port else "")
    return urlunsplit((parts.scheme, netloc, "", "", ""))

def is_proxmox_configured():
    return all(os.environ.get(k) for k in
               ["PROXMOX_HOST","PROXMOX_USER","PROXMOX_TOKEN_ID","PROXMOX_TOKEN_SECRET"])

def get_proxmox_connection():
    os.environ.pop("NO_PROXY", None)
    os.environ.pop("no_proxy", None)
    user = os.environ["PROXMOX_USER"]
    if "@" not in user:
        raise ValueError("PROXMOX_USER must include @realm, e.g. root@pam")
    host = _clean_host(os.environ["PROXMOX_HOST"])
    return ProxmoxAPI(host, user=user,
        token_name="%s!%s" % (user, os.environ["PROXMOX_TOKEN_ID"]),
        token_value=os.environ["PROXMOX_TOKEN_SECRET"],
        verify_ssl=os.environ.get("PROXMOX_VERIFY_SSL","false").lower()=="true",
        service="PVE", timeout=int(os.environ.get("PROXMOX_TIMEOUT","5")))
