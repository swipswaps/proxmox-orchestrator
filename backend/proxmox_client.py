import os
from urllib.parse import urlsplit, urlunsplit
from proxmoxer import ProxmoxAPI

def _clean_host(raw: str) -> str:
    """Return a PROXMOX_HOST safe for urllib/proxmoxer.
    Strips stray brackets, normalises scheme, removes trailing slash.
    """
    h = (raw or "").strip()
    if not h:
        return ""
    # Reject unmatched brackets early with a clear message
    if ("[" in h and "]" not in h) or ("]" in h and "[" not in h):
        raise ValueError(
            f"PROXMOX_HOST={h!r} has an unmatched bracket. "
            "Use a plain IPv4/hostname (e.g. 192.168.1.100) or a bracketed "
            "IPv6 literal (e.g. https://[fe80::1]:8006)."
        )
    if not h.startswith(("http://", "https://")):
        h = "https://" + h
    parts = urlsplit(h)
    host = parts.hostname or ""
    if not host:
        raise ValueError(f"PROXMOX_HOST={raw!r} has no host component")
    netloc = host
    if parts.port:
        netloc = f"{host}:{parts.port}"
    return urlunsplit((parts.scheme, netloc, "", "", ""))

def is_proxmox_configured() -> bool:
    return all(os.environ.get(k) for k in
               ["PROXMOX_HOST","PROXMOX_USER","PROXMOX_TOKEN_ID","PROXMOX_TOKEN_SECRET"])

def get_proxmox_connection():
    # Drop any proxy env that can make httpx choke on IPv6 CIDRs
    os.environ.pop("NO_PROXY", None)
    os.environ.pop("no_proxy", None)
    user = os.environ["PROXMOX_USER"]
    if "@" not in user:
        raise ValueError("PROXMOX_USER must include @realm, e.g. root@pam")
    host = _clean_host(os.environ["PROXMOX_HOST"])
    return ProxmoxAPI(
        host, user=user,
        token_name=f"{user}!{os.environ['PROXMOX_TOKEN_ID']}",
        token_value=os.environ["PROXMOX_TOKEN_SECRET"],
        verify_ssl=os.environ.get("PROXMOX_VERIFY_SSL","false").lower()=="true",
        service="PVE",
        timeout=int(os.environ.get("PROXMOX_TIMEOUT","5")),
    )
