#!/bin/bash
#
# 블록 스토어 앱 Node.js 구현 vs Go 구현 비교 (master에서 실행).
#
# 두 구현은 같은 RBD 마운트를 공유하고 포트만 다르다:
#   Node : central :3333  agent :4000
#   Go   : central :3334  agent :4001
#
# 측정 항목
#   1. 배포 발자국 — 노드에 무엇이 설치돼 있어야 하는가
#   2. 유휴 메모리
#   3. 업로드 중 피크 메모리 (가장 크게 갈리는 지점)
#   4. 노드 목록 조회 지연 — 정상 / 무응답 노드가 섞였을 때
#   5. 교차 확인 — 한쪽에 올린 파일이 다른 쪽에 보이는가
#
# 사용: bash block-store-compare.sh [업로드_MB]
set -uo pipefail

SIZE_MB="${1:-512}"
NODE_CENTRAL_PORT=3333
GO_CENTRAL_PORT=3334
STORE_DIR="${STORE_DIR:-/srv/rbd-store}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

hr() { printf '%s\n' "--------------------------------------------------------------------------"; }
have_go() { systemctl is-active --quiet ceph-block-central-go 2>/dev/null; }

if ! have_go; then
  echo "Go 중앙앱(ceph-block-central-go)이 실행 중이 아닙니다." >&2
  echo "호스트에서 'bash apps/block-store-app-go/scripts/build.sh' 후" >&2
  echo "'vagrant provision --provision-with blockstoreapp' 을 실행하세요." >&2
  exit 1
fi

# 서비스의 메인 PID 를 얻는다. RSS 를 재려면 프로세스가 특정돼야 한다.
main_pid() { systemctl show -p MainPID --value "$1" 2>/dev/null; }
rss_mb()  { awk '/VmRSS/{printf "%d", $2/1024}' "/proc/$1/status" 2>/dev/null || echo 0; }
hwm_mb()  { awk '/VmHWM/{printf "%d", $2/1024}' "/proc/$1/status" 2>/dev/null || echo 0; }

NODE_C=$(main_pid ceph-block-central)
GO_C=$(main_pid ceph-block-central-go)

echo
echo "###  블록 스토어 앱: Node.js vs Go  ###"
echo "저장소: $STORE_DIR (두 구현이 공유)"

# ---------- 1. 배포 발자국 ----------
hr; echo "1. 배포 발자국 — 노드에 무엇이 있어야 하는가"; hr
NM_DIR=/opt/ceph-block-store/node_modules
if [[ -d "$NM_DIR" ]]; then
  NM_FILES=$(find "$NM_DIR" -type f 2>/dev/null | wc -l)
  NM_PKGS=$(find "$NM_DIR" -maxdepth 1 -mindepth 1 -type d ! -name '.*' 2>/dev/null | wc -l)
  NM_SIZE=$(du -sh "$NM_DIR" 2>/dev/null | cut -f1)
else
  NM_FILES=0; NM_PKGS=0; NM_SIZE="-"
fi
NODE_RT=$(dpkg-query -W -f='${Installed-Size}' nodejs 2>/dev/null || echo 0)
GO_SIZE=$(stat -c%s /usr/local/bin/ceph-block-store 2>/dev/null || echo 0)

printf "  %-30s %-22s %s\n" "" "Node.js" "Go"
printf "  %-30s %-22s %s\n" "런타임" "nodejs $(( NODE_RT / 1024 )) MB 설치 필요" "없음 (정적 링크)"
printf "  %-30s %-22s %s\n" "의존 패키지" "${NM_PKGS}개" "0개"
printf "  %-30s %-22s %s\n" "배포 파일 수" "$(( NM_FILES + 2 ))개 (+public/)" "1개"
printf "  %-30s %-22s %s\n" "node_modules 크기" "$NM_SIZE" "-"
printf "  %-30s %-22s %s\n" "실행 파일 크기" "-" "$(( GO_SIZE / 1024 / 1024 )) MB (UI 포함)"
printf "  %-30s %-22s %s\n" "노드별 외부 의존" "apt+npm 레지스트리" "없음"

