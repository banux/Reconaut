// SPDX-License-Identifier: AGPL-3.0-only
// Package coapprobe fingerprinte un serveur CoAP (RFC 7252) en lui
// envoyant un seul `GET /.well-known/core` (CoRE Link Format, RFC 6690)
// puis en lisant la réponse pour capturer :
//
//   - le response code (class.detail, par ex. "2.05 Content"),
//   - le content-format (option 12 ; 40 = application/link-format, etc.),
//   - un excerpt du payload (le link-format dump), plafonné à 4 KiB.
//
// Le sondeur N'EFFECTUE AUCUNE mutation (PUT / POST / DELETE), N'OBSERVE
// PAS de ressource, NE FAIT PAS de découverte multicast. Reconaut n'est
// PAS un outil offensif.
//
// Source de vérité :
//
//	openspec/changes/add-coap-probe/specs/scanning/spec.md
//	  -> Requirement: CoAP Discovery Probe
//
// Linter CI : `scripts/check_coap_probe_no_offensive.sh`.
package coapprobe

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
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
	OutcomeNotCoAP   = "not_coap"
)

// CoAP method codes (cf. RFC 7252 §12.1).
// Seul GET (0x01) est utilisé par Reconaut. Les autres sont déclarés
// pour documenter ce qui est *interdit* — leur valeur littérale n'apparaît
// jamais dans le code prod (refusé par le linter).
const (
	methodGET = byte(0x01)
)

// CoAP option numbers (RFC 7252 §12.2).
const (
	optionUriPath       = 11
	optionContentFormat = 12
)

// CoAP Type (4 bits hauts du byte 0 après Ver).
const (
	typeCON = 0 // Confirmable
	// typeNON = 1 ; typeACK = 2 ; typeRST = 3 — non utilisés par le sondeur.
)

// Plafond strict pour l'excerpt du payload (link-format dump).
const maxPayloadExcerpt = 4096

// Config paramètre la sonde.
type Config struct {
	Port    int
	Timeout time.Duration
}

// Result est la sortie d'un appel à Probe.
type Result struct {
	ResponseCodeClass   uint8  `json:"response_code_class"`
	ResponseCodeDetail  uint8  `json:"response_code_detail"`
	ResponseCodeMeaning string `json:"response_code_meaning"`
	ContentFormat       int    `json:"content_format"`
	PayloadExcerpt      string `json:"payload_excerpt"`
	DurationMs          int    `json:"duration_ms"`
	BytesReceived       int    `json:"bytes_received"`
	Outcome             string `json:"outcome"`
}

// Probe ouvre un socket UDP vers target:port, envoie un seul CoAP
// GET /.well-known/core et lit la réponse. Pas de retransmission.
func Probe(ctx context.Context, target string, cfg Config) (Result, error) {
	cfg = withDefaults(cfg)
	start := time.Now()
	res := Result{
		Outcome:       OutcomeDialError,
		ContentFormat: -1,
	}

	// Garde de runtime : refuse les targets multicast. Un sondeur ASM
	// ne doit JAMAIS broadcast une requête à `all-CoAP-nodes`.
	if isMulticastTarget(target) {
		res.Outcome = OutcomeDialError
		res.DurationMs = msSince(start)
		return res, errors.New("coapprobe: multicast target refused")
	}

	addr := net.JoinHostPort(target, strconv.Itoa(cfg.Port))
	raddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		res.Outcome = OutcomeDialError
		res.DurationMs = msSince(start)
		return res, nil
	}
	conn, err := net.DialUDP("udp", nil, raddr)
	if err != nil {
		res.Outcome = classifyDialError(err)
		res.DurationMs = msSince(start)
		return res, nil
	}
	defer conn.Close()

	deadline := time.Now().Add(cfg.Timeout)
	_ = conn.SetDeadline(deadline)

	pkt, err := buildGetWellKnownCore()
	if err != nil {
		res.Outcome = OutcomeDialError
		res.DurationMs = msSince(start)
		return res, nil
	}
	if _, werr := conn.Write(pkt); werr != nil {
		res.Outcome = classifyDialError(werr)
		res.DurationMs = msSince(start)
		return res, nil
	}

	buf := make([]byte, 65535) // max UDP datagram
	n, _, rerr := conn.ReadFromUDP(buf)
	res.BytesReceived = n
	if rerr != nil {
		res.Outcome = classifyReadError(rerr)
		res.DurationMs = msSince(start)
		return res, nil
	}

	if perr := parseResponse(buf[:n], &res); perr != nil {
		res.Outcome = OutcomeNotCoAP
		res.DurationMs = msSince(start)
		return res, nil
	}
	res.Outcome = OutcomeSuccess
	res.DurationMs = msSince(start)
	return res, nil
}

