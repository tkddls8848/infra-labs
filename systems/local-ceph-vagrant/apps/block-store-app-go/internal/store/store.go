// Package store 는 RBD 마운트 디렉터리 하나를 평평한 파일 저장소로 다룬다.
//
// STORE_DIR 은 setup-rbd-node.sh 가 마운트한 RBD 이미지다. 저장소는 마운트를
// 만들지 않으며, 마운트가 빠진 상황(디렉터리는 있는데 실제 RBD 가 안 붙은 경우)을
// 정상으로 위장하지 않고 드러내는 것이 목적이다.
package store

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var (
	// ErrBadName 은 저장소 밖을 가리키는 이름을 거부할 때 반환한다.
	ErrBadName = errors.New("허용되지 않는 파일 이름")
	// ErrNotFound 는 대상 파일이 없을 때 반환한다.
	ErrNotFound = errors.New("파일 없음")
)

// Store 는 root 디렉터리 하나에 대한 파일 CRUD 를 제공한다.
type Store struct {
	root string
}

// New 는 root 를 절대경로로 정규화한 Store 를 만든다.
// root 존재 여부는 여기서 검사하지 않는다 — RBD 마운트는 나중에 붙을 수 있으므로
// 요청 시점에 Probe 로 확인한다.
func New(root string) (*Store, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("store root 경로 해석 실패(%s): %w", root, err)
	}
	return &Store{root: abs}, nil
}

// Root 는 저장소의 절대 경로를 반환한다.
func (s *Store) Root() string { return s.root }

// resolve 는 사용자 입력 이름을 root 안의 실제 경로로 바꾼다.
//
// Node 판(app.js)은 path.basename 으로 처리하는데, 그 방식은
// "a/../../etc/passwd" 를 조용히 "passwd" 로 바꿔치기해서 사용자가 요청한 것과
// 다른 파일을 성공적으로 다루게 만든다. 여기서는 이름을 변형하지 않고 거부한다.
func (s *Store) resolve(name string) (string, error) {
	if name == "" || name == "." || name == ".." {
		return "", fmt.Errorf("%w: %q", ErrBadName, name)
	}
	if strings.ContainsAny(name, `/\`) || strings.Contains(name, "\x00") {
		return "", fmt.Errorf("%w: 경로 구분자를 포함할 수 없습니다: %q", ErrBadName, name)
	}
	if strings.HasPrefix(name, ".") {
		return "", fmt.Errorf("%w: 점으로 시작할 수 없습니다: %q", ErrBadName, name)
	}
	full := filepath.Join(s.root, name)
	// Join 이 정규화한 뒤에도 root 바로 아래인지 다시 확인한다(이중 방어).
	if filepath.Dir(full) != s.root {
		return "", fmt.Errorf("%w: 저장소 밖을 가리킵니다: %q", ErrBadName, name)
	}
	return full, nil
}

// FileInfo 는 API 로 노출되는 파일 메타데이터다.
// JSON 키는 Node 판과 동일하게 유지한다 — 같은 UI 가 두 구현을 모두 읽는다.
type FileInfo struct {
	Key          string    `json:"key"`
	Size         int64     `json:"size"`
	LastModified time.Time `json:"lastModified"`
}

// List 는 저장소의 일반 파일 목록을 이름순으로 반환한다.
func (s *Store) List() ([]FileInfo, error) {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return nil, fmt.Errorf("저장소 목록 조회 실패(%s): %w", s.root, err)
	}
	out := make([]FileInfo, 0, len(entries))
	for _, e := range entries {
		if !e.Type().IsRegular() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			// 목록 조회 중 파일이 지워질 수 있다. 그 항목만 건너뛴다.
			continue
		}
		out = append(out, FileInfo{Key: e.Name(), Size: info.Size(), LastModified: info.ModTime()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

// Open 은 읽기용으로 파일을 연다. 호출자가 Close 해야 한다.
func (s *Store) Open(name string) (*os.File, os.FileInfo, error) {
	full, err := s.resolve(name)
	if err != nil {
		return nil, nil, err
	}
	f, err := os.Open(full)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, fmt.Errorf("%w: %s", ErrNotFound, name)
	}
	if err != nil {
		return nil, nil, fmt.Errorf("열기 실패(%s): %w", name, err)
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, fmt.Errorf("stat 실패(%s): %w", name, err)
	}
	if !info.Mode().IsRegular() {
		f.Close()
		return nil, nil, fmt.Errorf("%w: 일반 파일이 아닙니다: %s", ErrBadName, name)
	}
	return f, info, nil
}

// Write 는 r 의 내용을 name 으로 저장하고 기록된 바이트 수를 반환한다.
//
// r 을 메모리에 모으지 않고 그대로 디스크로 흘려보낸다. Node 판은
// multer.memoryStorage() 를 쓰기 때문에 업로드 파일 전체가 먼저 RAM 에
// 올라간다(상한 1GB). 1GB 파일 하나를 올리면 그 순간 RSS 가 1GB 늘어난다.
// 여기서는 파일 크기와 무관하게 32KB 버퍼만 쓴다.
//
// 임시 파일에 먼저 쓰고 rename 으로 교체한다. 업로드가 중간에 끊겨도 기존
// 파일이 반쯤 덮인 상태로 남지 않는다.
func (s *Store) Write(name string, r io.Reader) (n int64, err error) {
	full, err := s.resolve(name)
	if err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(s.root, ".upload-*")
	if err != nil {
		return 0, fmt.Errorf("임시 파일 생성 실패(%s): %w", s.root, err)
	}
	tmpName := tmp.Name()
	defer func() {
		if err != nil {
			tmp.Close()
			os.Remove(tmpName)
		}
	}()

	n, err = io.Copy(tmp, r)
	if err != nil {
		return 0, fmt.Errorf("쓰기 실패(%s): %w", name, err)
	}
	if err = tmp.Close(); err != nil {
		return 0, fmt.Errorf("임시 파일 닫기 실패(%s): %w", name, err)
	}
	if err = os.Chmod(tmpName, 0o644); err != nil {
		return 0, fmt.Errorf("권한 설정 실패(%s): %w", name, err)
	}
	if err = os.Rename(tmpName, full); err != nil {
		return 0, fmt.Errorf("교체 실패(%s): %w", name, err)
	}
	return n, nil
}

// Delete 는 파일을 삭제한다. 없으면 ErrNotFound.
func (s *Store) Delete(name string) error {
	full, err := s.resolve(name)
	if err != nil {
		return err
	}
	err = os.Remove(full)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: %s", ErrNotFound, name)
	}
	if err != nil {
		return fmt.Errorf("삭제 실패(%s): %w", name, err)
	}
	return nil
}

// Probe 는 저장소 디렉터리가 실제로 쓸 수 있는 상태인지 확인한다.
// 디렉터리가 없거나 디렉터리가 아니면 에러다 — RBD 마운트가 빠진 노드를
// "정상"으로 보고하면 중앙앱이 그 노드로 트래픽을 보내 루트 디스크에 쓰게 된다.
func (s *Store) Probe() error {
	info, err := os.Stat(s.root)
	if err != nil {
		return fmt.Errorf("저장소 경로 확인 실패(%s): %w", s.root, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("저장소 경로가 디렉터리가 아닙니다: %s", s.root)
	}
	return nil
}
