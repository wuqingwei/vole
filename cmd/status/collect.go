package main

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ---------- raw readers

func readFile(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func readInt(p string) (int64, bool) {
	s := readFile(p)
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseInt(s, 10, 64)
	return v, err == nil
}

// ---------- CPU

type cpuTimes struct{ idle, total uint64 }

func readCPUTimes() (cpuTimes, []cpuTimes) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return cpuTimes{}, nil
	}
	defer f.Close()
	var all cpuTimes
	var cores []cpuTimes
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "cpu") {
			continue
		}
		fs := strings.Fields(line)
		var t cpuTimes
		for i, v := range fs[1:] {
			n, _ := strconv.ParseUint(v, 10, 64)
			if i >= 8 { // guest time already counted in user
				break
			}
			t.total += n
			if i == 3 || i == 4 { // idle + iowait
				t.idle += n
			}
		}
		if fs[0] == "cpu" {
			all = t
		} else {
			cores = append(cores, t)
		}
	}
	return all, cores
}

func pct(a, b cpuTimes) float64 {
	dt := float64(b.total - a.total)
	if dt <= 0 {
		return 0
	}
	return (1 - float64(b.idle-a.idle)/dt) * 100
}

// ---------- memory

type MemInfo struct {
	Total       int64   `json:"total"`
	Used        int64   `json:"used"`
	Available   int64   `json:"available"`
	UsedPercent float64 `json:"used_percent"`
	Cached      int64   `json:"cached"`
	SwapTotal   int64   `json:"swap_total"`
	SwapUsed    int64   `json:"swap_used"`
}

func readMem() (MemInfo, bool) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return MemInfo{}, false
	}
	defer f.Close()
	m := map[string]int64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		if len(fs) >= 2 {
			v, _ := strconv.ParseInt(fs[1], 10, 64)
			m[strings.TrimSuffix(fs[0], ":")] = v * 1024
		}
	}
	mi := MemInfo{Total: m["MemTotal"], Available: m["MemAvailable"], Cached: m["Cached"] + m["Buffers"], SwapTotal: m["SwapTotal"], SwapUsed: m["SwapTotal"] - m["SwapFree"]}
	if mi.Available == 0 {
		mi.Available = m["MemFree"] + mi.Cached
	}
	mi.Used = mi.Total - mi.Available
	if mi.Total > 0 {
		mi.UsedPercent = float64(mi.Used) / float64(mi.Total) * 100
	}
	return mi, mi.Total > 0
}

// ---------- disks

type DiskInfo struct {
	Mount       string  `json:"mount"`
	Device      string  `json:"device"`
	FSType      string  `json:"fstype"`
	Total       int64   `json:"total"`
	Used        int64   `json:"used"`
	Free        int64   `json:"free"`
	UsedPercent float64 `json:"used_percent"`
}

var realFS = map[string]bool{"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true, "f2fs": true, "zfs": true, "vfat": true, "exfat": true, "ntfs": true, "ntfs3": true, "fuseblk": true, "jfs": true, "reiserfs": true, "bcachefs": true}

func readDisks() []DiskInfo {
	f, err := os.Open("/proc/self/mounts")
	if err != nil {
		return nil
	}
	defer f.Close()
	seen := map[string]bool{}
	var out []DiskInfo
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		if len(fs) < 3 {
			continue
		}
		dev, mnt, typ := fs[0], strings.ReplaceAll(fs[1], `\040`, " "), fs[2]
		if !realFS[typ] && mnt != "/" {
			continue
		}
		if strings.HasPrefix(mnt, "/snap/") || strings.HasPrefix(mnt, "/boot/efi") || strings.HasPrefix(mnt, "/var/lib/docker") {
			continue
		}
		if seen[dev] {
			continue
		}
		var st syscall.Statfs_t
		if syscall.Statfs(mnt, &st) != nil || st.Blocks == 0 {
			continue
		}
		seen[dev] = true
		total := int64(st.Blocks) * int64(st.Bsize)
		free := int64(st.Bavail) * int64(st.Bsize)
		used := total - int64(st.Bfree)*int64(st.Bsize)
		d := DiskInfo{Mount: mnt, Device: dev, FSType: typ, Total: total, Used: used, Free: free}
		if used+free > 0 {
			d.UsedPercent = float64(used) / float64(used+free) * 100
		}
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Mount == "/" {
			return true
		}
		if out[j].Mount == "/" {
			return false
		}
		return out[i].Total > out[j].Total
	})
	return out
}

