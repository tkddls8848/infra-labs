package central_test

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"cephblockstore/internal/agent"
	"cephblockstore/internal/central"
)

const token = "test-shared-secret"

// startAgent 는 임시 디렉터리를 RBD 마운트 대신 쓰는 에이전트를 띄운다.
func startAgent(t *testing.T) *httptest.Server {
	t.Helper()
	a, err := agent.New(agent.Config{StoreDir: t.TempDir(), Token: token})
	if err != nil {
		t.Fatalf("agent.New: %v", err)
	}
	srv := httptest.NewServer(a.Handler())
	t.Cleanup(srv.Close)
	return srv
}

// startLab 은 에이전트 2대 + 중앙앱을 띄운다.
func startLab(t *testing.T) (*httptest.Server, []*httptest.Server) {
	t.Helper()
	a1, a2 := startAgent(t), startAgent(t)
	c, err := central.New(central.Config{
		Nodes: []central.Node{
			{Name: "ceph-worker-1", URL: a1.URL},
			{Name: "ceph-worker-2", URL: a2.URL},
		},
		Token: token,
	})
	if err != nil {
		t.Fatalf("central.New: %v", err)
	}
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)
	return srv, []*httptest.Server{a1, a2}
}

func uploadTo(t *testing.T, base, node, name string, body []byte) *http.Response {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, err := mw.CreateFormFile("file", name)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	resp, err := http.Post(base+"/api/nodes/"+url.PathEscape(node)+"/files",
		mw.FormDataContentType(), &buf)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestNodesResponseShape(t *testing.T) {
	srv, _ := startLab(t)
	resp, err := http.Get(srv.URL + "/api/nodes")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	// UI(index.html)가 읽는 형태를 그대로 지켜야 한다: {nodes:[{name,url,online,store}]}
	var out struct {
		Nodes []struct {
			Name   string `json:"name"`
			URL    string `json:"url"`
			Online bool   `json:"online"`
			Store  string `json:"store"`
		} `json:"nodes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("파싱 실패: %v", err)
	}
	if len(out.Nodes) != 2 {
		t.Fatalf("노드 %d개, want 2", len(out.Nodes))
	}
	for _, n := range out.Nodes {
		if !n.Online {
			t.Errorf("노드 %s 가 offline", n.Name)
		}
		if n.Store == "" {
			t.Errorf("노드 %s 의 store 경로가 비었습니다", n.Name)
		}
	}
	if out.Nodes[0].Name != "ceph-worker-1" || out.Nodes[1].Name != "ceph-worker-2" {
		t.Fatalf("노드 순서: %s, %s", out.Nodes[0].Name, out.Nodes[1].Name)
	}
}

// TestNodesFanOutIsConcurrent 는 오프라인 노드가 있어도 전체 조회가
// 순차 합계가 아니라 가장 느린 노드 하나에 수렴하는지 본다.
// Node 판은 for...of + await 라 노드 수만큼 지연이 누적된다.
func TestNodesFanOutIsConcurrent(t *testing.T) {
	// 연결을 수락한 뒤 응답하지 않는 노드 3대를 만든다.
	var stalls []central.Node
	for i := 0; i < 3; i++ {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(10 * time.Second) // 요청 컨텍스트 타임아웃에 걸린다
		}))
		t.Cleanup(s.Close)
		stalls = append(stalls, central.Node{Name: "slow-" + string(rune('a'+i)), URL: s.URL})
	}
	c, err := central.New(central.Config{Nodes: stalls, Token: token})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	start := time.Now()
	resp, err := http.Get(srv.URL + "/api/nodes")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	elapsed := time.Since(start)

	// 내부 타임아웃은 5초다. 순차라면 3대 x 5초 = 15초가 걸린다.
	if elapsed > 9*time.Second {
		t.Fatalf("팬아웃이 순차로 동작합니다: %v (동시라면 ~5초)", elapsed)
	}
	t.Logf("느린 노드 3대 조회에 %v 소요 (순차였다면 ~15초)", elapsed)
}

func TestUploadListDownloadDelete(t *testing.T) {
	srv, _ := startLab(t)
	payload := bytes.Repeat([]byte("RBD"), 5000)
	const name = "보고서.bin"

	resp := uploadTo(t, srv.URL, "ceph-worker-1", name, payload)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("업로드 status = %d: %s", resp.StatusCode, b)
	}
	var up struct {
		Success bool   `json:"success"`
		Key     string `json:"key"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&up); err != nil {
		t.Fatal(err)
	}
	// 비ASCII 파일명이 왕복에서 깨지면 안 된다.
	if !up.Success || up.Key != name {
		t.Fatalf("업로드 응답 = %+v, key 는 %q 여야 함", up, name)
	}

	// 목록 — UI 가 읽는 키 이름 그대로여야 한다.
	lr, err := http.Get(srv.URL + "/api/nodes/ceph-worker-1/files")
	if err != nil {
		t.Fatal(err)
	}
	defer lr.Body.Close()
	var list struct {
		Files []struct {
			Key          string    `json:"key"`
			Size         int64     `json:"size"`
			LastModified time.Time `json:"lastModified"`
		} `json:"files"`
	}
	if err := json.NewDecoder(lr.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Files) != 1 || list.Files[0].Key != name {
		t.Fatalf("목록 = %+v", list.Files)
	}
	if list.Files[0].Size != int64(len(payload)) {
		t.Fatalf("size = %d, want %d", list.Files[0].Size, len(payload))
	}
	if list.Files[0].LastModified.IsZero() {
		t.Fatal("lastModified 가 비었습니다")
	}

	// 블록 스토리지의 본질: worker-1 에 올린 파일은 worker-2 에 없다.
	lr2, err := http.Get(srv.URL + "/api/nodes/ceph-worker-2/files")
	if err != nil {
		t.Fatal(err)
	}
	defer lr2.Body.Close()
	var list2 struct {
		Files []json.RawMessage `json:"files"`
	}
	if err := json.NewDecoder(lr2.Body).Decode(&list2); err != nil {
		t.Fatal(err)
	}
	if len(list2.Files) != 0 {
		t.Fatalf("worker-2 에 파일이 새어 들어갔습니다: %v", list2.Files)
	}

	// 다운로드
	dr, err := http.Get(srv.URL + "/api/nodes/ceph-worker-1/files/" + url.PathEscape(name) + "/download")
	if err != nil {
		t.Fatal(err)
	}
	defer dr.Body.Close()
	got, _ := io.ReadAll(dr.Body)
	if !bytes.Equal(got, payload) {
		t.Fatalf("다운로드 내용이 다릅니다 (%d vs %d bytes)", len(got), len(payload))
	}
	if cd := dr.Header.Get("Content-Disposition"); !strings.Contains(cd, "filename*=UTF-8''") {
		t.Fatalf("비ASCII 파일명에 RFC 5987 filename* 이 없습니다: %q", cd)
	}

	// 삭제
	req, _ := http.NewRequest(http.MethodDelete,
		srv.URL+"/api/nodes/ceph-worker-1/files/"+url.PathEscape(name), nil)
	delr, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer delr.Body.Close()
	if delr.StatusCode != http.StatusOK {
		t.Fatalf("삭제 status = %d", delr.StatusCode)
	}
}

func TestUnknownNodeRejected(t *testing.T) {
	srv, _ := startLab(t)
	// 등록되지 않은 이름으로는 중계하지 않는다.
	for _, path := range []string{
		"/api/nodes/evil.example.com/files",
		"/api/nodes/ceph-worker-9/files",
	} {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s status = %d, want 404", path, resp.StatusCode)
		}
	}
}

