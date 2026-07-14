#!/usr/bin/env bash
set -euo pipefail

# box installer — intended for: curl -fsSL .../install.sh | bash
#
# Downloads the box source tarball from its GitHub repo (heavy-duty/claudebox —
# the repo keeps the old name; only the tool is 'box'), installs the whole tree
# under $DEST, and puts a `box` symlink on PATH via $BINDIR.

REPO="${BOX_REPO:-heavy-duty/claudebox}"
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

# GitHub names the archive's top dir after the REPO, which is still 'claudebox':
# it extracts to claudebox-<ref>/. That is repo-derived, not a stray brand.
EXTRACTED="$(find "$TMPDIR" -maxdepth 1 -type d -name 'claudebox-*' | head -n1)"
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

# --- environment check -----------------------------------------------------
if ! command -v incus >/dev/null 2>&1; then
  warn "incus was not found. box needs Incus on the host."
  warn "  run the one-time host setup: $DEST/host/setup-host.sh"
fi

log "done — try: box new --name test"
