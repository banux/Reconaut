// SPDX-License-Identifier: AGPL-3.0-only
// Package rdpprobe fingerprinte un service RDP sur TCP/3389 :
//
//   - envoie un X.224 Connection Request portant un RDP Negotiation
//     Request (type 0x01) avec requestedProtocols = RDP|SSL|HYBRID|
//     RDSTLS|HYBRID_EX ;
//   - lit le X.224 Connection Confirm + parse le RDP Negotiation
//     Response (type 0x02) ou RDP Negotiation Failure (type 0x03) ;
//   - si PROTOCOL_SSL est annoncé ET TryTLSUpgrade=true, fait un
//     handshake TLS InsecureSkipVerify pour capturer le certificat
//     serveur (SHA-256, SANs, NotAfter) ;
//   - **referme immédiatement** la connexion.
//
// Le sondeur n'envoie JAMAIS de message MCS (Connect-Initial, Erect
// Domain Request, etc.), aucun PDU, aucun credential (password / NTLM
// / Kerberos / CredSSP). Reconaut n'est PAS un outil de bruteforce.
//
// Source de vérité :
//
//	openspec/changes/add-rdp-probe/specs/scanning/spec.md
//	  -> Requirement: RDP Banner and TLS Capture
//
// Linter CI : `scripts/check_rdp_probe_no_auth.sh` refuse tout
// pattern lié à l'auth (password, credential, NTLM, kerberos, etc.)
// dans ce package.
package rdpprobe

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

// Outcome enumère les issues possibles d'une sonde.
const (
	OutcomeSuccess            = "success"
	OutcomeTimeout            = "timeout"
	OutcomeDialError          = "dial_error"
	OutcomeNotRDP             = "not_rdp"
	OutcomeNegotiationFailure = "negotiation_failure"
	OutcomeTLSError           = "tls_error"
)

// RDP Negotiation Request/Response : RFC-équivalent
// [MS-RDPBCGR] 2.2.1.1.1 (Request) / 2.2.1.2.1 (Response).
const (
	negTypeRequest = 0x01
	negTypeRespOK  = 0x02
	negTypeFailure = 0x03

	flagProtocolRDP       uint32 = 0x00000000 // historique, "Standard RDP Security"
	flagProtocolSSL       uint32 = 0x00000001
	flagProtocolHybrid    uint32 = 0x00000002
	flagProtocolRDSTLS    uint32 = 0x00000004
	flagProtocolHybridEx  uint32 = 0x00000008
	flagProtocolRDSAAD    uint32 = 0x00000010
	requestedProtocolMask        = flagProtocolSSL | flagProtocolHybrid | flagProtocolRDSTLS | flagProtocolHybridEx
)

// Config paramètre la sonde.
type Config struct {
	// Port TCP cible. Défaut 3389 si zéro.
	Port int
	// Timeout total de la sonde (dial + X.224 + éventuel TLS). Défaut 5s.
	Timeout time.Duration
	// TryTLSUpgrade active la capture du cert si la cible annonce
	// PROTOCOL_SSL. Défaut true.
	TryTLSUpgrade bool
	// Cookie envoyé dans le RDP Negotiation Request (champ "Cookie: ..."
	// avant le type byte 0x01). Défaut "mstshash=" (chaîne neutre,
	// non identifiante). Un opérateur peut surcharger via env si
	// nécessaire.
	Cookie string
	// SkipTLSUpgradeEvenIfRequested force le no-upgrade. Utilisé en
	// test (override prioritaire sur TryTLSUpgrade).
	skipTLSUpgrade bool
}

// Result est la sortie d'un appel à Probe.
type Result struct {
	ProtocolVersion        uint32   `json:"protocol_version"`
	SecurityFlags          []string `json:"security_flags"`
	NegotiationFailureCode uint32   `json:"negotiation_failure_code"`
	TLSCertSHA256          string   `json:"tls_cert_sha256"`
	TLSSANs                []string `json:"tls_sans"`
	TLSNotAfter            string   `json:"tls_not_after"`
	DurationMs             int      `json:"duration_ms"`
	BytesReceived          int      `json:"bytes_received"`
	Outcome                string   `json:"outcome"`
}

