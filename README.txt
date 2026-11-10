PROXMOX REMOTE ORCHESTRATION ENGINE — HARDENED BUILD
====================================================
OVERVIEW
--------
Secure bridge between a React/Vite dashboard and a Proxmox VE hypervisor.
Terraform provisions infrastructure; Ansible hardens guests; FastAPI backend
tracks jobs in SQLite. The frontend auto-detects the backend and degrades
gracefully to demo mode when unreachable.

PREREQUISITES
-------------
• Proxmox VE 8.x/9.x with API token (user@realm!tokenid).
• Docker (or Podman) on the control node.
• Node.js ≥ 18 and npm.
• gh CLI authenticated with 'repo' scope (run: gh auth refresh -s repo).

QUICK START
-----------
1. Populate backend/.env (copy backend/.env.example).
2. docker build -t proxmox-orchestrator-backend ./backend
3. docker run -d -p 8000:8000 --env-file backend/.env \
     -v $(pwd)/backend/data:/app/data proxmox-orchestrator-backend
4. Visit https://<owner>.github.io/<repo>/ — the frontend detects the backend
   if reachable; otherwise it shows a demo-mode banner.

FORBIDDEN CONSTRUCTS
--------------------
This project intentionally avoids: sed, set -e, exit 1, 2>/dev/null,
and subprocess.run. All subprocess calls use Popen with start_new_session=True.
