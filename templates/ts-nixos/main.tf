terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

# Pre-existing resources, created outside this template:
#   - image  localhost/ts-nixos-workspace:latest  (NixOS; build with ./image/build.ps1)
#   - volume ts-nix-src                          (the project's code)
#   - volume coder-nixos-store                   (shared Nix store: every Nix package;
#                                                 Podman creates it on first use)
#   - volume coder-<owner>-dotfiles              (that user's dotfiles, git repo; on first use
#                                                 cloned from the Dotfiles repository parameter,
#                                                 or filled from ./dotfiles; Podman creates it)
# This template never creates or deletes them, so deleting a workspace keeps your code.
locals {
  image           = "localhost/ts-nixos-workspace:latest"
  src_volume      = "ts-nix-src"
  nix_volume      = "coder-nixos-store"
  dotfiles_volume = lower("coder-${data.coder_workspace_owner.me.name}-dotfiles")
  project_path = "/home/coder/ts-nix"

  # Postgres sidecar, reachable from the workspace as db:5432 (not exposed on the host)
  db_image    = "docker.io/library/postgres:18"
  db_user     = "dev"
  db_password = "dev"
  db_name     = "app"
}

provider "docker" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "dotfiles_url" {
  name         = "dotfiles_url"
  display_name = "Dotfiles repository"
  description  = <<-EOT
    Git URL of your dotfiles; leave empty for the starter config. A home-manager flake with
    `homeConfigurations.coder` is applied with home-manager. Anything else gets a base toolset,
    then its install.sh (or bootstrap.sh / setup.sh) runs, or its dotfiles are symlinked into ~.
    Only used while your dotfiles volume is empty: after that ~/dotfiles is yours.
  EOT
  type         = "string"
  default      = ""
  mutable      = true
  icon         = "/icon/dotfiles.svg"
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"

  # The vscode module below has the VS Code button (it opens the project folder); hide the
  # built-in one, which opens the home folder
  display_apps {
    vscode = false
  }

  startup_script = <<-EOT
    set -e

    # First start with an empty dotfiles volume: clone the Dotfiles repository parameter, or
    # fill it from the starter copy in ./dotfiles next to this template. After that, ~/dotfiles
    # is yours; the template never overwrites it.
    if [ -z "$(ls -A ~/dotfiles)" ]; then
      if [ -n "$DOTFILES_URL" ]; then
        git clone "$DOTFILES_URL" ~/dotfiles
      else
        %{~for f in fileset("${path.module}/dotfiles", "**")}
        mkdir -p "$(dirname ~/dotfiles/${f})"
        echo '${filebase64("${path.module}/dotfiles/${f}")}' | base64 -d > ~/dotfiles/${f}
        %{~endfor}
        git -C ~/dotfiles init -q -b main
        git -C ~/dotfiles add -A
        git -C ~/dotfiles commit -q -m "Initial dotfiles from the ts-nixos template"
      fi
    elif [ -n "$DOTFILES_URL" ] && [ "$(git -C ~/dotfiles remote get-url origin 2>/dev/null)" != "$DOTFILES_URL" ]; then
      echo "~/dotfiles already has content, so the Dotfiles repository setting is not used" >&2
    fi

    # A home-manager flake (homeConfigurations.coder, like the starter) sets up everything.
    # Other dotfiles get the base toolset from ./base (packages only, no files) via home-manager,
    # then are applied below the way `coder dotfiles` does it.
    if [ -f ~/dotfiles/flake.nix ] &&
       [ "$(nix eval --raw ~/dotfiles#homeConfigurations --apply 'c: if c ? coder then "yes" else "no"' 2>/dev/null)" = yes ]; then
      hm_flake=~/dotfiles
    else
      hm_flake=~/.local/share/coder-base
      rm -rf "$hm_flake"
      %{~for f in fileset("${path.module}/base", "**")}
      mkdir -p "$(dirname "$hm_flake/${f}")"
      echo '${filebase64("${path.module}/base/${f}")}' | base64 -d > "$hm_flake/${f}"
      %{~endfor}
    fi

    # Existing non-managed dotfiles are moved aside with a .backup suffix.
    nix build "$hm_flake#homeConfigurations.coder.activationPackage" -o ~/.cache/hm-activate
    HOME_MANAGER_BACKUP_EXT=backup ~/.cache/hm-activate/activate

    # Plain dotfiles: run the first install script found (re-run every start, so keep it
    # idempotent), otherwise symlink the repo's dotfiles into ~
    if [ "$hm_flake" != ~/dotfiles ]; then
      cd ~/dotfiles
      installer=""
      for s in install.sh install bootstrap.sh bootstrap script/bootstrap setup.sh setup script/setup; do
        if [ -f "$s" ]; then installer="$s"; break; fi
      done
      if [ -n "$installer" ]; then
        echo "Running $installer from your dotfiles"
        if [ -x "$installer" ]; then "./$installer"; else bash "$installer"; fi
      else
        for f in .[!.]* ..?*; do
          [ -e "$f" ] || continue
          case "$f" in .git|.github|.gitignore) continue ;; esac
          if [ -e ~/"$f" ] && [ ! -L ~/"$f" ]; then
            if [ -e ~/"$f.backup" ]; then
              echo "Skipping $f: ~/$f and ~/$f.backup both exist" >&2
              continue
            fi
            mv ~/"$f" ~/"$f.backup"
          fi
          ln -sfn ~/dotfiles/"$f" ~/"$f"
        done
      fi
      cd ~
    fi

    # Load the flake's dev shell (Node, pnpm, Rust) whenever a shell enters the project
    # Skipped while the project volume is still empty (clone the project into it first)
    cd ${local.project_path}
    if [ -f .envrc ]; then
      direnv allow
    else
      echo "No .envrc in ${local.project_path} yet; skipping direnv"
    fi

    # Install JS dependencies on first start
    if [ -f package.json ] && [ ! -d node_modules ]; then
      nix develop --command pnpm install
    fi
  EOT

  env = {
    # New terminals start here (see programs.zsh in ~/dotfiles/home.nix)
    PROJECT_DIR = local.project_path

    # Connection to the Postgres sidecar (also picked up by psql via the PG* variables)
    DATABASE_URL = "postgres://${local.db_user}:${local.db_password}@db:5432/${local.db_name}"
    PGHOST       = "db"
    PGUSER       = local.db_user
    PGPASSWORD   = local.db_password
    PGDATABASE   = local.db_name

    GIT_AUTHOR_NAME    = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email

    # Read by the startup script on first start (see data.coder_parameter.dotfiles_url)
    DOTFILES_URL = data.coder_parameter.dotfiles_url.value
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Project Disk"
    key          = "2_project_disk"
    script       = "coder stat disk --path ${local.project_path}"
    interval     = 60
    timeout      = 1
  }
}

