// SPDX-License-Identifier: AGPL-3.0-only
// scanner-service_fingerprint : binaire spécialisé `scan:service_fingerprint`.
//
// Pour la v1, ce binaire couvre les 6 sondeurs applicatifs §2.5 :
//   - SSH (banner + host-key SHA-256, TCP/22)
//   - RDP (X.224 Negotiation + capture TLS cert opt-in, TCP/3389)
//   - MQTT (CONNECT/CONNACK + capture TLS cert sur 8883, TCP/1883)
//   - CoAP (GET /.well-known/core, UDP/5683)
//   - Modbus (Read Device ID + fallback Read Holding, TCP/502)
//
// Tous sans authentification, sans mutation, sans énumération.
// Cf. openspec/changes/add-ssh-probe/, add-rdp-probe/, add-mqtt-probe/,
// add-coap-probe/, add-worker-modbus/.
//
// Variables d'environnement :
//   - RECONAUT_SSH_PROBE_TIMEOUT : timeout sonde SSH en secondes (défaut 5).
//   - RECONAUT_RDP_PROBE_TIMEOUT : timeout sonde RDP en secondes (défaut 5).
//   - RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE : "true"/"1" pour désactiver
//     l'upgrade TLS RDP (cert non capturé même si PROTOCOL_SSL annoncé).
//   - RECONAUT_MQTT_PROBE_TIMEOUT : timeout sonde MQTT en secondes (défaut 5).
//   - RECONAUT_MQTT_PROBE_DISABLE_TLS_UPGRADE : "true"/"1" pour désactiver
//     l'upgrade TLS MQTT sur port 8883.
//   - RECONAUT_COAP_PROBE_TIMEOUT : timeout sonde CoAP en secondes (défaut 5).
//   - RECONAUT_MODBUS_PROBE_TIMEOUT : timeout sonde Modbus en secondes (défaut 5).
//   - RECONAUT_MODBUS_PROBE_UNIT_ID : Unit ID Modbus (1-255, défaut 1).
package main

import (
	"context"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/banux/Reconaut/apps/scanner/internal/coapprobe"
	"github.com/banux/Reconaut/apps/scanner/internal/modbusprobe"
	"github.com/banux/Reconaut/apps/scanner/internal/mqttprobe"
	"github.com/banux/Reconaut/apps/scanner/internal/rdpprobe"
	"github.com/banux/Reconaut/apps/scanner/internal/runtime"
	"github.com/banux/Reconaut/apps/scanner/internal/scanhandler"
	"github.com/banux/Reconaut/apps/scanner/internal/sshprobe"
)

func main() {
	sshTimeoutSec := 5
	if v := os.Getenv("RECONAUT_SSH_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			sshTimeoutSec = n
		}
	}

	rdpTimeoutSec := 5
	if v := os.Getenv("RECONAUT_RDP_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			rdpTimeoutSec = n
		}
	}

	rdpTLSUpgrade := true
	if v := strings.ToLower(strings.TrimSpace(os.Getenv("RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE"))); v == "true" || v == "1" || v == "yes" {
		rdpTLSUpgrade = false
	}

	mqttTimeoutSec := 5
	if v := os.Getenv("RECONAUT_MQTT_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			mqttTimeoutSec = n
		}
	}
	mqttTLSUpgrade := true
	if v := strings.ToLower(strings.TrimSpace(os.Getenv("RECONAUT_MQTT_PROBE_DISABLE_TLS_UPGRADE"))); v == "true" || v == "1" || v == "yes" {
		mqttTLSUpgrade = false
	}

	sshProber := sshAdapter{cfg: sshprobe.Config{
		Timeout: time.Duration(sshTimeoutSec) * time.Second,
	}}

	rdpProber := rdpAdapter{cfg: rdpprobe.Config{
		Timeout:       time.Duration(rdpTimeoutSec) * time.Second,
		TryTLSUpgrade: rdpTLSUpgrade,
	}}

	mqttProber := mqttAdapter{cfg: mqttprobe.Config{
		Timeout:       time.Duration(mqttTimeoutSec) * time.Second,
		TryTLSUpgrade: mqttTLSUpgrade,
	}}

	coapTimeoutSec := 5
	if v := os.Getenv("RECONAUT_COAP_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			coapTimeoutSec = n
		}
	}
	coapProber := coapAdapter{cfg: coapprobe.Config{
		Timeout: time.Duration(coapTimeoutSec) * time.Second,
	}}

	modbusTimeoutSec := 5
	if v := os.Getenv("RECONAUT_MODBUS_PROBE_TIMEOUT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			modbusTimeoutSec = n
		}
	}
	modbusUnitID := byte(1)
	if v := os.Getenv("RECONAUT_MODBUS_PROBE_UNIT_ID"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 255 {
			modbusUnitID = byte(n)
		}
	}
	modbusProber := modbusAdapter{cfg: modbusprobe.Config{
		Timeout: time.Duration(modbusTimeoutSec) * time.Second,
		UnitID:  modbusUnitID,
	}}

	os.Exit(runtime.Run(runtime.Config{
		ScanKind: "service_fingerprint",
		Args:     os.Args[1:],
		HandlerOptions: scanhandler.Options{
			SSHProber:    sshProber,
			RDPProber:    rdpProber,
			MQTTProber:   mqttProber,
			CoAPProber:   coapProber,
			ModbusProber: modbusProber,
		},
	}))
}

