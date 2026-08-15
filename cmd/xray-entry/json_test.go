package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseJSONRejectsAmbiguity(t *testing.T) {
	cases := []string{
		`{"a":1,"a":2}`,
		`{"a":1} trailing`,
		`{"a":`,
	}
	for _, input := range cases {
		if _, err := parseJSON([]byte(input)); err == nil {
			t.Fatalf("parseJSON(%q) unexpectedly succeeded", input)
		}
	}
}

func TestRenderTemplatePreservesTypes(t *testing.T) {
	template, err := parseJSON([]byte(`{"port":{"$xrayParam":"listen_port"},"enabled":{"$xrayParam":"enabled"},"id":{"$xrayParam":"example_id"}}`))
	if err != nil {
		t.Fatal(err)
	}
	values, err := parseJSON([]byte(`{"listen_port":10085,"enabled":true,"example_id":"11111111-1111-4111-8111-111111111111"}`))
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := renderTemplate(template, values.(map[string]any))
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(rendered)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(b), `{"enabled":true,"id":"11111111-1111-4111-8111-111111111111","port":10085}`; got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestRenderTemplateFailsClosed(t *testing.T) {
	cases := []string{
		`{"$xrayParam":"missing"}`,
		`{"$xrayParam":"name","extra":true}`,
		`{"$xrayParam":3}`,
	}
	for _, input := range cases {
		template, err := parseJSON([]byte(input))
		if err != nil {
			t.Fatal(err)
		}
		_, err = renderTemplate(template, map[string]any{"name": "value"})
		if err == nil || (!strings.Contains(err.Error(), "missing") && !strings.Contains(err.Error(), "malformed")) {
			t.Fatalf("expected closed failure for %s, got %v", input, err)
		}
	}
}
