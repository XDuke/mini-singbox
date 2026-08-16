package app

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenewCertificatePreservesCredentialsAndStagesAuthenticatedDelivery(t *testing.T) {
	serverDirectory := filepath.Join(t.TempDir(), "server")
	generated, err := Generate(GenerateOptions{
		Output: serverDirectory, Protocols: []string{"reality", "hy2", "anytls"},
		Listen: "127.0.0.1", PublicAddress: "192.0.2.10",
		RealityPort: 20001, Hysteria2Port: 20002, AnyTLSPort: 20003,
		RealityServerName: "www.example.com", RealityHandshake: "www.example.com:443",
		TLSSAN: "server.example",
	})
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(serverDirectory, "config.json")
	configBefore, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	certificateBefore, err := os.ReadFile(filepath.Join(serverDirectory, "tls.crt"))
	if err != nil {
		t.Fatal(err)
	}
	stagingDirectory := filepath.Join(t.TempDir(), "renewed")
	renewed, err := RenewCertificate(RenewCertificateOptions{
		ConfigPath: configPath, Output: stagingDirectory, PublicAddress: "203.0.113.20",
		RealityPort: 51165, Hysteria2Port: 25421, AnyTLSPort: 36279,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(renewed.Files) != 6 {
		t.Fatalf("renewed files = %v", renewed.Files)
	}
	configAfter, err := os.ReadFile(configPath)
	if err != nil || !bytes.Equal(configBefore, configAfter) {
		t.Fatalf("renewal changed server config, error %v", err)
	}
	certificateAfter, err := os.ReadFile(filepath.Join(stagingDirectory, "tls.crt"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(certificateBefore, certificateAfter) {
		t.Fatal("renewal did not rotate the TLS certificate")
	}
	var original, updated clientInfo
	if err := json.Unmarshal(generated.ClientInfo, &original); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(renewed.ClientInfo, &updated); err != nil {
		t.Fatal(err)
	}
	if original.VLESSReality.UUID != updated.VLESSReality.UUID ||
		original.VLESSReality.PublicKey != updated.VLESSReality.PublicKey ||
		original.Hysteria2.Password != updated.Hysteria2.Password ||
		original.AnyTLS.Password != updated.AnyTLS.Password {
		t.Fatal("certificate renewal rotated a protocol credential")
	}
	if original.Hysteria2.CertSHA == updated.Hysteria2.CertSHA ||
		!strings.Contains(updated.Hysteria2.ShareURI, "pinSHA256=") {
		t.Fatalf("renewed Hysteria2 pin = %#v", updated.Hysteria2)
	}
	if updated.AnyTLS.ShareURI != "" {
		t.Fatalf("renewal generated unsafe AnyTLS URI by default: %s", updated.AnyTLS.ShareURI)
	}
	assertAuthenticatedAnyTLSOutbound(t, filepath.Join(stagingDirectory, updated.AnyTLS.SingBoxOutboundFile))
	for _, name := range []string{"config.json", "reality.key"} {
		if _, err := os.Stat(filepath.Join(stagingDirectory, name)); !os.IsNotExist(err) {
			t.Fatalf("renewal staging unexpectedly contains %s", name)
		}
	}
}

func TestRenewCertificateRejectsRealityOnly(t *testing.T) {
	serverDirectory := filepath.Join(t.TempDir(), "server")
	_, err := Generate(GenerateOptions{
		Output: serverDirectory, Protocols: []string{"reality"}, Listen: "127.0.0.1",
		RealityPort: 20001, RealityServerName: "www.example.com",
		RealityHandshake: "www.example.com:443",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = RenewCertificate(RenewCertificateOptions{
		ConfigPath: filepath.Join(serverDirectory, "config.json"),
		Output:     filepath.Join(t.TempDir(), "renewed"), PublicAddress: "203.0.113.20",
	})
	if err == nil || !strings.Contains(err.Error(), "requires Hysteria2 or AnyTLS") {
		t.Fatalf("RenewCertificate() error = %v", err)
	}
}

func TestRenewCertificateRejectsUnmanagedTLSPaths(t *testing.T) {
	serverDirectory := filepath.Join(t.TempDir(), "server")
	_, err := Generate(GenerateOptions{
		Output: serverDirectory, Protocols: []string{"hy2"}, Listen: "127.0.0.1",
		Hysteria2Port: 20002, TLSSAN: "server.example",
	})
	if err != nil {
		t.Fatal(err)
	}
	for source, destination := range map[string]string{"tls.crt": "external.crt", "tls.key": "external.key"} {
		content, err := os.ReadFile(filepath.Join(serverDirectory, source))
		if err != nil {
			t.Fatal(err)
		}
		mode := os.FileMode(0o600)
		if strings.HasSuffix(destination, ".crt") {
			mode = 0o644
		}
		if err := os.WriteFile(filepath.Join(serverDirectory, destination), content, mode); err != nil {
			t.Fatal(err)
		}
	}
	configPath := filepath.Join(serverDirectory, "config.json")
	content, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	content = bytes.ReplaceAll(content, []byte(`"tls.crt"`), []byte(`"external.crt"`))
	content = bytes.ReplaceAll(content, []byte(`"tls.key"`), []byte(`"external.key"`))
	if err := os.WriteFile(configPath, content, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = RenewCertificate(RenewCertificateOptions{
		ConfigPath: configPath, Output: filepath.Join(t.TempDir(), "renewed"),
		PublicAddress: "203.0.113.20", Hysteria2Port: 20002,
	})
	if err == nil || !strings.Contains(err.Error(), "requires managed tls.crt and tls.key paths") {
		t.Fatalf("RenewCertificate() error = %v", err)
	}
}
