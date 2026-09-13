// ceph-block-store — Ceph RBD 노드별 블록 스토어 파일 앱 (Go 구현).
//
// 같은 폴더의 ../block-store-app (Node.js) 과 동일한 HTTP API·동일한 UI 를
// 구현한다. 같은 랩·같은 RBD 마운트 위에서 나란히 띄워 비교하기 위한 것이므로
// 엔드포인트와 환경변수 계약을 임의로 바꾸지 않는다.
//
// 외부 모듈 의존성은 0 이다. 노드에 배포되는 산출물이 파일 하나여야
// "런타임도 패키지 매니저도 없는 노드에 복사 한 번"이 성립한다.
module cephblockstore

go 1.24
