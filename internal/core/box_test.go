package core

import (
	"context"
	"testing"

	"github.com/sagernet/sing-box/option"
)

func TestNewWithMinimumRegistries(t *testing.T) {
	b, err := New(context.Background(), option.Options{
		Log: &option.LogOptions{Level: "error"},
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	if err := b.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
}
