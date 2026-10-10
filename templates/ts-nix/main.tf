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
#   - image  localhost/ts-nix-workspace:latest  (build from ./image with `podman build`)
#   - volume ts-nix-src                          (the project's code)
#   - volume coder-nix-store                     (shared Nix store: every Nix package)
#   - volume coder-dotfiles                      (personal home-manager config, git repo;
#                                                 filled from ./dotfiles if empty)
# This template never creates or deletes them, so deleting a workspace keeps your code.
locals {
  image           = "localhost/ts-nix-workspace:latest"
  src_volume      = "ts-nix-src"
  nix_volume      = "coder-nix-store"
  dotfiles_volume = "coder-dotfiles"
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

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e

    # First start with an empty dotfiles volume: fill it from the starter copy in ./dotfiles
    # next to this template. After that, ~/dotfiles is yours; the template never overwrites it.
    if [ ! -f ~/dotfiles/flake.nix ]; then
      %{~for f in fileset("${path.module}/dotfiles", "**")}
      mkdir -p "$(dirname ~/dotfiles/${f})"
      echo '${filebase64("${path.module}/dotfiles/${f}")}' | base64 -d > ~/dotfiles/${f}
      %{~endfor}
      git -C ~/dotfiles init -q -b main
      git -C ~/dotfiles add -A
      git -C ~/dotfiles commit -q -m "Initial dotfiles from the ts-nix template"
    fi

    # Apply the personal environment (zsh, direnv, git, ...) from ~/dotfiles via home-manager.
    # Existing non-managed dotfiles are moved aside with a .backup suffix.
    nix build ~/dotfiles#homeConfigurations.coder.activationPackage -o ~/.cache/hm-activate
    HOME_MANAGER_BACKUP_EXT=backup ~/.cache/hm-activate/activate

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

resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  image    = local.image
  name     = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname = data.coder_workspace.me.name
  # Use the host gateway if the access URL is 127.0.0.1
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
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
