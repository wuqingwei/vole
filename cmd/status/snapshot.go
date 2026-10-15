package main

import (
	"fmt"
	"sort"
	"time"
)

type CPUInfo struct {
	Usage   float64    `json:"usage"`
	Cores   []float64  `json:"per_core"`
	Logical int        `json:"logical_cpu"`
	Load    [3]float64 `json:"load"`
}

type IOInfo struct {
	ReadBps  float64 `json:"read_bps"`
	WriteBps float64 `json:"write_bps"`
}

type NetIface struct {
	Name    string  `json:"name"`
	RxBps   float64 `json:"rx_bps"`
	TxBps   float64 `json:"tx_bps"`
	Default bool    `json:"default"`
}

type NetInfo struct {
	Interface string     `json:"interface"`
	RxBps     float64    `json:"rx_bps"`
	TxBps     float64    `json:"tx_bps"`
	Proxy     string     `json:"proxy,omitempty"`
	Ifaces    []NetIface `json:"interfaces"`
}

type Proc struct {
	PID  int     `json:"pid"`
	Name string  `json:"name"`
	CPU  float64 `json:"cpu"`
}

type ZombieParent struct {
	PID   int    `json:"pid"`
	Name  string `json:"name"`
	Count int    `json:"count"`
}

type Snapshot struct {
	HostInfo
	CollectedAt   string         `json:"collected_at"`
	HealthScore   int            `json:"health_score"`
	CPU           CPUInfo        `json:"cpu"`
	Memory        MemInfo        `json:"memory"`
	Disks         []DiskInfo     `json:"disks"`
	DiskIO        IOInfo         `json:"disk_io"`
	Network       NetInfo        `json:"network"`
	Power         PowerInfo      `json:"power"`
	TopProcs      []Proc         `json:"top_processes"`
	ProcessCount  int            `json:"process_count"`
	ZombieCount   int            `json:"zombie_count"`
	ZombieParents []ZombieParent `json:"zombie_parents"`
	Uptime        string         `json:"uptime"`
	UptimeSeconds int64          `json:"uptime_seconds"`
	Alerts        []string       `json:"alerts,omitempty"`
}

// Collector keeps the previous counters so each Sample returns rates.
type Collector struct {
	host      HostInfo
	t0        time.Time
	cpu0      cpuTimes
	cores0    []cpuTimes
	io0r      uint64
	io0w      uint64
	net0      map[string]ifaceCounters
	proc0     map[int]procSample
	hz        float64
	highCPU   map[int]int // pid -> consecutive samples above threshold
	threshold float64
	window    int
	alerts    bool
}

func NewCollector() *Collector {
	c := &Collector{host: readHost(), hz: 100, highCPU: map[int]int{}, threshold: 80, window: 30, alerts: true}
	c.prime()
	return c
}

func (c *Collector) prime() {
	c.t0 = time.Now()
	c.cpu0, c.cores0 = readCPUTimes()
	c.io0r, c.io0w = readDiskIO()
	c.net0 = readNet()
	c.proc0 = readProcs()
}