// Probe ouvre une connexion TCP vers target sur cfg.Port (défaut 3389),
// envoie un X.224 Connection Request + RDP Negotiation Request, lit la
// réponse et, si PROTOCOL_SSL est annoncé, capture le cert TLS sans
// jamais envoyer de phase MCS / auth. La cible est supposée déjà
// validée par le scope-driven enforcement côté Rails — Probe ne re-
// vérifie pas.
func Probe(ctx context.Context, target string, cfg Config) (Result, error) {
	cfg = withDefaults(cfg)
	start := time.Now()
	res := Result{
		Outcome:       OutcomeDialError,
		SecurityFlags: []string{},
		TLSSANs:       []string{},
	}

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

	// 1. X.224 Connection Request + RDP Negotiation Request.
	reqPkt := buildConnectionRequest(cfg.Cookie, requestedProtocolMask)
	if _, werr := conn.Write(reqPkt); werr != nil {
		res.Outcome = classifyWriteError(werr)
		res.DurationMs = msSince(start)
		return res, nil
	}

	// 2. Lecture de la réponse X.224 Connection Confirm.
	// On lit directement depuis conn (pas via bufio) pour ne laisser
	// AUCUN byte tamponné — sinon le TLS upgrade côté client ratera
	// des bytes du ClientHello/ServerHello.
	confirm, n, rerr := readTPKT(conn)
	res.BytesReceived = n
	if rerr != nil {
		res.Outcome = classifyReadError(rerr)
		res.DurationMs = msSince(start)
		return res, nil
	}

	negType, protoVer, flags, failCode, perr := parseConnectionConfirm(confirm)
	if perr != nil {
		// Le port a répondu mais pas avec une trame X.224 valide :
		// service non-RDP (HTTP, raw, etc.).
		res.Outcome = OutcomeNotRDP
		res.DurationMs = msSince(start)
		return res, nil
	}

	switch negType {
	case negTypeRespOK:
		res.ProtocolVersion = protoVer
		res.SecurityFlags = decodeSecurityFlags(flags)
	case negTypeFailure:
		res.NegotiationFailureCode = failCode
		res.Outcome = OutcomeNegotiationFailure
		res.DurationMs = msSince(start)
		return res, nil
	default:
		// Trame X.224 valide mais sans Negotiation Response/Failure : pas vraiment RDP.
		res.Outcome = OutcomeNotRDP
		res.DurationMs = msSince(start)
		return res, nil
	}

	// 3. TLS upgrade opt-in pour capturer le cert.
	if cfg.TryTLSUpgrade && !cfg.skipTLSUpgrade && (flags&flagProtocolSSL) != 0 {
		tlsConn := tls.Client(conn, &tls.Config{
			InsecureSkipVerify: true, //nolint:gosec // cert capture only, validation côté Rails
			ServerName:         target,
		})
		// On utilise HandshakeContext pour respecter le deadline restant.
		hsCtx, cancel := context.WithDeadline(ctx, deadline)
		defer cancel()
		if herr := tlsConn.HandshakeContext(hsCtx); herr != nil {
			res.Outcome = OutcomeTLSError
			res.DurationMs = msSince(start)
			return res, nil
		}
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
		// On ferme proprement le canal TLS (CloseNotify) puis la TCP
		// — défer fermera la conn underneath.
		_ = tlsConn.CloseWrite()
	}

	res.Outcome = OutcomeSuccess
	res.DurationMs = msSince(start)
	return res, nil
}

// buildConnectionRequest construit la trame complète à envoyer :
//
//	TPKT header (4 octets) : 0x03 0x00 <total_len:u16-be>
//	X.224 CR TPDU (7 octets) : <len> 0xE0 0x00 0x00 0x00 0x00 0x00
//	"Cookie: <value>\r\n"
//	RDP Negotiation Request (8 octets) :
//	   0x01 0x00 0x08 0x00 <requestedProtocols:u32-le>
//
// Le X.224 length = len(TPDU bytes) - 1 (sans compter le byte length
// lui-même), donc 6 + len(cookie_chunk) + 8 - 1 = 13 + len(cookie_chunk).
func buildConnectionRequest(cookie string, requestedProtocols uint32) []byte {
	cookieChunk := []byte("Cookie: " + cookie + "\r\n")

	negReq := make([]byte, 8)
	negReq[0] = negTypeRequest // type
	negReq[1] = 0x00           // flags
	binary.LittleEndian.PutUint16(negReq[2:4], 8) // length (8)
	binary.LittleEndian.PutUint32(negReq[4:8], requestedProtocols)

	x224 := make([]byte, 0, 7+len(cookieChunk)+len(negReq))
	// X.224 CR : len|0xE0|destRef:u16|srcRef:u16|class:u8
	x224 = append(x224, 0x00) // length placeholder (patched below)
	x224 = append(x224, 0xE0) // X.224 type CR
	x224 = append(x224, 0x00, 0x00) // destRef
	x224 = append(x224, 0x00, 0x00) // srcRef
	x224 = append(x224, 0x00)       // class
	x224 = append(x224, cookieChunk...)
	x224 = append(x224, negReq...)
	x224[0] = byte(len(x224) - 1) // X.224 length = TPDU bytes excluding the length field itself

	totalLen := 4 + len(x224)
	out := make([]byte, 4, totalLen)
	out[0] = 0x03 // TPKT version
	out[1] = 0x00 // reserved
	binary.BigEndian.PutUint16(out[2:4], uint16(totalLen))
	out = append(out, x224...)
	return out
}

