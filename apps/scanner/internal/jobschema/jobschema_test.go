package jobschema

import (
	"encoding/json"
	"strings"
	"testing"
)

// validScanJob returns a fresh, valid ScanJobV1 payload as a JSON byte slice.
func validScanJob(t *testing.T) []byte {
	t.Helper()
	payload := map[string]any{
		"schema_version":  1,
		"idempotency_key": "scan-2026-05-07-host-1234",
		"scan_kind":       "tcp_probe",
		"target": map[string]any{
			"kind":  "ip",
			"value": "192.0.2.1",
		},
		"requested_at": "2026-05-07T08:30:00Z",
	}
	bytes, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return bytes
}

func TestValidateScanJobV1_Accept(t *testing.T) {
	errs, err := Validate(NameScanJobV1, validScanJob(t))
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(errs) != 0 {
		t.Fatalf("expected 0 errors, got %v", errs)
	}
}

func TestValidateScanJobV1_RejectsBadSchemaVersion(t *testing.T) {
	var payload map[string]any
	_ = json.Unmarshal(validScanJob(t), &payload)
	payload["schema_version"] = 99
	bytes, _ := json.Marshal(payload)

	errs, err := Validate(NameScanJobV1, bytes)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(errs) == 0 {
		t.Fatal("expected at least one error for schema_version=99")
	}
	if !containsAny(errs, "schema_version") {
		t.Fatalf("expected error to mention schema_version, got %v", errs)
	}
}

func TestValidateScanJobV1_RejectsUnknownScanKind(t *testing.T) {
	var payload map[string]any
	_ = json.Unmarshal(validScanJob(t), &payload)
	payload["scan_kind"] = "icmp_flood"
	bytes, _ := json.Marshal(payload)

	errs, _ := Validate(NameScanJobV1, bytes)
	if len(errs) == 0 {
		t.Fatal("expected error for unknown scan_kind")
	}
}

func TestValidateScanJobV1_RejectsExtraField(t *testing.T) {
	var payload map[string]any
	_ = json.Unmarshal(validScanJob(t), &payload)
	payload["evil"] = true
	bytes, _ := json.Marshal(payload)

	errs, _ := Validate(NameScanJobV1, bytes)
	if !containsAny(errs, "evil") {
		t.Fatalf("expected error mentioning extra field, got %v", errs)
	}
}

func TestValidateScanJobV1_RejectsMissingRequired(t *testing.T) {
	var payload map[string]any
	_ = json.Unmarshal(validScanJob(t), &payload)
	delete(payload, "requested_at")
	bytes, _ := json.Marshal(payload)

	errs, _ := Validate(NameScanJobV1, bytes)
	if !containsAny(errs, "requested_at") {
		t.Fatalf("expected error about required field, got %v", errs)
	}
}

func TestValidateScanResultV1_Accept(t *testing.T) {
	payload := map[string]any{
		"schema_version":  1,
		"job_id":          "job-12345678",
		"idempotency_key": "scan-2026-05-07-host-1234",
		"target":          map[string]any{"kind": "ip", "value": "192.0.2.1"},
		"status":          "success",
		"observed_at":     "2026-05-07T08:31:00Z",
	}
	bytes, _ := json.Marshal(payload)

	errs, err := Validate(NameScanResultV1, bytes)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(errs) != 0 {
		t.Fatalf("expected 0 errors, got %v", errs)
	}
}

func TestValidateHeartbeatV1_RejectsNegativeInflight(t *testing.T) {
	payload := map[string]any{
		"schema_version": 1,
		"worker_id":      "worker-eu-west-1",
		"emitted_at":     "2026-05-07T08:30:00Z",
		"inflight_jobs":  -1,
	}
	bytes, _ := json.Marshal(payload)

	errs, _ := Validate(NameHeartbeatV1, bytes)
	if !containsAny(errs, "inflight_jobs") {
		t.Fatalf("expected error about negative inflight_jobs, got %v", errs)
	}
}

func TestValidate_UnknownSchema(t *testing.T) {
	_, err := Validate("Bogus", []byte(`{}`))
	if err == nil {
		t.Fatal("expected error for unknown schema")
	}
}

// Round-trip cross-language : un payload genere comme Rails l'enverrait
// (clefs string, schema_version int, RFC3339) doit traverser le validateur
// Go sans erreur. Ce test materialise le scenario "round-trip Rails -> Go"
// de openspec/changes/add-tech-stack/tasks.md section 3.1.
func TestRoundTripFromRailsLikePayload(t *testing.T) {
	rails := []byte(`{
		"schema_version": 1,
		"idempotency_key": "scan-2026-05-07-fr-modbus",
		"scan_kind": "tls_capture",
		"target": { "kind": "domain", "value": "example.fr" },
		"requested_at": "2026-05-07T09:00:00+02:00",
		"options": { "ports": [443, 8443] }
	}`)
	errs, err := Validate(NameScanJobV1, rails)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(errs) != 0 {
		t.Fatalf("Rails-shaped payload rejected: %v", errs)
	}
}

func containsAny(errs []string, needle string) bool {
	for _, e := range errs {
		if strings.Contains(e, needle) {
			return true
		}
	}
	return false
}
