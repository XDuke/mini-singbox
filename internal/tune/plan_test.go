package tune

import (
	"math"
	"testing"
)

func TestBuildPlanSafeCore(t *testing.T) {
	profile := testProfile()
	plan, err := BuildPlan(profile, Inputs{BandwidthMbps: 500, RTTMillis: 80})
	if err != nil {
		t.Fatal(err)
	}
	if plan.BDPBytes != 5_000_000 {
		t.Fatalf("BDPBytes = %d, want 5000000", plan.BDPBytes)
	}
	want := map[string]Action{
		KeyDefaultQdisc: ActionSet, KeyCongestionControl: ActionSet,
		KeyMTUProbing: ActionSet, KeySlowStartAfterIdle: ActionKeep,
	}
	for _, action := range plan.Actions {
		if action.Action != want[action.Key] {
			t.Fatalf("%s action = %s, want %s", action.Key, action.Action, want[action.Key])
		}
		if action.Action == ActionSet && action.Confidence != ConfidenceHigh {
			t.Fatalf("automatic action %s confidence = %s", action.Key, action.Confidence)
		}
	}
}

func TestBuildPlanHysteria2OnlySkipsTCP(t *testing.T) {
	profile := testProfile()
	profile.Workload = WorkloadProfile{Hysteria2: true}
	plan, err := BuildPlan(profile, Inputs{})
	if err != nil {
		t.Fatal(err)
	}
	for _, action := range plan.Actions {
		if action.Action != ActionSkip {
			t.Fatalf("%s action = %s, want SKIP", action.Key, action.Action)
		}
	}
}

func TestBuildPlanDoesNotGuessUnavailableFeatures(t *testing.T) {
	profile := testProfile()
	profile.FQAvailable = false
	profile.AvailableCC = []string{"reno", "cubic"}
	plan, err := BuildPlan(profile, Inputs{})
	if err != nil {
		t.Fatal(err)
	}
	actions := actionMap(plan)
	if actions[KeyDefaultQdisc].Action != ActionManual {
		t.Fatalf("qdisc action = %s, want MANUAL", actions[KeyDefaultQdisc].Action)
	}
	if actions[KeyCongestionControl].Action != ActionSkip {
		t.Fatalf("congestion action = %s, want SKIP", actions[KeyCongestionControl].Action)
	}
}

func TestBuildPlanPreservesAdministratorChoices(t *testing.T) {
	profile := testProfile()
	profile.Sysctls[KeyDefaultQdisc] = "cake"
	profile.Sysctls[KeyCongestionControl] = "dctcp"
	profile.Sysctls[KeyMTUProbing] = "2"
	plan, err := BuildPlan(profile, Inputs{})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{KeyDefaultQdisc, KeyCongestionControl, KeyMTUProbing} {
		action := actionMap(plan)[key]
		if action.Action != ActionKeep || action.ProposedValue != action.CurrentValue {
			t.Fatalf("%s action = %+v, want preserved KEEP", key, action)
		}
	}
}

func TestBuildPlanBDPOverflow(t *testing.T) {
	_, err := BuildPlan(testProfile(), Inputs{BandwidthMbps: math.MaxUint64, RTTMillis: 2})
	if err == nil {
		t.Fatal("BuildPlan accepted overflowing BDP")
	}
}

func TestMemoryPolicies(t *testing.T) {
	const mib = 1024 * 1024
	tests := []struct {
		memory uint64
		want   string
	}{
		{128 * mib, "ultra-low-memory"},
		{256 * mib, "low-memory"},
		{512 * mib, "conservative"},
		{1024 * mib, "proxy-small"},
	}
	for _, test := range tests {
		if got := memoryPolicy(test.memory); got != test.want {
			t.Errorf("memoryPolicy(%d) = %q, want %q", test.memory, got, test.want)
		}
	}
}

func testProfile() Profile {
	writable := make(map[string]bool)
	for _, key := range managedKeys {
		writable[key] = true
	}
	return Profile{
		Environment:  EnvironmentProfile{EffectiveMemoryBytes: 128 * 1024 * 1024, MemoryPolicy: "ultra-low-memory"},
		Capabilities: CapabilityProfile{Root: true, SysctlWritable: writable},
		Workload:     WorkloadProfile{Reality: true, AnyTLS: true, Hysteria2: true},
		Sysctls: map[string]string{
			KeyDefaultQdisc: "fq_codel", KeyCongestionControl: "cubic",
			KeyAvailableCC: "reno cubic bbr", KeyMTUProbing: "0", KeySlowStartAfterIdle: "1",
		},
		AvailableCC: []string{"reno", "cubic", "bbr"}, FQAvailable: true,
	}
}

func actionMap(plan Plan) map[string]TuneAction {
	result := make(map[string]TuneAction)
	for _, action := range plan.Actions {
		result[action.Key] = action
	}
	return result
}
