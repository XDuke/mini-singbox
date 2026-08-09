package config

import (
	"net/netip"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func Convert(validated *Validated) option.Options {
	c := validated.Config
	options := option.Options{
		Log: &option.LogOptions{Level: c.LogLevel(), Timestamp: true},
	}
	if c.VLESSReality != nil {
		listen := badoption.Addr(netip.MustParseAddr(c.VLESSReality.Listen))
		options.Inbounds = append(options.Inbounds, option.Inbound{
			Type: C.TypeVLESS,
			Tag:  "vless-reality",
			Options: &option.VLESSInboundOptions{
				ListenOptions: option.ListenOptions{Listen: &listen, ListenPort: uint16(c.VLESSReality.Port)},
				Users:         []option.VLESSUser{{UUID: c.VLESSReality.UUID, Flow: "xtls-rprx-vision"}},
				InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{TLS: &option.InboundTLSOptions{
					Enabled:    true,
					ServerName: c.VLESSReality.ServerName,
					Reality: &option.InboundRealityOptions{
						Enabled: true,
						Handshake: option.InboundRealityHandshakeOptions{ServerOptions: option.ServerOptions{
							Server: c.VLESSReality.HandshakeServer, ServerPort: uint16(c.VLESSReality.HandshakePort),
						}},
						PrivateKey: validated.RealityPrivateKey,
						ShortID:    badoption.Listable[string]{c.VLESSReality.ShortID},
					},
				}},
			},
		})
	}
	if c.Hysteria2 != nil {
		listen := badoption.Addr(netip.MustParseAddr(c.Hysteria2.Listen))
		hy2 := &option.Hysteria2InboundOptions{
			ListenOptions: option.ListenOptions{Listen: &listen, ListenPort: uint16(c.Hysteria2.Port)},
			Users:         []option.Hysteria2User{{Password: c.Hysteria2.Password}},
			InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{TLS: &option.InboundTLSOptions{
				Enabled:         true,
				MinVersion:      "1.3",
				CertificatePath: c.Hysteria2.CertificatePath,
				KeyPath:         c.Hysteria2.KeyPath,
			}},
		}
		if c.Hysteria2.UpMbps != nil {
			hy2.UpMbps = *c.Hysteria2.UpMbps
		}
		if c.Hysteria2.DownMbps != nil {
			hy2.DownMbps = *c.Hysteria2.DownMbps
		}
		options.Inbounds = append(options.Inbounds, option.Inbound{Type: C.TypeHysteria2, Tag: "hysteria2", Options: hy2})
	}
	if c.AnyTLS != nil {
		listen := badoption.Addr(netip.MustParseAddr(c.AnyTLS.Listen))
		options.Inbounds = append(options.Inbounds, option.Inbound{
			Type: C.TypeAnyTLS,
			Tag:  "anytls",
			Options: &option.AnyTLSInboundOptions{
				ListenOptions: option.ListenOptions{Listen: &listen, ListenPort: uint16(c.AnyTLS.Port)},
				Users:         []option.AnyTLSUser{{Password: c.AnyTLS.Password}},
				InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{TLS: &option.InboundTLSOptions{
					Enabled:         true,
					MinVersion:      "1.3",
					CertificatePath: c.AnyTLS.CertificatePath,
					KeyPath:         c.AnyTLS.KeyPath,
				}},
			},
		})
	}
	return options
}
