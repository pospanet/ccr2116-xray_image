//go:build linux

package main

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

var validSource = []byte(`{"outbounds":[]}`)

func writeSource(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, validSource, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func TestReadJSONFileAcceptsNonWritableRegularFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can open an owner-read-only file for writing; the actual-image read-only-mount regression covers this case")
	}
	path := filepath.Join(t.TempDir(), "read-only.json")
	writeSource(t, path, 0o400)
	if _, err := readJSONFile(path); err != nil {
		t.Fatalf("non-writable regular source failed: %v", err)
	}
}

func TestReadJSONFileRejectsOwnerWritableSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "owner-writable.json")
	writeSource(t, path, 0o600)
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	if _, err := readJSONFile(path); err == nil || !strings.Contains(err.Error(), "writable by the runtime user") {
		t.Fatalf("owner-writable source error = %v, want runtime-writeability rejection", err)
	}

	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, validSource) {
		t.Fatal("writeability probe changed source contents")
	}
	if before.Size() != after.Size() || before.Mode() != after.Mode() || !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("writeability probe changed source metadata")
	}
}

func TestReadJSONFileRejectsGroupOrOtherWritableSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "group-other-writable.json")
	writeSource(t, path, 0o666)
	if _, err := readJSONFile(path); err == nil {
		t.Fatal("group/other-writable source unexpectedly succeeded")
	}
}

func TestReadJSONFileRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	regular := filepath.Join(dir, "regular.json")
	writeSource(t, regular, 0o400)
	symlink := filepath.Join(dir, "symlink.json")
	if err := os.Symlink(regular, symlink); err != nil {
		t.Fatal(err)
	}
	if _, err := readJSONFile(symlink); err == nil {
		t.Fatal("symlink source unexpectedly succeeded")
	}
}

func TestReadJSONFileRejectsNonRegularSources(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "config.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "config.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	sources := []string{dir, fifo, socket}
	if _, err := os.Lstat("/dev/null"); err == nil {
		sources = append(sources, "/dev/null")
	}
	for _, source := range sources {
		t.Run(filepath.Base(source), func(t *testing.T) {
			if _, err := readJSONFile(source); err == nil {
				t.Fatalf("non-regular source %q unexpectedly succeeded", source)
			}
		})
	}
}

func TestReadJSONFileRejectsOversizeSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oversize.json")
	if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, maxConfigBytes+1), 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := readJSONFile(path); err == nil || !strings.Contains(err.Error(), "size limit") {
		t.Fatalf("oversize source error = %v, want size-limit rejection", err)
	}
}

func TestOpenSourceRejectsReplacementAfterInspection(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	replacement := filepath.Join(dir, "replacement.json")
	writeSource(t, path, 0o400)
	writeSource(t, replacement, 0o400)
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, path); err != nil {
		t.Fatal(err)
	}
	f, err := openSourceAfterLstat(path, before)
	if f != nil {
		_ = f.Close()
	}
	if err == nil {
		t.Fatal("source replacement after inspection unexpectedly succeeded")
	}
}

func TestOpenSourceRejectsSymlinkReplacementToSameFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	held := filepath.Join(dir, "held.json")
	writeSource(t, path, 0o400)
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path, held); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(held, path); err != nil {
		t.Fatal(err)
	}
	f, err := openSourceAfterLstat(path, before)
	if f != nil {
		_ = f.Close()
	}
	if err == nil {
		t.Fatal("symlink replacement to the inspected file unexpectedly succeeded")
	}
}

func TestWriteabilityProbeFailsClosedOnUnexpectedError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	writeSource(t, path, 0o400)
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	if err := validateSourceNotWritable(f); err == nil || !strings.Contains(err.Error(), "cannot determine") {
		t.Fatalf("closed-descriptor probe error = %v, want fail-closed result", err)
	}
}

func TestAnonymousTempRejectsEmptyInput(t *testing.T) {
	if _, err := anonymousTemp(nil); err == nil {
		t.Fatal("empty generated configuration unexpectedly succeeded")
	}
}
