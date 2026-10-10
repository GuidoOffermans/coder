# Builds the NixOS workspace image and loads it into Podman as localhost/ts-nixos-workspace:latest.
# Nix runs in a throwaway nixos/nix container; its store is kept in the nix-builder-store
# volume so rebuilds only build what changed.

podman run --rm `
  -v "${PSScriptRoot}:/src" `
  -v nix-builder-store:/nix `
  -w /src `
  -e 'NIX_CONFIG=experimental-features = nix-command flakes' `
  docker.io/nixos/nix:latest `
  sh -c 'nix build .#default --out-link /tmp/result && cp -L /tmp/result /src/image.tar.gz'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

podman load -i "$PSScriptRoot\image.tar.gz"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Remove-Item -Force "$PSScriptRoot\image.tar.gz" # -Force: it is read-only, like everything from the Nix store
