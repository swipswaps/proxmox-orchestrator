#!/usr/bin/env bash
set +e
trap 'echo ""; echo "⚠️  Interrupted"; exit 130' INT

main() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  [ "$(basename "$SCRIPT_DIR")" = "scripts" ] && cd "$(dirname "$SCRIPT_DIR")"

  REPO_NAME="${REPO_NAME:-proxmox-orchestrator}"
  PAGES_BRANCH="gh-pages"
  NO_GH_PAGES="no"
  ERRORS=0
  for arg in "$@"; do case "$arg" in
    --no-gh-pages) NO_GH_PAGES="yes" ;;
  esac; done

  fail() { echo "❌ $1"; ERRORS=$((ERRORS + 1)); }
  ok()   { echo "✅ $1"; }
  info() { echo "ℹ️  $1"; }
  step() { echo ""; echo "▶ $1"; }
  warn() { echo "⚠️  $1"; }

  port_in_use() { ss -ltn 2>&1 | awk '{print $4}' | grep -qE "[:.]$1$"; }
  find_next_free() {
    local p="$1"
    while [ "$p" -le 65535 ]; do
      port_in_use "$p" || { echo "$p"; return 0; }
      p=$((p + 1))
    done
  }

  # ================================================================
  # 0. Pre-flight
  # ================================================================
  step "0. Pre-flight"
  local missing=""
  for tool in gh git docker node npm; do
    command -v "$tool" &>/dev/null && ok "$tool" || missing="$missing $tool"
  done
  [ -n "$missing" ] && { fail "Missing:$missing"; return "$ERRORS"; }
  local owner
  owner=$(gh api user --jq '.login' 2>&1) || owner=""
  if [ -z "$owner" ] || [ "${owner:0:3}" = "gh:" ]; then
    fail "gh not authenticated"; return "$ERRORS"
  fi
  ok "Authenticated as $owner"
  git config user.email &>/dev/null || git config user.email "build@localhost"
  git config user.name  &>/dev/null || git config user.name  "Build Script"

  # ================================================================
  # 1. Port
  # ================================================================
  step "1. Port"
  local BACKEND_PORT
  BACKEND_PORT=$(grep '^BACKEND_PORT=' .env 2>/dev/null | cut -d= -f2)
  [ -z "$BACKEND_PORT" ] && BACKEND_PORT=8000
  if port_in_use "$BACKEND_PORT"; then
    local next
    next=$(find_next_free $((BACKEND_PORT + 1)))
    info "Port $BACKEND_PORT busy → using $next"
    BACKEND_PORT=$next
  fi
  ok "Backend+UI will listen on :$BACKEND_PORT"
  echo "BACKEND_PORT=$BACKEND_PORT" > .env

  # ================================================================
  # 2. Git
  # ================================================================
  step "2. Git"
  if [ ! -d .git ]; then
    git init -b main || fail "git init failed"
  else
    local cur
    cur=$(git symbolic-ref --short HEAD 2>&1) || cur=""
    [ "$cur" != "main" ] && { git show-ref --verify --quiet refs/heads/main && git checkout main || git checkout -B main; }
  fi
  ok "Git on 'main'"

  # ================================================================
  # 3. Emit files
  # ================================================================
  step "3. Emit files"
  mkdir -p backend terraform ansible frontend/src frontend/public backend/data

  cat > backend/.env.example <<'EOF'
# PROXMOX_HOST: clean IPv4/hostname, or bracketed IPv6.
# Examples: 192.168.1.100   https://192.168.1.100:8006   https://[fe80::1]:8006
PROXMOX_HOST=
PROXMOX_USER=root@pam
PROXMOX_TOKEN_ID=
PROXMOX_TOKEN_SECRET=
PROXMOX_NODE=pve
PROXMOX_VERIFY_SSL=false
PROXMOX_TIMEOUT=5
DATABASE_PATH=/app/data/orchestrator.db
EOF

  cat > backend/requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.31.0
