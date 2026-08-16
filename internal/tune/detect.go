package tune

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/XDuke/mini-singbox/internal/config"
)

type Manager struct {
	options    Options
	now        func() time.Time
	isRoot     func() bool
	stateOwner func(os.FileInfo) bool
	persist    func([]byte) error
}

func New(options Options) *Manager {
	if options.ConfigPath == "" {
		options.ConfigPath = DefaultConfigPath
	}
	if options.StateDirectory == "" {
		options.StateDirectory = DefaultStateDirectory
	}
	if options.SysctlFile == "" {
		options.SysctlFile = DefaultSysctlFile
	}
	if options.RootDirectory == "" {
		options.RootDirectory = string(filepath.Separator)
	}
	if options.ProcDirectory == "" {
		options.ProcDirectory = filepath.Join(options.RootDirectory, "proc")
	}
	if options.SysDirectory == "" {
		options.SysDirectory = filepath.Join(options.RootDirectory, "sys")
	}
	manager := &Manager{options: options, now: time.Now, isRoot: processIsRoot, stateOwner: fileOwnedByRoot}
	manager.persist = manager.writeManagedFile
	return manager
}

func (m *Manager) Detect() (Profile, error) {
	localConfig, err := config.DecodeFile(m.options.ConfigPath)
	if err != nil {
		return Profile{}, fmt.Errorf("tune: cannot read workload: %w", err)
	}
	profile := Profile{
		Workload: WorkloadProfile{
			Reality: localConfig.VLESSReality != nil, AnyTLS: localConfig.AnyTLS != nil,
			Hysteria2: localConfig.Hysteria2 != nil,
		},
		Sysctls:      make(map[string]string),
		Capabilities: CapabilityProfile{Root: m.isRoot(), SysctlWritable: make(map[string]bool)},
	}

	profile.Environment.Distribution = m.distribution()
	profile.Environment.Kernel = m.readTrimmed(filepath.Join(m.options.ProcDirectory, "sys/kernel/osrelease"))
	profile.Environment.Architecture = runtime.GOARCH
	profile.Environment.Virtualization = m.virtualization()
	profile.Environment.VisibleMemoryBytes = m.visibleMemory()
	profile.Environment.CgroupMemoryLimit = m.cgroupMemoryLimit(profile.Environment.VisibleMemoryBytes)
	profile.Environment.EffectiveMemoryBytes = profile.Environment.VisibleMemoryBytes
	if profile.Environment.CgroupMemoryLimit > 0 &&
		(profile.Environment.EffectiveMemoryBytes == 0 || profile.Environment.CgroupMemoryLimit < profile.Environment.EffectiveMemoryBytes) {
		profile.Environment.EffectiveMemoryBytes = profile.Environment.CgroupMemoryLimit
	}
	profile.Environment.MemoryPolicy = memoryPolicy(profile.Environment.EffectiveMemoryBytes)
	profile.Environment.LogicalCPUs = runtime.NumCPU()
	profile.Environment.EffectiveCPUs = m.effectiveCPUs(profile.Environment.LogicalCPUs)
	profile.Environment.Interface = m.defaultInterface()
	if profile.Environment.Interface != "" {
		profile.Environment.MTU, _ = strconv.Atoi(m.readTrimmed(filepath.Join(
			m.options.SysDirectory, "class/net", profile.Environment.Interface, "mtu")))
	}

	for _, key := range append(append([]string{}, managedKeys...), KeyAvailableCC) {
		profile.Sysctls[key] = m.readSysctl(key)
	}
	profile.AvailableCC = strings.Fields(profile.Sysctls[KeyAvailableCC])
	profile.Capabilities.NetAdmin = m.hasCapability(12)
	for _, key := range managedKeys {
		profile.Capabilities.SysctlWritable[key] = profile.Capabilities.Root && m.sysctlWritable(key)
	}
	profile.FQAvailable = m.fqAvailable(profile.Environment.Kernel, profile.Sysctls[KeyDefaultQdisc])
	if runtime.GOOS != "linux" {
		profile.Warnings = append(profile.Warnings, "system tuning is supported only on Linux")
	}
	if profile.Environment.EffectiveMemoryBytes == 0 {
		profile.Warnings = append(profile.Warnings, "effective RAM could not be detected; buffer tuning remains disabled")
	}
	if profile.Environment.Interface == "" {
		profile.Warnings = append(profile.Warnings, "default outbound interface is unknown")
	}
	return profile, nil
}

