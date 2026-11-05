package media

import "sync"

// keyedMutex 按 key 提供进程内互斥锁，用于「同一条目 / 同一个文件只允许一个写者」的场景。
//
// 比「map[string]*sync.Mutex 只增不减」多一层引用计数：没人持有时表项立即释放，
// 长期运行不会随着条目增删留下越来越大的锁表。
type keyedMutex struct {
	mu    sync.Mutex
	locks map[string]*keyedMutexEntry
}

type keyedMutexEntry struct {
	mu   sync.Mutex
	refs int
}

// Lock 获取 key 对应的锁并阻塞，返回的函数据此解锁。
func (k *keyedMutex) Lock(key string) func() {
	k.mu.Lock()
	if k.locks == nil {
		k.locks = make(map[string]*keyedMutexEntry)
	}
	entry, ok := k.locks[key]
	if !ok {
		entry = &keyedMutexEntry{}
		k.locks[key] = entry
	}
	entry.refs++
	k.mu.Unlock()

	entry.mu.Lock()
	return func() {
		entry.mu.Unlock()

		k.mu.Lock()
		entry.refs--
		if entry.refs == 0 {
			delete(k.locks, key)
		}
		k.mu.Unlock()
	}
}
