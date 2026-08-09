package app

import (
	"context"
	"os"
	"os/signal"
	"syscall"
)

// SignalContext cancels on the first termination signal and invokes force on
// the second. stop must be called to release signal resources.
func SignalContext(parent context.Context, force func()) (context.Context, func()) {
	ctx, cancel := context.WithCancel(parent)
	signals := make(chan os.Signal, 2)
	done := make(chan struct{})
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		select {
		case <-signals:
			cancel()
		case <-done:
			return
		}
		select {
		case <-signals:
			if force != nil {
				force()
			}
		case <-done:
		}
	}()
	return ctx, func() {
		signal.Stop(signals)
		close(done)
		cancel()
	}
}
