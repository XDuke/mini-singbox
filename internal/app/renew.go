package app

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"github.com/XDuke/mini-singbox/internal/config"
	"github.com/XDuke/mini-singbox/internal/secret"
)

type RenewCertificateOptions struct {
	ConfigPath               string
	Output                   string
	PublicAddress            string
	RealityPort              int
	Hysteria2Port            int
	AnyTLSPort               int
	AllowInsecureAnyTLSShare bool
}

type RenewCertificateResult struct {
	Files      []string
	ClientInfo []byte
}

// RenewCertificate stages a replacement TLS certificate, key, and matching
// client delivery files. It preserves every protocol credential and does not
// modify the active server directory; the control tool performs the guarded
// service stop, switch, health check, and rollback.
func RenewCertificate(options RenewCertificateOptions) (*RenewCertificateResult, error) {
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
	if localConfig.Hysteria2 == nil && localConfig.AnyTLS == nil {
		return nil, fmt.Errorf("certificate renewal requires Hysteria2 or AnyTLS")
	}
	absoluteConfigPath, err := filepath.Abs(options.ConfigPath)
	if err != nil {
		return nil, fmt.Errorf("resolve certificate renewal config path: %w", err)
	}
	expectedCertificatePath := filepath.Join(filepath.Dir(absoluteConfigPath), "tls.crt")
	expectedKeyPath := filepath.Join(filepath.Dir(absoluteConfigPath), "tls.key")
	validateManagedTLSPaths := func(protocol, certificatePath, keyPath string) error {
		if filepath.Clean(certificatePath) != expectedCertificatePath || filepath.Clean(keyPath) != expectedKeyPath {
			return fmt.Errorf("%s certificate renewal requires managed tls.crt and tls.key paths", protocol)
		}
		return nil
	}
	if localConfig.Hysteria2 != nil {
		if err := validateManagedTLSPaths("hysteria2", localConfig.Hysteria2.CertificatePath, localConfig.Hysteria2.KeyPath); err != nil {
			return nil, err
		}
	}
	if localConfig.AnyTLS != nil {
		if err := validateManagedTLSPaths("anytls", localConfig.AnyTLS.CertificatePath, localConfig.AnyTLS.KeyPath); err != nil {
			return nil, err
		}
	}

	certificatePath := ""
	if localConfig.Hysteria2 != nil {
		certificatePath = localConfig.Hysteria2.CertificatePath
	} else {
		certificatePath = localConfig.AnyTLS.CertificatePath
	}
	currentTLS, err := tlsClientInfo(certificatePath)
	if err != nil {
		return nil, fmt.Errorf("current delivery certificate: %w", err)
	}
	certificate, err := secret.SelfSignedCertificate(currentTLS.TLSSAN, time.Now())
	if err != nil {
		return nil, err
	}
	certificateSHA256, err := certificateFingerprintSHA256(certificate.CertificatePEM)
	if err != nil {
		return nil, err
	}

	client := clientInfo{SchemaVersion: config.SchemaVersion, PublicAddress: options.PublicAddress}
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
	newPasswordClient := func(port int, password string) *passwordClientInfo {
		return &passwordClientInfo{
			Port: port, Password: password, TLSSAN: currentTLS.TLSSAN,
			CertSHA: certificateSHA256, CertificatePEM: string(certificate.CertificatePEM),
		}
	}
	if localConfig.Hysteria2 != nil {
		client.Hysteria2 = newPasswordClient(localConfig.Hysteria2.Port, localConfig.Hysteria2.Password)
	}
	if localConfig.AnyTLS != nil {
		client.AnyTLS = newPasswordClient(localConfig.AnyTLS.Port, localConfig.AnyTLS.Password)
	}
	if err := applyPublicPorts(&client, options.RealityPort, options.Hysteria2Port, options.AnyTLSPort); err != nil {
		return nil, err
	}
	files, err := buildDeliveryFiles(&client, options.AllowInsecureAnyTLSShare)
	if err != nil {
		return nil, err
	}
	clientJSON, err := json.MarshalIndent(client, "", "  ")
	if err != nil {
		return nil, err
	}
	clientJSON = append(clientJSON, '\n')
	files = append(files,
		secret.File{Name: "tls.crt", Data: certificate.CertificatePEM, Mode: 0o644},
		secret.File{Name: "tls.key", Data: certificate.PrivateKeyPEM, Mode: 0o600},
		secret.File{Name: "client-info.json", Data: clientJSON, Mode: 0o600},
	)
	if err := secret.WriteFiles(options.Output, files, false); err != nil {
		return nil, err
	}

	result := &RenewCertificateResult{ClientInfo: clientJSON}
	for _, file := range files {
		result.Files = append(result.Files, filepath.Join(options.Output, file.Name))
	}
	return result, nil
}
