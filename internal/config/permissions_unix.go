//go:build unix

package config

import (
	"fmt"
	"io/fs"
)

func checkPermissions(mode fs.FileMode, kind fileKind) error {
	if kind == filePrivateKey && mode&0004 != 0 {
		return fmt.Errorf("private key is readable by other users (mode %04o)", mode)
	}
	if kind != fileCertificate && mode&0022 != 0 {
		return fmt.Errorf("file is writable by group or other users (mode %04o)", mode)
	}
	if kind == fileCertificate && mode&0002 != 0 {
		return fmt.Errorf("certificate is writable by other users (mode %04o)", mode)
	}
	return nil
}
