open Cmdliner
open Ash

let version = "0.1.5"

let interface_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "interface" ] ~docv:"INTERFACE"
        ~doc:"Network interface used to receive and send mDNS traffic.")

let name_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "name" ] ~docv:"NAME"
        ~doc:"Fully qualified mDNS name to publish, such as work.ash.local.")

let ipv4 =
  let parse value =
    try
      ignore (Mdns.ipv4_octets value);
      Ok value
    with Invalid_argument _ | Failure _ ->
      Error (`Msg (value ^ " is not an IPv4 address"))
  in
  Arg.conv (parse, Format.pp_print_string)

let address_arg =
  Arg.(
    required
    & opt (some ipv4) None
    & info [ "address" ] ~docv:"IPV4"
        ~doc:"IPv4 address returned in the published A record.")

let run interface name address =
  try Mdns.run ~interface ~name ~get_ip:(fun () -> Some address) ()
  with Invalid_argument message | Failure message ->
    Log.error "%s" message;
    2

let man =
  [
    `S Manpage.s_description;
    `P
      "$(tname) is a small standalone mDNS responder. It joins the IPv4 mDNS \
       multicast group on the selected interface and publishes one A record.";
    `P
      "Before publishing, it probes for conflicting records. It then announces \
       the address, answers matching A and ANY questions, detects later \
       conflicts, and sends a zero-TTL goodbye record when terminated.";
    `P
      "The address remains fixed for the lifetime of the process. A supervisor \
       should restart $(tname) when the interface address changes. Ash \
       normally runs it as the transient ash-mdns.service inside each managed \
       VM, but the responder itself is not guest-specific.";
    `S Manpage.s_examples;
    `P
      "Publish work.ash.local on eth0: $(b,ash-mdns --interface eth0 --name \
       work.ash.local --address 192.168.127.101)";
  ]

let command =
  Cmd.v
    (Cmd.info "ash-mdns" ~version
       ~doc:"publish an IPv4 address over multicast DNS" ~man)
    Term.(const run $ interface_arg $ name_arg $ address_arg)

let () = exit (Cmd.eval' command)
