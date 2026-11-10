PROXMOX REMOTE ORCHESTRATION ENGINE — HARDENED BUILD
====================================================
OVERVIEW
--------
Secure bridge between a React/Vite dashboard and a Proxmox VE hypervisor.
Terraform provisions infrastructure; Ansible hardens guests; FastAPI
tracks jobs in SQLite. The frontend auto-detects the backend and degrades
gracefully to demo mode when unreachable.

IDEMPOTENT BUILD
----------------
build_and_deploy.sh is safe to re-run. From a fresh directory, a partial
build, or a previously-successful build, it converges to the same state.

PREREQUISITES
-------------
• Proxmox VE 8.x/9.x with API token (user@realm!tokenid)
• Docker (or Podman) with buildx plugin
• Node.js ≥ 18, npm
• gh CLI authenticated with 'repo' scope:  gh auth refresh -s repo

QUICK START
-----------
1. Populate backend/.env (copy backend/.env.example)
2. docker build -t proxmox-orchestrator-backend ./backend
3. docker run -d -p 8000:8000 --env-file backend/.env \
     -v "$(pwd)/backend/data:/app/data" proxmox-orchestrator-backend
4. Visit https://<owner>.github.io/<repo>/
