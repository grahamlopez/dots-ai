#!/usr/bin/env bash
# Overview and bash guard {{{
#
# Requires bash: the step registry uses associative arrays. When piped from
# curl there is no file to re-exec, so fail loudly rather than let a later
# array literal produce a confusing syntax error.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: this installer requires bash, not sh." >&2
  echo "  curl -fsSL <url> | bash" >&2
  echo "  bash build-agent-env.sh" >&2
  exit 1
fi
set -euo pipefail

# Bootstrap a complete agentic development environment on Linux.
#
# Intended use:
#   curl -fsSL https://raw.githubusercontent.com/grahamlopez/dots-ai/main/.utils-ai/build-agent-env.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/grahamlopez/dots-ai/main/.utils-ai/build-agent-env.sh | bash -s -- --yes
#
# The first form opens the wizard: piping the script into bash makes stdin the
# script itself, so every prompt reads and writes /dev/tty instead. The second
# form takes everything without asking.
#
# Useful overrides:
#   DOTFILES_REPO=git@github.com:grahamlopez/dots \
#   AI_DOTFILES_REPO=git@github.com:grahamlopez/dots-ai \
#   INSTALL_ROOT="$HOME/local" \
#   GO_VERSION=go1.26.4 \
#   bash build-agent-env.sh
#
# With no arguments and a terminal attached, an interactive wizard asks what to
# install, showing what is already present. Passing any step selection flag, or
# --yes, runs non-interactively; without a terminal it installs everything, as
# it always has. A step that fails is reported at the end rather than aborting
# the run.
#
# Steps are described once in the step registry below; main, --help, the flag
# parser, the prerequisite check, and the wizard are all generated from it.
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

# }}}

# Configuration and defaults {{{
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
RUN_WIZARD=auto
SELECTION_EXPLICIT=0
LIST_STEPS_ONLY=0
PENDING_ONLY=
PENDING_SKIP=

# }}}

# Step registry {{{
# The step registry. Everything that installs something is described here once;
# main, usage, the flag parser, the prerequisite check, and the wizard are all
# driven from it, so adding a step means adding one row rather than touching
# five places.
STEP_ORDER=(
  core-dotfiles
  ai-dotfiles
  tmux
  nvim
  go
  node
  npm-tools
  claude
  codex
  cursor
  pi
  brev
)

declare -A STEP_LABEL=(
  [core-dotfiles]="Core dotfiles"
  [ai-dotfiles]="AI dotfiles"
  [tmux]="tmux (built from source)"
  [nvim]="Neovim"
  [go]="Go toolchain"
  [node]="nvm, Node.js, and npm"
  [npm-tools]="Global npm dev tools"
  [claude]="Claude CLI"
  [codex]="Codex CLI"
  [cursor]="Cursor agent CLI"
  [pi]="pi.dev CLI"
  [brev]="NVIDIA Brev CLI"
)

declare -A STEP_FN=(
  [core-dotfiles]=install_core_dotfiles
  [ai-dotfiles]=install_ai_dotfiles
  [tmux]=install_tmux
  [nvim]=install_nvim
  [go]=install_go
  [node]=install_nvm_node
  [npm-tools]=install_global_npm_tools
  [claude]=install_claude
  [codex]=install_codex
  [cursor]=install_cursor
  [pi]=install_pi
  [brev]=install_brev
)

# Steps that cannot run without another step's result.
declare -A STEP_NEEDS=(
  [npm-tools]="node"
)

# Command that proves a step is already installed, and how to ask its version.
declare -A STEP_PROBE=(
  [tmux]="tmux -V"
  [nvim]="nvim --version"
  [go]="go version"
  [node]="node --version"
  [npm-tools]="tsc --version"
  [claude]="claude --version"
  [codex]="codex --version"
  [cursor]="cursor-agent --version"
  [pi]="pi --version"
  [brev]="brev --version"
)

# Detected state of each step, filled in by detect_step_status.
declare -A STEP_STATUS=()

# Selection state: 1 = install, 0 = skip. Everything is on by default.
declare -A STEP_ON=()
for _step in "${STEP_ORDER[@]}"; do STEP_ON[$_step]=1; done
unset _step

# }}}

# Step selection and run state {{{
step_exists() {
  [[ -n "${STEP_LABEL[$1]:-}" ]]
}

