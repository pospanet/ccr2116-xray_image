//go:build linux

package main

import (
	"errors"
	"os"
	"syscall"
)

func execXray(args []string) error {
	return syscall.Exec(defaultXray, args, xrayEnvironment())
}

func execXrayWithStdin(f *os.File, args []string) error {
	if int(f.Fd()) != 0 {
		if err := syscall.Dup3(int(f.Fd()), 0, 0); err != nil {
			return errors.New("connect generated configuration to standard input")
		}
	}
	return syscall.Exec(defaultXray, args, xrayEnvironment())
}
