// vole-analyze: interactive disk explorer for Linux.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"vole/internal/units"
)

var version = "dev"

func main() {
	jsonOut := flag.Bool("json", false, "print a JSON report and exit")
	ver := flag.Bool("version", false, "print version")
	timeout := flag.Duration("timeout", 0, "stop scanning after this long (results become partial)")
	flag.Parse()
	if *ver {
		fmt.Println("vole-analyze", version)
		return
	}
	target := ""
	if flag.NArg() > 0 {
		t, err := filepath.Abs(flag.Arg(0))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if fi, err := os.Stat(t); err != nil || !fi.IsDir() {
			fmt.Fprintf(os.Stderr, "vole-analyze: %s is not a readable directory\n", t)
			os.Exit(1)
		}
		target = t
	}
	if *jsonOut {
		s := NewScanner()
		if *timeout > 0 {
			s.Deadline = time.Now().Add(*timeout)
		}
		var r Result
		if target == "" {
			r = s.Overview()
		} else {
			r = s.ScanDir(target)
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(r); err != nil {
			os.Exit(1)
		}
		return
	}
	m := newModel(target)
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------- model

type view struct {
	res    Result
	cursor int
	top    int
}

type scanDoneMsg struct {
	path string
	res  Result
}
type tickMsg struct{}

type model struct {
	stack     []view
	cache     map[string]Result
	scanning  string
	scanner   *Scanner
	filter    string
	filtering bool
	selected  map[string]bool
	confirm   bool
	showLarge bool
	msg       string
	width     int
	height    int
	start     string
	spin      int
}

func newModel(start string) model {
	return model{cache: map[string]Result{}, selected: map[string]bool{}, start: start, width: 100, height: 30}
}

func (m model) scan(path string) tea.Cmd {
	s := m.scanner
	return func() tea.Msg {
		if path == "" {
			return scanDoneMsg{path, s.Overview()}
		}
		return scanDoneMsg{path, s.ScanDir(path)}
	}
}

func tick() tea.Cmd {
	return tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m model) Init() tea.Cmd { return nil }

func (m *model) beginScan(path string) tea.Cmd {
	if r, ok := m.cache[path]; ok {
		m.stack = append(m.stack, view{res: r})
		return nil
	}
	m.scanner = NewScanner()
	m.scanning = path
	if path == "" {
		m.scanning = "overview"
	}
	return tea.Batch(m.scan(path), tick())
}

func (m model) cur() *view {
	if len(m.stack) == 0 {
		return nil
	}
	return &m.stack[len(m.stack)-1]
}

func (m model) visible() []Entry {
	v := m.cur()
	if v == nil {
		return nil
	}
	var out []Entry
	for _, e := range v.res.Entries {
		if m.filter != "" && !strings.Contains(strings.ToLower(e.Name), strings.ToLower(m.filter)) {
			continue
		}
		out = append(out, e)
		if len(out) >= 30 && m.filter == "" {
			break
		}
	}
	return out
}

func (m model) listRows() int {
	r := m.height - 8
	if r < 5 {
		r = 5
	}
	return r
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		if len(m.stack) == 0 && m.scanning == "" {
			return m, m.beginScanVal(m.start)
		}
	case tickMsg:
		if m.scanning != "" {
			m.spin++
			return m, tick()
		}
	case scanDoneMsg:
		m.cache[msg.path] = msg.res
		m.scanning = ""
		m.stack = append(m.stack, view{res: msg.res})
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func (m *model) beginScanVal(p string) tea.Cmd { return m.beginScan(p) }

func (m model) key(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	s := k.String()
	if m.filtering {
		switch s {
		case "enter", "esc":
			m.filtering = false
			if s == "esc" {
				m.filter = ""
			}
		case "backspace":
			if len(m.filter) > 0 {
				m.filter = m.filter[:len(m.filter)-1]
			}
		default:
			if len(k.Runes) > 0 {
				m.filter += string(k.Runes)
			}
		}
		if v := m.cur(); v != nil {
			v.cursor, v.top = 0, 0
		}
		return m, nil
	}
	if m.confirm {
		m.confirm = false
		if s == "y" || s == "Y" {
			return m.trashSelected()
		}
		m.msg = "Cancelled."
		return m, nil
	}
	if s == "q" || s == "ctrl+c" {
		return m, tea.Quit
	}
	if m.scanning != "" {
		return m, nil
	}
	v := m.cur()
	if v == nil {
		return m, nil
	}
	items := m.visible()
	m.msg = ""
	switch s {
	case "up", "k":
		if v.cursor > 0 {
			v.cursor--
		}
	case "down", "j":
		if v.cursor < len(items)-1 {
			v.cursor++
		}
	case "pgup", "ctrl+u":
		v.cursor -= m.listRows()
		if v.cursor < 0 {
			v.cursor = 0
		}
	case "pgdown", "ctrl+d":
		v.cursor += m.listRows()
		if v.cursor > len(items)-1 {
			v.cursor = len(items) - 1
		}
	case "g", "home":
		v.cursor = 0
	case "G", "end":
		v.cursor = len(items) - 1
	case "enter", "l", "right":
		if m.showLarge || v.cursor >= len(items) {
			return m, nil
		}
		e := items[v.cursor]
		if !e.IsDir {
			return m, nil
		}
		m.filter = ""
		if e.Old {
			return m, m.beginScanVal(e.Path)
		}
		return m, m.beginScanVal(e.Path)
	case "h", "left", "backspace", "esc":
		if m.showLarge {
			m.showLarge = false
		} else if len(m.stack) > 1 {
			m.stack = m.stack[:len(m.stack)-1]
			m.filter = ""
		}
	case "/":
		m.filtering = true
		m.filter = ""
	case " ":
		if v.cursor < len(items) && !v.res.Overview {
			p := items[v.cursor].Path
			if m.selected[p] {
				delete(m.selected, p)
			} else {
				m.selected[p] = true
			}
			if v.cursor < len(items)-1 {
				v.cursor++
			}
		}
	case "f":
		m.showLarge = !m.showLarge
	case "d", "delete":
		if v.res.Overview && len(m.selected) == 0 {
			m.msg = "Open a location first; overview entries can't be trashed."
			return m, nil
		}
		if len(m.selected) == 0 && v.cursor < len(items) {
			m.selected[items[v.cursor].Path] = true
		}
		if len(m.selected) > 0 {
			m.confirm = true
		}
	case "o":
		if v.cursor < len(items) {
			p := items[v.cursor].Path
			if !items[v.cursor].IsDir {
				p = filepath.Dir(p)
			}
			_ = exec.Command("xdg-open", p).Start()
			m.msg = "Opened " + p
		}
	case "r":
		path := v.res.Path
		if v.res.Overview {
			path = ""
		}
		delete(m.cache, path)
		m.stack = m.stack[:len(m.stack)-1]
		return m, m.beginScanVal(path)
	}
	// keep cursor visible
	rows := m.listRows()
	if v.cursor < v.top {
		v.top = v.cursor
	}
	if v.cursor >= v.top+rows {
		v.top = v.cursor - rows + 1
	}
	return m, nil
}

func (m model) trashSelected() (tea.Model, tea.Cmd) {
	var paths []string
	for p := range m.selected {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	var errs []string
	n := 0
	var freed int64
	sizes := map[string]int64{}
	for _, v := range m.stack {
		for _, e := range v.res.Entries {
			sizes[e.Path] = e.Size
		}
	}
	for _, p := range paths {
		if err := moveToTrash(p); err != nil {
			errs = append(errs, err.Error())
			continue
		}
		n++
		freed += sizes[p]
	}
	m.selected = map[string]bool{}
	// drop cached results for every ancestor so sizes refresh
	for k := range m.cache {
		for _, p := range paths {
			if k == "" || strings.HasPrefix(p, k+"/") {
				delete(m.cache, k)
			}
		}
	}
	// remove trashed entries from the views on the stack
	for i := range m.stack {
		var keep []Entry
		for _, e := range m.stack[i].res.Entries {
			gone := false
			for _, p := range paths {
				if e.Path == p {
					gone = true
				}
			}
			if !gone {
				keep = append(keep, e)
			}
		}
		m.stack[i].res.Entries = keep
		if c := m.stack[i].cursor; c >= len(keep) && c > 0 {
			m.stack[i].cursor = len(keep) - 1
		}
	}
	m.msg = fmt.Sprintf("Moved %d item(s) to Trash, %s", n, units.Human(freed))
	if len(errs) > 0 {
		m.msg += " · " + errs[0]
	}
	return m, nil
}

// ---------------------------------------------------------------- view

var (
	sBold  = lipgloss.NewStyle().Bold(true)
	sDim   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	sCyan  = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	sGreen = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	sYel   = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	sRed   = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	sSel   = lipgloss.NewStyle().Foreground(lipgloss.Color("6")).Bold(true)
)

var spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

func (m model) View() string {
	home, _ := os.UserHomeDir()
	if m.scanning != "" {
		files, bytes := int64(0), int64(0)
		if m.scanner != nil {
			files, bytes = m.scanner.Files.Load(), m.scanner.Bytes.Load()
		}
		return fmt.Sprintf("\n  %s Scanning %s…\n\n  %s files · %s\n\n  %s",
			sCyan.Render(spinner[m.spin%len(spinner)]), strings.Replace(m.scanning, home, "~", 1),
			commas(files), units.Human(bytes), sDim.Render("q quit"))
	}
	v := m.cur()
	if v == nil {
		return ""
	}
	var b strings.Builder
	path := strings.Replace(v.res.Path, home, "~", 1)
	if v.res.Overview {
		fmt.Fprintf(&b, "%s  %s\n%s\n\n", sBold.Render("Analyze Disk"), sDim.Render("("+units.Human(freeSpace("/"))+" free)"), "Select a location to explore:")
	} else {
		st := ""
		if v.res.Status != statusComplete {
			st = sYel.Render("  partial")
		}
		fmt.Fprintf(&b, "%s  %s  %s%s\n%s\n\n", sBold.Render("Analyze"), sCyan.Render(path),
			sDim.Render(units.Human(v.res.TotalSize)+" · "+commas(v.res.TotalFiles)+" files · "+units.Human(freeSpace(v.res.Path))+" free"), st,
			sDim.Render(breadcrumbs(m.stack, home)))
	}
	if m.showLarge {
		b.WriteString(sBold.Render("Largest files found so far") + "\n\n")
		lf := v.res.LargeFiles
		if len(lf) == 0 {
			b.WriteString(sDim.Render("  No files over 50MB.") + "\n")
		}
		for _, f := range lf {
			fmt.Fprintf(&b, "  %9s  %s\n", units.Human(f.Size), units.Truncate(strings.Replace(f.Path, home, "~", 1), m.width-16))
		}
		b.WriteString("\n" + sDim.Render("f/← back · q quit"))
		return b.String()
	}
	items := m.visible()
	total := v.res.TotalSize
	if total <= 0 {
		for _, e := range items {
			total += e.Size
		}
	}
	nameW := m.width - 66
	if nameW < 16 {
		nameW = 16
	}
	rows := m.listRows()
	now := time.Now()
	for i := v.top; i < len(items) && i < v.top+rows; i++ {
		e := items[i]
		p := 0.0
		if total > 0 {
			p = float64(e.Size) / float64(total) * 100
		}
		barStyle := sGreen
		if p > 40 {
			barStyle = sRed
		} else if p > 15 {
			barStyle = sYel
		}
		cursor := "   "
		if i == v.cursor {
			cursor = sSel.Render(" ▶ ")
		}
		mark := " "
		if m.selected[e.Path] {
			mark = sGreen.Render("●")
		}
		name := e.Name
		if e.IsDir && !v.res.Overview {
			name += "/"
		}
		size := units.Human(e.Size)
		switch e.Status {
		case statusPartial:
			size += "+"
		case statusUnavailable:
			if e.Size == 0 {
				size = "unknown"
			}
		}
		age := ""
		if e.ModTime > 0 && !v.res.Overview {
			if d := now.Sub(time.Unix(e.ModTime, 0)); d > 90*24*time.Hour {
				age = sDim.Render(fmt.Sprintf(" >%dmo", int(d.Hours()/24/30)))
			}
		}
		if e.Old {
			age = sDim.Render(" >3mo")
		}
		line := fmt.Sprintf("%s%s%3d. %s %5.1f%%  |  %-*s %9s%s",
			cursor, mark, i+1, barStyle.Render(units.Bar(p, 24, "█", " ")), p, nameW, units.Truncate(name, nameW), size, age)
		if i == v.cursor {
			line = sBold.Render(line)
		}
		b.WriteString(line + "\n")
	}
	if len(items) == 0 {
		b.WriteString(sDim.Render("   (empty)") + "\n")
	}
	b.WriteString("\n")
	if m.filtering || m.filter != "" {
		b.WriteString(sCyan.Render("/"+m.filter) + "\n")
	}
	if m.confirm {
		var sz int64
		for _, e := range v.res.Entries {
			if m.selected[e.Path] {
				sz += e.Size
			}
		}
		b.WriteString(sYel.Render(fmt.Sprintf("Move %d item(s), %s, to Trash? [y/N]", len(m.selected), units.Human(sz))) + "\n")
	} else if m.msg != "" {
		b.WriteString(m.msg + "\n")
	}
	help := "↑↓/jk move · Enter open · ← back · / filter · Space select · d trash · f large files · o open · r rescan · q quit"
	if len(m.selected) > 0 {
		help = fmt.Sprintf("%d selected · ", len(m.selected)) + help
	}
	b.WriteString(sDim.Render(units.Truncate(help, m.width)))
	return b.String()
}

func breadcrumbs(st []view, home string) string {
	var parts []string
	for _, v := range st {
		if v.res.Overview {
			parts = append(parts, "Overview")
		} else {
			parts = append(parts, filepath.Base(v.res.Path))
		}
	}
	return strings.Join(parts, " › ")
}

func commas(n int64) string {
	s := fmt.Sprintf("%d", n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}
