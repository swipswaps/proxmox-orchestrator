#!/usr/bin/env bash
# build_and_deploy.sh — idempotent, pre-scan, no duplicate instances
set +e
trap 'echo ""; echo "⚠️  Interrupted"; exit 130' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ "$(basename "$SCRIPT_DIR")" = "scripts" ] && cd "$(dirname "$SCRIPT_DIR")"

REPO_NAME="${REPO_NAME:-proxmox-orchestrator}"
PAGES_BRANCH="gh-pages"
NON_INTERACTIVE="no"
FORCE_PORTS="no"
AUTO_FREE="no"
SKIP_MONITORING="no"
ERRORS=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y)              NON_INTERACTIVE="yes" ;;
    --ports|-p)            FORCE_PORTS="yes" ;;
    --free|-f)             AUTO_FREE="yes" ;;
    --skip-monitoring|-m)  SKIP_MONITORING="yes" ;;
  esac
done

fail() { echo "❌ $1"; ERRORS=$((ERRORS + 1)); }
ok()   { echo "✅ $1"; }
info() { echo "ℹ️  $1"; }
step() { echo ""; echo "▶ $1"; }

# ================================================================
# Detection
# ================================================================
port_in_use() {
  local p="$1"
  if command -v ss &>/dev/null; then
    ss -ltn 2>&1 | awk '{print $4}' | grep -qE "[:.]$p$"
  elif command -v netstat &>/dev/null; then
    netstat -ltn 2>&1 | awk '{print $4}' | grep -qE "[:.]$p$"
  else
    return 1
  fi
}

port_owner() {
  local p="$1" c pid
  c=$(docker ps --filter "publish=$p" --format '{{.Names}}' 2>&1 | head -n1)
  [ -n "$c" ] && { echo "docker:$c"; return; }
  if command -v ss &>/dev/null; then
    pid=$(ss -ltnp 2>&1 | grep ":$p " | grep -o 'pid=[0-9]*' | head -n1 | cut -d= -f2)
  fi
  if [ -n "$pid" ] && [ -r "/proc/$pid/comm" ]; then
    echo "process:$(cat "/proc/$pid/comm") ($pid)"
  else
    echo "unknown"
  fi
}

detect_service_container() {
  local service="$1"
  docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}' 2>&1 | \
    awk -F'|' -v svc="$service" '
      tolower($2) ~ tolower(svc) && tolower($1) !~ /proxmox-orchestrator/ {
        print
      }'
}

extract_host_port() {
  echo "$1" | grep -oE '0\.0\.0\.0:[0-9]+->' | head -n1 | cut -d: -f2 | cut -d- -f1
}

find_next_free() {
  local p="$1"
  while [ "$p" -le 65535 ]; do
    port_in_use "$p" || { echo "$p"; return 0; }
    p=$((p + 1))
  done
  return 1
}

# ================================================================
# Save incremental state so Ctrl+C doesn't lose progress
# ================================================================
save_env_partial() {
  cat > .env.tmp <<EOF
# Partial state — will be renamed to .env when complete
BACKEND_PORT=$BACKEND_PORT
DOCKGE_PORT=$DOCKGE_PORT
PROMETHEUS_PORT=$PROM_PORT
CADVISOR_PORT=$CADVISOR_PORT
GRAFANA_PORT=$GRAFANA_PORT
SKIP_DOCKGE=$SKIP_DOCKGE
SKIP_PROMETHEUS=$SKIP_PROMETHEUS
SKIP_CADVISOR=$SKIP_CADVISOR
SKIP_GRAFANA=$SKIP_GRAFANA
EXISTING_DOCKGE_PORT=$EXISTING_DOCKGE_PORT
EXISTING_PROMETHEUS_PORT=$EXISTING_PROMETHEUS_PORT
EXISTING_CADVISOR_PORT=$EXISTING_CADVISOR_PORT
EXISTING_GRAFANA_PORT=$EXISTING_GRAFANA_PORT
EOF
}