step_on() {
  [[ "${STEP_ON[$1]}" = 1 ]]
}

set_step() {
  STEP_ON[$1]=$2
}

# Mark that the command line chose steps, which suppresses the wizard.
set_step_explicit() {
  set_step "$1" "$2"
  SELECTION_EXPLICIT=1
}

# Steps that failed without stopping the run. Reported by print_completion_notes.
FAILED_STEPS=

# }}}

# Command line: usage, flags, parsing {{{
usage() {
  cat <<'USAGE'
Usage: build-agent-env.sh [options]

With no options and a terminal attached, an interactive wizard asks what to
install. Passing any step selection flag, or --yes, runs non-interactively.

Options:
  -y, --yes             Install everything without asking.
  --wizard              Force the wizard on, seeded with any flags given.
  --no-wizard           Never ask; use the defaults and flags as given.
  --only a,b,c          Install only these steps.
  --skip a,b,c          Install everything except these steps.
  --skip-<step>         Skip one step; see --list for the names.
  --skip-dotfiles       Skip both dotfiles steps.
  --skip-ai-tools       Skip claude, codex, cursor, and pi (not brev).
  --skip-prereqs        Do not check for prerequisite commands.
  --list                List the step names and exit.
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

list_steps() {
  printf 'Steps, in the order they run:\n\n'
  local step
  for step in "${STEP_ORDER[@]}"; do
    printf '  %-14s %s\n' "$step" "${STEP_LABEL[$step]}"
  done
}

# Validate a comma or space separated step list. Returns non-zero rather than
# calling exit, so the caller can exit from the current shell -- an exit inside
# a command or process substitution would only end the subshell and let the run
# continue with an empty selection.
validate_step_list() {
  local list=$1 step
  for step in ${list//,/ }; do
    if ! step_exists "$step"; then
      echo "error: unknown step: $step" >&2
      echo "Run --list to see the step names." >&2
      return 2
    fi
  done
  return 0
}

# Turn the flags the parser collected into selection state. Runs after the
# function definitions, which is why the parser only records them.
apply_pending_selection() {
  local step

  validate_step_list "$PENDING_ONLY" || exit 2
  validate_step_list "$PENDING_SKIP" || exit 2

  if [ -n "$PENDING_ONLY" ]; then
    for step in "${STEP_ORDER[@]}"; do
      set_step "$step" 0
    done
    for step in ${PENDING_ONLY//,/ }; do
      set_step "$step" 1
    done
    SELECTION_EXPLICIT=1
  fi

  if [ -n "$PENDING_SKIP" ]; then
    for step in ${PENDING_SKIP//,/ }; do
      set_step "$step" 0
    done
    SELECTION_EXPLICIT=1
  fi
}


while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      RUN_WIZARD=off
      ;;
    --wizard)
      RUN_WIZARD=on
      ;;
    --no-wizard)
      RUN_WIZARD=off
      ;;
    --list)
      LIST_STEPS_ONLY=1
      ;;
    --only)
      [ "$#" -ge 2 ] || { echo "--only needs a list" >&2; exit 2; }
      PENDING_ONLY=$2
      shift
      ;;
    --only=*)
      PENDING_ONLY=${1#*=}
      ;;
    --skip)
      [ "$#" -ge 2 ] || { echo "--skip needs a list" >&2; exit 2; }
      PENDING_SKIP="${PENDING_SKIP:-},$2"
      shift
      ;;
    --skip=*)
      PENDING_SKIP="${PENDING_SKIP:-},${1#*=}"
      ;;
    --skip-prereqs)
      SKIP_PREREQS=1
      ;;
    --skip-dotfiles)
      PENDING_SKIP="${PENDING_SKIP:-},core-dotfiles,ai-dotfiles"
      ;;
    --skip-ai-tools)
      PENDING_SKIP="${PENDING_SKIP:-},claude,codex,cursor,pi"
      ;;
    --skip-*)
      PENDING_SKIP="${PENDING_SKIP:-},${1#--skip-}"
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

# }}}

# Logging and process helpers {{{
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

  if ! tty_available; then
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

# }}}

# Platform detection {{{
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

# }}}

# Directories, symlinks, shell profile {{{
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

# }}}

