#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef __linux__
#include <linux/vm_sockets.h>
#endif

static void fail_errno(const char *operation, int error) {
  char message[256];
  snprintf(message, sizeof(message), "%s: %s", operation, strerror(error));
  caml_failwith(message);
}

static int close_on_exec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  return flags == -1 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1 ? -1 : 0;
}

CAMLprim value agent_portal_peer_credentials(value fd_value) {
  CAMLparam1(fd_value);
  CAMLlocal1(result);
#ifdef SO_PEERCRED
  struct ucred credentials;
  socklen_t length = sizeof(credentials);
  if (getsockopt(Int_val(fd_value), SOL_SOCKET, SO_PEERCRED, &credentials, &length) == -1)
    fail_errno("getsockopt(SO_PEERCRED)", errno);
  result = caml_alloc_tuple(3);
  Store_field(result, 0, Val_int(credentials.pid));
  Store_field(result, 1, Val_int(credentials.uid));
  Store_field(result, 2, Val_int(credentials.gid));
  CAMLreturn(result);
#else
  caml_failwith("SO_PEERCRED is unavailable on this platform");
#endif
}

CAMLprim value agent_portal_vsock_listen(value port_value, value backlog_value) {
  CAMLparam2(port_value, backlog_value);
#ifdef __linux__
  int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd == -1) fail_errno("socket(AF_VSOCK)", errno);

  struct sockaddr_vm address;
  memset(&address, 0, sizeof(address));
  address.svm_family = AF_VSOCK;
  address.svm_cid = VMADDR_CID_ANY;
  address.svm_port = (unsigned int)Int_val(port_value);
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) == -1) {
    int error = errno;
    close(fd);
    fail_errno("bind(AF_VSOCK)", error);
  }
  if (listen(fd, Int_val(backlog_value)) == -1) {
    int error = errno;
    close(fd);
    fail_errno("listen(AF_VSOCK)", error);
  }
  CAMLreturn(Val_int(fd));
#else
  caml_failwith("AF_VSOCK is unavailable on this platform");
#endif
}

CAMLprim value agent_portal_vsock_connect(value cid_value, value port_value) {
  CAMLparam2(cid_value, port_value);
#ifdef __linux__
  int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd == -1) fail_errno("socket(AF_VSOCK)", errno);

  struct sockaddr_vm address;
  memset(&address, 0, sizeof(address));
  address.svm_family = AF_VSOCK;
  address.svm_cid = (unsigned int)Int_val(cid_value);
  address.svm_port = (unsigned int)Int_val(port_value);

  int result;
  caml_enter_blocking_section();
  result = connect(fd, (struct sockaddr *)&address, sizeof(address));
  int error = errno;
  caml_leave_blocking_section();
  if (result == -1) {
    close(fd);
    fail_errno("connect(AF_VSOCK)", error);
  }
  CAMLreturn(Val_int(fd));
#else
  caml_failwith("AF_VSOCK is unavailable on this platform");
#endif
}

CAMLprim value agent_portal_vsock_accept(value fd_value) {
  CAMLparam1(fd_value);
  CAMLlocal1(result);
#ifdef __linux__
  struct sockaddr_vm address;
  socklen_t length = sizeof(address);
  int fd;
  caml_enter_blocking_section();
  fd = accept(Int_val(fd_value), (struct sockaddr *)&address, &length);
  int error = errno;
  caml_leave_blocking_section();
  if (fd == -1) fail_errno("accept(AF_VSOCK)", error);
  if (close_on_exec(fd) == -1) {
    error = errno;
    close(fd);
    fail_errno("fcntl(FD_CLOEXEC)", error);
  }
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(fd));
  Store_field(result, 1, Val_int(address.svm_cid));
  CAMLreturn(result);
#else
  caml_failwith("AF_VSOCK is unavailable on this platform");
#endif
}
