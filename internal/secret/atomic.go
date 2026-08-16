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
	file      File
	target    string
	temp      string
	backup    string
	hadTarget bool
	installed bool
}

type renameFunc func(string, string) error

func WriteFiles(directory string, files []File, force bool) error {
	return writeFiles(directory, files, force, os.Rename)
}

func writeFiles(directory string, files []File, force bool, rename renameFunc) error {
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
		stagedFile := stagedFile{file: file, target: target}
		if force {
			stagedFile.backup = target + ".backup"
			if _, err := os.Lstat(stagedFile.backup); err == nil {
				return fmt.Errorf("refusing existing backup path: %s", stagedFile.backup)
			} else if !os.IsNotExist(err) {
				return fmt.Errorf("inspect backup path %s: %w", stagedFile.backup, err)
			}
		}
		staged = append(staged, stagedFile)
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
		if err := replaceTarget(&staged[index], force, rename); err != nil {
			return rollbackWrite(directory, staged, rename, err)
		}
	}
	if err := syncDirectory(directory); err != nil {
		return rollbackWrite(directory, staged, rename, fmt.Errorf("sync output directory: %w", err))
	}
	for _, stagedFile := range staged {
		content, err := os.ReadFile(stagedFile.target)
		if err != nil || !bytes.Equal(content, stagedFile.file.Data) {
			return rollbackWrite(directory, staged, rename, fmt.Errorf("verify generated file %s", stagedFile.target))
		}
	}
	for index := range staged {
		if staged[index].hadTarget {
			if err := os.Remove(staged[index].backup); err != nil {
				return fmt.Errorf("remove committed-file backup %s: %w", staged[index].backup, err)
			}
			staged[index].backup = ""
		}
	}
	if err := syncDirectory(directory); err != nil {
		return fmt.Errorf("sync committed output directory: %w", err)
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

func replaceTarget(file *stagedFile, force bool, rename renameFunc) error {
	if !force {
		if _, err := os.Lstat(file.target); err == nil {
			return fmt.Errorf("output appeared during generation: %s", file.target)
		} else if !os.IsNotExist(err) {
			return err
		}
		if err := rename(file.temp, file.target); err != nil {
			return err
		}
		file.temp = ""
		file.installed = true
		return nil
	}
	if _, err := os.Lstat(file.backup); err == nil {
		return fmt.Errorf("backup path appeared during generation: %s", file.backup)
	} else if !os.IsNotExist(err) {
		return err
	}
	if _, err := os.Lstat(file.target); err == nil {
		if err := rename(file.target, file.backup); err != nil {
			return err
		}
		file.hadTarget = true
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := rename(file.temp, file.target); err != nil {
		return err
	}
	file.temp = ""
	file.installed = true
	return nil
}

func rollbackWrite(directory string, files []stagedFile, rename renameFunc, cause error) error {
	var rollbackErrors []string
	for index := len(files) - 1; index >= 0; index-- {
		file := &files[index]
		if file.installed {
			if err := os.Remove(file.target); err != nil && !os.IsNotExist(err) {
				rollbackErrors = append(rollbackErrors, fmt.Sprintf("remove %s: %v", file.target, err))
				continue
			}
			file.installed = false
		}
		if file.hadTarget {
			if err := rename(file.backup, file.target); err != nil {
				rollbackErrors = append(rollbackErrors, fmt.Sprintf("restore %s: %v", file.target, err))
				continue
			}
			file.hadTarget = false
			file.backup = ""
		}
	}
	cleanupTemps(files)
	if err := syncDirectory(directory); err != nil {
		rollbackErrors = append(rollbackErrors, fmt.Sprintf("sync rollback directory: %v", err))
	}
	if len(rollbackErrors) != 0 {
		return fmt.Errorf("%w; rollback incomplete: %s", cause, strings.Join(rollbackErrors, "; "))
	}
	return cause
}

func cleanupTemps(files []stagedFile) {
	for _, file := range files {
		if file.temp != "" {
			_ = os.Remove(file.temp)
		}
	}
}
