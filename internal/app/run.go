package app

import (
	"context"
	"fmt"

	"github.com/XDuke/mini-singbox/internal/config"
	"github.com/XDuke/mini-singbox/internal/core"
	"github.com/sagernet/sing-box/option"
)

func loadOptions(path string) (option.Options, error) {
	localConfig, err := config.DecodeFile(path)
	if err != nil {
		return option.Options{}, err
	}
	validated, err := config.Validate(localConfig)
	if err != nil {
		return option.Options{}, err
	}
	return config.Convert(validated), nil
}

func Run(ctx context.Context, configPath string) error {
	options, err := loadOptions(configPath)
	if err != nil {
		return err
	}
	b, err := core.New(ctx, options)
	if err != nil {
		return fmt.Errorf("core: cannot create sing-box: %w", err)
	}
	if err := b.Start(); err != nil {
		_ = b.Close()
		return fmt.Errorf("core: cannot start sing-box: %w", err)
	}
	<-ctx.Done()
	if err := b.Close(); err != nil {
		return fmt.Errorf("core: cannot close sing-box: %w", err)
	}
	return nil
}
