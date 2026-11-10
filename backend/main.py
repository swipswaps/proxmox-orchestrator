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
