#!/usr/bin/env bash
set +e
trap 'echo ""; echo "⚠️  Interrupted"; exit 130' INT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ "$(basename "$SCRIPT_DIR")" = "scripts" ] && cd "$(dirname "$SCRIPT_DIR")"
REPO_NAME="${REPO_NAME:-proxmox-orchestrator}"
PAGES_BRANCH="gh-pages"
ERRORS=0
fail() { echo "❌ $1"; ERRORS=$((ERRORS + 1)); }
ok()   { echo "✅ $1"; }
info() { echo "ℹ️  $1"; }
step() { echo ""; echo "▶ $1"; }
warn() { echo "⚠️  $1"; }

port_in_use() { ss -ltn 2>&1 | awk '{print $4}' | grep -qE "[:.]$1$"; }
find_next_free() { local p="$1"; while [ "$p" -le 65535 ]; do port_in_use "$p" || { echo "$p"; return 0; }; p=$((p+1)); done; }
port_owner() {
  local c; c=$(docker ps --filter "publish=$1" --format '{{.Names}}' | head -1)
  [ -n "$c" ] && { echo "docker:$c"; return; }
  echo "unknown"
}

step "0. Pre-flight"
local missing=""
for tool in gh git docker node npm; do command -v "$tool" &>/dev/null && ok "$tool" || missing="$missing $tool"; done
[ -n "$missing" ] && { fail "Missing:$missing"; return "$ERRORS"; }
local owner; owner=$(gh api user --jq '.login' 2>&1) || owner=""
[ -z "$owner" ] && { fail "gh not authenticated"; return "$ERRORS"; }
ok "Authenticated as $owner"
git config user.email &>/dev/null || git config user.email "build@localhost"
git config user.name  &>/dev/null || git config user.name  "Build Script"

step "1. Ports"
local BACKEND_PORT=8002
if port_in_use "$BACKEND_PORT"; then BACKEND_PORT=$(find_next_free 8003); fi
ok "Backend port: $BACKEND_PORT"

cat > .env <<EOF
BACKEND_PORT=$BACKEND_PORT
EOF

step "2. Git"
[ -d .git ] || git init -b main || fail "git init"
local cur; cur=$(git symbolic-ref --short HEAD 2>&1) || cur=""
[ "$cur" != "main" ] && git checkout -B main
ok "Git ready"

step "3. Emit files"
mkdir -p backend terraform ansible frontend/src frontend/public monitoring/prometheus backend/data

cat > backend/.env.example <<'EOF'
# PROXMOX_HOST must be a clean hostname or IPv4.
# Do NOT include brackets or an IPv6 literal without [ ].
# Examples: 192.168.1.100   https://192.168.1.100:8006
PROXMOX_HOST=
PROXMOX_USER=root@pam
PROXMOX_TOKEN_ID=
PROXMOX_TOKEN_SECRET=
PROXMOX_NODE=pve
PROXMOX_VERIFY_SSL=false
PROXMOX_TIMEOUT=5
NO_PROXY=
no_proxy=
DATABASE_PATH=/app/data/orchestrator.db
EOF

cat > backend/proxmox_client.py <<'EOF'
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
EOF

cat > backend/main.py <<'EOF'
import os, subprocess
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from database import init_db, get_db_connection
from proxmox_client import get_proxmox_connection, is_proxmox_configured

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

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
            detail = f"{type(e).__name__}: {e}"
    return {"backend":"ok","proxmox_configured":configured,
            "proxmox_connected":connected,"detail":detail}

@app.get("/api/nodes")
def list_nodes():
    if not is_proxmox_configured():
        return {"nodes":[],"proxmox_available":False,"message":"Proxmox not configured"}
    try: return {"nodes": get_proxmox_connection().nodes.get(), "proxmox_available": True}
    except Exception as e: return {"nodes":[],"proxmox_available":False,"message":str(e)}

