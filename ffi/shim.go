// Command ffi exposes the pure manifest -> QEMU pipeline of the virtle
// library as a C shared library, so OCaml (via ctypes) can call into it
// in-process instead of spawning the virtle CLI.
//
// The shim is consumer-owned glue over the importable virtle packages:
// manifest decode/resolve/validate and QEMU argv generation. Manifests are
// passed as TOML or JSON bytes and returned as JSON (resolved manifest) or
// as a freshly allocated argv array. Handles are small integers into a Go
// registry so the Go garbage collector keeps parsed manifests alive for the
// lifetime of the process.
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
	"encoding/json"
	"sync"
	"unsafe"

	"github.com/shazow/virtle/manifest"
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

func main() {}
