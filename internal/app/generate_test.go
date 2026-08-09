package app

import (
	"bytes"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/XDuke/mini-singbox/internal/config"
)

func TestGenerateAllProtocolsAndValidate(t *testing.T) {
	output := filepath.Join(t.TempDir(), "generated")
	options := GenerateOptions{
		Output: output, Protocols: []string{"reality", "hy2", "anytls"}, Listen: "127.0.0.1",
		PublicAddress: "203.0.113.10",
		RealityPort:   20001, Hysteria2Port: 20002, AnyTLSPort: 20003,
		PublicRealityPort: 51165, PublicHysteria2Port: 25421, PublicAnyTLSPort: 36279,
		RealityServerName: "www.example.com", RealityHandshake: "www.example.com:443",
		TLSSAN: "server.example",
	}
	result, err := Generate(options)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Files) != 8 {
		t.Fatalf("generated files = %v", result.Files)
	}
	loaded, err := config.DecodeFile(filepath.Join(output, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := config.Validate(loaded); err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(loaded.VLESSReality.PrivateKeyPath) || !filepath.IsAbs(loaded.Hysteria2.KeyPath) {
		t.Fatal("relative generated paths were not resolved against config directory")
	}
	var client clientInfo
	if err := json.Unmarshal(result.ClientInfo, &client); err != nil {
		t.Fatal(err)
	}
	if client.Hysteria2.Password == client.AnyTLS.Password {
		t.Fatal("Hysteria2 and AnyTLS passwords must differ")
	}
	if client.PublicAddress != options.PublicAddress {
		t.Fatalf("client delivery metadata = %#v", client)
	}
	if bytes.Contains(result.ClientInfo, []byte(`"subscription"`)) {
		t.Fatalf("client info unexpectedly contains subscription metadata: %s", result.ClientInfo)
	}
	assertShareURI(t, client.VLESSReality.ShareURI, "vless", options.PublicAddress, options.PublicRealityPort)
	assertShareURI(t, client.Hysteria2.ShareURI, "hysteria2", options.PublicAddress, options.PublicHysteria2Port)
	assertShareURI(t, client.AnyTLS.ShareURI, "anytls", options.PublicAddress, options.PublicAnyTLSPort)
	if !strings.Contains(client.Hysteria2.ShareURI, "insecure=1") ||
		!strings.Contains(client.Hysteria2.ShareURI, "pinSHA256=") {
		t.Fatalf("Hysteria2 share URI is not certificate-pinned: %s", client.Hysteria2.ShareURI)
	}
	if !strings.Contains(client.AnyTLS.ShareURI, "insecure=1") {
		t.Fatalf("AnyTLS self-signed share URI lacks explicit insecure flag: %s", client.AnyTLS.ShareURI)
	}
	if _, err := Generate(options); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("second Generate() error = %v", err)
	}
	options.Force = true
	if _, err := Generate(options); err != nil {
		t.Fatalf("forced Generate() error = %v", err)
	}
	entries, err := os.ReadDir(output)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), ".tmp-") || strings.HasSuffix(entry.Name(), ".backup") {
			t.Fatalf("temporary file left behind: %s", entry.Name())
		}
	}
}

func TestGenerateRealityOnlyDoesNotRequireTLS(t *testing.T) {
	_, err := Generate(GenerateOptions{
		Output: filepath.Join(t.TempDir(), "generated"), Protocols: []string{"reality"}, Listen: "::1",
		RealityPort: 20001, RealityServerName: "www.example.com", RealityHandshake: "www.example.com:443",
	})
	if err != nil {
		t.Fatal(err)
	}
}

func assertShareURI(t *testing.T, value, scheme, host string, port int) {
	t.Helper()
	parsed, err := url.Parse(value)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != scheme || parsed.Hostname() != host || parsed.Port() != strconv.Itoa(port) {
		t.Fatalf("share URI = %s", value)
	}
}

func TestGenerateRejectsInvalidInputs(t *testing.T) {
	base := GenerateOptions{
		Output: filepath.Join(t.TempDir(), "generated"), Protocols: []string{"hy2"}, Listen: "127.0.0.1",
		Hysteria2Port: 20002, TLSSAN: "server.example",
	}
	tests := []struct {
		name string
		edit func(*GenerateOptions)
	}{
		{"unknown protocol", func(o *GenerateOptions) { o.Protocols = []string{"unknown"} }},
		{"hostname listen", func(o *GenerateOptions) { o.Listen = "localhost" }},
		{"bad port", func(o *GenerateOptions) { o.Hysteria2Port = 80 }},
		{"bad SAN", func(o *GenerateOptions) { o.TLSSAN = "bad_name" }},
		{"bad public address", func(o *GenerateOptions) {
			o.PublicAddress = "https://server.example"
		}},
		{"bad public port", func(o *GenerateOptions) {
			o.PublicAddress = "server.example"
			o.PublicHysteria2Port = 70000
		}},
		{"public port without address", func(o *GenerateOptions) {
			o.PublicHysteria2Port = 25421
		}},
		{"bad reality name", func(o *GenerateOptions) {
			o.Protocols = []string{"reality"}
			o.RealityPort = 20001
			o.RealityServerName = "bad_name"
			o.RealityHandshake = "www.example.com:443"
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			options := base
			test.edit(&options)
			if _, err := Generate(options); err == nil {
				t.Fatal("Generate() unexpectedly succeeded")
			}
		})
	}
}

func TestGenerateRejectsConflictingPublicTCPPorts(t *testing.T) {
	_, err := Generate(GenerateOptions{
		Output:    filepath.Join(t.TempDir(), "generated"),
		Protocols: []string{"reality", "anytls"}, Listen: "127.0.0.1",
		PublicAddress: "server.example", PublicRealityPort: 443, PublicAnyTLSPort: 443,
		RealityPort: 20001, AnyTLSPort: 20003,
		RealityServerName: "www.example.com", RealityHandshake: "www.example.com:443",
		TLSSAN: "server.example",
	})
	if err == nil || !strings.Contains(err.Error(), "conflicts") {
		t.Fatalf("Generate() error = %v", err)
	}
}
