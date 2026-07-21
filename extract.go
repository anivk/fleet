package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"os"
	"path/filepath"
)

// extractScripts writes the embedded fleet runtime to a per-content cache dir and
// returns its path (which becomes FLEET_HOME). It re-extracts only when the embedded
// content changes (the dir is named by a hash of it), so upgrades are automatic and
// steady-state runs are a cheap stat.
func extractScripts() (string, error) {
	sum := contentHash()
	base, err := os.UserCacheDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	dir := filepath.Join(base, "fleet", sum)
	marker := filepath.Join(dir, ".extracted")
	if _, err := os.Stat(marker); err == nil {
		return dir, nil
	}
	err = fs.WalkDir(scriptFS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		dst := filepath.Join(dir, p)
		if d.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}
		b, err := scriptFS.ReadFile(p)
		if err != nil {
			return err
		}
		mode := fs.FileMode(0o644)
		if filepath.Ext(p) == ".sh" {
			mode = 0o755
		}
		return os.WriteFile(dst, b, mode)
	})
	if err != nil {
		return "", err
	}
	_ = os.WriteFile(marker, []byte(sum), 0o644)
	return dir, nil
}

// contentHash is a short, stable digest of every embedded file (path + bytes), so a
// changed binary lands in a fresh cache dir.
func contentHash() string {
	h := sha256.New()
	_ = fs.WalkDir(scriptFS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		b, _ := scriptFS.ReadFile(p)
		h.Write([]byte(p))
		h.Write(b)
		return nil
	})
	return hex.EncodeToString(h.Sum(nil))[:16]
}
