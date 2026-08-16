//go:build linux

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

func openSource(path string) (*os.File, error) {
	clean := filepath.Clean(path)
	before, err := os.Lstat(clean)
	if err != nil {
		return nil, errors.New("cannot inspect source")
	}
	if err := validateSourceInfo(before); err != nil {
		return nil, err
	}
	return openSourceAfterLstat(clean, before)
}

func openSourceAfterLstat(path string, before os.FileInfo) (*os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, errors.New("source changed or could not be opened safely")
	}
	f := os.NewFile(uintptr(fd), path)
	if f == nil {
		_ = syscall.Close(fd)
		return nil, errors.New("read failed")
	}
	failed := true
	defer func() {
		if failed {
			_ = f.Close()
		}
	}()

	after, err := f.Stat()
	if err != nil || !os.SameFile(before, after) {
		return nil, errors.New("source changed while opening")
	}
	if err := validateSourceInfo(after); err != nil {
		return nil, err
	}
	if err := validateSourceNotWritable(f); err != nil {
		return nil, err
	}
	current, err := os.Lstat(path)
	if err != nil || !current.Mode().IsRegular() || !os.SameFile(after, current) {
		return nil, errors.New("source changed while opening")
	}
	if err := validateSourceInfo(current); err != nil {
		return nil, err
	}

	failed = false
	return f, nil
}

func validateOpenSource(f *os.File) error {
	info, err := f.Stat()
	if err != nil {
		return errors.New("cannot inspect open source")
	}
	if err := validateSourceInfo(info); err != nil {
		return err
	}
	return validateSourceNotWritable(f)
}

func validateSourceNotWritable(f *os.File) error {
	if f == nil {
		return errors.New("cannot determine source writeability")
	}
	// Reopen the already verified file object through its procfs descriptor.
	// O_WRONLY alone neither creates nor truncates a file, and no write is
	// issued. Following this process-owned magic link avoids another lookup of
	// the caller-controlled source path while preserving the descriptor's mount.
	probePath := "/proc/self/fd/" + strconv.FormatUint(uint64(f.Fd()), 10)
	probe, err := os.OpenFile(probePath, os.O_WRONLY, 0)
	if err == nil {
		_ = probe.Close()
		return errors.New("source is writable by the runtime user")
	}
	if errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EROFS) {
		return nil
	}
	return errors.New("cannot determine source writeability")
}
