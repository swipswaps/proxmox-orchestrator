#!/usr/bin/env bash
# build_and_deploy.sh — idempotent, orphan-aware, name-conflict-aware
set +e
trap 'echo ""; echo "⚠️  Interrupted"; exit 130' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ "$(basename "$SCRIPT_DIR")" = "scripts" ] && cd "$(dirname "$SCRIPT_DIR")"

REPO_NAME="${REPO_NAME:-proxmox-orchestrator}"
PAGES_BRANCH="gh-pages"
NON_INTERACTIVE="no"; FORCE_PORTS="no"; AUTO_FREE="no"; SKIP_MONITORING="no"
ERRORS=0
for arg in "$@"; do case "$arg" in
  --yes|-y)             NON_INTERACTIVE="yes" ;;
  --ports|-p)           FORCE_PORTS="yes" ;;
  --free|-f)            AUTO_FREE="yes" ;;
  --skip-monitoring|-m) SKIP_MONITORING="yes" ;;
esac; done

fail() { echo "❌ $1"; ERRORS=$((ERRORS + 1)); }
ok()   { echo "✅ $1"; }
info() { echo "ℹ️  $1"; }
step() { echo ""; echo "▶ $1"; }
warn() { echo "⚠️  $1"; }

# ----------------------------------------------------------------
# Docker helpers with progress
# ----------------------------------------------------------------
docker_stop_progress() {
  local c="$1"
  if ! docker inspect --format '{{.State.Running}}' "$c" &>/dev/null | grep -q true; then
    info "$c is already stopped"; return 0
  fi
  echo "    ⏳ Stopping $c (grace period up to 10s) ..."
  local t0 t1
  t0=$(date +%s)
  docker stop "$c" &>/dev/null
  t1=$(date +%s)
  ok "Stopped $c in $((t1 - t0))s"
}

docker_rm_progress() {
  local c="$1"
  if ! docker inspect "$c" &>/dev/null; then
    info "$c does not exist"; return 0
  fi
  echo "    ⏳ Removing $c ..."
  docker rm "$c" &>/dev/null && ok "Removed $c" || fail "Could not remove $c"
}

# ----------------------------------------------------------------
# Port detection
# ----------------------------------------------------------------
port_in_use() {
  local p="$1"
  if command -v ss &>/dev/null; then
    ss -ltn 2>&1 | awk '{print $4}' | grep -qE "[:.]$p$"
  elif command -v netstat &>/dev/null; then
    netstat -ltn 2>&1 | awk '{print $4}' | grep -qE "[:.]$p$"
  else return 1; fi
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
  else echo "unknown"; fi
}
find_next_free() {
  local p="$1"
  while [ "$p" -le 65535 ]; do port_in_use "$p" || { echo "$p"; return 0; }; p=$((p + 1)); done
  return 1
}

