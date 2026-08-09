//go:build fuzz

package config

import (
	"bytes"
	"testing"
)

func FuzzDecode(f *testing.F) {
	f.Add([]byte(`{"schema_version":1}`))
	f.Add([]byte(`{"schema_version":1,"unknown":true}`))
	f.Fuzz(func(t *testing.T, content []byte) {
		_, _ = Decode(bytes.NewReader(content))
	})
}
