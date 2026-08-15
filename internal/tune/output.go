package tune

import (
	"fmt"
	"io"
	"strings"
)

func PrintProfile(writer io.Writer, profile Profile) {
	environment := profile.Environment
	fmt.Fprintln(writer, "Environment")
	fmt.Fprintf(writer, "  Distribution   : %s\n", valueOrUnknown(environment.Distribution))
	fmt.Fprintf(writer, "  Kernel         : %s\n", valueOrUnknown(environment.Kernel))
	fmt.Fprintf(writer, "  Architecture   : %s\n", valueOrUnknown(environment.Architecture))
	fmt.Fprintf(writer, "  Virtualization : %s\n", valueOrUnknown(environment.Virtualization))
	fmt.Fprintf(writer, "  Visible RAM    : %s\n", formatBytes(environment.VisibleMemoryBytes))
	fmt.Fprintf(writer, "  Cgroup limit   : %s\n", formatBytes(environment.CgroupMemoryLimit))
	fmt.Fprintf(writer, "  Effective RAM  : %s (%s)\n", formatBytes(environment.EffectiveMemoryBytes), environment.MemoryPolicy)
	fmt.Fprintf(writer, "  CPU            : %d logical, %d effective\n", environment.LogicalCPUs, environment.EffectiveCPUs)
	fmt.Fprintf(writer, "  Interface      : %s\n", valueOrUnknown(environment.Interface))
	if environment.MTU > 0 {
		fmt.Fprintf(writer, "  MTU            : %d\n", environment.MTU)
	} else {
		fmt.Fprintln(writer, "  MTU            : unknown")
	}
	fmt.Fprintf(writer, "  TCP CC         : %s\n", valueOrUnknown(profile.Sysctls[KeyCongestionControl]))
	fmt.Fprintf(writer, "  Default qdisc  : %s\n", valueOrUnknown(profile.Sysctls[KeyDefaultQdisc]))
	fmt.Fprintf(writer, "  BBR available  : %s\n", yesNo(contains(profile.AvailableCC, "bbr")))
	fmt.Fprintf(writer, "  fq available   : %s\n", yesNo(profile.FQAvailable))

	fmt.Fprintln(writer, "Workload")
	fmt.Fprintf(writer, "  Reality        : %s (TCP)\n", enabled(profile.Workload.Reality))
	fmt.Fprintf(writer, "  AnyTLS         : %s (TCP)\n", enabled(profile.Workload.AnyTLS))
	fmt.Fprintf(writer, "  Hysteria2      : %s (UDP/QUIC, observe only)\n", enabled(profile.Workload.Hysteria2))

	fmt.Fprintln(writer, "Capabilities")
	fmt.Fprintf(writer, "  Root           : %s\n", yesNo(profile.Capabilities.Root))
	fmt.Fprintf(writer, "  CAP_NET_ADMIN  : %s\n", yesNo(profile.Capabilities.NetAdmin))
	writable := 0
	for _, key := range managedKeys {
		if profile.Capabilities.SysctlWritable[key] {
			writable++
		}
	}
	fmt.Fprintf(writer, "  Sysctl write   : %d/%d managed keys\n", writable, len(managedKeys))
	for _, warning := range profile.Warnings {
		fmt.Fprintf(writer, "  Warning        : %s\n", warning)
	}
}

func PrintPlan(writer io.Writer, plan Plan) {
	PrintProfile(writer, plan.Profile)
	fmt.Fprintln(writer, "Measurement")
	if plan.Inputs.BandwidthMbps == 0 {
		fmt.Fprintln(writer, "  Bandwidth      : unknown (no active speed test performed)")
	} else {
		fmt.Fprintf(writer, "  Bandwidth      : %d Mbps (user supplied)\n", plan.Inputs.BandwidthMbps)
	}
	if plan.Inputs.RTTMillis == 0 {
		fmt.Fprintln(writer, "  RTT            : unknown (no public host contacted)")
	} else {
		fmt.Fprintf(writer, "  RTT            : %d ms (user supplied)\n", plan.Inputs.RTTMillis)
	}
	if plan.BDPBytes > 0 {
		fmt.Fprintf(writer, "  BDP            : %s (informational; automatic buffer tuning is disabled)\n", formatBytes(plan.BDPBytes))
	}
	fmt.Fprintln(writer, "Plan")
	for _, action := range plan.Actions {
		values := ""
		if action.ProposedValue != "" && action.CurrentValue != action.ProposedValue {
			values = fmt.Sprintf(" %s -> %s", valueOrUnknown(action.CurrentValue), action.ProposedValue)
		}
		fmt.Fprintf(writer, "  [%-11s] %s%s — %s\n", action.Action, action.Key, values, action.Reason)
	}
}

func PrintVerification(writer io.Writer, result VerifyResult) {
	if !result.Managed {
		fmt.Fprintln(writer, "Tuning state: unmanaged")
		return
	}
	fmt.Fprintf(writer, "Tuning state: %s\n", result.Phase)
	if len(result.Drift) == 0 {
		fmt.Fprintln(writer, "Verification: managed runtime values and persistence match; no drift")
		return
	}
	fmt.Fprintln(writer, "Verification: drift detected")
	for _, item := range result.Drift {
		fmt.Fprintf(writer, "  - %s\n", item)
	}
}

func formatBytes(bytes uint64) string {
	if bytes == 0 {
		return "unknown"
	}
	const mib = 1024 * 1024
	if bytes%mib == 0 {
		return fmt.Sprintf("%d MiB", bytes/mib)
	}
	return fmt.Sprintf("%.1f MiB", float64(bytes)/mib)
}

func valueOrUnknown(value string) string {
	if strings.TrimSpace(value) == "" {
		return "unknown"
	}
	return value
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func enabled(value bool) string {
	if value {
		return "enabled"
	}
	return "disabled"
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}
