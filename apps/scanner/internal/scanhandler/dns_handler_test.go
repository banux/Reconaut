package scanhandler

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/goodjob"
	"github.com/banux/Reconaut/apps/scanner/internal/results"
)

// Cf. openspec/changes/add-dns-records-scanner/tasks.md §2.3.

type fakeProber struct {
	records []ResolvedRecord
	err     error
	called  int
	target  string
}

func (f *fakeProber) Resolve(_ context.Context, target string) ([]ResolvedRecord, error) {
	f.called++
	f.target = target
	if f.err != nil {
		return nil, f.err
	}
	return f.records, nil
}

func dnsPayload(idemKey, targetKind, value string) map[string]any {
	return map[string]any{
		"schema_version":  float64(1),
		"idempotency_key": idemKey,
		"scan_kind":       "dns_records",
		"target":          map[string]any{"kind": targetKind, "value": value},
		"requested_at":    time.Now().UTC().Format(time.RFC3339),
	}
}

func TestNew_DNSRecords_PersistsResolvedRecords(t *testing.T) {
	prober := &fakeProber{records: []ResolvedRecord{
		{RecordType: "A", Name: "example.fr", Value: "192.0.2.10", TTL: 300},
		{RecordType: "MX", Name: "example.fr", Value: "10 mail.example.fr", TTL: 300},
		{RecordType: "TXT", Name: "example.fr", Value: "v=spf1 -all", TTL: 300},
	}}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{DNSProber: prober})

	job := goodjob.Job{ID: "j1", Params: dnsPayload("scan-dns-001-aaaa", "domain", "example.fr")}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}

	if prober.called != 1 {
		t.Fatalf("prober.Resolve called %d times, want 1", prober.called)
	}
	if prober.target != "example.fr" {
		t.Errorf("prober target=%q, want example.fr", prober.target)
	}

	persisted, _ := store.List(context.Background())
	if len(persisted) != 1 {
		t.Fatalf("expected 1 result row, got %d", len(persisted))
	}
	r := persisted[0]
	if r.ScanKind != "dns_records" {
		t.Errorf("ScanKind=%q, want dns_records", r.ScanKind)
	}

	// Le champ Status porte le JSON des findings (transitoire en
	// attendant la colonne findings jsonb).
	var payload struct {
		Records []ResolvedRecord `json:"records"`
		Count   int              `json:"count"`
	}
	if err := json.Unmarshal([]byte(r.Status), &payload); err != nil {
		t.Fatalf("Status is not valid JSON: %v\n%s", err, r.Status)
	}
	if payload.Count != 3 {
		t.Errorf("count=%d, want 3", payload.Count)
	}
	if len(payload.Records) != 3 {
		t.Errorf("records=%d, want 3", len(payload.Records))
	}
}

func TestNew_DNSRecords_RejectsTargetKindIP(t *testing.T) {
	prober := &fakeProber{}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{DNSProber: prober})

	job := goodjob.Job{ID: "j1", Params: dnsPayload("scan-dns-002-bbbb", "ip", "192.0.2.10")}
	err := handler(context.Background(), job)
	if err == nil {
		t.Fatal("expected error for target_kind=ip on dns_records")
	}
	if !strings.Contains(err.Error(), "domain") {
		t.Errorf("error should mention domain : %v", err)
	}
	if prober.called != 0 {
		t.Errorf("prober should NOT be called when target_kind=ip ; got called=%d", prober.called)
	}
	if store.Count() != 0 {
		t.Errorf("no result should be persisted ; got %d", store.Count())
	}
}

func TestNew_DNSRecords_NoProberWired_PersistsSkipped(t *testing.T) {
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{DNSProber: nil})

	job := goodjob.Job{ID: "j1", Params: dnsPayload("scan-dns-003-cccc", "domain", "ex.fr")}
	if err := handler(context.Background(), job); err != nil {
		t.Fatalf("handler: %v", err)
	}
	persisted, _ := store.List(context.Background())
	if len(persisted) != 1 {
		t.Fatalf("expected 1 row, got %d", len(persisted))
	}
	if !strings.Contains(persisted[0].Status, "skipped") {
		t.Errorf("Status should mention 'skipped' when no prober wired : %q", persisted[0].Status)
	}
}

func TestNew_DNSRecords_ProberError(t *testing.T) {
	prober := &fakeProber{err: errors.New("dns broken")}
	store := results.NewInMemoryStore()
	handler := NewWithOptions(store, Options{DNSProber: prober})

	job := goodjob.Job{ID: "j1", Params: dnsPayload("scan-dns-004-dddd", "domain", "ex.fr")}
	err := handler(context.Background(), job)
	if err == nil {
		t.Fatal("expected error when prober fails")
	}
	if !strings.Contains(err.Error(), "dns") {
		t.Errorf("error should mention dns : %v", err)
	}
}
