#!/usr/bin/env bash
set -euo pipefail

# claudebox installer — intended for: curl -fsSL .../install.sh | bash
#
# Downloads the claudebox repo tarball, installs the whole tree under
# $DEST, and puts a `box` symlink on PATH via $BINDIR.

REPO="${CLAUDEBOX_REPO:-heavy-duty/claudebox}"
REF="${CLAUDEBOX_REF:-main}"
DEST="${CLAUDEBOX_HOME:-$HOME/.local/share/claudebox}"
BINDIR="${CLAUDEBOX_BIN:-$HOME/.local/bin}"

log() { printf 'claudebox-install: %s\n' "$*"; }
warn() { printf 'claudebox-install: WARNING: %s\n' "$*" >&2; }
die() { printf 'claudebox-install: ERROR: %s\n' "$*" >&2; exit 1; }

# --- prerequisites ---------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl is required but was not found. Please install curl and re-run."
command -v tar  >/dev/null 2>&1 || die "tar is required but was not found. Please install tar and re-run."

# --- temp workspace --------------------------------------------------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"

log "installing box (the claudebox repo) ($REPO@$REF)"
log "downloading $URL"
curl -fsSL "$URL" -o "$TMPDIR/claudebox.tar.gz" \
  || die "failed to download $URL"

log "extracting archive"
tar -xzf "$TMPDIR/claudebox.tar.gz" -C "$TMPDIR" \
  || die "failed to extract archive"

# GitHub archives extract to a single top-level dir like claudebox-<ref>/
EXTRACTED="$(find "$TMPDIR" -maxdepth 1 -type d -name 'claudebox-*' | head -n1)"
[ -n "$EXTRACTED" ] || die "could not find extracted claudebox-* directory in archive"
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

# --- PATH check ------------------------------------------------------------
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *)
    log "note: $BINDIR is not on your PATH."
    log "  add this to your shell rc (e.g. ~/.bashrc or ~/.zshrc):"
    log "      export PATH=\"$BINDIR:\$PATH\""
    ;;
esac

# --- environment check -----------------------------------------------------
if ! command -v incus >/dev/null 2>&1; then
  warn "incus was not found. box needs Incus on the host."
  warn "  run the one-time host setup: $DEST/host/setup-host.sh"
fi

log "done — try: box new --name test"
