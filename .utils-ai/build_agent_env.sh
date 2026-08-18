#!/bin/sh
set -eu

# Bootstrap a complete agentic development environment on Linux.
#
# Intended use:
#   curl -fsSL https://raw.githubusercontent.com/grahamlopez/dots/main/.utils/build_agent_env.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/grahamlopez/dots/main/.utils/build_agent_env.sh | sh -s -- --yes
#
# Useful overrides:
#   DOTFILES_REPO=git@github.com:grahamlopez/dots \
#   AI_DOTFILES_REPO=git@github.com:grahamlopez/dots-ai \
#   INSTALL_ROOT="$HOME/local" \
#   GO_VERSION=go1.26.4 \
#   sh build_agent_env.sh
#
# Every install step can be turned off individually with its own --skip-* flag,
# and a step that fails is reported at the end instead of aborting the run.
#
# Any Linux distribution works. Prerequisites are checked, never installed, and
# are split into what this installer and the tools it installs need, versus
# optional dev-environment extras; only the required set is enforced. On
# Debian-like systems the exact apt commands are printed, elsewhere the list of
# what is needed. Note that the Neovim release tarballs are glibc-linked, so
# --skip-nvim is required on musl systems such as Alpine.
#
# Dotfiles come from two independent bare repos that both use $HOME as their
# work tree: the core repo and the AI repo. Keep the set of paths they track
# disjoint -- if both track the same file, each repo will report the other
# repo's version as a local modification forever.

