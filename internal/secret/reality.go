package secret

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
)

type RealityKeyPair struct {
	Private string
	Public  string
}

func RealityKeys() (RealityKeyPair, error) {
	privateKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return RealityKeyPair{}, err
	}
	return RealityKeyPair{
		Private: base64.RawURLEncoding.EncodeToString(privateKey.Bytes()),
		Public:  base64.RawURLEncoding.EncodeToString(privateKey.PublicKey().Bytes()),
	}, nil
}
