package tune

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDetectUsesNestedCgroupV2Limit(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	writeTestFile(t, filepath.Join(manager.options.ProcDirectory, "self/cgroup"), "0::/tenant/mini\n")
	writeTestFile(t, filepath.Join(manager.options.SysDirectory, "fs/cgroup/tenant/mini/memory.max"), "134217728\n")
	profile, err := manager.Detect()
	if err != nil {
		t.Fatal(err)
	}
	if profile.Environment.VisibleMemoryBytes != 8*1024*1024*1024 {
		t.Fatalf("visible memory = %d", profile.Environment.VisibleMemoryBytes)
	}
	if profile.Environment.CgroupMemoryLimit != 128*1024*1024 {
		t.Fatalf("cgroup limit = %d, want 128 MiB", profile.Environment.CgroupMemoryLimit)
	}
	if profile.Environment.EffectiveMemoryBytes != 128*1024*1024 {
		t.Fatalf("effective memory = %d, want 128 MiB", profile.Environment.EffectiveMemoryBytes)
	}
}

func TestDetectUsesSmallestCgroupAncestorLimit(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	writeTestFile(t, filepath.Join(manager.options.ProcDirectory, "self/cgroup"), "0::/tenant/mini\n")
	writeTestFile(t, filepath.Join(manager.options.SysDirectory, "fs/cgroup/tenant/memory.max"), "67108864\n")
	writeTestFile(t, filepath.Join(manager.options.SysDirectory, "fs/cgroup/tenant/mini/memory.max"), "max\n")
	profile, err := manager.Detect()
	if err != nil {
		t.Fatal(err)
	}
	if profile.Environment.CgroupMemoryLimit != 64*1024*1024 {
		t.Fatalf("cgroup limit = %d, want 64 MiB ancestor limit", profile.Environment.CgroupMemoryLimit)
	}
}

func TestFQModuleFileAloneDoesNotAuthorizeApply(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	if err := os.RemoveAll(filepath.Join(manager.options.SysDirectory, "module/sch_fq")); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(manager.options.RootDirectory, "lib/modules/6.12.0-test/kernel/net/sched/sch_fq.ko"), "module")
	profile, err := manager.Detect()
	if err != nil {
		t.Fatal(err)
	}
	if profile.FQAvailable {
		t.Fatal("an unloaded module file must not authorize automatic fq selection")
	}
}

func TestCgroupV1AndUnlimitedSentinel(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	writeTestFile(t, filepath.Join(manager.options.ProcDirectory, "self/cgroup"), "5:memory:/lxc/example\n")
	limitPath := filepath.Join(manager.options.SysDirectory, "fs/cgroup/memory/lxc/example/memory.limit_in_bytes")
	writeTestFile(t, limitPath, "268435456\n")
	if got := manager.cgroupMemoryLimit(8 * 1024 * 1024 * 1024); got != 256*1024*1024 {
		t.Fatalf("v1 limit = %d, want 256 MiB", got)
	}
	writeTestFile(t, limitPath, "9223372036854771712\n")
	if got := manager.cgroupMemoryLimit(8 * 1024 * 1024 * 1024); got != 0 {
		t.Fatalf("unlimited sentinel = %d, want 0", got)
	}
}

func TestCPUListCount(t *testing.T) {
	tests := map[string]int{"0": 1, "0-1": 2, "0-1,4,6-7": 5, "bad": 0, "3-1": 0}
	for value, expected := range tests {
		if actual := cpuListCount(value); actual != expected {
			t.Errorf("cpuListCount(%q) = %d, want %d", value, actual, expected)
		}
	}
}

func TestDefaultInterfaceFallsBackToIPv6(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{AnyTLS: true})
	writeTestFile(t, filepath.Join(manager.options.ProcDirectory, "net/route"), "Iface Destination Gateway Flags\n")
	writeTestFile(t, filepath.Join(manager.options.ProcDirectory, "net/ipv6_route"), strings.Repeat("0", 32)+" 00 "+strings.Repeat("0", 32)+" 00 "+strings.Repeat("0", 32)+" 00000000 00000000 00000000 00000001 eth6\n")
	if actual := manager.defaultInterface(); actual != "eth6" {
		t.Fatalf("defaultInterface() = %q, want eth6", actual)
	}
}

