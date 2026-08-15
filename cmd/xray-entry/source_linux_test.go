//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadJSONFileRejectsUnsafeSources(t *testing.T) {
	dir := t.TempDir()
	writable := filepath.Join(dir, "writable.json")
	if err := os.WriteFile(writable, []byte(`{"outbounds":[]}`), 0o666); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(writable, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := readJSONFile(writable); err == nil {
		t.Fatal("group-writable source unexpectedly succeeded")
	}

	regular := filepath.Join(dir, "regular.json")
	if err := os.WriteFile(regular, []byte(`{"outbounds":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(dir, "symlink.json")
	if err := os.Symlink(regular, symlink); err != nil {
		t.Fatal(err)
	}
	if _, err := readJSONFile(symlink); err == nil {
		t.Fatal("symlink source unexpectedly succeeded")
	}
}

func TestAnonymousTempRejectsEmptyInput(t *testing.T) {
	if _, err := anonymousTemp(nil); err == nil {
		t.Fatal("empty generated configuration unexpectedly succeeded")
	}
}
