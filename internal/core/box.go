package core

import (
	"context"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/option"
)

// New creates the single sing-box instance used by mini-singbox.
func New(parent context.Context, options option.Options) (*box.Box, error) {
	return box.New(box.Options{
		Context: Context(parent),
		Options: options,
	})
}
