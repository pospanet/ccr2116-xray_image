package main

import (
	"encoding/base64"
	"os"
	"testing"
)

func TestParseOptions(t *testing.T) {
	o, err := parseOptions([]string{"--mode", "template", "--template", "/tmp/template.json", "--values", "/tmp/values.json"})
	if err != nil {
		t.Fatal(err)
	}
	if o.mode != "template" || o.template != "/tmp/template.json" || o.values != "/tmp/values.json" {
		t.Fatalf("unexpected options: %#v", o)
	}
	if _, err := parseOptions([]string{"--mode", "implicit"}); err == nil {
		t.Fatal("unknown mode succeeded")
	}
	invalid := [][]string{
		{"--mode", "file", "--mode", "template"},
		{"--mode", "file", "--template", "/tmp/template.json"},
		{"--mode", "template", "--config", "/tmp/config.json"},
		{"--mode", "env-base64", "--values", "/tmp/values.json"},
		{"--mode", "env-base64", "--env-var", "INVALID=NAME"},
	}
	for _, args := range invalid {
		if _, err := parseOptions(args); err == nil {
			t.Fatalf("parseOptions(%q) unexpectedly succeeded", args)
		}
	}
}

func TestEnvBase64IsClearedAfterRead(t *testing.T) {
	const name = "XRAY_ENTRY_TEST_CONFIG"
	t.Setenv(name, base64.StdEncoding.EncodeToString([]byte(`{"outbounds":[]}`)))
	if _, err := generatedConfig(options{mode: "env-base64", envVar: name}); err != nil {
		t.Fatal(err)
	}
	if _, ok := os.LookupEnv(name); ok {
		t.Fatal("base64 source remains in process environment")
	}
}