// whole-disk sector counters (read, written)
func readDiskIO() (uint64, uint64) {
	f, err := os.Open("/proc/diskstats")
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	var r, w uint64
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		if len(fs) < 10 {
			continue
		}
		name := fs[2]
		if strings.HasPrefix(name, "loop") || strings.HasPrefix(name, "ram") || strings.HasPrefix(name, "zram") || strings.HasPrefix(name, "dm-") || strings.HasPrefix(name, "sr") {
			continue
		}
		if _, err := os.Stat("/sys/block/" + name); err != nil { // partitions are not under /sys/block
			continue
		}
		a, _ := strconv.ParseUint(fs[5], 10, 64)
		b, _ := strconv.ParseUint(fs[9], 10, 64)
		r += a
		w += b
	}
	return r * 512, w * 512
}

// ---------- network

type ifaceCounters struct{ rx, tx uint64 }

func readNet() map[string]ifaceCounters {
	f, err := os.Open("/proc/net/dev")
	if err != nil {
		return nil
	}
	defer f.Close()
	out := map[string]ifaceCounters{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		i := strings.Index(line, ":")
		if i < 0 {
			continue
		}
		name := strings.TrimSpace(line[:i])
		fs := strings.Fields(line[i+1:])
		if len(fs) < 9 || name == "lo" {
			continue
		}
		rx, _ := strconv.ParseUint(fs[0], 10, 64)
		tx, _ := strconv.ParseUint(fs[8], 10, 64)
		out[name] = ifaceCounters{rx, tx}
	}
	return out
}

func defaultIface() string {
	f, err := os.Open("/proc/net/route")
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	best, bestMetric := "", int64(1<<62)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		if len(fs) > 6 && fs[1] == "00000000" {
			m, _ := strconv.ParseInt(fs[6], 10, 64)
			if m < bestMetric {
				best, bestMetric = fs[0], m
			}
		}
	}
	return best
}

func proxyInfo() string {
	for _, k := range []string{"https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"} {
		if v := os.Getenv(k); v != "" {
			kind := "HTTP"
			if strings.HasPrefix(v, "socks") {
				kind = "SOCKS"
			}
			v = strings.TrimPrefix(strings.TrimPrefix(strings.TrimPrefix(v, "http://"), "https://"), "socks5://")
			if i := strings.LastIndex(v, "@"); i >= 0 {
				v = v[i+1:]
			}
			return kind + " · " + strings.TrimSuffix(v, "/")
		}
	}
	return ""
}

// ---------- power & thermals

type PowerInfo struct {
	Present bool    `json:"present"`
	Level   int     `json:"level"`
	Status  string  `json:"status"`
	Health  float64 `json:"health_percent,omitempty"`
	Cycles  int     `json:"cycles,omitempty"`
	OnAC    bool    `json:"on_ac"`
	TempC   float64 `json:"temp_c,omitempty"`
	FanRPM  int     `json:"fan_rpm,omitempty"`
}

func readPower() PowerInfo {
	var p PowerInfo
	items, _ := filepath.Glob("/sys/class/power_supply/*")
	for _, d := range items {
		typ := readFile(d + "/type")
		switch typ {
		case "Battery":
			if readFile(d+"/scope") == "Device" { // mice, keyboards
				continue
			}
			p.Present = true
			if v, ok := readInt(d + "/capacity"); ok {
				p.Level = int(v)
			}
			p.Status = readFile(d + "/status")
			if v, ok := readInt(d + "/cycle_count"); ok && v > 0 {
				p.Cycles = int(v)
			}
			full, ok1 := readInt(d + "/energy_full")
			design, ok2 := readInt(d + "/energy_full_design")
			if !ok1 || !ok2 {
				full, ok1 = readInt(d + "/charge_full")
				design, ok2 = readInt(d + "/charge_full_design")
			}
			if ok1 && ok2 && design > 0 {
				p.Health = float64(full) / float64(design) * 100
			}
		case "Mains", "USB":
			if v, ok := readInt(d + "/online"); ok && v == 1 {
				p.OnAC = true
			}
		}
	}
	p.TempC = readTemp()
	p.FanRPM = readFan()
	return p
}