// sshAdapter adapte sshprobe.Probe à l'interface scanhandler.SSHProber
// (mappe sshprobe.Result → scanhandler.SSHProbeResult).
type sshAdapter struct {
	cfg sshprobe.Config
}

func (a sshAdapter) Probe(ctx context.Context, target string, port int) (scanhandler.SSHProbeResult, error) {
	cfg := a.cfg
	if port > 0 {
		cfg.Port = port
	}
	res, err := sshprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.SSHProbeResult{}, err
	}
	return scanhandler.SSHProbeResult{
		Banner:        res.Banner,
		HostKeySHA256: res.HostKeySHA256,
		DurationMs:    res.DurationMs,
		BytesReceived: res.BytesReceived,
		Outcome:       res.Outcome,
	}, nil
}

// rdpAdapter adapte rdpprobe.Probe à l'interface scanhandler.RDPProber.
type rdpAdapter struct {
	cfg rdpprobe.Config
}

func (a rdpAdapter) Probe(ctx context.Context, target string, port int) (scanhandler.RDPProbeResult, error) {
	cfg := a.cfg
	if port > 0 {
		cfg.Port = port
	}
	res, err := rdpprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.RDPProbeResult{}, err
	}
	return scanhandler.RDPProbeResult{
		ProtocolVersion:        res.ProtocolVersion,
		SecurityFlags:          res.SecurityFlags,
		NegotiationFailureCode: res.NegotiationFailureCode,
		TLSCertSHA256:          res.TLSCertSHA256,
		TLSSANs:                res.TLSSANs,
		TLSNotAfter:            res.TLSNotAfter,
		DurationMs:             res.DurationMs,
		BytesReceived:          res.BytesReceived,
		Outcome:                res.Outcome,
	}, nil
}

// mqttAdapter adapte mqttprobe.Probe à l'interface scanhandler.MQTTProber.
type mqttAdapter struct {
	cfg mqttprobe.Config
}

func (a mqttAdapter) Probe(ctx context.Context, target string, port int) (scanhandler.MQTTProbeResult, error) {
	cfg := a.cfg
	if port > 0 {
		cfg.Port = port
	}
	res, err := mqttprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.MQTTProbeResult{}, err
	}
	return scanhandler.MQTTProbeResult{
		ProtocolLevel:     res.ProtocolLevel,
		ReturnCode:        res.ReturnCode,
		ReturnCodeMeaning: res.ReturnCodeMeaning,
		SessionPresent:    res.SessionPresent,
		TLSCertSHA256:     res.TLSCertSHA256,
		TLSSANs:           res.TLSSANs,
		TLSNotAfter:       res.TLSNotAfter,
		DurationMs:        res.DurationMs,
		BytesReceived:     res.BytesReceived,
		Outcome:           res.Outcome,
	}, nil
}

// coapAdapter adapte coapprobe.Probe à l'interface scanhandler.CoAPProber.
type coapAdapter struct {
	cfg coapprobe.Config
}

func (a coapAdapter) Probe(ctx context.Context, target string, port int) (scanhandler.CoAPProbeResult, error) {
	cfg := a.cfg
	if port > 0 {
		cfg.Port = port
	}
	res, err := coapprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.CoAPProbeResult{}, err
	}
	return scanhandler.CoAPProbeResult{
		ResponseCodeClass:   res.ResponseCodeClass,
		ResponseCodeDetail:  res.ResponseCodeDetail,
		ResponseCodeMeaning: res.ResponseCodeMeaning,
		ContentFormat:       res.ContentFormat,
		PayloadExcerpt:      res.PayloadExcerpt,
		DurationMs:          res.DurationMs,
		BytesReceived:       res.BytesReceived,
		Outcome:             res.Outcome,
	}, nil
}

// modbusAdapter adapte modbusprobe.Probe à l'interface scanhandler.ModbusProber.
type modbusAdapter struct {
	cfg modbusprobe.Config
}

func (a modbusAdapter) Probe(ctx context.Context, target string, port int) (scanhandler.ModbusProbeResult, error) {
	cfg := a.cfg
	if port > 0 {
		cfg.Port = port
	}
	res, err := modbusprobe.Probe(ctx, target, cfg)
	if err != nil {
		return scanhandler.ModbusProbeResult{}, err
	}
	return scanhandler.ModbusProbeResult{
		VendorName:         res.VendorName,
		ProductCode:        res.ProductCode,
		MajorMinorRevision: res.MajorMinorRevision,
		FunctionCode:       res.FunctionCode,
		ExceptionCode:      res.ExceptionCode,
		ExceptionMeaning:   res.ExceptionMeaning,
		IsModbus:           res.IsModbus,
		DurationMs:         res.DurationMs,
		BytesReceived:      res.BytesReceived,
		Outcome:            res.Outcome,
	}, nil
}
