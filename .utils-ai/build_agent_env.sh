#!/bin/sh
set -eu

# Bootstrap a complete agentic development environment on Ubuntu 24.04.
#
# Intended use:
#   curl -fsSL https://raw.githubusercontent.com/grahamlopez/dots/main/.utils/build_agent_env.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/grahamlopez/dots/main/.utils/build_agent_env.sh | sh -s -- --yes
#
# Useful overrides:
#   DOTFILES_REPO=git@github.com:grahamlopez/dots \
#   PI_AGENT_REPO=git@github.com:grahamlopez/pi-configs \
#   INSTALL_ROOT="$HOME/local" \
#   GO_VERSION=go1.26.4 \
#   sh build_agent_env.sh

DOTFILES_REPO=${DOTFILES_REPO:-git@github.com:grahamlopez/dots}
PI_AGENT_REPO=${PI_AGENT_REPO:-git@github.com:grahamlopez/pi-configs}
INSTALL_ROOT=${INSTALL_ROOT:-"$HOME/local"}
APPS_DIR=${APPS_DIR:-"$INSTALL_ROOT/apps"}
OPT_DIR=${OPT_DIR:-"$INSTALL_ROOT/opt"}
BIN_DIR=${BIN_DIR:-"$INSTALL_ROOT/bin"}
SCRATCH_DIR=${SCRATCH_DIR:-"$INSTALL_ROOT/scratch"}
DOTFILES_DIR=${DOTFILES_DIR:-"$HOME/.dots-git"}
PI_AGENT_DIR=${PI_AGENT_DIR:-"$HOME/.pi"}
NVM_VERSION=${NVM_VERSION:-v0.40.4}
NODE_VERSION=${NODE_VERSION:-node}
GO_VERSION=${GO_VERSION:-latest}
GO_INSTALL_DIR=${GO_INSTALL_DIR:-"$OPT_DIR/go"}
CLAUDE_INSTALL_URL=${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}
CODEX_INSTALL_URL=${CODEX_INSTALL_URL:-https://chatgpt.com/codex/install.sh}
CURSOR_INSTALL_URL=${CURSOR_INSTALL_URL:-https://cursor.com/install}
PI_INSTALL_URL=${PI_INSTALL_URL:-https://pi.dev/install.sh}

ASSUME_YES=0
SKIP_DOTFILES=0
SKIP_PI_AGENT=0
SKIP_TMUX=0
SKIP_NVIM=0
SKIP_GO=0
SKIP_AI_TOOLS=0

usage() {
  cat <<'USAGE'
Usage: build_agent_env.sh [options]

Options:
  -y, --yes          Run non-interactively where possible.
  --skip-dotfiles    Do not clone or check out the dotfiles repo.
  --skip-pi-configs  Do not clone or update the pi-configs repo.
  --skip-tmux        Do not build tmux from GitHub releases.
  --skip-nvim        Do not install Neovim from GitHub releases.
  --skip-go          Do not install Go from official binary releases.
  --skip-ai-tools    Do not install Claude, Codex, Cursor, or pi.dev CLIs.
  -h, --help         Show this help.

Environment overrides:
  DOTFILES_REPO      Default: git@github.com:grahamlopez/dots
  PI_AGENT_REPO      Default: git@github.com:grahamlopez/pi-configs
  INSTALL_ROOT       Default: $HOME/local
  NVM_VERSION        Default: v0.40.4
  NODE_VERSION       Default: node
  GO_VERSION         Default: latest (or set to go1.26.4 / 1.26.4)
  GO_INSTALL_DIR     Default: $INSTALL_ROOT/opt/go
  CLAUDE_INSTALL_URL Default: https://claude.ai/install.sh
  CODEX_INSTALL_URL  Default: https://chatgpt.com/codex/install.sh
  CURSOR_INSTALL_URL Default: https://cursor.com/install
  PI_INSTALL_URL     Default: https://pi.dev/install.sh
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      ;;
    --skip-dotfiles)
      SKIP_DOTFILES=1
      ;;
    --skip-pi-configs)
      SKIP_PI_AGENT=1
      ;;
    --skip-tmux)
      SKIP_TMUX=1
      ;;
    --skip-nvim)
      SKIP_NVIM=1
      ;;
    --skip-go)
      SKIP_GO=1
      ;;
    --skip-ai-tools)
      SKIP_AI_TOOLS=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

