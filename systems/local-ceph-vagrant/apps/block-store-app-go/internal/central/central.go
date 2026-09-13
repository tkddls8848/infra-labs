// Package central 은 master 에서 도는 중앙앱이다.
//
// ../block-store-app/app.js 의 startCentral() 과 같은 엔드포인트를 제공하며,
// 같은 index.html 을 서빙한다. 브라우저 입장에서는 두 구현이 구분되지 않는다.
//
//	GET    /                                     UI (바이너리에 embed)
//	GET    /api/nodes                            {nodes:[{name,url,online,store}]}
//	GET    /api/nodes/{node}/files               에이전트로 중계
//	GET    /api/nodes/{node}/files/{name}/download
//	POST   /api/nodes/{node}/files
//	DELETE /api/nodes/{node}/files/{name}
package central

import (
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
	"sort"
	"strings"
	"sync"
	"time"

	"cephblockstore/internal/web"
)

// Config 는 중앙앱 기동 설정이다.
type Config struct {
	Addr      string
	Nodes     []Node
	Token     string
	MaxUpload int64
}

// Node 는 등록된 스토리지 노드 하나다.
type Node struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// ParseNodes 는 "name=url,name=url" 형식을 노드 목록으로 바꾼다.
// Node 판의 parseNodes() 와 같은 형식을 받는다.
func ParseNodes(spec string) ([]Node, error) {
	var out []Node
	seen := map[string]bool{}
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, raw, ok := strings.Cut(part, "=")
		name, raw = strings.TrimSpace(name), strings.TrimSpace(raw)
		if !ok || name == "" || raw == "" {
			return nil, fmt.Errorf("노드 항목 형식이 잘못됐습니다(name=url): %q", part)
		}
		if seen[name] {
			return nil, fmt.Errorf("노드 이름이 중복됐습니다: %q", name)
		}
		u, err := url.Parse(raw)
		if err != nil || u.Scheme == "" || u.Host == "" {
			return nil, fmt.Errorf("노드 URL 이 잘못됐습니다: %q", raw)
		}
		seen[name] = true
		out = append(out, Node{Name: name, URL: strings.TrimRight(raw, "/")})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("등록할 노드가 없습니다: %q", spec)
	}
	return out, nil
}

// Central 은 중앙앱 서버다.
type Central struct {
	cfg   Config
	nodes map[string]string // name -> url
	http  *http.Client
}

// New 는 Central 을 만든다.
func New(cfg Config) (*Central, error) {
	if len(cfg.Nodes) == 0 {
		return nil, errors.New("등록된 노드가 없습니다 (NODES)")
	}
	if cfg.MaxUpload <= 0 {
		cfg.MaxUpload = 1 << 30
	}
	m := make(map[string]string, len(cfg.Nodes))
	for _, n := range cfg.Nodes {
		m[n.Name] = n.URL
	}
	return &Central{
		cfg:   cfg,
		nodes: m,
		http: &http.Client{
			Transport: &http.Transport{
				MaxIdleConnsPerHost: 32,
				IdleConnTimeout:     90 * time.Second,
			},
		},
	}, nil
}

// Handler 는 라우터를 반환한다.
func (c *Central) Handler() http.Handler {
	mux := http.NewServeMux()
	// UI 는 //go:embed 로 바이너리 안에 있다. public/ 디렉터리를 따로 배포하지 않는다.
	mux.Handle("GET /", http.FileServerFS(web.FS()))
	mux.HandleFunc("GET /api/nodes", c.handleNodes)
	mux.HandleFunc("GET /api/nodes/{node}/files", c.handleList)
	mux.HandleFunc("GET /api/nodes/{node}/files/{name}/download", c.handleDownload)
	mux.HandleFunc("POST /api/nodes/{node}/files", c.handleUpload)
	mux.HandleFunc("DELETE /api/nodes/{node}/files/{name}", c.handleDelete)
	return mux
}

// nodeURL 은 등록된 노드만 찾아준다. 이름이 아니라 주소를 받아 프록시하면
// 그대로 SSRF 통로가 되므로, 레지스트리에 없는 대상은 절대 호출하지 않는다.
func (c *Central) nodeURL(name string) (string, bool) {
	u, ok := c.nodes[name]
	return u, ok
}

// nodeStatus 는 /api/nodes 응답 한 줄이다.
type nodeStatus struct {
	Name   string `json:"name"`
	URL    string `json:"url"`
	Online bool   `json:"online"`
	Store  string `json:"store,omitempty"`
}

// handleNodes 는 모든 노드의 상태를 동시에 조회한다.
//
// Node 판은 for...of 안에서 await 하므로 노드를 하나씩 순차 조회한다. 노드
// 하나가 응답하지 않으면 그 타임아웃이 끝날 때까지 나머지 노드도 대기하고,
// UI 전체가 그만큼 멈춘다. 여기서는 팬아웃해서 전체 지연이 가장 느린 노드
// 하나에 수렴한다.
func (c *Central) handleNodes(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := timeoutCtx(r, 5*time.Second)
	defer cancel()

	out := make([]nodeStatus, len(c.cfg.Nodes))
	var wg sync.WaitGroup
	for i, n := range c.cfg.Nodes {
		wg.Add(1)
		go func(i int, n Node) {
			defer wg.Done()
			st := nodeStatus{Name: n.Name, URL: n.URL}
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, n.URL+"/health", nil)
			if err != nil {
				out[i] = st
				return
			}
			req.Header.Set("x-agent-token", c.cfg.Token)
			resp, err := c.http.Do(req)
			if err != nil {
				out[i] = st // offline
				return
			}
			defer resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				var h struct {
					OK    bool   `json:"ok"`
					Store string `json:"store"`
				}
				if json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&h) == nil {
					st.Online = h.OK
					st.Store = h.Store
				}
			}
			out[i] = st
		}(i, n)
	}
	wg.Wait()
	// 등록 순서를 유지하되 이름순으로 안정 정렬해 UI 목록이 흔들리지 않게 한다.
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	writeJSON(w, http.StatusOK, map[string]any{"nodes": out})
}