func TestAgentRequiresToken(t *testing.T) {
	a := startAgent(t)
	// Node 판과 동일하게 /health 를 포함한 모든 경로가 토큰을 요구한다.
	for _, path := range []string{"/health", "/files"} {
		resp, err := http.Get(a.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("토큰 없는 %s status = %d, want 401", path, resp.StatusCode)
		}
	}
	// 틀린 토큰도 막혀야 한다.
	req, _ := http.NewRequest(http.MethodGet, a.URL+"/files", nil)
	req.Header.Set("x-agent-token", "wrong")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("틀린 토큰 status = %d, want 401", resp.StatusCode)
	}
}

func TestAgentRejectsPathEscape(t *testing.T) {
	a := startAgent(t)
	// x-filename 헤더로 경로 탈출을 시도해도 저장소 밖에 닿으면 안 된다.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, _ := mw.CreateFormFile("file", "ok.bin")
	part.Write([]byte("x"))
	mw.Close()

	req, _ := http.NewRequest(http.MethodPost, a.URL+"/files", &buf)
	req.Header.Set("x-agent-token", token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("x-filename", url.QueryEscape("../escaped.txt"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	// path.Base 로 "escaped.txt" 가 되어 저장소 안에 저장되거나(허용),
	// 거부되거나(허용) 둘 중 하나여야 한다. 저장소 밖으로 나가면 안 된다.
	var out struct {
		Key string `json:"key"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	if strings.Contains(out.Key, "/") || strings.Contains(out.Key, "..") {
		t.Fatalf("경로 성분이 살아남았습니다: %q", out.Key)
	}
}

func TestUIIsEmbedded(t *testing.T) {
	srv, _ := startLab(t)
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	// public/ 디렉터리 없이도 UI 가 나와야 한다.
	if !bytes.Contains(body, []byte("/api/nodes")) {
		t.Fatalf("embed 된 UI 가 서빙되지 않았습니다 (%d bytes)", len(body))
	}
}

func TestParseNodes(t *testing.T) {
	nodes, err := central.ParseNodes(
		"ceph-worker-1=http://192.168.60.11:4000, ceph-worker-2=http://192.168.60.12:4000/")
	if err != nil {
		t.Fatalf("ParseNodes: %v", err)
	}
	if len(nodes) != 2 {
		t.Fatalf("노드 %d개", len(nodes))
	}
	// 뒤 슬래시는 떼야 경로를 이어붙일 때 "//files" 가 되지 않는다.
	if nodes[1].URL != "http://192.168.60.12:4000" {
		t.Fatalf("URL = %q", nodes[1].URL)
	}
	for _, bad := range []string{"", "worker1", "worker1=", "=http://x", "w=not-a-url",
		"w=http://a:1,w=http://b:2"} {
		if _, err := central.ParseNodes(bad); err == nil {
			t.Errorf("ParseNodes(%q) 가 통과했습니다", bad)
		}
	}
}