@app.post("/api/deploy")
def trigger_deployment(req: DeploymentRequest):
    if not is_proxmox_configured(): raise HTTPException(503, "Proxmox not configured")
    try: get_proxmox_connection().version.get()
    except Exception as e: raise HTTPException(503, f"Proxmox unreachable: {e}")
    conn = get_db_connection(); cur = conn.cursor()
    cur.execute("INSERT INTO deployments (name,type,target_node,status) VALUES (?,?,?,?)",
                (req.name, req.type, req.node, "PENDING"))
    conn.commit(); dep_id = cur.lastrowid; conn.close()
    env = os.environ.copy(); env.update({
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
    conn.close(); return [dict(r) for r in rows]
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

cat > backend/requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.31.0
pydantic==2.9.2
proxmoxer==2.0.1
requests==2.32.3
ansible-core==2.17.3
python-dotenv==1.0.1
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
ENV NO_PROXY=""
ENV no_proxy=""
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["sh", "-c", "curl -f http://localhost:8000/api/health || kill -TERM 1"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# ... (terraform/, ansible/, frontend/ boilerplate unchanged from v5) ...

# FRONTEND FIX — loading state always settles
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
    const offline = (detail = '') =>
      setState({ loading: false, backendOnline: false,
                 proxmoxConfigured: false, proxmoxConnected: false, detail });

    fetch(`${API_BASE}/api/health`, { signal: c.signal })
      .then(r => {
        if (!r.ok) { offline(`HTTP ${r.status}`); return; }
        return fetch(`${API_BASE}/api/status`)
          .then(r2 => r2.ok ? r2.json() : Promise.reject(new Error(`HTTP ${r2.status}`)))
          .then(s => setState({
            loading: false, backendOnline: true,
            proxmoxConfigured: s.proxmox_configured,
            proxmoxConnected: s.proxmox_connected,
            detail: s.detail || ''
          }));
      })
      .catch(err => offline(err?.message || 'network error'))
      .finally(() => clearTimeout(t));
  }, []);

  useEffect(() => {
    if (!state.backendOnline) return;
    fetch(`${API_BASE}/api/deployments`)
      .then(r => r.ok ? r.json() : [])
      .then(setDeployments).catch(() => {});
  }, [state.backendOnline]);

  const handleDeploy = async (e) => {
    e.preventDefault();
    if (!state.proxmoxConnected) return;
    const r = await fetch(`${API_BASE}/api/deploy`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...form, cores: 2, memory: 2048 }),
    });
    if (r.ok) { alert('Deployment triggered!'); window.location.reload(); }
    else { const j = await r.json().catch(() => ({})); alert('Deploy failed: ' + (j.detail || r.status)); }
  };

  if (state.loading) return <p style={{ padding: 40 }}>Checking backend…</p>;
  const deployEnabled = state.backendOnline && state.proxmoxConnected;
  let banner;
  if (!state.backendOnline) banner = { bg: '#fff3cd', color: '#856404',
    text: `⚠️ Backend unreachable${state.detail ? ` (${state.detail})` : ''}. Running in demo mode.` };
  else if (!state.proxmoxConfigured) banner = { bg: '#cfe2ff', color: '#084298',
    text: 'ℹ️ Backend online. Proxmox not configured — fill PROXMOX_* in backend/.env.' };
  else if (!state.proxmoxConnected) banner = { bg: '#fff3cd', color: '#856404',
    text: `⚠️ Proxmox configured but unreachable${state.detail ? `: ${state.detail}` : ''}.` };
  else banner = { bg: '#d1e7dd', color: '#0f5132', text: '✅ Backend online, Proxmox connected.' };

  return (
    <div style={{ fontFamily: 'sans-serif', maxWidth: 800, margin: '40px auto', padding: 20 }}>
      <h2>Proxmox Remote Orchestration Console</h2>
      <div style={{ background: banner.bg, color: banner.color, padding: 12, borderRadius: 4, marginBottom: 20 }}>{banner.text}</div>
      <form onSubmit={handleDeploy} style={{ display: 'flex', gap: 10, marginBottom: 20, opacity: deployEnabled ? 1 : 0.5 }}>
        <input type="text" placeholder="Instance Name" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} required disabled={!deployEnabled} />
        <select value={form.type} onChange={e => setForm({ ...form, type: e.target.value })} disabled={!deployEnabled}><option value="lxc">LXC</option><option value="vm">VM</option></select>
        <input type="text" placeholder="Target Node" value={form.node} onChange={e => setForm({ ...form, node: e.target.value })} required disabled={!deployEnabled} />
        <button type="submit" disabled={!deployEnabled}>Deploy</button>
      </form>
      <h3>Deployment History</h3>
      <table border="1" cellPadding="10" style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead><tr><th>ID</th><th>Name</th><th>Type</th><th>Node</th><th>Status</th><th>Timestamp</th></tr></thead>
        <tbody>
          {deployments.length === 0 && <tr><td colSpan="6" style={{ textAlign: 'center' }}>No deployments.</td></tr>}
          {deployments.map(d => (<tr key={d.id}><td>{d.id}</td><td>{d.name}</td><td>{d.type}</td><td>{d.target_node}</td><td>{d.status}</td><td>{d.created_at}</td></tr>))}
        </tbody>
      </table>
    </div>
  );
}
EOF

