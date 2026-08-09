//go:build !unix && !windows

package config

import "io/fs"

func checkPermissions(_ fs.FileMode, _ fileKind) error { return nil }