func (m *Manager) distribution() string {
	content, err := os.ReadFile(m.rootPath("etc/os-release"))
	if err != nil {
		return "unknown"
	}
	values := make(map[string]string)
	for _, line := range strings.Split(string(content), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			values[key] = strings.Trim(value, "\"'")
		}
	}
	if values["PRETTY_NAME"] != "" {
		return values["PRETTY_NAME"]
	}
	if values["ID"] != "" {
		return values["ID"]
	}
	return "unknown"
}

func (m *Manager) virtualization() string {
	if value := m.readTrimmed(m.rootPath("run/systemd/container")); value != "" {
		return value
	}
	if m.pathExists(m.rootPath(".dockerenv")) {
		return "docker"
	}
	if m.pathExists(m.rootPath("run/.containerenv")) {
		return "podman"
	}
	cgroups := strings.ToLower(m.readTrimmed(filepath.Join(m.options.ProcDirectory, "1/cgroup")) + "\n" +
		m.readTrimmed(filepath.Join(m.options.ProcDirectory, "self/cgroup")))
	for _, candidate := range []string{"docker", "podman", "containerd", "lxc", "openvz"} {
		if strings.Contains(cgroups, candidate) {
			return candidate
		}
	}
	if strings.Contains(cgroups, "kubepods") {
		return "kubernetes"
	}
	if m.pathExists(filepath.Join(m.options.ProcDirectory, "vz")) {
		return "openvz"
	}
	dmi := strings.ToLower(m.readTrimmed(filepath.Join(m.options.SysDirectory, "class/dmi/id/product_name")) + " " +
		m.readTrimmed(filepath.Join(m.options.SysDirectory, "class/dmi/id/sys_vendor")))
	for _, candidate := range []struct{ marker, name string }{
		{"kvm", "kvm"}, {"qemu", "qemu"}, {"vmware", "vmware"},
		{"virtualbox", "virtualbox"}, {"hyper-v", "hyper-v"},
	} {
		if strings.Contains(dmi, candidate.marker) {
			return candidate.name
		}
	}
	if dmi != "" {
		return "bare-metal-or-unknown"
	}
	return "unknown"
}

func (m *Manager) visibleMemory() uint64 {
	file, err := os.Open(filepath.Join(m.options.ProcDirectory, "meminfo"))
	if err != nil {
		return 0
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 2 && fields[0] == "MemTotal:" {
			value, err := strconv.ParseUint(fields[1], 10, 64)
			if err == nil && value <= ^uint64(0)/1024 {
				return value * 1024
			}
		}
	}
	return 0
}

func (m *Manager) cgroupMemoryLimit(visible uint64) uint64 {
	content, _ := os.ReadFile(filepath.Join(m.options.ProcDirectory, "self/cgroup"))
	var candidates []string
	for _, line := range strings.Split(string(content), "\n") {
		parts := strings.SplitN(line, ":", 3)
		if len(parts) != 3 {
			continue
		}
		relative := cleanCgroupPath(parts[2])
		if parts[0] == "0" && parts[1] == "" {
			candidates = append(candidates, cgroupLimitPaths(
				filepath.Join(m.options.SysDirectory, "fs/cgroup"), relative, "memory.max")...)
		}
		if slices.Contains(strings.Split(parts[1], ","), "memory") {
			candidates = append(candidates,
				cgroupLimitPaths(filepath.Join(m.options.SysDirectory, "fs/cgroup/memory"), relative, "memory.limit_in_bytes")...)
			candidates = append(candidates,
				cgroupLimitPaths(filepath.Join(m.options.SysDirectory, "fs/cgroup"), relative, "memory.limit_in_bytes")...)
		}
	}
	candidates = append(candidates,
		filepath.Join(m.options.SysDirectory, "fs/cgroup/memory.max"),
		filepath.Join(m.options.SysDirectory, "fs/cgroup/memory/memory.limit_in_bytes"))
	var smallest uint64
	for _, path := range candidates {
		value := m.readTrimmed(path)
		if value == "" || value == "max" {
			continue
		}
		limit, err := strconv.ParseUint(value, 10, 64)
		if err != nil || limit == 0 || limit >= 1<<60 {
			continue
		}
		if visible > 0 && limit >= visible {
			continue
		}
		if smallest == 0 || limit < smallest {
			smallest = limit
		}
	}
	return smallest
}

