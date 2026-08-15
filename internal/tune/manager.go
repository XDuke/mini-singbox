package tune

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const stateSchema = 1

func (m *Manager) Plan(inputs Inputs) (Plan, error) {
	profile, err := m.Detect()
	if err != nil {
		return Plan{}, err
	}
	return BuildPlan(profile, inputs)
}

func (m *Manager) Apply(inputs Inputs, dryRun bool) (result ApplyResult, err error) {
	plan, err := m.Plan(inputs)
	if err != nil {
		return ApplyResult{}, err
	}
	result = ApplyResult{Plan: plan, DryRun: dryRun}
	requested := make(map[string]string)
	for _, action := range plan.Actions {
		if action.Action == ActionSet && action.Confidence == ConfidenceHigh {
			requested[action.Key] = action.ProposedValue
		}
	}
	if dryRun {
		return result, nil
	}
	if len(requested) == 0 {
		verification, verifyErr := m.Verify()
		if verifyErr != nil {
			return ApplyResult{}, verifyErr
		}
		if len(verification.Drift) != 0 {
			return ApplyResult{}, fmt.Errorf("managed tuning has drift; run 'mini-singbox tune status' and rollback before reapplying")
		}
		return result, nil
	}
	if !plan.Profile.Capabilities.Root {
		return ApplyResult{}, fmt.Errorf("tune apply requires root")
	}
	if err := m.ensureStateDirectory(); err != nil {
		return ApplyResult{}, err
	}

	baseline, baselineExists, err := m.loadBaseline()
	if err != nil {
		return ApplyResult{}, err
	}
	active, activeExists, err := m.loadActive()
	if err != nil {
		return ApplyResult{}, err
	}
	if activeExists {
		verification, verifyErr := m.verifyActive(active)
		if verifyErr != nil {
			return ApplyResult{}, verifyErr
		}
		if len(verification.Drift) != 0 {
			return ApplyResult{}, fmt.Errorf("managed tuning has drift; run 'mini-singbox tune status' and rollback before reapplying")
		}
		for key, value := range requested {
			if active.Values[key] != value {
				return ApplyResult{}, fmt.Errorf("tuning plan changed for %s; rollback before applying a new plan", key)
			}
		}
		return result, nil
	}

	if !baselineExists {
		if exists, unsafe, statErr := pathState(m.options.SysctlFile); statErr != nil {
			return ApplyResult{}, statErr
		} else if exists || unsafe {
			return ApplyResult{}, fmt.Errorf("cannot safely establish pre-tune baseline: %s already exists", m.options.SysctlFile)
		}
		baseline = baselineState{
			Schema: stateSchema, CreatedAt: m.now().UTC(), ProgramVersion: m.options.ProgramVersion,
			Kernel: plan.Profile.Environment.Kernel, Interface: plan.Profile.Environment.Interface,
			Values: make(map[string]string),
		}
		for _, key := range managedKeys {
			if value := plan.Profile.Sysctls[key]; value != "" {
				baseline.Values[key] = value
			}
		}
		if err := m.writeJSONNew(m.baselinePath(), baseline, 0o600); err != nil {
			return ApplyResult{}, fmt.Errorf("create immutable tuning baseline: %w", err)
		}
	} else {
		if exists, unsafe, statErr := pathState(m.options.SysctlFile); statErr != nil {
			return ApplyResult{}, statErr
		} else if exists || unsafe {
			return ApplyResult{}, fmt.Errorf("cannot reuse incomplete baseline while %s exists without active ownership state", m.options.SysctlFile)
		}
		for key, original := range baseline.Values {
			if current := m.readSysctl(key); current != original {
				return ApplyResult{}, fmt.Errorf("cannot reuse incomplete baseline: %s is %q, expected %q", key, current, original)
			}
		}
	}

	content := managedSysctlContent(requested)
	hash := contentHash(content)
	active = activeState{
		Schema: stateSchema, Phase: "applying", UpdatedAt: m.now().UTC(),
		Values: requested, SysctlFileHash: hash,
	}
	if err := m.writeJSONAtomic(m.activePath(), active, 0o600); err != nil {
		return ApplyResult{}, fmt.Errorf("record tuning transaction: %w", err)
	}

	committed := false
	defer func() {
		if err == nil || committed {
			return
		}
		if recoveryErr := m.recoverApply(baseline, active, result.Changed); recoveryErr != nil {
			err = fmt.Errorf("%w; automatic recovery also failed: %v", err, recoveryErr)
		}
	}()

	for _, key := range managedKeys {
		value, ok := requested[key]
		if !ok {
			continue
		}
		if err = m.writeSysctl(key, value); err != nil {
			return result, fmt.Errorf("apply %s=%s: %w", key, value, err)
		}
		result.Changed = append(result.Changed, key)
		if actual := m.readSysctl(key); actual != value {
			return result, fmt.Errorf("verify %s: read %q after writing %q", key, actual, value)
		}
	}
	if err = m.persist(content); err != nil {
		return result, fmt.Errorf("persist tuning: %w", err)
	}
	active.Phase = "active"
	active.UpdatedAt = m.now().UTC()
	if err = m.writeJSONAtomic(m.activePath(), active, 0o600); err != nil {
		return result, fmt.Errorf("commit tuning state: %w", err)
	}
	committed = true
	return result, nil
}