func (c *Central) handleList(w http.ResponseWriter, r *http.Request) {
	base, ok := c.nodeURL(r.PathValue("node"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown node"})
		return
	}
	c.proxyJSON(w, r, http.MethodGet, base+"/files", nil, "")
}

func (c *Central) handleDelete(w http.ResponseWriter, r *http.Request) {
	base, ok := c.nodeURL(r.PathValue("node"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown node"})
		return
	}
	c.proxyJSON(w, r, http.MethodDelete,
		base+"/files/"+url.PathEscape(r.PathValue("name")), nil, "")
}

func (c *Central) handleDownload(w http.ResponseWriter, r *http.Request) {
	base, ok := c.nodeURL(r.PathValue("node"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown node"})
		return
	}
	name := r.PathValue("name")
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet,
		base+"/files/"+url.PathEscape(name)+"/download", nil)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	req.Header.Set("x-agent-token", c.cfg.Token)

	resp, err := c.http.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{
			"error": "agent unreachable", "details": err.Error(),
		})
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		writeJSON(w, resp.StatusCode, map[string]string{"error": "download failed"})
		return
	}

	// 에이전트가 준 헤더를 그대로 넘긴다. 본문은 버퍼링 없이 브라우저로 흘려보낸다.
	for _, h := range []string{"Content-Disposition", "Content-Type", "Content-Length"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	if w.Header().Get("Content-Disposition") == "" {
		w.Header().Set("Content-Disposition",
			fmt.Sprintf(`attachment; filename*=UTF-8''%s`, url.PathEscape(name)))
	}
	if _, err := io.Copy(w, resp.Body); err != nil {
		log.Printf("[block-app/central] 다운로드 중계 중단: %s: %v", name, err)
	}
}

// handleUpload 는 브라우저의 multipart 를 에이전트로 그대로 흘려보낸다.
//
// Node 판은 multer 로 메모리에 받은 뒤 Blob 을 만들어 다시 FormData 에 담는다.
// 즉 파일이 중앙앱 RAM 에 최소 한 벌(실질적으로 두 벌) 올라간다. 여기서는
// io.Pipe 로 받는 쪽과 보내는 쪽을 직결해 파일 크기와 무관하게 메모리가 일정하다.
func (c *Central) handleUpload(w http.ResponseWriter, r *http.Request) {
	base, ok := c.nodeURL(r.PathValue("node"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown node"})
		return
	}

	mediaType, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || !strings.HasPrefix(mediaType, "multipart/") || params["boundary"] == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no file"})
		return
	}
	body := http.MaxBytesReader(w, r.Body, c.cfg.MaxUpload)
	defer body.Close()

	mr := multipart.NewReader(body, params["boundary"])
	var filePart *multipart.Part
	for {
		p, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "no file", "details": err.Error(),
			})
			return
		}
		if p.FormName() == "file" {
			filePart = p
			break
		}
		p.Close()
	}
	if filePart == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no file"})
		return
	}
	defer filePart.Close()

	// 브라우저가 보낸 filename 은 경로 성분을 떼고 쓴다.
	name := path.Base(strings.ReplaceAll(filePart.FileName(), `\`, "/"))
	if name == "" || name == "." || name == "/" {
		name = "upload.bin"
	}

	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		// 파이프 쓰기 쪽에서 실패하면 읽는 쪽(HTTP 요청)이 같은 에러로 끝나야 한다.
		part, err := mw.CreateFormFile("file", name)
		if err != nil {
			pw.CloseWithError(err)
			return
		}
		if _, err := io.Copy(part, filePart); err != nil {
			pw.CloseWithError(err)
			return
		}
		if err := mw.Close(); err != nil {
			pw.CloseWithError(err)
			return
		}
		pw.Close()
	}()

	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, base+"/files", pr)
	if err != nil {
		pr.CloseWithError(err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	req.Header.Set("x-agent-token", c.cfg.Token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	// 파일명은 URL-encode 해서 헤더로 넘긴다(Node 판과 동일한 계약).
	req.Header.Set("x-filename", url.QueryEscape(name))

	resp, err := c.http.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{
			"error": "agent unreachable", "details": err.Error(),
		})
		return
	}
	defer resp.Body.Close()
	relayJSON(w, resp)
}

// proxyJSON 은 에이전트의 JSON 응답을 상태 코드까지 그대로 중계한다.
func (c *Central) proxyJSON(w http.ResponseWriter, r *http.Request, method, target string, body io.Reader, contentType string) {
	req, err := http.NewRequestWithContext(r.Context(), method, target, body)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	req.Header.Set("x-agent-token", c.cfg.Token)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{
			"error": "agent unreachable", "details": err.Error(),
		})
		return
	}
	defer resp.Body.Close()
	relayJSON(w, resp)
}

func relayJSON(w http.ResponseWriter, resp *http.Response) {
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(raw)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