func TestApplyVerifyAndRollback(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true, AnyTLS: true, Hysteria2: true})
	result, err := manager.Apply(Inputs{}, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Changed) != 3 {
		t.Fatalf("changed = %v, want three safe-core keys", result.Changed)
	}
	assertSysctl(t, manager, KeyDefaultQdisc, "fq")
	assertSysctl(t, manager, KeyCongestionControl, "bbr")
	assertSysctl(t, manager, KeyMTUProbing, "1")
	assertSysctl(t, manager, KeySlowStartAfterIdle, "1")
	verification, err := manager.Verify()
	if err != nil {
		t.Fatal(err)
	}
	if !verification.Managed || len(verification.Drift) != 0 {
		t.Fatalf("verification = %+v", verification)
	}
	content, err := os.ReadFile(manager.options.SysctlFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(content), KeySlowStartAfterIdle) {
		t.Fatal("persistence claimed ownership of a KEEP action")
	}
	restored, err := manager.Rollback()
	if err != nil {
		t.Fatal(err)
	}
	if len(restored) != 3 {
		t.Fatalf("restored = %v", restored)
	}
	assertSysctl(t, manager, KeyDefaultQdisc, "fq_codel")
	assertSysctl(t, manager, KeyCongestionControl, "cubic")
	assertSysctl(t, manager, KeyMTUProbing, "0")
	if _, err := os.Stat(manager.options.SysctlFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("managed sysctl file remains after rollback: %v", err)
	}
	if _, err := os.Stat(manager.activePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("active state remains after rollback: %v", err)
	}
	matches, err := filepath.Glob(filepath.Join(manager.options.StateDirectory, "baseline-*.json"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("archived baseline = %v, err = %v", matches, err)
	}
}

func TestApplyIsIdempotentAfterSuccessfulTune(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	if _, err := manager.Apply(Inputs{}, false); err != nil {
		t.Fatal(err)
	}
	result, err := manager.Apply(Inputs{}, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Changed) != 0 {
		t.Fatalf("second apply changed values: %v", result.Changed)
	}
	verification, err := manager.Verify()
	if err != nil || !verification.Managed || len(verification.Drift) != 0 {
		t.Fatalf("verification after second apply = %+v, err = %v", verification, err)
	}
}

func TestHysteria2OnlyApplyCreatesNoState(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Hysteria2: true})
	result, err := manager.Apply(Inputs{}, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Changed) != 0 {
		t.Fatalf("Hysteria2-only apply changed values: %v", result.Changed)
	}
	if _, err := os.Stat(manager.options.StateDirectory); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Hysteria2-only apply created tuning state: %v", err)
	}
}

func TestRollbackProtectsExternalDrift(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	if _, err := manager.Apply(Inputs{}, false); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, manager.sysctlPath(KeyCongestionControl), "reno")
	_, err := manager.Rollback()
	if err == nil || !strings.Contains(err.Error(), "protect external changes") {
		t.Fatalf("Rollback error = %v, want external-change protection", err)
	}
	assertSysctl(t, manager, KeyCongestionControl, "reno")
	if _, err := os.Stat(manager.activePath()); err != nil {
		t.Fatalf("active state was removed despite drift: %v", err)
	}
}

func TestApplyRefusesExistingUnownedSysctlFile(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{AnyTLS: true})
	writeTestFile(t, manager.options.SysctlFile, "net.ipv4.tcp_mtu_probing = 2\n")
	_, err := manager.Apply(Inputs{}, false)
	if err == nil || !strings.Contains(err.Error(), "cannot safely establish") {
		t.Fatalf("Apply error = %v, want safe baseline refusal", err)
	}
}

func TestApplyDryRunChangesNothing(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	result, err := manager.Apply(Inputs{}, true)
	if err != nil {
		t.Fatal(err)
	}
	if !result.DryRun {
		t.Fatal("Apply did not report dry run")
	}
	assertSysctl(t, manager, KeyMTUProbing, "0")
	if _, err := os.Stat(manager.options.StateDirectory); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry run created state directory: %v", err)
	}
}

