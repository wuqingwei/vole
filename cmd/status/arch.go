package main

import "runtime"

func runtimeArch() string { return runtime.GOARCH }

// utsString converts a Utsname field ([]int8 or []uint8 depending on arch) to a string.
func utsString[T int8 | uint8](f []T) string {
	b := make([]byte, 0, len(f))
	for _, c := range f {
		if c == 0 {
			break
		}
		b = append(b, byte(c))
	}
	return string(b)
}
