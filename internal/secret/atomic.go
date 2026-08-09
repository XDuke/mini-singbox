package secret

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

type File struct {
	Name string
	Data []byte
	Mode fs.FileMode
}

type stagedFile struct {
	file   File
	target string
	temp   string
}

func WriteFiles(directory string, files []File, force bool) error {
	if directory == "" {
		return fmt.Errorf("output directory is empty")
	}
	if err := ensureSecureDirectory(directory); err != nil {
		return err
	}
	seen := make(map[string]struct{}, len(files))
	staged := make([]stagedFile, 0, len(files))
	for _, file := range files {
		if file.Name == "" || filepath.Base(file.Name) != file.Name || strings.ContainsAny(file.Name, `/\\`) {
			return fmt.Errorf("unsafe output file name %q", file.Name)
		}
		if _, exists := seen[file.Name]; exists {
			return fmt.Errorf("duplicate output file %q", file.Name)
		}
		seen[file.Name] = struct{}{}
		target := filepath.Join(directory, file.Name)
		info, err := os.Lstat(target)
		if err == nil {
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("refusing symbolic-link output %s", target)
			}
			if !info.Mode().IsRegular() {
				return fmt.Errorf("output target is not a regular file: %s", target)
			}
			if !force {
				return fmt.Errorf("output already exists: %s; use --force to replace", target)
			}
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("inspect output %s: %w", target, err)
		}
		staged = append(staged, stagedFile{file: file, target: target})
	}
	for index := range staged {
		temp, err := writeTemp(directory, staged[index].file)
		if err != nil {
			cleanupTemps(staged)
			return err
		}
		staged[index].temp = temp
	}
	for index := range staged {
		if err := replaceTarget(staged[index].temp, staged[index].target, force); err != nil {
			cleanupTemps(staged[index:])
			return err
		}
		staged[index].temp = ""
	}
	if err := syncDirectory(directory); err != nil {
		return fmt.Errorf("sync output directory: %w", err)
	}
	for _, stagedFile := range staged {
		content, err := os.ReadFile(stagedFile.target)
		if err != nil || !bytes.Equal(content, stagedFile.file.Data) {
			return fmt.Errorf("verify generated file %s", stagedFile.target)
		}
	}
	return nil
}

func ensureSecureDirectory(directory string) error {
	info, err := os.Lstat(directory)
	if os.IsNotExist(err) {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return fmt.Errorf("create output directory: %w", err)
		}
		info, err = os.Lstat(directory)
	}
	if err != nil {
		return fmt.Errorf("inspect output directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("output directory must not be a symbolic link")
	}
	if !info.IsDir() {
		return fmt.Errorf("output path is not a directory")
	}
	if err := checkDirectoryPermissions(info.Mode().Perm()); err != nil {
		return err
	}
	return nil
}

func writeTemp(directory string, file File) (string, error) {
	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		return "", err
	}
	temp := filepath.Join(directory, "."+file.Name+".tmp-"+hex.EncodeToString(suffix))
	handle, err := os.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, file.Mode)
	if err != nil {
		return "", fmt.Errorf("create temporary file for %s: %w", file.Name, err)
	}
	ok := false
	defer func() {
		if !ok {
			handle.Close()
			_ = os.Remove(temp)
		}
	}()
	if err := handle.Chmod(file.Mode); err != nil {
		return "", err
	}
	if _, err := handle.Write(file.Data); err != nil {
		return "", err
	}
	if err := handle.Sync(); err != nil {
		return "", err
	}
	if err := handle.Close(); err != nil {
		return "", err
	}
	ok = true
	return temp, nil
}

func replaceTarget(temp, target string, force bool) error {
	if !force {
		if _, err := os.Lstat(target); err == nil {
			return fmt.Errorf("output appeared during generation: %s", target)
		} else if !os.IsNotExist(err) {
			return err
		}
		return os.Rename(temp, target)
	}
	backup := target + ".backup"
	if _, err := os.Lstat(backup); err == nil {
		return fmt.Errorf("refusing existing backup path: %s", backup)
	} else if !os.IsNotExist(err) {
		return err
	}
	hadTarget := false
	if _, err := os.Lstat(target); err == nil {
		if err := os.Rename(target, backup); err != nil {
			return err
		}
		hadTarget = true
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.Rename(temp, target); err != nil {
		if hadTarget {
			_ = os.Rename(backup, target)
		}
		return err
	}
	if hadTarget {
		if err := os.Remove(backup); err != nil {
			return fmt.Errorf("remove replaced-file backup: %w", err)
		}
	}
	return nil
}

func cleanupTemps(files []stagedFile) {
	for _, file := range files {
		if file.temp != "" {
			_ = os.Remove(file.temp)
		}
	}
}