# ---------- 2. 유휴 메모리 ----------
hr; echo "2. 유휴 메모리 (중앙앱)"; hr
printf "  %-30s %-22s %s\n" "RSS" "$(rss_mb "$NODE_C") MB" "$(rss_mb "$GO_C") MB"

# ---------- 3. 업로드 중 피크 메모리 ----------
hr; echo "3. ${SIZE_MB}MB 업로드 중 피크 메모리"; hr
dd if=/dev/urandom of="$TMP/payload.bin" bs=1M count="$SIZE_MB" status=none

WORKER="$(curl -s "http://127.0.0.1:${NODE_CENTRAL_PORT}/api/nodes" \
  | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)"
if [[ -z "$WORKER" ]]; then
  echo "  온라인 노드를 찾지 못했습니다 — 3~5단계를 건너뜁니다." >&2
else
  for impl in node go; do
    if [[ "$impl" == node ]]; then port=$NODE_CENTRAL_PORT; pid=$NODE_C; label="Node.js"
    else port=$GO_CENTRAL_PORT; pid=$GO_C; label="Go"; fi

    # VmHWM 은 프로세스 수명 동안의 최고치라 초기화가 안 된다.
    # 재시작해 기준선을 맞춘 뒤 측정한다.
    svc=$([[ "$impl" == node ]] && echo ceph-block-central || echo ceph-block-central-go)
    systemctl restart "$svc"; sleep 2
    pid=$(main_pid "$svc")

    before=$(rss_mb "$pid")
    curl -s -o /dev/null -F "file=@$TMP/payload.bin;filename=cmp-${impl}.bin" \
      "http://127.0.0.1:${port}/api/nodes/${WORKER}/files"
    printf "  %-30s %-22s %s\n" "$label 중앙앱" "업로드 전 ${before} MB" "피크 $(hwm_mb "$pid") MB"
  done
fi

# ---------- 4. 노드 목록 조회 지연 ----------
hr; echo "4. /api/nodes 조회 지연"; hr
for impl in node go; do
  port=$([[ "$impl" == node ]] && echo $NODE_CENTRAL_PORT || echo $GO_CENTRAL_PORT)
  label=$([[ "$impl" == node ]] && echo "Node.js" || echo "Go")
  t=$( { TIMEFORMAT=%R; time curl -s -o /dev/null "http://127.0.0.1:${port}/api/nodes"; } 2>&1 )
  printf "  %-30s %s초\n" "$label (전 노드 정상)" "$t"
done
echo
echo "  참고: 워커 하나를 멈춰(vagrant halt ceph-worker-2) 다시 실행하면 차이가 커집니다."
echo "        Node 판은 노드를 순차 조회하고 fetch 에 타임아웃이 없어 무응답 노드 하나가"
echo "        목록 전체를 무기한 붙잡습니다. Go 판은 동시 조회 + 5초 상한이라 유계입니다."

# ---------- 5. 교차 확인 ----------
hr; echo "5. 교차 확인 — 같은 RBD 마운트를 보는가"; hr
if [[ -n "$WORKER" ]]; then
  n_list=$(curl -s "http://127.0.0.1:${NODE_CENTRAL_PORT}/api/nodes/${WORKER}/files" | grep -o '"key":"[^"]*"' | sort)
  g_list=$(curl -s "http://127.0.0.1:${GO_CENTRAL_PORT}/api/nodes/${WORKER}/files"   | grep -o '"key":"[^"]*"' | sort)
  if [[ "$n_list" == "$g_list" ]]; then
    echo "  두 UI 의 파일 목록이 동일합니다 ($(grep -c . <<<"$n_list")개)"
  else
    echo "  목록이 다릅니다:"
    diff <(echo "$n_list") <(echo "$g_list") | sed 's/^/    /'
  fi
  # 측정용 파일 정리
  for impl in node go; do
    curl -s -o /dev/null -X DELETE \
      "http://127.0.0.1:${GO_CENTRAL_PORT}/api/nodes/${WORKER}/files/cmp-${impl}.bin"
  done
fi
hr
echo
