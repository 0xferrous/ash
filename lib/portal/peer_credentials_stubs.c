#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <sys/socket.h>

CAMLprim value agent_portal_peer_credentials(value fd_value) {
  CAMLparam1(fd_value);
  CAMLlocal1(result);
#ifdef SO_PEERCRED
  struct ucred credentials;
  socklen_t length = sizeof(credentials);
  if (getsockopt(Int_val(fd_value), SOL_SOCKET, SO_PEERCRED, &credentials, &length) == -1)
    caml_failwith("getsockopt(SO_PEERCRED) failed");
  result = caml_alloc_tuple(3);
  Store_field(result, 0, Val_int(credentials.pid));
  Store_field(result, 1, Val_int(credentials.uid));
  Store_field(result, 2, Val_int(credentials.gid));
  CAMLreturn(result);
#else
  caml_failwith("SO_PEERCRED is unavailable on this platform");
#endif
}