DOTFILES_REPO=${DOTFILES_REPO:-git@github.com:grahamlopez/dots}
INSTALL_ROOT=${INSTALL_ROOT:-"$HOME/local"}
APPS_DIR=${APPS_DIR:-"$INSTALL_ROOT/apps"}
OPT_DIR=${OPT_DIR:-"$INSTALL_ROOT/opt"}
BIN_DIR=${BIN_DIR:-"$INSTALL_ROOT/bin"}
SCRATCH_DIR=${SCRATCH_DIR:-"$INSTALL_ROOT/scratch"}
DOTFILES_DIR=${DOTFILES_DIR:-"$HOME/.dots-git"}
AI_DOTFILES_REPO=${AI_DOTFILES_REPO:-git@github.com:grahamlopez/dots-ai}
AI_DOTFILES_DIR=${AI_DOTFILES_DIR:-"$HOME/.dots-ai-git"}
NVM_VERSION=${NVM_VERSION:-v0.40.4}
NODE_VERSION=${NODE_VERSION:-node}
GO_VERSION=${GO_VERSION:-latest}
GO_INSTALL_DIR=${GO_INSTALL_DIR:-"$OPT_DIR/go"}
CLAUDE_INSTALL_URL=${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}
CODEX_INSTALL_URL=${CODEX_INSTALL_URL:-https://chatgpt.com/codex/install.sh}
CURSOR_INSTALL_URL=${CURSOR_INSTALL_URL:-https://cursor.com/install}
PI_INSTALL_URL=${PI_INSTALL_URL:-https://pi.dev/install.sh}
BREV_INSTALL_URL=${BREV_INSTALL_URL:-https://raw.githubusercontent.com/brevdev/brev-cli/main/bin/install-latest.sh}

ASSUME_YES=0
SKIP_PREREQS=0
SKIP_CORE_DOTFILES=0
SKIP_AI_DOTFILES=0
SKIP_TMUX=0
SKIP_NVIM=0
SKIP_GO=0
SKIP_NODE=0
SKIP_NPM_TOOLS=0
SKIP_CLAUDE=0
SKIP_CODEX=0
SKIP_CURSOR=0
SKIP_PI=0
SKIP_BREV=0

# Steps that failed without stopping the run. Reported by print_completion_notes.
FAILED_STEPS=

usage() {
  cat <<'USAGE'
Usage: build_agent_env.sh [options]

Options:
  -y, --yes             Run non-interactively where possible.
  --skip-prereqs        Do not check for prerequisite commands.
  --skip-dotfiles       Do not install either dotfiles repo (core and AI).
  --skip-core-dotfiles  Do not clone or check out the core dotfiles repo.
  --skip-ai-dotfiles    Do not clone or check out the AI dotfiles repo.
  --skip-tmux           Do not build tmux from GitHub releases.
  --skip-nvim           Do not install Neovim from GitHub releases.
  --skip-go             Do not install Go from official binary releases.
  --skip-node           Do not install nvm, Node.js, or npm.
  --skip-npm-tools      Do not install the global npm development tools.
  --skip-ai-tools       Do not install the four agent CLIs (claude, codex,
                        cursor, pi). Brev is separate; use --skip-brev.
  --skip-claude         Do not install the Claude CLI.
  --skip-codex          Do not install the Codex CLI.
  --skip-cursor         Do not install the Cursor agent CLI.
  --skip-pi             Do not install the pi.dev CLI.
  --skip-brev           Do not install the NVIDIA Brev CLI.
  -h, --help            Show this help.

Environment overrides:
  DOTFILES_REPO      Default: git@github.com:grahamlopez/dots
  DOTFILES_DIR       Default: $HOME/.dots-git
  AI_DOTFILES_REPO   Default: git@github.com:grahamlopez/dots-ai
  AI_DOTFILES_DIR    Default: $HOME/.dots-ai-git
  INSTALL_ROOT       Default: $HOME/local
  NVM_VERSION        Default: v0.40.4
  NODE_VERSION       Default: node
  GO_VERSION         Default: latest (or set to go1.26.4 / 1.26.4)
  GO_INSTALL_DIR     Default: $INSTALL_ROOT/opt/go
  CLAUDE_INSTALL_URL Default: https://claude.ai/install.sh
  CODEX_INSTALL_URL  Default: https://chatgpt.com/codex/install.sh
  CURSOR_INSTALL_URL Default: https://cursor.com/install
  PI_INSTALL_URL     Default: https://pi.dev/install.sh
  BREV_INSTALL_URL   Default: brevdev/brev-cli bin/install-latest.sh
  GITHUB_TOKEN       Optional; passed through to the Brev installer, which
                     reads the GitHub API and is rate limited without one.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      ;;
    --skip-prereqs)
      SKIP_PREREQS=1
      ;;
    --skip-dotfiles)
      SKIP_CORE_DOTFILES=1
      SKIP_AI_DOTFILES=1
      ;;
    --skip-core-dotfiles)
      SKIP_CORE_DOTFILES=1
      ;;
    --skip-ai-dotfiles)
      SKIP_AI_DOTFILES=1
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
    --skip-node)
      SKIP_NODE=1
      ;;
    --skip-npm-tools)
      SKIP_NPM_TOOLS=1
      ;;
    --skip-ai-tools)
      SKIP_CLAUDE=1
      SKIP_CODEX=1
      SKIP_CURSOR=1
      SKIP_PI=1
      ;;
    --skip-claude)
      SKIP_CLAUDE=1
      ;;
    --skip-codex)
      SKIP_CODEX=1
      ;;
    --skip-cursor)
      SKIP_CURSOR=1
      ;;
    --skip-pi)
      SKIP_PI=1
      ;;
    --skip-brev)
      SKIP_BREV=1
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

