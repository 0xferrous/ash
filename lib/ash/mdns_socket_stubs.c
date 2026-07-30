#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

static void fail_socket(const char *operation) {
  char message[256];
  snprintf(message, sizeof(message), "%s: %s", operation, strerror(errno));
  caml_failwith(message);
}

CAMLprim value ash_mdns_open_socket(value interface_name_value) {
  CAMLparam1(interface_name_value);

  const char *interface_name = String_val(interface_name_value);
  unsigned int interface_index = if_nametoindex(interface_name);
  if (interface_index == 0) {
    errno = ENODEV;
    fail_socket("mDNS interface lookup");
  }

  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) fail_socket("mDNS socket");

  int enabled = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) < 0) {
    close(fd);
    fail_socket("mDNS SO_REUSEADDR");
  }

  struct sockaddr_in bind_address;
  memset(&bind_address, 0, sizeof(bind_address));
  bind_address.sin_family = AF_INET;
  bind_address.sin_port = htons(5353);
  bind_address.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(fd, (struct sockaddr *)&bind_address, sizeof(bind_address)) < 0) {
    close(fd);
    fail_socket("mDNS bind");
  }

  struct ip_mreqn membership;
  memset(&membership, 0, sizeof(membership));
  membership.imr_multiaddr.s_addr = inet_addr("224.0.0.251");
  membership.imr_ifindex = (int)interface_index;
  if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership,
                 sizeof(membership)) < 0) {
    close(fd);
    fail_socket("mDNS multicast join");
  }

  struct ip_mreqn outgoing_interface;
  memset(&outgoing_interface, 0, sizeof(outgoing_interface));
  outgoing_interface.imr_ifindex = (int)interface_index;
  if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing_interface,
                 sizeof(outgoing_interface)) < 0) {
    close(fd);
    fail_socket("mDNS multicast interface");
  }

  unsigned char ttl = 255;
  if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl)) < 0) {
    close(fd);
    fail_socket("mDNS multicast TTL");
  }

  unsigned char loop = 1;
  if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof(loop)) < 0) {
    close(fd);
    fail_socket("mDNS multicast loop");
  }

  CAMLreturn(Val_int(fd));
}
