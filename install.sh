#!/usr/bin/env bash
set -euo pipefail

# box installer — intended for: curl -fsSL .../install.sh | bash
#
# Downloads the box source tarball from its GitHub repo (heavy-duty/box) and
# installs it into the VERSIONED layout under $DEST:
#
#   $DEST/versions/<version>/    one full tree per installed version
#   $DEST/current -> versions/<version>       the default version
#   $BINDIR/box   -> $DEST/current/bin/box    the PATH entry
#
# Versions install side by side, the way plenty of CLIs manage theirs: `box
# versions` lists them, `box use <v>` switches the default, `box uninstall`
# removes them. Re-running with an already-installed version is a converging
# no-op (BOX_REINSTALL=1 replaces that version's tree); a NEW version installs
# beside the old one and becomes the default only when NO boxes exist — #66's
# stance (never change versions under a user's boxes) now guards the FLIP, not
# the whole install. A pre-0.7.0 flat tree is migrated in place, so upgrading
# from 0.6.0 is seamless. (GitHub redirects the repo's pre-rename URLs, so an
# old install script keeps working; BOX_REPO overrides.)
#
# BOX_INSTALL_SOURCE=<dir-or-tarball> installs from a local tree instead of
# downloading — for CI and the drill, so what lands is the code under review.

REPO="${BOX_REPO:-heavy-duty/box}"
# Three install channels, one knob (#83): BOX_REF unset installs the LATEST
# RELEASE (the tag resolved from GitHub's releases/latest redirect, below);
# BOX_REF=<tag> pins a release; BOX_REF=<branch> (say, main) is the dev
# channel. A set ref is tried as a tag first, then as a branch.
REF="${BOX_REF:-}"
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

# A version is a DIRECTORY NAME under versions/ — nothing else. One strict
# gate for every caller that builds a path from one (the installer's new_ver,
# migration's flat_ver, and bin/box's 'use'/single-version uninstall): only
# [A-Za-z0-9._+-], no leading '.' or '-'. That forbids '/', '..'-escapes,
# spaces and option-lookalikes by construction — a crafted version dies HERE,
# never in an rm -rf or an ln. bin/box carries a byte-identical copy;
# test/cli.sh diffs the two so the gates cannot drift.
valid_version() {
  case "$1" in
    ''|.*|-*) return 1 ;;
    *[!A-Za-z0-9._+-]*) return 1 ;;
  esac
  return 0
}

# Which boxes exist on this host, at THIS caller's tier? Prints their names
# (both tag generations) and succeeds when at least one exists; fails when
# none are visible — including when incus is absent or not answering, because
# #66's stance protects BOXES from a version change, and a daemon that cannot
# answer has none to protect. bin/box carries a byte-identical copy (the CLI
# needs the same gate for 'box use' / 'box uninstall'); test/cli.sh diffs the
# two so they cannot drift.
existing_boxes() {
  command -v incus >/dev/null 2>&1 || return 1
  { timeout 10 incus list user.box=1 --format csv --columns n </dev/null
    timeout 10 incus list user.claudebox=1 --format csv --columns n </dev/null
  } 2>/dev/null | awk -F, 'NF && !seen[$1]++ { print $1 }' | grep .
}

# The latest release, resolved the no-API way (#83): GitHub answers
# https://github.com/<repo>/releases/latest with a redirect to
# .../releases/tag/<tag>, so one HEAD request reads the tag off the Location
# header — no API, no token, no rate-limit pain. Prints the bare tag; fails
# when the redirect does not answer or does not name a tag (a repo with no
# releases redirects to /releases), so the caller can refuse LOUDLY instead
# of silently installing main. test/release.sh drives this against a shim
# curl serving canned redirects.
latest_release_tag() {
  local loc
  loc="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "https://github.com/$REPO/releases/latest")" || return 1
  case "$loc" in
    */releases/tag/?*) printf '%s\n' "${loc##*/releases/tag/}" ;;
    *) return 1 ;;
  esac
}

