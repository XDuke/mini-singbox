package app

import (
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/XDuke/mini-singbox/internal/config"
	"github.com/XDuke/mini-singbox/internal/secret"
)

type GenerateOptions struct {
	Output                   string
	Protocols                []string
	Listen                   string
	PublicAddress            string
	RealityPort              int
	Hysteria2Port            int
	AnyTLSPort               int
	PublicRealityPort        int
	PublicHysteria2Port      int
	PublicAnyTLSPort         int
	RealityServerName        string
	RealityHandshake         string
	TLSSAN                   string
	AllowInsecureAnyTLSShare bool
	Force                    bool
}

type GenerateResult struct {
	Files      []string
	ClientInfo []byte
}

type clientInfo struct {
	SchemaVersion int                 `json:"schema_version"`
	PublicAddress string              `json:"public_address,omitempty"`
	VLESSReality  *vlessClientInfo    `json:"vless_reality,omitempty"`
	Hysteria2     *passwordClientInfo `json:"hysteria2,omitempty"`
	AnyTLS        *passwordClientInfo `json:"anytls,omitempty"`
}

type vlessClientInfo struct {
	Port       int    `json:"port"`
	UUID       string `json:"uuid"`
	PublicKey  string `json:"public_key"`
	ShortID    string `json:"short_id"`
	ServerName string `json:"server_name"`
	ShareURI   string `json:"share_uri,omitempty"`
}

type passwordClientInfo struct {
	Port                int    `json:"port"`
	Password            string `json:"password"`
	TLSSAN              string `json:"tls_san"`
	CertSHA             string `json:"certificate_sha256,omitempty"`
	SingBoxOutboundFile string `json:"sing_box_outbound_file,omitempty"`
	MihomoProxyFile     string `json:"mihomo_proxy_file,omitempty"`
	V2RayNShareFile     string `json:"v2rayn_share_file,omitempty"`
	V2RayNShareURI      string `json:"v2rayn_share_uri,omitempty"`
	ShareURI            string `json:"share_uri,omitempty"`
	CertificatePEM      string `json:"-"`
}

