// SPDX-License-Identifier: AGPL-3.0-only
// Package jobschema loads and validates the canonical JSON schemas
// shared between Rails (apps/api) and the Go workers (apps/scanner).
//
// Source of truth: packages/job-schema/*.json at the monorepo root.
// Spec: openspec/changes/add-tech-stack/specs/architecture/spec.md
//
// We deliberately avoid pulling a heavy JSON-Schema library to keep
// scanner-worker dependency-free. Instead, we implement the small subset
// of validation we need (required fields, const values, enums, types,
// integer minimums, additionalProperties=false). When a stricter library
// becomes warranted, swap this file out without changing the public API.
package jobschema

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// Name is the symbolic identifier of a known schema.
type Name string

const (
	NameScanJobV1    Name = "ScanJobV1"
	NameScanResultV1 Name = "ScanResultV1"
	NameHeartbeatV1  Name = "HeartbeatV1"
)

var schemaFiles = map[Name]string{
	NameScanJobV1:    "scan_job_v1.json",
	NameScanResultV1: "scan_result_v1.json",
	NameHeartbeatV1:  "heartbeat_v1.json",
}

// SchemasDir returns the absolute path to packages/job-schema/.
//
// We resolve it relative to this source file so tests work without env
// variables. RECONAUT_JOB_SCHEMA_DIR overrides for ops who repackage.
func SchemasDir() string {
	if env := os.Getenv("RECONAUT_JOB_SCHEMA_DIR"); env != "" {
		return env
	}
	_, here, _, _ := runtime.Caller(0)
	// .../apps/scanner/internal/jobschema/jobschema.go -> repo root -> packages/job-schema
	return filepath.Clean(filepath.Join(filepath.Dir(here), "..", "..", "..", "..", "packages", "job-schema"))
}

type rawSchema map[string]any

func loadRawSchema(name Name) (rawSchema, error) {
	file, ok := schemaFiles[name]
	if !ok {
		return nil, fmt.Errorf("unknown schema: %q", name)
	}
	path := filepath.Join(SchemasDir(), file)
	bytes, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read schema %s: %w", path, err)
	}
	var schema rawSchema
	if err := json.Unmarshal(bytes, &schema); err != nil {
		return nil, fmt.Errorf("parse schema %s: %w", path, err)
	}
	return schema, nil
}

// Validate checks payload against the named schema. Returns the list of
// validation errors. An empty slice means the payload conforms.
func Validate(name Name, payload []byte) ([]string, error) {
	schema, err := loadRawSchema(name)
	if err != nil {
		return nil, err
	}
	var data any
	if err := json.Unmarshal(payload, &data); err != nil {
		return nil, fmt.Errorf("parse payload: %w", err)
	}
	v := &validator{}
	v.validate("$", schema, data)
	return v.errors, nil
}

type validator struct {
	errors []string
}

func (v *validator) push(format string, args ...any) {
	v.errors = append(v.errors, fmt.Sprintf(format, args...))
}

func (v *validator) validate(path string, schema rawSchema, data any) {
	if t, ok := schema["type"].(string); ok {
		if !typeMatches(t, data) {
			v.push("%s: expected type %q, got %T", path, t, data)
			return
		}
	}

	if c, ok := schema["const"]; ok {
		if !jsonEqual(c, data) {
			v.push("%s: expected const %v, got %v", path, c, data)
		}
	}

	if enum, ok := schema["enum"].([]any); ok {
		matched := false
		for _, candidate := range enum {
			if jsonEqual(candidate, data) {
				matched = true
				break
			}
		}
		if !matched {
			v.push("%s: value %v not in enum", path, data)
		}
	}

	switch typed := data.(type) {
	case map[string]any:
		v.validateObject(path, schema, typed)
	case string:
		v.validateString(path, schema, typed)
	case float64:
		v.validateNumber(path, schema, typed)
	case []any:
		v.validateArray(path, schema, typed)
	}
}

func (v *validator) validateObject(path string, schema rawSchema, obj map[string]any) {
	if required, ok := schema["required"].([]any); ok {
		for _, r := range required {
			key, _ := r.(string)
			if _, present := obj[key]; !present {
				v.push("%s: missing required field %q", path, key)
			}
		}
	}

	props, _ := schema["properties"].(map[string]any)
	additional := true
	if a, ok := schema["additionalProperties"].(bool); ok {
		additional = a
	}

	for key, value := range obj {
		subSchema, declared := props[key].(map[string]any)
		if !declared {
			if !additional {
				v.push("%s: unexpected field %q", path, key)
			}
			continue
		}
		v.validate(path+"."+key, rawSchema(subSchema), value)
	}
}

func (v *validator) validateString(path string, schema rawSchema, s string) {
	if min, ok := numberFromAny(schema["minLength"]); ok {
		if len(s) < int(min) {
			v.push("%s: shorter than minLength=%d", path, int(min))
		}
	}
	if max, ok := numberFromAny(schema["maxLength"]); ok {
		if len(s) > int(max) {
			v.push("%s: longer than maxLength=%d", path, int(max))
		}
	}
	if format, ok := schema["format"].(string); ok && format == "date-time" {
		if !looksLikeRFC3339(s) {
			v.push("%s: not a date-time", path)
		}
	}
}

func (v *validator) validateNumber(path string, schema rawSchema, n float64) {
	if t, ok := schema["type"].(string); ok && t == "integer" {
		if n != float64(int64(n)) {
			v.push("%s: expected integer, got %v", path, n)
		}
	}
	if min, ok := numberFromAny(schema["minimum"]); ok {
		if n < min {
			v.push("%s: below minimum %v", path, min)
		}
	}
}

func (v *validator) validateArray(path string, schema rawSchema, arr []any) {
	if items, ok := schema["items"].(map[string]any); ok {
		for i, item := range arr {
			v.validate(fmt.Sprintf("%s[%d]", path, i), rawSchema(items), item)
		}
	}
}

func typeMatches(want string, data any) bool {
	switch want {
	case "object":
		_, ok := data.(map[string]any)
		return ok
	case "array":
		_, ok := data.([]any)
		return ok
	case "string":
		_, ok := data.(string)
		return ok
	case "integer", "number":
		f, ok := data.(float64)
		if !ok {
			return false
		}
		if want == "integer" {
			return f == float64(int64(f))
		}
		return true
	case "boolean":
		_, ok := data.(bool)
		return ok
	case "null":
		return data == nil
	}
	return true
}

func jsonEqual(a, b any) bool {
	ab, _ := json.Marshal(a)
	bb, _ := json.Marshal(b)
	return string(ab) == string(bb)
}

func numberFromAny(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}

func looksLikeRFC3339(s string) bool {
	if len(s) < 20 {
		return false
	}
	if s[4] != '-' || s[7] != '-' || s[10] != 'T' {
		return false
	}
	last := s[len(s)-1]
	return last == 'Z' || strings.ContainsAny(s[len(s)-6:], "+-")
}
