#!/bin/bash
#
# 워커(스토리지 노드)에서 실행: 에이전트 기동.
#
# 대조군: ../../block-store-app/scripts/run-agent.sh (Node.js 판)
#   그쪽은 같은 자리에서 다음을 한다 —
#     curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
#     sudo apt-get install -y nodejs
#     npm install --omit=dev
#   즉 노드마다 인터넷·apt 미러·npm 레지스트리 세 곳에 의존한다.
#
# 이 스크립트에는 설치 단계가 없다. 바이너리가 이미 있으면 그냥 실행한다.
#
# 사전: 이 디렉터리(또는 PATH)에 ceph-block-store 바이너리가 있고,
#       RBD 가 STORE_DIR 에 마운트돼 있어야 한다(먼저 setup-rbd-node.sh 실행).
#
# 사용: AGENT_TOKEN=<공유시크릿> bash run-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STORE_DIR="${STORE_DIR:-/srv/rbd-store}"
PORT="${PORT:-4000}"
: "${AGENT_TOKEN:?AGENT_TOKEN 환경변수를 설정하세요 (중앙앱과 동일한 값)}"

# 바이너리 위치: 같은 디렉터리 → 상위 dist/ → PATH 순으로 찾는다.
ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
BIN=""
for cand in \
  "$SCRIPT_DIR/ceph-block-store" \
  "$SCRIPT_DIR/../ceph-block-store" \
  "$SCRIPT_DIR/../dist/ceph-block-store-linux-$ARCH" \
  "$(command -v ceph-block-store 2>/dev/null || true)"
do
  if [[ -n "$cand" && -x "$cand" ]]; then BIN="$cand"; break; fi
done

if [[ -z "$BIN" ]]; then
  echo "바이너리를 찾지 못했습니다. 호스트에서 빌드 후 이 노드로 복사하세요:" >&2
  echo "  bash scripts/build.sh   # dist/ceph-block-store-linux-$ARCH 생성" >&2
  exit 1
fi

if [[ ! -d "$STORE_DIR" ]]; then
  echo "경고: STORE_DIR($STORE_DIR)가 없습니다. setup-rbd-node.sh를 먼저 실행했는지 확인하세요." >&2
fi

echo ">> agent 기동: STORE_DIR=$STORE_DIR PORT=$PORT (Ctrl+C로 종료)"
echo ">> 설치한 패키지: 0개"
exec env ROLE=agent STORE_DIR="$STORE_DIR" PORT="$PORT" AGENT_TOKEN="$AGENT_TOKEN" "$BIN"
