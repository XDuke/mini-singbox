package app

import (
	"context"
	"fmt"

	"github.com/XDuke/mini-singbox/internal/core"
)

// Check fully validates and instantiates the configuration without starting
// the box. It therefore does not bind sockets or perform DNS/network access.
func Check(configPath string) error {
	options, err := loadOptions(configPath)
	if err != nil {
		return err
	}
	b, err := core.New(context.Background(), options)
	if err != nil {
		return fmt.Errorf("core: cannot create sing-box: %w", err)
	}
	if err := b.Close(); err != nil {
		return fmt.Errorf("core: cannot close sing-box after check: %w", err)
	}
	return nil
}
