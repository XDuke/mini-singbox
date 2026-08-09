package config

import (
	"fmt"
	"os"
)

type fileKind uint8

const (
	fileConfig fileKind = iota
	filePrivateKey
	fileCertificate
)

func checkFile(path string, kind fileKind) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fieldError(path, "file does not exist or is a broken link", "create a readable regular file at this path")
	}
	if info.Mode()&os.ModeSymlink != 0 {
		info, err = os.Stat(path)
		if err != nil {
			return fieldError(path, "symbolic link target is missing", "repair the link or use a regular file")
		}
	}
	if info.IsDir() {
		return fieldError(path, "path is a directory", "use a regular file")
	}
	if !info.Mode().IsRegular() {
		return fieldError(path, fmt.Sprintf("unsupported file mode %s", info.Mode()), "use a regular file")
	}
	if err := checkPermissions(info.Mode().Perm(), kind); err != nil {
		return fieldError(path, err.Error(), permissionHint(kind))
	}
	return nil
}

func permissionHint(kind fileKind) string {
	if kind == fileCertificate {
		return "use mode 0644 or 0444"
	}
	return "use mode 0600 or 0400; mode 0440 is allowed for container secrets"
}
