package core

import (
	"context"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/adapter/inbound"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/adapter/service"
	"github.com/sagernet/sing-box/dns"
	dnslocal "github.com/sagernet/sing-box/dns/transport/local"
	"github.com/sagernet/sing-box/protocol/anytls"
	"github.com/sagernet/sing-box/protocol/hysteria2"
	"github.com/sagernet/sing-box/protocol/vless"
)

// Context returns the minimum registry set required by box.New. The outbound,
// endpoint, and service registries are deliberately empty. box.New provides
// the internal direct outbound, while only the local DNS transport is present.
func Context(parent context.Context) context.Context {
	inbounds := inbound.NewRegistry()
	vless.RegisterInbound(inbounds)
	hysteria2.RegisterInbound(inbounds)
	anytls.RegisterInbound(inbounds)

	dnsTransports := dns.NewTransportRegistry()
	dnslocal.RegisterTransport(dnsTransports)

	return box.Context(
		parent,
		inbounds,
		outbound.NewRegistry(),
		endpoint.NewRegistry(),
		dnsTransports,
		service.NewRegistry(),
	)
}
