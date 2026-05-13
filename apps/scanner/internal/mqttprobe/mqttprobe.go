// SPDX-License-Identifier: AGPL-3.0-only
// Package mqttprobe fingerprinte un broker MQTT :
//
//   - envoie un paquet CONNECT MQTT 3.1.1 sans aucun credential ;
//   - lit le CONNACK pour récupérer protocol_level + return_code +
//     session_present ;
//   - si port 8883 ou TryTLSUpgrade=true, fait d'abord un handshake
//     TLS InsecureSkipVerify pour capturer le cert (avant le CONNECT
//     qui passera alors dans le canal TLS) ;
//   - envoie un DISCONNECT propre puis ferme TCP.
//
// Le sondeur n'envoie JAMAIS de PUBLISH / SUBSCRIBE / UNSUBSCRIBE /
// PINGREQ, ni d'username / password / Will. Reconaut n'est PAS un
// outil de bruteforce ni d'écoute de topics utilisateurs.
//
// Source de vérité :
//
//	openspec/changes/add-mqtt-probe/specs/scanning/spec.md
//	  -> Requirement: MQTT Broker Probe
//
// Linter CI : `scripts/check_mqtt_probe_no_auth.sh`.
package mqttprobe

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
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
	OutcomeNotMQTT   = "not_mqtt"
	OutcomeTLSError  = "tls_error"
)

// MQTT 3.1.1 paquet types (4 bits hauts du premier octet).
const (
	pktConnect    = 0x10
	pktConnack    = 0x20
	pktDisconnect = 0xE0
	protocolLevel = 0x04 // MQTT 3.1.1
)

// Connect flags bits (cf. [MQTT-3.1.1] 3.1.2.3).
const (
	flagCleanSession = 0x02
	// Les bits Will (0x04, 0x18, 0x20), Password (0x40), Username (0x80)
	// DOIVENT rester à 0 — interdiction porteuse du contrat anti-auth.
)

// Config paramètre la sonde.
type Config struct {
	Port          int
	Timeout       time.Duration
	TryTLSUpgrade bool
	ClientID      string
}

// Result est la sortie d'un appel à Probe.
type Result struct {
	ProtocolLevel     uint8    `json:"protocol_level"`
	ReturnCode        uint8    `json:"return_code"`
	ReturnCodeMeaning string   `json:"return_code_meaning"`
	SessionPresent    bool     `json:"session_present"`
	TLSCertSHA256     string   `json:"tls_cert_sha256"`
	TLSSANs           []string `json:"tls_sans"`
	TLSNotAfter       string   `json:"tls_not_after"`
	DurationMs        int      `json:"duration_ms"`
	BytesReceived     int      `json:"bytes_received"`
	Outcome           string   `json:"outcome"`
}

// Probe ouvre une connexion TCP (avec TLS si demandé) vers target,
// envoie un MQTT CONNECT puis lit le CONNACK. Le sondeur se déconnecte
// proprement (DISCONNECT) et ferme la connexion.
func Probe(ctx context.Context, target string, cfg Config) (Result, error) {
	cfg = withDefaults(cfg)
	start := time.Now()
	res := Result{
		Outcome: OutcomeDialError,
		TLSSANs: []string{},
	}

	addr := net.JoinHostPort(target, strconv.Itoa(cfg.Port))

	dialer := &net.Dialer{Timeout: cfg.Timeout}
	rawConn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		res.Outcome = classifyDialError(err)
		res.DurationMs = msSince(start)
		return res, nil
	}
	defer rawConn.Close()

	deadline := time.Now().Add(cfg.Timeout)
	_ = rawConn.SetDeadline(deadline)

	// TLS upgrade conditionnel : activé sur port 8883 par défaut, ou
	// si TryTLSUpgrade explicitement true.
	var conn net.Conn = rawConn
	if shouldUseTLS(cfg) {
		tlsConn := tls.Client(rawConn, &tls.Config{
			InsecureSkipVerify: true, //nolint:gosec // cert capture only, validation côté Rails
			ServerName:         target,
		})
		hsCtx, cancel := context.WithDeadline(ctx, deadline)
		if herr := tlsConn.HandshakeContext(hsCtx); herr != nil {
			cancel()
			res.Outcome = OutcomeTLSError
			res.DurationMs = msSince(start)
			return res, nil
		}
		cancel()
		state := tlsConn.ConnectionState()
		if len(state.PeerCertificates) > 0 {
			leaf := state.PeerCertificates[0]
			sum := sha256.Sum256(leaf.Raw)
			res.TLSCertSHA256 = "sha256:" + hex.EncodeToString(sum[:])
			res.TLSSANs = append(res.TLSSANs, leaf.DNSNames...)
			if !leaf.NotAfter.IsZero() {
				res.TLSNotAfter = leaf.NotAfter.UTC().Format(time.RFC3339)
			}
		}
		conn = tlsConn
	}

	// 1. Construire et envoyer CONNECT.
	connectPkt := buildConnect(cfg.ClientID)
	if _, werr := conn.Write(connectPkt); werr != nil {
		res.Outcome = classifyWriteError(werr)
		res.DurationMs = msSince(start)
		return res, nil
	}

	// 2. Lire CONNACK : 4 octets fixes.
	connack := make([]byte, 4)
	n, rerr := io.ReadFull(conn, connack)
	res.BytesReceived = n
	if rerr != nil {
		res.Outcome = classifyReadError(rerr)
		res.DurationMs = msSince(start)
		return res, nil
	}

	// CONNACK : byte[0]=0x20, byte[1]=0x02, byte[2]=session_present,
	// byte[3]=return_code.
	if connack[0] != pktConnack || connack[1] != 0x02 {
		res.Outcome = OutcomeNotMQTT
		res.DurationMs = msSince(start)
		return res, nil
	}
	res.ProtocolLevel = protocolLevel
	res.SessionPresent = (connack[2] & 0x01) == 0x01
	res.ReturnCode = connack[3]
	res.ReturnCodeMeaning = decodeReturnCode(connack[3])
	res.Outcome = OutcomeSuccess

	// 3. DISCONNECT propre (trame `0xE0 0x00`). Best-effort — si
	// l'écriture échoue, on ignore (la connexion est sur le point de
	// se fermer de toute façon).
	_, _ = conn.Write([]byte{pktDisconnect, 0x00})

	res.DurationMs = msSince(start)
	return res, nil
}