# Run one install step, recording rather than propagating a failure.
#
# The step runs in a subshell so that a die() inside it, or inside any helper it
# calls, ends only the step. The subshell must not be the condition of an "if"
# or the left side of an "||": in both of those contexts the shell ignores set
# -e for the whole command, including inside the subshell, so the step would run
# on past its first failing command and report success. Hence the standalone
# subshell with errexit toggled off around it in the parent only -- and the
# explicit "set -e" inside, because the subshell inherits that "set +e".
run_step() {
  step_label=$1
  shift

  set +e
  ( set -e; "$@" )
  step_status=$?
  set -e

  if [ "$step_status" -ne 0 ]; then
    warn "step '$step_label' failed (exit $step_status); continuing"
    FAILED_STEPS="$FAILED_STEPS $step_label"
  fi

  return 0
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

require_linux() {
  kernel=$(uname -s)
  [ "$kernel" = Linux ] || die "this installer only supports Linux; detected $kernel"
}

# /etc/os-release is sourced in a subshell so its many variables (ID, NAME,
# VERSION, ...) do not leak into the rest of the script.
distro_name() {
  if [ ! -r /etc/os-release ]; then
    printf 'this system\n'
    return 0
  fi

  (
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-${NAME:-this system}}"
  )
}

# True for Ubuntu, Debian, and derivatives (Mint, Pop!_OS, ...), which all use
# the same apt package names.
is_debian_like() {
  [ -r /etc/os-release ] || return 1

  (
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
      *" ubuntu "*|*" debian "*) exit 0 ;;
      *) exit 1 ;;
    esac
  )
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

# Prerequisite packages, split by who needs them.
#
# Required covers this installer plus the tools it installs: the tmux build
# needs a toolchain and the libevent/ncurses headers, and that same toolchain is
# what nvim-treesitter uses to compile parsers, what node-gyp uses for native npm
# modules, and what cgo uses. Optional is the dev-box set -- nothing in the
# bootstrap or the installed tools calls any of it.
#
# Deliberately absent from both: autoconf, automake, bison, cmake, gettext, and
# ninja. tmux ships a pre-generated configure and cmd-parse.c in its release
# tarball, and Neovim is installed as a binary release, so nothing here builds
# from an autotools or CMake source tree.
print_prereq_packages() {
  if is_debian_like; then
    cat <<'EOF2'
Required -- this installer and the tools it installs:

sudo apt-get update && sudo apt-get install -y \
  build-essential \
  ca-certificates \
  curl \
  git \
  jq \
  libevent-dev \
  libncurses-dev \
  openssh-client \
  pkg-config \
  tar \
  util-linux

Optional -- a working dev environment, not needed to bootstrap:

sudo apt-get install -y \
  fd-find \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep \
  shellcheck \
  unzip \
  wget \
  xclip \
  xz-utils
EOF2
  else
    cat <<'EOF2'
Package names vary by distribution.

Required -- this installer and the tools it installs:

  toolchain   C compiler, make, pkg-config    (tmux build; --skip-tmux drops it)
  headers     libevent, ncurses               (tmux build; --skip-tmux drops it)
  downloads   curl, tar, ca-certificates
  tools       git, jq, coreutils, util-linux, openssh client

Optional -- a working dev environment, not needed to bootstrap:

  search      ripgrep, fd
  clipboard   xclip (X11 only)
  python      python3 with pip and venv
  archives    unzip, xz
  linting     shellcheck
  downloads   wget (curl is used when it is absent)
EOF2
  fi
}

# True when a step that clones over GitHub SSH is enabled.
uses_github_ssh() {
  if [ "$SKIP_CORE_DOTFILES" = 0 ] && repo_uses_github_ssh "$DOTFILES_REPO"; then
    return 0
  fi

  if [ "$SKIP_AI_DOTFILES" = 0 ] && repo_uses_github_ssh "$AI_DOTFILES_REPO"; then
    return 0
  fi

  return 1
}

