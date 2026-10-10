# The workspace's system: NixOS running systemd inside the Podman container.
# Personal shell and tools still come from home-manager (~/dotfiles), and the project's
# toolchain from its flake.nix; this file only holds what belongs to the machine.
# Changes take effect after rebuilding the image (./build.ps1) and restarting the workspace.
{ pkgs, ... }:
{
  boot.isContainer = true;
  system.stateVersion = "26.05";

  # Podman provides the hostname, DNS and /etc/hosts (which holds host.docker.internal)
  networking.hostName = "";
  networking.useHostResolvConf = true;
  networking.firewall.enable = false;
  environment.etc.hosts.enable = false;

  users.mutableUsers = false;
  users.groups.coder.gid = 1000;
  users.users.coder = {
    isNormalUser = true;
    uid = 1000; # same uid as before, so files on the existing volumes stay owned by it
    group = "coder";
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;
  # No passwords anywhere: you get in through the Coder agent, which runs as coder
  users.allowNoPasswordLogin = true;

  nix.channel.enable = false;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "coder" ];
    sandbox = false; # the build sandbox needs namespaces the container doesn't get
  };

  # Before home-manager runs, the startup script needs git (to create the dotfiles repo)
  environment.systemPackages = with pkgs; [ git curl ];

  # Run the prebuilt binaries that editors download into the workspace
  # (code-server, the VS Code and JetBrains backends, Mason's language servers)
  programs.nix-ld.enable = true;
  # ...and the scripts among them that start with #!/bin/bash
  systemd.tmpfiles.rules = [ "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash" ];

  # The Coder agent. The template uploads its init script and token before the container
  # starts; the script downloads the agent binary from the Coder server and runs it.
  systemd.services.coder-agent = {
    description = "Coder workspace agent";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "nix-daemon.socket" ];
    unitConfig.ConditionPathExists = "/var/lib/coder/init.sh";
    # The agent's processes (startup script, terminals, IDE backends) inherit this PATH
    path = [ "/home/coder/.nix-profile" "/run/wrappers" "/run/current-system/sw" ];
    serviceConfig = {
      User = "coder";
      WorkingDirectory = "/home/coder";
      EnvironmentFile = "/var/lib/coder/agent.env";
      ExecStart = "${pkgs.bash}/bin/sh /var/lib/coder/init.sh";
      Restart = "always";
      RestartSec = 5;
    };
  };

  documentation.nixos.enable = false;
}