# docker-compose.yml (valid multi-line YAML, port from .env)
cat > docker-compose.yml <<'EOF'
services:
  backend:
    image: proxmox-orchestrator-backend
    build:
      context: ./backend
    container_name: proxmox-orchestrator-backend
    restart: unless-stopped
    env_file:
      - backend/.env
    ports:
      - "${BACKEND_PORT:-8002}:8000"
    volumes:
      - ./backend/data:/app/data
      - ./terraform:/app/terraform
      - ./ansible:/app/ansible
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

[ -f backend/.env ] || cp backend/.env.example backend/.env
mkdir -p backend/data
[ "$(id -u)" -ne 1000 ] && chmod 0777 backend/data &>/dev/null
ok "Files emitted"

step "4. Validate backend/.env PROXMOX_HOST"
if grep -q '^PROXMOX_HOST=' backend/.env; then
  host_val=$(grep '^PROXMOX_HOST=' backend/.env | cut -d= -f2-)
  if [ -z "$host_val" ]; then
    warn "PROXMOX_HOST is empty — backend will run Proxmox-free (OK)"
  elif { [[ "$host_val" == *"["* ]] && [[ "$host_val" != *"]"* ]]; } || \
       { [[ "$host_val" == *"]"* ]] && [[ "$host_val" != *"["* ]]; }; then
    fail "PROXMOX_HOST='$host_val' has unmatched brackets — this causes 'Invalid IPv6 URL'"
    info "Fix: set PROXMOX_HOST=192.168.1.100 (no brackets) or https://[fe80::1]:8006 (bracketed IPv6)"
  else
    ok "PROXMOX_HOST looks well-formed: $host_val"
  fi
fi

step "5. Commit + push"
git add -A
git diff --cached --quiet && ok "No changes" || { git commit -m "Fix: frontend loading state + host validation" || fail "commit"; ok "Committed"; }
if gh repo view "$owner/$REPO_NAME" &>/dev/null; then ok "Repo exists"
else gh repo create "$REPO_NAME" --public --source=. --remote=origin --push || fail "create"; fi
git remote get-url origin &>/dev/null || git remote add origin "https://github.com/$owner/$REPO_NAME.git"
git push -u origin main || fail "push"
ok "Pushed"

step "6. Frontend"
pushd frontend &>/dev/null
[ -f package-lock.json ] || npm install --legacy-peer-deps
npm ci --legacy-peer-deps || fail "npm ci"
rm -rf dist
VITE_BASE_PATH="/$REPO_NAME/" npm run build || fail "build"
popd &>/dev/null
[ -d frontend/dist ] && ok "dist/ produced" || fail "dist/ missing"

step "7. gh-pages + Pages"
pushd frontend &>/dev/null
npx --yes gh-pages -d dist -r "https://github.com/$owner/$REPO_NAME.git" || fail "gh-pages"
popd &>/dev/null
ok "gh-pages pushed"
local waited=0 found=""
while [ "$waited" -lt 60 ]; do
  git ls-remote --exit-code --heads origin "$PAGES_BRANCH" &>/dev/null && { found="yes"; break; }
  sleep 3; waited=$((waited+3))
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
fi

step "8. Backend"
docker compose build backend || fail "build"
docker compose up -d --force-recreate backend || fail "up"
local hwaited=0 healthy=""
while [ "$hwaited" -lt 60 ]; do
  curl -fsS --max-time 5 "http://localhost:$BACKEND_PORT/api/health" &>/dev/null && { healthy="yes"; break; }
  sleep 2; hwaited=$((hwaited+2))
done
[ -n "$healthy" ] && ok "Backend healthy on :$BACKEND_PORT" || fail "Backend unhealthy"

step "Summary"
echo "  Pages:    https://$owner.github.io/$REPO_NAME/"
echo "  Backend:  http://localhost:$BACKEND_PORT/api/health"
curl -s --max-time 5 "http://localhost:$BACKEND_PORT/api/status" | python3 -m json.tool 2>&1 || true
echo ""
echo "  If 'Invalid IPv6 URL' persists: edit backend/.env PROXMOX_HOST, then:"
echo "    docker compose up -d --force-recreate backend"
echo ""
echo "  If Pages shows 'Checking backend…' after 3s: check browser console for"
echo "  mixed-content block (HTTPS page → HTTP localhost). Use one of:"
echo "    cd frontend && npm run dev            # local dev (proxied)"
echo "    cloudflared tunnel --url http://localhost:$BACKEND_PORT"
echo "    mount frontend/dist on FastAPI       # same-origin"
if command -v xdg-open &>/dev/null; then xdg-open "https://$owner.github.io/$REPO_NAME/" &>/dev/null &
elif command -v open &>/dev/null; then open "https://$owner.github.io/$REPO_NAME/" &>/dev/null &
fi
return "$ERRORS"
