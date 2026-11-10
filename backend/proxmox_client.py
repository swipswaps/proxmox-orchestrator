import os
from proxmoxer import ProxmoxAPI
def is_proxmox_configured():
    required = ["PROXMOX_HOST", "PROXMOX_USER",
                "PROXMOX_TOKEN_ID", "PROXMOX_TOKEN_SECRET"]
    return all(os.environ.get(k) for k in required)
def get_proxmox_connection():
    host = os.environ["PROXMOX_HOST"]
    user = os.environ["PROXMOX_USER"]
    token_id = os.environ["PROXMOX_TOKEN_ID"]
    token_secret = os.environ["PROXMOX_TOKEN_SECRET"]
    token_name = f"{user}!{token_id}"
    verify_ssl = os.environ.get("PROXMOX_VERIFY_SSL", "false").lower() == "true"
    timeout = int(os.environ.get("PROXMOX_TIMEOUT", "5"))
    return ProxmoxAPI(host, user=user, token_name=token_name,
                      token_value=token_secret, verify_ssl=verify_ssl,
                      service="PVE", timeout=timeout)