# Headless Neovim server in the project; attach from your machine with
#   coder port-forward <workspace> --tcp 6666:6666
#   nvim --server 127.0.0.1:6666 --remote-ui
# Listens on localhost only: Neovim's RPC has no auth, the Coder tunnel does.
# Restarted when it exits (e.g. :qa from a client), so it's always there to attach to.
resource "coder_script" "nvim_server" {
  agent_id     = coder_agent.main.id
  display_name = "Neovim server"
  icon         = "/icon/neovim.svg"
  run_on_start = true
  script       = <<-EOT
    #!/usr/bin/env bash
    nohup bash -c '
      # home-manager installs nvim during the startup script
      until command -v nvim >/dev/null; do sleep 2; done
      cd ${local.project_path}
      while true; do
        nvim --headless --listen 127.0.0.1:6666
        sleep 1
      done
    ' >/tmp/nvim-server.log 2>&1 &
  EOT
}

# Opens your local Neovim attached to that server. Needs the nvim-coder:// handler on your
# machine: run client/nvim-coder/install.ps1 from this repo once.
resource "coder_app" "nvim" {
  agent_id     = coder_agent.main.id
  slug         = "nvim"
  display_name = "Neovim"
  icon         = "https://neovim.io/logos/neovim-mark-flat.svg"
  external     = true
  url          = "nvim-coder://open/${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}"
  order        = 4
}

