package central

import (
	"context"
	"net/http"
	"time"
)

// timeoutCtx 는 요청 컨텍스트에 상한을 씌운다.
func timeoutCtx(r *http.Request, d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), d)
}
