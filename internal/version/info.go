package version

import (
	"fmt"
	"runtime"
	"runtime/debug"
)

var (
	Version   = "dev"
	Commit    = "unknown"
	BuildTime = "unknown"
	Dirty     = "unknown"
)

func String() string {
	return fmt.Sprintf(
		"mini-singbox %s\ngit_commit %s\nbuild_time %s\ngo_version %s\nsing_box_version %s\ntarget %s/%s\ndirty_build %s",
		Version, Commit, BuildTime, runtime.Version(), singBoxVersion(), runtime.GOOS, runtime.GOARCH, Dirty,
	)
}

func singBoxVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	for _, dependency := range info.Deps {
		if dependency.Path == "github.com/sagernet/sing-box" {
			if dependency.Replace != nil {
				return dependency.Replace.Version
			}
			return dependency.Version
		}
	}
	return "unknown"
}
