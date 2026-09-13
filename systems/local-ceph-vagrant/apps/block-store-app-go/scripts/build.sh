#!/bin/bash
#
# 정적 바이너리 크로스컴파일.
#
#   CGO_ENABLED=0  → libc 를 포함해 어떤 동적 링크도 없다. 워커의 배포판이나
#                    glibc 버전과 무관하게 그대로 실행된다.
#   -trimpath      → 빌드 호스트의 절대 경로가 바이너리에 남지 않는다.
#   -s -w          → 심볼/DWARF 제거.
#
# 산출물은 dist/ceph-block-store-linux-<arch> 하나뿐이다. UI 는 //go:embed 로
# 이미 안에 들어 있으므로 함께 배포할 정적 파일이 없다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$APP_DIR/dist"

ARCHES="${ARCHES:-amd64 arm64}"
VERSION="${VERSION:-$(git -C "$APP_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)}"

command -v go >/dev/null 2>&1 || {
  echo "[build][failed] reason=go 툴체인이 없습니다. https://go.dev/dl 에서 설치하세요." >&2
  exit 1
}

cd "$APP_DIR"
echo "[build][target=local] go vet + test"
go vet ./...
go test ./...

mkdir -p "$DIST_DIR"
for arch in $ARCHES; do
  out="$DIST_DIR/ceph-block-store-linux-$arch"
  echo "[build][target=linux/$arch] 컴파일"
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$out" .
done

echo
echo "산출물 (version=$VERSION):"
ls -lh "$DIST_DIR" | tail -n +2 | awk '{printf "  %-34s %s\n", $9, $5}'
if command -v file >/dev/null 2>&1; then
  echo
  echo "링크 확인:"
  for arch in $ARCHES; do
    printf "  %s\n" "$(file -b "$DIST_DIR/ceph-block-store-linux-$arch")"
  done
fi