# Runs your own ~/dotfiles/personalize script (if present and executable) on every start, for
# tweaks that don't belong in the template. It lives in the dotfiles volume, so it's shared by
# all your workspaces and versioned with your dotfiles; output goes to ~/personalize.log.
# See https://registry.coder.com/modules/coder/personalize
module "personalize" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/personalize/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  path     = "~/dotfiles/personalize"
}

# See https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  folder   = local.project_path
  order    = 1
}

# See https://registry.coder.com/modules/coder/vscode-desktop
module "vscode" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/vscode-desktop/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  folder   = local.project_path
  order    = 2
}

# WebStorm and RustRover buttons; they open the project through JetBrains Toolbox
# See https://registry.coder.com/modules/coder/jetbrains
module "jetbrains" {
  count      = data.coder_workspace.me.start_count
  source     = "registry.coder.com/coder/jetbrains/coder"
  version    = "~> 1.4"
  agent_id   = coder_agent.main.id
  agent_name = "main"
  folder     = local.project_path
  default    = ["WS", "RR"]
  tooltip    = "Opens in JetBrains Toolbox on your computer (installed on this PC)."
  coder_app_order = 3
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# Private network shared by the workspace and its database
resource "docker_network" "workspace" {
  name = "coder-${data.coder_workspace.me.id}"
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# Database files; kept when the workspace is stopped or deleted, like the home volume
resource "docker_volume" "db_volume" {
  name = "coder-${data.coder_workspace.me.id}-pgdata"
  lifecycle {
    ignore_changes = all
  }
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "db" {
  count = data.coder_workspace.me.start_count
  image = local.db_image
  name  = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}-db"
  env = [
    "POSTGRES_USER=${local.db_user}",
    "POSTGRES_PASSWORD=${local.db_password}",
    "POSTGRES_DB=${local.db_name}",
  ]
  restart = "unless-stopped"

  networks_advanced {
    name    = docker_network.workspace.name
    aliases = ["db"]
  }
  # Postgres 18+ keeps its data under /var/lib/postgresql/<major>/docker
  volumes {
    container_path = "/var/lib/postgresql"
    volume_name    = docker_volume.db_volume.name
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# The workspace mounts the shared store volume over /nix, which hides the image's own store,
# so first copy the image's NixOS system into the volume. Runs to completion before the
# workspace starts; quick once the system is already there.
resource "docker_container" "nix_seed" {
  count      = data.coder_workspace.me.start_count
  image      = local.image
  name       = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}-nix-seed"
  entrypoint = ["/sbin/seed-nix-store"]
  attach     = true
  must_run   = false

  volumes {
    container_path = "/mnt/nix"
    volume_name    = local.nix_volume
  }

  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "workspace" {
  count      = data.coder_workspace.me.start_count
  depends_on = [docker_container.nix_seed]
  image      = local.image
  name       = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname   = data.coder_workspace.me.name
  # Boot NixOS; systemd then starts the agent (coder-agent.service in image/configuration.nix)
  # from the two files uploaded here
  entrypoint = ["/sbin/init"]
  # NixOS mounts tmpfs at /run/wrappers (for sudo, since Podman's /run is nosuid) and some
  # services keep this capability; systemd-nspawn gives it to NixOS containers too
  capabilities {
    add = ["SYS_ADMIN"]
  }
  upload {
    file = "/var/lib/coder/init.sh"
    # Use the host gateway if the access URL is 127.0.0.1
    content = replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")
  }
  upload {
    file    = "/var/lib/coder/agent.env"
    content = "CODER_AGENT_TOKEN=${coder_agent.main.token}\n"
  }
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  networks_advanced {
    name = docker_network.workspace.name
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
  }
  volumes {
    container_path = "/nix"
    volume_name    = local.nix_volume
  }
  volumes {
    container_path = local.project_path
    volume_name    = local.src_volume
  }
  volumes {
    container_path = "/home/coder/dotfiles"
    volume_name    = local.dotfiles_volume
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}