func Generate(options GenerateOptions) (*GenerateResult, error) {
	protocols, err := normalizeProtocols(options.Protocols)
	if err != nil {
		return nil, err
	}
	if _, err := netip.ParseAddr(options.Listen); err != nil {
		return nil, fmt.Errorf("listen: must be an IP address literal")
	}
	ports := make(map[int]string, len(protocols))
	for _, protocol := range protocols {
		var port int
		switch protocol {
		case "reality":
			port = options.RealityPort
		case "hy2":
			port = options.Hysteria2Port
		case "anytls":
			port = options.AnyTLSPort
		}
		if port < 1024 || port > 65535 {
			return nil, fmt.Errorf("%s port: must be in range 1024-65535", protocol)
		}
		if previous, exists := ports[port]; exists {
			return nil, fmt.Errorf("%s port %d conflicts with %s", protocol, port, previous)
		}
		ports[port] = protocol
	}
	if options.PublicAddress != "" {
		if err := validatePublicAddress(options.PublicAddress); err != nil {
			return nil, err
		}
	} else if options.PublicRealityPort != 0 || options.PublicHysteria2Port != 0 || options.PublicAnyTLSPort != 0 {
		return nil, fmt.Errorf("public-address: is required when a public port is set")
	}

	localConfig := config.Config{SchemaVersion: config.SchemaVersion, Log: &config.LogConfig{Level: "warn"}}
	client := clientInfo{SchemaVersion: config.SchemaVersion, PublicAddress: options.PublicAddress}
	files := make([]secret.File, 0, 8)

	if containsProtocol(protocols, "reality") {
		host, port, err := splitHandshake(options.RealityHandshake)
		if err != nil {
			return nil, err
		}
		if options.RealityServerName == "" {
			return nil, fmt.Errorf("reality-server-name: is required for Reality")
		}
		if net.ParseIP(options.RealityServerName) != nil || !validGenerateDNSName(options.RealityServerName) {
			return nil, fmt.Errorf("reality-server-name: must be a valid DNS name")
		}
		if net.ParseIP(host) == nil && !validGenerateDNSName(host) {
			return nil, fmt.Errorf("reality-handshake: host must be a valid DNS name or IP address")
		}
		uuid, err := secret.UUIDv4()
		if err != nil {
			return nil, err
		}
		shortID, err := secret.ShortID()
		if err != nil {
			return nil, err
		}
		keyPair, err := secret.RealityKeys()
		if err != nil {
			return nil, err
		}
		localConfig.VLESSReality = &config.VLESSRealityConfig{
			Listen: options.Listen, Port: options.RealityPort, UUID: uuid,
			PrivateKeyPath: "reality.key", ShortID: shortID,
			ServerName: options.RealityServerName, HandshakeServer: host, HandshakePort: port,
		}
		client.VLESSReality = &vlessClientInfo{
			Port: options.RealityPort, UUID: uuid, PublicKey: keyPair.Public,
			ShortID: shortID, ServerName: options.RealityServerName,
		}
		files = append(files, secret.File{Name: "reality.key", Data: []byte(keyPair.Private + "\n"), Mode: 0o600})
	}

	needTLS := containsProtocol(protocols, "hy2") || containsProtocol(protocols, "anytls")
	certificateSHA256 := ""
	var certificatePEM []byte
	if needTLS {
		certificate, err := secret.SelfSignedCertificate(options.TLSSAN, time.Now())
		if err != nil {
			return nil, err
		}
		certificatePEM = certificate.CertificatePEM
		certificateSHA256, err = certificateFingerprintSHA256(certificate.CertificatePEM)
		if err != nil {
			return nil, err
		}
		files = append(files,
			secret.File{Name: "tls.crt", Data: certificate.CertificatePEM, Mode: 0o644},
			secret.File{Name: "tls.key", Data: certificate.PrivateKeyPEM, Mode: 0o600},
		)
	}
	if containsProtocol(protocols, "hy2") {
		password, err := secret.Password()
		if err != nil {
			return nil, err
		}
		localConfig.Hysteria2 = &config.Hysteria2Config{
			Listen: options.Listen, Port: options.Hysteria2Port, Password: password,
			CertificatePath: "tls.crt", KeyPath: "tls.key",
		}
		client.Hysteria2 = &passwordClientInfo{
			Port: options.Hysteria2Port, Password: password, TLSSAN: options.TLSSAN,
			CertSHA: certificateSHA256,
		}
	}
	if containsProtocol(protocols, "anytls") {
		password, err := secret.Password()
		if err != nil {
			return nil, err
		}
		localConfig.AnyTLS = &config.AnyTLSConfig{
			Listen: options.Listen, Port: options.AnyTLSPort, Password: password,
			CertificatePath: "tls.crt", KeyPath: "tls.key",
		}
		client.AnyTLS = &passwordClientInfo{
			Port: options.AnyTLSPort, Password: password, TLSSAN: options.TLSSAN,
			CertSHA: certificateSHA256, CertificatePEM: string(certificatePEM),
		}
	}

	if options.PublicAddress != "" {
		if err := applyPublicPorts(
			&client,
			options.PublicRealityPort,
			options.PublicHysteria2Port,
			options.PublicAnyTLSPort,
		); err != nil {
			return nil, err
		}
		shareFiles, err := buildDeliveryFiles(&client, options.AllowInsecureAnyTLSShare)
		if err != nil {
			return nil, err
		}
		files = append(files, shareFiles...)
	}

	configJSON, err := json.MarshalIndent(localConfig, "", "  ")
	if err != nil {
		return nil, err
	}
	clientJSON, err := json.MarshalIndent(client, "", "  ")
	if err != nil {
		return nil, err
	}
	configJSON = append(configJSON, '\n')
	clientJSON = append(clientJSON, '\n')
	files = append(files,
		secret.File{Name: "config.json", Data: configJSON, Mode: 0o600},
		secret.File{Name: "client-info.json", Data: clientJSON, Mode: 0o600},
	)
	if err := secret.WriteFiles(options.Output, files, options.Force); err != nil {
		return nil, err
	}
	configPath := filepath.Join(options.Output, "config.json")
	generated, err := config.DecodeFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("verify generated config: %w", err)
	}
	if _, err := config.Validate(generated); err != nil {
		return nil, fmt.Errorf("verify generated config: %w", err)
	}
	result := &GenerateResult{ClientInfo: clientJSON}
	for _, file := range files {
		result.Files = append(result.Files, filepath.Join(options.Output, file.Name))
	}
	return result, nil
}

func normalizeProtocols(protocols []string) ([]string, error) {
	if len(protocols) == 0 {
		return nil, fmt.Errorf("protocols: enable at least one of reality, hy2, anytls")
	}
	seen := make(map[string]bool, len(protocols))
	result := make([]string, 0, len(protocols))
	for _, protocol := range protocols {
		protocol = strings.ToLower(strings.TrimSpace(protocol))
		if protocol != "reality" && protocol != "hy2" && protocol != "anytls" {
			return nil, fmt.Errorf("protocols: unknown protocol %q", protocol)
		}
		if seen[protocol] {
			return nil, fmt.Errorf("protocols: duplicate protocol %q", protocol)
		}
		seen[protocol] = true
		result = append(result, protocol)
	}
	return result, nil
}

func containsProtocol(protocols []string, expected string) bool {
	for _, protocol := range protocols {
		if protocol == expected {
			return true
		}
	}
	return false
}

func splitHandshake(value string) (string, int, error) {
	host, portText, err := net.SplitHostPort(value)
	if err != nil || host == "" {
		return "", 0, fmt.Errorf("reality-handshake: use HOST:PORT (IPv6 must use [ADDRESS]:PORT)")
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return "", 0, fmt.Errorf("reality-handshake: port must be in range 1-65535")
	}
	return host, port, nil
}

func validGenerateDNSName(value string) bool {
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
