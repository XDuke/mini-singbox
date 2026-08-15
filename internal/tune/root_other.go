//go:build !linux

package tune

import "os"

func processIsRoot() bool {
	return false
}

func fileOwnedByRoot(_ os.FileInfo) bool {
	return true
}

func stateDirectoryModeSecure(_ os.FileInfo) bool {
	return true
}

func persistenceDirectoryModeSecure(_ os.FileInfo) bool {
	return true
}