func (m *Manager) Verify() (VerifyResult, error) {
	active, exists, err := m.loadActive()
	if err != nil {
		return VerifyResult{}, err
	}
	if !exists {
		return VerifyResult{}, nil
	}
	return m.verifyActive(active)
}

func (m *Manager) verifyActive(active activeState) (VerifyResult, error) {
	result := VerifyResult{Managed: true, Phase: active.Phase}
	if active.Phase != "active" {
		result.Drift = append(result.Drift, "an incomplete tune apply transaction is recorded")
	}
	keys := sortedKeys(active.Values)
	for _, key := range keys {
		actual := m.readSysctl(key)
		if actual != active.Values[key] {
			result.Drift = append(result.Drift, fmt.Sprintf("%s: current=%q managed=%q", key, actual, active.Values[key]))
		}
	}
	info, err := os.Lstat(m.options.SysctlFile)
	if errors.Is(err, os.ErrNotExist) {
		result.Drift = append(result.Drift, "managed sysctl file is missing")
		return result, nil
	}
	if err != nil {
		return VerifyResult{}, fmt.Errorf("inspect managed sysctl file: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		result.Drift = append(result.Drift, "managed sysctl path is not a regular file")
		return result, nil
	}
	content, err := readLimitedFile(m.options.SysctlFile, 1<<20)
	if err != nil {
		return VerifyResult{}, fmt.Errorf("read managed sysctl file: %w", err)
	}
	if contentHash(content) != active.SysctlFileHash {
		result.Drift = append(result.Drift, "managed sysctl file content changed outside mini-singbox")
	}
	return result, nil
}

func (m *Manager) Rollback() ([]string, error) {
	active, exists, err := m.loadActive()
	if err != nil || !exists {
		return nil, err
	}
	if !m.isRoot() {
		return nil, fmt.Errorf("tune rollback requires root")
	}
	baseline, baselineExists, err := m.loadBaseline()
	if err != nil {
		return nil, err
	}
	if !baselineExists {
		return nil, fmt.Errorf("cannot rollback: immutable baseline is missing")
	}
	var restored, drift []string
	for _, key := range sortedKeys(active.Values) {
		original, ok := baseline.Values[key]
		if !ok {
			drift = append(drift, key+": baseline value missing")
			continue
		}
		current := m.readSysctl(key)
		if current == original {
			continue
		}
		if current != active.Values[key] {
			drift = append(drift, fmt.Sprintf("%s: current=%q is not managed=%q", key, current, active.Values[key]))
			continue
		}
		if err := m.writeSysctl(key, original); err != nil {
			drift = append(drift, fmt.Sprintf("%s: restore failed: %v", key, err))
			continue
		}
		if current = m.readSysctl(key); current != original {
			drift = append(drift, fmt.Sprintf("%s: restore verification read %q", key, current))
			continue
		}
		restored = append(restored, key)
	}
	if err := m.removeManagedFile(active.SysctlFileHash); err != nil {
		drift = append(drift, err.Error())
	}
	if len(drift) != 0 {
		return restored, fmt.Errorf("rollback stopped to protect external changes: %s", strings.Join(drift, "; "))
	}
	if err := os.Remove(m.activePath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return restored, fmt.Errorf("remove active tuning state: %w", err)
	}
	archive := filepath.Join(m.options.StateDirectory, fmt.Sprintf("baseline-%d.json", m.now().UTC().UnixNano()))
	if err := os.Rename(m.baselinePath(), archive); err != nil {
		return restored, fmt.Errorf("archive restored tuning baseline: %w", err)
	}
	return restored, nil
}

func (m *Manager) recoverApply(baseline baselineState, active activeState, changed []string) error {
	var failures []string
	for i := len(changed) - 1; i >= 0; i-- {
		key := changed[i]
		current := m.readSysctl(key)
		if current != active.Values[key] {
			failures = append(failures, key+": value drifted during recovery")
			continue
		}
		if err := m.writeSysctl(key, baseline.Values[key]); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", key, err))
		}
	}
	if exists, unsafe, stateErr := pathState(m.options.SysctlFile); stateErr != nil {
		failures = append(failures, "inspect managed sysctl file: "+stateErr.Error())
	} else if exists {
		if unsafe {
			failures = append(failures, "managed sysctl path became unsafe")
		} else if content, readErr := readLimitedFile(m.options.SysctlFile, 1<<20); readErr != nil {
			failures = append(failures, "read managed sysctl file: "+readErr.Error())
		} else if contentHash(content) != active.SysctlFileHash {
			failures = append(failures, "managed sysctl file changed during recovery")
		} else if removeErr := os.Remove(m.options.SysctlFile); removeErr != nil {
			failures = append(failures, "remove managed sysctl file: "+removeErr.Error())
		}
	}
	if len(failures) == 0 {
		_ = os.Remove(m.activePath())
		return nil
	}
	return errors.New(strings.Join(failures, "; "))
}

