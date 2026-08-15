//go:build linux

package main

import (
	"io"
	"os"
	"testing"
)

func TestAnonymousTempIsUnlinkedAndPrivate(t *testing.T) {
	f, err := anonymousTemp([]byte(`{"outbounds":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := os.Stat(f.Name()); !os.IsNotExist(err) {
		t.Fatalf("temporary pathname still exists: %v", err)
	}
	info, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode is %o, want 0600", info.Mode().Perm())
	}
	b, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"outbounds":[]}` {
		t.Fatalf("unexpected bytes %q", b)
	}
}
