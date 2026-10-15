package main

import (
	"container/heap"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	statusComplete    = "complete"
	statusPartial     = "partial"
	statusUnavailable = "unavailable"
)

type Entry struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Size    int64  `json:"size"`
	IsDir   bool   `json:"is_dir"`
	Files   int64  `json:"files,omitempty"`
	ModTime int64  `json:"mtime,omitempty"`
	Status  string `json:"scan_status"`
	Label   string `json:"label,omitempty"`
	Old     bool   `json:"-"`
}

type LargeFile struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
}

type Result struct {
	Path       string      `json:"path"`
	Overview   bool        `json:"overview"`
	Entries    []Entry     `json:"entries"`
	LargeFiles []LargeFile `json:"large_files"`
	TotalSize  int64       `json:"total_size"`
	TotalFiles int64       `json:"total_files"`
	Status     string      `json:"scan_status"`
}

// Virtual filesystems and paths never worth walking.
var skipPaths = map[string]bool{"/proc": true, "/sys": true, "/dev": true, "/run": true, "/tmp/.X11-unix": true}

type inodeKey struct{ dev, ino uint64 }

type Scanner struct {
	sem      chan struct{}
	mu       sync.Mutex
	seen     map[inodeKey]struct{}
	large    largeHeap
	largeMin int64
	Files    atomic.Int64
	Bytes    atomic.Int64
	Deadline time.Time
}

func NewScanner() *Scanner {
	return &Scanner{sem: make(chan struct{}, 32), seen: map[inodeKey]struct{}{}, largeMin: 50 << 20}
}

func diskUsage(st *syscall.Stat_t) int64 {
	if st.Blocks > 0 {
		return st.Blocks * 512
	}
	return st.Size
}

// sizeOf walks p (not crossing filesystems) and returns bytes, files, status.
func (s *Scanner) sizeOf(p string, dev uint64) (int64, int64, string) {
	if skipPaths[p] {
		return 0, 0, statusComplete
	}
	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return 0, 0, statusUnavailable
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFDIR {
		return s.fileSize(p, &st), 1, statusComplete
	}
	if dev != 0 && uint64(st.Dev) != dev {
		return 0, 0, statusComplete // other filesystem
	}
	if !s.Deadline.IsZero() && time.Now().After(s.Deadline) {
		return 0, 0, statusPartial
	}
	f, err := os.Open(p)
	if err != nil {
		return diskUsage(&st), 0, statusUnavailable
	}
	names, err := f.Readdirnames(-1)
	f.Close()
	status := statusComplete
	if err != nil {
		status = statusPartial
	}
	total := diskUsage(&st)
	var files int64
	var wg sync.WaitGroup
	var mu sync.Mutex
	for _, n := range names {
		child := filepath.Join(p, n)
		var cst syscall.Stat_t
		if err := syscall.Lstat(child, &cst); err != nil {
			mu.Lock()
			status = statusPartial
			mu.Unlock()
			continue
		}
		if cst.Mode&syscall.S_IFMT != syscall.S_IFDIR {
			sz := s.fileSize(child, &cst)
			mu.Lock()
			total += sz
			files++
			mu.Unlock()
			continue
		}
		select {
		case s.sem <- struct{}{}:
			wg.Add(1)
			go func(c string) {
				defer wg.Done()
				b, fl, stt := s.sizeOf(c, uint64(st.Dev))
				<-s.sem
				mu.Lock()
				total += b
				files += fl
				if stt != statusComplete {
					status = statusPartial
				}
				mu.Unlock()
			}(child)
		default:
			b, fl, stt := s.sizeOf(child, uint64(st.Dev))
			mu.Lock()
			total += b
			files += fl
			if stt != statusComplete {
				status = statusPartial
			}
			mu.Unlock()
		}
	}
	wg.Wait()
	return total, files, status
}

func (s *Scanner) fileSize(p string, st *syscall.Stat_t) int64 {
	s.Files.Add(1)
	if st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return 0
	}
	if st.Nlink > 1 { // count hard links once
		k := inodeKey{uint64(st.Dev), uint64(st.Ino)}
		s.mu.Lock()
		if _, ok := s.seen[k]; ok {
			s.mu.Unlock()
			return 0
		}
		s.seen[k] = struct{}{}
		s.mu.Unlock()
	}
	sz := diskUsage(st)
	s.Bytes.Add(sz)
	if sz >= s.largeMin {
		s.mu.Lock()
		heap.Push(&s.large, LargeFile{Name: filepath.Base(p), Path: p, Size: sz})
		if s.large.Len() > 30 {
			heap.Pop(&s.large)
		}
		s.mu.Unlock()
	}
	return sz
}

