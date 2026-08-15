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
		`{"a":"\uD800"}`,
		`{"a":"\uDC00"}`,
		string([]byte{'{', '"', 'a', '"', ':', '"', 0xff, '"', '}'}),
	}
	for _, input := range cases {
		if _, err := parseJSON([]byte(input)); err == nil {
			t.Fatalf("parseJSON(%q) unexpectedly succeeded", input)
		}
	}
}

func TestParseJSONAcceptsSurrogatePair(t *testing.T) {
	if _, err := parseJSON([]byte(`{"value":"\uD83D\uDE00"}`)); err != nil {
		t.Fatal(err)
	}
}

func TestParseJSONAcceptsNumericValues(t *testing.T) {
	config, err := parseJSON([]byte(`{"log":{"loglevel":"warning"},"inbounds":[{"port":18080}],"outbounds":[{"protocol":"freedom"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := config.(map[string]any)["inbounds"].([]any)[0].(map[string]any)["port"]; !ok || got != json.Number("18080") {
		t.Fatalf("unexpected numeric value from parser: %#v", got)
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
		`{"$xrayUnknown":"name"}`,
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

func TestRenderTemplateRejectsUnusedValues(t *testing.T) {
	template, err := parseJSON([]byte(`{"value":{"$xrayParam":"used"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := renderTemplate(template, map[string]any{"used": true, "unused": false}); err == nil {
		t.Fatal("unused template value unexpectedly succeeded")
	}
}