func (m *Manager) writeSysctl(key, value string) error {
	path := m.sysctlPath(key)
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("unsafe sysctl path %s", path)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	_, writeErr := io.WriteString(file, value)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

func (m *Manager) ensureStateDirectory() error {
	if err := os.MkdirAll(m.options.StateDirectory, 0o700); err != nil {
		return fmt.Errorf("create tuning state directory: %w", err)
	}
	info, err := os.Lstat(m.options.StateDirectory)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("unsafe tuning state directory: %s", m.options.StateDirectory)
	}
	if !m.stateOwner(info) {
		return fmt.Errorf("tuning state directory is not owned by root: %s", m.options.StateDirectory)
	}
	return os.Chmod(m.options.StateDirectory, 0o700)
}

func (m *Manager) checkStateDirectory() error {
	info, err := os.Lstat(m.options.StateDirectory)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || !stateDirectoryModeSecure(info) {
		return fmt.Errorf("unsafe tuning state directory: %s", m.options.StateDirectory)
	}
	if !m.stateOwner(info) {
		return fmt.Errorf("tuning state directory is not owned by root: %s", m.options.StateDirectory)
	}
	return nil
}

func (m *Manager) baselinePath() string {
	return filepath.Join(m.options.StateDirectory, "baseline.json")
}
func (m *Manager) activePath() string { return filepath.Join(m.options.StateDirectory, "active.json") }

func (m *Manager) loadBaseline() (baselineState, bool, error) {
	if err := m.checkStateDirectory(); err != nil {
		return baselineState{}, false, err
	}
	var state baselineState
	exists, err := readJSONFile(m.baselinePath(), &state)
	if err != nil || !exists {
		return state, exists, err
	}
	if state.Schema != stateSchema || len(state.Values) == 0 {
		return baselineState{}, false, fmt.Errorf("invalid tuning baseline schema or values")
	}
	if err := validateStateValues(state.Values); err != nil {
		return baselineState{}, false, fmt.Errorf("invalid tuning baseline: %w", err)
	}
	return state, true, nil
}

