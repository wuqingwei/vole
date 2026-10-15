package main

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// moveToTrash follows the freedesktop.org Trash spec for the home trash.
// Items on another filesystem go through `gio trash` when available.
func moveToTrash(p string) error {
	abs, err := filepath.Abs(p)
	if err != nil {
		return err
	}
	if isProtected(abs) {
		return fmt.Errorf("refusing to trash protected path %s", abs)
	}
	home, _ := os.UserHomeDir()
	dataHome := os.Getenv("XDG_DATA_HOME")
	if dataHome == "" {
		dataHome = filepath.Join(home, ".local", "share")
	}
	trash := filepath.Join(dataHome, "Trash")
	if err := os.MkdirAll(filepath.Join(trash, "files"), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(trash, "info"), 0o700); err != nil {
		return err
	}
	var a, b syscall.Stat_t
	if syscall.Lstat(abs, &a) != nil {
		return fmt.Errorf("%s no longer exists", abs)
	}
	_ = syscall.Stat(trash, &b)
	if a.Dev != b.Dev {
		if g, err := exec.LookPath("gio"); err == nil {
			return exec.Command(g, "trash", abs).Run()
		}
		return fmt.Errorf("%s is on another filesystem and gio is not installed", abs)
	}
	base := filepath.Base(abs)
	name := base
	for i := 1; ; i++ {
		f, err := os.OpenFile(filepath.Join(trash, "info", name+".trashinfo"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			u := (&url.URL{Path: abs}).EscapedPath()
			fmt.Fprintf(f, "[Trash Info]\nPath=%s\nDeletionDate=%s\n", u, time.Now().Format("2006-01-02T15:04:05"))
			f.Close()
			break
		}
		if !os.IsExist(err) {
			return err
		}
		ext := filepath.Ext(base)
		name = fmt.Sprintf("%s.%d%s", strings.TrimSuffix(base, ext), i, ext)
	}
	if err := os.Rename(abs, filepath.Join(trash, "files", name)); err != nil {
		os.Remove(filepath.Join(trash, "info", name+".trashinfo"))
		return err
	}
	logOp(abs)
	return nil
}

func isProtected(p string) bool {
	home, _ := os.UserHomeDir()
	p = filepath.Clean(p)
	protected := []string{"/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/var", home,
		filepath.Join(home, ".config"), filepath.Join(home, ".local"), filepath.Join(home, ".local/share"), filepath.Join(home, ".ssh"), filepath.Join(home, ".gnupg")}
	for _, x := range protected {
		if p == x {
			return true
		}
	}
	return strings.HasPrefix(p, filepath.Join(home, ".ssh")+"/") || strings.HasPrefix(p, filepath.Join(home, ".gnupg")+"/") ||
		strings.Count(p, "/") < 2
}

func logOp(p string) {
	if os.Getenv("VOLE_NO_OPLOG") == "1" {
		return
	}
	d := os.Getenv("XDG_STATE_HOME")
	if d == "" {
		home, _ := os.UserHomeDir()
		d = filepath.Join(home, ".local", "state")
	}
	d = filepath.Join(d, "vole")
	_ = os.MkdirAll(d, 0o755)
	f, err := os.OpenFile(filepath.Join(d, "operations.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s\tanalyze-%d\tanalyze\ttrash\t0\t%s\n", time.Now().UTC().Format("2006-01-02T15:04:05Z"), os.Getpid(), p)
}