func cleanCgroupPath(value string) string {
	cleaned := filepath.Clean("/" + value)
	return strings.TrimPrefix(cleaned, string(filepath.Separator))
}

func cgroupLimitPaths(base, relative, filename string) []string {
	current := filepath.Join(base, relative)
	var paths []string
	for {
		paths = append(paths, filepath.Join(current, filename))
		if current == base {
			return paths
		}
		parent := filepath.Dir(current)
		if parent == current || !strings.HasPrefix(parent+string(filepath.Separator), base+string(filepath.Separator)) {
			return paths
		}
		current = parent
	}
}

func (m *Manager) effectiveCPUs(logical int) int {
	effective := logical
	status, _ := os.ReadFile(filepath.Join(m.options.ProcDirectory, "self/status"))
	for _, line := range strings.Split(string(status), "\n") {
		if strings.HasPrefix(line, "Cpus_allowed_list:") {
			if count := cpuListCount(strings.TrimSpace(strings.TrimPrefix(line, "Cpus_allowed_list:"))); count > 0 && count < effective {
				effective = count
			}
		}
	}
	if effective < 1 {
		return 1
	}
	return effective
}

func cpuListCount(value string) int {
	count := 0
	for _, part := range strings.Split(value, ",") {
		bounds := strings.SplitN(strings.TrimSpace(part), "-", 2)
		start, err := strconv.Atoi(bounds[0])
		if err != nil {
			return 0
		}
		end := start
		if len(bounds) == 2 {
			end, err = strconv.Atoi(bounds[1])
			if err != nil || end < start {
				return 0
			}
		}
		count += end - start + 1
	}
	return count
}

func (m *Manager) defaultInterface() string {
	content, _ := os.ReadFile(filepath.Join(m.options.ProcDirectory, "net/route"))
	for _, line := range strings.Split(string(content), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 4 && fields[1] == "00000000" {
			flags, _ := strconv.ParseUint(fields[3], 16, 64)
			if flags&1 != 0 {
				return fields[0]
			}
		}
	}
	content, _ = os.ReadFile(filepath.Join(m.options.ProcDirectory, "net/ipv6_route"))
	for _, line := range strings.Split(string(content), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 10 && fields[0] == strings.Repeat("0", 32) && fields[1] == "00" {
			return fields[len(fields)-1]
		}
	}
	return ""
}

func (m *Manager) hasCapability(bit uint) bool {
	content, _ := os.ReadFile(filepath.Join(m.options.ProcDirectory, "self/status"))
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, "CapEff:") {
			value, err := strconv.ParseUint(strings.TrimSpace(strings.TrimPrefix(line, "CapEff:")), 16, 64)
			return err == nil && value&(uint64(1)<<bit) != 0
		}
	}
	return false
}

func (m *Manager) fqAvailable(kernel, current string) bool {
	if current == "fq" || m.pathExists(filepath.Join(m.options.SysDirectory, "module/sch_fq")) {
		return true
	}
	modules, _ := os.ReadFile(filepath.Join(m.options.ProcDirectory, "modules"))
	for _, line := range strings.Split(string(modules), "\n") {
		if strings.HasPrefix(line, "sch_fq ") {
			return true
		}
	}
	config, _ := os.ReadFile(m.rootPath(filepath.Join("boot", "config-"+kernel)))
	if strings.Contains(string(config), "CONFIG_NET_SCH_FQ=y") {
		return true
	}
	return false
}

func (m *Manager) readSysctl(key string) string {
	return m.readTrimmed(m.sysctlPath(key))
}

func (m *Manager) sysctlPath(key string) string {
	return filepath.Join(m.options.ProcDirectory, "sys", filepath.FromSlash(strings.ReplaceAll(key, ".", "/")))
}

func (m *Manager) sysctlWritable(key string) bool {
	file, err := os.OpenFile(m.sysctlPath(key), os.O_WRONLY, 0)
	if err != nil {
		return false
	}
	return file.Close() == nil
}

func (m *Manager) rootPath(relative string) string {
	return filepath.Join(m.options.RootDirectory, filepath.FromSlash(relative))
}

func (m *Manager) readTrimmed(path string) string {
	content, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(content))
}

func (m *Manager) pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
