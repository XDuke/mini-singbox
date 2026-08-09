package config

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/XDuke/mini-singbox/internal/core"
	"github.com/sagernet/sing-box/option"
)

func TestDecodeRejectsUnknownField(t *testing.T) {
	_, err := Decode(strings.NewReader(`{
		"schema_version": 1,
		"vless_reality": {"flow": "xtls-rprx-vision"}
	}`))
	if err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("Decode() error = %v, want unknown-field rejection", err)
	}
}

func TestDecodeRejectsOversize(t *testing.T) {
	_, err := Decode(bytes.NewReader(bytes.Repeat([]byte{' '}, MaxConfigSize+1)))
	if err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("Decode() error = %v, want size rejection", err)
	}
}

func TestDecodeRejectsTrailingValue(t *testing.T) {
	_, err := Decode(strings.NewReader(`{"schema_version":1} {}`))
	if err == nil || !strings.Contains(err.Error(), "trailing") {
		t.Fatalf("Decode() error = %v, want trailing-data rejection", err)
	}
}

func TestValidateAndConvert(t *testing.T) {
	c := validConfig(t)
	validated, err := Validate(c)
	if err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	options := Convert(validated)
	if len(options.Inbounds) != 3 {
		t.Fatalf("len(Inbounds) = %d, want 3", len(options.Inbounds))
	}
	if len(options.Outbounds) != 0 || options.DNS != nil || options.Route != nil || options.Experimental != nil {
		t.Fatal("Convert() exposed forbidden options")
	}
	vlessOptions := options.Inbounds[0].Options.(*option.VLESSInboundOptions)
	if len(vlessOptions.Users) != 1 || vlessOptions.Users[0].Flow != "xtls-rprx-vision" {
		t.Fatalf("VLESS users = %#v", vlessOptions.Users)
	}
	if vlessOptions.Multiplex != nil || vlessOptions.Transport != nil || vlessOptions.TLS == nil || vlessOptions.TLS.Reality == nil {
		t.Fatal("VLESS fixed transport/TLS invariants not satisfied")
	}
	hy2Options := options.Inbounds[1].Options.(*option.Hysteria2InboundOptions)
	if len(hy2Options.Users) != 1 || hy2Options.TLS == nil || hy2Options.TLS.MinVersion != "1.3" {
		t.Fatalf("Hysteria2 options = %#v", hy2Options)
	}
	if hy2Options.Masquerade != nil || hy2Options.BrutalDebug {
		t.Fatal("Hysteria2 forbidden options are enabled")
	}
	anyTLSOptions := options.Inbounds[2].Options.(*option.AnyTLSInboundOptions)
	if len(anyTLSOptions.Users) != 1 || anyTLSOptions.TLS == nil || anyTLSOptions.TLS.MinVersion != "1.3" {
		t.Fatalf("AnyTLS options = %#v", anyTLSOptions)
	}
	if anyTLSOptions.PaddingScheme != nil {
		t.Fatal("AnyTLS custom padding is exposed")
	}
	b, err := core.New(context.Background(), options)
	if err != nil {
		t.Fatalf("three-protocol core.New() error = %v", err)
	}
	if err := b.Close(); err != nil {
		t.Fatalf("three-protocol Close() error = %v", err)
	}
}

func TestAnyTLSOnlyInstantiates(t *testing.T) {
	c := validConfig(t)
	c.VLESSReality = nil
	c.Hysteria2 = nil
	validated, err := Validate(c)
	if err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	b, err := core.New(context.Background(), Convert(validated))
	if err != nil {
		t.Fatalf("AnyTLS core.New() error = %v", err)
	}
	if err := b.Close(); err != nil {
		t.Fatalf("AnyTLS Close() error = %v", err)
	}
}