# ================================================================
# Pre-scan landscape
# ================================================================
scan_landscape() {
  step "1. Port landscape scan"
  echo "  Inspecting default ports before prompting anything."
  echo ""
  printf "  %-12s %-6s %-30s %s\n" "SERVICE" "PORT" "OWNER" "REUSABLE?"
  printf "  %-12s %-6s %-30s %s\n" "--------" "----" "-----" "---------"

  local svc port owner reusable status
  for pair in "backend:8000" "dockge:5001" "prometheus:9090" "cadvisor:9091" "grafana:3001"; do
    svc="${pair%%:*}"; port="${pair##*:}"
    if ! port_in_use "$port"; then
      printf "  %-12s %-6s %-30s %s\n" "$svc" "$port" "(free)" "—"
      continue
    fi
    owner=$(port_owner "$port")
    if [ "$svc" = "backend" ]; then
      status="no (unique)"
    else
      reusable=$(detect_service_container "$svc")
      [ -n "$reusable" ] && status="YES" || status="no (different svc)"
    fi
    printf "  %-12s %-6s %-30s %s\n" "$svc" "$port" "$owner" "$status"
  done
  echo ""
}

# ================================================================
# Smart port resolution — only prompt when there's a real decision
# ================================================================
resolve_port() {
  local service="$1" label="$2" default="$3" current="$4"
  local svc_upper; svc_upper=$(echo "$service" | tr '[:lower:]' '[:upper:]')
  local skip_var="SKIP_$svc_upper"
  local ex_var="EXISTING_${svc_upper}_PORT"

  # 1. Try saved value from .env (silent if still free)
  if [ "$FORCE_PORTS" != "yes" ] && [ -n "$current" ] && ! port_in_use "$current"; then
    eval "$skip_var=no"; eval "$ex_var=\"\""
    echo "$current"; return
  fi

  # 2. If default is free → use it silently, no prompt at all
  if [ "$FORCE_PORTS" != "yes" ] && ! port_in_use "$default"; then
    eval "$skip_var=no"; eval "$ex_var=\"\""
    echo "$default"; return
  fi

  # 3. Conflict — detect if there's a reusable existing service
  local existing=""
  [ "$service" != "backend" ] && existing=$(detect_service_container "$service")

  if [ -n "$existing" ]; then
    # Reusable conflict — need user decision
    local ex_name ex_image ex_ports ex_port
    ex_name=$(echo "$existing" | head -n1 | cut -d'|' -f1)
    ex_image=$(echo "$existing" | head -n1 | cut -d'|' -f2)
    ex_ports=$(echo "$existing" | head -n1 | cut -d'|' -f3)
    ex_port=$(extract_host_port "$ex_ports")
    [ -z "$ex_port" ] && ex_port="$default"

    if [ "$NON_INTERACTIVE" = "yes" ]; then
      if [ "$AUTO_FREE" = "yes" ]; then
        info "Replacing $service ($ex_name) per --free flag"
        docker stop "$ex_name" &>/dev/null
        eval "$skip_var=no"; eval "$ex_var=\"\""
        echo "$default"
      else
        info "Reusing $service ($ex_name) at :$ex_port (--yes mode)"
        eval "$skip_var=yes"; eval "$ex_var=$ex_port"
        echo "$ex_port"
      fi
      return
    fi

    # Interactive: 3-way prompt
    echo "" >&2
    echo "  $label" >&2
    echo "    ⚠️  Existing $service detected:" >&2
    echo "        Container: $ex_name" >&2
    echo "        Image:     $ex_image" >&2
    echo "        Host port: :$ex_port" >&2
    echo "" >&2
    echo "    Two instances = two data stores, two admins, wasted RAM." >&2
    echo "" >&2
    echo "    [S] Reuse existing $service on :$ex_port  (recommended)" >&2
    echo "    [P] Pick new port — run a second $service" >&2
    echo "    [R] Replace — stop $ex_name, run ours on :$default" >&2
    printf "    Choice [S/p/r] (Enter=S, 15s auto): " >&2
    local choice=""; read -t 15 -r choice; echo "" >&2
    choice="${choice:-S}"
    case "$choice" in
      [Pp]*)
        local n; n=$(find_next_free $((default + 1)))
        info "Second $service will run on :$n" >&2
        eval "$skip_var=no"; eval "$ex_var=\"\""
        echo "$n"
        ;;
      [Rr]*)
        info "Stopping $ex_name to replace with ours" >&2
        docker stop "$ex_name" &>/dev/null
        eval "$skip_var=no"; eval "$ex_var=\"\""
        echo "$default"
        ;;
      *)
        eval "$skip_var=yes"; eval "$ex_var=$ex_port"
        info "Will reuse existing $service at :$ex_port" >&2
        echo "$ex_port"
        ;;
    esac
    return
  fi

  # 4. Non-reusable conflict — auto-suggest + single-key prompt
  local suggested; suggested=$(find_next_free $((default + 1)))
  [ -z "$suggested" ] && suggested="$default"
  local owner; owner=$(port_owner "$default")

  if [ "$NON_INTERACTIVE" = "yes" ]; then
    info "$label: $default busy ($owner) → using $suggested"
    eval "$skip_var=no"; eval "$ex_var=\"\""
    echo "$suggested"; return
  fi

  echo "" >&2
  echo "  $label" >&2
  echo "    $default busy by: $owner" >&2
  echo "    (This is NOT a $service instance — cannot reuse.)" >&2
  echo "    Suggested: :$suggested" >&2
  echo "    [Enter] use $suggested  |  [s] skip this service" >&2
  printf "    Choice: " >&2
  local choice=""; read -t 15 -r choice; echo "" >&2

  case "$choice" in
    [Ss]*)
      info "Skipping $service — will not run" >&2
      eval "$skip_var=yes"; eval "$ex_var=\"\""
      echo "0"  # sentinel
      ;;
    *)
      eval "$skip_var=no"; eval "$ex_var=\"\""
      echo "$suggested"
      ;;
  esac
}

