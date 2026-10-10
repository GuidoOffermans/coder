{
  description = "ts-nixos workspace image: NixOS, booting systemd inside a Podman container";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
      };
      toplevel = nixos.config.system.build.toplevel;

      # The workspace mounts the shared store volume over /nix, which hides this image's own
      # store. The template runs this first (with the volume at /mnt/nix) to copy the system
      # into it; paths already there are skipped, so it is quick after the first time.
      seed = pkgs.writeShellScript "seed-nix-store" ''
        set -e
        export PATH=${pkgs.coreutils}/bin
        ${pkgs.nix}/bin/nix --extra-experimental-features nix-command --option build-users-group "" \
          copy --no-check-sigs --to 'local?root=/mnt' ${toplevel}
        # Keep it safe from `nix-collect-garbage` run in any workspace sharing the volume
        mkdir -p /mnt/nix/var/nix/gcroots
        ln -sfn ${toplevel} /mnt/nix/var/nix/gcroots/ts-nixos-workspace
      '';

      root = pkgs.runCommand "workspace-root" { } ''
        mkdir -p $out/sbin
        ln -s ${toplevel}/init $out/sbin/init
        ln -s ${seed} $out/sbin/seed-nix-store
      '';
    in
    {
      nixosConfigurations.workspace = nixos;

      packages.${system}.default = pkgs.dockerTools.buildLayeredImage {
        name = "localhost/ts-nixos-workspace";
        tag = "latest";
        contents = [ root ];
        # Registers the image's store paths, so the seed step can `nix copy` them
        includeNixDB = true;
        # Mount points for the volumes; a fresh volume inherits this ownership (coder = 1000)
        fakeRootCommands = ''
          mkdir -p etc tmp var home/coder/dotfiles root
          chmod 1777 tmp
          chown -R 1000:1000 home/coder
        '';
        config = {
          # Podman switches to systemd mode (tmpfs /run, cgroups, stop signal) for /sbin/init
          Entrypoint = [ "/sbin/init" ];
          StopSignal = "SIGRTMIN+3";
          # For `podman exec`; systemd services set their own PATH
          Env = [ "PATH=/run/wrappers/bin:/run/current-system/sw/bin" ];
        };
      };
    };
}
