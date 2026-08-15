package tune

import "time"

const (
	DefaultConfigPath     = "/etc/mini-singbox/config.json"
	DefaultStateDirectory = "/var/lib/mini-singbox/tune"
	DefaultSysctlFile     = "/etc/sysctl.d/90-mini-singbox-tune.conf"
)

const (
	KeyDefaultQdisc       = "net.core.default_qdisc"
	KeyCongestionControl  = "net.ipv4.tcp_congestion_control"
	KeyAvailableCC        = "net.ipv4.tcp_available_congestion_control"
	KeyMTUProbing         = "net.ipv4.tcp_mtu_probing"
	KeySlowStartAfterIdle = "net.ipv4.tcp_slow_start_after_idle"
)

var managedKeys = []string{
	KeyDefaultQdisc,
	KeyCongestionControl,
	KeyMTUProbing,
	KeySlowStartAfterIdle,
}

type WorkloadProfile struct {
	Reality   bool
	AnyTLS    bool
	Hysteria2 bool
}

func (w WorkloadProfile) TCPEnabled() bool {
	return w.Reality || w.AnyTLS
}

type CapabilityProfile struct {
	Root           bool
	NetAdmin       bool
	SysctlWritable map[string]bool
}

type EnvironmentProfile struct {
	Distribution         string
	Kernel               string
	Architecture         string
	Virtualization       string
	VisibleMemoryBytes   uint64
	CgroupMemoryLimit    uint64
	EffectiveMemoryBytes uint64
	LogicalCPUs          int
	EffectiveCPUs        int
	Interface            string
	MTU                  int
	MemoryPolicy         string
}

type Profile struct {
	Environment  EnvironmentProfile
	Capabilities CapabilityProfile
	Workload     WorkloadProfile
	Sysctls      map[string]string
	AvailableCC  []string
	FQAvailable  bool
	Warnings     []string
}

type Action string

const (
	ActionKeep        Action = "KEEP"
	ActionSet         Action = "SET"
	ActionSkip        Action = "SKIP"
	ActionUnsupported Action = "UNSUPPORTED"
	ActionManual      Action = "MANUAL"
)

type Confidence string

const (
	ConfidenceHigh   Confidence = "HIGH"
	ConfidenceMedium Confidence = "MEDIUM"
	ConfidenceLow    Confidence = "LOW"
)

type TuneAction struct {
	Key           string
	CurrentValue  string
	ProposedValue string
	Action        Action
	Reason        string
	Risk          string
	Capability    string
	Confidence    Confidence
}

type Inputs struct {
	BandwidthMbps uint64
	RTTMillis     uint64
}

type Plan struct {
	Profile  Profile
	Inputs   Inputs
	BDPBytes uint64
	Actions  []TuneAction
}

type Options struct {
	ConfigPath     string
	StateDirectory string
	SysctlFile     string
	RootDirectory  string
	ProcDirectory  string
	SysDirectory   string
	ProgramVersion string
}

type baselineState struct {
	Schema         int               `json:"schema"`
	CreatedAt      time.Time         `json:"created_at"`
	ProgramVersion string            `json:"program_version"`
	Kernel         string            `json:"kernel"`
	Interface      string            `json:"interface,omitempty"`
	Values         map[string]string `json:"values"`
}

type activeState struct {
	Schema         int               `json:"schema"`
	Phase          string            `json:"phase"`
	UpdatedAt      time.Time         `json:"updated_at"`
	Values         map[string]string `json:"values"`
	SysctlFileHash string            `json:"sysctl_file_sha256"`
}

type ApplyResult struct {
	Plan    Plan
	Changed []string
	DryRun  bool
}

type VerifyResult struct {
	Managed bool
	Phase   string
	Drift   []string
}
