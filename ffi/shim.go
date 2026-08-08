// Command ffi exposes the pure manifest -> QEMU pipeline of the virtle
// library as a C shared library, so OCaml (via ctypes) can call into it
// in-process instead of spawning the virtle CLI.
//
// The shim is consumer-owned glue over the importable virtle packages:
// manifest decode/resolve/validate, QEMU argv generation, and plan
// execution. Manifests are passed as TOML or JSON bytes and returned as JSON
// (resolved manifest) or as a freshly allocated argv array; virtle_launch
// executes a manifest's plan to completion (host run processes, QEMU,
// socket readiness) using Go-side process and socket backends. Handles are
// small integers into a Go registry so the Go garbage collector keeps parsed
// manifests alive for the lifetime of the process.
//
// Memory ownership: strings and argv arrays returned by this library are
// allocated with C malloc and must be released with virtle_string_free and
// virtle_argv_free. Manifest handles must be released with
// virtle_manifest_free.
//
// Build with: go build -buildmode=c-shared -o libvirtle.so .
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unsafe"

	"github.com/shazow/virtle/executor"
	"github.com/shazow/virtle/manifest"
	"github.com/shazow/virtle/plan"
	"github.com/shazow/virtle/qemu"
)

// registry keeps parsed manifests alive for the lifetime of the process.
type registry struct {
	mu   sync.Mutex
	next int64
	m    map[int64]*manifest.Manifest
}

var reg = &registry{m: make(map[int64]*manifest.Manifest)}

func (r *registry) add(m *manifest.Manifest) int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.next++
	r.m[r.next] = m
	return r.next
}

func (r *registry) get(id int64) *manifest.Manifest {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.m[id]
}

func (r *registry) del(id int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.m, id)
}

// virtle_ffi_version returns a static version string for the library.
//
//export virtle_ffi_version
func virtle_ffi_version() *C.char {
	return C.CString("0.1.0")
}

// virtle_manifest_parse decodes and resolves a manifest document (TOML or
// JSON bytes). Returns a non-zero handle on success; on failure returns 0
// with *err set to a malloc'd message.
//
//export virtle_manifest_parse
func virtle_manifest_parse(data *C.char, length C.size_t, out *C.int64_t, err **C.char) C.int {
	if data == nil || out == nil || err == nil {
		return -1
	}
	raw := C.GoBytes(unsafe.Pointer(data), C.int(length))
	doc, e := manifest.DecodeDocumentBytes(raw, "manifest.toml")
	if e == nil {
		var m *manifest.Manifest
		m, e = doc.Manifest()
		if e == nil {
			if _, e = m.ResolvedQEMU(); e == nil {
				*out = C.int64_t(reg.add(m))
				return 0
			}
		}
	}
	*err = C.CString(e.Error())
	return 1
}

// virtle_manifest_resolved_json renders the resolved manifest as JSON.
//
//export virtle_manifest_resolved_json
func virtle_manifest_resolved_json(handle C.int64_t, out **C.char, err **C.char) C.int {
	m := reg.get(int64(handle))
	if m == nil {
		*err = C.CString("invalid manifest handle")
		return 1
	}
	data, e := json.MarshalIndent(m, "", "  ")
	if e != nil {
		*err = C.CString(e.Error())
		return 1
	}
	*out = C.CString(string(data))
	return 0
}

// virtle_qemu_argv builds the QEMU argv for a parsed manifest handle. cid is
// the allocated vsock context id; incoming adds "-incoming defer" for state
// restore. The caller frees argv and its elements with virtle_argv_free.
//
//export virtle_qemu_argv
func virtle_qemu_argv(handle C.int64_t, cid C.int, incoming C.int, argvOut ***C.char, argcOut *C.size_t, err **C.char) C.int {
	m := reg.get(int64(handle))
	if m == nil {
		*err = C.CString("invalid manifest handle")
		return 1
	}
	q, e := m.ResolvedQEMU()
	if e != nil {
		*err = C.CString(e.Error())
		return 1
	}
	argv, e := qemu.BuildArgs(q, int(cid), incoming != 0)
	if e != nil {
		*err = C.CString(e.Error())
		return 1
	}
	ptr := C.malloc(C.size_t(len(argv)) * C.size_t(unsafe.Sizeof(uintptr(0))))
	elems := unsafe.Slice((**C.char)(ptr), len(argv))
	for i, arg := range argv {
		elems[i] = C.CString(arg)
	}
	*argvOut = (**C.char)(ptr)
	*argcOut = C.size_t(len(argv))
	return 0
}

// virtle_argv_free releases an argv array returned by virtle_qemu_argv.
//
//export virtle_argv_free
func virtle_argv_free(argv **C.char, argc C.size_t) {
	if argv == nil {
		return
	}
	elems := unsafe.Slice(argv, int(argc))
	for _, s := range elems {
		C.free(unsafe.Pointer(s))
	}
	C.free(unsafe.Pointer(argv))
}

// virtle_string_free releases a string returned by this library.
//
//export virtle_string_free
func virtle_string_free(s *C.char) {
	C.free(unsafe.Pointer(s))
}

// virtle_manifest_free releases a parsed manifest handle.
//
//export virtle_manifest_free
func virtle_manifest_free(handle C.int64_t) {
	reg.del(int64(handle))
}

