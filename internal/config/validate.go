package config

import (
	"crypto/ecdh"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/netip"
	"os"
	"strings"
	"unicode/utf8"
)

type Validated struct {
	Config            *Config
	RealityPrivateKey string
}

func Validate(c *Config) (*Validated, error) {
	if c == nil {
		return nil, fieldError("config", "is nil", "provide a schema_version 1 config")
	}
	if c.SchemaVersion != SchemaVersion {
		return nil, fieldError("schema_version", fmt.Sprintf("must equal %d", SchemaVersion), "set schema_version to 1")
	}
	if level := c.LogLevel(); level != "warn" && level != "error" {
		return nil, fieldError("log.level", "must be warn or error", "set log.level to warn or error")
	}
	if c.VLESSReality == nil && c.Hysteria2 == nil && c.AnyTLS == nil {
		return nil, fieldError("config", "at least one protocol is required", "add vless_reality, hysteria2, or anytls")
	}

	validated := &Validated{Config: c}
	ports := make(map[int]string, 2)
	credentials := make(map[string]string, 2)
	if c.VLESSReality != nil {
		privateKey, err := validateVLESSReality(c.VLESSReality, ports, credentials)
		if err != nil {
			return nil, err
		}
		validated.RealityPrivateKey = privateKey
	}
	if c.Hysteria2 != nil {
		if err := validateHysteria2(c.Hysteria2, ports, credentials); err != nil {
			return nil, err
		}
	}
	if c.AnyTLS != nil {
		if err := validateAnyTLS(c.AnyTLS, ports, credentials); err != nil {
			return nil, err
		}
	}
	return validated, nil
}

func validateVLESSReality(c *VLESSRealityConfig, ports map[int]string, credentials map[string]string) (string, error) {
	if err := validateListen("vless_reality.listen", c.Listen); err != nil {
		return "", err
	}
	if err := validatePort("vless_reality.port", c.Port, 1024, 65535, ports); err != nil {
		return "", err
	}
	if !validUUID(c.UUID) {
		return "", fieldError("vless_reality.uuid", "is not a valid canonical UUID", "use a UUID in 8-4-4-4-12 form")
	}
	if err := uniqueCredential("vless_reality.uuid", c.UUID, credentials); err != nil {
		return "", err
	}
	if c.PrivateKeyPath == "" {
		return "", fieldError("vless_reality.private_key_path", "is empty", "provide a local Reality private key file")
	}
	if err := checkFile(c.PrivateKeyPath, filePrivateKey); err != nil {
		return "", fieldError("vless_reality.private_key_path", err.Error(), "use a secure readable private-key file")
	}
	privateKey, err := readRealityPrivateKey(c.PrivateKeyPath)
	if err != nil {
		return "", err
	}
	shortID, err := hex.DecodeString(c.ShortID)
	if err != nil || len(shortID) != 8 || len(c.ShortID) != 16 {
		return "", fieldError("vless_reality.short_id", "must be exactly 16 hexadecimal characters", "generate an 8-byte short ID")
	}
	if !validDNSName(c.ServerName) || isIPAddress(c.ServerName) {
		return "", fieldError("vless_reality.server_name", "is not a valid DNS name", "use a DNS hostname, not an IP address")
	}
	if !validDNSName(c.HandshakeServer) && !isIPAddress(c.HandshakeServer) {
		return "", fieldError("vless_reality.handshake_server", "is not a valid DNS name or IP literal", "use a hostname or IP address")
	}
	if c.HandshakePort < 1 || c.HandshakePort > 65535 {
		return "", fieldError("vless_reality.handshake_port", "must be in range 1-65535", "choose a valid TCP port")
	}
	return privateKey, nil
}

func validateHysteria2(c *Hysteria2Config, ports map[int]string, credentials map[string]string) error {
	if err := validateListen("hysteria2.listen", c.Listen); err != nil {
		return err
	}
	if err := validatePort("hysteria2.port", c.Port, 1024, 65535, ports); err != nil {
		return err
	}
	if utf8.RuneCountInString(c.Password) < 16 {
		return fieldError("hysteria2.password", "must contain at least 16 characters", "generate a cryptographically random password")
	}
	if err := uniqueCredential("hysteria2.password", c.Password, credentials); err != nil {
		return err
	}
	if err := validateBandwidth("hysteria2.up_mbps", c.UpMbps); err != nil {
		return err
	}
	if err := validateBandwidth("hysteria2.down_mbps", c.DownMbps); err != nil {
		return err
	}
	return validateTLSFiles("hysteria2", c.CertificatePath, c.KeyPath)
}

