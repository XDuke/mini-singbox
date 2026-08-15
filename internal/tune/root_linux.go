//go:build linux

package tune

import (
	"os"
	"syscall"
)

func processIsRoot() bool {
	return os.Geteuid() == 0
}

func fileOwnedByRoot(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == 0
}

func stateDirectoryModeSecure(info os.FileInfo) bool {
	return info.Mode().Perm()&0o077 == 0
}

func persistenceDirectoryModeSecure(info os.FileInfo) bool {
	return info.Mode().Perm()&0o022 == 0
}