# Commands this script actually runs, narrowed to the steps that are enabled.
# Anything absent from this list is a convenience for the finished environment,
# not a prerequisite for building it, so it must not block the bootstrap.
required_commands() {
  printf '%s\n' git curl tar sed awk

  [ "$SKIP_GO" = 1 ] || printf '%s\n' jq sha256sum
  [ "$SKIP_TMUX" = 1 ] || printf '%s\n' cc make pkg-config
  [ "$SKIP_PI" = 1 ] || printf '%s\n' setsid

  # The Brev installer stages the download in a mktemp directory.
  [ "$SKIP_BREV" = 1 ] || printf '%s\n' mktemp

  # nvm and the Claude, Cursor, and Brev installers are bash scripts.
  if [ "$SKIP_NODE" = 0 ] || [ "$SKIP_CLAUDE" = 0 ] || [ "$SKIP_CURSOR" = 0 ] ||
     [ "$SKIP_BREV" = 0 ]; then
    printf '%s\n' bash
  fi

  if uses_github_ssh; then
    printf '%s\n' ssh-keygen ssh-keyscan
  fi
}

# Wanted in the finished environment but never invoked here, so a missing one is
# reported and then ignored rather than treated as a failure.
optional_commands() {
  printf '%s\n' rg fd xclip shellcheck python3 unzip xz wget
}

# Debian packages fd as "fdfind", so either name satisfies the fd prerequisite.
have_prereq() {
  case "$1" in
    fd)
      have fd || have fdfind
      ;;
    *)
      have "$1"
      ;;
  esac
}

count_words() {
  # shellcheck disable=SC2086
  set -- $1
  printf '%s\n' "$#"
}

