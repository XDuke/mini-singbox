package secret

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestRandomCredentials(t *testing.T) {
	password, err := Password()
	if err != nil {
		t.Fatal(err)
	}
	decodedPassword, err := base64.RawURLEncoding.DecodeString(password)
	if err != nil || len(decodedPassword) != 32 {
		t.Fatalf("Password() = %q, decoded length %d, error %v", password, len(decodedPassword), err)
	}
	shortID, err := ShortID()
	if err != nil {
		t.Fatal(err)
	}
	decodedShortID, err := hex.DecodeString(shortID)
	if err != nil || len(decodedShortID) != 8 {
		t.Fatalf("ShortID() = %q", shortID)
	}
	uuid, err := UUIDv4()
	if err != nil {
		t.Fatal(err)
	}
	if len(uuid) != 36 || uuid[14] != '4' || !strings.Contains("89ab", strings.ToLower(uuid[19:20])) {
		t.Fatalf("UUIDv4() = %q", uuid)
	}
	keys, err := RealityKeys()
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := base64.RawURLEncoding.DecodeString(keys.Private)
	if err != nil || len(privateKey) != 32 {
		t.Fatalf("Reality private key length = %d, error %v", len(privateKey), err)
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(keys.Public)
	if err != nil || len(publicKey) != 32 {
		t.Fatalf("Reality public key length = %d, error %v", len(publicKey), err)
	}
}

func TestSelfSignedCertificate(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	generated, err := SelfSignedCertificate("server.example", now)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(generated.CertificatePEM, generated.PrivateKeyPEM)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(generated.CertificatePEM)
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if err := certificate.VerifyHostname("server.example"); err != nil {
		t.Fatal(err)
	}
	if certificate.PublicKeyAlgorithm != x509.ECDSA || len(pair.Certificate) != 1 {
		t.Fatalf("unexpected certificate algorithm or chain")
	}
	if certificate.NotAfter.Sub(now) != 365*24*time.Hour {
		t.Fatalf("validity = %v", certificate.NotAfter.Sub(now))
	}
}

func TestWriteFilesAtomicAndOverwriteProtection(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "output")
	files := []File{{Name: "secret", Data: []byte("first"), Mode: 0o600}}
	if err := WriteFiles(directory, files, false); err != nil {
		t.Fatal(err)
	}
	if err := WriteFiles(directory, files, false); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("second WriteFiles() error = %v", err)
	}
	files[0].Data = []byte("second")
	if err := WriteFiles(directory, files, true); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(directory, "secret"))
	if err != nil || string(content) != "second" {
		t.Fatalf("content = %q, error %v", content, err)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(filepath.Join(directory, "secret"))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("mode = %v, error %v", info.Mode().Perm(), err)
		}
	}
}

func TestWriteFilesRejectsSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink creation requires additional Windows privilege")
	}
	directory := t.TempDir()
	target := filepath.Join(directory, "target")
	if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(directory, "secret")); err != nil {
		t.Fatal(err)
	}
	err := WriteFiles(directory, []File{{Name: "secret", Data: []byte("replace"), Mode: 0o600}}, true)
	if err == nil || !strings.Contains(err.Error(), "symbolic-link") {
		t.Fatalf("WriteFiles() error = %v", err)
	}
}