func readTemp() float64 {
	best := 0.0
	// prefer CPU package sensors from hwmon
	hw, _ := filepath.Glob("/sys/class/hwmon/hwmon*")
	for _, h := range hw {
		name := readFile(h + "/name")
		if name != "coretemp" && name != "k10temp" && name != "zenpower" && name != "cpu_thermal" && name != "soc_thermal" && name != "acpitz" {
			continue
		}
		ts, _ := filepath.Glob(h + "/temp*_input")
		for _, t := range ts {
			if v, ok := readInt(t); ok && float64(v)/1000 > best && v < 150000 {
				best = float64(v) / 1000
			}
		}
	}
	if best > 0 {
		return best
	}
	zs, _ := filepath.Glob("/sys/class/thermal/thermal_zone*")
	for _, z := range zs {
		if v, ok := readInt(z + "/temp"); ok && float64(v)/1000 > best && v < 150000 {
			best = float64(v) / 1000
		}
	}
	return best
}

func readFan() int {
	fs, _ := filepath.Glob("/sys/class/hwmon/hwmon*/fan*_input")
	max := 0
	for _, f := range fs {
		if v, ok := readInt(f); ok && int(v) > max {
			max = int(v)
		}
	}
	return max
}

// ---------- processes

type procSample struct {
	name  string
	ticks uint64
	state byte
	ppid  int
}

func readProcs() map[int]procSample {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	out := make(map[int]procSample, len(ents))
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/stat")
		if err != nil {
			continue
		}
		s := string(b)
		l, r := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
		if l < 0 || r < 0 || r+2 >= len(s) {
			continue
		}
		name := s[l+1 : r]
		fs := strings.Fields(s[r+2:])
		if len(fs) < 13 {
			continue
		}
		ut, _ := strconv.ParseUint(fs[11], 10, 64)
		st, _ := strconv.ParseUint(fs[12], 10, 64)
		pp, _ := strconv.Atoi(fs[1])
		out[pid] = procSample{name: name, ticks: ut + st, state: fs[0][0], ppid: pp}
	}
	return out
}

// ---------- host

type HostInfo struct {
	Hostname string `json:"host"`
	Model    string `json:"model,omitempty"`
	CPU      string `json:"cpu_model"`
	Cores    int    `json:"logical_cpu"`
	OS       string `json:"os"`
	Kernel   string `json:"kernel"`
}

func readHost() HostInfo {
	h := HostInfo{}
	h.Hostname, _ = os.Hostname()
	h.Model = strings.TrimSpace(readFile("/sys/class/dmi/id/product_name"))
	if h.Model == "" || strings.Contains(strings.ToLower(h.Model), "to be filled") {
		h.Model = strings.TrimRight(readFile("/proc/device-tree/model"), "\x00")
	}
	if f, err := os.Open("/proc/cpuinfo"); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			l := sc.Text()
			if strings.HasPrefix(l, "processor") {
				h.Cores++
			}
			if h.CPU == "" && (strings.HasPrefix(l, "model name") || strings.HasPrefix(l, "Hardware") || strings.HasPrefix(l, "cpu model")) {
				if i := strings.Index(l, ":"); i >= 0 {
					h.CPU = strings.TrimSpace(l[i+1:])
				}
			}
		}
		f.Close()
	}
	if h.CPU == "" {
		h.CPU = runtimeArch()
	}
	h.CPU = strings.NewReplacer("(R)", "", "(TM)", "", " CPU", "", "  ", " ").Replace(h.CPU)
	if i := strings.Index(h.CPU, " @ "); i > 0 {
		h.CPU = h.CPU[:i]
	}
	for _, l := range strings.Split(readFile("/etc/os-release"), "\n") {
		if strings.HasPrefix(l, "PRETTY_NAME=") {
			h.OS = strings.Trim(strings.TrimPrefix(l, "PRETTY_NAME="), `"`)
		}
	}
	var u syscall.Utsname
	if syscall.Uname(&u) == nil {
		h.Kernel = utsString(u.Release[:])
	}
	return h
}

func uptime() time.Duration {
	s := strings.Fields(readFile("/proc/uptime"))
	if len(s) == 0 {
		return 0
	}
	f, _ := strconv.ParseFloat(s[0], 64)
	return time.Duration(f) * time.Second
}

func loadAvg() [3]float64 {
	var l [3]float64
	fs := strings.Fields(readFile("/proc/loadavg"))
	for i := 0; i < 3 && i < len(fs); i++ {
		l[i], _ = strconv.ParseFloat(fs[i], 64)
	}
	return l
}
