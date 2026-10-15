// Package units holds small formatting helpers shared by the Go tools.
package units

import (
	"fmt"
	"strings"
)

// Human formats a byte count as 1.2GB.
func Human(b int64) string {
	if b < 0 {
		b = 0
	}
	u := []string{"B", "KB", "MB", "GB", "TB", "PB"}
	f := float64(b)
	i := 0
	for f >= 1024 && i < len(u)-1 {
		f /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%dB", b)
	}
	return fmt.Sprintf("%.1f%s", f, u[i])
}

// Bar renders a horizontal bar of width w filled to pct (0-100).
func Bar(pct float64, w int, full, empty string) string {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	n := int(pct/100*float64(w) + 0.5)
	return strings.Repeat(full, n) + strings.Repeat(empty, w-n)
}

var sparks = []rune("▁▂▃▄▅▆▇█")

// Spark renders values as a sparkline.
func Spark(vals []float64) string {
	max := 0.0
	for _, v := range vals {
		if v > max {
			max = v
		}
	}
	var sb strings.Builder
	for _, v := range vals {
		i := 0
		if max > 0 {
			i = int(v / max * float64(len(sparks)-1))
		}
		sb.WriteRune(sparks[i])
	}
	return sb.String()
}

// Truncate shortens s to n runes with an ellipsis.
func Truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return string(r[:n])
	}
	return string(r[:n-1]) + "…"
}
