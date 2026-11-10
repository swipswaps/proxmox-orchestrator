#!/usr/bin/env bash
# audit.sh — read-only deployment audit
AUDIT_ERRORS=0
audit_fail() { echo "❌ $1"; AUDIT_ERRORS=$((AUDIT_ERRORS + 1)); }
audit_ok()   { echo "✅ $1"; }
audit_warn() { echo "⚠️  $1"; }
audit_step() { echo ""; echo "▶ $1"; }

audit_main() {
  audit_step "Audit 0: Repository structure"
  for p in backend/Dockerfile backend/main.py backend/proxmox_client.py \
           backend/requirements.txt frontend/dist/index.html; do
    if [ -e "$p" ]; then audit_ok "$p exists"; else audit_fail "$p missing"; fi
  done

  audit_step "Audit 1: Environment file"
  if [ -f backend/.env ]; then
    audit_ok "backend/.env exists"
    for k in PROXMOX_HOST PROXMOX_USER PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET; do
      if grep -q "^${k}=" backend/.env; then
        audit_ok "  $k present (value not inspected)"
      else
        audit_fail "  $k missing"
      fi
    done
    if grep -q '^PROXMOX_HOST=$' backend/.env; then
      audit_warn "  PROXMOX_HOST is empty — backend will run Proxmox-free (OK)"
    fi
  else
    audit_fail "backend/.env missing"
  fi

  audit_step "Audit 2: docker-compose.yml"
  if [ -f docker-compose.yml ]; then
    audit_ok "docker-compose.yml exists"
    if docker compose config &>/dev/null; then
      audit_ok "  config valid"
    else
      audit_fail "  config invalid"
    fi
  else
    audit_fail "docker-compose.yml missing"
  fi

  audit_step "Audit 3: Docker image"
  if docker image inspect proxmox-orchestrator-backend &>/dev/null; then
    audit_ok "Image present"
    hc=$(docker image inspect --format '{{.Config.Healthcheck}}' \
         proxmox-orchestrator-backend 2>&1) || hc=""
    if [ -n "$hc" ] && [ "$hc" != "<nil>" ] && [ "$hc" != "[]" ]; then
      audit_ok "  HEALTHCHECK defined"
    else
      audit_fail "  HEALTHCHECK missing"
    fi
  else
    audit_fail "Image missing — run build_and_deploy.sh first"
  fi

  audit_step "Audit 4: Container runtime"
  if docker ps --format '{{.Names}}' 2>&1 | grep -q "proxmox-orchestrator-backend"; then
    audit_ok "Container running"
    if curl -fsS http://localhost:8000/api/health &>/dev/null; then
      audit_ok "  /api/health 200"
    else
      audit_fail "  /api/health not reachable"
    fi
    if curl -fsS http://localhost:8000/api/status &>/dev/null; then
      audit_ok "  /api/status 200"
    else
      audit_fail "  /api/status not reachable"
    fi
  else
    audit_warn "No running container"
    docker ps -a --format '{{.Names}}\t{{.Status}}' 2>&1 | grep proxmox-orchestrator || true
  fi

  audit_step "Audit 5: Port 8000"
  if command -v ss &>/dev/null; then
    if ss -ltn 2>&1 | grep -q ':8000 '; then
      audit_warn "Port 8000 in use"
    else
      audit_ok "Port 8000 free"
    fi
  elif command -v netstat &>/dev/null; then
    if netstat -ltn 2>&1 | grep -q ':8000 '; then
      audit_warn "Port 8000 in use"
    else
      audit_ok "Port 8000 free"
    fi
  else
    audit_warn "ss/netstat not available"
  fi

  audit_step "Audit Summary"
  if [ "$AUDIT_ERRORS" -eq 0 ]; then
    echo "✅ AUDIT PASSED"
  else
    echo "🔥 AUDIT FOUND $AUDIT_ERRORS ISSUE(S)"
  fi
  return "$AUDIT_ERRORS"
}
audit_main "$@"
