package store

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := New(t.TempDir())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return s
}

func TestResolveRejectsEscape(t *testing.T) {
	s := newTestStore(t)
	// Node 판은 path.basename 으로 이런 입력을 "안전한 이름"으로 바꿔 성공시킨다.
	// 여기서는 거부해야 한다.
	bad := []string{
		"", ".", "..", "../etc/passwd", "a/../../etc/passwd", "sub/file.bin",
		`..\windows`, "/abs/path", ".hidden", "with\x00nul",
	}
	for _, name := range bad {
		if _, err := s.resolve(name); !errors.Is(err, ErrBadName) {
			t.Errorf("resolve(%q) = %v, ErrBadName 여야 함", name, err)
		}
	}
}

func TestResolveAcceptsPlainNames(t *testing.T) {
	s := newTestStore(t)
	for _, name := range []string{"a.bin", "보고서.txt", "a b.txt", "x..y", "report-2026.pdf"} {
		got, err := s.resolve(name)
		if err != nil {
			t.Fatalf("resolve(%q) 실패: %v", name, err)
		}
		if want := filepath.Join(s.Root(), name); got != want {
			t.Fatalf("resolve(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestEscapeDoesNotTouchOutsideFile(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "victim.txt")
	if err := os.WriteFile(outside, []byte("original"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newTestStore(t)
	rel, err := filepath.Rel(s.Root(), outside)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Write(rel, strings.NewReader("overwritten")); !errors.Is(err, ErrBadName) {
		t.Fatalf("Write(%q) = %v, ErrBadName 여야 함", rel, err)
	}
	got, err := os.ReadFile(outside)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "original" {
		t.Fatalf("저장소 밖 파일이 덮였습니다: %q", got)
	}
}

func TestWriteReadDelete(t *testing.T) {
	s := newTestStore(t)
	payload := strings.Repeat("ceph-rbd", 1000)

	n, err := s.Write("a.bin", strings.NewReader(payload))
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	if n != int64(len(payload)) {
		t.Fatalf("Write n = %d, want %d", n, len(payload))
	}

	f, info, err := s.Open("a.bin")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	got, err := io.ReadAll(f)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != payload {
		t.Fatal("읽은 내용이 다릅니다")
	}
	if info.Size() != int64(len(payload)) {
		t.Fatalf("size = %d, want %d", info.Size(), len(payload))
	}

	if err := s.Delete("a.bin"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, _, err := s.Open("a.bin"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("삭제 후 Open = %v, ErrNotFound 여야 함", err)
	}
}

type failingReader struct {
	data []byte
	n    int
}

func (f *failingReader) Read(p []byte) (int, error) {
	if f.n >= len(f.data) {
		return 0, errors.New("업로드 연결 끊김")
	}
	c := copy(p, f.data[f.n:])
	f.n += c
	return c, nil
}

func TestWriteIsAtomicOnFailure(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.Write("a.bin", strings.NewReader("GOOD")); err != nil {
		t.Fatal(err)
	}
	// Node 판은 fsp.writeFile 로 대상 파일에 직접 쓰므로, 실패한 덮어쓰기가
	// 기존 파일을 훼손할 수 있다. 여기서는 임시 파일 + rename 이라 안전해야 한다.
	if _, err := s.Write("a.bin", &failingReader{data: []byte("PARTIAL")}); err == nil {
		t.Fatal("실패해야 할 Write 가 성공했습니다")
	}
	f, _, err := s.Open("a.bin")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	got, _ := io.ReadAll(f)
	if string(got) != "GOOD" {
		t.Fatalf("기존 파일이 훼손됐습니다: %q", got)
	}
	entries, err := os.ReadDir(s.Root())
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".upload-") {
			t.Fatalf("임시 파일이 남았습니다: %s", e.Name())
		}
	}
}

func TestListSkipsNonRegularAndSorts(t *testing.T) {
	s := newTestStore(t)
	for _, n := range []string{"b.bin", "a.bin"} {
		if _, err := s.Write(n, strings.NewReader("x")); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(s.Root(), "adir"), 0o755); err != nil {
		t.Fatal(err)
	}
	files, err := s.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 || files[0].Key != "a.bin" || files[1].Key != "b.bin" {
		t.Fatalf("List = %v", files)
	}
}

func TestProbeFailsWhenMissing(t *testing.T) {
	s, err := New(filepath.Join(t.TempDir(), "not-mounted"))
	if err != nil {
		t.Fatal(err)
	}
	// RBD 마운트가 빠진 노드를 정상으로 보고하면 안 된다.
	if err := s.Probe(); err == nil {
		t.Fatal("없는 경로에 대해 Probe 가 성공했습니다")
	}
}
