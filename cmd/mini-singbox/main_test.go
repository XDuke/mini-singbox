package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func TestVersion(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := execute([]string{"version"}, &stdout, &stderr); code != 0 {
		t.Fatalf("execute(version) = %d, stderr = %s", code, stderr.String())
	}
	for _, expected := range []string{"mini-singbox", "go_version", "sing_box_version", "target", "dirty_build"} {
		if !strings.Contains(stdout.String(), expected) {
			t.Fatalf("version output missing %q: %s", expected, stdout.String())
		}
	}
}

func TestUnknownCommand(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := execute([]string{"unknown"}, &stdout, &stderr); code != 2 {
		t.Fatalf("execute(unknown) = %d, want 2", code)
	}
}

func TestGenerateCommandHidesSecretsByDefault(t *testing.T) {
	var stdout, stderr bytes.Buffer
	output := filepath.Join(t.TempDir(), "generated")
	code := execute([]string{
		"generate", "--output", output, "--protocols", "reality,hy2,anytls",
		"--listen", "127.0.0.1", "--public-address", "203.0.113.10",
		"--reality-server-name", "www.example.com",
		"--reality-handshake", "www.example.com:443", "--tls-san", "server.example",
	}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("execute(generate) = %d, stderr = %s", code, stderr.String())
	}
	if strings.Contains(stdout.String(), "password") || strings.Contains(stdout.String(), "private") {
		t.Fatalf("default output leaked secret material: %s", stdout.String())
	}
}

func TestDeliverCommandHidesSecrets(t *testing.T) {
	var stdout, stderr bytes.Buffer
	serverDirectory := filepath.Join(t.TempDir(), "server")
	code := execute([]string{
		"generate", "--output", serverDirectory, "--protocols", "reality,hy2,anytls",
		"--listen", "127.0.0.1", "--reality-server-name", "www.example.com",
		"--reality-handshake", "www.example.com:443", "--tls-san", "server.example",
	}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("execute(generate) = %d, stderr = %s", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	deliveryDirectory := filepath.Join(t.TempDir(), "delivery")
	code = execute([]string{
		"deliver", "-c", filepath.Join(serverDirectory, "config.json"),
		"--output", deliveryDirectory, "--public-address", "203.0.113.10",
		"--reality-port", "51165", "--hy2-port", "25421", "--anytls-port", "36279",
	}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("execute(deliver) = %d, stderr = %s", code, stderr.String())
	}
	if strings.Contains(stdout.String(), "password") || strings.Contains(stdout.String(), "vless://") ||
		strings.Contains(stdout.String(), "hysteria2://") || strings.Contains(stdout.String(), "anytls://") {
		t.Fatalf("deliver output leaked secret material: %s", stdout.String())
	}
}
