#!/usr/bin/env bash
# fix.sh — idempotent fix (Proxmox-free backend support)
FIX_ERRORS=0
fix_fail() { echo "❌ $1"; FIX_ERRORS=$((FIX_ERRORS + 1)); }
fix_ok()   { echo "✅ $1"; }
fix_step() { echo ""; echo "▶ $1"; }

# Write file if content differs; backup prior version.
safe_write_file() {
  target="$1"
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$target" ] && cmp -s "$target" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  if [ -f "$target" ]; then cp "$target" "$target.bak"; fi
  mkdir -p "$(dirname "$target")"
  cp "$tmp" "$target"
  rm -f "$tmp"
  fix_ok "$target updated"
}

fix_main() {
  fix_step "Fix 0: backend/.env (never overwritten)"
  if [ -f backend/.env ]; then
    fix_ok "backend/.env exists (untouched)"
  else
    cat > backend/.env <<'ENV'
PROXMOX_HOST=
PROXMOX_USER=
PROXMOX_TOKEN_ID=
PROXMOX_TOKEN_SECRET=
PROXMOX_NODE=pve
PROXMOX_VERIFY_SSL=false
PROXMOX_TIMEOUT=5
DATABASE_PATH=/app/data/orchestrator.db
ENV
    fix_ok "Created backend/.env (empty Proxmox creds — safe for Proxmox-free run)"
  fi

  fix_step "Fix 1: backend code (graceful Proxmox-free operation)"
  safe_write_file backend/proxmox_client.py <<'PY'
import os
from proxmoxer import ProxmoxAPI

def is_proxmox_configured() -> bool:
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
PY

  safe_write_file backend/main.py <<'PY'
import os, subprocess
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from database import init_db, get_db_connection
from proxmox_client import get_proxmox_connection, is_proxmox_configured

app = FastAPI(title="Proxmox Orchestration Engine")
app.add_middleware(CORSMiddleware, allow_origins=["*"],
                   allow_methods=["*"], allow_headers=["*"])

class DeploymentRequest(BaseModel):
    name: str
    type: str
    node: str
    cores: int = 2
    memory: int = 2048

@app.on_event("startup")
def startup_event():
    init_db()

@app.get("/api/health")
def health():
    return {"status": "ok"}

@app.get("/api/status")
def status():
    configured = is_proxmox_configured()
    connected = False
    detail = ""
    if configured:
        try:
            get_proxmox_connection().version.get()
            connected = True
        except Exception as e:
            detail = str(e)
    return {"backend": "ok", "proxmox_configured": configured,
            "proxmox_connected": connected, "detail": detail}

@app.get("/api/nodes")
def list_nodes():
    if not is_proxmox_configured():
        return {"nodes": [], "proxmox_available": False,
                "message": "Proxmox not configured"}
    try:
        return {"nodes": get_proxmox_connection().nodes.get(),
                "proxmox_available": True}
    except Exception as e:
        return {"nodes": [], "proxmox_available": False, "message": str(e)}

@app.post("/api/deploy")
def trigger_deployment(req: DeploymentRequest):
    if not is_proxmox_configured():
        raise HTTPException(503, "Proxmox not configured — set PROXMOX_* in backend/.env")
    try:
        get_proxmox_connection().version.get()
    except Exception as e:
        raise HTTPException(503, f"Proxmox unreachable: {e}")

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("INSERT INTO deployments (name,type,target_node,status) VALUES (?,?,?,?)",
                (req.name, req.type, req.node, "PENDING"))
    conn.commit()
    dep_id = cur.lastrowid
    conn.close()

    env = os.environ.copy()
    env.update({
        "TF_VAR_instance_name": req.name,
        "TF_VAR_target_node": req.node,
        "TF_VAR_cores": str(req.cores),
        "TF_VAR_memory": str(req.memory),
        "TF_VAR_instance_type": req.type,
    })
    try:
        init = subprocess.Popen(["terraform","init","-upgrade"], cwd="/app/terraform",
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        _, err = init.communicate(timeout=120)
        if init.returncode != 0:
            raise RuntimeError(err.decode())
        apply = subprocess.Popen(["terraform","apply","-auto-approve"], cwd="/app/terraform",
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        _, err = apply.communicate(timeout=600)
        if apply.returncode != 0:
            raise RuntimeError(err.decode())
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
PY

  safe_write_file backend/.env.example <<'ENV'
# Leave empty to run backend WITHOUT Proxmox (health/status/deployments work).
# Fill in when Proxmox host is ready, then: docker compose up -d --force-recreate
PROXMOX_HOST=
PROXMOX_USER=
PROXMOX_TOKEN_ID=
PROXMOX_TOKEN_SECRET=
PROXMOX_NODE=pve
PROXMOX_VERIFY_SSL=false
PROXMOX_TIMEOUT=5
DATABASE_PATH=/app/data/orchestrator.db
ENV

  fix_step "Fix 2: frontend App.jsx (three-state banner)"
  safe_write_file frontend/src/App.jsx <<'JSX'
import React, { useState, useEffect } from 'react';
const API_BASE = import.meta.env.VITE_API_BASE || '';
export default function App() {
  const [deployments, setDeployments] = useState([]);
  const [state, setState] = useState({
    loading: true, backendOnline: false, proxmoxConfigured: false,
    proxmoxConnected: false, detail: '',
  });
  const [form, setForm] = useState({ name: '', node: 'pve', type: 'lxc' });
  useEffect(() => {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 3000);
    fetch(`${API_BASE}/api/health`, { signal: c.signal })
      .then(r => { if (!r.ok) return; return fetch(`${API_BASE}/api/status`).then(r2 => r2.json()); })
      .then(s => { if (s) setState({ loading: false, backendOnline: true,
        proxmoxConfigured: s.proxmox_configured,
        proxmoxConnected: s.proxmox_connected, detail: s.detail || '' }); })
      .catch(() => setState(prev => ({ ...prev, loading: false })))
      .finally(() => clearTimeout(t));
  }, []);
  useEffect(() => {
    if (!state.backendOnline) return;
    fetch(`${API_BASE}/api/deployments`).then(r => r.json())
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
  if (!state.backendOnline) {
    banner = { bg: '#fff3cd', color: '#856404',
      text: '⚠️ Backend unreachable. Running in demo mode — deployment controls disabled.' };
  } else if (!state.proxmoxConfigured) {
    banner = { bg: '#cfe2ff', color: '#084298',
      text: 'ℹ️ Backend online. Proxmox not configured yet — fill PROXMOX_* in backend/.env and restart.' };
  } else if (!state.proxmoxConnected) {
    banner = { bg: '#fff3cd', color: '#856404',
      text: '⚠️ Backend online, Proxmox configured but unreachable. Check network / credentials.' };
  } else {
    banner = { bg: '#d1e7dd', color: '#0f5132',
      text: '✅ Backend online, Proxmox connected.' };
  }
  return (
    <div style={{ fontFamily: 'sans-serif', maxWidth: 800, margin: '40px auto', padding: 20 }}>
      <h2>Proxmox Remote Orchestration Console</h2>
      <div style={{ background: banner.bg, color: banner.color,
                    padding: 12, borderRadius: 4, marginBottom: 20 }}>{banner.text}</div>
      <form onSubmit={handleDeploy} style={{ display: 'flex', gap: 10, marginBottom: 20,
                                             opacity: deployEnabled ? 1 : 0.5 }}>
        <input type="text" placeholder="Instance Name" value={form.name}
          onChange={e => setForm({ ...form, name: e.target.value })} required disabled={!deployEnabled} />
        <select value={form.type} onChange={e => setForm({ ...form, type: e.target.value })} disabled={!deployEnabled}>
          <option value="lxc">LXC</option><option value="vm">VM</option>
        </select>
        <input type="text" placeholder="Target Node" value={form.node}
          onChange={e => setForm({ ...form, node: e.target.value })} required disabled={!deployEnabled} />
        <button type="submit" disabled={!deployEnabled}>Deploy</button>
      </form>
      <h3>Deployment History</h3>
      <table border="1" cellPadding="10" style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead><tr><th>ID</th><th>Name</th><th>Type</th><th>Node</th><th>Status</th><th>Timestamp</th></tr></thead>
        <tbody>
          {deployments.length === 0 && <tr><td colSpan="6" style={{ textAlign: 'center' }}>No deployments.</td></tr>}
          {deployments.map(d => (
            <tr key={d.id}><td>{d.id}</td><td>{d.name}</td><td>{d.type}</td>
              <td>{d.target_node}</td><td>{d.status}</td><td>{d.created_at}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
JSX

  fix_step "Fix 3: docker-compose.yml (simple env_file — file guaranteed to exist)"
  safe_write_file docker-compose.yml <<'YAML'
version: '3.8'
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
      - "8000:8000"
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
YAML

  fix_step "Fix 4: backend/data + .gitignore"
  mkdir -p backend/data
  fix_ok "backend/data ready"
  if [ -f .gitignore ]; then
    if ! grep -qx '\.env' .gitignore; then
      printf '.env\n' >> .gitignore
      fix_ok ".gitignore now excludes .env"
    else
      fix_ok ".gitignore already excludes .env"
    fi
  fi

  fix_step "Fix 5: validate compose"
  if docker compose config &>/dev/null; then
    fix_ok "docker compose config valid"
  else
    fix_fail "docker compose config invalid"
  fi

  fix_step "Fix 6: rebuild backend image (picks up code changes)"
  if docker compose build backend; then
    fix_ok "Image rebuilt"
  else
    fix_fail "Image rebuild failed"
  fi

  if [ "$START_MODE" = "yes" ]; then
    fix_step "Fix 7: start backend and wait for health"
    if docker compose up -d; then
      fix_ok "docker compose up -d succeeded"
      waited=0
      healthy=""
      while [ "$waited" -lt 60 ]; do
        if curl -fsS http://localhost:8000/api/health &>/dev/null; then
          healthy="yes"; break
        fi
        sleep 2
        waited=$((waited + 2))
      done
      if [ -n "$healthy" ]; then
        fix_ok "Backend healthy after ${waited}s"
      else
        fix_fail "Backend not responding within 60s"
        echo "  Logs: docker compose logs backend"
      fi
    else
      fix_fail "docker compose up -d failed"
    fi
  else
    fix_step "Fix 7: start backend (skipped)"
    echo "  Run: bash bootstrap.sh --start"
  fi

  fix_step "Summary"
  if [ "$FIX_ERRORS" -eq 0 ]; then
    echo "🎉 FIXES APPLIED"
  else
    echo "🔥 COMPLETED WITH $FIX_ERRORS ERROR(S)"
  fi
}

START_MODE=""
for arg in "$@"; do
  case "$arg" in
    --fix)   ;;  # accepted but no-op (fix is the default action)
    --start) START_MODE="yes" ;;
  esac
done

main() {
  if [ "${1:-}" != "--fix" ] && [ "${1:-}" != "--start" ] && [ -z "${1:-}" ]; then
    echo "This script modifies files. To apply fixes, run:"
    echo "  ./fix.sh --fix             # apply file fixes"
    echo "  ./fix.sh --fix --start     # apply fixes AND start backend"
    echo ""
    echo "Read-only audit: ./audit.sh"
    return 0
  fi
  fix_main
  return "$FIX_ERRORS"
}

main "$@"