# --- prerequisites ---------------------------------------------------------
# curl only when something must be downloaded — a local BOX_INSTALL_SOURCE
# needs none, which is what lets test/cli.sh drive REAL installs offline.
if [ -z "${BOX_INSTALL_SOURCE:-}" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required but was not found. Please install curl and re-run."
fi
command -v tar  >/dev/null 2>&1 || die "tar is required but was not found. Please install tar and re-run."

if [ -n "${BOX_INSTALL_SOURCE:-}" ]; then
  SRCDESC="local source $BOX_INSTALL_SOURCE"
else
  SRCDESC="$REPO@${REF:-latest release}"
fi

# --- confirm first ---------------------------------------------------------
# Prompt BEFORE downloading anything: the first thing a curl|bash should do is
# ask whether you meant to. Everything after this converges: re-running with a
# version that is already installed changes nothing and says so, which
# dissolves the whole "curl clobbered my working install / rebuilt the stack
# under my boxes" class of failures (#66).
confirm "Install box from $SRCDESC?" || die "cancelled — nothing was changed."

# Flip $DEST/current to versions/<v> atomically: build the new link beside it,
# rename over. Plain ln -sfn is unlink+create — a window where current names
# nothing and a concurrent 'box' invocation dies mid-chain. bin/box's cmd_use
# flips with the same pattern.
flip_current() {
  ln -sfn "versions/$1" "$DEST/current.new.$$"
  mv -Tf "$DEST/current.new.$$" "$DEST/current"
}

# --- migrate a pre-0.7.0 flat install --------------------------------------
# 0.6.0 and earlier installed the tree FLAT at $DEST (bin/box directly under
# it). Move such a tree to versions/<its-VERSION> BEFORE anything else, so an
# upgrade from 0.6.0 is seamless and the version comparison below sees the
# truth. The move is two renames inside one parent directory — no copying, no
# window with no install — and the operator's tree is preserved bit for bit.
if [ -e "$DEST/bin/box" ] && [ ! -d "$DEST/versions" ]; then
  flat_ver="$(cat "$DEST/VERSION" 2>/dev/null || echo 0.0.0-unknown)"
  # The flat tree's VERSION is data from disk, not from this installer — the
  # same trust boundary as the new_ver check, so the same gate: a corrupted
  # (or hostile) VERSION must not steer the mv/ln below out of versions/.
  valid_version "$flat_ver" || die "the flat install's VERSION is not a sane directory name: '$flat_ver' — fix $DEST/VERSION (one line, e.g. 0.6.0), then re-run"
  log "found a pre-0.7.0 flat install at $DEST (version $flat_ver) — migrating it into the versioned layout"
  staging="$DEST.migrating.$$"
  mv "$DEST" "$staging"
  mkdir -p "$DEST/versions"
  mv "$staging" "$DEST/versions/$flat_ver"
  flip_current "$flat_ver"
  mkdir -p "$BINDIR"
  ln -sfn "$DEST/current/bin/box" "$BINDIR/box"
  log "migrated: it now lives at $DEST/versions/$flat_ver (still current; your boxes are untouched)"
fi

# Whether ANY version was installed before this run — read before we add one.
# It gates the host-setup offer below: a host that already ran box has made
# that decision (and may have live boxes the stack must not be rebuilt under,
# #66); after an upgrade, 'box setup-host' re-applies stack changes on purpose.
had_install=0
if [ -d "$DEST/versions" ] && [ -n "$(ls -A "$DEST/versions" 2>/dev/null)" ]; then
  had_install=1
fi

# --- temp workspace --------------------------------------------------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- acquire the tree ------------------------------------------------------
if [ -n "${BOX_INSTALL_SOURCE:-}" ]; then
  SRC="$BOX_INSTALL_SOURCE"
  INSTALLED_FROM="local:$SRC"
  if [ -d "$SRC" ]; then
    log "copying local tree $SRC"
    mkdir -p "$TMPDIR/tree"
    # tar, not cp -a: --exclude=.git, so a working checkout never carries its
    # VCS state (or its size) into the install tree.
    tar -C "$SRC" --exclude=.git -cf - . | tar -xf - -C "$TMPDIR/tree"
    EXTRACTED="$TMPDIR/tree"
  elif [ -f "$SRC" ]; then
    log "extracting local tarball $SRC"
    tar -xzf "$SRC" -C "$TMPDIR" || die "failed to extract $SRC"
    EXTRACTED="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  else
    die "BOX_INSTALL_SOURCE is set but is neither a directory nor a tarball: $SRC"
  fi
else
  # No BOX_REF → the latest release, resolved only now (AFTER the confirm:
  # even a redirect probe is network the operator has not yet said yes to).
  # A failed resolution REFUSES with the way out — it must never hang, and
  # never silently hand out main when the operator asked for a release (#83).
  if [ -z "$REF" ]; then
    REF="$(latest_release_tag)" \
      || die "could not resolve the latest release (no release tag behind https://github.com/$REPO/releases/latest). Check the network, and that $REPO has releases — or pick the ref yourself: BOX_REF=<tag> pins a release, BOX_REF=main installs the development tip."
    SRCDESC="$REPO@$REF"
    log "latest release: $REF"
  fi
  INSTALLED_FROM="$REPO@$REF"
  log "installing box from $REPO@$REF"
  # A ref is a TAG first (the pinned-release channel), a branch second (the
  # dev channel, BOX_REF=main) — and the fallback only exists for a ref the
  # OPERATOR named: a resolved latest tag has no branch to fall through to.
  URL="https://github.com/$REPO/archive/refs/tags/$REF.tar.gz"
  log "downloading $URL"
  if ! curl -fsSL "$URL" -o "$TMPDIR/box.tar.gz"; then
    [ -n "${BOX_REF:-}" ] || die "failed to download $URL"
    URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
    log "no tag '$REF' — trying it as a branch: $URL"
    curl -fsSL "$URL" -o "$TMPDIR/box.tar.gz" \
      || die "failed to download it as either — '$REF' is neither a tag nor a branch of $REPO"
  fi

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
fi
[ -n "${EXTRACTED:-}" ] || die "could not find the source tree in $SRCDESC"
[ -f "$EXTRACTED/bin/box" ] || die "source does not contain bin/box — is $SRCDESC correct?"

# The tree's own VERSION file names the directory it lands in — the version IS
# the identity of what is being installed, and 'box versions' lists these names.
new_ver="$(cat "$EXTRACTED/VERSION" 2>/dev/null || true)"
[ -n "$new_ver" ] || die "source has no VERSION file — cannot install it as a version"
valid_version "$new_ver" || die "the source's VERSION is not a sane directory name: '$new_ver'"

# --- install into $DEST/versions/<version> ---------------------------------
VDIR="$DEST/versions/$new_ver"
newly_installed=0
if [ -d "$VDIR" ]; then
  if [ -n "${BOX_REINSTALL:-}" ]; then
    # Replace THIS version's tree, as atomically as two renames allow — never
    # a partial overlay of new files onto an old tree.
    log "BOX_REINSTALL=1 — replacing the installed $new_ver tree"
    stage="$VDIR.new.$$"; old="$VDIR.old.$$"
    rm -rf "$stage" "$old"
    chmod +x "$EXTRACTED/bin/box"
    mv "$EXTRACTED" "$stage"
    # Swap by renames, delete LAST: rm-then-move leaves a hole the whole
    # length of the delete where current -> this version resolves to nothing.
    mv "$VDIR" "$old"
    mv "$stage" "$VDIR"
    rm -rf "$old"
    printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
    log "reinstalled $new_ver"
  else
    cur_from="$(cat "$VDIR/INSTALLED_FROM" 2>/dev/null || echo '<unknown source>')"
    log "box $new_ver is already installed ($cur_from) — nothing to do."
    log "(BOX_REINSTALL=1 replaces this version's tree; 'box versions' lists what is installed.)"
  fi
else
  log "installing $new_ver into $VDIR"
  mkdir -p "$DEST/versions"
  chmod +x "$EXTRACTED/bin/box"
  mv "$EXTRACTED" "$VDIR"
  newly_installed=1
  # Record WHAT was installed, so a caller can assert it got what it asked for.
  # Without this, an installer invoked with stale env vars (the CLAUDEBOX_* names
  # retired in 0.5.0) silently falls back to the defaults and installs main —
  # and the caller drills the wrong tree, believing it drilled its branch.
  printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
fi

# --- which version is the default? -----------------------------------------
# 'current' is the tracked default; flipping it is the ONLY step that changes
# what an operator's `box` runs. #66's stance, kept exactly here: never change
# versions under existing boxes. A fresh host (or a dangling current) is
# claimed outright; an upgrade flips only when no box exists — otherwise the
# new version sits installed side-by-side and 'box use' is the deliberate act.
cur="$(readlink -f "$DEST/current" 2>/dev/null || true)"
want="$(readlink -f "$VDIR")"
if [ -z "$cur" ] || [ ! -d "$cur" ]; then
  flip_current "$new_ver"
  log "default version: $new_ver"
elif [ "$cur" = "$want" ]; then
  : # already the default — nothing to flip
elif [ "$newly_installed" -eq 0 ]; then
  # A converge/no-op (or BOX_REINSTALL) of a version that is NOT the default
  # never moves the default — a re-run must change nothing (#66); switching is
  # 'box use', a deliberate act.
  log "the default stays $(basename "$cur") — 'box use $new_ver' switches."
else
  old_ver="$(basename "$cur")"
  if names="$(existing_boxes)"; then
    warn "this host has existing boxes:"
    while IFS= read -r n; do warn "  · $n"; done <<<"$names"
    warn "refusing to change the default box version under them (#66) — the default stays at $old_ver."
    log "box $new_ver is installed side-by-side. To switch:"
    log "    · preserve what you care about — 'box down <box>', 'box export <box>'"
    log "      (one portable file per box, #70), then 'box rm <box>' when you are done"
    log "    · then flip the default:  box use $new_ver"
  else
    flip_current "$new_ver"
    log "default version switched: $old_ver -> $new_ver ('box use $old_ver' switches back)"
  fi
fi

# --- put box on PATH -------------------------------------------------------
# ln -sfn converges, and that includes HEALING: a stale or dangling
# $BINDIR/box (say, its tree half-removed by hand) must never block or wedge
# an install — it gets repointed at the current chain, whatever it said before.
mkdir -p "$BINDIR"
ln -sfn "$DEST/current/bin/box" "$BINDIR/box"
log "linked $BINDIR/box -> $DEST/current/bin/box"
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

# A global (root) install is run by OTHER users, but mv preserves the tarball's
# root:root ownership and GitHub's archives carry no world bits on some paths — so
# without this, a non-root caller cannot even traverse into $DEST to reach bin/box.
# Root owns the tree, nobody else writes it, everybody reads it. a+rX: read on
# files, +search (x) on directories only. Guarded on root so the per-user install
# stays byte-identical to before.
if [ "$(id -u)" -eq 0 ]; then
  chmod -R a+rX "$DEST"
fi

# --- the OTHER tier's install, if any --------------------------------------
# A root (/opt/box) and a per-user (~/.local/share/box) install coexist by
# PATH order alone, which is easy to be surprised by — say so out loud rather
# than let two versions silently shadow each other (#71's layout, both sides).
if [ "$(id -u)" -ne 0 ]; then
  if [ -e /opt/box/current/bin/box ] || [ -e /opt/box/bin/box ]; then
    warn "a GLOBAL install also exists at /opt/box — PATH order decides which 'box' you run (check: command -v box)"
  fi
else
  sudo_home=""
  if [ -n "${SUDO_USER:-}" ]; then
    sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)" || sudo_home=""
  fi
  if [ -n "$sudo_home" ] && { [ -e "$sudo_home/.local/share/box/current/bin/box" ] || [ -e "$sudo_home/.local/share/box/bin/box" ]; }; then
    warn "a PER-USER install also exists at $sudo_home/.local/share/box — PATH order decides which 'box' $SUDO_USER runs"
  fi
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

