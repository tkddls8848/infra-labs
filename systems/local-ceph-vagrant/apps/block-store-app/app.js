// app.js — Ceph RBD 노드별 블록 스토어 파일 앱
//
// 블록(RBD)은 단일 writer라 노드 간 공유가 안 된다. 그래서 노드마다 자기 RBD
// 볼륨을 따로 마운트하고, 사용자가 "저장 노드"를 골라 그 노드 볼륨에 CRUD 한다.
//
//   ROLE=agent   → 워커에서 로컬 RBD 마운트(STORE_DIR)에 파일 CRUD API 제공
//   ROLE=central → master에서 UI 제공 + 선택 노드의 에이전트로 프록시 (기본값)

const path = require('path');
const fsp = require('fs/promises');
const { Readable } = require('stream');
const express = require('express');
const multer = require('multer');

const ROLE = process.env.ROLE || 'central';
const PORT = process.env.PORT || (ROLE === 'agent' ? 4000 : 3333);
const AGENT_TOKEN = process.env.AGENT_TOKEN || 'change-me-token';
const MAX_FILE_SIZE = 1024 * 1024 * 1024; // 1GB

function log(...a) { console.log(new Date().toISOString(), `[block-app/${ROLE}]`, ...a); }

const app = express();
app.use(express.json());

if (AGENT_TOKEN === 'change-me-token') {
  log('경고: AGENT_TOKEN이 기본값입니다. 환경변수 AGENT_TOKEN으로 공유 시크릿을 설정하세요.');
}

if (ROLE === 'agent') startAgent();
else startCentral();

app.listen(PORT, () => log(`listening on :${PORT} (role=${ROLE})`));

// ===================== 노드 에이전트 =====================
function startAgent() {
  const STORE_DIR = process.env.STORE_DIR || '/srv/rbd-store';
  const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_FILE_SIZE } });

  // 토큰 검증 (중앙앱만 호출 가능)
  app.use((req, res, next) => {
    if (req.headers['x-agent-token'] !== AGENT_TOKEN) return res.status(401).json({ error: 'unauthorized' });
    next();
  });

  const resolve = (name) => path.join(STORE_DIR, path.basename(name)); // 경로 탈출 방지

  app.get('/health', async (req, res) => {
    try {
      const st = await fsp.stat(STORE_DIR);
      res.json({ ok: st.isDirectory(), store: STORE_DIR });
    } catch (e) {
      res.status(500).json({ ok: false, store: STORE_DIR, error: e.message });
    }
  });

  app.get('/files', async (req, res) => {
    try {
      const names = await fsp.readdir(STORE_DIR);
      const files = [];
      for (const n of names) {
        const st = await fsp.stat(path.join(STORE_DIR, n)).catch(() => null);
        if (st && st.isFile()) files.push({ key: n, size: st.size, lastModified: st.mtime });
      }
      res.json({ files });
    } catch (e) {
      res.status(500).json({ error: 'Failed to list files', details: e.message });
    }
  });

  app.get('/files/:name/download', (req, res) => {
    res.download(resolve(req.params.name), path.basename(req.params.name), (err) => {
      if (err && !res.headersSent) res.status(404).json({ error: 'not found' });
    });
  });

  app.post('/files', upload.single('file'), async (req, res) => {
    if (!req.file) return res.status(400).json({ error: 'no file' });
    // 파일명은 중앙앱이 x-filename(UTF-8, URL-encoded) 헤더로 전달
    const raw = req.headers['x-filename'] ? decodeURIComponent(req.headers['x-filename']) : req.file.originalname;
    const name = path.basename(raw);
    try {
      await fsp.writeFile(resolve(name), req.file.buffer);
      log(`upload OK: ${name} (${req.file.size} bytes) -> ${STORE_DIR}`);
      res.json({ success: true, key: name });
    } catch (e) {
      res.status(500).json({ error: 'Failed to write file', details: e.message });
    }
  });

  app.delete('/files/:name', async (req, res) => {
    try {
      await fsp.unlink(resolve(req.params.name));
      log(`delete OK: ${path.basename(req.params.name)}`);
      res.json({ success: true });
    } catch (e) {
      res.status(500).json({ error: 'Failed to delete file', details: e.message });
    }
  });

  log(`agent store dir: ${STORE_DIR}`);
}

