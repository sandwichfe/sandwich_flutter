package media

import (
	"errors"
	"testing"
)

func TestScanProgressSnapshot(t *testing.T) {
	var progress scanProgress
	progress.begin()
	progress.setLibrary("lib1", "电影")
	progress.addFiles(3)
	progress.markScanned("/media/a.mkv")
	progress.addFailure("/media/b.mkv", errors.New("探测失败"))

	snapshot := progress.snapshot()
	if !snapshot.Running || snapshot.LibraryID != "lib1" || snapshot.LibraryName != "电影" {
		t.Fatalf("扫描状态不符合预期: %+v", snapshot)
	}
	if snapshot.Total != 3 || snapshot.Scanned != 1 {
		t.Fatalf("计数 = %d/%d，期望 1/3", snapshot.Scanned, snapshot.Total)
	}
	if snapshot.CurrentPath != "/media/a.mkv" {
		t.Fatalf("currentPath = %q", snapshot.CurrentPath)
	}
	if len(snapshot.Failures) != 1 || snapshot.Failures[0].Reason != "探测失败" {
		t.Fatalf("失败列表不符合预期: %+v", snapshot.Failures)
	}

	// 快照必须是副本：外部修改不能反向污染扫描状态。
	snapshot.Failures[0].Reason = "被改写"
	if progress.snapshot().Failures[0].Reason != "探测失败" {
		t.Fatal("快照与内部状态共享了失败列表")
	}

	progress.finish()
	finished := progress.snapshot()
	if finished.Running {
		t.Fatal("finish 后 running 应为 false")
	}
	if finished.FinishedAt.IsZero() {
		t.Fatal("finish 后应记录结束时间")
	}
}
