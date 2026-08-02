# Import this module into the NixOS configuration used by `ash spawn -f`.
# It enables the guest side of Ash's shared VirtIO-GPU Vulkan mode and installs
# tools for verifying and using it with llama.cpp.
{ pkgs, ... }:
{
  boot.kernelModules = [ "virtio_gpu" ];

  hardware.graphics.enable = true;

  environment.systemPackages = [
    pkgs.vulkan-tools
    pkgs.llama-cpp-vulkan
  ];
}
