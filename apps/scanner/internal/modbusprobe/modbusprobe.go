// SPDX-License-Identifier: AGPL-3.0-only
// Package modbusprobe fingerprinte un device Modbus TCP (RFC Modbus
// Application Protocol V1.1b3, port 502) en lui envoyant au plus deux
// paquets read-only :
//
//   - 1er : Read Device Identification (fonction 0x2B, MEI type 0x0E,
//     ReadDeviceIDCode=0x01 "basic"). Récupère vendor_name (object 0),
//     product_code (object 1), major_minor_revision (object 2).
//   - 2e (fallback) si le 1er reçoit une exception (function | 0x80) :
//     Read Holding Registers (fonction 0x03) à l'adresse 0, quantity
//     1. Confirme au moins que c'est un endpoint Modbus.
//
// Le sondeur N'EFFECTUE AUCUNE écriture (toutes les fonctions write
// 0x05/0x06/0x0F/0x10/0x17 sont INTERDITES par construction). La
// fonction Diagnostics (0x08) — qui peut RESET un device industriel —
// est également INTERDITE. Reconaut n'est PAS un outil offensif.
//
// Source de vérité :
//
//	openspec/changes/add-worker-modbus/specs/scanning/spec.md
//	  -> Requirement: Modbus TCP Device Fingerprint
//
// Linter CI : `scripts/check_modbus_probe_no_write.sh`.
package modbusprobe

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"math/rand"
	"net"
	"strconv"
	"strings"
	"time"
)

// Outcome enumère les issues possibles d'une sonde.
const (
	OutcomeSuccess   = "success"
	OutcomeTimeout   = "timeout"
	OutcomeDialError = "dial_error"
	OutcomeNotModbus = "not_modbus"
)

// Function codes acceptés en code prod. Tout autre est suspect — voir
// le linter scripts/check_modbus_probe_no_write.sh.
const (
	fnReadHoldingRegisters byte = 0x03
	fnReadDeviceID         byte = 0x2B
	meiTypeReadDeviceID    byte = 0x0E

	exceptionMask byte = 0x80 // function_code | 0x80 => exception response
)

// Config paramètre la sonde.
type Config struct {
	Port    int
	Timeout time.Duration
	UnitID  byte
}

// Result est la sortie d'un appel à Probe.
type Result struct {
	VendorName         string `json:"vendor_name"`
	ProductCode        string `json:"product_code"`
	MajorMinorRevision string `json:"major_minor_revision"`
	FunctionCode       uint8  `json:"function_code"`
	ExceptionCode      uint8  `json:"exception_code"`
	ExceptionMeaning   string `json:"exception_meaning"`
	IsModbus           bool   `json:"is_modbus"`
	DurationMs         int    `json:"duration_ms"`
	BytesReceived      int    `json:"bytes_received"`
	Outcome            string `json:"outcome"`
}

