package app

import (
	"crypto/ecdh"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/XDuke/mini-singbox/internal/config"
	"github.com/XDuke/mini-singbox/internal/secret"
)

type DeliverOptions struct {
	ConfigPath    string
	Output        string
	PublicAddress string
	RealityPort   int
	Hysteria2Port int
	AnyTLSPort    int
	Force         bool
}

type DeliverResult struct {
	Files      []string
	ClientInfo []byte
}

// Deliver rebuilds client delivery files from an existing validated server
// configuration. It does not change server configuration, credentials, or keys.
func Deliver(options DeliverOptions) (*DeliverResult, error) {
	if err := validatePublicAddress(options.PublicAddress); err != nil {
		return nil, err
	}
	localConfig, err := config.DecodeFile(options.ConfigPath)
	if err != nil {
		return nil, err
	}
	validated, err := config.Validate(localConfig)
	if err != nil {
		return nil, err
	}

	client := clientInfo{
		SchemaVersion: config.SchemaVersion,
		PublicAddress: options.PublicAddress,
	}
	if localConfig.VLESSReality != nil {
		publicKey, err := realityPublicKey(validated.RealityPrivateKey)
		if err != nil {
			return nil, err
		}
		client.VLESSReality = &vlessClientInfo{
			Port:       localConfig.VLESSReality.Port,
			UUID:       localConfig.VLESSReality.UUID,
			PublicKey:  publicKey,
			ShortID:    localConfig.VLESSReality.ShortID,
			ServerName: localConfig.VLESSReality.ServerName,
		}
	}
	if localConfig.Hysteria2 != nil {
		clientInfo, err := tlsClientInfo(localConfig.Hysteria2.CertificatePath)
		if err != nil {
			return nil, fmt.Errorf("hysteria2 delivery certificate: %w", err)
		}
		clientInfo.Port = localConfig.Hysteria2.Port
		clientInfo.Password = localConfig.Hysteria2.Password
		client.Hysteria2 = clientInfo
	}
	if localConfig.AnyTLS != nil {
		clientInfo, err := tlsClientInfo(localConfig.AnyTLS.CertificatePath)
		if err != nil {
			return nil, fmt.Errorf("anytls delivery certificate: %w", err)
		}
		clientInfo.Port = localConfig.AnyTLS.Port
		clientInfo.Password = localConfig.AnyTLS.Password
		client.AnyTLS = clientInfo
	}
	if err := applyPublicPorts(&client, options.RealityPort, options.Hysteria2Port, options.AnyTLSPort); err != nil {
		return nil, err
	}
	files, err := buildShareFiles(&client)
	if err != nil {
		return nil, err
	}
	clientJSON, err := json.MarshalIndent(client, "", "  ")
	if err != nil {
		return nil, err
	}
	clientJSON = append(clientJSON, '\n')
	files = append(files, secret.File{Name: "client-info.json", Data: clientJSON, Mode: 0o600})
	if err := secret.WriteFiles(options.Output, files, options.Force); err != nil {
		return nil, err
	}

	result := &DeliverResult{ClientInfo: clientJSON}
	for _, file := range files {
		result.Files = append(result.Files, filepath.Join(options.Output, file.Name))
	}
	return result, nil
}

func realityPublicKey(privateKey string) (string, error) {
	privateBytes, err := base64.RawURLEncoding.DecodeString(privateKey)
	if err != nil {
		return "", fmt.Errorf("derive Reality public key: decode private key: %w", err)
	}
	key, err := ecdh.X25519().NewPrivateKey(privateBytes)
	if err != nil {
		return "", fmt.Errorf("derive Reality public key: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()), nil
}

func tlsClientInfo(certificatePath string) (*passwordClientInfo, error) {
	content, err := os.ReadFile(certificatePath)
	if err != nil {
		return nil, fmt.Errorf("read certificate: %w", err)
	}
	block, rest := pem.Decode(content)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("expected a PEM certificate")
	}
	for len(strings.TrimSpace(string(rest))) != 0 {
		var additional *pem.Block
		additional, rest = pem.Decode(rest)
		if additional == nil || additional.Type != "CERTIFICATE" {
			return nil, fmt.Errorf("certificate file contains non-certificate PEM data")
		}
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse certificate: %w", err)
	}
	serverName := ""
	if len(certificate.DNSNames) > 0 {
		serverName = certificate.DNSNames[0]
	} else if len(certificate.IPAddresses) > 0 {
		serverName = certificate.IPAddresses[0].String()
	}
	if serverName == "" {
		return nil, fmt.Errorf("certificate has no DNS or IP subject alternative name")
	}
	fingerprint := sha256.Sum256(certificate.Raw)
	return &passwordClientInfo{TLSSAN: serverName, CertSHA: hex.EncodeToString(fingerprint[:])}, nil
}
