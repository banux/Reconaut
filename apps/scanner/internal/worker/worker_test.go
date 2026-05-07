package worker

import (
	"strings"
	"testing"
)

// Smoke test - satisfait le critere "chaque suite contient un test smoke
// trivial qui passe" de add-tech-stack tasks 2.1.
func TestVersionDeclared(t *testing.T) {
	if Version == "" {
		t.Fatal("Version must not be empty")
	}
	if !strings.Contains(Version, "bootstrap") && !strings.HasPrefix(Version, "0.") && !strings.HasPrefix(Version, "1.") {
		t.Fatalf("Version %q does not look semver-compatible", Version)
	}
}
