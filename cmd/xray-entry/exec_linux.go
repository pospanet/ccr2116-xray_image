//go:build linux

package main

import (
	"errors"
	"os"
	"syscall"
)

func execXrayWithStdin(f *os.File, args []string) error {
	sourceFD := int(f.Fd())
	duplicate := -1
	if sourceFD == 0 {
		var err error
		duplicate, err = syscall.Dup(sourceFD)
		if err != nil {
			return errors.New("connect configuration to standard input")
		}
		sourceFD = duplicate
	}
	if err := syscall.Dup3(sourceFD, 0, 0); err != nil {
		if duplicate >= 0 {
			_ = syscall.Close(duplicate)
		}
		return errors.New("connect configuration to standard input")
	}
	if duplicate >= 0 {
		if err := syscall.Close(duplicate); err != nil {
			return errors.New("close duplicated configuration descriptor")
		}
	}
	return syscall.Exec(defaultXray, args, xrayEnvironment())
}
