// vole-status: live system health dashboard for Linux.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"golang.org/x/term"

	"vole/internal/units"
)

var version = "dev"

type prefs struct {
	ShowCat   bool `json:"show_cat"`
	CoreLimit int  `json:"core_limit"` // 0 = hide, -1 = all
}

func prefsPath() string {
	d := os.Getenv("XDG_CONFIG_HOME")
	if d == "" {
		d = filepath.Join(os.Getenv("HOME"), ".config")
	}
	return filepath.Join(d, "vole", "status.json")
}

func loadPrefs() prefs {
	p := prefs{ShowCat: true, CoreLimit: 4}
	if b, err := os.ReadFile(prefsPath()); err == nil {
		_ = json.Unmarshal(b, &p)
	}
	return p
}

func savePrefs(p prefs) {
	_ = os.MkdirAll(filepath.Dir(prefsPath()), 0o755)
	b, _ := json.Marshal(p)
	_ = os.WriteFile(prefsPath(), b, 0o644)
}

func main() {
	jsonOut := flag.Bool("json", false, "print one JSON snapshot and exit")
	watch := flag.Bool("watch", false, "stream newline-delimited JSON")
	interval := flag.Duration("interval", time.Second, "refresh interval")
	thr := flag.Float64("proc-cpu-threshold", 80, "alert when a process stays above this CPU %")
	win := flag.Duration("proc-cpu-window", 30*time.Second, "how long a process must stay above the threshold")
	alerts := flag.Bool("proc-cpu-alerts", true, "enable process CPU alerts")
	ver := flag.Bool("version", false, "print version")
	flag.Parse()
	if *ver {
		fmt.Println("vole-status", version)
		return
	}
	if *interval < 200*time.Millisecond {
		*interval = 200 * time.Millisecond
	}

	c := NewCollector()
	c.threshold, c.window, c.alerts = *thr, int(win.Seconds()), *alerts

	piped := !term.IsTerminal(int(os.Stdout.Fd()))
	if *watch {
		enc := json.NewEncoder(os.Stdout)
		for {
			time.Sleep(*interval)
			if err := enc.Encode(c.Sample()); err != nil {
				os.Exit(1)
			}
		}
	}
	if *jsonOut || piped {
		time.Sleep(500 * time.Millisecond)
		s := c.Sample()
		if s.Memory.Total == 0 && s.CPU.Logical == 0 {
			fmt.Fprintln(os.Stderr, "vole-status: no metrics available")
			os.Exit(1)
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(s); err != nil {
			os.Exit(1)
		}
		return
	}

	m := model{c: c, interval: *interval, prefs: loadPrefs()}
	time.Sleep(300 * time.Millisecond)
	m.snap = c.Sample()
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------- TUI

type tickMsg time.Time

type model struct {
	c        *Collector
	snap     Snapshot
	interval time.Duration
	prefs    prefs
	width    int
	height   int
	rxHist   []float64
	txHist   []float64
	frame    int
}

func (m model) tick() tea.Cmd {
	return tea.Tick(m.interval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) Init() tea.Cmd { return m.tick() }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			return m, tea.Quit
		case "k":
			m.prefs.ShowCat = !m.prefs.ShowCat
			savePrefs(m.prefs)
		case "c":
			switch m.prefs.CoreLimit {
			case 0:
				m.prefs.CoreLimit = 4
			case 4:
				m.prefs.CoreLimit = 8
			case 8:
				m.prefs.CoreLimit = -1
			default:
				m.prefs.CoreLimit = 0
			}
			savePrefs(m.prefs)
		}
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		m.snap = m.c.Sample()
		m.rxHist = push(m.rxHist, m.snap.Network.RxBps, 16)
		m.txHist = push(m.txHist, m.snap.Network.TxBps, 16)
		m.frame++
		return m, m.tick()
	}
	return m, nil
}

func push(h []float64, v float64, n int) []float64 {
	h = append(h, v)
	if len(h) > n {
		h = h[len(h)-n:]
	}
	return h
}

var (
	cBold   = lipgloss.NewStyle().Bold(true)
	cDim    = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	cGreen  = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	cYellow = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	cRed    = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	cCyan   = lipgloss.NewStyle().Foreground(lipgloss.Color("6")).Bold(true)
	cMag    = lipgloss.NewStyle().Foreground(lipgloss.Color("5"))
)

func levelStyle(p float64) lipgloss.Style {
	switch {
	case p >= 85:
		return cRed
	case p >= 65:
		return cYellow
	default:
		return cGreen
	}
}