// ===================== 중앙 앱 (master) =====================
function startCentral() {
  app.use(express.static(path.join(__dirname, 'public')));
  const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_FILE_SIZE } });

  // 노드 레지스트리: "name=url,name=url" (기본값은 워커 2대 — 환경변수 NODES로 덮어쓰기)
  const NODES = parseNodes(
    process.env.NODES ||
      'ceph-worker-1=http://192.168.60.11:4000,ceph-worker-2=http://192.168.60.12:4000'
  );
  const headers = () => ({ 'x-agent-token': AGENT_TOKEN });
  const nodeUrl = (n) => NODES[n];

  // 노드 목록 + 온라인 상태
  app.get('/api/nodes', async (req, res) => {
    const nodes = [];
    for (const [name, url] of Object.entries(NODES)) {
      let online = false, store = null;
      try {
        const r = await fetch(`${url}/health`, { headers: headers() });
        if (r.ok) { const h = await r.json(); online = !!h.ok; store = h.store; }
      } catch { /* offline */ }
      nodes.push({ name, url, online, store });
    }
    res.json({ nodes });
  });

  // 파일 목록
  app.get('/api/nodes/:node/files', async (req, res) => {
    const url = nodeUrl(req.params.node);
    if (!url) return res.status(404).json({ error: 'unknown node' });
    try {
      const r = await fetch(`${url}/files`, { headers: headers() });
      res.status(r.status).json(await r.json());
    } catch (e) {
      res.status(502).json({ error: 'agent unreachable', details: e.message });
    }
  });

  // 다운로드 (에이전트 → 중앙 → 브라우저 스트리밍)
  app.get('/api/nodes/:node/files/:name/download', async (req, res) => {
    const url = nodeUrl(req.params.node);
    if (!url) return res.status(404).json({ error: 'unknown node' });
    try {
      const r = await fetch(`${url}/files/${encodeURIComponent(req.params.name)}/download`, { headers: headers() });
      if (!r.ok) return res.status(r.status).json({ error: 'download failed' });
      res.setHeader('Content-Disposition',
        r.headers.get('content-disposition') || `attachment; filename="${encodeURIComponent(req.params.name)}"`);
      const ct = r.headers.get('content-type');
      if (ct) res.setHeader('Content-Type', ct);
      Readable.fromWeb(r.body).pipe(res);
    } catch (e) {
      res.status(502).json({ error: 'agent unreachable', details: e.message });
    }
  });

  // 업로드 (브라우저 → 중앙 → 에이전트)
  app.post('/api/nodes/:node/files', upload.single('file'), async (req, res) => {
    const url = nodeUrl(req.params.node);
    if (!url) return res.status(404).json({ error: 'unknown node' });
    if (!req.file) return res.status(400).json({ error: 'no file' });
    // 브라우저가 보낸 multipart originalname은 latin1로 들어오므로 UTF-8로 복원
    const name = Buffer.from(req.file.originalname, 'latin1').toString('utf8');
    try {
      const fd = new FormData();
      fd.append('file', new Blob([req.file.buffer], { type: req.file.mimetype || 'application/octet-stream' }), name);
      const r = await fetch(`${url}/files`, {
        method: 'POST',
        headers: { ...headers(), 'x-filename': encodeURIComponent(name) },
        body: fd,
      });
      res.status(r.status).json(await r.json());
    } catch (e) {
      res.status(502).json({ error: 'agent unreachable', details: e.message });
    }
  });

  // 삭제
  app.delete('/api/nodes/:node/files/:name', async (req, res) => {
    const url = nodeUrl(req.params.node);
    if (!url) return res.status(404).json({ error: 'unknown node' });
    try {
      const r = await fetch(`${url}/files/${encodeURIComponent(req.params.name)}`, { method: 'DELETE', headers: headers() });
      res.status(r.status).json(await r.json());
    } catch (e) {
      res.status(502).json({ error: 'agent unreachable', details: e.message });
    }
  });

  app.get('/', (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));
  log(`central nodes: ${Object.keys(NODES).join(', ') || '(none)'}`);
}

function parseNodes(s) {
  const m = {};
  s.split(',').map((x) => x.trim()).filter(Boolean).forEach((pair) => {
    const i = pair.indexOf('=');
    if (i > 0) m[pair.slice(0, i).trim()] = pair.slice(i + 1).trim();
  });
  return m;
}