prompt_yes_no() {
  question=$1

  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi

  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    die "cannot prompt without a TTY; rerun with --yes after confirming the prerequisite manually"
  fi

  printf '%s [y/N] ' "$question" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=
  case "$answer" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_ubuntu_2404() {
  [ -r /etc/os-release ] || die "cannot detect OS; expected Ubuntu 24.04"
  # shellcheck disable=SC1091
  . /etc/os-release

  if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
    die "this installer expects Ubuntu 24.04; detected ${PRETTY_NAME:-unknown OS}"
  fi
}

ensure_dirs() {
  mkdir -p "$APPS_DIR" "$OPT_DIR" "$BIN_DIR" "$SCRATCH_DIR"
  export GOBIN="$BIN_DIR"
  export PATH="$BIN_DIR:$HOME/.local/bin:$HOME/.claude/local/bin:$HOME/.codex/bin:$HOME/.pi/bin:$PATH"
}

symlink_file() {
  destination=$1
  shift
  command_name=$(basename "$destination")
  source_path=

  while [ "$#" -gt 0 ]; do
    candidate=$1
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      source_path=$candidate
      break
    fi
    shift
  done

  if [ -z "$source_path" ]; then
    source_path=$(command -v "$command_name" 2>/dev/null || true)
  fi

  if [ -z "$source_path" ]; then
    die "could not find $command_name after installation; expected to symlink it to $destination"
  fi

  case "$source_path" in
    /*)
      ;;
    *)
      die "resolved $command_name to non-path value '$source_path'; cannot symlink it to $destination"
      ;;
  esac

  if [ "$source_path" = "$destination" ]; then
    return 0
  fi

  ln -sfn "$source_path" "$destination"
}

ensure_profile_snippet() {
  profile=$HOME/.profile
  marker='# agent-env bootstrap'

  touch "$profile"
  if ! grep -Fq "$marker" "$profile"; then
    cat >> "$profile" <<EOF2

# agent-env bootstrap
export PATH="$BIN_DIR:\$HOME/.local/bin:\$PATH"
export GOBIN="$BIN_DIR"
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
EOF2
    return 0
  fi

  if ! grep -Fq 'export GOBIN=' "$profile"; then
    cat >> "$profile" <<EOF2

# Go user command installs
export GOBIN="$BIN_DIR"
EOF2
  fi
}

print_apt_prereq_command() {
  cat <<'EOF2'
sudo apt-get update && sudo apt-get install -y \
  autoconf \
  automake \
  bison \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  fd-find \
  gettext \
  git \
  gnupg \
  jq \
  libevent-dev \
  libncurses-dev \
  ninja-build \
  openssh-client \
  pkg-config \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep \
  shellcheck \
  tar \
  unzip \
  util-linux \
  wget \
  xclip \
  xz-utils
EOF2
}

require_commands() {
  missing=

  for cmd in "$@"; do
    if ! have "$cmd"; then
      missing="$missing $cmd"
    fi
  done

  if [ -n "$missing" ]; then
    warn "missing required commands:$missing"
    cat >&2 <<'EOF2'
Run the Ubuntu prerequisite command, then rerun this installer.
EOF2
    print_apt_prereq_command >&2
    exit 1
  fi
}

confirm_system_packages() {
  log "Confirming Ubuntu package prerequisites"

  cat <<'EOF2'
This installer will not run sudo or apt-get for you.
Run this command on the VM before continuing:

EOF2
  print_apt_prereq_command
  printf '\n'

  if ! prompt_yes_no "Have you run the command above on this VM?"; then
    die "run the prerequisite command, then rerun this script"
  fi

  require_commands \
    autoconf \
    automake \
    awk \
    bash \
    bison \
    cc \
    cmake \
    curl \
    fdfind \
    gettext \
    git \
    jq \
    make \
    mktemp \
    ninja \
    pkg-config \
    python3 \
    rg \
    sed \
    setsid \
    sha256sum \
    shellcheck \
    ssh-keygen \
    ssh-keyscan \
    tar \
    unzip \
    wget \
    xclip \
    xz

  if [ ! -e "$BIN_DIR/fd" ]; then
    ln -sfn "$(command -v fdfind)" "$BIN_DIR/fd"
  fi
}

ensure_github_known_host() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/known_hosts"
  chmod 600 "$HOME/.ssh/known_hosts"

  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    log "Adding github.com to SSH known_hosts"
    ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || die "could not fetch github.com SSH host key"
  fi
}

repo_uses_github_ssh() {
  case "$1" in
    git@github.com:*|ssh://git@github.com/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_github_repo_access() {
  needs_ssh_prompt=0

  if [ "$SKIP_DOTFILES" = 0 ] && repo_uses_github_ssh "$DOTFILES_REPO"; then
    needs_ssh_prompt=1
  fi

  if [ "$SKIP_PI_AGENT" = 0 ] && repo_uses_github_ssh "$PI_AGENT_REPO"; then
    needs_ssh_prompt=1
  fi

  if [ "$needs_ssh_prompt" = 1 ]; then
    ensure_github_known_host

    cat <<EOF2

This installer clones GitHub repositories over SSH.
Make sure this VM has an SSH key loaded and that the public key is allowed on GitHub.
EOF2

    if ! prompt_yes_no "Are the GitHub SSH keys installed and ready?"; then
      die "install an SSH key for GitHub, then rerun this script"
    fi
  fi

  if [ "$SKIP_DOTFILES" = 0 ] && ! git ls-remote "$DOTFILES_REPO" HEAD >/dev/null 2>&1; then
    die "cannot access $DOTFILES_REPO"
  fi

  if [ "$SKIP_PI_AGENT" = 0 ] && ! git ls-remote "$PI_AGENT_REPO" HEAD >/dev/null 2>&1; then
    die "cannot access $PI_AGENT_REPO"
  fi
}

git_default_branch() {
  repo_dir=$1
  branch=$(git --git-dir="$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || branch=
  if [ -n "$branch" ]; then
    printf '%s\n' "$branch"
    return 0
  fi

  branch=$(git --git-dir="$repo_dir" remote show origin | awk '/HEAD branch/ {print $NF; exit}')
  [ -n "$branch" ] || branch=main
  printf '%s\n' "$branch"
}

backup_conflicting_dotfiles() {
  backup_dir=$1
  list_file=$2

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    target=$HOME/$path

    if [ -e "$target" ] || [ -L "$target" ]; then
      mkdir -p "$backup_dir/$(dirname "$path")"
      mv "$target" "$backup_dir/$path"
    fi
  done < "$list_file"
}

install_dotfiles() {
  [ "$SKIP_DOTFILES" = 0 ] || return 0

  log "Installing dotfiles"

  if [ ! -d "$DOTFILES_DIR" ]; then
    git clone --bare "$DOTFILES_REPO" "$DOTFILES_DIR"
    # A bare clone leaves remote.origin.fetch unset, so no refs/remotes/origin/*
    # tracking refs exist and "origin/main" is not a valid object name. Configure
    # the refspec and fetch so the tracking refs (and origin/HEAD) materialize.
    git --git-dir="$DOTFILES_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git --git-dir="$DOTFILES_DIR" fetch --prune origin
    git --git-dir="$DOTFILES_DIR" remote set-head origin --auto >/dev/null 2>&1 || true
  else
    git --git-dir="$DOTFILES_DIR" fetch --prune origin
  fi

  branch=$(git_default_branch "$DOTFILES_DIR")
  tracked_file_list=$SCRATCH_DIR/dotfiles-tracked-files.txt
  git --git-dir="$DOTFILES_DIR" ls-tree -r --name-only "origin/$branch" > "$tracked_file_list"

  if ! git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" checkout -B "$branch" "origin/$branch"; then
    backup_dir=$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)
    warn "dotfile checkout had conflicts; backing up conflicting paths to $backup_dir"
    mkdir -p "$backup_dir"
    backup_conflicting_dotfiles "$backup_dir" "$tracked_file_list"
    git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" checkout -B "$branch" "origin/$branch"
  fi

  git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" config status.showUntrackedFiles no
}

clone_or_update_repo() {
  repo=$1
  dest=$2

  if [ -d "$dest/.git" ]; then
    git -C "$dest" fetch --prune origin
    git -C "$dest" pull --ff-only
  elif [ -e "$dest" ]; then
    die "$dest exists but is not a git repository"
  else
    git clone "$repo" "$dest"
  fi
}

install_pi_agent_repo() {
  [ "$SKIP_PI_AGENT" = 0 ] || return 0

  log "Installing pi-configs repository"
  clone_or_update_repo "$PI_AGENT_REPO" "$PI_AGENT_DIR"
}

latest_github_tag() {
  repo=$1
  latest_url=https://github.com/$repo/releases/latest
  location=$(curl -fsSIL "$latest_url" | tr -d '\r' | awk '/^[Ll]ocation:/ {value=$2} END {print value}')
  tag=${location##*/}

  if [ -z "$tag" ] || [ "$tag" = "$location" ]; then
    die "could not determine latest release tag for $repo"
  fi
  printf '%s\n' "$tag"
}