pydantic==2.9.2
proxmoxer==2.0.1
requests==2.32.3
ansible-core==2.17.3
python-dotenv==1.0.1
EOF

  cat > backend/database.py <<'EOF'
import sqlite3, os
DB_PATH = os.getenv("DATABASE_PATH", "/app/data/orchestrator.db")
def get_db_connection():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn
def init_db():
    conn = get_db_connection()
    with conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS deployments (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('lxc','vm')),
            target_node TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'PENDING',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
    conn.close()
EOF

  cat > backend/proxmox_client.py <<'EOF'
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
EOF

  cat > backend/main.py <<'EOF'
import os, subprocess
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel
from database import init_db, get_db_connection
from proxmox_client import get_proxmox_connection, is_proxmox_configured

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"],
                   allow_methods=["*"], allow_headers=["*"])

class DeploymentRequest(BaseModel):
    name: str; type: str; node: str; cores: int = 2; memory: int = 2048

@app.on_event("startup")
def startup_event(): init_db()

@app.get("/api/health")
def health(): return {"status": "ok"}

@app.get("/api/status")
def status():
    configured = is_proxmox_configured()
    connected = False; detail = ""
    if configured:
        try:
            get_proxmox_connection().version.get()
            connected = True
        except Exception as e:
            detail = "%s: %s" % (type(e).__name__, e)
    return {"backend":"ok","proxmox_configured":configured,
            "proxmox_connected":connected,"detail":detail}

@app.get("/api/nodes")
def list_nodes():
    if not is_proxmox_configured():
        return {"nodes":[],"proxmox_available":False,"message":"Proxmox not configured"}
    try:
        return {"nodes": get_proxmox_connection().nodes.get(), "proxmox_available": True}
    except Exception as e:
        return {"nodes":[],"proxmox_available":False,"message":str(e)}