# ================================================================
# main()
# ================================================================
main() {

  step "0. Pre-flight"
  local missing=""
  for tool in gh git docker node npm; do
    command -v "$tool" &>/dev/null && ok "$tool" || missing="$missing $tool"
  done
  [ -n "$missing" ] && { fail "Missing:$missing"; return "$ERRORS"; }
  docker buildx version &>/dev/null && ok "docker buildx" || fail "buildx missing"

  local owner
  owner=$(gh api user --jq '.login' 2>&1) || owner=""
  if [ -z "$owner" ] || [ "${owner:0:3}" = "gh:" ]; then
    fail "gh not authenticated. Run: gh auth login && gh auth refresh -s repo"
    return "$ERRORS"
  fi
  ok "Authenticated as $owner"
  git config user.email &>/dev/null || git config user.email "build@localhost"
  git config user.name  &>/dev/null || git config user.name  "Build Script"

  # ----------------------------------------------------------------
  # 1. Pre-scan
  # ----------------------------------------------------------------
  scan_landscape

  # ----------------------------------------------------------------
  # 2. Resolve ports (only prompts on genuine decisions)
  # ----------------------------------------------------------------
  step "2. Port resolution (only prompts on conflicts)"
  SKIP_DOCKGE=no; SKIP_PROMETHEUS=no; SKIP_CADVISOR=no; SKIP_GRAFANA=no
  EXISTING_DOCKGE_PORT=""; EXISTING_PROMETHEUS_PORT=""
  EXISTING_CADVISOR_PORT=""; EXISTING_GRAFANA_PORT=""

  local BACKEND_PORT DOCKGE_PORT PROM_PORT CADVISOR_PORT GRAFANA_PORT
  local PORTS_SAVED="no"

  # Load saved state (including .env.tmp from interrupted run)
  local env_source=""
  [ -f .env ] && env_source=".env"
  [ -f .env.tmp ] && env_source=".env.tmp"
  if [ -n "$env_source" ] && [ "$FORCE_PORTS" != "yes" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        BACKEND_PORT) BACKEND_PORT="$value" ;;
        DOCKGE_PORT)  DOCKGE_PORT="$value" ;;
        PROMETHEUS_PORT) PROM_PORT="$value" ;;
        CADVISOR_PORT) CADVISOR_PORT="$value" ;;
        GRAFANA_PORT)  GRAFANA_PORT="$value" ;;
        SKIP_DOCKGE)   SKIP_DOCKGE="$value" ;;
        SKIP_PROMETHEUS) SKIP_PROMETHEUS="$value" ;;
        SKIP_CADVISOR) SKIP_CADVISOR="$value" ;;
        SKIP_GRAFANA)  SKIP_GRAFANA="$value" ;;
        EXISTING_GRAFANA_PORT) EXISTING_GRAFANA_PORT="$value" ;;
        EXISTING_PROMETHEUS_PORT) EXISTING_PROMETHEUS_PORT="$value" ;;
        EXISTING_CADVISOR_PORT) EXISTING_CADVISOR_PORT="$value" ;;
        EXISTING_DOCKGE_PORT) EXISTING_DOCKGE_PORT="$value" ;;
      esac
    done < "$env_source"
    [ -n "$BACKEND_PORT" ] && [ -n "$DOCKGE_PORT" ] && [ -n "$PROM_PORT" ] && \
      [ -n "$CADVISOR_PORT" ] && [ -n "$GRAFANA_PORT" ] && PORTS_SAVED="yes"
    [ "$PORTS_SAVED" = "yes" ] && ok "Resuming from $env_source"
  fi

  if [ "$PORTS_SAVED" != "yes" ]; then
    BACKEND_PORT=$(resolve_port "backend"    "Backend API" 8000 "${BACKEND_PORT:-}")
    save_env_partial
    DOCKGE_PORT=$(resolve_port  "dockge"     "Dockge UI"   5001 "${DOCKGE_PORT:-}")
    save_env_partial
    PROM_PORT=$(resolve_port    "prometheus" "Prometheus"  9090 "${PROM_PORT:-}")
    save_env_partial
    CADVISOR_PORT=$(resolve_port "cadvisor"  "cAdvisor"    9091 "${CADVISOR_PORT:-}")
    save_env_partial
    GRAFANA_PORT=$(resolve_port "grafana"    "Grafana"     3001 "${GRAFANA_PORT:-}")
    save_env_partial

    # Handle skips reported as port=0
    [ "$BACKEND_PORT" = "0" ] && { fail "Backend cannot be skipped"; BACKEND_PORT=8001; }
    [ "$DOCKGE_PORT" = "0" ]  && SKIP_DOCKGE=yes
    [ "$PROM_PORT" = "0" ]    && SKIP_PROMETHEUS=yes
    [ "$CADVISOR_PORT" = "0" ] && SKIP_CADVISOR=yes
    [ "$GRAFANA_PORT" = "0" ] && SKIP_GRAFANA=yes

    save_env_partial
    mv .env.tmp .env
    ok ".env finalized"
    info "  Backend=$BACKEND_PORT  Dockge=$( [ "$SKIP_DOCKGE" = yes ] && echo SKIP || echo $DOCKGE_PORT )"
    info "  Prom=$( [ "$SKIP_PROMETHEUS" = yes ] && echo SKIP || echo $PROM_PORT )  cAdv=$( [ "$SKIP_CADVISOR" = yes ] && echo SKIP || echo $CADVISOR_PORT )  Grafana=$( [ "$SKIP_GRAFANA" = yes ] && echo SKIP || echo $GRAFANA_PORT )"
  fi

  # ----------------------------------------------------------------
  # 3. Git
  # ----------------------------------------------------------------
  step "3. Git repository"
  if [ ! -d .git ]; then
    git init -b main || fail "git init failed"
  else
    local cur; cur=$(git symbolic-ref --short HEAD 2>&1) || cur=""
    [ "$cur" != "main" ] && { git show-ref --verify --quiet refs/heads/main && git checkout main || git checkout -b main; }
  fi
  ok "Git ready on 'main'"

  # ----------------------------------------------------------------
  # 4. Emit project files
  # ----------------------------------------------------------------
  step "4. Emitting project files"
  mkdir -p backend terraform ansible frontend/src frontend/public \
           monitoring/prometheus monitoring/dockge backend/data

  cat > README.txt <<'EOF'