// Probe ouvre une connexion TCP vers target:port, envoie 1 Read Device
// Identification, puis (en cas d'exception) 1 Read Holding Registers
// fallback. Pas de retry, pas d'énumération. Au plus 2 paquets envoyés.
func Probe(ctx context.Context, target string, cfg Config) (Result, error) {
	cfg = withDefaults(cfg)
	start := time.Now()
	res := Result{Outcome: OutcomeDialError}

	addr := net.JoinHostPort(target, strconv.Itoa(cfg.Port))
	dialer := &net.Dialer{Timeout: cfg.Timeout}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		res.Outcome = classifyDialError(err)
		res.DurationMs = msSince(start)
		return res, nil
	}
	defer conn.Close()

	deadline := time.Now().Add(cfg.Timeout)
	_ = conn.SetDeadline(deadline)

	// Tentative 1 : Read Device Identification.
	resp1, n1, err := sendAndRead(conn, buildReadDeviceID(cfg.UnitID))
	res.BytesReceived += n1
	if err != nil {
		res.Outcome = classifyReadError(err)
		res.DurationMs = msSince(start)
		return res, nil
	}

	fc1, exCode1, body1, perr := parseResponse(resp1)
	if perr != nil {
		res.Outcome = OutcomeNotModbus
		res.DurationMs = msSince(start)
		return res, nil
	}
	res.IsModbus = true
	res.FunctionCode = fc1

	if fc1 == fnReadDeviceID {
		// Réponse positive : extraire vendor/product/revision.
		vendor, product, rev := parseDeviceIDObjects(body1)
		res.VendorName = vendor
		res.ProductCode = product
		res.MajorMinorRevision = rev
		res.Outcome = OutcomeSuccess
		res.DurationMs = msSince(start)
		return res, nil
	}

	// Exception sur Read Device ID → fallback Read Holding Registers.
	if fc1 == (fnReadDeviceID | exceptionMask) {
		res.ExceptionCode = exCode1
		res.ExceptionMeaning = decodeException(exCode1)

		resp2, n2, err := sendAndRead(conn, buildReadHoldingRegisters(cfg.UnitID))
		res.BytesReceived += n2
		if err != nil {
			// Le 2e write/read a échoué mais on a déjà confirmé Modbus
			// via le 1er. Retourne success avec exception info.
			res.Outcome = OutcomeSuccess
			res.DurationMs = msSince(start)
			return res, nil
		}

		fc2, exCode2, _, perr := parseResponse(resp2)
		if perr != nil {
			// Réponse 2 invalide — bizarre mais on garde l'info du 1er.
			res.Outcome = OutcomeSuccess
			res.DurationMs = msSince(start)
			return res, nil
		}
		// Le fallback a réussi : on overwrite le FunctionCode avec celui
		// du 2e échange (qui a "réussi" au sens "réponse non-exception").
		if fc2 == fnReadHoldingRegisters {
			res.FunctionCode = fnReadHoldingRegisters
			res.ExceptionCode = 0
			res.ExceptionMeaning = ""
		} else if fc2 == (fnReadHoldingRegisters | exceptionMask) {
			res.ExceptionCode = exCode2
			res.ExceptionMeaning = decodeException(exCode2)
		}
		res.Outcome = OutcomeSuccess
		res.DurationMs = msSince(start)
		return res, nil
	}

	// Autre function_code : pas Modbus à proprement parler.
	res.Outcome = OutcomeNotModbus
	res.DurationMs = msSince(start)
	return res, nil
}

// buildMBAP construit le préfixe MBAP (7 octets) :
//
//	[2 octets] transaction_id (random)
//	[2 octets] protocol_id = 0
//	[2 octets] length = nombre d'octets qui suivent (unit_id + PDU)
//	[1 octet]  unit_id
func buildMBAP(unitID byte, pduLen int) []byte {
	mbap := make([]byte, 7)
	binary.BigEndian.PutUint16(mbap[0:2], uint16(rand.Intn(0xFFFF))) //nolint:gosec // transaction id, pas sensible
	mbap[2] = 0x00 // protocol_id (hi)
	mbap[3] = 0x00 // protocol_id (lo)
	binary.BigEndian.PutUint16(mbap[4:6], uint16(pduLen+1)) // length = unit_id (1) + PDU
	mbap[6] = unitID
	return mbap
}

// buildReadDeviceID construit le paquet complet pour la fonction
// Read Device Identification (0x2B/0x0E) "basic" stream avec object_id 0.
// PDU = 4 octets : [function | mei_type | read_device_id_code | object_id].
func buildReadDeviceID(unitID byte) []byte {
	pdu := []byte{
		fnReadDeviceID,
		meiTypeReadDeviceID,
		0x01, // read_device_id_code = basic
		0x00, // object_id start = VendorName
	}
	mbap := buildMBAP(unitID, len(pdu))
	return append(mbap, pdu...)
}

// buildReadHoldingRegisters construit le paquet pour la fonction 0x03
// avec starting_address=0 et quantity=1. Read-only ; pas une mutation.
// PDU = 5 octets : [function | starting_address (u16) | quantity (u16)].
func buildReadHoldingRegisters(unitID byte) []byte {
	pdu := []byte{
		fnReadHoldingRegisters,
		0x00, 0x00, // starting_address = 0
		0x00, 0x01, // quantity = 1
	}
	mbap := buildMBAP(unitID, len(pdu))
	return append(mbap, pdu...)
}

