package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

func parseJSON(data []byte) (any, error) {
	if len(data) == 0 || len(data) > maxConfigBytes {
		return nil, errors.New("JSON input is empty or exceeds size limit")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	v, err := parseJSONValue(d, 0)
	if err != nil {
		return nil, errors.New("invalid JSON")
	}
	if _, err := d.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("JSON has trailing data")
	}
	return v, nil
}

func parseJSONValue(d *json.Decoder, depth int) (any, error) {
	if depth > maxJSONDepth {
		return nil, errors.New("JSON exceeds nesting limit")
	}
	token, err := d.Token()
	if err != nil {
		return nil, err
	}
	switch value := token.(type) {
	case json.Delim:
		switch value {
		case '{':
			object := make(map[string]any)
			for d.More() {
				keyToken, err := d.Token()
				if err != nil {
					return nil, err
				}
				key, ok := keyToken.(string)
				if !ok {
					return nil, errors.New("object key is not a string")
				}
				if _, exists := object[key]; exists {
					return nil, fmt.Errorf("duplicate key %q", key)
				}
				child, err := parseJSONValue(d, depth+1)
				if err != nil {
					return nil, err
				}
				object[key] = child
			}
			end, err := d.Token()
			if err != nil || end != json.Delim('}') {
				return nil, errors.New("unterminated object")
			}
			return object, nil
		case '[':
			array := make([]any, 0)
			for d.More() {
				child, err := parseJSONValue(d, depth+1)
				if err != nil {
					return nil, err
				}
				array = append(array, child)
			}
			end, err := d.Token()
			if err != nil || end != json.Delim(']') {
				return nil, errors.New("unterminated array")
			}
			return array, nil
		default:
			return nil, errors.New("unexpected delimiter")
		}
	case string, bool, nil:
		return value, nil
	case json.Number, float64:
		return value, nil
	default:
		return nil, errors.New("unexpected JSON value")
	}
}

func renderTemplate(value any, values map[string]any) (any, error) {
	switch current := value.(type) {
	case map[string]any:
		if _, hasMarker := current["$xrayParam"]; hasMarker {
			if len(current) != 1 {
				return nil, errors.New("malformed parameter marker")
			}
			name, ok := current["$xrayParam"].(string)
			if !ok || len(name) > maxParameterName || !parameterName.MatchString(name) {
				return nil, errors.New("malformed parameter marker")
			}
			replacement, found := values[name]
			if !found {
				return nil, fmt.Errorf("missing required parameter %q", name)
			}
			return replacement, nil
		}
		result := make(map[string]any, len(current))
		for key, child := range current {
			rendered, err := renderTemplate(child, values)
			if err != nil {
				return nil, err
			}
			result[key] = rendered
		}
		return result, nil
	case []any:
		result := make([]any, len(current))
		for i, child := range current {
			rendered, err := renderTemplate(child, values)
			if err != nil {
				return nil, err
			}
			result[i] = rendered
		}
		return result, nil
	default:
		return value, nil
	}
}
