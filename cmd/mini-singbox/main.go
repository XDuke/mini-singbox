package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/XDuke/mini-singbox/internal/app"
	"github.com/XDuke/mini-singbox/internal/tune"
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
	case "renew-certificate":
		return executeRenewCertificate(args[1:], stdout, stderr)
	case "tune":
		return executeTune(args[1:], stdout, stderr)
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
	fmt.Fprintln(writer, "usage: mini-singbox <run|check|generate|deliver|renew-certificate|tune|version> [options]")
}

func executeTune(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printTuneUsage(stderr)
		return 2
	}
	command := args[0]
	flags := flag.NewFlagSet("tune "+command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("c", tune.DefaultConfigPath, "path to mini-singbox config")
	stateDirectory := flags.String("state-dir", tune.DefaultStateDirectory, "tuning state directory")
	bandwidth := flags.Uint64("bw", 0, "known line rate in Mbps (no speed test is performed)")
	rtt := flags.Uint64("rtt", 0, "known round-trip time in milliseconds (no ping is performed)")
	dryRun := flags.Bool("dry-run", false, "show actions without modifying the system")
	if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 {
		if flags.NArg() != 0 {
			fmt.Fprintf(stderr, "tune %s: unexpected arguments\n", command)
		}
		return 2
	}
	if (*bandwidth == 0) != (*rtt == 0) {
		fmt.Fprintln(stderr, "tune: --bw and --rtt must be supplied together")
		return 2
	}
	if command != "apply" && *dryRun {
		fmt.Fprintln(stderr, "tune: --dry-run is valid only with apply")
		return 2
	}
	if command != "plan" && command != "apply" && (*bandwidth != 0 || *rtt != 0) {
		fmt.Fprintln(stderr, "tune: --bw and --rtt are valid only with plan or apply")
		return 2
	}
	manager := tune.New(tune.Options{
		ConfigPath: *configPath, StateDirectory: *stateDirectory, ProgramVersion: versioninfo.Version,
	})
	inputs := tune.Inputs{BandwidthMbps: *bandwidth, RTTMillis: *rtt}
	switch command {
	case "detect":
		profile, err := manager.Detect()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		tune.PrintProfile(stdout, profile)
	case "plan":
		plan, err := manager.Plan(inputs)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		tune.PrintPlan(stdout, plan)
	case "apply":
		result, err := manager.Apply(inputs, *dryRun)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		tune.PrintPlan(stdout, result.Plan)
		if result.DryRun {
			fmt.Fprintln(stdout, "Result: dry run; no system state changed")
			return 0
		}
		if len(result.Changed) == 0 {
			fmt.Fprintln(stdout, "Result: no safe changes were required or supported")
		} else {
			fmt.Fprintf(stdout, "Result: applied and verified %d sysctl change(s)\n", len(result.Changed))
		}
	case "verify":
		result, err := manager.Verify()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		tune.PrintVerification(stdout, result)
		if len(result.Drift) != 0 {
			return 1
		}
	case "status":
		plan, err := manager.Plan(tune.Inputs{})
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		tune.PrintPlan(stdout, plan)
		result, err := manager.Verify()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		tune.PrintVerification(stdout, result)
		if len(result.Drift) != 0 {
			return 1
		}
	case "rollback":
		restored, err := manager.Rollback()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		if len(restored) == 0 {
			fmt.Fprintln(stdout, "Result: no active mini-singbox tuning to rollback")
		} else {
			fmt.Fprintf(stdout, "Result: restored %d sysctl value(s) and removed managed persistence\n", len(restored))
		}
	case "help", "-h", "--help":
		printTuneUsage(stdout)
	default:
		fmt.Fprintf(stderr, "unknown tune command %q\n", command)
		printTuneUsage(stderr)
		return 2
	}
	return 0
}

func printTuneUsage(writer io.Writer) {
	fmt.Fprintln(writer, "usage: mini-singbox tune <detect|plan|apply|verify|status|rollback> [options]")
	fmt.Fprintln(writer, "       tune plan|apply [--bw Mbps --rtt ms]")
	fmt.Fprintln(writer, "       tune apply [--dry-run]")
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
	allowInsecureAnyTLSShare := flags.Bool("allow-insecure-anytls-share", false, "generate an unauthenticated AnyTLS URI (unsafe)")
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
		TLSSAN: *tlsSAN, AllowInsecureAnyTLSShare: *allowInsecureAnyTLSShare, Force: *force,
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
	allowInsecureAnyTLSShare := flags.Bool("allow-insecure-anytls-share", false, "generate an unauthenticated AnyTLS URI (unsafe)")
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
		AllowInsecureAnyTLSShare: *allowInsecureAnyTLSShare, Force: *force,
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

func executeRenewCertificate(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("renew-certificate", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("c", "config.json", "path to existing mini-singbox config")
	output := flags.String("output", ".", "empty staging output directory")
	publicAddress := flags.String("public-address", "", "client-facing DNS name or IP address")
	realityPort := flags.Int("reality-port", 0, "client-facing VLESS Reality port")
	hy2Port := flags.Int("hy2-port", 0, "client-facing Hysteria2 port")
	anyTLSPort := flags.Int("anytls-port", 0, "client-facing AnyTLS port")
	allowInsecureAnyTLSShare := flags.Bool("allow-insecure-anytls-share", false, "generate an unauthenticated AnyTLS URI (unsafe)")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		if flags.NArg() != 0 {
			fmt.Fprintln(stderr, "renew-certificate: unexpected arguments")
		}
		return 2
	}
	result, err := app.RenewCertificate(app.RenewCertificateOptions{
		ConfigPath: *configPath, Output: *output, PublicAddress: *publicAddress,
		RealityPort: *realityPort, Hysteria2Port: *hy2Port, AnyTLSPort: *anyTLSPort,
		AllowInsecureAnyTLSShare: *allowInsecureAnyTLSShare,
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