download_file() {
  url=$1
  dest=$2

  if have wget; then
    wget -q -O "$dest" "$url"
  else
    curl -fsSL "$url" -o "$dest"
  fi
}

cpu_count() {
  if have nproc; then
    nproc
  else
    getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2\n'
  fi
}

install_tmux() {
  [ "$SKIP_TMUX" = 0 ] || return 0

  log "Building latest tmux release"
  tag=$(latest_github_tag tmux/tmux)
  version=${tag#tmux-}
  prefix=$APPS_DIR/tmux-$version
  archive=$SCRATCH_DIR/tmux-$version.tar.gz
  src_dir=$SCRATCH_DIR/tmux-$version

  if [ -x "$prefix/bin/tmux" ]; then
    log "tmux $version is already installed"
  else
    rm -rf "$src_dir"
    download_file "https://github.com/tmux/tmux/releases/download/$tag/tmux-$version.tar.gz" "$archive"
    tar -xzf "$archive" -C "$SCRATCH_DIR"

    (
      cd "$src_dir"
      ./configure --prefix="$prefix"
      make -j"$(cpu_count)"
      make install
    )
  fi

  ln -sfn "$prefix" "$APPS_DIR/tmux"
  symlink_file "$BIN_DIR/tmux" "$prefix/bin/tmux"
}

machine_arch() {
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      printf 'x86_64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    *)
      die "unsupported architecture for Neovim release asset: $arch"
      ;;
  esac
}

install_nvim() {
  [ "$SKIP_NVIM" = 0 ] || return 0

  log "Installing latest Neovim release"
  tag=$(latest_github_tag neovim/neovim)
  version=${tag#v}
  arch=$(machine_arch)
  asset=nvim-linux-$arch.tar.gz
  prefix=$APPS_DIR/nvim-$version
  archive=$SCRATCH_DIR/$asset

  if [ -x "$prefix/bin/nvim" ]; then
    log "Neovim $version is already installed"
  else
    rm -rf "$prefix" "$SCRATCH_DIR/nvim-linux-$arch"
    download_file "https://github.com/neovim/neovim/releases/download/$tag/$asset" "$archive"
    tar -xzf "$archive" -C "$SCRATCH_DIR"
    mv "$SCRATCH_DIR/nvim-linux-$arch" "$prefix"
  fi

  ln -sfn "$prefix" "$APPS_DIR/nvim"
  symlink_file "$BIN_DIR/nvim" "$prefix/bin/nvim"
}

go_release_arch() {
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      printf 'amd64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    *)
      die "unsupported architecture for Go release asset: $arch"
      ;;
  esac
}

latest_go_version() {
  version=$(curl -fsSL 'https://go.dev/VERSION?m=text' | awk 'NR == 1 { print; exit }')
  [ -n "$version" ] || die "could not determine latest Go version"
  printf '%s\n' "$version"
}

normalize_go_version() {
  version=$1
  case "$version" in
    latest)
      latest_go_version
      ;;
    go*)
      printf '%s\n' "$version"
      ;;
    [0-9]*)
      printf 'go%s\n' "$version"
      ;;
    *)
      die "GO_VERSION must be 'latest' or a Go release version like go1.26.4"
      ;;
  esac
}