# --- host setup (second prompt) --------------------------------------------
# The tool is installed; the machine is not yet a box host. Offer to finish the
# job — build Incus and the isolation stack — rather than leave 'box new' to die
# later on a host with no boxnet and no profile (#64). This is its own decision:
# you might be installing the CLI on a workstation and hosting boxes elsewhere.
# Offered on a FRESH host only: a host that already had a box install has made
# this decision (and may have live boxes the stack must not be rebuilt under);
# 'box setup-host' re-applies stack changes deliberately, after an upgrade.
# BOX_SKIP_SETUP_HOST=1 answers "no" without prompting (image builds, a host set
# up by hand); BOX_YES answers "yes".
setup_ok=""
setup_declined=""
if [ "$had_install" -eq 1 ]; then
  log "this host already had a box install — skipping host setup (re-apply stack changes any time: box setup-host)"
  setup_declined=1
elif [ -n "${BOX_SKIP_SETUP_HOST:-}" ]; then
  log "skipping host setup (BOX_SKIP_SETUP_HOST is set)."
  setup_declined=1
elif [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  warn "cannot set up the host: it needs root and sudo was not found."
  warn "  run this as root to finish: $DEST/current/host/setup-host.sh"
  setup_declined=1
elif confirm "Set up this machine as a box host now? (installs Incus + the isolation stack; needs sudo)"; then
  # </dev/null because under 'curl … | bash' this script IS stdin: a child that
  # reads stdin eats the installer's own remaining lines. sudo is unaffected —
  # it prompts on /dev/tty, so an interactive host can still authenticate.
  # setup-host re-execs itself under sg incus-admin if it must add you to the
  # group; that re-exec is a child here and completes the whole setup in one go.
  if bash "$DEST/current/host/setup-host.sh" </dev/null; then
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
  log "done ($SRCDESC, version $new_ver) — try: box new --name test"
elif [ -n "$setup_declined" ]; then
  log "done ($SRCDESC, version $new_ver) — when you want this machine to host boxes: box setup-host"
else
  log "done ($SRCDESC, version $new_ver) — finish with 'box setup-host', then: box new --name test"
fi
