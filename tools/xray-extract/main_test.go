package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestExtractAllowlist(t *testing.T) {
	archive := makeArchive(t, []archiveEntry{
		{name: "xray", body: "binary"},
		{name: "geoip.dat", body: "geoip"},
		{name: "geosite.dat", body: "geosite"},
		{name: "README.md", body: "ignored"},
	})
	output := filepath.Join(t.TempDir(), "output")
	if err := extract(archive, output); err != nil {
		t.Fatal(err)
	}
	for name, mode := range allowedFiles {
		info, err := os.Stat(filepath.Join(output, name))
		if err != nil {
			t.Fatal(err)
		}
		if runtime.GOOS == "linux" && info.Mode().Perm() != mode {
			t.Fatalf("%s mode is %o, want %o", name, info.Mode().Perm(), mode)
		}
	}
	if _, err := os.Stat(filepath.Join(output, "README.md")); !os.IsNotExist(err) {
		t.Fatal("non-allowlisted entry was extracted")
	}
}

func TestExtractRejectsMissingAndDuplicateEntries(t *testing.T) {
	cases := [][]archiveEntry{
		{{name: "xray", body: "binary"}},
		{
			{name: "xray", body: "one"},
			{name: "xray", body: "two"},
			{name: "geoip.dat", body: "geoip"},
			{name: "geosite.dat", body: "geosite"},
		},
	}
	for _, entries := range cases {
		if err := extract(makeArchive(t, entries), filepath.Join(t.TempDir(), "output")); err == nil {
			t.Fatal("unsafe archive unexpectedly succeeded")
		}
	}
}

type archiveEntry struct {
	name string
	body string
}

func makeArchive(t *testing.T, entries []archiveEntry) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "archive.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	for _, entry := range entries {
		header := &zip.FileHeader{Name: entry.name, Method: zip.Store}
		header.SetMode(0o644)
		part, err := w.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write([]byte(entry.body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}