install_go() {
  [ "$SKIP_GO" = 0 ] || return 0

  log "Installing Go from official binary releases"
  version=$(normalize_go_version "$GO_VERSION")
  case "$version" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
      die "GO_VERSION resolved to unsafe release name: $version"
      ;;
  esac

  arch=$(go_release_arch)
  filename=$version.linux-$arch.tar.gz
  prefix=$GO_INSTALL_DIR/$version
  archive=$SCRATCH_DIR/$filename
  metadata=$SCRATCH_DIR/go-releases.json

  download_file 'https://go.dev/dl/?mode=json&include=all' "$metadata"
  sha256=$(jq -r --arg filename "$filename" '[.[] | .files[] | select(.filename == $filename) | .sha256][0] // ""' "$metadata")
  [ -n "$sha256" ] || die "could not find checksum for $filename in Go release metadata"

  mkdir -p "$GO_INSTALL_DIR" "$BIN_DIR"

  if [ -x "$prefix/bin/go" ]; then
    log "Go $version is already installed"
  elif [ -e "$prefix" ]; then
    die "$prefix exists but does not contain bin/go"
  else
    extract_dir=$SCRATCH_DIR/go-extract-$version
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    download_file "https://go.dev/dl/$filename" "$archive"
    printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c -

    tar -xzf "$archive" -C "$extract_dir"
    [ -x "$extract_dir/go/bin/go" ] || die "Go archive did not contain go/bin/go"
    mv "$extract_dir/go" "$prefix"
    rm -rf "$extract_dir"
  fi

  ln -sfn "$version" "$GO_INSTALL_DIR/current"
  symlink_file "$BIN_DIR/go" "$GO_INSTALL_DIR/current/bin/go"
  symlink_file "$BIN_DIR/gofmt" "$GO_INSTALL_DIR/current/bin/gofmt"

  export GOBIN="$BIN_DIR"
  goroot=$("$BIN_DIR/go" env GOROOT)
  [ -d "$goroot/src" ] || die "installed go reported unusable GOROOT: $goroot"

  log "Go $version installed with GOROOT=$goroot and GOBIN=$GOBIN"
}