# ----------------------------------------------------------------
# Container-name conflict detection
# ----------------------------------------------------------------
detect_name_conflict() {
  docker ps -a --filter "name=^${1}$" --format '{{.Names}}' | grep -qx "$1"
}
inspect_name_conflict() {
  local img state
  img=$(docker inspect --format '{{.Config.Image}}' "$1" 2>&1)
  state=$(docker inspect --format '{{.State.Status}}' "$1" 2>&1)
  echo "$img|$state"
}
resolve_container_name() {
  local svc="$1" default="$1"
  local name_var="${svc^^}_CONTAINER_NAME"
  local reuse_var="REUSE_${svc^^}"

  if ! detect_name_conflict "$default"; then
    eval "$name_var=\"$default\""; eval "$reuse_var=\"no\""; return
  fi

  local img_state img state
  img_state=$(inspect_name_conflict "$default")
  img=$(echo "$img_state" | cut -d'|' -f1)
  state=$(echo "$img_state" | cut -d'|' -f2)

  if echo "$img" | grep -qiE "(^|/|:)$default(:|$)"; then
    if [ "$NON_INTERACTIVE" = "yes" ]; then
      if [ "$AUTO_FREE" = "yes" ]; then
        info "Replacing existing $default ($state)"
        docker_stop_progress "$default"; docker_rm_progress "$default"
        eval "$name_var=\"$default\""; eval "$reuse_var=\"no\""
      else
        info "Reusing existing $default ($state)"
        eval "$name_var=\"$default\""; eval "$reuse_var=\"yes\""
      fi
      return
    fi
    echo "" >&2
    echo "  Container '$default' already exists ($img, $state)" >&2
    echo "  This IS a $default instance." >&2
    echo "" >&2
    echo "    [K] Keep and reuse — skip starting ours (recommended)" >&2
    echo "    [S] Stop, then start fresh" >&2
    echo "    [D] Delete (stop + rm), then start fresh" >&2
    printf "  Choice [K/s/d] (Enter=K): " >&2
    local c=""; read -t 15 -r c; c="${c:-K}"; echo "" >&2
    case "$c" in
      [Ss]*) docker_stop_progress "$default"; eval "$name_var=\"$default\""; eval "$reuse_var=\"no\"" ;;
      [Dd]*) docker_stop_progress "$default"; docker_rm_progress "$default"; eval "$name_var=\"$default\""; eval "$reuse_var=\"no\"" ;;
      *)     eval "$name_var=\"$default\""; eval "$reuse_var=\"yes\"" ;;
    esac
  else
    info "Container name '$default' taken by '$img' — will name ours '${REPO_NAME}-${default}'"
    eval "$name_var=\"${REPO_NAME}-${default}\""; eval "$reuse_var=\"no\""
  fi
}

