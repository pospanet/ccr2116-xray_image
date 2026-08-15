package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
)

const (
	defaultXray      = "/usr/local/bin/xray"
	maxConfigBytes   = 1 << 20
	maxJSONDepth     = 64
	maxParameterName = 128
)

var parameterName = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_.-]{0,127}$`)

type options struct {
	mode, config, template, values, envVar string
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "xray-entry:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		args = []string{"run"}
	}
	command := args[0]
	if command == "version" || command == "uuid" {
		if len(args) != 1 {
			return errors.New("unexpected arguments")
		}
		return forward(command)
	}
	if command != "run" && command != "test" {
		return errors.New("command must be run, test, version, or uuid")
	}
	opts, err := parseOptions(args[1:])
	if err != nil {
		return err
	}
	if opts.mode == "file" {
		if err := safeRegularFile(opts.config); err != nil {
			return fmt.Errorf("file mode config %q: %w", opts.config, err)
		}
		if _, err := readJSONFile(opts.config); err != nil {
			return fmt.Errorf("file mode config %q: invalid JSON", opts.config)
		}
		if err := validatePath(opts.config); err != nil {
			return err
		}
		if command == "test" {
			return nil
		}
		return execXray([]string{defaultXray, "run", "-format", "json", "-config", opts.config})
	}

	data, err := generatedConfig(opts)
	if err != nil {
		return err
	}
	f, err := anonymousTemp(data)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := validateStdin(f); err != nil {
		return err
	}
	if command == "test" {
		return nil
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return errors.New("rewind generated configuration")
	}
	return execXrayWithStdin(f, []string{defaultXray, "run", "-format", "json"})
}

func parseOptions(args []string) (options, error) {
	o := options{mode: "file", config: "/etc/xray/config.json", template: "/etc/xray/config.template.json", values: "/etc/xray/values.json", envVar: "XRAY_CONFIG_BASE64"}
	fs := flag.NewFlagSet("xray-entry", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.mode, "mode", o.mode, "configuration mode")
	fs.StringVar(&o.config, "config", o.config, "configuration path")
	fs.StringVar(&o.template, "template", o.template, "template path")
	fs.StringVar(&o.values, "values", o.values, "values path")
	fs.StringVar(&o.envVar, "env-var", o.envVar, "base64 environment variable")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return options{}, errors.New("invalid command options")
	}
	if o.mode != "file" && o.mode != "template" && o.mode != "env-base64" {
		return options{}, errors.New("mode must be file, template, or env-base64")
	}
	if o.envVar == "" {
		return options{}, errors.New("environment variable name is required")
	}
	return o, nil
}

func forward(command string) error {
	c := exec.Command(defaultXray, command)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	c.Env = xrayEnvironment()
	if err := c.Run(); err != nil {
		return fmt.Errorf("xray %s failed", command)
	}
	return nil
}

func validatePath(path string) error {
	c := exec.Command(defaultXray, "run", "-format", "json", "-test", "-config", path)
	c.Env = xrayEnvironment()
	if err := c.Run(); err != nil {
		return errors.New("file mode validation failed")
	}
	return nil
}

func validateStdin(f *os.File) error {
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return errors.New("rewind generated configuration for validation")
	}
	c := exec.Command(defaultXray, "run", "-format", "json", "-test")
	c.Stdin = f
	c.Env = xrayEnvironment()
	if err := c.Run(); err != nil {
		return errors.New("generated configuration validation failed")
	}
	return nil
}

func xrayEnvironment() []string {
	env := make([]string, 0, len(os.Environ())+1)
	for _, entry := range os.Environ() {
		if len(entry) >= len("XRAY_LOCATION_ASSET=") && entry[:len("XRAY_LOCATION_ASSET=")] == "XRAY_LOCATION_ASSET=" {
			continue
		}
		env = append(env, entry)
	}
	return append(env, "XRAY_LOCATION_ASSET=/usr/local/share/xray")
}

func generatedConfig(o options) ([]byte, error) {
	switch o.mode {
	case "template":
		template, err := readJSONFile(o.template)
		if err != nil {
			return nil, fmt.Errorf("template mode template %q: %w", o.template, err)
		}
		values, err := readJSONFile(o.values)
		if err != nil {
			return nil, fmt.Errorf("template mode values %q: %w", o.values, err)
		}
		object, ok := values.(map[string]any)
		if !ok {
			return nil, errors.New("template mode values must be a JSON object")
		}
		rendered, err := renderTemplate(template, object)
		if err != nil {
			return nil, fmt.Errorf("template mode: %w", err)
		}
		encoded, err := json.Marshal(rendered)
		if err != nil || len(encoded) > maxConfigBytes {
			return nil, errors.New("template mode rendered configuration exceeds size limit")
		}
		return encoded, nil
	case "env-base64":
		encoded, ok := os.LookupEnv(o.envVar)
		if !ok || encoded == "" {
			return nil, fmt.Errorf("env-base64 mode environment variable %q is required", o.envVar)
		}
		if len(encoded) > base64.StdEncoding.EncodedLen(maxConfigBytes) {
			return nil, errors.New("env-base64 mode configuration exceeds size limit")
		}
		decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
		if err != nil || len(decoded) > maxConfigBytes {
			return nil, errors.New("env-base64 mode contains malformed or oversize data")
		}
		if _, err := parseJSON(decoded); err != nil {
			return nil, errors.New("env-base64 mode contains invalid JSON")
		}
		return decoded, nil
	default:
		return nil, errors.New("unsupported generated configuration mode")
	}
}

func readJSONFile(path string) (any, error) {
	if err := safeRegularFile(path); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		return nil, errors.New("read failed")
	}
	return parseJSON(b)
}

func safeRegularFile(path string) error {
	info, err := os.Lstat(filepath.Clean(path))
	if err != nil {
		return errors.New("cannot inspect source")
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("source must be a regular file")
	}
	if info.Mode().Perm()&0o022 != 0 {
		return errors.New("source must not be writable by group or others")
	}
	if info.Size() > maxConfigBytes {
		return errors.New("source exceeds size limit")
	}
	return nil
}

func anonymousTemp(data []byte) (*os.File, error) {
	f, err := os.CreateTemp("/tmp", "xray-entry-")
	if err != nil {
		return nil, errors.New("create generated configuration")
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return nil, errors.New("restrict generated configuration permissions")
	}
	if err := os.Remove(f.Name()); err != nil {
		f.Close()
		return nil, errors.New("unlink generated configuration")
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return nil, errors.New("write generated configuration")
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		f.Close()
		return nil, errors.New("rewind generated configuration")
	}
	return f, nil
}
