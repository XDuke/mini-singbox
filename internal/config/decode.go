package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

func Decode(reader io.Reader) (*Config, error) {
	content, err := io.ReadAll(io.LimitReader(reader, MaxConfigSize+1))
	if err != nil {
		return nil, fieldError("config", "cannot read JSON", "make the file readable and try again")
	}
	if len(content) > MaxConfigSize {
		return nil, fieldError("config", fmt.Sprintf("size exceeds %d bytes", MaxConfigSize), "reduce the config to at most 1 MiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	var result Config
	if err := decoder.Decode(&result); err != nil {
		return nil, fieldError("config", fmt.Sprintf("invalid JSON or unknown field: %v", err), "use only fields defined by schema_version 1")
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return nil, fieldError("config", "contains trailing JSON data", "keep exactly one JSON object")
	}
	return &result, nil
}

func DecodeFile(path string) (*Config, error) {
	if path == "" {
		return nil, fieldError("config", "path is empty", "pass -c CONFIG")
	}
	if err := checkFile(path, fileConfig); err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fieldError("config", "cannot open file", "make it readable by the service user")
	}
	defer file.Close()
	result, err := Decode(file)
	if err != nil {
		return nil, err
	}
	absolutePath, err := filepath.Abs(path)
	if err != nil {
		return nil, fieldError("config", "cannot resolve path", "use a valid local config path")
	}
	resolveRelativePaths(result, filepath.Dir(absolutePath))
	return result, nil
}

func resolveRelativePaths(result *Config, directory string) {
	if result.VLESSReality != nil && result.VLESSReality.PrivateKeyPath != "" && !filepath.IsAbs(result.VLESSReality.PrivateKeyPath) {
		result.VLESSReality.PrivateKeyPath = filepath.Join(directory, result.VLESSReality.PrivateKeyPath)
	}
	if result.Hysteria2 != nil {
		if result.Hysteria2.CertificatePath != "" && !filepath.IsAbs(result.Hysteria2.CertificatePath) {
			result.Hysteria2.CertificatePath = filepath.Join(directory, result.Hysteria2.CertificatePath)
		}
		if result.Hysteria2.KeyPath != "" && !filepath.IsAbs(result.Hysteria2.KeyPath) {
			result.Hysteria2.KeyPath = filepath.Join(directory, result.Hysteria2.KeyPath)
		}
	}
	if result.AnyTLS != nil {
		if result.AnyTLS.CertificatePath != "" && !filepath.IsAbs(result.AnyTLS.CertificatePath) {
			result.AnyTLS.CertificatePath = filepath.Join(directory, result.AnyTLS.CertificatePath)
		}
		if result.AnyTLS.KeyPath != "" && !filepath.IsAbs(result.AnyTLS.KeyPath) {
			result.AnyTLS.KeyPath = filepath.Join(directory, result.AnyTLS.KeyPath)
		}
	}
}