# ----------------------------------------------------------------
# Orphan handler with validation + safety
# ----------------------------------------------------------------
handle_orphans() {
  local compose_file="$1" project="$2" label="$3"

  # VALIDATE FIRST — otherwise config error corrupts $services and marks
  # every container as orphan (this is what happened in your log)
  local cfg_err
  if ! cfg_err=$(docker compose -f "$compose_file" config --quiet 2>&1); then
    fail "$compose_file has invalid YAML — skipping orphan check"
    echo "    Compose error: $cfg_err" >&2
    return 1
  fi

  local services
  services=$(docker compose -f "$compose_file" config --services 2>&1)
  if [ -z "$services" ]; then
    warn "$label: no services defined — skipping orphan check"
    return 0
  fi

  local all_containers
  all_containers=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
                   --format '{{.Names}}' 2>&1)

  local orphans=""
  for c in $all_containers; do
    local svc
    svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$c" 2>&1)
    if [ -z "$svc" ] || ! echo "$services" | grep -qx "$svc"; then
      orphans="$orphans $c"
    fi
  done

  [ -z "$orphans" ] && { ok "$label: no orphans"; return 0; }

  echo ""
  warn "Orphan containers in project '$project' ($label):"
  echo ""
  printf "      %-32s %-32s %s\n" "NAME" "IMAGE" "STATUS"
  printf "      %-32s %-32s %s\n" "----" "-----" "------"
  for c in $orphans; do
    local img state
    img=$(docker inspect --format '{{.Config.Image}}' "$c" 2>&1)
    state=$(docker inspect --format '{{.State.Status}}' "$c" 2>&1)
    printf "      %-32s %-32s %s\n" "$c" "$img" "$state"
  done

  echo ""
  echo "  Orphan handling:"
  echo "    [K] Keep all — leave them running (default)"
  echo "    [A] Auto — remove all orphans"
  echo "    [M] Manual — show commands, I'll run them"
  echo "    [P] Per-container decisions"
  printf "  Choice [K/a/m/p] (Enter=K): "
  local choice=""; read -t 15 -r choice; echo ""; choice="${choice:-K}"

  case "$choice" in
    [Aa]*)
      for c in $orphans; do
        docker_stop_progress "$c"
        docker_rm_progress "$c"
      done
      ;;
    [Mm]*)
      echo ""
      echo "  Run these to clean up manually:"
      for c in $orphans; do
        echo "    docker stop $c && docker rm $c"
      done
      echo ""
      echo "  Or to silence the warning without deleting:"
      for c in $orphans; do
        echo "    docker update --label-add com.docker.compose.project=legacy-$(date +%s) $c"
      done
      ;;
    [Pp]*)
      for c in $orphans; do
        local img state is_known svc_of_c
        img=$(docker inspect --format '{{.Config.Image}}' "$c" 2>&1)
        state=$(docker inspect --format '{{.State.Status}}' "$c" 2>&1)
        svc_of_c=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$c" 2>&1)
        is_known="no"
        [ -n "$svc_of_c" ] && echo "$services" | grep -qx "$svc_of_c" && is_known="yes"

        echo ""
        echo "  $c ($img, $state)"
        [ "$is_known" = "yes" ] && echo "    ⚠️  This IS a service in $compose_file (state mismatch, not true orphan)"
        echo "    [K] Keep"
        echo "    [T] Terminate (stop only — can restart later)"
        echo "    [D] Delete (stop + rm)"
        echo "    [L] Relabel to another project (silences warning)"
        printf "    Choice [K/t/d/l] (Enter=K): "
        local c2=""; read -t 15 -r c2; c2="${c2:-K}"
        case "$c2" in
          [Tt]*) docker_stop_progress "$c" ;;
          [Dd]*)
            if [ "$is_known" = "yes" ]; then
              printf "    ⚠️  This is a service. Deleting means it will be recreated on next up. Confirm? [y/N]: "
              local confirm=""; read -t 15 -r confirm
              if [ "${confirm:-N}" = "y" ] || [ "${confirm:-N}" = "Y" ]; then
                docker_stop_progress "$c"; docker_rm_progress "$c"
              else
                ok "Cancelled — kept $c"
              fi
            else
              docker_stop_progress "$c"; docker_rm_progress "$c"
            fi
            ;;
          [Ll]*) docker update --label-add "com.docker.compose.project=legacy-$(date +%s)" "$c" &>/dev/null \
                   && ok "Relabeled $c" || fail "Could not relabel $c" ;;
          *) ok "Kept $c" ;;
        esac
      done
      ;;
    *) info "Keeping all orphans" ;;
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
    fail "gh not authenticated. Run: gh auth login && gh auth refresh -s repo"; return "$ERRORS"
  fi
  ok "Authenticated as $owner"
  git config user.email &>/dev/null || git config user.email "build@localhost"
  git config user.name  &>/dev/null || git config user.name  "Build Script"

  # ----------------------------------------------------------------
  # 1. Container name audit
  # ----------------------------------------------------------------
  step "1. Container name audit"
  DOCKGE_CONTAINER_NAME=""; REUSE_DOCKGE="no"
  PROMETHEUS_CONTAINER_NAME=""; REUSE_PROMETHEUS="no"
  CADVISOR_CONTAINER_NAME=""; REUSE_CADVISOR="no"
  GRAFANA_CONTAINER_NAME=""; REUSE_GRAFANA="no"

  resolve_container_name "dockge"
  resolve_container_name "prometheus"
  resolve_container_name "cadvisor"
  resolve_container_name "grafana"

  ok "Container names resolved"
  info "  dockge=$DOCKGE_CONTAINER_NAME  reuse=$REUSE_DOCKGE"
  info "  prometheus=$PROMETHEUS_CONTAINER_NAME  reuse=$REUSE_PROMETHEUS"
  info "  cadvisor=$CADVISOR_CONTAINER_NAME  reuse=$REUSE_CADVISOR"
  info "  grafana=$GRAFANA_CONTAINER_NAME  reuse=$REUSE_GRAFANA"

  # ----------------------------------------------------------------
  # 2. Port landscape
  # ----------------------------------------------------------------
  step "2. Port landscape"
  printf "  %-12s %-6s %-30s %s\n" "SERVICE" "PORT" "OWNER" "REUSABLE?"
  printf "  %-12s %-6s %-30s %s\n" "--------" "----" "-----" "---------"
  for pair in "backend:8000" "dockge:5001" "prometheus:9090" "cadvisor:9091" "grafana:3001"; do
    svc="${pair%%:*}"; port="${pair##*:}"
    if ! port_in_use "$port"; then
      printf "  %-12s %-6s %-30s %s\n" "$svc" "$port" "(free)" "—"; continue
    fi
    owner_p=$(port_owner "$port")
    local status
    if [ "$svc" = "backend" ]; then status="no (unique)"
    else
      existing=$(docker ps -a --format '{{.Names}}|{{.Image}}' | \
        awk -F'|' -v svc="$svc" 'tolower($2) ~ tolower(svc) {print; exit}')
      [ -n "$existing" ] && status="YES (image)" || status="no (different svc)"
    fi
    printf "  %-12s %-6s %-30s %s\n" "$svc" "$port" "$owner_p" "$status"
  done

  # ----------------------------------------------------------------
  # 3. Port resolution
  # ----------------------------------------------------------------
  step "3. Port resolution"
  local BACKEND_PORT DOCKGE_PORT PROM_PORT CADVISOR_PORT GRAFANA_PORT
  local PORTS_SAVED="no" env_source=""
  [ -f .env ] && env_source=".env"
  [ -f .env.tmp ] && env_source=".env.tmp"
  if [ -n "$env_source" ] && [ "$FORCE_PORTS" != "yes" ]; then
    while IFS='=' read -r key value; do case "$key" in
      BACKEND_PORT) BACKEND_PORT="$value" ;;
      DOCKGE_PORT)  DOCKGE_PORT="$value" ;;
      PROMETHEUS_PORT) PROM_PORT="$value" ;;
      CADVISOR_PORT) CADVISOR_PORT="$value" ;;
      GRAFANA_PORT)  GRAFANA_PORT="$value" ;;
      SKIP_DOCKGE)   SKIP_DOCKGE="$value" ;;
      SKIP_PROMETHEUS) SKIP_PROMETHEUS="$value" ;;
      SKIP_CADVISOR) SKIP_CADVISOR="$value" ;;
      SKIP_GRAFANA)  SKIP_GRAFANA="$value" ;;
      EXISTING_DOCKGE_PORT)     EXISTING_DOCKGE_PORT="$value" ;;
      EXISTING_PROMETHEUS_PORT) EXISTING_PROMETHEUS_PORT="$value" ;;
      EXISTING_CADVISOR_PORT)   EXISTING_CADVISOR_PORT="$value" ;;
      EXISTING_GRAFANA_PORT)    EXISTING_GRAFANA_PORT="$value" ;;
      DOCKGE_CONTAINER_NAME)     DOCKGE_CONTAINER_NAME="$value" ;;
      PROMETHEUS_CONTAINER_NAME) PROMETHEUS_CONTAINER_NAME="$value" ;;
      CADVISOR_CONTAINER_NAME)   CADVISOR_CONTAINER_NAME="$value" ;;
      GRAFANA_CONTAINER_NAME)    GRAFANA_CONTAINER_NAME="$value" ;;
    esac; done < "$env_source"
    [ -n "$BACKEND_PORT" ] && [ -n "$DOCKGE_PORT" ] && [ -n "$PROM_PORT" ] && \
      [ -n "$CADVISOR_PORT" ] && [ -n "$GRAFANA_PORT" ] && PORTS_SAVED="yes"
    [ "$PORTS_SAVED" = "yes" ] && ok "Resuming from $env_source"
  fi

  [ "$REUSE_DOCKGE" = "yes" ]     && SKIP_DOCKGE=yes
  [ "$REUSE_PROMETHEUS" = "yes" ] && SKIP_PROMETHEUS=yes
  [ "$REUSE_CADVISOR" = "yes" ]   && SKIP_CADVISOR=yes
  [ "$REUSE_GRAFANA" = "yes" ]    && SKIP_GRAFANA=yes

  for pair in "dockge:DOCKGE" "prometheus:PROMETHEUS" "cadvisor:CADVISOR" "grafana:GRAFANA"; do
    svc="${pair%%:*}"; var="${pair##*:}"
    skip_var="SKIP_$var"; ex_var="EXISTING_${var}_PORT"
    if [ "${!skip_var}" = "yes" ] && [ -z "${!ex_var}" ]; then
      ex_port=$(docker port "$svc" 2>&1 | grep -oE ':[0-9]+' | head -1 | tr -d ':')
      [ -n "$ex_port" ] && eval "$ex_var=$ex_port"
    fi
  done

  if [ "$PORTS_SAVED" != "yes" ]; then
    ask_simple() {
      local label="$1" default="$2" current="$3" value suggested
      [ "$FORCE_PORTS" != "yes" ] && [ -n "$current" ] && ! port_in_use "$current" && { echo "$current"; return; }
      [ "$FORCE_PORTS" != "yes" ] && ! port_in_use "$default" && { echo "$default"; return; }
      suggested=$(find_next_free $((default + 1))); [ -z "$suggested" ] && suggested="$default"
      echo "" >&2; echo "  $label" >&2
      echo "    $default busy by: $(port_owner "$default")" >&2
      echo "    Suggesting: :$suggested" >&2
      printf "    Port [%s] (Enter=accept): " "$suggested" >&2
      value=""; read -t 15 -r value; echo "" >&2
      [ -z "$value" ] && value="$suggested"
      port_in_use "$value" && value=$(find_next_free $((value + 1)))
      echo "$value"
    }
    BACKEND_PORT=$(ask_simple "Backend API" 8000 "${BACKEND_PORT:-}")
    [ "$SKIP_DOCKGE" != "yes" ]     && DOCKGE_PORT=$(ask_simple "Dockge UI" 5001 "${DOCKGE_PORT:-}")
    [ "$SKIP_PROMETHEUS" != "yes" ] && PROM_PORT=$(ask_simple "Prometheus" 9090 "${PROM_PORT:-}")
    [ "$SKIP_CADVISOR" != "yes" ]   && CADVISOR_PORT=$(ask_simple "cAdvisor" 9091 "${CADVISOR_PORT:-}")
    [ "$SKIP_GRAFANA" != "yes" ]    && GRAFANA_PORT=$(ask_simple "Grafana" 3001 "${GRAFANA_PORT:-}")
    [ -z "$DOCKGE_PORT" ] && DOCKGE_PORT=5001
    [ -z "$PROM_PORT" ] && PROM_PORT=9090
    [ -z "$CADVISOR_PORT" ] && CADVISOR_PORT=9091
    [ -z "$GRAFANA_PORT" ] && GRAFANA_PORT=3001
  fi

  cat > .env <<EOF
