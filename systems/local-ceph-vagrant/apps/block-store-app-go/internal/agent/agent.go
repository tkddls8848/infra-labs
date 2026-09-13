// Package agent 는 스토리지 노드(워커)에서 도는 에이전트다.
//
// ../block-store-app/app.js 의 startAgent() 와 같은 엔드포인트·같은 응답 형태를
// 제공한다. 중앙앱이 어느 구현이든 똑같이 호출할 수 있어야 나란히 비교가 된다.
//
//	GET    /health                 {ok, store}
//	GET    /files                  {files:[{key,size,lastModified}]}
//	GET    /files/{name}/download  파일 본문
//	POST   /files                  multipart 'file' + x-filename 헤더
//	DELETE /files/{name}           {success:true}
//
// 모든 경로가 x-agent-token 을 요구한다(Node 판과 동일).
package agent

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"

	"cephblockstore/internal/store"
)

// Config 는 에이전트 기동 설정이다.
type Config struct {
	Addr     string
	StoreDir string
	Token    string
	// MaxUpload 는 업로드 상한(바이트)이다. Node 판의 multer 한도와 같은 1GiB 를 기본으로 쓴다.
	MaxUpload int64
}

// Agent 는 에이전트 HTTP 서버다.
type Agent struct {
	cfg   Config
	store *store.Store
}

// New 는 Agent 를 만든다.
func New(cfg Config) (*Agent, error) {
	if cfg.StoreDir == "" {
		return nil, errors.New("STORE_DIR 이 비어 있습니다")
	}
	if cfg.MaxUpload <= 0 {
		cfg.MaxUpload = 1 << 30
	}
	st, err := store.New(cfg.StoreDir)
	if err != nil {
		return nil, err
	}
	return &Agent{cfg: cfg, store: st}, nil
}

// Handler 는 인증이 적용된 라우터를 반환한다.
func (a *Agent) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", a.handleHealth)
	mux.HandleFunc("GET /files", a.handleList)
	mux.HandleFunc("GET /files/{name}/download", a.handleDownload)
	mux.HandleFunc("POST /files", a.handleUpload)
	mux.HandleFunc("DELETE /files/{name}", a.handleDelete)
	return a.withAuth(mux)
}

// withAuth 는 모든 경로에 공유 토큰을 요구한다.
func (a *Agent) withAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("x-agent-token")
		// 상수 시간 비교 — 토큰을 응답 시간으로 한 바이트씩 알아내는 경로를 막는다.
		// Node 판의 !== 문자열 비교는 첫 불일치에서 즉시 반환한다.
		if subtle.ConstantTimeCompare([]byte(got), []byte(a.cfg.Token)) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *Agent) handleHealth(w http.ResponseWriter, r *http.Request) {
	if err := a.store.Probe(); err != nil {
		// RBD 마운트가 빠진 상태를 200 으로 보고하지 않는다.
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "store": a.store.Root(), "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "store": a.store.Root()})
}

func (a *Agent) handleList(w http.ResponseWriter, r *http.Request) {
	files, err := a.store.List()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "Failed to list files", "details": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"files": files})
}

func (a *Agent) handleDownload(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	f, info, err := a.store.Open(name)
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	defer f.Close()

	// 파일명에 비ASCII 가 들어갈 수 있으므로 RFC 5987 filename* 을 함께 준다.
	w.Header().Set("Content-Disposition", fmt.Sprintf(
		`attachment; filename="%s"; filename*=UTF-8''%s`,
		sanitizeASCII(name), url.PathEscape(name)))
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	if _, err := io.Copy(w, f); err != nil {
		log.Printf("[block-app/agent] 다운로드 중단: %s: %v", name, err)
	}
}

// handleUpload 는 multipart 본문을 스트리밍으로 받아 그대로 디스크에 흘려보낸다.
//
// Node 판은 multer.memoryStorage() 라서 파일 전체가 먼저 RAM 에 올라간다.
// 여기서는 multipart.Reader 로 파트를 하나씩 읽어 io.Copy 로 넘기므로,
// 1GB 파일을 올려도 상주 메모리는 버퍼 크기 수준에 머문다.
func (a *Agent) handleUpload(w http.ResponseWriter, r *http.Request) {
	mediaType, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || !strings.HasPrefix(mediaType, "multipart/") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no file"})
		return
	}
	boundary, ok := params["boundary"]
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no file"})
		return
	}

	// 상한을 넘는 본문은 읽는 도중에 끊는다. 먼저 다 받고 크기를 재면
	// 상한의 의미가 없다.
	body := http.MaxBytesReader(w, r.Body, a.cfg.MaxUpload)
	defer body.Close()
	mr := multipart.NewReader(body, boundary)

	// 파일명은 중앙앱이 x-filename(UTF-8, URL-encoded) 헤더로 전달한다.
	// 없으면 파트의 filename 으로 대체한다 — Node 판과 같은 우선순위다.
	nameHint := ""
	if raw := r.Header.Get("x-filename"); raw != "" {
		if decoded, err := url.QueryUnescape(raw); err == nil {
			nameHint = decoded
		}
	}

	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			writeUploadErr(w, a.cfg.MaxUpload, err)
			return
		}
		if part.FormName() != "file" {
			part.Close()
			continue
		}

		name := nameHint
		if name == "" {
			name = part.FileName()
		}
		// 헤더로 온 이름이든 파트 이름이든 경로 성분을 떼고 검증한다.
		name = path.Base(strings.ReplaceAll(name, `\`, "/"))

		n, err := a.store.Write(name, part)
		part.Close()
		if err != nil {
			writeUploadErr(w, a.cfg.MaxUpload, err)
			return
		}
		log.Printf("[block-app/agent] upload OK: %s (%d bytes) -> %s", name, n, a.store.Root())
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "key": name})
		return
	}
	writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no file"})
}

func (a *Agent) handleDelete(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if err := a.store.Delete(name); err != nil {
		writeStoreErr(w, err)
		return
	}
	log.Printf("[block-app/agent] delete OK: %s", name)
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func writeUploadErr(w http.ResponseWriter, max int64, err error) {
	var maxErr *http.MaxBytesError
	if errors.As(err, &maxErr) {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{
			"error":   "Failed to write file",
			"details": fmt.Sprintf("업로드 상한(%d bytes) 초과", max),
		})
		return
	}
	if errors.Is(err, store.ErrBadName) {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Failed to write file", "details": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]string{
		"error": "Failed to write file", "details": err.Error(),
	})
}

func writeStoreErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	case errors.Is(err, store.ErrBadName):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
}

// sanitizeASCII 는 Content-Disposition 의 filename= 에 넣을 수 있게
// 비ASCII 와 따옴표를 걷어낸다. 원본 이름은 filename*= 쪽이 전달한다.
func sanitizeASCII(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r < 0x20 || r > 0x7e || r == '"' || r == '\\' {
			b.WriteByte('_')
			continue
		}
		b.WriteRune(r)
	}
	if b.Len() == 0 {
		return "download"
	}
	return b.String()
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
