# Everything personal about the workspace shell lives here.
# Adapted from github.com/GuidoOffermans/dotfiles (zsh, Oh My Posh, git, tmux, Neovim).
# Apply changes with:  nh home switch
# (also applied automatically every time the workspace starts)
{ config, pkgs, lib, ... }:
{
  home.username = "coder";
  home.homeDirectory = "/home/coder";
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    ripgrep
    fd
    jq
    lsd
    tldr
    wget
    zsh-completions
    sesh

    # Neovim, plus what LazyVim needs: compilers for treesitter parsers,
    # unzip + node for the Mason LSP installer, yazi for yazi.nvim,
    # Lua 5.1 + luarocks for lazy.nvim's rocks support
    neovim
    gcc
    gnumake
    tree-sitter
    unzip
    nodejs
    yazi
    lua5_1
    lua51Packages.luarocks
  ];

  home.sessionVariables.EDITOR = "nvim";

  # Your LazyVim config, kept editable in ~/dotfiles/nvim (lazy.nvim also writes its lock file there)
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/nvim";

  # code-server (VS Code in the browser) draws text with fonts installed on *your* machine,
  # so JetBrains Mono Nerd Font must be installed there (it is on Windows). This only
  # merges the font keys into code-server's settings, keeping anything set in its UI.
  home.activation.codeServerFont = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    f="$HOME/.local/share/code-server/User/settings.json"
    mkdir -p "$(dirname "$f")"
    [ -s "$f" ] || echo '{}' > "$f"
    font="'JetBrainsMono Nerd Font', 'JetBrainsMono NF', monospace"
    if ${pkgs.jq}/bin/jq --arg font "$font" \
        '. + {"editor.fontFamily": $font, "terminal.integrated.fontFamily": $font}' \
        "$f" > "$f.tmp"; then
      mv "$f.tmp" "$f"
    else
      rm -f "$f.tmp"
      echo "code-server settings.json is not plain JSON; set the font in its UI instead" >&2
    fi
  '';

  # `nh home switch` applies ~/dotfiles and shows what changed
  programs.nh = {
    enable = true;
    flake = "${config.home.homeDirectory}/dotfiles";
  };

  programs.tmux = {
    enable = true;
    shell = "${pkgs.zsh}/bin/zsh";
    prefix = "C-s";
    baseIndex = 1;
    mouse = true;
    plugins = with pkgs.tmuxPlugins; [
      sensible
      vim-tmux-navigator
      nord
    ];
    extraConfig = ''
      unbind r
      bind r source-file ~/.config/tmux/tmux.conf \; display-message "Config reloaded..."

      set-option -sa terminal-overrides ",xterm*:Tc"
      set-window-option -g pane-base-index 1
      set-option -g renumber-windows on

      bind-key x kill-pane # skip "kill-pane 1? (y/n)" prompt
      set -g detach-on-destroy off
      set -g set-clipboard on

      # LDUR
      bind-key h select-pane -L
      bind-key j select-pane -D
      bind-key k select-pane -U
      bind-key l select-pane -R

      set-option -g status-position top

      bind-key "T" run-shell "sesh connect \"$(
        sesh list --icons | fzf-tmux -p 80%,70% \
          --no-sort --ansi --border-label ' sesh ' --prompt '⚡  ' \
          --header '  ^a all ^t tmux ^g configs ^x zoxide ^d tmux kill ^f find' \
          --bind 'tab:down,btab:up' \
          --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
          --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
          --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
          --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
          --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \
          --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \
          --preview-window 'right:55%' \
          --preview 'sesh preview {}'
      )\""
    '';
  };

  programs.zsh = {
    enable = true;
    defaultKeymap = "emacs";
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history = {
      size = 10000;
      save = 10000;
      share = true;
      append = true;
      ignoreSpace = true;
      ignoreDups = true;
      ignoreAllDups = true;
      saveNoDups = true;
      findNoDups = true;
      expireDuplicatesFirst = true;
    };

    shellAliases = {
      gco = "git checkout";
      gst = "git status";
      gcm = "git checkout main";
      ls = "lsd";
      l = "ls -l";
      lsa = "ls -a";
      lla = "ls -la";
      lt = "ls --tree";
      lg = "lazygit";
      vim = "nvim";
      findnm = ''find . -name "node_modules" -type d -prune -print | xargs du -chs'';
    };

    initContent = lib.mkMerge [
      # Fuzzy tab-completion menus: must load right after compinit (order 570)
      # and before autosuggestions / syntax highlighting wrap the widgets
      (lib.mkOrder 571 ''
        source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh
      '')
      ''
      bindkey '^p' history-search-backward
      bindkey '^n' history-search-forward
      bindkey '^[w' kill-region

      zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
      zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"
      zstyle ':completion:*' menu no
      zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
      zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'

      # Start new terminals in the workspace's project (set by the Coder template)
      if [ -n "$PROJECT_DIR" ] && [ "$PWD" = "$HOME" ]; then cd "$PROJECT_DIR"; fi
      ''
    ];
  };

  # The container's login shell is bash; hand interactive sessions over to zsh
  programs.bash = {
    enable = true;
    initExtra = ''
      if [ -z "$ZSH_VERSION" ] && [ -x "$HOME/.nix-profile/bin/zsh" ]; then
        exec "$HOME/.nix-profile/bin/zsh"
      fi
    '';
  };

  # Two-line prompt: path, ❄ when in a Nix dev shell, git status, slow-command timer
  programs.oh-my-posh = {
    enable = true;
    settings = builtins.fromTOML (builtins.readFile ./omp-theme.toml);
  };

  programs.fzf.enable = true;
  programs.zoxide.enable = true;
  programs.bat.enable = true;
  programs.lazygit.enable = true;

  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = false;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true; # caches each project's dev shell, so entering it is instant
    config.global.hide_env_diff = true; # skip the long list of changed variables
  };

  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      # Email comes from the Coder account (GIT_AUTHOR_EMAIL / GIT_COMMITTER_EMAIL)
      user.name = "Guido Offermans";
      init.defaultBranch = "main";
      core.pager = "${pkgs.diff-so-fancy}/bin/diff-so-fancy | less --tabs=4 -RFX";
      interactive.diffFilter = "${pkgs.diff-so-fancy}/bin/diff-so-fancy --patch";
      color = {
        ui = true;
        "diff-highlight" = {
          oldNormal = "red bold";
          oldHighlight = "red bold 52";
          newNormal = "green bold";
          newHighlight = "green bold 22";
        };
        diff = {
          meta = 11;
          frag = "magenta bold";
          func = "146 bold";
          commit = "yellow bold";
          old = "red bold";
          new = "green bold";
          whitespace = "red reverse";
        };
      };
    };
  };
}