// statSocketWaiter is a plan.SocketWaiter that polls with os.Stat.
type statSocketWaiter struct{ poll time.Duration }

func (w statSocketWaiter) Wait(ctx context.Context, paths []string) error {
	for {
		all := true
		for _, p := range paths {
			if _, err := os.Stat(p); err != nil {
				all = false
				break
			}
		}
		if all {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(w.poll):
		}
	}
}

// launchPlan executes a resolved manifest's plan to completion: prepare
// runtime directories, start host run processes (virtiofsd daemons lower
// into runs), start QEMU, wait for the QMP socket, hold until the VM exits,
// then tear everything down. It returns the allocated CID and the QMP socket
// path on success. This mirrors example/launch in the virtle repo, but is
// driven through the plan package's execution primitives.
func launchPlan(ctx context.Context, m *manifest.Manifest, cid int, incoming bool) (usedCID int, qmpSocket string, err error) {
	p, err := plan.BuildPlan(plan.Spec{Manifest: m}, nil, nil)
	if err != nil {
		return 0, "", err
	}
	q, err := m.ResolvedQEMU()
	if err != nil {
		return 0, "", err
	}
	if cid <= 0 {
		cid, err = plan.AcquireCID(m, nil, hostVSockCIDChecker{})
		if err != nil {
			return 0, "", err
		}
	}
	argv, err := qemu.BuildArgs(q, cid, incoming)
	if err != nil {
		return 0, "", err
	}

	runner := &executor.Runner{}
	processes := plan.NewProcessSet()
	cleanup := func() { _ = processes.Close(context.Background()) }

	// Prepare the runtime directories and clear stale sockets.
	for _, dir := range m.ResolvedPersistenceDirectories() {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return 0, "", err
		}
	}
	for _, path := range p.RuntimeSocketCleanupFiles() {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return 0, "", err
		}
		_ = os.Remove(path)
	}

	// Start host run processes (virtiofsd daemons are lowered into runs).
	runs, err := m.ResolvedRuns(cid)
	if err != nil {
		return 0, "", err
	}
	started := executor.NewGroup()
	for _, run := range runs {
		if len(run.Exec) == 0 {
			continue
		}
		cmd := executor.Command(run.Exec[0], run.Exec[1:], run.Env)
		cmd.Dir = run.Dir
		proc, err := runner.Start(cmd)
		if err != nil {
			cleanup()
			return 0, "", err
		}
		started.Add(proc)
	}
	processes.AddGroup(started)

	// Wait for virtiofs daemon sockets to appear.
	if err := plan.WaitForSockets(ctx, plan.SocketWait{
		Stage:        "host startup",
		SocketPaths:  p.VirtioFSSocketPaths,
		SocketWaiter: statSocketWaiter{poll: 100 * time.Millisecond},
		Watchers:     processes.Watchers(),
	}); err != nil {
		cleanup()
		return 0, "", err
	}

	// Start QEMU; guest serial output goes to stderr so it is observable.
	qemuCmd := executor.Command(q.BinaryPath, argv, nil)
	qemuCmd.Dir = m.Paths.WorkingDir
	qemuCmd.Stdout = os.Stderr
	qemuCmd.Stderr = os.Stderr
	qemuProc, err := runner.Start(qemuCmd)
	if err != nil {
		cleanup()
		return 0, "", err
	}
	processes.SetQEMU(qemuProc)

	// Wait for the QMP socket, then hold until the VM exits.
	if err := plan.WaitForSockets(ctx, plan.SocketWait{
		Stage:        "vm startup",
		SocketPaths:  []string{p.Paths.QMPSocket},
		SocketWaiter: statSocketWaiter{poll: 100 * time.Millisecond},
		Watchers:     processes.Watchers(),
	}); err != nil {
		cleanup()
		return 0, "", err
	}
	if err := plan.WaitForLifecycleProcess(ctx, plan.LifecycleProcessWait{
		Stage:    "vm",
		Process:  qemuProc,
		Watchers: processes.VMWatchers(),
	}); err != nil {
		cleanup()
		return 0, "", err
	}
	cleanup()
	return cid, p.Paths.QMPSocket, nil
}

// virtle_launch executes the plan for a parsed manifest to completion and
// returns a JSON result {"cid":N,"qmpSocket":"..."}. cid <= 0 allocates a
// free vsock CID from the manifest range. On failure returns non-zero with
// *err set.
//
//export virtle_launch
func virtle_launch(handle C.int64_t, cid C.int, incoming C.int, outJSON **C.char, err **C.char) C.int {
	m := reg.get(int64(handle))
	if m == nil {
		*err = C.CString("invalid manifest handle")
		return 1
	}
	usedCID, qmpSocket, e := launchPlan(context.Background(), m, int(cid), incoming != 0)
	if e != nil {
		*err = C.CString(e.Error())
		return 1
	}
	result, e := json.Marshal(map[string]any{
		"cid":       usedCID,
		"qmpSocket": qmpSocket,
	})
	if e != nil {
		*err = C.CString(e.Error())
		return 1
	}
	*outJSON = C.CString(string(result))
	return 0
}

func main() {}
