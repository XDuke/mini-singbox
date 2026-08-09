package config

const (
	SchemaVersion = 1
	MaxConfigSize = 1 << 20
)

type Config struct {
	SchemaVersion int                 `json:"schema_version"`
	Log           *LogConfig          `json:"log,omitempty"`
	VLESSReality  *VLESSRealityConfig `json:"vless_reality,omitempty"`
	Hysteria2     *Hysteria2Config    `json:"hysteria2,omitempty"`
	AnyTLS        *AnyTLSConfig       `json:"anytls,omitempty"`
}

type LogConfig struct {
	Level string `json:"level"`
}

type VLESSRealityConfig struct {
	Listen          string `json:"listen"`
	Port            int    `json:"port"`
	UUID            string `json:"uuid"`
	PrivateKeyPath  string `json:"private_key_path"`
	ShortID         string `json:"short_id"`
	ServerName      string `json:"server_name"`
	HandshakeServer string `json:"handshake_server"`
	HandshakePort   int    `json:"handshake_port"`
}

type Hysteria2Config struct {
	Listen          string `json:"listen"`
	Port            int    `json:"port"`
	Password        string `json:"password"`
	CertificatePath string `json:"certificate_path"`
	KeyPath         string `json:"key_path"`
	UpMbps          *int   `json:"up_mbps,omitempty"`
	DownMbps        *int   `json:"down_mbps,omitempty"`
}

type AnyTLSConfig struct {
	Listen          string `json:"listen"`
	Port            int    `json:"port"`
	Password        string `json:"password"`
	CertificatePath string `json:"certificate_path"`
	KeyPath         string `json:"key_path"`
}

func (c *Config) LogLevel() string {
	if c.Log == nil || c.Log.Level == "" {
		return "warn"
	}
	return c.Log.Level
}
