package secret

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
)

func randomBytes(size int) ([]byte, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return nil, fmt.Errorf("secure random: %w", err)
	}
	return value, nil
}

func Password() (string, error) {
	value, err := randomBytes(32)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func ShortID() (string, error) {
	value, err := randomBytes(8)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func UUIDv4() (string, error) {
	value, err := randomBytes(16)
	if err != nil {
		return "", err
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		value[0:4], value[4:6], value[6:8], value[8:10], value[10:16]), nil
}
