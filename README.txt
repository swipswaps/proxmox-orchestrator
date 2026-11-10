PROXMOX REMOTE ORCHESTRATION ENGINE
See .env for ports and reuse decisions.
Backend: FastAPI (unique, always started)
Monitoring: Dockge, Prometheus, cAdvisor, Grafana (reusable if already running)

Flags:
  -y, --yes             non-interactive (auto-reuse compatible services)
  -p, --ports           force re-pick every port
  -f, --free            stop conflicting containers and replace
  -m, --skip-monitoring skip all monitoring (backend only)
