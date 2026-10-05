# Workspace image: Ubuntu + Nix, nothing else.
# Everything else comes from Nix:
#   - personal shell/tools: home-manager config in the coder-dotfiles volume
#   - project toolchain:    the project's flake.nix
# Nix itself is the Ubuntu package (/usr/bin/nix), so it never depends on the
# contents of the shared /nix volume, which only holds the package store.
#
# Pinned to one Ubuntu release so rebuilds only change when this file does.
FROM docker.io/library/ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Only what's needed before home-manager runs:
#   ca-certificates + curl: the Coder agent download and Nix fetching over https
#   git:      the startup script creates the dotfiles repo before home-manager provides git
#   sudo:     admin access for the coder user
#   locales:  en_US.UTF-8
#   less, procps: pager and ps/top, missing from the minimal Ubuntu image
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git sudo locales less procps nix-bin \
 && rm -rf /var/lib/apt/lists/* \
 && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Replace Ubuntu's default `ubuntu` user (uid 1000) with `coder` at the same uid,
# so files on the existing volumes stay owned by it
RUN userdel -r ubuntu \
 && useradd coder --create-home --shell=/bin/bash --uid=1000 --user-group \
 && echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nopasswd \
 && chmod 0440 /etc/sudoers.d/nopasswd

# Single-user Nix: coder owns the store, no daemon needed
RUN mkdir -p /nix/store /nix/var/nix /etc/nix && chown -R coder:coder /nix \
 && printf 'store = local\nexperimental-features = nix-command flakes\nsandbox = false\nbuild-users-group =\n' > /etc/nix/nix.conf

# Put the home-manager profile first on PATH for every session
ENV PATH=/home/coder/.nix-profile/bin:$PATH

# Mount point for the dotfiles volume; a fresh volume inherits this ownership
RUN mkdir -p /home/coder/dotfiles && chown coder:coder /home/coder/dotfiles

USER coder
WORKDIR /home/coder