# Prerequisites {{{
# Prerequisite packages, split by who needs them.
#
# Required covers this installer plus the tools it installs: the tmux build
# needs a toolchain and the libevent/ncurses headers, and that same toolchain is
# what nvim-treesitter uses to compile parsers, what node-gyp uses for native npm
# modules, and what cgo uses. Optional is the dev-box set -- nothing in the
# bootstrap calls any of it, though the dotfiles' Claude statusline uses bc for
# float math once it is in place.
#
# bison is required even though tmux ships a pre-generated cmd-parse.c: its
# configure runs AC_CHECK_PROG on $YACC and hard-errors with "yacc not found"
# before it ever gets to the build, so the pre-generated parser does not save
# us. byacc or any other yacc satisfies the check equally well.
#
# Deliberately absent from both: autoconf, automake, cmake, gettext, and ninja.
# tmux ships a pre-generated configure in its release tarball, and Neovim is
# installed as a binary release, so nothing here builds from an autotools or
# CMake source tree.
#
# Prints one section, or both. "required" and "optional" are used on their own
# when only that half of the report is actionable; with no argument both print,
# separated by a blank line.
print_prereq_packages() {
  want_required=1
  want_optional=1
  case ${1:-all} in
    required) want_optional=0 ;;
    optional) want_required=0 ;;
  esac

  # apt-get update belongs to whichever command comes first in the output.
  apt_optional_prefix='sudo apt-get install -y'
  if [ "$want_required" = 0 ]; then
    apt_optional_prefix='sudo apt-get update && sudo apt-get install -y'
  fi

  is_debian_like || printf 'Package names vary by distribution.\n\n'

  if [ "$want_required" = 1 ]; then
    if is_debian_like; then
      cat <<'EOF2'
Required -- this installer and the tools it installs:

sudo apt-get update && sudo apt-get install -y \
  bison \
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
EOF2
    else
      cat <<'EOF2'
Required -- this installer and the tools it installs:

  toolchain   C compiler, make, pkg-config    (tmux build; --skip-tmux drops it)
  parser      bison or byacc                  (tmux build; --skip-tmux drops it)
  headers     libevent, ncurses               (tmux build; --skip-tmux drops it)
  downloads   curl, tar, ca-certificates
  tools       git, jq, coreutils, util-linux, openssh client
EOF2
    fi
  fi

  if [ "$want_required" = 1 ] && [ "$want_optional" = 1 ]; then
    printf '\n'
  fi

  if [ "$want_optional" = 1 ]; then
    if is_debian_like; then
      cat <<EOF2
Optional -- a working dev environment, not needed to bootstrap:

$apt_optional_prefix \\
  bc \\
  fd-find \\
  python3 \\
  python3-pip \\
  python3-venv \\
  ripgrep \\
  shellcheck \\
  unzip \\
  wget \\
  xclip \\
  xz-utils
EOF2
    else
      cat <<'EOF2'
Optional -- a working dev environment, not needed to bootstrap:

  search      ripgrep, fd
  clipboard   xclip (X11 only)
  python      python3 with pip and venv
  archives    unzip, xz
  linting     shellcheck
  statusline  bc (Claude Code statusline)
  downloads   wget (curl is used when it is absent)
EOF2
    fi
  fi
}

# Commands this script actually runs, narrowed to the steps that are enabled.
# Anything absent from this list is a convenience for the finished environment,
# not a prerequisite for building it, so it must not block the bootstrap.
required_commands() {
  printf '%s\n' git curl tar sed awk

  if step_on go; then
    printf '%s\n' jq sha256sum
  fi

  if step_on tmux; then
    printf '%s\n' cc make pkg-config yacc
  fi

  if step_on pi; then
    printf '%s\n' setsid
  fi

  # The Brev installer stages the download in a mktemp directory.
  if step_on brev; then
    printf '%s\n' mktemp
  fi

  # nvm and the Claude, Cursor, and Brev installers are bash scripts.
  if step_on node || step_on claude || step_on cursor || step_on brev; then
    printf '%s\n' bash
  fi

  if uses_github_ssh; then
    printf '%s\n' ssh-keygen ssh-keyscan
  fi
}

# Wanted in the finished environment but never invoked here, so a missing one is
# reported and then ignored rather than treated as a failure.
optional_commands() {
  printf '%s\n' rg fd xclip shellcheck python3 unzip xz wget bc
}

