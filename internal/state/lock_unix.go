//go:build unix

package state

import (
	"os"
	"syscall"
)

type lockMode int

const (
	lockExclusive lockMode = syscall.LOCK_EX
	lockShared    lockMode = syscall.LOCK_SH
)

func lockFile(f *os.File, mode lockMode) error {
	return syscall.Flock(int(f.Fd()), int(mode))
}

func unlockFile(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}