# Ports & reuse decisions
BACKEND_PORT=$BACKEND_PORT
DOCKGE_PORT=$DOCKGE_PORT
PROMETHEUS_PORT=$PROM_PORT
CADVISOR_PORT=$CADVISOR_PORT
GRAFANA_PORT=$GRAFANA_PORT
SKIP_DOCKGE=${SKIP_DOCKGE:-no}
SKIP_PROMETHEUS=${SKIP_PROMETHEUS:-no}
SKIP_CADVISOR=${SKIP_CADVISOR:-no}
SKIP_GRAFANA=${SKIP_GRAFANA:-no}
EXISTING_DOCKGE_PORT=${EXISTING_DOCKGE_PORT:-}
EXISTING_PROMETHEUS_PORT=${EXISTING_PROMETHEUS_PORT:-}
EXISTING_CADVISOR_PORT=${EXISTING_CADVISOR_PORT:-}
EXISTING_GRAFANA_PORT=${EXISTING_GRAFANA_PORT:-}
DOCKGE_CONTAINER_NAME=${DOCKGE_CONTAINER_NAME:-dockge}
PROMETHEUS_CONTAINER_NAME=${PROMETHEUS_CONTAINER_NAME:-prometheus}
CADVISOR_CONTAINER_NAME=${CADVISOR_CONTAINER_NAME:-cadvisor}
GRAFANA_CONTAINER_NAME=${GRAFANA_CONTAINER_NAME:-grafana}
EOF
  ok ".env written"

  step "4. Git repository"
  if [ ! -d .git ]; then
    git init -b main || fail "git init failed"
  else
    local cur; cur=$(git symbolic-ref --short HEAD 2>&1) || cur=""
    [ "$cur" != "main" ] && { git show-ref --verify --quiet refs/heads/main && git checkout main || git checkout -b main; }
  fi
  ok "Git ready on 'main'"

  # ----------------------------------------------------------------
  # 5. Emit project files
  # ----------------------------------------------------------------
  step "5. Emitting project files"
  mkdir -p backend terraform ansible frontend/src frontend/public \
           monitoring/prometheus monitoring/dockge backend/data

  cat > README.txt <<'EOF'