@app.post("/api/deploy")
def trigger_deployment(req: DeploymentRequest):
    if not is_proxmox_configured():
        raise HTTPException(503, "Proxmox not configured")
    try:
        get_proxmox_connection().version.get()
    except Exception as e:
        raise HTTPException(503, "Proxmox unreachable: %s" % e)
    conn = get_db_connection(); cur = conn.cursor()
    cur.execute("INSERT INTO deployments (name,type,target_node,status) VALUES (?,?,?,?)",
                (req.name, req.type, req.node, "PENDING"))
    conn.commit(); dep_id = cur.lastrowid; conn.close()
    env = os.environ.copy()
    env.update({
        "TF_VAR_instance_name": req.name, "TF_VAR_target_node": req.node,
        "TF_VAR_cores": str(req.cores), "TF_VAR_memory": str(req.memory),
        "TF_VAR_instance_type": req.type})
    try:
        for cmd, t in [(["terraform","init","-upgrade"], 120),
                       (["terraform","apply","-auto-approve"], 600)]:
            p = subprocess.Popen(cmd, cwd="/app/terraform", env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
            _, err = p.communicate(timeout=t)
            if p.returncode != 0: raise RuntimeError(err.decode())
        conn = get_db_connection()
        conn.execute("UPDATE deployments SET status=? WHERE id=?", ("SUCCESS", dep_id))
        conn.commit(); conn.close()
        return {"status": "success", "deployment_id": dep_id}
    except Exception as e:
        conn = get_db_connection()
        conn.execute("UPDATE deployments SET status=? WHERE id=?", ("FAILED", dep_id))
        conn.commit(); conn.close()
        raise HTTPException(500, str(e))

@app.get("/api/deployments")
def get_deployments():
    conn = get_db_connection()
    rows = conn.execute("SELECT * FROM deployments ORDER BY created_at DESC").fetchall()
    conn.close()
    return [dict(r) for r in rows]

# Serve built UI from /app/dist when mounted
DIST = "/app/dist"
if os.path.isdir(DIST):
    if os.path.isdir(DIST + "/assets"):
        app.mount("/assets", StaticFiles(directory=DIST + "/assets"), name="assets")
    @app.get("/")
    def serve_index(): return FileResponse(DIST + "/index.html")
    @app.get("/{full_path:path}")
    def spa_fallback(full_path: str):
        if full_path.startswith(("api/", "assets/")):
            raise HTTPException(404)
        return FileResponse(DIST + "/index.html")
EOF

  cat > backend/Dockerfile <<'EOF'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip git openssh-client && rm -rf /var/lib/apt/lists/*
ARG TERRAFORM_VERSION=1.17.1
RUN curl -fsSLo /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/terraform && rm /tmp/terraform.zip
RUN pip install --no-cache-dir ansible-core==2.17.3
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["sh", "-c", "curl -f http://localhost:8000/api/health || kill -TERM 1"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

  cat > terraform/variables.tf <<'EOF'
variable "proxmox_api_url" { type = string; default = "https://192.168.1.100:8006/api2/json" }
variable "proxmox_api_token_id" { type = string; default = "root@pam!orchestrator" }
variable "proxmox_api_token_secret" { type = string; sensitive = true }
variable "target_node" { type = string; default = "pve" }
variable "instance_name" { type = string; default = "managed-node-01" }
variable "instance_type" { type = string; default = "lxc" }
variable "cores" { type = number; default = 2 }
variable "memory" { type = number; default = 2048 }
EOF

  cat > terraform/main.tf <<'EOF'
terraform {
  required_version = ">= 1.16.0"
  required_providers { proxmox = { source = "Telmate/proxmox", version = "3.0.2-rc10" } }
}
provider "proxmox" {
  pm_api_url = var.proxmox_api_url
  pm_api_token_id = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
  pm_tls_insecure = true
}
resource "proxmox_lxc" "container" {
  count = var.instance_type == "lxc" ? 1 : 0
  target_node = var.target_node; hostname = var.instance_name
  ostemplate = "local:vztmpl/debian-12-standard_12.2-1_amd64.zst"
  cores = var.cores; memory = var.memory; unprivileged = true; start = true
  rootfs { storage = "local-lvm"; size = "8G" }
  network { name = "eth0"; bridge = "vmbr0"; ip = "dhcp" }
}
resource "proxmox_vm_qemu" "vm" {
  count = var.instance_type == "vm" ? 1 : 0
  name = var.instance_name; target_node = var.target_node
  clone = "debian-12-template"; cores = var.cores; memory = var.memory
  agent = 1; os_type = "cloud-init"
  disk { size = "10G"; type = "scsi"; storage = "local-lvm" }
  network { model = "virtio"; bridge = "vmbr0" }
}
EOF

  cat > terraform/outputs.tf <<'EOF'
output "instance_ip" {
  value = try(proxmox_lxc.container[0].ssh_host,
              proxmox_vm_qemu.vm[0].default_ipv4_address, "unknown")
}
EOF

  cat > ansible/site.yml <<'EOF'
- hosts: all
  become: yes
  tasks:
    - dnf: { name: firewalld, state: present }
    - firewalld: { zone: drop, state: enabled, permanent: yes, immediate: yes }
    - lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PermitRootLogin'
        line: 'PermitRootLogin no'
        validate: '/usr/sbin/sshd -t -f %s'
      notify: restart sshd
    - selinux: { policy: targeted, state: enforcing }
  handlers:
    - systemd: { name: sshd, state: restarted }
      listen: restart sshd
EOF

  cat > frontend/package.json <<'EOF'
{
  "name": "orchestrator-ui", "private": true, "version": "1.0.0", "type": "module",
  "scripts": { "dev": "vite", "build": "vite build", "preview": "vite preview" },
  "dependencies": { "react": "^18.3.1", "react-dom": "^18.3.1" },
  "devDependencies": { "@vitejs/plugin-react": "4.3.4", "vite": "^5.4.21" }
}
EOF

  cat > frontend/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>Proxmox Orchestration Console</title></head>
<body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body></html>
EOF

  cat > frontend/src/main.jsx <<'EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
ReactDOM.createRoot(document.getElementById('root')).render(<React.StrictMode><App/></React.StrictMode>);
EOF

  cat > frontend/vite.config.js <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({
  plugins: [react()],
  base: './',
  server: { port: 3000, proxy: { '/api': { target: 'http://localhost:8000', changeOrigin: true } } }
})
EOF

  cat > frontend/src/App.jsx <<'EOF'
import React, { useState, useEffect } from 'react';
const API_BASE = import.meta.env.VITE_API_BASE || '';
export default function App() {
  const [deployments, setDeployments] = useState([]);
  const [state, setState] = useState({
    loading: true, backendOnline: false,
    proxmoxConfigured: false, proxmoxConnected: false, detail: '',
  });
  const [form, setForm] = useState({ name: '', node: 'pve', type: 'lxc' });

  useEffect(() => {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 3000);
    const offline = (d='') => setState({ loading:false, backendOnline:false,
      proxmoxConfigured:false, proxmoxConnected:false, detail:d });
    fetch(`${API_BASE}/api/health`, { signal: c.signal })
      .then(r => {
        if (!r.ok) { offline(`HTTP ${r.status}`); return; }
        return fetch(`${API_BASE}/api/status`)
          .then(r2 => r2.ok ? r2.json() : Promise.reject(new Error(`HTTP ${r2.status}`)))
          .then(s => setState({ loading:false, backendOnline:true,
            proxmoxConfigured:s.proxmox_configured,
            proxmoxConnected:s.proxmox_connected, detail:s.detail||'' }));
      })
      .catch(err => offline(err?.message || 'network error'))
      .finally(() => clearTimeout(t));
  }, []);

  useEffect(() => {
    if (!state.backendOnline) return;
    fetch(`${API_BASE}/api/deployments`).then(r => r.ok ? r.json() : [])
      .then(setDeployments).catch(() => {});
  }, [state.backendOnline]);

  const handleDeploy = async (e) => {
    e.preventDefault(); if (!state.proxmoxConnected) return;
    const r = await fetch(`${API_BASE}/api/deploy`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...form, cores: 2, memory: 2048 }) });
    if (r.ok) { alert('Deployment triggered!'); window.location.reload(); }
    else { const j = await r.json().catch(() => ({})); alert('Deploy failed: ' + (j.detail || r.status)); }
  };

  if (state.loading) return <p style={{ padding: 40 }}>Checking backend…</p>;
  const enabled = state.backendOnline && state.proxmoxConnected;
  let banner;
  if (!state.backendOnline) banner = { bg:'#fff3cd', color:'#856404',
    text:`⚠️ Backend unreachable${state.detail?` (${state.detail})`:''}. Demo mode.` };
  else if (!state.proxmoxConfigured) banner = { bg:'#cfe2ff', color:'#084298',
    text:'ℹ️ Backend online. Proxmox not configured — fill PROXMOX_* in backend/.env.' };
  else if (!state.proxmoxConnected) banner = { bg:'#fff3cd', color:'#856404',
    text:`⚠️ Proxmox configured but unreachable: ${state.detail}` };
  else banner = { bg:'#d1e7dd', color:'#0f5132', text:'✅ Backend online, Proxmox connected.' };

  return (
    <div style={{ fontFamily:'sans-serif', maxWidth:800, margin:'40px auto', padding:20 }}>
      <h2>Proxmox Remote Orchestration Console</h2>
      <div style={{ background:banner.bg, color:banner.color, padding:12, borderRadius:4, marginBottom:20 }}>{banner.text}</div>
      <form onSubmit={handleDeploy} style={{ display:'flex', gap:10, marginBottom:20, opacity:enabled?1:0.5 }}>
        <input type="text" placeholder="Instance Name" value={form.name}
          onChange={e => setForm({ ...form, name:e.target.value })} required disabled={!enabled} />
        <select value={form.type} onChange={e => setForm({ ...form, type:e.target.value })} disabled={!enabled}>
          <option value="lxc">LXC</option><option value="vm">VM</option>
        </select>
        <input type="text" placeholder="Target Node" value={form.node}
          onChange={e => setForm({ ...form, node:e.target.value })} required disabled={!enabled} />
        <button type="submit" disabled={!enabled}>Deploy</button>
      </form>
      <h3>Deployment History</h3>
      <table border="1" cellPadding="10" style={{ width:'100%', borderCollapse:'collapse' }}>
        <thead><tr><th>ID</th><th>Name</th><th>Type</th><th>Node</th><th>Status</th><th>Timestamp</th></tr></thead>
        <tbody>
          {deployments.length===0 && <tr><td colSpan="6" style={{ textAlign:'center' }}>No deployments.</td></tr>}
          {deployments.map(d => (
            <tr key={d.id}><td>{d.id}</td><td>{d.name}</td><td>{d.type}</td>
              <td>{d.target_node}</td><td>{d.status}</td><td>{d.created_at}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
EOF

  cat > frontend/public/404.html <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><script>
(function(){var s=location.pathname.split('/').filter(Boolean);
s.length>0?location.replace('/'+s[0]+'/'):location.replace('/');})();
</script></head><body></body></html>
EOF

  cat > docker-compose.yml <<'EOF'
services:
  backend:
    image: proxmox-orchestrator-backend
    build:
      context: ./backend
    restart: unless-stopped
    env_file:
      - backend/.env
    ports:
      - "${BACKEND_PORT:-8000}:8000"
    volumes:
      - ./backend/data:/app/data
      - ./terraform:/app/terraform
      - ./ansible:/app/ansible
      - ./frontend/dist:/app/dist:ro
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    networks:
      - orchestrator_net
networks:
  orchestrator_net:
    driver: bridge
EOF

  cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.venv/
venv/
*.db
*.sqlite
node_modules/
dist/
.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
*.retry
.env
.env.tmp
*.bak
.DS_Store
EOF

  [ -f backend/.env ] || cp backend/.env.example backend/.env
  mkdir -p backend/data
  [ "$(id -u)" -ne 1000 ] && chmod 0777 backend/data &>/dev/null
  ok "Files emitted"

  # ================================================================
  # 4. Validate PROXMOX_HOST
  # ================================================================
  step "4. Validate PROXMOX_HOST"
  if grep -q '^PROXMOX_HOST=' backend/.env; then
    local host_val
    host_val=$(grep '^PROXMOX_HOST=' backend/.env | cut -d= -f2-)
    if [ -z "$host_val" ]; then
      warn "PROXMOX_HOST empty — backend runs Proxmox-free (OK)"
    elif { [[ "$host_val" == *"["* ]] && [[ "$host_val" != *"]"* ]]; } || \
         { [[ "$host_val" == *"]"* ]] && [[ "$host_val" != *"["* ]]; }; then
      fail "PROXMOX_HOST has unmatched brackets: $host_val"
    else
      ok "PROXMOX_HOST well-formed: $host_val"
    fi
  fi

  # ================================================================
  # 5. Frontend build
  # ================================================================
  step "5. Frontend build (base='./')"
  if pushd frontend &>/dev/null; then
    [ -f package-lock.json ] || npm install --legacy-peer-deps
    npm ci --legacy-peer-deps || fail "npm ci"
    rm -rf dist
    npm run build || fail "Vite build"
    [ -d dist ] && ok "dist/ produced" || fail "dist/ missing"
    popd &>/dev/null
  else
    fail "Cannot cd into frontend"
  fi

  # ================================================================
  # 6. Commit + push
  # ================================================================
  step "6. Commit + push"
  git add -A
  if git diff --cached --quiet; then
    ok "No changes"
  else
    git commit -m "v8: serve UI from backend" || fail "commit failed"
    ok "Committed"
  fi
  if gh repo view "$owner/$REPO_NAME" &>/dev/null; then
    ok "Repo exists"
  else
    gh repo create "$REPO_NAME" --public --source=. --remote=origin --push || fail "create failed"
  fi
  git remote get-url origin &>/dev/null || git remote add origin "https://github.com/$owner/$REPO_NAME.git"
  git push -u origin main || fail "push failed"
  ok "Pushed main"

  # ================================================================
  # 7. gh-pages
  # ================================================================
  if [ "$NO_GH_PAGES" = "no" ]; then
    step "7. gh-pages + Pages"
    if [ -d frontend/dist ] && pushd frontend &>/dev/null; then
      npx --yes gh-pages -d dist -r "https://github.com/$owner/$REPO_NAME.git" \
        || fail "gh-pages deploy failed"
      popd &>/dev/null
      ok "gh-pages pushed"
    fi
    local waited=0 found=""
    while [ "$waited" -lt 60 ]; do
      if git ls-remote --exit-code --heads origin "$PAGES_BRANCH" &>/dev/null; then
        found="yes"; break
      fi
      sleep 3; waited=$((waited + 3))
    done
    if [ -n "$found" ]; then
      if gh api "repos/$owner/$REPO_NAME/pages" --silent &>/dev/null; then
        gh api "repos/$owner/$REPO_NAME/pages" -X PUT --input - &>/dev/null <<JSON || fail "PUT"
{"source":{"branch":"$PAGES_BRANCH","path":"/"}}
JSON
        ok "Pages updated"
      else
        gh api "repos/$owner/$REPO_NAME/pages" -X POST --input - &>/dev/null <<JSON || fail "POST"
{"source":{"branch":"$PAGES_BRANCH","path":"/"}}
JSON
        ok "Pages enabled"
      fi
    else
      fail "gh-pages not found after 60s"
    fi
  else
    step "7. gh-pages (skipped)"
  fi

  # ================================================================
  # 8. Backend
  # ================================================================
  step "8. Backend"
  info "Removing any old container from prior runs ..."
  docker rm -f proxmox-orchestrator-backend &>/dev/null
  info "Building image ..."
  docker compose build backend || fail "build failed"
  info "Starting container ..."
  docker compose up -d --force-recreate backend || fail "up failed"

  local hwaited=0 healthy=""
  while [ "$hwaited" -lt 60 ]; do
    if curl -fsS --max-time 5 "http://localhost:$BACKEND_PORT/api/health" &>/dev/null; then
      healthy="yes"; break
    fi
    sleep 2; hwaited=$((hwaited + 2))
  done
  if [ -n "$healthy" ]; then ok "API healthy after ${hwaited}s"
  else fail "API not healthy — see: docker compose logs backend"; fi

  if curl -fsS --max-time 5 "http://localhost:$BACKEND_PORT/" 2>&1 | grep -qi '<!DOCTYPE html'; then
    ok "UI served at http://localhost:$BACKEND_PORT/"
  else
    fail "UI not served — check ./frontend/dist is mounted"
  fi

  # ================================================================
  # 9. Summary
  # ================================================================
  step "Summary"
  echo ""
  if [ "$ERRORS" -eq 0 ]; then
    echo "🎉 ONE-SHOT BUILD SUCCEEDED"
    echo ""
    echo "  ★ LOCAL APP:  http://localhost:$BACKEND_PORT/"
    echo "                http://localhost:$BACKEND_PORT/api/health"
    echo ""
    if [ "$NO_GH_PAGES" = "no" ]; then
      echo "  Hosted demo:  https://$owner.github.io/$REPO_NAME/"
      echo "                (backend-unreachable banner is expected)"
      echo ""
    fi
    echo "  Backend status:"
    curl -s --max-time 5 "http://localhost:$BACKEND_PORT/api/status" | python3 -m json.tool 2>&1 || true
    echo ""
    echo "  If Proxmox unreachable: edit backend/.env, then:"
    echo "    docker compose up -d --force-recreate backend"
    echo ""
    echo "  Re-run:  ./$BUILD_SCRIPT --no-gh-pages   (local only)"
    if command -v xdg-open &>/dev/null; then xdg-open "http://localhost:$BACKEND_PORT/" &>/dev/null &
    elif command -v open &>/dev/null; then open "http://localhost:$BACKEND_PORT/" &>/dev/null &
    fi
  else
    echo "🔥 COMPLETED WITH $ERRORS ERROR(S)"
    echo "  Logs: docker compose logs backend"
  fi
  return "$ERRORS"
}

main "$@"