func validateAnyTLS(c *AnyTLSConfig, ports map[int]string, credentials map[string]string) error {
	if err := validateListen("anytls.listen", c.Listen); err != nil {
		return err
	}
	if err := validatePort("anytls.port", c.Port, 1024, 65535, ports); err != nil {
		return err
	}
	if utf8.RuneCountInString(c.Password) < 16 {
		return fieldError("anytls.password", "must contain at least 16 characters", "generate a cryptographically random password")
	}
	if err := uniqueCredential("anytls.password", c.Password, credentials); err != nil {
		return err
	}
	return validateTLSFiles("anytls", c.CertificatePath, c.KeyPath)
}

func validateListen(path, value string) error {
	if _, err := netip.ParseAddr(value); err != nil {
		return fieldError(path, "must be an IP address literal", "use an IPv4 or IPv6 address such as 0.0.0.0 or ::")
	}
	return nil
}

func validatePort(path string, port, min, max int, ports map[int]string) error {
	if port < min || port > max {
		return fieldError(path, fmt.Sprintf("must be in range %d-%d", min, max), "choose an unprivileged listening port")
	}
	if existing, found := ports[port]; found {
		return fieldError(path, fmt.Sprintf("port %d conflicts with %s", port, existing), "choose a different port")
	}
	ports[port] = path
	return nil
}

func uniqueCredential(path, value string, credentials map[string]string) error {
	if existing, found := credentials[value]; found {
		return fieldError(path, fmt.Sprintf("credential duplicates %s", existing), "use a different credential for every protocol")
	}
	credentials[value] = path
	return nil
}

func validateBandwidth(path string, value *int) error {
	if value != nil && (*value < 1 || *value > 10000) {
		return fieldError(path, "must be in range 1-10000", "remove the field or choose a valid Mbps value")
	}
	return nil
}

func validateTLSFiles(prefix, certificatePath, keyPath string) error {
	if certificatePath == "" {
		return fieldError(prefix+".certificate_path", "is empty", "provide a local certificate file")
	}
	if keyPath == "" {
		return fieldError(prefix+".key_path", "is empty", "provide a local TLS private-key file")
	}
	if err := checkFile(certificatePath, fileCertificate); err != nil {
		return fieldError(prefix+".certificate_path", err.Error(), "use a readable local certificate file")
	}
	if err := checkFile(keyPath, filePrivateKey); err != nil {
		return fieldError(prefix+".key_path", err.Error(), "use a secure readable private-key file")
	}
	if _, err := tls.LoadX509KeyPair(certificatePath, keyPath); err != nil {
		return fieldError(prefix+".certificate_path", "certificate and private key are invalid or do not match", "provide a matching PEM certificate and key")
	}
	return nil
}

func readRealityPrivateKey(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fieldError("vless_reality.private_key_path", "cannot open file", "make it readable by the service user")
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil || len(content) > 4096 {
		return "", fieldError("vless_reality.private_key_path", "cannot read a small key file", "store one Base64URL X25519 private key")
	}
	encoded := strings.TrimSpace(string(content))
	key, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(key) != 32 {
		return "", fieldError("vless_reality.private_key_path", "does not contain a 32-byte Base64URL key", "generate a valid Reality X25519 private key")
	}
	if _, err := ecdh.X25519().NewPrivateKey(key); err != nil {
		return "", fieldError("vless_reality.private_key_path", "contains an invalid X25519 private key", "generate a new Reality key")
	}
	return encoded, nil
}

func validUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	raw := strings.ReplaceAll(value, "-", "")
	decoded, err := hex.DecodeString(raw)
	return err == nil && len(decoded) == 16
}

func isIPAddress(value string) bool {
	_, err := netip.ParseAddr(value)
	return err == nil
}

func validDNSName(value string) bool {
	value = strings.TrimSuffix(value, ".")
	if value == "" || len(value) > 253 {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, ch := range label {
			if (ch < 'a' || ch > 'z') && (ch < 'A' || ch > 'Z') && (ch < '0' || ch > '9') && ch != '-' {
				return false
			}
		}
	}
	return true
}
