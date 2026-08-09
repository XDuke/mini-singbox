package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/XDuke/mini-singbox/internal/app"
	versioninfo "github.com/XDuke/mini-singbox/internal/version"
)

func main() {
	os.Exit(execute(os.Args[1:], os.Stdout, os.Stderr))
}

func execute(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return 2
	}
	switch args[0] {
	case "run":
		configPath, ok := parseConfigFlag("run", args[1:], stderr)
		if !ok {
			return 2
		}
		ctx, stop := app.SignalContext(context.Background(), func() { os.Exit(130) })
		defer stop()
		if err := app.Run(ctx, configPath); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "check":
		configPath, ok := parseConfigFlag("check", args[1:], stderr)
		if !ok {
			return 2
		}
		if err := app.Check(configPath); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintln(stdout, "configuration is valid")
		return 0
	case "generate":
		return executeGenerate(args[1:], stdout, stderr)
	case "deliver":
		return executeDeliver(args[1:], stdout, stderr)
	case "version":
		if len(args) != 1 {
			fmt.Fprintln(stderr, "version: unexpected arguments")
			return 2
		}
		fmt.Fprintln(stdout, versioninfo.String())
		return 0
	default:
		fmt.Fprintf(stderr, "unknown command %q\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func parseConfigFlag(command string, args []string, stderr io.Writer) (string, bool) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("c", "config.json", "path to mini-singbox config")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		if flags.NArg() != 0 {
			fmt.Fprintf(stderr, "%s: unexpected arguments\n", command)
		}
		return "", false
	}
	return *configPath, true
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, "usage: mini-singbox <run|check|generate|deliver|version> [options]")
}

func executeGenerate(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("generate", flag.ContinueOnError)
	flags.SetOutput(stderr)
	output := flags.String("output", ".", "output directory")
	protocolText := flags.String("protocols", "reality,hy2,anytls", "comma-separated protocols")
	listen := flags.String("listen", "::", "listening IP address")
	publicAddress := flags.String("public-address", "", "client-facing DNS name or IP address")
	realityPort := flags.Int("reality-port", 20001, "VLESS Reality port")
	hy2Port := flags.Int("hy2-port", 20002, "Hysteria2 port")
	anyTLSPort := flags.Int("anytls-port", 20003, "AnyTLS port")
	publicRealityPort := flags.Int("public-reality-port", 0, "client-facing VLESS Reality port (defaults to --reality-port)")
	publicHy2Port := flags.Int("public-hy2-port", 0, "client-facing Hysteria2 port (defaults to --hy2-port)")
	publicAnyTLSPort := flags.Int("public-anytls-port", 0, "client-facing AnyTLS port (defaults to --anytls-port)")
	realityServerName := flags.String("reality-server-name", "", "Reality server name")
	realityHandshake := flags.String("reality-handshake", "", "Reality handshake HOST:PORT")
	tlsSAN := flags.String("tls-san", "", "self-signed certificate DNS/IP SAN")
	force := flags.Bool("force", false, "replace existing generated files")
	showSecrets := flags.Bool("show-secrets", false, "print client credentials to stdout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		if flags.NArg() != 0 {
			fmt.Fprintln(stderr, "generate: unexpected arguments")
		}
		return 2
	}
	protocols := strings.Split(*protocolText, ",")
	result, err := app.Generate(app.GenerateOptions{
		Output: *output, Protocols: protocols, Listen: *listen, PublicAddress: *publicAddress,
		RealityPort: *realityPort, Hysteria2Port: *hy2Port, AnyTLSPort: *anyTLSPort,
		PublicRealityPort: *publicRealityPort, PublicHysteria2Port: *publicHy2Port,
		PublicAnyTLSPort:  *publicAnyTLSPort,
		RealityServerName: *realityServerName, RealityHandshake: *realityHandshake,
		TLSSAN: *tlsSAN, Force: *force,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	for _, path := range result.Files {
		fmt.Fprintln(stdout, path)
	}
	if *showSecrets {
		fmt.Fprintln(stderr, "WARNING: client credentials follow on stdout")
		stdout.Write(result.ClientInfo)
	}
	return 0
}

func executeDeliver(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("deliver", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("c", "config.json", "path to existing mini-singbox config")
	output := flags.String("output", ".", "delivery output directory")
	publicAddress := flags.String("public-address", "", "client-facing DNS name or IP address")
	realityPort := flags.Int("reality-port", 0, "client-facing VLESS Reality port")
	hy2Port := flags.Int("hy2-port", 0, "client-facing Hysteria2 port")
	anyTLSPort := flags.Int("anytls-port", 0, "client-facing AnyTLS port")
	force := flags.Bool("force", false, "replace existing delivery files")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		if flags.NArg() != 0 {
			fmt.Fprintln(stderr, "deliver: unexpected arguments")
		}
		return 2
	}
	result, err := app.Deliver(app.DeliverOptions{
		ConfigPath: *configPath, Output: *output, PublicAddress: *publicAddress,
		RealityPort: *realityPort, Hysteria2Port: *hy2Port, AnyTLSPort: *anyTLSPort,
		Force: *force,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	for _, path := range result.Files {
		fmt.Fprintln(stdout, path)
	}
	return 0
}
