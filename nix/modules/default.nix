{
  ashGuest = import ./ash-guest.nix;
  ashGuestBoot = import ./ash-guest-boot.nix;
  ashGuestQga = import ./ash-guest-qga.nix;
  ashGuestSsh = import ./ash-guest-ssh.nix;
  ashGuestStore = import ./ash-guest-store.nix;
}