// ScanDir lists the direct children of dir with their recursive sizes.
func (s *Scanner) ScanDir(dir string) Result {
	res := Result{Path: dir, Status: statusComplete}
	var st syscall.Stat_t
	if err := syscall.Stat(dir, &st); err != nil {
		res.Status = statusUnavailable
		return res
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		res.Status = statusUnavailable
		return res
	}
	out := make([]Entry, len(ents))
	var wg sync.WaitGroup
	for i, e := range ents {
		i, e := i, e
		wg.Add(1)
		go func() {
			defer wg.Done()
			p := filepath.Join(dir, e.Name())
			en := Entry{Name: e.Name(), Path: p, IsDir: e.IsDir()}
			if info, err := e.Info(); err == nil {
				en.ModTime = info.ModTime().Unix()
			}
			if e.Type()&os.ModeSymlink != 0 {
				var lst syscall.Stat_t
				_ = syscall.Lstat(p, &lst)
				en.Size, en.Status = diskUsage(&lst), statusComplete
			} else {
				en.Size, en.Files, en.Status = s.sizeOf(p, uint64(st.Dev))
			}
			out[i] = en
		}()
	}
	wg.Wait()
	sort.Slice(out, func(i, j int) bool { return out[i].Size > out[j].Size })
	for _, e := range out {
		res.TotalSize += e.Size
		res.TotalFiles += e.Files
		if !e.IsDir {
			res.TotalFiles++
		}
		if e.Status != statusComplete {
			res.Status = statusPartial
		}
	}
	res.Entries = out
	res.LargeFiles = s.Large()
	return res
}

func (s *Scanner) Large() []LargeFile {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := make([]LargeFile, len(s.large))
	copy(l, s.large)
	sort.Slice(l, func(i, j int) bool { return l[i].Size > l[j].Size })
	if len(l) > 20 {
		l = l[:20]
	}
	return l
}

// Overview builds the start screen: well-known places on Linux.
func (s *Scanner) Overview() Result {
	home, _ := os.UserHomeDir()
	type loc struct{ label, path string }
	locs := []loc{
		{"Home", home},
		{"User cache", filepath.Join(home, ".cache")},
		{"User data", filepath.Join(home, ".local/share")},
		{"User config", filepath.Join(home, ".config")},
		{"Flatpak (user)", filepath.Join(home, ".local/share/flatpak")},
		{"Flatpak (system)", "/var/lib/flatpak"},
		{"Snap", "/var/lib/snapd/snaps"},
		{"Docker", "/var/lib/docker"},
		{"Package cache", "/var/cache"},
		{"System logs", "/var/log"},
		{"Programs (/usr)", "/usr"},
		{"Optional (/opt)", "/opt"},
		{"Trash", filepath.Join(home, ".local/share/Trash")},
	}
	res := Result{Path: "/", Overview: true, Status: statusComplete}
	var wg sync.WaitGroup
	out := make([]Entry, len(locs))
	for i, l := range locs {
		i, l := i, l
		if _, err := os.Lstat(l.path); err != nil {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			b, f, st := s.sizeOf(l.path, 0)
			out[i] = Entry{Name: l.label, Label: l.label, Path: l.path, Size: b, Files: f, IsDir: true, Status: st}
		}()
	}
	wg.Wait()
	// Old downloads (90 days+)
	dl := filepath.Join(home, "Downloads")
	if ents, err := os.ReadDir(dl); err == nil {
		var sz int64
		cut := time.Now().AddDate(0, 0, -90)
		for _, e := range ents {
			info, err := e.Info()
			if err != nil || info.ModTime().After(cut) {
				continue
			}
			b, _, _ := s.sizeOf(filepath.Join(dl, e.Name()), 0)
			sz += b
		}
		if sz > 0 {
			out = append(out, Entry{Name: "Old Downloads (90d+)", Label: "Old Downloads (90d+)", Path: dl, Size: sz, IsDir: true, Status: statusComplete, Old: true})
		}
	}
	for _, e := range out {
		if e.Path == "" {
			continue
		}
		if e.Status != statusComplete {
			res.Status = statusPartial
		}
		res.Entries = append(res.Entries, e)
	}
	sort.SliceStable(res.Entries, func(i, j int) bool { return res.Entries[i].Size > res.Entries[j].Size })
	for _, e := range res.Entries {
		res.TotalSize += e.Size
		res.TotalFiles += e.Files
	}
	res.LargeFiles = s.Large()
	return res
}

func freeSpace(p string) int64 {
	var fs syscall.Statfs_t
	if syscall.Statfs(p, &fs) != nil {
		return 0
	}
	return int64(fs.Bavail) * int64(fs.Bsize)
}

// ---- min-heap of large files
type largeHeap []LargeFile

func (h largeHeap) Len() int            { return len(h) }
func (h largeHeap) Less(i, j int) bool  { return h[i].Size < h[j].Size }
func (h largeHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *largeHeap) Push(x interface{}) { *h = append(*h, x.(LargeFile)) }
func (h *largeHeap) Pop() interface{} {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}
