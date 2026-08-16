//go:build !linux

package main

import (
	"errors"
	"os"
)

func execXrayWithStdin(f *os.File, args []string) error {
	return errors.New("xray-entry runtime is supported only on linux")
}