// readTPKT lit une trame TPKT complète à partir du reader.
// Retourne le payload (après le header de 4 octets), le nombre d'octets
// lus au total et une éventuelle erreur. On lit byte-stream sans
// bufferer en avance pour ne pas perdre de données du flux post-X.224
// (typiquement le ServerHello qui suit un TLS upgrade).
func readTPKT(r io.Reader) ([]byte, int, error) {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, 0, err
	}
	if hdr[0] != 0x03 {
		return nil, 4, fmt.Errorf("not_tpkt: version=%#x", hdr[0])
	}
	total := int(binary.BigEndian.Uint16(hdr[2:4]))
	if total < 4 || total > 65535 {
		return nil, 4, fmt.Errorf("not_tpkt: total_len=%d", total)
	}
	body := make([]byte, total-4)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, 4, err
	}
	return body, total, nil
}

// parseConnectionConfirm interprète le body X.224 CC qui suit le
// header TPKT. Format attendu :
//
//	X.224 CC : <len:u8> 0xD0 <destRef:u16> <srcRef:u16> <class:u8>
//	RDP Negotiation Response OU Failure : 8 octets
//	  - Response (type 0x02) : 0x02 <flags:u8> 0x08 0x00 <selectedProto:u32-le>
//	  - Failure  (type 0x03) : 0x03 <flags:u8> 0x08 0x00 <failureCode:u32-le>
func parseConnectionConfirm(body []byte) (negType byte, protoVer uint32, flags uint32, failCode uint32, err error) {
	if len(body) < 7 {
		return 0, 0, 0, 0, errors.New("body_too_short")
	}
	// body[0] = X.224 length, body[1] = X.224 type (CC = 0xD0)
	if body[1] != 0xD0 {
		return 0, 0, 0, 0, fmt.Errorf("not_x224_cc: type=%#x", body[1])
	}
	// On saute le header X.224 CC (7 octets).
	tail := body[7:]
	if len(tail) < 8 {
		// Pas de Negotiation Response/Failure : c'est un X.224 CC nu,
		// rare mais valide ; on retourne un type "vide" pour qu'en
		// haut on classe en not_rdp.
		return 0, 0, 0, 0, nil
	}
	negType = tail[0]
	switch negType {
	case negTypeRespOK:
		flags = uint32(tail[1])
		// tail[2:4] = length (0x0008), tail[4:8] = selectedProtocols
		protoVer = binary.LittleEndian.Uint32(tail[4:8])
		return negTypeRespOK, protoVer, protoVer, 0, nil
	case negTypeFailure:
		failCode = binary.LittleEndian.Uint32(tail[4:8])
		return negTypeFailure, 0, 0, failCode, nil
	default:
		return negType, 0, 0, 0, nil
	}
}

// decodeSecurityFlags traduit le bitmask selectedProtocols en chaînes
// lisibles. Les bits sont définis par [MS-RDPBCGR] 2.2.1.2.1.
func decodeSecurityFlags(flags uint32) []string {
	out := []string{}
	if flags == 0 {
		// Tous les bits éteints = "Standard RDP Security" (PROTOCOL_RDP).
		out = append(out, "PROTOCOL_RDP")
		return out
	}
	if flags&flagProtocolSSL != 0 {
		out = append(out, "PROTOCOL_SSL")
	}
	if flags&flagProtocolHybrid != 0 {
		out = append(out, "PROTOCOL_HYBRID")
	}
	if flags&flagProtocolRDSTLS != 0 {
		out = append(out, "PROTOCOL_RDSTLS")
	}
	if flags&flagProtocolHybridEx != 0 {
		out = append(out, "PROTOCOL_HYBRID_EX")
	}
	if flags&flagProtocolRDSAAD != 0 {
		out = append(out, "PROTOCOL_RDSAAD")
	}
	return out
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

func classifyWriteError(err error) string {
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
		return OutcomeNotRDP
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return OutcomeTimeout
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline") {
		return OutcomeTimeout
	}
	if strings.Contains(msg, "eof") || strings.Contains(msg, "closed") || strings.Contains(msg, "reset") {
		return OutcomeNotRDP
	}
	return OutcomeNotRDP
}

func withDefaults(cfg Config) Config {
	if cfg.Port == 0 {
		cfg.Port = 3389
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
	}
	if cfg.Cookie == "" {
		// Cookie standard d'un client RDC qui n'a pas encore négocié de
		// nom : non identifiant, ne mime aucun compte légitime.
		cfg.Cookie = "mstshash="
	}
	// TryTLSUpgrade : on n'a pas de way safe de distinguer "non défini"
	// de "false" sur un bool en Go. On documente "défaut true" → si le
	// caller veut désactiver, il met explicitement false. À l'appel
	// depuis main(), main() lit l'env et fixe le bool.
	return cfg
}

func msSince(start time.Time) int {
	d := time.Since(start)
	if d < 0 {
		return 0
	}
	return int(d / time.Millisecond)
}
