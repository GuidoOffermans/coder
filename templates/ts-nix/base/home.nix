# Base toolset for dotfiles repositories that aren't a home-manager flake.
# Packages only, no files: the user's own dotfiles (install script or symlinks) own ~.
# Owned by the template and rewritten every workspace start; personal changes belong in
# your dotfiles repository.
{ pkgs, ... }:
{
  home.username = "coder";
  home.homeDirectory = "/home/coder";
  home.stateVersion = "26.05";

  home.packages = with pkgs; [
    git
    zsh
    tmux
    neovim
    direnv
    nix-direnv
    fzf
    ripgrep
    fd
    jq

    # Common Neovim config needs: treesitter parsers and Mason LSP installs
    gcc
    gnumake
    unzip
    nodejs
  ];
}