// buildGetWellKnownCore construit le paquet CoAP :
//
//	byte 0 : Ver(2)=01 | Type(2)=00 (CON) | TKL(4)=2  → 0x42
//	byte 1 : Code = 0x01 (GET)
//	bytes 2-3 : Message ID (random uint16, big-endian)
//	bytes 4-5 : Token (2 random bytes)
//	Options :
//	  - Uri-Path "well-known" (delta=11, len=10) → header 0xBA + bytes
//	  - Uri-Path "core"        (delta=0,  len=4) → header 0x04 + bytes
//
// Pas de payload (donc pas de marker 0xFF).
func buildGetWellKnownCore() ([]byte, error) {
	var rnd [4]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return nil, fmt.Errorf("coapprobe: rand: %w", err)
	}
	msgID := binary.BigEndian.Uint16(rnd[:2])
	token := rnd[2:4]

	pkt := make([]byte, 0, 32)
	// Header byte 0 : Ver=01, Type=00 (CON), TKL=2 → 01 00 0010 = 0x42
	pkt = append(pkt, 0x42)
	// Code : GET
	pkt = append(pkt, methodGET)
	// Message ID
	pkt = appendUint16(pkt, msgID)
	// Token
	pkt = append(pkt, token...)
	// Uri-Path "well-known"
	pkt = appendUriPathOption(pkt, "well-known", 11) // delta from 0 = 11
	// Uri-Path "core"
	pkt = appendUriPathOption(pkt, "core", 0) // delta from previous = 0
	return pkt, nil
}

// appendUriPathOption sérialise une option Uri-Path (number 11) avec
// la forme simple (delta < 13, length < 13). Suffisant pour les
// segments standards de `/.well-known/core`.
func appendUriPathOption(buf []byte, value string, delta int) []byte {
	if len(value) >= 13 || delta >= 13 {
		// Cas non géré en v1 — les segments de well-known/core sont
		// tous < 13 chars. On retombe sur la forme simple en tronquant
		// (sera détecté en test si on dépasse).
	}
	hdr := byte((delta << 4) | (len(value) & 0x0F))
	buf = append(buf, hdr)
	buf = append(buf, []byte(value)...)
	return buf
}

