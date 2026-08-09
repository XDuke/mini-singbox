package config

import "fmt"

type FieldError struct {
	Path   string
	Reason string
	Hint   string
}

func (e *FieldError) Error() string {
	return fmt.Sprintf("%s: %s; fix: %s", e.Path, e.Reason, e.Hint)
}

func fieldError(path, reason, hint string) error {
	return &FieldError{Path: path, Reason: reason, Hint: hint}
}