PROXMOX REMOTE ORCHESTRATION ENGINE
See .env for ports and reuse decisions.
Backend: FastAPI (unique, always started)
Monitoring: Dockge, Prometheus, cAdvisor, Grafana (reusable if already running)

Flags:
  -y, --yes             non-interactive (auto-reuse compatible services)
  -p, --ports           force re-pick every port
  -f, --free            stop conflicting containers and replace
  -m, --skip-monitoring skip all monitoring (backend only)
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

  cat > backend/.env.example <<'EOF'
PROXMOX_HOST=
PROXMOX_USER=root@pam
PROXMOX_TOKEN_ID=
PROXMOX_TOKEN_SECRET=
PROXMOX_NODE=pve
PROXMOX_VERIFY_SSL=false
PROXMOX_TIMEOUT=5
DATABASE_PATH=/app/data/orchestrator.db
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
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('lxc','vm')),
            target_node TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'PENDING',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
    conn.close()
EOF

  cat > backend/proxmox_client.py <<'EOF'
import os
from proxmoxer import ProxmoxAPI
def is_proxmox_configured() -> bool:
    return all(os.environ.get(k) for k in
               ["PROXMOX_HOST","PROXMOX_USER","PROXMOX_TOKEN_ID","PROXMOX_TOKEN_SECRET"])
