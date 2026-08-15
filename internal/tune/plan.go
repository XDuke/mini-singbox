package tune

import (
	"fmt"
	"math"
	"slices"
)

func BuildPlan(profile Profile, inputs Inputs) (Plan, error) {
	plan := Plan{Profile: profile, Inputs: inputs}
	if inputs.BandwidthMbps > 0 && inputs.RTTMillis > 0 {
		if inputs.BandwidthMbps > math.MaxUint64/inputs.RTTMillis/125 {
			return Plan{}, fmt.Errorf("bandwidth and RTT produce an overflowing BDP")
		}
		plan.BDPBytes = inputs.BandwidthMbps * inputs.RTTMillis * 125
	}

	if !profile.Workload.TCPEnabled() {
		for _, key := range managedKeys {
			plan.Actions = append(plan.Actions, TuneAction{
				Key: key, CurrentValue: profile.Sysctls[key], Action: ActionSkip,
				Reason: "no TCP proxy protocol is enabled; Hysteria2 remains UDP/QUIC observation-only",
				Risk:   "none", Confidence: ConfidenceHigh,
			})
		}
		return plan, nil
	}

	plan.Actions = append(plan.Actions,
		planQdisc(profile),
		planCongestionControl(profile),
		planMTUProbing(profile),
		TuneAction{
			Key: KeySlowStartAfterIdle, CurrentValue: profile.Sysctls[KeySlowStartAfterIdle],
			Action: ActionKeep, Reason: "conservative policy keeps the kernel or administrator choice",
			Risk: "changing idle restart can create bursts", Confidence: ConfidenceHigh,
		},
	)
	return plan, nil
}

func planQdisc(profile Profile) TuneAction {
	current := profile.Sysctls[KeyDefaultQdisc]
	if current == "fq" {
		return TuneAction{Key: KeyDefaultQdisc, CurrentValue: current, ProposedValue: "fq", Action: ActionKeep,
			Reason: "fq is already the default qdisc", Risk: "low", Confidence: ConfidenceHigh}
	}
	if current == "" {
		return unsupported(KeyDefaultQdisc, current, "fq", "the sysctl is unavailable")
	}
	if current != "pfifo_fast" && current != "fq_codel" {
		return TuneAction{Key: KeyDefaultQdisc, CurrentValue: current, ProposedValue: current, Action: ActionKeep,
			Reason: "an existing non-generic qdisc is preserved as an administrator or provider choice",
			Risk:   "overriding an intentional qdisc is unsafe", Confidence: ConfidenceHigh}
	}
	if !profile.FQAvailable {
		return TuneAction{Key: KeyDefaultQdisc, CurrentValue: current, ProposedValue: "fq", Action: ActionManual,
			Reason: "fq support could not be proven without loading a kernel module", Risk: "kernel may reject fq",
			Capability: "fq availability unknown", Confidence: ConfidenceLow}
	}
	if !profile.Capabilities.SysctlWritable[KeyDefaultQdisc] {
		return unsupported(KeyDefaultQdisc, current, "fq", "the current namespace cannot write this sysctl")
	}
	return TuneAction{Key: KeyDefaultQdisc, CurrentValue: current, ProposedValue: "fq", Action: ActionSet,
		Reason:     "fq provides per-flow pacing for future default qdiscs; the live interface is not replaced",
		Risk:       "low; an existing live qdisc remains unchanged",
		Capability: "fq present and sysctl writable", Confidence: ConfidenceHigh}
}

func planCongestionControl(profile Profile) TuneAction {
	current := profile.Sysctls[KeyCongestionControl]
	if current == "bbr" {
		return TuneAction{Key: KeyCongestionControl, CurrentValue: current, ProposedValue: "bbr", Action: ActionKeep,
			Reason: "BBR is already selected", Risk: "low", Confidence: ConfidenceHigh}
	}
	if !slices.Contains(profile.AvailableCC, "bbr") {
		return TuneAction{Key: KeyCongestionControl, CurrentValue: current, ProposedValue: "bbr", Action: ActionSkip,
			Reason: "BBR is not registered in tcp_available_congestion_control; no module or kernel change is attempted",
			Risk:   "none", Capability: "bbr unavailable", Confidence: ConfidenceHigh}
	}
	if current == "" {
		return unsupported(KeyCongestionControl, current, "bbr", "the sysctl is unavailable")
	}
	if current != "cubic" && current != "reno" {
		return TuneAction{Key: KeyCongestionControl, CurrentValue: current, ProposedValue: current, Action: ActionKeep,
			Reason: "an existing non-generic congestion control is preserved as an administrator or provider choice",
			Risk:   "overriding an intentional algorithm is unsafe", Confidence: ConfidenceHigh}
	}
	if !profile.Capabilities.SysctlWritable[KeyCongestionControl] {
		return unsupported(KeyCongestionControl, current, "bbr", "the current namespace cannot write this sysctl")
	}
	return TuneAction{Key: KeyCongestionControl, CurrentValue: current, ProposedValue: "bbr", Action: ActionSet,
		Reason: "BBR is already registered by the running kernel", Risk: "low",
		Capability: "bbr advertised and sysctl writable", Confidence: ConfidenceHigh}
}

func planMTUProbing(profile Profile) TuneAction {
	current := profile.Sysctls[KeyMTUProbing]
	if current == "1" || current == "2" {
		return TuneAction{Key: KeyMTUProbing, CurrentValue: current, ProposedValue: current, Action: ActionKeep,
			Reason: "TCP MTU probing is already enabled; the existing mode is preserved", Risk: "low", Confidence: ConfidenceHigh}
	}
	if current == "" {
		return unsupported(KeyMTUProbing, current, "1", "the sysctl is unavailable")
	}
	if !profile.Capabilities.SysctlWritable[KeyMTUProbing] {
		return unsupported(KeyMTUProbing, current, "1", "the current namespace cannot write this sysctl")
	}
	return TuneAction{Key: KeyMTUProbing, CurrentValue: current, ProposedValue: "1", Action: ActionSet,
		Reason: "mode 1 activates TCP PLPMTUD only after an ICMP black hole is detected", Risk: "low",
		Capability: "sysctl writable", Confidence: ConfidenceHigh}
}

func unsupported(key, current, proposed, reason string) TuneAction {
	return TuneAction{Key: key, CurrentValue: current, ProposedValue: proposed, Action: ActionUnsupported,
		Reason: reason, Risk: "none", Capability: "unavailable", Confidence: ConfidenceHigh}
}

func memoryPolicy(bytes uint64) string {
	const mib = 1024 * 1024
	switch {
	case bytes == 0:
		return "unknown"
	case bytes <= 128*mib:
		return "ultra-low-memory"
	case bytes <= 256*mib:
		return "low-memory"
	case bytes <= 512*mib:
		return "conservative"
	default:
		return "proxy-small"
	}
}
