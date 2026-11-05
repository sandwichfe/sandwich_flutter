package media

import (
	"log"
	"runtime/debug"
)

// RunSafe 在独立 goroutine 中执行 fn，并兜住 panic。
//
// 后台任务（扫描、抽帧、任务队列）不在 HTTP 中间件的 recover 覆盖范围内，
// 一次 nil 解引用就会打死整个进程；而扫描与 ffmpeg 恰恰是最容易出错的路径。
// name 只用于日志定位，建议写成「缩略图预生成」这类人话。
func RunSafe(name string, fn func()) {
	go func() {
		defer RecoverBackground(name)
		fn()
	}()
}

// RecoverBackground 返回一个可 defer 的 panic 回收函数，供已经在 goroutine 里的场景使用。
func RecoverBackground(name string) func() {
	return func() {
		if recovered := recover(); recovered != nil {
			log.Printf("[后台任务] %s panic: %v\n%s", name, recovered, debug.Stack())
		}
	}
}
