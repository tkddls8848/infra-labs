// Command ceph-block-store 는 Ceph RBD 노드별 블록 스토어 파일 앱이다.
//
// 같은 폴더의 ../block-store-app/app.js (Node.js) 와 동일한 역할·동일한 HTTP API·
// 동일한 UI 를 제공한다. 같은 랩·같은 RBD 마운트 위에서 나란히 띄워 비교하는 것이
// 목적이므로, 환경변수 계약을 Node 판과 똑같이 맞춘다:
//
//	ROLE         central | agent      (기본 central)
//	PORT         리슨 포트            (기본 central 3333 / agent 4000)
//	AGENT_TOKEN  공유 시크릿
//	STORE_DIR    (agent) RBD 마운트   (기본 /srv/rbd-store)
//	NODES        (central) name=url,… 레지스트리
//
// 그래서 systemd 유닛에서 ExecStart 만 바꿔 끼울 수 있다.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"cephblockstore/internal/agent"
	"cephblockstore/internal/central"
)

// version 은 빌드 시 -ldflags 로 주입한다. scripts/build.sh 참고.
var version = "dev"

const (
	defaultNodes = "ceph-worker-1=http://192.168.60.11:4000,ceph-worker-2=http://192.168.60.12:4000"
	defaultStore = "/srv/rbd-store"
	maxUpload    = 1 << 30 // 1GiB — Node 판 multer 한도와 동일
)

func main() {
	role := env("ROLE", "central")
	log.SetFlags(0)
	log.SetPrefix("")

	if err := run(role); err != nil {
		logf(role, "종료: %v", err)
		os.Exit(1)
	}
}

func run(role string) error {
	token := os.Getenv("AGENT_TOKEN")
	if token == "" {
		// Node 판은 기본 토큰으로 조용히 뜨고 경고만 찍는다. 기본 시크릿으로
		// 뜬 서비스는 사실상 인증이 없는 것과 같으므로 여기서는 거부한다.
		return errors.New("AGENT_TOKEN 이 설정되지 않았습니다. central 과 agent 에 같은 값을 지정하세요")
	}

	// SIGINT/SIGTERM 에 진행 중인 요청을 정리하고 내려간다. systemd 재시작 때
	// 업로드가 반쯤 끊긴 파일을 남기지 않기 위한 것이다.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	switch role {
	case "agent":
		return runAgent(ctx, token)
	case "central":
		return runCentral(ctx, token)
	default:
		return fmt.Errorf("알 수 없는 ROLE: %q (central|agent)", role)
	}
}

func runAgent(ctx context.Context, token string) error {
	storeDir := env("STORE_DIR", defaultStore)
	addr, err := listenAddr("4000")
	if err != nil {
		return err
	}

	a, err := agent.New(agent.Config{
		Addr: addr, StoreDir: storeDir, Token: token, MaxUpload: maxUpload,
	})
	if err != nil {
		return err
	}
	logf("agent", "store dir: %s", storeDir)
	logf("agent", "listening on %s (version=%s)", addr, version)
	return serve(ctx, "agent", addr, a.Handler())
}

func runCentral(ctx context.Context, token string) error {
	addr, err := listenAddr("3333")
	if err != nil {
		return err
	}

	nodes, err := central.ParseNodes(env("NODES", defaultNodes))
	if err != nil {
		return err
	}
	c, err := central.New(central.Config{
		Addr: addr, Nodes: nodes, Token: token, MaxUpload: maxUpload,
	})
	if err != nil {
		return err
	}
	names := make([]string, len(nodes))
	for i, n := range nodes {
		names[i] = n.Name
	}
	logf("central", "nodes: %v", names)
	logf("central", "listening on %s (version=%s)", addr, version)
	return serve(ctx, "central", addr, c.Handler())
}

// serve 는 ctx 가 끝날 때까지 서버를 돌리고, 종료 시 유예 시간을 준다.
func serve(ctx context.Context, role, addr string, h http.Handler) error {
	srv := &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		// 대용량 업로드/다운로드가 있으므로 본문 전체 타임아웃은 두지 않는다.
	}
	errCh := make(chan error, 1)
	go func() {
		err := srv.ListenAndServe()
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		errCh <- err
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		logf(role, "종료 신호 수신, 진행 중 요청 정리")
		shutCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutCtx); err != nil {
			return fmt.Errorf("graceful shutdown 실패: %w", err)
		}
		return <-errCh
	}
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// logf 는 Node 판과 같은 형태로 찍는다: <ISO8601> [block-app/<role>] <msg>
func logf(role, format string, args ...any) {
	log.Printf("%s [block-app/%s] %s",
		time.Now().UTC().Format(time.RFC3339Nano), role, fmt.Sprintf(format, args...))
}

// listenAddr 는 PORT 환경변수를 검증해 리슨 주소로 만든다.
// 잘못된 값이면 기동 시점에 막는다 — ":abc" 로 리슨하면 런타임에야 실패한다.
func listenAddr(def string) (string, error) {
	raw := env("PORT", def)
	port, err := strconv.Atoi(raw)
	if err != nil || port < 1 || port > 65535 {
		return "", fmt.Errorf("PORT 값이 잘못됐습니다: %q (1-65535)", raw)
	}
	return ":" + strconv.Itoa(port), nil
}
