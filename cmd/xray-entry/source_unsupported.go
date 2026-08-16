//go:build !linux

package main

import (
	"errors"
	"os"
)

func openSource(path string) (*os.File, error) {
	return nil, errors.New("secure source inspection is supported only on linux")
}

func validateOpenSource(f *os.File) error {
	return errors.New("secure source inspection is supported only on linux")
}
