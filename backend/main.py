import os, subprocess
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from database import init_db, get_db_connection
from proxmox_client import get_proxmox_connection

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

@app.get("/api/nodes")
def list_nodes():
    try:
        return get_proxmox_connection().nodes.get()
    except Exception as e:
        raise HTTPException(500, str(e))

@app.post("/api/deploy")
def trigger_deployment(req: DeploymentRequest):
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
