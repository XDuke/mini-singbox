package app

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/XDuke/mini-singbox/internal/secret"
)

func validatePublicAddress(value string) error {
	if value == "" || strings.TrimSpace(value) != value {
		return fmt.Errorf("public-address: must be a DNS name or IP address without a port")
	}
	if net.ParseIP(value) == nil && !validGenerateDNSName(value) {
		return fmt.Errorf("public-address: must be a DNS name or IP address without a port")
	}
	return nil
}

func certificateFingerprintSHA256(certificatePEM []byte) (string, error) {
	block, rest := pem.Decode(certificatePEM)
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return "", fmt.Errorf("generated TLS certificate is not one PEM certificate")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", fmt.Errorf("parse generated TLS certificate: %w", err)
	}
	fingerprint := sha256.Sum256(certificate.Raw)
	return hex.EncodeToString(fingerprint[:]), nil
}

func buildDeliveryFiles(client *clientInfo, allowInsecureAnyTLSShare bool) ([]secret.File, error) {
	address := client.PublicAddress
	files := make([]secret.File, 0, 3)
	if client.VLESSReality != nil {
		query := url.Values{
			"encryption": {"none"},
			"flow":       {"xtls-rprx-vision"},
			"fp":         {"chrome"},
			"pbk":        {client.VLESSReality.PublicKey},
			"security":   {"reality"},
			"sid":        {client.VLESSReality.ShortID},
			"sni":        {client.VLESSReality.ServerName},
			"type":       {"tcp"},
		}
		client.VLESSReality.ShareURI = shareURI(
			"vless", client.VLESSReality.UUID, address, client.VLESSReality.Port,
			"", query, "mini-singbox Reality",
		)
		files = append(files, shareFile("share-reality.txt", client.VLESSReality.ShareURI))
	}
	if client.Hysteria2 != nil {
		query := url.Values{
			"insecure":  {"1"},
			"pinSHA256": {client.Hysteria2.CertSHA},
			"sni":       {client.Hysteria2.TLSSAN},
		}
		client.Hysteria2.ShareURI = shareURI(
			"hysteria2", client.Hysteria2.Password, address, client.Hysteria2.Port,
			"/", query, "mini-singbox Hysteria2",
		)
		files = append(files, shareFile("share-hysteria2.txt", client.Hysteria2.ShareURI))
	}
	if client.AnyTLS != nil {
		client.AnyTLS.SingBoxOutboundFile = "client-anytls-sing-box-outbound.json"
		outbound, err := json.MarshalIndent(struct {
			Type       string `json:"type"`
			Tag        string `json:"tag"`
			Server     string `json:"server"`
			ServerPort int    `json:"server_port"`
			Password   string `json:"password"`
			TLS        struct {
				Enabled     bool     `json:"enabled"`
				ServerName  string   `json:"server_name"`
				Certificate []string `json:"certificate"`
			} `json:"tls"`
		}{
			Type: "anytls", Tag: "mini-singbox-anytls", Server: address,
			ServerPort: client.AnyTLS.Port, Password: client.AnyTLS.Password,
			TLS: struct {
				Enabled     bool     `json:"enabled"`
				ServerName  string   `json:"server_name"`
				Certificate []string `json:"certificate"`
			}{Enabled: true, ServerName: client.AnyTLS.TLSSAN, Certificate: []string{client.AnyTLS.CertificatePEM}},
		}, "", "  ")
		if err != nil {
			return nil, fmt.Errorf("marshal AnyTLS sing-box outbound: %w", err)
		}
		if client.AnyTLS.CertificatePEM == "" {
			return nil, fmt.Errorf("cannot build authenticated AnyTLS client config without the server certificate")
		}
		outbound = append(outbound, '\n')
		files = append(files, secret.File{
			Name: client.AnyTLS.SingBoxOutboundFile, Data: outbound, Mode: 0o600,
		})
		if allowInsecureAnyTLSShare {
			query := url.Values{
				"insecure": {"1"},
				"sni":      {client.AnyTLS.TLSSAN},
			}
			client.AnyTLS.ShareURI = shareURI(
				"anytls", client.AnyTLS.Password, address, client.AnyTLS.Port,
				"/", query, "mini-singbox AnyTLS UNSAFE",
			)
			files = append(files, shareFile("share-anytls.txt", client.AnyTLS.ShareURI))
		}
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("cannot build sharing files without an enabled protocol")
	}
	return files, nil
}

func applyPublicPorts(client *clientInfo, realityPort, hysteria2Port, anyTLSPort int) error {
	tcpPorts := make(map[int]string, 2)
	if client.VLESSReality != nil {
		port, err := resolvePublicPort("public-reality-port", realityPort, client.VLESSReality.Port)
		if err != nil {
			return err
		}
		client.VLESSReality.Port = port
		tcpPorts[port] = "Reality"
	}
	if client.Hysteria2 != nil {
		port, err := resolvePublicPort("public-hy2-port", hysteria2Port, client.Hysteria2.Port)
		if err != nil {
			return err
		}
		client.Hysteria2.Port = port
	}
	if client.AnyTLS != nil {
		port, err := resolvePublicPort("public-anytls-port", anyTLSPort, client.AnyTLS.Port)
		if err != nil {
			return err
		}
		if previous, exists := tcpPorts[port]; exists {
			return fmt.Errorf("public-anytls-port: port %d conflicts with %s TCP", port, previous)
		}
		client.AnyTLS.Port = port
	}
	return nil
}

func resolvePublicPort(name string, requested, fallback int) (int, error) {
	if requested == 0 {
		return fallback, nil
	}
	if requested < 1 || requested > 65535 {
		return 0, fmt.Errorf("%s: must be in range 1-65535", name)
	}
	return requested, nil
}

func shareURI(scheme, credential, address string, port int, path string, query url.Values, label string) string {
	uri := url.URL{
		Scheme:   scheme,
		User:     url.User(credential),
		Host:     net.JoinHostPort(address, strconv.Itoa(port)),
		Path:     path,
		RawQuery: query.Encode(),
		Fragment: label,
	}
	return uri.String()
}

func shareFile(name, uri string) secret.File {
	return secret.File{Name: name, Data: []byte(uri + "\n"), Mode: 0o600}
}