func (c *Collector) Sample() Snapshot {
	now := time.Now()
	dt := now.Sub(c.t0).Seconds()
	if dt <= 0 {
		dt = 1
	}
	s := Snapshot{HostInfo: c.host, CollectedAt: now.UTC().Format(time.RFC3339)}

	cpu1, cores1 := readCPUTimes()
	s.CPU.Usage = pct(c.cpu0, cpu1)
	for i := range cores1 {
		if i < len(c.cores0) {
			s.CPU.Cores = append(s.CPU.Cores, pct(c.cores0[i], cores1[i]))
		}
	}
	s.CPU.Logical = len(cores1)
	s.CPU.Load = loadAvg()

	s.Memory, _ = readMem()
	s.Disks = readDisks()

	r, w := readDiskIO()
	s.DiskIO = IOInfo{ReadBps: float64(r-c.io0r) / dt, WriteBps: float64(w-c.io0w) / dt}

	net1 := readNet()
	def := defaultIface()
	s.Network.Interface = def
	s.Network.Proxy = proxyInfo()
	for name, n1 := range net1 {
		n0, ok := c.net0[name]
		if !ok {
			continue
		}
		ni := NetIface{Name: name, RxBps: float64(n1.rx-n0.rx) / dt, TxBps: float64(n1.tx-n0.tx) / dt, Default: name == def}
		s.Network.Ifaces = append(s.Network.Ifaces, ni)
		if name == def {
			s.Network.RxBps, s.Network.TxBps = ni.RxBps, ni.TxBps
		}
	}
	if def == "" { // no default route: sum all
		for _, i := range s.Network.Ifaces {
			s.Network.RxBps += i.RxBps
			s.Network.TxBps += i.TxBps
		}
	}
	sort.Slice(s.Network.Ifaces, func(i, j int) bool { return s.Network.Ifaces[i].Name < s.Network.Ifaces[j].Name })

	s.Power = readPower()

	proc1 := readProcs()
	s.ProcessCount = len(proc1)
	zp := map[int]int{}
	for pid, p := range proc1 {
		if p.state == 'Z' {
			s.ZombieCount++
			zp[p.ppid]++
		}
		if p0, ok := c.proc0[pid]; ok && p.ticks >= p0.ticks {
			cpu := float64(p.ticks-p0.ticks) / c.hz / dt * 100
			if cpu > 0.05 {
				s.TopProcs = append(s.TopProcs, Proc{PID: pid, Name: p.name, CPU: cpu})
			}
			if c.alerts {
				if cpu >= c.threshold {
					c.highCPU[pid]++
				} else {
					delete(c.highCPU, pid)
				}
			}
		}
	}
	for pid := range c.highCPU {
		if _, ok := proc1[pid]; !ok {
			delete(c.highCPU, pid)
		}
	}
	sort.Slice(s.TopProcs, func(i, j int) bool { return s.TopProcs[i].CPU > s.TopProcs[j].CPU })
	if len(s.TopProcs) > 8 {
		s.TopProcs = s.TopProcs[:8]
	}
	for ppid, n := range zp {
		s.ZombieParents = append(s.ZombieParents, ZombieParent{PID: ppid, Name: proc1[ppid].name, Count: n})
	}
	sort.Slice(s.ZombieParents, func(i, j int) bool { return s.ZombieParents[i].Count > s.ZombieParents[j].Count })
	if len(s.ZombieParents) > 3 {
		s.ZombieParents = s.ZombieParents[:3]
	}
	if c.alerts {
		for pid, n := range c.highCPU {
			if float64(n)*dt >= float64(c.window) {
				s.Alerts = append(s.Alerts, fmt.Sprintf("%s (%d) above %.0f%% CPU for %ds+", proc1[pid].name, pid, c.threshold, c.window))
			}
		}
	}

	up := uptime()
	s.UptimeSeconds = int64(up.Seconds())
	s.Uptime = fmtUptime(up)
	s.HealthScore = health(s)

	c.t0, c.cpu0, c.cores0, c.io0r, c.io0w, c.net0, c.proc0 = now, cpu1, cores1, r, w, net1, proc1
	return s
}

func fmtUptime(d time.Duration) string {
	days := int(d.Hours()) / 24
	h := int(d.Hours()) % 24
	m := int(d.Minutes()) % 60
	if days > 0 {
		return fmt.Sprintf("%dd %dh %dm", days, h, m)
	}
	return fmt.Sprintf("%dh %dm", h, m)
}

func health(s Snapshot) int {
	score := 100
	switch {
	case s.CPU.Usage > 90:
		score -= 20
	case s.CPU.Usage > 70:
		score -= 10
	case s.CPU.Usage > 50:
		score -= 4
	}
	if s.CPU.Logical > 0 && s.CPU.Load[2] > float64(s.CPU.Logical)*1.5 {
		score -= 10
	}
	switch {
	case s.Memory.UsedPercent > 92:
		score -= 20
	case s.Memory.UsedPercent > 80:
		score -= 10
	case s.Memory.UsedPercent > 70:
		score -= 4
	}
	if s.Memory.SwapTotal > 0 && float64(s.Memory.SwapUsed)/float64(s.Memory.SwapTotal) > 0.5 {
		score -= 5
	}
	if len(s.Disks) > 0 {
		d := s.Disks[0].UsedPercent
		switch {
		case d > 95:
			score -= 25
		case d > 90:
			score -= 15
		case d > 80:
			score -= 6
		}
	}
	switch {
	case s.Power.TempC > 90:
		score -= 15
	case s.Power.TempC > 80:
		score -= 6
	}
	if s.Power.Present && s.Power.Health > 0 && s.Power.Health < 70 {
		score -= 5
	}
	if s.UptimeSeconds > 30*86400 {
		score -= 5
	}
	if s.DiskIO.ReadBps+s.DiskIO.WriteBps > 300*1024*1024 {
		score -= 4
	}
	if score < 0 {
		score = 0
	}
	return score
}