func bar(p float64, w int) string {
	return levelStyle(p).Render(units.Bar(p, w, "█", "")) + cDim.Render(strings.Repeat("░", w-int(clamp(p)/100*float64(w)+0.5)))
}

func clamp(p float64) float64 {
	if p < 0 {
		return 0
	}
	if p > 100 {
		return 100
	}
	return p
}

func ioMeter(bps float64) string {
	// 5 blocks, log-ish scale up to 200MB/s
	steps := []float64{0.1, 5, 25, 80, 200}
	mb := bps / 1024 / 1024
	n := 0
	for _, s := range steps {
		if mb >= s {
			n++
		}
	}
	return strings.Repeat("▮", n) + cDim.Render(strings.Repeat("▯", 5-n))
}

func rate(bps float64) string { return fmt.Sprintf("%.2f MB/s", bps/1024/1024) }

func row(label, val string) string { return fmt.Sprintf("%-7s %s", label, val) }

func (m model) View() string {
	s := m.snap
	bw := 18
	colW := 42
	if m.width > 0 && m.width < 90 {
		colW = m.width - 2
	}

	hs := s.HealthScore
	hcol := cGreen
	if hs < 60 {
		hcol = cRed
	} else if hs < 80 {
		hcol = cYellow
	}
	head := fmt.Sprintf("%s  Health %s  %s",
		cBold.Render("Vole Status"),
		hcol.Render(fmt.Sprintf("● %d", hs)),
		cDim.Render(strings.Join(nonEmpty(s.Model, units.Truncate(s.CPU0(), 28), units.Human(s.Memory.Total), s.OS), " · ")))

	// CPU
	cpu := []string{cCyan.Render("⚙ CPU")}
	cpu = append(cpu, row("Total", bar(s.CPU.Usage, bw)+fmt.Sprintf(" %5.1f%%", s.CPU.Usage)))
	cpu = append(cpu, row("Load", fmt.Sprintf("%.2f / %.2f / %.2f (%d cores)", s.CPU.Load[0], s.CPU.Load[1], s.CPU.Load[2], s.CPU.Logical)))
	limit := m.prefs.CoreLimit
	if limit < 0 || limit > len(s.CPU.Cores) {
		limit = len(s.CPU.Cores)
	}
	for i := 0; i < limit; i++ {
		cpu = append(cpu, row(fmt.Sprintf("Core %d", i+1), bar(s.CPU.Cores[i], bw)+fmt.Sprintf(" %5.1f%%", s.CPU.Cores[i])))
	}

	// Memory
	mem := []string{cCyan.Render("▦ Memory")}
	mem = append(mem, row("Used", bar(s.Memory.UsedPercent, bw)+fmt.Sprintf(" %5.1f%%", s.Memory.UsedPercent)))
	mem = append(mem, row("Total", fmt.Sprintf("%.1f / %.1f GB", gb(s.Memory.Used), gb(s.Memory.Total))))
	mem = append(mem, row("Avail", fmt.Sprintf("%.1f GB · cache %.1f GB", gb(s.Memory.Available), gb(s.Memory.Cached))))
	if s.Memory.SwapTotal > 0 {
		sp := float64(s.Memory.SwapUsed) / float64(s.Memory.SwapTotal) * 100
		mem = append(mem, row("Swap", bar(sp, bw)+fmt.Sprintf(" %.1f/%.1f GB", gb(s.Memory.SwapUsed), gb(s.Memory.SwapTotal))))
	}

	// Disk
	disk := []string{cCyan.Render("▤ Disk")}
	for i, d := range s.Disks {
		if i >= 3 {
			break
		}
		disk = append(disk, row(units.Truncate(mountLabel(d.Mount), 7), bar(d.UsedPercent, bw)+fmt.Sprintf(" %5.1f%%", d.UsedPercent)))
		if i == 0 {
			disk = append(disk, row("Free", fmt.Sprintf("%s of %s", units.Human(d.Free), units.Human(d.Total))))
		}
	}
	disk = append(disk, row("Read", ioMeter(s.DiskIO.ReadBps)+"  "+rate(s.DiskIO.ReadBps)))
	disk = append(disk, row("Write", ioMeter(s.DiskIO.WriteBps)+"  "+rate(s.DiskIO.WriteBps)))

	// Power
	pw := []string{cCyan.Render("⚡ Power")}
	if s.Power.Present {
		pw = append(pw, row("Level", bar(float64(s.Power.Level), bw)+fmt.Sprintf(" %d%%", s.Power.Level)))
		pw = append(pw, row("Status", s.Power.Status))
		h := "Normal"
		if s.Power.Health > 0 {
			h = fmt.Sprintf("%.0f%%", s.Power.Health)
		}
		if s.Power.Cycles > 0 {
			h += fmt.Sprintf(" · %d cycles", s.Power.Cycles)
		}
		pw = append(pw, row("Health", h))
	} else {
		src := "AC power"
		if !s.Power.OnAC {
			src = "Desktop / no battery"
		}
		pw = append(pw, row("Source", src))
	}
	t := "n/a"
	if s.Power.TempC > 0 {
		t = levelStyle(s.Power.TempC).Render(fmt.Sprintf("%.0f°C", s.Power.TempC))
	}
	if s.Power.FanRPM > 0 {
		t += fmt.Sprintf(" · %d RPM", s.Power.FanRPM)
	}
	pw = append(pw, row("Temp", t))
	pw = append(pw, row("Uptime", s.Uptime))

	// Network
	nw := []string{cCyan.Render("⇅ Network") + cDim.Render("  "+s.Network.Interface)}
	nw = append(nw, row("Down", cGreen.Render(units.Spark(pad(m.rxHist, 16)))+"  "+rate(s.Network.RxBps)))
	nw = append(nw, row("Up", cMag.Render(units.Spark(pad(m.txHist, 16)))+"  "+rate(s.Network.TxBps)))
	if s.Network.Proxy != "" {
		nw = append(nw, row("Proxy", units.Truncate(s.Network.Proxy, colW-9)))
	}

	// Processes
	pr := []string{cCyan.Render("▶ Processes") + cDim.Render(fmt.Sprintf("  %d total", s.ProcessCount))}
	if s.ZombieCount > 0 {
		z := fmt.Sprintf("%d", s.ZombieCount)
		if len(s.ZombieParents) > 0 {
			z += fmt.Sprintf(" · %s (%d) ×%d", s.ZombieParents[0].Name, s.ZombieParents[0].PID, s.ZombieParents[0].Count)
		}
		pr = append(pr, row("Zombies", cYellow.Render(z)))
	}
	for i, p := range s.TopProcs {
		if i >= 5 {
			break
		}
		n := int(p.CPU / 20)
		if n > 5 {
			n = 5
		}
		pr = append(pr, fmt.Sprintf("%-14s %s %5.1f%%", units.Truncate(p.Name, 14), strings.Repeat("▮", n)+cDim.Render(strings.Repeat("▯", 5-n)), p.CPU))
	}

	col := func(l []string) string { return lipgloss.NewStyle().Width(colW).Render(strings.Join(l, "\n")) }
	var body string
	if m.width == 0 || m.width >= 2*colW+2 {
		body = strings.Join([]string{
			lipgloss.JoinHorizontal(lipgloss.Top, col(cpu), "  ", col(mem)),
			lipgloss.JoinHorizontal(lipgloss.Top, col(disk), "  ", col(pw)),
			lipgloss.JoinHorizontal(lipgloss.Top, col(nw), "  ", col(pr)),
		}, "\n\n")
	} else {
		body = strings.Join([]string{col(cpu), col(mem), col(disk), col(pw), col(nw), col(pr)}, "\n\n")
	}
	out := head + "\n\n" + body
	if len(s.Alerts) > 0 {
		out += "\n\n" + cRed.Render("! "+strings.Join(s.Alerts, "\n! "))
	}
	if m.prefs.ShowCat {
		out += "\n\n" + cDim.Render(vole(m.frame))
	}
	out += "\n" + cDim.Render("q quit · c cores · k mascot")
	return out
}

func vole(frame int) string {
	frames := []string{"  (\\_/)  ~ sniffing for junk", "  (•ᴥ•)  ~ all good down here", "  (\\_/)  ~ digging…"}
	return frames[(frame/4)%len(frames)]
}

func (s Snapshot) CPU0() string { return s.HostInfo.CPU }

func gb(b int64) float64 { return float64(b) / 1024 / 1024 / 1024 }

func pad(h []float64, n int) []float64 {
	if len(h) >= n {
		return h
	}
	return append(make([]float64, n-len(h)), h...)
}

func mountLabel(m string) string {
	if m == "/" {
		return "Used"
	}
	return filepath.Base(m)
}

func nonEmpty(xs ...string) []string {
	var o []string
	for _, x := range xs {
		if strings.TrimSpace(x) != "" && x != "0B" {
			o = append(o, x)
		}
	}
	return o
}
