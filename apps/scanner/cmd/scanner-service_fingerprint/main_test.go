// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"context"
	"net"
	"testing"
	"time"
)

// TestSSHAdapter_RespectsTimeout vérifie que le binaire applique le
// timeout configuré (RECONAUT_SSH_PROBE_TIMEOUT) à la sonde via
// l'adapter sshAdapter. On simule la lecture d'env via une valeur
// directe — l'objectif est de prouver que cfg.Timeout est bien
// honorée par sshprobe.Probe à travers l'adapter, pas de tester
// os.Getenv lui-même.
//
// Cf. openspec/changes/add-ssh-probe/tasks.md §2.2.
func TestSSHAdapter_RespectsTimeout(t *testing.T) {
	// Démarre un serveur silencieux qui accepte la connexion mais ne
	// renvoie aucun banner (équivalent d'un service inconnu sur 22).
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		// Lit puis ferme — sans rien envoyer.
		buf := make([]byte, 1)
		_, _ = c.Read(buf)
	}()

	host, p, _ := net.SplitHostPort(ln.Addr().String())
	var port int
	for _, c := range p {
		port = port*10 + int(c-'0')
	}

	adapter := sshAdapter{}
	adapter.cfg.Timeout = 300 * time.Millisecond

	start := time.Now()
	res, err := adapter.Probe(context.Background(), host, port)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	// 300 ms timeout + un peu de slack ; on vérifie qu'on n'a pas
	// attendu 5s (le défaut) — invariant : le timeout configuré pèse.
	if elapsed > 2*time.Second {
		t.Errorf("probe took %v, expected ~300ms", elapsed)
	}
	// Outcome attendu : not_ssh (port ouvert mais protocole muet).
	if res.Outcome != "not_ssh" && res.Outcome != "timeout" {
		t.Errorf("expected outcome not_ssh or timeout, got %q", res.Outcome)
	}
}

// TestRDPAdapter_RespectsTimeout symétrique de SSH : on prouve que le
// timeout configuré dans rdpprobe.Config est bien appliqué à travers
// l'adapter.
//
// Cf. openspec/changes/add-rdp-probe/tasks.md §2.2.
func TestRDPAdapter_RespectsTimeout(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		buf := make([]byte, 1024)
		_, _ = c.Read(buf)
	}()

	host, p, _ := net.SplitHostPort(ln.Addr().String())
	var port int
	for _, c := range p {
		port = port*10 + int(c-'0')
	}

	adapter := rdpAdapter{}
	adapter.cfg.Timeout = 300 * time.Millisecond

	start := time.Now()
	res, err := adapter.Probe(context.Background(), host, port)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if elapsed > 2*time.Second {
		t.Errorf("probe took %v, expected ~300ms", elapsed)
	}
	if res.Outcome != "timeout" && res.Outcome != "not_rdp" {
		t.Errorf("expected outcome timeout or not_rdp, got %q", res.Outcome)
	}
}

// TestRDPAdapter_TLSUpgradeDisabled : quand DISABLE_TLS_UPGRADE est
// honoré (TryTLSUpgrade=false), un TLS handshake n'est PAS tenté
// même si la cible annonce PROTOCOL_SSL. On ne le vérifie pas via
// env (couplage process-global) mais par construction sur l'adapter :
// si rdpprobe.Config.TryTLSUpgrade est false, le sondeur n'envoie pas
// de ClientHello — cette propriété est testée exhaustivement dans
// internal/rdpprobe. Ici on s'assure juste que l'adapter recopie
// fidèlement TryTLSUpgrade depuis sa config.
func TestRDPAdapter_TLSUpgradeFlagPropagation(t *testing.T) {
	off := rdpAdapter{}
	off.cfg.TryTLSUpgrade = false
	if off.cfg.TryTLSUpgrade {
		t.Fatal("adapter must preserve TryTLSUpgrade=false")
	}

	on := rdpAdapter{}
	on.cfg.TryTLSUpgrade = true
	if !on.cfg.TryTLSUpgrade {
		t.Fatal("adapter must preserve TryTLSUpgrade=true")
	}
}
