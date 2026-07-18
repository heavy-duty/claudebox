#!/usr/bin/env bash
set -euo pipefail

# box installer — intended for: curl -fsSL .../install.sh | bash
#
# Downloads the box source tarball from its GitHub repo (heavy-duty/box),
# installs the whole tree under $DEST, and puts a `box` symlink on PATH via
# $BINDIR. (GitHub redirects the repo's pre-rename URLs, so an old install
# script keeps working; BOX_REPO overrides.)

REPO="${BOX_REPO:-heavy-duty/box}"
REF="${BOX_REF:-main}"
# Root installs GLOBALLY, non-root installs per-user. box's install tree is
# EXECUTED by other users (the multi-user host path: rig installs box once, every
# incus-group operator runs it) — unlike rig, which is root-only and can hide in
# /root. So a root install must land in a system location, not $HOME: /root is
# 0700, so a $HOME/.local tree there is unreadable to everyone else and the whole
# fleet gets 'command not found' (#71). /opt/box is the world-readable system
# tree; /usr/local/bin is already on every login PATH. BOX_HOME/BOX_BIN still win.
if [ "$(id -u)" -eq 0 ]; then
  DEST="${BOX_HOME:-/opt/box}"
  BINDIR="${BOX_BIN:-/usr/local/bin}"
else
  DEST="${BOX_HOME:-$HOME/.local/share/box}"
  BINDIR="${BOX_BIN:-$HOME/.local/bin}"
fi

log() { printf 'box-install: %s\n' "$*"; }
warn() { printf 'box-install: WARNING: %s\n' "$*" >&2; }
die() { printf 'box-install: ERROR: %s\n' "$*" >&2; exit 1; }

# Ask a yes/no question and echo the answer. The wrinkle: under the intended
# 'curl … | bash', THIS SCRIPT is stdin — so a plain 'read' would consume the
# installer's own remaining lines, not the user's keystroke. Prompts therefore
# read the terminal directly via /dev/tty. When there is no terminal at all (CI,
# a pipe with no tty), there is nobody to ask: BOX_YES=1 means "assume yes to
# every prompt" and is how automation and the drill drive this unattended;
# without it we refuse rather than silently assume consent.
confirm() {  # $1 = question
  [ -n "${BOX_YES:-}" ] && return 0
  if ! { true >/dev/tty; } 2>/dev/null; then
    die "no terminal to confirm on. Re-run with BOX_YES=1 to proceed non-interactively (assumes yes to all prompts)."
  fi
  local reply
  printf 'box-install: %s [y/N] ' "$1" >/dev/tty
  read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- prerequisites ---------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl is required but was not found. Please install curl and re-run."
command -v tar  >/dev/null 2>&1 || die "tar is required but was not found. Please install tar and re-run."

# --- confirm, then no-op if already installed ------------------------------
# Prompt BEFORE downloading anything: the first thing a curl|bash should do is
# ask whether you meant to. Then, if box is already installed, this run changes
# nothing and says so — a re-run is a safe no-op, which dissolves the whole
# "curl clobbered my working install / rebuilt the stack under my boxes" class
# of failures. Upgrading is deliberately NOT an in-place overwrite: you uninstall
# what you have (dealing with your boxes as you do) and install fresh.
confirm "Install box from $REPO@$REF?" || die "cancelled — nothing was changed."

if [ -e "$BINDIR/box" ] || [ -x "$DEST/bin/box" ]; then
  cur="$(cat "$DEST/INSTALLED_FROM" 2>/dev/null || echo '<unknown source>')"
  cur_ver="$(cat "$DEST/VERSION" 2>/dev/null || echo '?')"
  log "box is already installed ($cur, version $cur_ver) — nothing to do."
  log "To install a different version, remove the current one first:"
  log "    · preserve any boxes you care about — 'box down <box>', then keep them"
  log "      (a portable 'box export' is #70; for now copy what you need OUT via"
  log "      'box shell'/'box exec'), and 'box rm <box>' when you are done"
  log "    · uninstall:  rm -rf \"$DEST\" \"$BINDIR/box\""
  log "    · then re-run this installer"
  exit 0
fi

# --- temp workspace --------------------------------------------------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"

log "installing box from $REPO@$REF"
log "downloading $URL"
curl -fsSL "$URL" -o "$TMPDIR/box.tar.gz" \
  || die "failed to download $URL"

log "extracting archive"
tar -xzf "$TMPDIR/box.tar.gz" -C "$TMPDIR" \
  || die "failed to extract archive"

# GitHub names the archive's top dir <repo>-<ref> (slashes in a ref become
# dashes) — deriving that name is guesswork, and it broke for real at the
# claudebox → box rename, when this glob kept looking for claudebox-* and the
# installer died on every host. The tarball has exactly ONE top-level
# directory: take the directory, whatever it is called, and let the bin/box
# check below judge whether it is the right tree.
EXTRACTED="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -n "$EXTRACTED" ] || die "could not find the extracted source directory in archive"
[ -f "$EXTRACTED/bin/box" ] || die "archive does not contain bin/box — is $REPO@$REF correct?"

# --- install into $DEST ----------------------------------------------------
# Reached only on a host with no existing install (the no-op check above
# exits otherwise), so this is always a fresh tree, never an overwrite.
log "installing into $DEST"
mkdir -p "$(dirname "$DEST")"
mv "$EXTRACTED" "$DEST"

chmod +x "$DEST/bin/box"

# A global (root) install is run by OTHER users, but mv preserves the tarball's
# root:root ownership and GitHub's archives carry no world bits on some paths — so
# without this, a non-root caller cannot even traverse into $DEST to reach bin/box.
# Root owns the tree, nobody else writes it, everybody reads it. a+rX: read on
# files, +search (x) on directories only. Guarded on root so the per-user install
# stays byte-identical to before.
if [ "$(id -u)" -eq 0 ]; then
  chmod -R a+rX "$DEST"
fi

# --- put box on PATH -------------------------------------------------------
mkdir -p "$BINDIR"
ln -sf "$DEST/bin/box" "$BINDIR/box"
log "linked $BINDIR/box -> $DEST/bin/box"
# 0.4.0 renamed the binary (clean cut): clear a stale claudebox symlink so it
# cannot dangle at the old bin path forever. Old BOXES keep working — the CLI
# honors their legacy tag — it is only the old command name that retires.
if [ -L "$BINDIR/claudebox" ]; then
  rm -f "$BINDIR/claudebox"
  log "removed the old claudebox symlink — the command is 'box' now (your existing boxes keep working)"
fi
# 0.5.0 moved the install tree from ~/.local/share/claudebox to ~/.local/share/box.
# Sweep the old tree so an upgrade does not leave a stale copy behind.
OLD_DEST="$HOME/.local/share/claudebox"
if [ -d "$OLD_DEST" ] && [ "$OLD_DEST" != "$DEST" ]; then
  rm -rf "$OLD_DEST"
  log "removed the old install tree at $OLD_DEST (it now lives at $DEST)"
fi

# --- PATH check ------------------------------------------------------------
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *)
    log "note: $BINDIR is not on your PATH."
    log "  add this to your shell rc (e.g. ~/.bashrc or ~/.zshrc):"
    log "      export PATH=\"$BINDIR:\$PATH\""
    ;;