func TestValidationFailures(t *testing.T) {
	tests := []struct {
		name string
		edit func(*Config)
		want string
	}{
		{"schema version", func(c *Config) { c.SchemaVersion = 2 }, "schema_version"},
		{"log level", func(c *Config) { c.Log.Level = "info" }, "log.level"},
		{"no protocol", func(c *Config) { c.VLESSReality = nil; c.Hysteria2 = nil; c.AnyTLS = nil }, "at least one"},
		{"duplicate port", func(c *Config) { c.Hysteria2.Port = c.VLESSReality.Port }, "conflicts"},
		{"hostname listen", func(c *Config) { c.VLESSReality.Listen = "localhost" }, "IP address literal"},
		{"bad uuid", func(c *Config) { c.VLESSReality.UUID = "not-a-uuid" }, "canonical UUID"},
		{"bad short id", func(c *Config) { c.VLESSReality.ShortID = "abcd" }, "16 hexadecimal"},
		{"ip server name", func(c *Config) { c.VLESSReality.ServerName = "1.1.1.1" }, "DNS name"},
		{"bad handshake", func(c *Config) { c.VLESSReality.HandshakeServer = "bad_name" }, "DNS name or IP"},
		{"short password", func(c *Config) { c.Hysteria2.Password = "short" }, "16 characters"},
		{"short anytls password", func(c *Config) { c.AnyTLS.Password = "short" }, "anytls.password"},
		{"bad bandwidth", func(c *Config) { value := 0; c.Hysteria2.UpMbps = &value }, "1-10000"},
		{"duplicate credential", func(c *Config) { c.Hysteria2.Password = c.VLESSReality.UUID }, "duplicates"},
		{"duplicate anytls credential", func(c *Config) { c.AnyTLS.Password = c.Hysteria2.Password }, "duplicates"},
		{"missing key", func(c *Config) { c.VLESSReality.PrivateKeyPath = filepath.Join(t.TempDir(), "missing") }, "private_key_path"},
		{"missing certificate", func(c *Config) { c.Hysteria2.CertificatePath = filepath.Join(t.TempDir(), "missing") }, "certificate_path"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			c := validConfig(t)
			test.edit(c)
			_, err := Validate(c)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Validate() error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestValidateRejectsMismatchedCertificate(t *testing.T) {
	c := validConfig(t)
	_, otherKey := writeTLSFiles(t, t.TempDir(), "other")
	c.Hysteria2.KeyPath = otherKey
	_, err := Validate(c)
	if err == nil || !strings.Contains(err.Error(), "do not match") {
		t.Fatalf("Validate() error = %v, want mismatch", err)
	}
}

func TestValidateRejectsUnsafePrivateKeyPermissions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows ACLs are checked by deployment tests")
	}
	c := validConfig(t)
	if err := os.Chmod(c.VLESSReality.PrivateKeyPath, 0o606); err != nil {
		t.Fatal(err)
	}
	_, err := Validate(c)
	if err == nil || !strings.Contains(err.Error(), "other") {
		t.Fatalf("Validate() error = %v, want unsafe-permission rejection", err)
	}
}

func TestValidationErrorDoesNotLeakCredential(t *testing.T) {
	c := validConfig(t)
	secret := "do-not-print-me"
	c.Hysteria2.Password = secret
	_, err := Validate(c)
	if err == nil {
		t.Fatal("Validate() unexpectedly succeeded")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("error leaked credential: %v", err)
	}
}

func validConfig(t *testing.T) *Config {
	t.Helper()
	directory := t.TempDir()
	realityKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	realityPath := filepath.Join(directory, "reality.key")
	if err := os.WriteFile(realityPath, []byte(base64.RawURLEncoding.EncodeToString(realityKey.Bytes())+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	certificatePath, keyPath := writeTLSFiles(t, directory, "tls")
	up, down := 20, 50
	return &Config{
		SchemaVersion: 1,
		Log:           &LogConfig{Level: "warn"},
		VLESSReality: &VLESSRealityConfig{
			Listen:          "127.0.0.1",
			Port:            20001,
			UUID:            "11111111-1111-4111-8111-111111111111",
			PrivateKeyPath:  realityPath,
			ShortID:         "0123456789abcdef",
			ServerName:      "www.example.com",
			HandshakeServer: "www.example.com",
			HandshakePort:   443,
		},
		Hysteria2: &Hysteria2Config{
			Listen:          "127.0.0.1",
			Port:            20002,
			Password:        "hysteria2-test-password-1234",
			CertificatePath: certificatePath,
			KeyPath:         keyPath,
			UpMbps:          &up,
			DownMbps:        &down,
		},
		AnyTLS: &AnyTLSConfig{
			Listen:          "127.0.0.1",
			Port:            20003,
			Password:        "anytls-test-password-5678",
			CertificatePath: certificatePath,
			KeyPath:         keyPath,
		},
	}
}

func writeTLSFiles(t *testing.T, directory, prefix string) (string, string) {
	t.Helper()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test.example"},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"test.example"},
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	certificatePath := filepath.Join(directory, prefix+".crt")
	keyPath := filepath.Join(directory, prefix+".key")
	if err := os.WriteFile(certificatePath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificateDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	return certificatePath, keyPath
}
