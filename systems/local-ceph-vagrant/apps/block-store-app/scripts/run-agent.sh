#!/bin/bash
#
# 워커(스토리지 노드)에서 실행: 의존성 설치 후 에이전트 기동.
# 사전: 이 디렉터리에 app.js, package.json 이 있고, RBD가 STORE_DIR에 마운트돼 있어야 함
#       (먼저 setup-rbd-node.sh 실행).
#
# 사용: AGENT_TOKEN=<공유시크릿> bash run-agent.sh

set -euo pipefail

STORE_DIR="${STORE_DIR:-/srv/rbd-store}"
PORT="${PORT:-4000}"
: "${AGENT_TOKEN:?AGENT_TOKEN 환경변수를 설정하세요 (중앙앱과 동일한 값)}"

# Node.js 없으면 설치 (NodeSource 20 LTS)
if ! command -v node >/dev/null 2>&1; then
  echo ">> Node.js 설치 중..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

echo ">> 의존성 설치 (express, multer)..."
npm install --omit=dev

if [[ ! -d "$STORE_DIR" ]]; then
  echo "경고: STORE_DIR($STORE_DIR)가 없습니다. setup-rbd-node.sh를 먼저 실행했는지 확인하세요." >&2
fi

echo ">> agent 기동: STORE_DIR=$STORE_DIR PORT=$PORT (Ctrl+C로 종료)"
exec env ROLE=agent STORE_DIR="$STORE_DIR" PORT="$PORT" AGENT_TOKEN="$AGENT_TOKEN" node app.js