esac

# Record WHAT was installed, so a caller can assert it got what it asked for.
# Without this, an installer invoked with stale env vars (the CLAUDEBOX_* names
# retired in 0.5.0) silently falls back to the defaults and installs main —
# and the caller drills the wrong tree, believing it drilled its branch.
# Written BEFORE host setup: this records the install, which has now happened,
# and it must not hinge on whether the host stack came up.
printf '%s@%s\n' "$REPO" "$REF" > "$DEST/INSTALLED_FROM"

# --- host setup (second prompt) --------------------------------------------
# The tool is installed; the machine is not yet a box host. Offer to finish the
# job — build Incus and the isolation stack — rather than leave 'box new' to die
# later on a host with no boxnet and no profile (#64). This is its own decision:
# you might be installing the CLI on a workstation and hosting boxes elsewhere.
# BOX_SKIP_SETUP_HOST=1 answers "no" without prompting (image builds, a host set
# up by hand); BOX_YES answers "yes".
setup_ok=""
setup_declined=""
if [ -n "${BOX_SKIP_SETUP_HOST:-}" ]; then
  log "skipping host setup (BOX_SKIP_SETUP_HOST is set)."
  setup_declined=1
elif [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  warn "cannot set up the host: it needs root and sudo was not found."
  warn "  run this as root to finish: $DEST/host/setup-host.sh"
  setup_declined=1
elif confirm "Set up this machine as a box host now? (installs Incus + the isolation stack; needs sudo)"; then
  # </dev/null because under 'curl … | bash' this script IS stdin: a child that
  # reads stdin eats the installer's own remaining lines. sudo is unaffected —
  # it prompts on /dev/tty, so an interactive host can still authenticate.
  # setup-host re-execs itself under sg incus-admin if it must add you to the
  # group; that re-exec is a child here and completes the whole setup in one go.
  if bash "$DEST/host/setup-host.sh" </dev/null; then
    setup_ok=1
  else
    warn "host setup did not complete — box is installed, the host is not ready."
    warn "  fix the error above and re-run: box setup-host"
  fi
else
  log "skipped host setup."
  setup_declined=1
fi

if [ -n "$setup_ok" ]; then
  log "done ($REPO@$REF) — try: box new --name test"
elif [ -n "$setup_declined" ]; then
  log "done ($REPO@$REF) — when you want this machine to host boxes: box setup-host"
else
  log "done ($REPO@$REF) — finish with 'box setup-host', then: box new --name test"
fi