PROXMOX REMOTE ORCHESTRATION ENGINE
See .env for ports, container names, and reuse decisions.
Monitoring compose uses project name 'repo-monitoring' (isolated).
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
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('lxc','vm')),
            target_node TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'PENDING',
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
    return ProxmoxAPI(os.environ["PROXMOX_HOST"], user=user,
        token_name=f"{user}!{os.environ['PROXMOX_TOKEN_ID']}",
        token_value=os.environ["PROXMOX_TOKEN_SECRET"],
        verify_ssl=os.environ.get("PROXMOX_VERIFY_SSL","false").lower()=="true",
        service="PVE", timeout=int(os.environ.get("PROXMOX_TIMEOUT","5")))
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
    configured = is_proxmox_configured(); connected = False; detail = ""
    if configured:
        try: get_proxmox_connection().version.get(); connected = True
        except Exception as e: detail = str(e)
    return {"backend":"ok","proxmox_configured":configured,"proxmox_connected":connected,"detail":detail}
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
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
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
    - firewalld:
        zone: drop
        rich_rule: 'rule family="ipv4" source address="192.168.0.0/16" service name="ssh" accept'
        permanent: yes; immediate: yes; state: enabled
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
      .catch(() => setState(prev => ({ ...prev, loading: false }))).finally(() => clearTimeout(t));
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
          {deployments.map(d => (<tr key={d.id}><td>{d.id}</td><td>{d.name}</td><td>{d.type}</td><td>{d.target_node}</td><td>{d.status}</td><td>{d.created_at}</td></tr>))}
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

  # ================================================================
  # CORRECTED docker-compose.yml — valid multi-line YAML
  # ================================================================
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
      - "${BACKEND_PORT:-8000}:8000"
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

  cat > docker-compose.monitoring.yml <<'EOF'