// parseResponse extrait du buffer un response code, un content-format
// et un payload excerpt. Met à jour res en place. Retourne une erreur
// si le format est manifestement invalide.
func parseResponse(buf []byte, res *Result) error {
	if len(buf) < 4 {
		return errors.New("response too short")
	}
	// byte 0 : version + type + TKL
	ver := (buf[0] >> 6) & 0x03
	if ver != 0x01 {
		return fmt.Errorf("unexpected CoAP version: %d", ver)
	}
	tkl := int(buf[0] & 0x0F)
	if tkl > 8 {
		return fmt.Errorf("invalid TKL: %d", tkl)
	}
	// byte 1 : Code = class(3 bits hauts) | detail(5 bits)
	code := buf[1]
	res.ResponseCodeClass = (code >> 5) & 0x07
	res.ResponseCodeDetail = code & 0x1F
	res.ResponseCodeMeaning = decodeCode(res.ResponseCodeClass, res.ResponseCodeDetail)

	// Skip header (4 bytes) + token (TKL bytes).
	pos := 4 + tkl
	if pos > len(buf) {
		return errors.New("token truncated")
	}

	// Parse options : on cherche Content-Format (12). Les autres sont
	// ignorées en v1. Boucle jusqu'au marker 0xFF (début payload) ou
	// fin du buffer.
	optNumber := 0
	for pos < len(buf) {
		b := buf[pos]
		if b == 0xFF {
			// Marker payload — saute et capture l'excerpt.
			pos++
			payload := buf[pos:]
			if len(payload) > maxPayloadExcerpt {
				payload = payload[:maxPayloadExcerpt]
			}
			res.PayloadExcerpt = string(payload)
			return nil
		}
		delta := int(b >> 4)
		length := int(b & 0x0F)
		pos++
		// Extension de delta : on ne supporte pas les formes 13/14 en
		// v1 (notre serveur de test n'en émet pas). Si on rencontre,
		// on s'arrête prudemment.
		if delta >= 13 || length >= 13 {
			return errors.New("extended option delta/length not supported")
		}
		optNumber += delta
		if pos+length > len(buf) {
			return errors.New("option truncated")
		}
		value := buf[pos : pos+length]
		pos += length

		if optNumber == optionContentFormat {
			res.ContentFormat = decodeUintOption(value)
		}
	}
	// Pas de payload marker rencontré — c'est OK, juste pas de body.
	return nil
}

// decodeUintOption interprète la valeur d'option (0-4 octets) comme
// un uint big-endian, conforme à RFC 7252 §3.2.
func decodeUintOption(v []byte) int {
	out := 0
	for _, b := range v {
		out = (out << 8) | int(b)
	}
	return out
}

// decodeCode traduit (class, detail) en chaîne "X.YY Meaning".
// Les codes couverts sont les plus courants ; les inconnus sont juste
// formattés sans label.
func decodeCode(class, detail uint8) string {
	prefix := fmt.Sprintf("%d.%02d", class, detail)
	switch {
	case class == 2 && detail == 5:
		return prefix + " Content"
	case class == 2 && detail == 3:
		return prefix + " Valid"
	case class == 2 && detail == 4:
		return prefix + " Changed"
	case class == 2 && detail == 1:
		return prefix + " Created"
	case class == 4 && detail == 0:
		return prefix + " Bad Request"
	case class == 4 && detail == 1:
		return prefix + " Unauthorized"
	case class == 4 && detail == 3:
		return prefix + " Forbidden"
	case class == 4 && detail == 4:
		return prefix + " Not Found"
	case class == 4 && detail == 5:
		return prefix + " Method Not Allowed"
	case class == 5 && detail == 0:
		return prefix + " Internal Server Error"
	case class == 5 && detail == 1:
		return prefix + " Not Implemented"
	case class == 5 && detail == 3:
		return prefix + " Service Unavailable"
	default:
		return prefix
	}
}

// isMulticastTarget rejette les IP/host multicast. Garde runtime
// alignée sur le linter statique.
func isMulticastTarget(target string) bool {
	ip := net.ParseIP(target)
	if ip == nil {
		return false
	}
	return ip.IsMulticast()
}

func appendUint16(buf []byte, v uint16) []byte {
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, v)
	return append(buf, b...)
}

func classifyDialError(err error) string {
	if err == nil {
		return OutcomeDialError
	}
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline"):
		return OutcomeTimeout
	default:
		return OutcomeDialError
	}
}

func classifyReadError(err error) string {
	if err == nil {
		return OutcomeNotCoAP
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return OutcomeTimeout
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline") {
		return OutcomeTimeout
	}
	if strings.Contains(msg, "refused") || strings.Contains(msg, "unreachable") {
		return OutcomeDialError
	}
	return OutcomeNotCoAP
}

func withDefaults(cfg Config) Config {
	if cfg.Port == 0 {
		cfg.Port = 5683
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
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
