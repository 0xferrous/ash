//go:build linux

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	vhostVSockPath                = "/dev/vhost-vsock"
	vhostVSockSetGuestCID uintptr = 0x4008af60
)

// hostVSockCIDChecker probes /dev/vhost-vsock to find a free guest CID,
// mirroring what virtle's runtime manager does at launch.
type hostVSockCIDChecker struct{}

func (c hostVSockCIDChecker) Available(cid int) (bool, error) {
	file, err := os.OpenFile(vhostVSockPath, os.O_RDWR|syscall.O_CLOEXEC, 0)
	if err != nil {
		// No vhost-vsock device; let QEMU report missing host devices later.
		return true, nil
	}
	defer file.Close()

	value := uint64(cid)
	_, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		file.Fd(),
		vhostVSockSetGuestCID,
		uintptr(unsafe.Pointer(&value)),
	)
	switch errno {
	case 0:
		return true, nil
	case syscall.EADDRINUSE:
		return false, nil
	default:
		return false, fmt.Errorf("check vsock cid %d availability: %w", cid, errno)
	}
}
