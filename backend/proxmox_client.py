import os
from proxmoxer import ProxmoxAPI
def get_proxmox_connection():
    host = os.environ["PROXMOX_HOST"]
    user = os.environ["PROXMOX_USER"]
    token_id = os.environ["PROXMOX_TOKEN_ID"]
    token_secret = os.environ["PROXMOX_TOKEN_SECRET"]
    token_name = f"{user}!{token_id}"
    return ProxmoxAPI(host, user=user, token_name=token_name,
                      token_value=token_secret, verify_ssl=False, service="PVE")