install_nvm_node() {
  log "Installing nvm, Node.js, and npm"
  export NVM_DIR="$HOME/.nvm"

  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    mkdir -p "$NVM_DIR"
    download_file "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" "$SCRATCH_DIR/nvm-install.sh"
    PROFILE=/dev/null bash "$SCRATCH_DIR/nvm-install.sh"
  fi

  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install "$NODE_VERSION"
  nvm alias default "$NODE_VERSION"
  nvm use default
  npm install -g npm@latest
}

install_global_npm_tools() {
  log "Installing global npm development tools"
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm use default >/dev/null

  npm install -g \
    vite \
    typescript \
    tsx \
    pnpm \
    yarn
}

install_ai_tools() {
  [ "$SKIP_AI_TOOLS" = 0 ] || return 0

  log "Installing agent CLIs"
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm use default >/dev/null

  download_file "$CLAUDE_INSTALL_URL" "$SCRATCH_DIR/claude-install.sh"
  bash "$SCRATCH_DIR/claude-install.sh"
  symlink_file "$BIN_DIR/claude" \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/local/bin/claude"

  download_file "$CODEX_INSTALL_URL" "$SCRATCH_DIR/codex-install.sh"
  CODEX_NON_INTERACTIVE=true sh "$SCRATCH_DIR/codex-install.sh"
  symlink_file "$BIN_DIR/codex" \
    "$HOME/.local/bin/codex" \
    "$HOME/.codex/bin/codex"

  download_file "$CURSOR_INSTALL_URL" "$SCRATCH_DIR/cursor-install.sh"
  bash "$SCRATCH_DIR/cursor-install.sh"
  symlink_file "$BIN_DIR/agent" \
    "$HOME/.local/bin/agent"
  symlink_file "$BIN_DIR/cursor-agent" \
    "$HOME/.local/bin/cursor-agent"
  symlink_file "$BIN_DIR/cursor" \
    "$HOME/.local/bin/cursor-agent" \
    "$HOME/.local/bin/agent"

  download_file "$PI_INSTALL_URL" "$SCRATCH_DIR/pi-install.sh"
  # Pi reads its install confirmation from /dev/tty. Running it without a
  # controlling TTY makes its installer choose the install/reinstall default.
  TERM=dumb setsid sh "$SCRATCH_DIR/pi-install.sh"
  symlink_file "$BIN_DIR/pi" \
    "$HOME/.local/bin/pi" \
    "$HOME/.pi/bin/pi"
}

print_completion_notes() {
  cat <<EOF2

Done.

Installed into:
  $INSTALL_ROOT

Make sure these settings are active in new shells:
  PATH includes $BIN_DIR and $HOME/.local/bin
  GOBIN=$BIN_DIR

If this was the first nvm install in the shell, open a new terminal or run:
  export NVM_DIR="\$HOME/.nvm"
  . "\$NVM_DIR/nvm.sh"
EOF2
}

main() {
  require_ubuntu_2404
  ensure_dirs
  confirm_system_packages

  if [ "$SKIP_DOTFILES" = 0 ] || [ "$SKIP_PI_AGENT" = 0 ]; then
    require_github_repo_access
  fi

  install_dotfiles
  install_pi_agent_repo
  install_tmux
  install_nvim
  install_go
  install_nvm_node
  ensure_profile_snippet
  install_global_npm_tools
  install_ai_tools
  print_completion_notes
}

main "$@"
