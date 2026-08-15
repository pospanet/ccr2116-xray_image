package main

import "testing"

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
}