def get_proxmox_connection():
    user = os.environ["PROXMOX_USER"]
    if "@" not in user:
        raise ValueError("PROXMOX_USER must include @realm, e.g. root@pam")
    return ProxmoxAPI(
        os.environ["PROXMOX_HOST"], user=user,
        token_name=f"{user}!{os.environ['PROXMOX_TOKEN_ID']}",
        token_value=os.environ["PROXMOX_TOKEN_SECRET"],
        verify_ssl=os.environ.get("PROXMOX_VERIFY_SSL","false").lower()=="true",
        service="PVE",
        timeout=int(os.environ.get("PROXMOX_TIMEOUT","5")))
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
        try: get_proxmox_connection().version.get(); connected = True
        except Exception as e: detail = str(e)
    return {"backend":"ok","proxmox_configured":configured,"proxmox_connected":connected,"detail":detail}

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
    if not is_proxmox_configured(): raise HTTPException(503, "Proxmox not configured")
    try: get_proxmox_connection().version.get()
    except Exception as e: raise HTTPException(503, f"Proxmox unreachable: {e}")
    conn = get_db_connection()
    cur = conn.cursor()
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
    conn.close()
    return [dict(r) for r in rows]
EOF

  cat > backend/Dockerfile <<'EOF'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip git openssh-client && rm -rf /var/lib/apt/lists/*
ARG TERRAFORM_VERSION=1.17.1
RUN curl -fsSLo /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/terraform \
    && rm /tmp/terraform.zip
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
  required_providers {
    proxmox = { source = "Telmate/proxmox", version = "3.0.2-rc10" }
  }
}
provider "proxmox" {
  pm_api_url          = var.proxmox_api_url
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
  pm_tls_insecure     = true
}
resource "proxmox_lxc" "container" {
  count        = var.instance_type == "lxc" ? 1 : 0
  target_node  = var.target_node
  hostname     = var.instance_name
  ostemplate   = "local:vztmpl/debian-12-standard_12.2-1_amd64.zst"
  cores        = var.cores
  memory       = var.memory
  unprivileged = true
  start        = true
  rootfs { storage = "local-lvm"; size = "8G" }
  network { name = "eth0"; bridge = "vmbr0"; ip = "dhcp" }
}
resource "proxmox_vm_qemu" "vm" {
  count       = var.instance_type == "vm" ? 1 : 0
  name        = var.instance_name
  target_node = var.target_node
  clone       = "debian-12-template"
  cores       = var.cores
  memory      = var.memory
  agent       = 1
  os_type     = "cloud-init"
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
    - firewalld:
        zone: drop
        rich_rule: 'rule family="ipv4" source address="192.168.0.0/16" service name="ssh" accept'
        permanent: yes
        immediate: yes
        state: enabled
    - lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PermitRootLogin'
        line: 'PermitRootLogin no'
        validate: '/usr/sbin/sshd -t -f %s'
      notify: restart sshd
    - lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PasswordAuthentication'
        line: 'PasswordAuthentication no'
        validate: '/usr/sbin/sshd -t -f %s'
      notify: restart sshd
    - selinux: { policy: targeted, state: enforcing }
    - dnf: { name: dnf-automatic, state: present }
      notify: enable dnf-automatic
  handlers:
    - systemd: { name: sshd, state: restarted }
      listen: restart sshd
    - systemd: { name: dnf-automatic.timer, state: started, enabled: yes }
      listen: enable dnf-automatic
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
  base: process.env.VITE_BASE_PATH || '/',
  server: { port: 3000, proxy: { '/api': { target: 'http://localhost:8000', changeOrigin: true } } }
})
EOF

  cat > frontend/src/App.jsx <<'EOF'
import React, { useState, useEffect } from 'react';
const API_BASE = import.meta.env.VITE_API_BASE || '';
export default function App() {
  const [deployments, setDeployments] = useState([]);
  const [state, setState] = useState({ loading: true, backendOnline: false, proxmoxConfigured: false, proxmoxConnected: false, detail: '' });
  const [form, setForm] = useState({ name: '', node: 'pve', type: 'lxc' });
  useEffect(() => {
    const c = new AbortController(); const t = setTimeout(() => c.abort(), 3000);
    fetch(`${API_BASE}/api/health`, { signal: c.signal })
      .then(r => { if (!r.ok) return; return fetch(`${API_BASE}/api/status`).then(r2 => r2.json()); })
      .then(s => { if (s) setState({ loading: false, backendOnline: true, proxmoxConfigured: s.proxmox_configured, proxmoxConnected: s.proxmox_connected, detail: s.detail || '' }); })
      .catch(() => setState(prev => ({ ...prev, loading: false })))
      .finally(() => clearTimeout(t));
  }, []);
  useEffect(() => {
    if (!state.backendOnline) return;
    fetch(`${API_BASE}/api/deployments`).then(r => r.json()).then(setDeployments).catch(() => {});
  }, [state.backendOnline]);
  const handleDeploy = async (e) => {
    e.preventDefault(); if (!state.proxmoxConnected) return;
    const r = await fetch(`${API_BASE}/api/deploy`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...form, cores: 2, memory: 2048 }) });
    if (r.ok) { alert('Deployment triggered!'); window.location.reload(); }
    else { const j = await r.json().catch(() => ({})); alert('Deploy failed: ' + (j.detail || r.status)); }
  };
  if (state.loading) return <p style={{ padding: 40 }}>Checking backend…</p>;
  const deployEnabled = state.backendOnline && state.proxmoxConnected;
  let banner;
  if (!state.backendOnline) banner = { bg: '#fff3cd', color: '#856404', text: '⚠️ Backend unreachable.' };
  else if (!state.proxmoxConfigured) banner = { bg: '#cfe2ff', color: '#084298', text: 'ℹ️ Backend online. Proxmox not configured.' };
  else if (!state.proxmoxConnected) banner = { bg: '#fff3cd', color: '#856404', text: '⚠️ Proxmox configured but unreachable.' };
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
          {deployments.map(d => (
            <tr key={d.id}><td>{d.id}</td><td>{d.name}</td><td>{d.type}</td><td>{d.target_node}</td><td>{d.status}</td><td>{d.created_at}</td></tr>
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
    build: { context: ./backend }
    container_name: proxmox-orchestrator-backend
    restart: unless-stopped
    env_file: [ backend/.env ]
    ports: [ "${BACKEND_PORT:-8000}:8000" ]
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
    networks: [ orchestrator_net ]
networks:
  orchestrator_net: { driver: bridge }
EOF

  cat > docker-compose.monitoring.yml <<'EOF'
services:
  dockge:
    image: louislam/dockge:1.5.0
    container_name: dockge
    restart: unless-stopped
    ports: [ "${DOCKGE_PORT:-5001}:5001" ]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./monitoring/dockge:/app/data
      - /opt/stacks:/opt/stacks
    environment: [ "DOCKGE_STACKS_DIR=/opt/stacks" ]
    networks: [ monitoring ]

  prometheus:
    image: prom/prometheus:v3.15.1
    container_name: prometheus
    restart: unless-stopped
    ports: [ "${PROMETHEUS_PORT:-9090}:9090" ]
    volumes:
      - ./monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prom-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=7d'
    networks: [ monitoring ]
    extra_hosts: [ "host.docker.internal:host-gateway" ]

  cadvisor:
    image: ghcr.io/google/cadvisor:v0.60.6
    container_name: cadvisor
    restart: unless-stopped
    ports: [ "${CADVISOR_PORT:-9091}:8080" ]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    privileged: true
    devices: [ /dev/kmsg ]
    networks: [ monitoring ]

  grafana:
    image: grafana/grafana:12.4.2
    container_name: grafana
    restart: unless-stopped
    ports: [ "${GRAFANA_PORT:-3001}:3000" ]
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=change-me-now
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes: [ grafana-data:/var/lib/grafana ]
    networks: [ monitoring ]
    depends_on: [ prometheus ]

volumes:
  prom-data:
  grafana-data:

networks:
  monitoring: { driver: bridge }
EOF

  if [ "$SKIP_CADVISOR" = "yes" ] && [ -n "$EXISTING_CADVISOR_PORT" ]; then
    CADVISOR_TARGET="host.docker.internal:${EXISTING_CADVISOR_PORT}"
  else
    CADVISOR_TARGET="cadvisor:8080"
  fi

  cat > monitoring/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'cadvisor'
    scrape_interval: 5s
    static_configs:
      - targets: ['$CADVISOR_TARGET']
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
  ok "All project files emitted"

  # ----------------------------------------------------------------
  # 5. Commit + push
  # ----------------------------------------------------------------
  step "5. Commit + push"
  git add -A
  git diff --cached --quiet && ok "No changes" || { git commit -m "Build: sync" || fail "commit failed"; ok "Committed"; }

  step "6. GitHub repo"
  if gh repo view "$owner/$REPO_NAME" &>/dev/null; then ok "Repo exists"
  else gh repo create "$REPO_NAME" --public --source=. --remote=origin --push || fail "create failed"; fi
  git remote get-url origin &>/dev/null || git remote add origin "https://github.com/$owner/$REPO_NAME.git"
  git push -u origin main || fail "push failed"
  ok "Pushed main"

  # ----------------------------------------------------------------
  # 7. Frontend build + gh-pages
  # ----------------------------------------------------------------
  step "7. Frontend + gh-pages"
  if pushd frontend &>/dev/null; then
    if [ ! -f package-lock.json ]; then
      npm install --legacy-peer-deps || fail "npm install failed"
      git add package-lock.json
    fi
    npm ci --legacy-peer-deps || fail "npm ci failed"
    rm -rf dist
    VITE_BASE_PATH="/$REPO_NAME/" npm run build || fail "Vite build failed"
    [ -d dist ] && ok "dist/ produced" || fail "dist/ missing"
    popd &>/dev/null
  fi
  if [ -d frontend/dist ] && pushd frontend &>/dev/null; then
    npx --yes gh-pages -d dist -r "https://github.com/$owner/$REPO_NAME.git" || fail "gh-pages deploy failed"
    popd &>/dev/null
    ok "gh-pages pushed"
  fi

  step "8. Wait for gh-pages + enable Pages"
  local waited=0 found=""
  while [ "$waited" -lt 60 ]; do
    git ls-remote --exit-code --heads origin "$PAGES_BRANCH" &>/dev/null && { found="yes"; break; }
    sleep 3; waited=$((waited + 3))
  done
  if [ -n "$found" ]; then
    ok "gh-pages found"
    if gh api "repos/$owner/$REPO_NAME/pages" --silent &>/dev/null; then
      gh api "repos/$owner/$REPO_NAME/pages" -X PUT --input - &>/dev/null <<JSON || fail "Pages PUT failed"
{"source":{"branch":"$PAGES_BRANCH","path":"/"}}
JSON
      ok "Pages updated"
    else
      gh api "repos/$owner/$REPO_NAME/pages" -X POST --input - &>/dev/null <<JSON || fail "Pages POST failed"
{"source":{"branch":"$PAGES_BRANCH","path":"/"}}
JSON
      ok "Pages enabled"
    fi
  else
    fail "gh-pages not found"
  fi

  # ----------------------------------------------------------------
  # 9. Backend
  # ----------------------------------------------------------------
  step "9. Backend"
  docker compose build backend || fail "build failed"
  docker compose up -d || fail "up failed"
  local hwaited=0 healthy=""
  while [ "$hwaited" -lt 60 ]; do
    curl -fsS --max-time 5 "http://localhost:$BACKEND_PORT/api/health" &>/dev/null && { healthy="yes"; break; }
    sleep 2; hwaited=$((hwaited + 2))
  done
  [ -n "$healthy" ] && ok "Backend healthy after ${hwaited}s" || fail "Backend not healthy"

  # ----------------------------------------------------------------
  # 10. Monitoring (only start non-skipped)
  # ----------------------------------------------------------------
  step "10. Monitoring stack"
  for svc in dockge prometheus cadvisor grafana; do
    svc_upper=$(echo "$svc" | tr '[:lower:]' '[:upper:]')
    skip_var="SKIP_$svc_upper"
    ex_var="EXISTING_${svc_upper}_PORT"
    if [ "$SKIP_MONITORING" = "yes" ] || [ "${!skip_var}" = "yes" ]; then
      ex="${!ex_var}"
      [ -n "$ex" ] && info "$svc: reusing existing at :$ex" || info "$svc: skipped"
    else
      docker compose -f docker-compose.monitoring.yml up -d "$svc" \
        && ok "$svc started" || fail "$svc failed"
    fi
  done

  wait_http() {
    local url="$1" label="$2" waited=0
    while [ "$waited" -lt 60 ]; do
      curl -fsS --max-time 5 "$url" &>/dev/null && { ok "$label OK"; return 0; }
      sleep 2; waited=$((waited + 2))
    done
    fail "$label not reachable ($url)"
  }
  [ "$SKIP_MONITORING" = "yes" ] && info "Monitoring skipped (--skip-monitoring)"
  [ "$SKIP_MONITORING" != "yes" ] && [ "$SKIP_DOCKGE" != "yes" ]     && wait_http "http://localhost:$DOCKGE_PORT"             "Dockge"
  [ "$SKIP_MONITORING" != "yes" ] && [ "$SKIP_PROMETHEUS" != "yes" ] && wait_http "http://localhost:$PROM_PORT/-/healthy"     "Prometheus"
  [ "$SKIP_MONITORING" != "yes" ] && [ "$SKIP_CADVISOR" != "yes" ]   && wait_http "http://localhost:$CADVISOR_PORT/healthz"   "cAdvisor"
  [ "$SKIP_MONITORING" != "yes" ] && [ "$SKIP_GRAFANA" != "yes" ]    && wait_http "http://localhost:$GRAFANA_PORT/api/health" "Grafana"

  # ----------------------------------------------------------------
  # 11. Summary
  # ----------------------------------------------------------------
  step "Summary"
  local PAGES_URL="https://$owner.github.io/$REPO_NAME/"
  if [ "$ERRORS" -eq 0 ]; then
    echo "🎉 BUILD SUCCEEDED"
    echo ""
    echo "  Pages:    $PAGES_URL"
    echo "  Backend:  http://localhost:$BACKEND_PORT/api/health"
    if [ "$SKIP_DOCKGE" = "yes" ]; then
      [ -n "$EXISTING_DOCKGE_PORT" ] && echo "  Dockge:   REUSED (existing at :$EXISTING_DOCKGE_PORT)" || echo "  Dockge:   skipped"
    else
      echo "  Dockge:   http://localhost:$DOCKGE_PORT"
    fi
    if [ "$SKIP_PROMETHEUS" = "yes" ]; then
      [ -n "$EXISTING_PROMETHEUS_PORT" ] && echo "  Prom:     REUSED (existing at :$EXISTING_PROMETHEUS_PORT)" || echo "  Prom:     skipped"
    else
      echo "  Prom:     http://localhost:$PROM_PORT"
    fi
    if [ "$SKIP_CADVISOR" = "yes" ]; then
      [ -n "$EXISTING_CADVISOR_PORT" ] && echo "  cAdv:     REUSED (existing at :$EXISTING_CADVISOR_PORT)" || echo "  cAdv:     skipped"
    else
      echo "  cAdv:     http://localhost:$CADVISOR_PORT"
    fi
    if [ "$SKIP_GRAFANA" = "yes" ]; then
      [ -n "$EXISTING_GRAFANA_PORT" ] && echo "  Grafana:  REUSED (existing at :$EXISTING_GRAFANA_PORT)" || echo "  Grafana:  skipped"
    else
      echo "  Grafana:  http://localhost:$GRAFANA_PORT  (admin / change-me-now)"
    fi
    echo ""
    curl -s --max-time 5 "http://localhost:$BACKEND_PORT/api/status" | python3 -m json.tool 2>&1 || true
    if   command -v xdg-open &>/dev/null; then xdg-open "$PAGES_URL" &>/dev/null &
    elif command -v open     &>/dev/null; then open     "$PAGES_URL" &>/dev/null &
    fi
  else
    echo "🔥 COMPLETED WITH $ERRORS ERROR(S)"
  fi
  return "$ERRORS"
}

main "$@"