// buildConnect construit le paquet MQTT CONNECT 3.1.1 :
//
//	Fixed header : 0x10 + remaining_length (variable, max 5 bytes)
//	Variable header :
//	  - protocol name : u16 length + "MQTT"
//	  - protocol level : 0x04
//	  - connect flags : 0x02 (clean session only ; PAS d'username/password)
//	  - keep alive : u16 (60 secondes)
//	Payload :
//	  - client_id : u16 length + bytes (vide accepté en 3.1.1 si clean_session=1)
func buildConnect(clientID string) []byte {
	// Variable header
	varHeader := []byte{}
	varHeader = appendString(varHeader, "MQTT")
	varHeader = append(varHeader, protocolLevel)
	varHeader = append(varHeader, flagCleanSession)
	varHeader = appendUint16(varHeader, 60) // keep alive 60s

	// Payload : client_id seul (pas de will, pas d'username, pas de password)
	payload := appendString(nil, clientID)

	body := append(varHeader, payload...)

	out := []byte{pktConnect}
	out = append(out, encodeRemainingLength(len(body))...)
	out = append(out, body...)
	return out
}

// encodeRemainingLength encode la longueur restante en variable byte
// integer MQTT (1 à 4 octets selon la valeur).
func encodeRemainingLength(n int) []byte {
	out := []byte{}
	for {
		b := byte(n % 128)
		n /= 128
		if n > 0 {
			b |= 0x80
		}
		out = append(out, b)
		if n == 0 {
			break
		}
	}
	return out
}

func appendString(buf []byte, s string) []byte {
	buf = appendUint16(buf, uint16(len(s)))
	buf = append(buf, []byte(s)...)
	return buf
}

func appendUint16(buf []byte, v uint16) []byte {
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, v)
	return append(buf, b...)
}

// decodeReturnCode traduit le return_code CONNACK 3.1.1.
// Cf. [MQTT-3.1.1] 3.2.2.3.
func decodeReturnCode(rc uint8) string {
	switch rc {
	case 0:
		return "accepted"
	case 1:
		return "unacceptable_protocol_version"
	case 2:
		return "identifier_rejected"
	case 3:
		return "server_unavailable"
	case 4:
		return "bad_username_or_password"
	case 5:
		return "not_authorized"
	default:
		return "unknown"
	}
}

func shouldUseTLS(cfg Config) bool {
	if cfg.TryTLSUpgrade {
		return true
	}
	return cfg.Port == 8883
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

func classifyWriteError(err error) string {
	if err == nil {
		return OutcomeDialError
	}
	if errors.Is(err, io.EOF) {
		return OutcomeNotMQTT
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline") {
		return OutcomeTimeout
	}
	return OutcomeDialError
}

func classifyReadError(err error) string {
	if err == nil {
		return OutcomeNotMQTT
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return OutcomeTimeout
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline") {
		return OutcomeTimeout
	}
	if strings.Contains(msg, "eof") || strings.Contains(msg, "closed") || strings.Contains(msg, "reset") {
		return OutcomeNotMQTT
	}
	return OutcomeNotMQTT
}

func withDefaults(cfg Config) Config {
	if cfg.Port == 0 {
		cfg.Port = 1883
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
	}
	// ClientID par défaut : vide. Le broker doit en assigner un s'il
	// accepte (3.1.1 §3.1.3.1). Choix neutre, non-identifiant.
	return cfg
}

func msSince(start time.Time) int {
	d := time.Since(start)
	if d < 0 {
		return 0
	}
	return int(d / time.Millisecond)
}