func TestApplyRecoversWhenPersistenceFails(t *testing.T) {
	manager := newFakeManager(t, WorkloadProfile{Reality: true})
	manager.persist = func([]byte) error {
		return errors.New("simulated persistence failure")
	}
	_, err := manager.Apply(Inputs{}, false)
	if err == nil || !strings.Contains(err.Error(), "persist tuning") {
		t.Fatalf("Apply error = %v, want persistence failure", err)
	}
	assertSysctl(t, manager, KeyDefaultQdisc, "fq_codel")
	assertSysctl(t, manager, KeyCongestionControl, "cubic")
	assertSysctl(t, manager, KeyMTUProbing, "0")
	if _, err := os.Stat(manager.activePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed apply kept active transaction: %v", err)
	}
}

func newFakeManager(t *testing.T, workload WorkloadProfile) *Manager {
	t.Helper()
	root := t.TempDir()
	configPath := filepath.Join(root, "etc/mini-singbox/config.json")
	configJSON := `{"schema_version":1`
	if workload.Reality {
		configJSON += `,"vless_reality":{}`
	}
	if workload.AnyTLS {
		configJSON += `,"anytls":{}`
	}
	if workload.Hysteria2 {
		configJSON += `,"hysteria2":{}`
	}
	configJSON += `}`
	writeTestFile(t, configPath, configJSON)
	proc := filepath.Join(root, "proc")
	sys := filepath.Join(root, "sys")
	writeTestFile(t, filepath.Join(root, "etc/os-release"), "PRETTY_NAME=Test Linux\n")
	writeTestFile(t, filepath.Join(proc, "meminfo"), "MemTotal:       8388608 kB\n")
	writeTestFile(t, filepath.Join(proc, "sys/kernel/osrelease"), "6.12.0-test\n")
	writeTestFile(t, filepath.Join(proc, "self/cgroup"), "0::/\n")
	writeTestFile(t, filepath.Join(proc, "self/status"), "Cpus_allowed_list:\t0-1\nCapEff:\t0000000000001000\n")
	writeTestFile(t, filepath.Join(proc, "1/cgroup"), "0::/\n")
	writeTestFile(t, filepath.Join(proc, "net/route"), "Iface Destination Gateway Flags\neth0 00000000 00000000 0001\n")
	writeTestFile(t, filepath.Join(sys, "class/net/eth0/mtu"), "1500\n")
	if err := os.MkdirAll(filepath.Join(sys, "module/sch_fq"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(proc, "sys/net/core/default_qdisc"), "fq_codel")
	writeTestFile(t, filepath.Join(proc, "sys/net/ipv4/tcp_congestion_control"), "cubic")
	writeTestFile(t, filepath.Join(proc, "sys/net/ipv4/tcp_available_congestion_control"), "reno cubic bbr")
	writeTestFile(t, filepath.Join(proc, "sys/net/ipv4/tcp_mtu_probing"), "0")
	writeTestFile(t, filepath.Join(proc, "sys/net/ipv4/tcp_slow_start_after_idle"), "1")
	manager := New(Options{
		ConfigPath: configPath, StateDirectory: filepath.Join(root, "etc/mini-singbox/tune"),
		SysctlFile:    filepath.Join(root, "etc/sysctl.d/90-mini-singbox-tune.conf"),
		RootDirectory: root, ProcDirectory: proc, SysDirectory: sys, ProgramVersion: "test",
	})
	manager.isRoot = func() bool { return true }
	manager.stateOwner = func(os.FileInfo) bool { return true }
	manager.now = func() time.Time { return time.Unix(1_700_000_000, 123).UTC() }
	return manager
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assertSysctl(t *testing.T, manager *Manager, key, expected string) {
	t.Helper()
	if actual := manager.readSysctl(key); actual != expected {
		t.Fatalf("%s = %q, want %q", key, actual, expected)
	}
}