name: repo-monitoring

services:
  dockge:
    image: louislam/dockge:1.5.0
    container_name: ${DOCKGE_CONTAINER_NAME:-dockge}
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
    container_name: ${PROMETHEUS_CONTAINER_NAME:-prometheus}
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
    container_name: ${CADVISOR_CONTAINER_NAME:-cadvisor}
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
    container_name: ${GRAFANA_CONTAINER_NAME:-grafana}
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
  monitoring:
    driver: bridge
EOF

  if [ "${SKIP_CADVISOR:-no}" = "yes" ] && [ -n "${EXISTING_CADVISOR_PORT:-}" ]; then
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
  # 6. Validate + orphan check
  # ----------------------------------------------------------------
  step "6. Validate compose files"
  if docker compose -f docker-compose.yml config --quiet 2>/dev/null; then
    ok "docker-compose.yml valid"
  else
    fail "docker-compose.yml invalid"
    docker compose -f docker-compose.yml config 2>&1 | head -5
  fi
  if docker compose -f docker-compose.monitoring.yml config --quiet 2>/dev/null; then
    ok "docker-compose.monitoring.yml valid"
  else
    fail "docker-compose.monitoring.yml invalid"
    docker compose -f docker-compose.monitoring.yml config 2>&1 | head -5
  fi

  step "7. Orphan check (main project 'repo')"
  handle_orphans "docker-compose.yml" "repo" "main"

  # ----------------------------------------------------------------
  # 8. Commit + push
  # ----------------------------------------------------------------
  step "8. Commit + push"
  git add -A
  git diff --cached --quiet && ok "No changes" || { git commit -m "Build: sync" || fail "commit failed"; ok "Committed"; }

  step "9. GitHub repo"
  if gh repo view "$owner/$REPO_NAME" &>/dev/null; then ok "Repo exists"
  else gh repo create "$REPO_NAME" --public --source=. --remote=origin --push || fail "create failed"; fi
  git remote get-url origin &>/dev/null || git remote add origin "https://github.com/$owner/$REPO_NAME.git"
  git push -u origin main || fail "push failed"
  ok "Pushed main"

  # ----------------------------------------------------------------
  # 10. Frontend + gh-pages + Pages
  # ----------------------------------------------------------------
  step "10. Frontend"
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
  step "11. Wait for gh-pages + enable Pages"
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
  # 12. Backend — NO --remove-orphans (user decisions preserved)
  # ----------------------------------------------------------------
  step "12. Backend"
  info "Building image (may take 30-60s on first run) ..."
  docker compose build backend || fail "build failed"
  info "Starting container ..."
  docker compose up -d backend || fail "up failed"
  local hwaited=0 healthy=""
  while [ "$hwaited" -lt 60 ]; do
    curl -fsS --max-time 5 "http://localhost:$BACKEND_PORT/api/health" &>/dev/null && { healthy="yes"; break; }
    sleep 2; hwaited=$((hwaited + 2))
  done
  [ -n "$healthy" ] && ok "Backend healthy after ${hwaited}s" || fail "Backend not healthy"

  # ----------------------------------------------------------------
  # 13. Monitoring (isolated project)
  # ----------------------------------------------------------------
  step "13. Monitoring stack"
  if [ "$SKIP_MONITORING" = "yes" ]; then
    info "Monitoring skipped (--skip-monitoring)"
  else
    for svc in dockge prometheus cadvisor grafana; do
      svc_upper=$(echo "$svc" | tr '[:lower:]' '[:upper:]')
      skip_var="SKIP_$svc_upper"; ex_var="EXISTING_${svc_upper}_PORT"
      if [ "${!skip_var}" = "yes" ]; then
        ex="${!ex_var}"
        [ -n "$ex" ] && info "$svc: reusing existing at :$ex" || info "$svc: skipped"
      else
        info "Starting $svc ..."
        docker compose -f docker-compose.monitoring.yml up -d "$svc" \
          && ok "$svc started" || fail "$svc failed"
      fi
    done
    wait_http() {
      local url="$1" label="$2" w=0
      while [ "$w" -lt 60 ]; do
        curl -fsS --max-time 5 "$url" &>/dev/null && { ok "$label OK"; return 0; }
        sleep 2; w=$((w + 2))
      done
      fail "$label not reachable ($url)"
    }
    [ "$SKIP_DOCKGE" != "yes" ]     && wait_http "http://localhost:$DOCKGE_PORT"             "Dockge"
    [ "$SKIP_PROMETHEUS" != "yes" ] && wait_http "http://localhost:$PROM_PORT/-/healthy"     "Prometheus"
    [ "$SKIP_CADVISOR" != "yes" ]   && wait_http "http://localhost:$CADVISOR_PORT/healthz"   "cAdvisor"
    [ "$SKIP_GRAFANA" != "yes" ]    && wait_http "http://localhost:$GRAFANA_PORT/api/health" "Grafana"
  fi

  # ----------------------------------------------------------------
  # 14. Summary
  # ----------------------------------------------------------------
  step "Summary"
  local PAGES_URL="https://$owner.github.io/$REPO_NAME/"
  if [ "$ERRORS" -eq 0 ]; then
    echo "🎉 BUILD SUCCEEDED"
    echo ""
    echo "  Pages:    $PAGES_URL"
    echo "  Backend:  http://localhost:$BACKEND_PORT/api/health"
    echo ""
    echo "  Monitoring services:"
    for pair in "dockge:DOCKGE:Dockge" "prometheus:PROMETHEUS:Prometheus" "cadvisor:CADVISOR:cAdvisor" "grafana:GRAFANA:Grafana"; do
      svc="${pair%%:*}"; var="${pair#*:}"; var="${var%%:*}"
      skip_var="SKIP_$var"; ex_var="EXISTING_${var}_PORT"; port_var="${var}_PORT"
      if [ "${!skip_var}" = "yes" ]; then
        [ -n "${!ex_var}" ] && echo "    $svc:  REUSED (existing on :${!ex_var})" || echo "    $svc:  skipped"
      else
        echo "    $svc:  http://localhost:${!port_var}"
      fi
    done
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
