//go:build unix

package secret

import (
	"fmt"
	"io/fs"
	"os"
)

func checkDirectoryPermissions(mode fs.FileMode) error {
	if mode&0o022 != 0 {
		return fmt.Errorf("output directory is writable by group or other users (mode %04o)", mode)
	}
	return nil
}

func syncDirectory(directory string) error {
	handle, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer handle.Close()
	return handle.Sync()
}
