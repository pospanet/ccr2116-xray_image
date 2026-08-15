package main

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const maxExtractedFileBytes = 128 << 20

var allowedFiles = map[string]os.FileMode{
	"xray":        0o555,
	"geoip.dat":   0o444,
	"geosite.dat": 0o444,
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: xray-extract ARCHIVE OUTPUT_DIRECTORY")
		os.Exit(2)
	}
	if err := extract(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "xray-extract:", err)
		os.Exit(1)
	}
}

func extract(archivePath, outputDirectory string) error {
	archive, err := zip.OpenReader(archivePath)
	if err != nil {
		return errors.New("open verified archive")
	}
	defer archive.Close()
	if err := os.MkdirAll(outputDirectory, 0o700); err != nil {
		return errors.New("create extraction directory")
	}
	found := make(map[string]bool, len(allowedFiles))
	for _, entry := range archive.File {
		mode, allowed := allowedFiles[entry.Name]
		if !allowed {
			continue
		}
		if found[entry.Name] {
			return fmt.Errorf("duplicate allowlisted entry %q", entry.Name)
		}
		if !entry.FileInfo().Mode().IsRegular() || entry.UncompressedSize64 > maxExtractedFileBytes {
			return fmt.Errorf("unsafe allowlisted entry %q", entry.Name)
		}
		if err := extractFile(entry, filepath.Join(outputDirectory, entry.Name), mode); err != nil {
			return err
		}
		found[entry.Name] = true
	}
	for name := range allowedFiles {
		if !found[name] {
			return fmt.Errorf("missing allowlisted entry %q", name)
		}
	}
	return nil
}

func extractFile(entry *zip.File, destination string, mode os.FileMode) error {
	source, err := entry.Open()
	if err != nil {
		return fmt.Errorf("open allowlisted entry %q", entry.Name)
	}
	defer source.Close()
	target, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return fmt.Errorf("create allowlisted entry %q", entry.Name)
	}
	written, copyErr := io.Copy(target, io.LimitReader(source, maxExtractedFileBytes+1))
	closeErr := target.Close()
	if copyErr != nil || closeErr != nil || written != int64(entry.UncompressedSize64) || written > maxExtractedFileBytes {
		return fmt.Errorf("extract allowlisted entry %q", entry.Name)
	}
	return nil
}
