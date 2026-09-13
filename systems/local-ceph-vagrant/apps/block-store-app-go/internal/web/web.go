// Package web 은 중앙앱 UI 를 바이너리에 embed 한다.
//
// Node 판은 public/ 디렉터리를 앱과 함께 배포해야 한다. 여기서는 UI 가
// 바이너리 안에 있으므로 배포 대상이 파일 하나로 유지된다.
package web

import (
	"embed"
	"io/fs"
)

//go:embed assets
var assets embed.FS

// FS 는 UI 정적 자산 루트를 반환한다.
func FS() fs.FS {
	sub, err := fs.Sub(assets, "assets")
	if err != nil {
		// embed 는 컴파일 타임에 확정되므로 여기 도달하면 빌드가 잘못된 것이다.
		panic("embed 된 assets 디렉터리를 열 수 없습니다: " + err.Error())
	}
	return sub
}