# Debian packages fd as "fdfind", so either name satisfies the fd prerequisite.
# tmux's configure accepts any yacc, and not every distribution installs the
# generic "yacc" name alongside bison, so accept the implementations directly.
have_prereq() {
  case "$1" in
    fd)
      have fd || have fdfind
      ;;
    yacc)
      have yacc || have bison || have byacc
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

  # Nothing here blocks the run, but the install command is only useful if it is
  # printed, so show it whenever something optional is absent.
  if [ -n "$optional_missing" ]; then
    cat <<EOF2

The optional commands are not needed to bootstrap, so the installer continues
without them. To fill them in on $(distro_name):

EOF2
    print_prereq_packages optional
    printf '\n'
  fi

  link_fd_alias
}

# }}}

# GitHub access {{{
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

# True when a step that clones over GitHub SSH is enabled.
uses_github_ssh() {
  if step_on core-dotfiles && repo_uses_github_ssh "$DOTFILES_REPO"; then
    return 0
  fi

  if step_on ai-dotfiles && repo_uses_github_ssh "$AI_DOTFILES_REPO"; then
    return 0
  fi

  return 1
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

  if step_on core-dotfiles && ! git ls-remote "$DOTFILES_REPO" HEAD >/dev/null 2>&1; then
    die "cannot access $DOTFILES_REPO"
  fi

  if step_on ai-dotfiles && ! git ls-remote "$AI_DOTFILES_REPO" HEAD >/dev/null 2>&1; then
    die "cannot access $AI_DOTFILES_REPO (rerun with --skip-ai-dotfiles if it does not exist yet)"
  fi
}

# }}}

# Dotfiles {{{
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
  log "Installing core dotfiles"
  install_bare_dotfiles core "$DOTFILES_REPO" "$DOTFILES_DIR"
}

install_ai_dotfiles() {
  log "Installing AI dotfiles"
  install_bare_dotfiles ai "$AI_DOTFILES_REPO" "$AI_DOTFILES_DIR"
}

# }}}

# Download and build helpers {{{
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

# }}}

# Install steps {{{