# One group of the prerequisite report: a satisfied/total count, the commands
# already present, and the ones still missing.
print_status_group() {
  group=$1
  present=${2# }
  missing=${3# }
  present_count=$(count_words "$present")
  total=$((present_count + $(count_words "$missing")))

  printf '  %s (%s/%s satisfied)\n' "$group" "$present_count" "$total"

  if [ -n "$present" ]; then
    printf '    ok       %s\n' "$present"
  fi

  if [ -n "$missing" ]; then
    printf '    missing  %s\n' "$missing"
  fi
}

# Debian packages fd as "fdfind"; everywhere else it is "fd". Give the Debian
# build the usual name without shadowing a real fd.
link_fd_alias() {
  if have fd; then
    return 0
  fi

  if ! have fdfind; then
    return 0
  fi

  if [ ! -e "$BIN_DIR/fd" ]; then
    ln -sfn "$(command -v fdfind)" "$BIN_DIR/fd"
  fi
}

check_prerequisites() {
  [ "$SKIP_PREREQS" = 0 ] || return 0

  log "Checking prerequisites"

  required_present=
  required_missing=
  for cmd in $(required_commands); do
    if have_prereq "$cmd"; then
      required_present="$required_present $cmd"
    else
      required_missing="$required_missing $cmd"
    fi
  done

  optional_present=
  optional_missing=
  for cmd in $(optional_commands); do
    if have_prereq "$cmd"; then
      optional_present="$optional_present $cmd"
    else
      optional_missing="$optional_missing $cmd"
    fi
  done

  print_status_group "required by this installer" "$required_present" "$required_missing"
  print_status_group "optional dev environment" "$optional_present" "$optional_missing"

  if [ -n "$required_missing" ]; then
    warn "missing required commands:$required_missing"
    cat >&2 <<EOF2

This installer does not run sudo or a package manager for you.
Install the missing prerequisites on $(distro_name), then rerun this script.

EOF2
    print_prereq_packages >&2
    printf '\n' >&2
    die "prerequisites are not satisfied (or rerun with --skip-prereqs to bypass this check)"
  fi

  link_fd_alias
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
  if uses_github_ssh; then
    ensure_github_known_host

    cat <<EOF2

This installer clones GitHub repositories over SSH.
Make sure this VM has an SSH key loaded and that the public key is allowed on GitHub.
EOF2

    if ! prompt_yes_no "Are the GitHub SSH keys installed and ready?"; then
      die "install an SSH key for GitHub, then rerun this script"
    fi
  fi

  if [ "$SKIP_CORE_DOTFILES" = 0 ] && ! git ls-remote "$DOTFILES_REPO" HEAD >/dev/null 2>&1; then
    die "cannot access $DOTFILES_REPO"
  fi

  if [ "$SKIP_AI_DOTFILES" = 0 ] && ! git ls-remote "$AI_DOTFILES_REPO" HEAD >/dev/null 2>&1; then
    die "cannot access $AI_DOTFILES_REPO (rerun with --skip-ai-dotfiles if it does not exist yet)"
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

# Check out one bare dotfiles repo against $HOME. "label" names the repo in log
# messages and keeps its scratch and backup paths from colliding with the other
# repo's.
install_bare_dotfiles() {
  label=$1
  repo=$2
  git_dir=$3

  if [ ! -d "$git_dir" ]; then
    git clone --bare "$repo" "$git_dir"
    # A bare clone leaves remote.origin.fetch unset, so no refs/remotes/origin/*
    # tracking refs exist and "origin/main" is not a valid object name. Configure
    # the refspec and fetch so the tracking refs (and origin/HEAD) materialize.
    git --git-dir="$git_dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git --git-dir="$git_dir" fetch --prune origin
    git --git-dir="$git_dir" remote set-head origin --auto >/dev/null 2>&1 || true
  else
    git --git-dir="$git_dir" fetch --prune origin
  fi

  branch=$(git_default_branch "$git_dir")
  tracked_file_list=$SCRATCH_DIR/$label-dotfiles-tracked-files.txt
  git --git-dir="$git_dir" ls-tree -r --name-only "origin/$branch" > "$tracked_file_list"

  if ! git --git-dir="$git_dir" --work-tree="$HOME" checkout -B "$branch" "origin/$branch"; then
    backup_dir=$HOME/.dotfiles-backup/$label/$(date +%Y%m%d-%H%M%S)
    warn "$label dotfile checkout had conflicts; backing up conflicting paths to $backup_dir"
    mkdir -p "$backup_dir"
    backup_conflicting_dotfiles "$backup_dir" "$tracked_file_list"
    git --git-dir="$git_dir" --work-tree="$HOME" checkout -B "$branch" "origin/$branch"
  fi

  git --git-dir="$git_dir" --work-tree="$HOME" config status.showUntrackedFiles no
}

install_core_dotfiles() {
  [ "$SKIP_CORE_DOTFILES" = 0 ] || return 0

  log "Installing core dotfiles"
  install_bare_dotfiles core "$DOTFILES_REPO" "$DOTFILES_DIR"
}

install_ai_dotfiles() {
  [ "$SKIP_AI_DOTFILES" = 0 ] || return 0

  log "Installing AI dotfiles"
  install_bare_dotfiles ai "$AI_DOTFILES_REPO" "$AI_DOTFILES_DIR"
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
  [ "$SKIP_NODE" = 0 ] || return 0

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

# Put the default Node.js on PATH for steps that need it. Node may have been
# skipped with --skip-node, so a missing nvm is a warning, not a failure: the
# agent CLIs below ship native installers and mostly do not need it.
use_default_node() {
  export NVM_DIR="$HOME/.nvm"

  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    warn "nvm is not installed; continuing without a managed Node.js on PATH"
    return 0
  fi

  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm use default >/dev/null
}

install_global_npm_tools() {
  [ "$SKIP_NPM_TOOLS" = 0 ] || return 0

  log "Installing global npm development tools"
  use_default_node
  have npm || die "npm is not available; rerun without --skip-node"

  npm install -g \
    vite \
    typescript \
    tsx \
    pnpm \
    yarn
}

install_claude() {
  [ "$SKIP_CLAUDE" = 0 ] || return 0

  log "Installing the Claude CLI"
  use_default_node

  download_file "$CLAUDE_INSTALL_URL" "$SCRATCH_DIR/claude-install.sh"
  bash "$SCRATCH_DIR/claude-install.sh"
  symlink_file "$BIN_DIR/claude" \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/local/bin/claude"
}

install_codex() {
  [ "$SKIP_CODEX" = 0 ] || return 0

  log "Installing the Codex CLI"
  use_default_node

  download_file "$CODEX_INSTALL_URL" "$SCRATCH_DIR/codex-install.sh"
  CODEX_NON_INTERACTIVE=true sh "$SCRATCH_DIR/codex-install.sh"
  symlink_file "$BIN_DIR/codex" \
    "$HOME/.local/bin/codex" \
    "$HOME/.codex/bin/codex"
}

install_cursor() {
  [ "$SKIP_CURSOR" = 0 ] || return 0

  log "Installing the Cursor agent CLI"
  use_default_node

  download_file "$CURSOR_INSTALL_URL" "$SCRATCH_DIR/cursor-install.sh"
  bash "$SCRATCH_DIR/cursor-install.sh"
  symlink_file "$BIN_DIR/agent" \
    "$HOME/.local/bin/agent"
  symlink_file "$BIN_DIR/cursor-agent" \
    "$HOME/.local/bin/cursor-agent"
  symlink_file "$BIN_DIR/cursor" \
    "$HOME/.local/bin/cursor-agent" \
    "$HOME/.local/bin/agent"
}

install_pi() {
  [ "$SKIP_PI" = 0 ] || return 0

  log "Installing the pi.dev CLI"
  use_default_node

  download_file "$PI_INSTALL_URL" "$SCRATCH_DIR/pi-install.sh"
  # Pi reads its install confirmation from /dev/tty. Running it without a
  # controlling TTY makes its installer choose the install/reinstall default.
  TERM=dumb setsid sh "$SCRATCH_DIR/pi-install.sh"
  symlink_file "$BIN_DIR/pi" \
    "$HOME/.local/bin/pi" \
    "$HOME/.pi/bin/pi"
}

# NVIDIA Brev. Its installer resolves the latest release through the GitHub API,
# which is rate limited per IP for unauthenticated callers; it picks up
# GITHUB_TOKEN from the environment, or a token from the gh CLI, when either is
# available. It installs to $HOME/.local/bin and never needs sudo -- running it
# with sudo would resolve $HOME to root's home instead.
install_brev() {
  [ "$SKIP_BREV" = 0 ] || return 0

  log "Installing the NVIDIA Brev CLI"

  download_file "$BREV_INSTALL_URL" "$SCRATCH_DIR/brev-install.sh"
  bash "$SCRATCH_DIR/brev-install.sh"
  symlink_file "$BIN_DIR/brev" \
    "$HOME/.local/bin/brev"
}

print_completion_notes() {
  if [ -n "$FAILED_STEPS" ]; then
    cat <<EOF2

Finished with failures.

These steps did not complete:$FAILED_STEPS

Rerun the script to retry them, or rerun with the matching --skip-* flags to
leave them out.
EOF2
  else
    printf '\nDone.\n'
  fi

  cat <<EOF2

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
  # Preflight stays fatal: a non-Linux host, missing prerequisites, or an
  # unusable SSH key makes every step below meaningless.
  require_linux
  ensure_dirs
  check_prerequisites

  if [ "$SKIP_CORE_DOTFILES" = 0 ] || [ "$SKIP_AI_DOTFILES" = 0 ]; then
    require_github_repo_access
  fi

  # Core runs before AI, so the AI repo wins any path both repos track.
  run_step core-dotfiles install_core_dotfiles
  run_step ai-dotfiles install_ai_dotfiles
  run_step tmux install_tmux
  run_step nvim install_nvim
  run_step go install_go
  run_step node install_nvm_node
  ensure_profile_snippet
  run_step npm-tools install_global_npm_tools
  run_step claude install_claude
  run_step codex install_codex
  run_step cursor install_cursor
  run_step pi install_pi
  run_step brev install_brev
  print_completion_notes

  [ -z "$FAILED_STEPS" ] || exit 1
}

main "$@"
