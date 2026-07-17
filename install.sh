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
DEST="${BOX_HOME:-$HOME/.local/share/box}"
BINDIR="${BOX_BIN:-$HOME/.local/bin}"

log() { printf 'box-install: %s\n' "$*"; }
warn() { printf 'box-install: WARNING: %s\n' "$*" >&2; }
die() { printf 'box-install: ERROR: %s\n' "$*" >&2; exit 1; }

# --- prerequisites ---------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl is required but was not found. Please install curl and re-run."
command -v tar  >/dev/null 2>&1 || die "tar is required but was not found. Please install tar and re-run."

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

# --- atomically replace $DEST ---------------------------------------------
log "installing into $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$EXTRACTED" "$DEST"

chmod +x "$DEST/bin/box"

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

# --- host setup ------------------------------------------------------------
# The installer finishes the job (#64). Telling the user to go run setup-host
# was a step that read as optional and failed later as mysterious: the install
# reports success, 'box' is on PATH, and 'box new' dies on a host with no
# Incus, no boxnet, no profile. setup-host is idempotent by design, so doing
# this on EVERY install is also how an upgraded host picks up stack changes —
# the isolation fixes that ship as new firewall rules land when the tool that
# claims them lands, instead of waiting on someone to re-run a command.
# BOX_SKIP_SETUP_HOST=1 opts out: CI, image builds, a host set up by hand.
setup_ok=""
if [ -n "${BOX_SKIP_SETUP_HOST:-}" ]; then
  log "skipping host setup (BOX_SKIP_SETUP_HOST is set) — run it yourself: box setup-host"
elif [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  warn "host setup needs root and sudo was not found."
  warn "  run this as root to finish: $DEST/host/setup-host.sh"
else
  log "running one-time host setup (installs Incus + the isolation stack; may ask for sudo)"
  # </dev/null because under 'curl … | bash' this script IS stdin: a child that
  # reads stdin eats the installer's own remaining lines. sudo is unaffected —
  # it prompts on /dev/tty, so an interactive host can still authenticate.
  if bash "$DEST/host/setup-host.sh" </dev/null; then
    setup_ok=1
  else
    warn "host setup did not complete — box is installed, the host is not ready."
    warn "  fix the error above and re-run: box setup-host"
  fi
fi

if [ -n "$setup_ok" ]; then
  log "done ($REPO@$REF) — try: box new --name test"
else
  log "done ($REPO@$REF) — finish with 'box setup-host', then: box new --name test"
fi
