//go:build !unix && !windows

package secret

import "io/fs"

func checkDirectoryPermissions(_ fs.FileMode) error { return nil }
func syncDirectory(_ string) error                  { return nil }
