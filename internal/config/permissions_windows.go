//go:build windows

package config

import "io/fs"

func checkPermissions(_ fs.FileMode, _ fileKind) error {
	// Windows ACLs are not represented by os.FileMode. Access is still tested
	// by opening and reading the file; deployment ACL checks run on Linux.
	return nil
}