// sendAndRead envoie un paquet et lit la réponse complète (MBAP + PDU).
// Retourne le body PDU (function_code + data) sans le MBAP header.
func sendAndRead(conn net.Conn, packet []byte) ([]byte, int, error) {
	if _, err := conn.Write(packet); err != nil {
		return nil, 0, err
	}

	// Lire d'abord les 7 octets MBAP, puis lire `length-1` octets de PDU.
	mbap := make([]byte, 7)
	if _, err := io.ReadFull(conn, mbap); err != nil {
		return nil, 0, err
	}
	bodyLen := int(binary.BigEndian.Uint16(mbap[4:6])) - 1 // length inclut unit_id (1)
	if bodyLen <= 0 || bodyLen > 253 {
		return nil, 7, errors.New("modbusprobe: invalid PDU length")
	}
	body := make([]byte, bodyLen)
	if _, err := io.ReadFull(conn, body); err != nil {
		return nil, 7, err
	}
	return body, 7 + bodyLen, nil
}

// parseResponse parse le PDU body : 1er octet = function_code (avec
// exception bit éventuel), reste = data. Retourne (function_code,
// exception_code, body_after_fc, error).
func parseResponse(body []byte) (byte, byte, []byte, error) {
	if len(body) < 1 {
		return 0, 0, nil, errors.New("modbusprobe: empty body")
	}
	fc := body[0]
	if fc&exceptionMask != 0 {
		// Exception response : 1 octet exception_code après le fc.
		if len(body) < 2 {
			return fc, 0, nil, errors.New("modbusprobe: exception body truncated")
		}
		return fc, body[1], body[2:], nil
	}
	return fc, 0, body[1:], nil
}

// parseDeviceIDObjects extrait vendor_name (object 0), product_code
// (object 1), major_minor_revision (object 2) depuis le body d'une
// réponse Read Device Identification réussie.
//
// Layout du body après le function_code (0x2B) :
//
//	[1] mei_type (0x0E)
//	[1] read_device_id_code (echo de la requête)
//	[1] conformity_level
//	[1] more_follows
//	[1] next_object_id
//	[1] number_of_objects
//	Pour chaque object :
//	  [1] object_id
//	  [1] object_length
//	  [N] object_value (ASCII)
func parseDeviceIDObjects(body []byte) (vendor, product, revision string) {
	if len(body) < 6 {
		return
	}
	// Skip : mei_type, read_device_id_code, conformity_level, more_follows,
	// next_object_id, number_of_objects
	numObjects := int(body[5])
	pos := 6
	for i := 0; i < numObjects && pos+2 <= len(body); i++ {
		objID := body[pos]
		objLen := int(body[pos+1])
		pos += 2
		if pos+objLen > len(body) {
			return
		}
		value := string(body[pos : pos+objLen])
		switch objID {
		case 0x00:
			vendor = value
		case 0x01:
			product = value
		case 0x02:
			revision = value
		}
		pos += objLen
	}
	return
}

// decodeException traduit un exception_code Modbus standard en texte.
// Cf. RFC Modbus Application Protocol V1.1b3 §7.
func decodeException(code byte) string {
	switch code {
	case 0x01:
		return "Illegal Function"
	case 0x02:
		return "Illegal Data Address"
	case 0x03:
		return "Illegal Data Value"
	case 0x04:
		return "Server Device Failure"
	case 0x05:
		return "Acknowledge"
	case 0x06:
		return "Server Device Busy"
	case 0x08:
		return "Memory Parity Error"
	case 0x0A:
		return "Gateway Path Unavailable"
	case 0x0B:
		return "Gateway Target Device Failed to Respond"
	default:
		return "Unknown Exception"
	}
}

func classifyDialError(err error) string {
	if err == nil {
		return OutcomeDialError
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline") {
		return OutcomeTimeout
	}
	return OutcomeDialError
}

func classifyReadError(err error) string {
	if err == nil {
		return OutcomeNotModbus
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return OutcomeTimeout
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline") {
		return OutcomeTimeout
	}
	if strings.Contains(msg, "eof") || strings.Contains(msg, "reset") || strings.Contains(msg, "closed") {
		return OutcomeNotModbus
	}
	return OutcomeNotModbus
}

func withDefaults(cfg Config) Config {
	if cfg.Port == 0 {
		cfg.Port = 502
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
	}
	if cfg.UnitID == 0 {
		cfg.UnitID = 1
	}
	return cfg
}

func msSince(start time.Time) int {
	d := time.Since(start)
	if d < 0 {
		return 0
	}
	return int(d / time.Millisecond)
}