func (m *Manager) loadActive() (activeState, bool, error) {
	if err := m.checkStateDirectory(); err != nil {
		return activeState{}, false, err
	}
	var state activeState
	exists, err := readJSONFile(m.activePath(), &state)
	if err != nil || !exists {
		return state, exists, err
	}
	if state.Schema != stateSchema || len(state.Values) == 0 || state.SysctlFileHash == "" {
		return activeState{}, false, fmt.Errorf("invalid active tuning state")
	}
	if err := validateStateValues(state.Values); err != nil {
		return activeState{}, false, fmt.Errorf("invalid active tuning state: %w", err)
	}
	if len(state.SysctlFileHash) != 64 {
		return activeState{}, false, fmt.Errorf("invalid active tuning state hash")
	}
	if _, err := hex.DecodeString(state.SysctlFileHash); err != nil {
		return activeState{}, false, fmt.Errorf("invalid active tuning state hash")
	}
	return state, true, nil
}

func validateStateValues(values map[string]string) error {
	allowed := make(map[string]bool, len(managedKeys))
	for _, key := range managedKeys {
		allowed[key] = true
	}
	for key, value := range values {
		if !allowed[key] {
			return fmt.Errorf("unmanaged key %q", key)
		}
		if value == "" || strings.ContainsAny(value, "\r\n\x00") {
			return fmt.Errorf("unsafe value for %s", key)
		}
	}
	return nil
}

func readJSONFile(path string, destination any) (bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return false, fmt.Errorf("unsafe state file: %s", path)
	}
	content, err := readLimitedFile(path, 1<<20)
	if err != nil {
		return false, err
	}
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return false, fmt.Errorf("decode %s: %w", path, err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return false, fmt.Errorf("decode %s: trailing data", path)
	}
	return true, nil
}

func (m *Manager) writeJSONNew(path string, value any, mode os.FileMode) error {
	content, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err = file.Write(content); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	return err
}

func (m *Manager) writeJSONAtomic(path string, value any, mode os.FileMode) error {
	content, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return atomicWrite(path, content, mode)
}

func (m *Manager) writeManagedFile(content []byte) error {
	parent := filepath.Dir(m.options.SysctlFile)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return err
	}
	parentInfo, err := os.Lstat(parent)
	if err != nil {
		return err
	}
	if parentInfo.Mode()&os.ModeSymlink != 0 || !parentInfo.IsDir() {
		return fmt.Errorf("unsafe managed sysctl directory: %s", parent)
	}
	if !m.stateOwner(parentInfo) || !persistenceDirectoryModeSecure(parentInfo) {
		return fmt.Errorf("managed sysctl directory is not root-owned and protected from group/world writes: %s", parent)
	}
	if info, err := os.Lstat(m.options.SysctlFile); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("unsafe managed sysctl path: %s", m.options.SysctlFile)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return atomicWrite(m.options.SysctlFile, content, 0o644)
}

func atomicWrite(path string, content []byte, mode os.FileMode) error {
	temporary := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	file, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(temporary)
		}
	}()
	if _, err = file.Write(content); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	cleanup = false
	return nil
}

func (m *Manager) removeManagedFile(expectedHash string) error {
	info, err := os.Lstat(m.options.SysctlFile)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("refusing to remove unsafe managed sysctl path")
	}
	content, err := readLimitedFile(m.options.SysctlFile, 1<<20)
	if err != nil {
		return err
	}
	if contentHash(content) != expectedHash {
		return fmt.Errorf("refusing to remove externally changed managed sysctl file")
	}
	return os.Remove(m.options.SysctlFile)
}

func readLimitedFile(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(content)) > limit {
		return nil, fmt.Errorf("file exceeds %d bytes", limit)
	}
	return content, nil
}

func managedSysctlContent(values map[string]string) []byte {
	var builder strings.Builder
	builder.WriteString("# Managed by mini-singbox tune. Do not edit; use mini-singbox tune rollback.\n")
	for _, key := range managedKeys {
		if value, ok := values[key]; ok {
			fmt.Fprintf(&builder, "%s = %s\n", key, value)
		}
	}
	return []byte(builder.String())
}

func contentHash(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func pathState(path string) (exists, unsafe bool, err error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	return true, info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular(), nil
}
