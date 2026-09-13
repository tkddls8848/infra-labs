import os
from datetime import datetime
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

app = FastAPI(title="Storage Test App")

STORAGE_PATHS = {
    "cephfs": "/mnt/cephfs",
    "rbd":    "/mnt/rbd",
    "beegfs": "/mnt/beegfs",
}

STORAGE_LABELS = {
    "cephfs": "Ceph File (CephFS)",
    "rbd":    "Ceph Block (RBD)",
    "beegfs": "BeeGFS",
}


class FileBody(BaseModel):
    name: str
    content: str


class UpdateBody(BaseModel):
    content: str


def get_mount_path(storage: str) -> str:
    if storage not in STORAGE_PATHS:
        raise HTTPException(400, f"Unknown storage '{storage}'. Valid: {list(STORAGE_PATHS.keys())}")
    path = STORAGE_PATHS[storage]
    if not os.path.isdir(path):
        raise HTTPException(503, f"Storage '{storage}' not mounted at {path}")
    return path


def safe_filename(name: str) -> str:
    """Strip path separators to prevent path traversal."""
    return os.path.basename(name)


# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/api/health")
def health():
    status = {}
    for key, path in STORAGE_PATHS.items():
        status[key] = {
            "label": STORAGE_LABELS[key],
            "mounted": os.path.isdir(path),
            "path": path,
        }
    return {"status": "ok", "storages": status}


# ── List files ────────────────────────────────────────────────────────────────

@app.get("/api/{storage}/files")
def list_files(storage: str):
    path = get_mount_path(storage)
    try:
        files = []
        for fname in sorted(os.listdir(path)):
            fpath = os.path.join(path, fname)
            if os.path.isfile(fpath):
                st = os.stat(fpath)
                files.append({
                    "name": fname,
                    "size": st.st_size,
                    "modified": datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds"),
                })
        return {"storage": storage, "label": STORAGE_LABELS[storage], "files": files}
    except OSError as e:
        raise HTTPException(500, str(e))


# ── Create file ───────────────────────────────────────────────────────────────

@app.post("/api/{storage}/files", status_code=201)
def create_file(storage: str, body: FileBody):
    path = get_mount_path(storage)
    name = safe_filename(body.name)
    if not name:
        raise HTTPException(400, "Invalid filename")
    fpath = os.path.join(path, name)
    if os.path.exists(fpath):
        raise HTTPException(409, f"File '{name}' already exists")
    try:
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(body.content)
        return {"message": "created", "name": name}
    except OSError as e:
        raise HTTPException(500, str(e))


# ── Read file ─────────────────────────────────────────────────────────────────

@app.get("/api/{storage}/files/{filename}")
def read_file(storage: str, filename: str):
    path = get_mount_path(storage)
    fpath = os.path.join(path, safe_filename(filename))
    if not os.path.isfile(fpath):
        raise HTTPException(404, f"File '{filename}' not found")
    try:
        with open(fpath, "r", encoding="utf-8") as f:
            content = f.read()
        st = os.stat(fpath)
        return {
            "name": filename,
            "content": content,
            "size": st.st_size,
            "modified": datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds"),
        }
    except OSError as e:
        raise HTTPException(500, str(e))


# ── Update file ───────────────────────────────────────────────────────────────

@app.put("/api/{storage}/files/{filename}")
def update_file(storage: str, filename: str, body: UpdateBody):
    path = get_mount_path(storage)
    fpath = os.path.join(path, safe_filename(filename))
    if not os.path.isfile(fpath):
        raise HTTPException(404, f"File '{filename}' not found")
    try:
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(body.content)
        return {"message": "updated", "name": filename}
    except OSError as e:
        raise HTTPException(500, str(e))


# ── Delete file ───────────────────────────────────────────────────────────────

@app.delete("/api/{storage}/files/{filename}")
def delete_file(storage: str, filename: str):
    path = get_mount_path(storage)
    fpath = os.path.join(path, safe_filename(filename))
    if not os.path.isfile(fpath):
        raise HTTPException(404, f"File '{filename}' not found")
    try:
        os.remove(fpath)
        return {"message": "deleted", "name": filename}
    except OSError as e:
        raise HTTPException(500, str(e))


# ── Static frontend (must be last) ────────────────────────────────────────────
app.mount("/", StaticFiles(directory="static", html=True), name="static")
