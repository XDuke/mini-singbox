package app

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/XDuke/mini-singbox/internal/config"
)

func TestCheckDoesNotBindConfiguredPort(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_, portText, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}

	directory := t.TempDir()
	privateKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privateKeyPath := filepath.Join(directory, "reality.key")
	if err := os.WriteFile(privateKeyPath, []byte(base64.RawURLEncoding.EncodeToString(privateKey.Bytes())), 0o600); err != nil {
		t.Fatal(err)
	}
	localConfig := config.Config{
		SchemaVersion: 1,
		VLESSReality: &config.VLESSRealityConfig{
			Listen:          "127.0.0.1",
			Port:            port,
			UUID:            "11111111-1111-4111-8111-111111111111",
			PrivateKeyPath:  privateKeyPath,
			ShortID:         "0123456789abcdef",
			ServerName:      "www.example.com",
			HandshakeServer: "www.example.com",
			HandshakePort:   443,
		},
	}
	content, err := json.Marshal(localConfig)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(directory, "config.json")
	if err := os.WriteFile(configPath, content, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Check(configPath); err != nil {
		t.Fatalf("Check() error = %v", err)
	}
}