# tmux {{{
install_tmux() {
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

# }}}

# Neovim {{{
install_nvim() {
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

# }}}

# Go {{{
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

# }}}

# Node and npm {{{
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

# }}}

# Agent CLIs {{{
install_claude() {
  log "Installing the Claude CLI"
  use_default_node

  download_file "$CLAUDE_INSTALL_URL" "$SCRATCH_DIR/claude-install.sh"
  bash "$SCRATCH_DIR/claude-install.sh"
  symlink_file "$BIN_DIR/claude" \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/local/bin/claude"
}

install_codex() {
  log "Installing the Codex CLI"
  use_default_node

  download_file "$CODEX_INSTALL_URL" "$SCRATCH_DIR/codex-install.sh"
  CODEX_NON_INTERACTIVE=true sh "$SCRATCH_DIR/codex-install.sh"
  symlink_file "$BIN_DIR/codex" \
    "$HOME/.local/bin/codex" \
    "$HOME/.codex/bin/codex"
}

install_cursor() {
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
  log "Installing the NVIDIA Brev CLI"

  download_file "$BREV_INSTALL_URL" "$SCRATCH_DIR/brev-install.sh"
  bash "$SCRATCH_DIR/brev-install.sh"
  symlink_file "$BIN_DIR/brev" \
    "$HOME/.local/bin/brev"
}

# }}}

# }}}

# Completion notes {{{
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

# }}}

# Installed-state detection {{{
# node and the global npm tools live under nvm, which is not on PATH until it is
# sourced, so look for the binary directly rather than using command -v.
nvm_bin() {
  local match
  for match in "$HOME"/.nvm/versions/node/*/bin/"$1"; do
    if [ -x "$match" ]; then
      printf '%s' "$match"
      return 0
    fi
  done
  return 1
}

# Run a version probe defensively: a third-party CLI can be slow or hang, and
# this runs before anything is installed.
probe_version() {
  local out=
  if have timeout; then
    out=$(timeout 3 $1 2>/dev/null | head -n1) || out=
  else
    out=$($1 2>/dev/null | head -n1) || out=
  fi
  # "go version go1.26.6 linux/amd64" is mostly noise in a status column.
  out=${out#go version }
  printf '%s' "${out:0:34}"
}

# A short description of what is already present for one step. Always succeeds;
# "-" means nothing found.
step_status() {
  local step=$1 probe cmd bin out

  case "$step" in
    core-dotfiles)
      if [ -d "$DOTFILES_DIR" ]; then printf 'cloned'; else printf -- '-'; fi
      return 0
      ;;
    ai-dotfiles)
      if [ -d "$AI_DOTFILES_DIR" ]; then printf 'cloned'; else printf -- '-'; fi
      return 0
      ;;
    node)
      if bin=$(nvm_bin node); then
        out=$(probe_version "$bin --version")
        if [ -n "$out" ]; then printf '%s' "$out"; else printf 'installed'; fi
      elif [ -s "$HOME/.nvm/nvm.sh" ]; then
        printf 'nvm only'
      else
        printf -- '-'
      fi
      return 0
      ;;
    npm-tools)
      if nvm_bin tsc >/dev/null; then printf 'installed'; else printf -- '-'; fi
      return 0
      ;;
  esac

  probe=${STEP_PROBE[$step]:-}
  if [ -z "$probe" ]; then
    printf -- '-'
    return 0
  fi

  cmd=${probe%% *}
  if ! have "$cmd"; then
    printf -- '-'
    return 0
  fi

  out=$(probe_version "$probe")
  if [ -n "$out" ]; then printf '%s' "$out"; else printf 'installed'; fi
  return 0
}

step_missing() {
  [ "${STEP_STATUS[$1]:--}" = "-" ]
}

detect_step_status() {
  local step
  for step in "${STEP_ORDER[@]}"; do
    STEP_STATUS[$step]=$(step_status "$step")
  done
}

# }}}

# Wizard {{{
# Test by opening /dev/tty, not with -r/-w: the permission test can pass on a
# /dev/tty that cannot actually be opened.
tty_available() {
  { : >/dev/tty; } 2>/dev/null
}

tty_say() {
  printf '%s\n' "$*" > /dev/tty
}

tty_ask() {
  printf '%s' "$1" > /dev/tty
}

wizard_should_run() {
  case "$RUN_WIZARD" in
    on)
      tty_available && return 0
      warn "--wizard was given but no terminal is available"
      return 1
      ;;
    off)
      return 1
      ;;
  esac

  [ "$SELECTION_EXPLICIT" = 0 ] || return 1
  tty_available
}

select_all() {
  local step
  for step in "${STEP_ORDER[@]}"; do
    set_step "$step" "$1"
  done
}

select_only() {
  local step
  select_all 0
  for step in "$@"; do
    set_step "$step" 1
  done
}

select_missing() {
  local step
  for step in "${STEP_ORDER[@]}"; do
    if step_missing "$step"; then set_step "$step" 1; else set_step "$step" 0; fi
  done
}

wizard_render() {
  local step i=0 mark

  tty_say ""
  printf '   %2s  %-3s %-26s %s\n' "#" "" "step" "already installed" > /dev/tty
  tty_say "  ----------------------------------------------------------------"
  for step in "${STEP_ORDER[@]}"; do
    i=$((i + 1))
    if step_on "$step"; then mark="x"; else mark=" "; fi
    printf '   %2d  [%s] %-26s %s\n' \
      "$i" "$mark" "${STEP_LABEL[$step]}" "${STEP_STATUS[$step]:--}" > /dev/tty
  done
}

wizard_toggle_index() {
  local i=$1 step
  if [ "$i" -lt 1 ] || [ "$i" -gt "${#STEP_ORDER[@]}" ]; then
    tty_say "  no such number: $i"
    return 0
  fi
  step=${STEP_ORDER[$((i - 1))]}
  if step_on "$step"; then set_step "$step" 0; else set_step "$step" 1; fi
}

wizard_toggle_tokens() {
  local tok lo hi i
  for tok in ${1//,/ }; do
    case "$tok" in
      [0-9]*-[0-9]*)
        lo=${tok%%-*}
        hi=${tok##*-}
        for ((i = lo; i <= hi; i++)); do
          wizard_toggle_index "$i"
        done
        ;;
      [0-9]*)
        wizard_toggle_index "$tok"
        ;;
      *)
        tty_say "  did not understand: $tok"
        ;;
    esac
  done
}

wizard_custom() {
  local input

  while true; do
    wizard_render
    tty_say ""
    tty_say "  numbers toggle a line (3, or 3 5, or 3-6)"
    tty_say "  a all   n none   m only what is missing   d done   q quit"
    tty_ask "  > "
    IFS= read -r input < /dev/tty || input=d

    case "$input" in
      d|"") return 0 ;;
      q) die "cancelled" ;;
      a) select_all 1 ;;
      n) select_all 0 ;;
      m) select_missing ;;
      *) wizard_toggle_tokens "$input" ;;
    esac
  done
}

wizard_presets() {
  local choice

  tty_say ""
  tty_say "  1) Everything"
  tty_say "  2) Only what is missing"
  tty_say "  3) Dotfiles, tmux, and Neovim"
  tty_say "  4) Agent CLIs only"
  tty_say "  5) Choose individually"
  tty_ask "  Choose [1]: "
  IFS= read -r choice < /dev/tty || choice=1

  case "${choice:-1}" in
    1) select_all 1 ;;
    2) select_missing ;;
    3) select_only core-dotfiles ai-dotfiles tmux nvim ;;
    4) select_only claude codex cursor pi brev ;;
    5) wizard_custom ;;
    *)
      tty_say "  not one of the choices; taking everything"
      select_all 1
      ;;
  esac
}

wizard_confirm() {
  local answer chosen

  resolve_step_deps
  chosen=$(selected_steps | tr '\n' ' ')

  tty_say ""
  if [ -z "${chosen// /}" ]; then
    tty_say "  Nothing selected."
  else
    tty_say "  Will install:$chosen"
  fi
  tty_ask "  Proceed? [Y/n] "
  IFS= read -r answer < /dev/tty || answer=y

  case "$answer" in
    n|N|no|NO|No) return 1 ;;
    *) return 0 ;;
  esac
}

run_wizard() {
  log "What should be installed?"
  tty_say "  checking what is already present..."
  detect_step_status

  while true; do
    wizard_presets
    if wizard_confirm; then
      return 0
    fi
    wizard_custom
    if wizard_confirm; then
      return 0
    fi
  done
}

# }}}

# Dependency resolution and main {{{
# Turn on anything a selected step depends on. Loops until stable so a chain of
# dependencies resolves.
resolve_step_deps() {
  local step need changed=1

  while [ "$changed" = 1 ]; do
    changed=0
    for step in "${STEP_ORDER[@]}"; do
      step_on "$step" || continue
      for need in ${STEP_NEEDS[$step]:-}; do
        if ! step_on "$need"; then
          set_step "$need" 1
          warn "enabling '$need', which '$step' needs"
          changed=1
        fi
      done
    done
  done
}

selected_steps() {
  local step
  for step in "${STEP_ORDER[@]}"; do
    step_on "$step" && printf '%s\n' "$step"
  done
  return 0
}

main() {
  apply_pending_selection

  if [ "$LIST_STEPS_ONLY" = 1 ]; then
    list_steps
    exit 0
  fi

  # Preflight stays fatal: a non-Linux host, missing prerequisites, or an
  # unusable SSH key makes every step below meaningless.
  require_linux
  ensure_dirs

  if wizard_should_run; then
    run_wizard
  elif [ "$SELECTION_EXPLICIT" = 0 ] && [ "$ASSUME_YES" = 0 ] && [ "$RUN_WIZARD" != off ]; then
    warn "no terminal available; installing everything (use --only/--skip, or --yes to silence this)"
  fi

  resolve_step_deps
  check_prerequisites

  if step_on core-dotfiles || step_on ai-dotfiles; then
    require_github_repo_access
  fi

  # Core dotfiles run before AI dotfiles, so the AI repo wins any path both
  # repos track.
  local step
  for step in "${STEP_ORDER[@]}"; do
    if step_on "$step"; then
      run_step "$step" "${STEP_FN[$step]}"
    fi
  done

  ensure_profile_snippet
  print_completion_notes

  [ -z "$FAILED_STEPS" ] || exit 1
}

main "$@"

# }}}

# vim: set foldmethod=marker foldlevel=0:
