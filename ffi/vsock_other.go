//go:build !linux

package main

// hostVSockCIDChecker is a stub for non-linux hosts: every CID is available,
// and QEMU reports missing or inaccessible host devices at launch.
type hostVSockCIDChecker struct{}

func (c hostVSockCIDChecker) Available(cid int) (bool, error) { return true, nil }
