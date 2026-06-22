#!/usr/bin/env bash
#
# disk-cleanup.sh -- SAFETY-CRITICAL, project-aware Linux-side (ext4) disk reporter & reclaimer.
#
# SYNTHESIS OF THREE STRATEGIES:
#   1. DECLARATIVE RULE TABLE. Every Tier-0 cache category is a row in $RULES
#      (tier|label|scanner|allow_glob|restore|note). Adding a category is adding a
#      row, not a code branch -- the safety logic stays in ONE auditable chokepoint.
#   2. PROJECT-GRAPH-FIRST. Phase 1 walks the scan roots and builds a MAP of every
#      project and its regenerable dependency/build dirs. That map, plus a hard
#      denylist, defines the PROTECTED set BEFORE anything is classified as waste.
#      Anything INSIDE a project that is not an explicit, named, regenerable dep dir
#      is PROTECTED BY DEFAULT (it might be source, data, or irreplaceable assets).
#   3. QUARANTINE-AS-DEFAULT-SAFE-DELETION. The PRIMARY reclaim mechanism is a
#      REVERSIBLE move into a dated quarantine folder with a RESTORE manifest.
#      Irreversible `rm -rf` happens ONLY behind the explicit, extra --purge flag.
#
# THE PRIME DIRECTIVE: it must be impossible to delete something a user/project needs.
#   When in doubt we REPORT, never act. A missed bit of garbage is fine; a wrong
#   delete is a catastrophic failure.
#     - DRY-RUN by default: with no flags it ONLY reports. It touches NOTHING without
#       --delete/--purge AND a confirmation (or --yes).
#     - THE TRIPLE GATE -- defense in depth on EVERY action target, re-checked
#       immediately before the action (TOCTOU defense). A target is eligible ONLY if
#       ALL of these hold:
#         (A) it exists and is NOT a symlink, and its realpath resolves strictly
#             UNDER an allowed action scope (a scan root, or an opted-in /tmp) -- this
#             catches symlink/mount escapes (e.g. ~/foo -> /mnt/f/bar),
#         (B) the path matches a known-safe ALLOWLIST glob/pattern, AND
#         (C) the path does NOT match the protected DENYLIST / project graph, AND it
#             does NOT CONTAIN (shallowly) a VCS dir, project marker, or source file.
#       Any failure -> the item is SKIPPED and reported in an audit trail, never
#       silently vanished.
#     - Only Tier-0 (always-regenerating caches, trash, old loose /tmp files, loose
#       tool caches OUTSIDE any project) is eligible for an action. Tier-1 (project
#       deps/builds, toolchain stores) is NEVER auto-removed -- only reported with a
#       restore cmd. Large re-downloadable binaries (ms-playwright) are a SEPARATE
#       opt-in tier.
#     - HARD-REFUSE always: /, $HOME, any scan root itself, the system/virtual mounts,
#       and any path containing a protected segment: .git .ssh .gnupg .pki .config
#       assets-golden .claude/projects -- or that looks like a source/asset/secret file
#       -- or any DIRECTORY that shallowly contains a VCS dir / project marker / source.
#
# WSL NOTE: /mnt (9p/drvfs) can report the SAME st_dev as ext4 on some setups, so
#   `find -xdev` is not sufficient on its own. We therefore (i) never follow symlinks
#   (find -P, and refuse -L candidates), (ii) explicitly prune /mnt /proc /sys /dev
#   /run, AND (iii) realpath-reject any candidate that escapes the action scope. The
#   realpath scope check is the real backstop; -xdev and the prunes are belt-and-braces.
#
# Pure bash (>=4) + coreutils + find/du/df. Single self-contained file. Linux-side only.
#
set -euo pipefail
IFS=$'\n\t'

# ============================================================================================
# Constants & globals
# ============================================================================================
readonly PROG="${0##*/}"
readonly VERSION="2.1.0"
readonly LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/disk-cleanup"
readonly LOG_FILE="${LOG_DIR}/last-run.log"

# Filesystems / virtual paths we must NEVER descend into or act upon.
readonly -a SYSTEM_PRUNE=( /mnt /proc /sys /dev /run )

# Project marker filenames that identify a project root. Used both for discovery AND
# for the DOWNWARD containment check that protects any directory holding one of these.
readonly -a PROJECT_MARKERS=(
  package.json pyproject.toml requirements.txt setup.py setup.cfg
  Cargo.toml go.mod Gemfile composer.json pom.xml build.gradle
  build.gradle.kts Pipfile poetry.lock
)

# VCS / secret directory basenames that, if found ANYWHERE shallowly beneath a candidate
# directory, make that directory protected (downward containment check).
readonly -a CONTAINED_PROTECT_DIRS=( .git .svn .hg .bzr .ssh .gnupg .pki )

# Regenerable dependency/build dir basenames inside a project (Tier-1, report-only).
readonly -a DEP_DIR_NAMES=(
  node_modules .venv venv env virtualenv
  target build dist .next .nuxt .svelte-kit out
  __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox
  .gradle vendor .turbo
)

# Dir basenames that are package-manager / tooling caches or vendored-dep trees.
# We PRUNE these during PROJECT DISCOVERY so a vendored package.json (e.g.
# node_modules/foo/package.json) or a toolchain store's own package.json (e.g.
# ~/.nvm/package.json -- verified present on this machine) is NEVER mistaken for a
# real project. They are handled wholesale as Tier-0/Tier-1 instead.
readonly -a DISCOVERY_PRUNE_NAMES=(
  node_modules .npm .nvm .cache .local .rustup .cargo .gradle
  vendor .venv venv .git .tox .pyenv .gem
)

# Hard-refuse path segments: any candidate containing one of these (as a path segment)
# is NEVER touched, regardless of tier or pattern.
readonly -a HARD_REFUSE_SEG=( .git .ssh .gnupg .pki .config assets-golden .password-store .gpg )

# Defaults (overridable by flags).
declare -a SCAN_ROOTS=()
# Cache bases anchor known scan-root-relative caches/stores. We deliberately do NOT
# add $HOME as a fallback when explicit -p roots are given (so a scan of root X never
# surfaces or touches another location's caches -- a scope-correctness guard). On a
# default run this is just ( $HOME ). Populated in parse_args.
declare -a CACHE_BASES=()
TOP_N=15
TMP_AGE_DAYS=7
DO_DELETE=0          # an action was requested (move-to-quarantine by default)
DO_PURGE=0           # irreversible rm -rf instead of quarantine (implies DO_DELETE)
ASSUME_YES=0
INCLUDE_REDOWNLOADABLE=0
INCLUDE_TMP=0        # opt-in: scan loose /tmp files for stale, you-owned waste
QUARANTINE_DIR=""    # explicit quarantine root; default derived under $HOME if empty
JSON_OUT=0

# Accumulators. Each entry is a single NUL-free record built as "<bytes>\t<path>\t<note>".
# (Paths containing embedded NUL are impossible on Unix; embedded TAB/newline are handled
#  by NUL-joining the arrays for display -- see print_group/refused printers.)
declare -a TIER0_ITEMS=()        # safe waste, eligible for an action
declare -a TIER1_DEP_ITEMS=()    # project deps -- report only, restore cmd
declare -a REDOWNLOAD_ITEMS=()   # large re-downloadable (ms-playwright)
declare -a SKIPPED_ITEMS=()      # candidates rejected by a safety gate (audit trail)

# Dedup: a realpath may be recorded at most once across ALL tiers.
declare -A SEEN_ITEMS=()
# Dedup for the refused audit trail (keyed by "path\treason") so repeated rejects of the
# same path don't flood the report.
declare -A SEEN_SKIPS=()

# Out-param from vet_candidate (avoids command-substitution subshell, so SKIPPED_ITEMS
# mutations inside vet_candidate survive into the parent shell). See vet_candidate.
VETTED_RP=""

# Project graph (associative arrays keyed by realpath).
declare -A PROJECT_ROOTS=()       # realpath -> type (node|python|rust|go|generic)
declare -A PROTECTED_DEP_DIRS=()  # realpath of regenerable dep dir -> restore cmd

TIER0_TOTAL=0
TIER1_TOTAL=0
REDOWNLOAD_TOTAL=0

# find expression arrays (IFS-independent, space/newline-safe; built once at startup).
declare -a FIND_PRUNE_EXPR=()            # prune system mounts
declare -a FIND_MARKER_EXPR=()           # match project marker filenames
declare -a FIND_DISCOVERY_PRUNE_EXPR=()  # prune system mounts + store/cache trees
declare -a FIND_GIT_PRUNE_EXPR=()        # like discovery prune, but NOT .git (so .git can match)
declare -a FIND_DEP_EXPR=()              # match regenerable dep dir names
declare -a FIND_CONTAIN_EXPR=()          # match VCS dirs + project markers (downward check)

# ============================================================================================
# THE RULE TABLE -- the declarative heart of the Tier-0 / redownloadable classification.
#
# Each entry:  tier | label | scanner | allow_glob | restore | note
#   tier        : tier0           (safe, regenerates -- eligible for an action) |
#                 redownloadable  (large, slow to refetch -- opt-in only)
#                 (Tier-1 project dirs come from the project walker, not this table.)
#   label       : human-readable category
#   scanner     : function name emitting NUL-separated absolute candidate paths
#   allow_glob  : documentation of the safe path shape (the real gate-(B) check is the
#                 predicate mapped from the scanner; see predicate_for_scanner)
#   restore     : how to recreate the data after removal
#   note        : extra context for the report
# Fields are '|'-separated; none of our fields contain '|'.
# ============================================================================================
readonly -a RULES=(
  # --- Tier-0: package-manager caches that ALWAYS regenerate -------------------------------
  "tier0|pip cache|scan_cache_pip|<base>/.cache/pip|auto-regenerates on next pip install|HTTP/wheel cache"
  "tier0|uv cache|scan_cache_uv|<base>/.cache/uv|auto-regenerates on next uv run|uv python cache"
  "tier0|npm _cacache|scan_npm_cacache|<base>/.npm/_cacache|auto-regenerates on next npm install|npm content cache"
  "tier0|npm _npx one-off cache|scan_npm_npx|<base>/.npm/_npx|auto-regenerates on next npx call|throwaway npx packages"
  "tier0|npm _logs|scan_npm_logs|<base>/.npm/_logs|auto-regenerates|npm debug logs"
  "tier0|yarn cache|scan_cache_yarn|<base>/.cache/yarn|auto-regenerates on next yarn install|yarn cache"
  "tier0|pnpm cache|scan_cache_pnpm|<base>/.cache/pnpm|auto-regenerates on next pnpm install|pnpm cache (not the store)"
  "tier0|vite cache|scan_cache_vite|<base>/.cache/vite|auto-regenerates on next build|vite cache"
  "tier0|turbo cache|scan_cache_turbo|<base>/.cache/turbo|auto-regenerates on next build|turborepo cache"
  "tier0|webpack cache|scan_cache_webpack|<base>/.cache/webpack|auto-regenerates on next build|webpack cache"
  "tier0|esbuild cache|scan_cache_esbuild|<base>/.cache/esbuild|auto-regenerates on next build|esbuild cache"
  "tier0|babel cache|scan_cache_babel|<base>/.cache/babel|auto-regenerates on next build|babel cache"
  "tier0|go build cache|scan_cache_gobuild|<base>/.cache/go-build|auto-regenerates on next go build|go build cache"
  "tier0|giget cache|scan_cache_giget|<base>/.cache/giget|auto-regenerates on next template fetch|giget template cache"
  "tier0|prisma cache|scan_cache_prisma|<base>/.cache/prisma|auto-regenerates on next prisma run|prisma engines cache"
  "tier0|zig cache|scan_cache_zig|<base>/.cache/zig|auto-regenerates on next zig build|zig global cache"
  "tier0|mesa shader cache|scan_cache_mesa|<base>/.cache/mesa_shader_cache|auto-regenerates on next GL use|mesa shader cache"
  "tier0|fontconfig cache|scan_cache_fontconfig|<base>/.cache/fontconfig|auto-regenerates|fontconfig cache"
  "tier0|ms-playwright-mcp cache|scan_cache_mspwmcp|<base>/.cache/ms-playwright-mcp|auto-regenerates on next run|playwright-mcp cache"
  "tier0|ffmpeg-static cache|scan_cache_ffmpegstatic|<base>/.cache/ffmpeg-static-nodejs|re-downloads on next use|ffmpeg-static binary cache"
  "tier0|thumbnail cache|scan_cache_thumbnails|<base>/.cache/thumbnails|auto-regenerates|image thumbnails"
  # --- Tier-0: trash ----------------------------------------------------------------------
  "tier0|Trash|scan_trash|<base>/.local/share/Trash|N/A -- already discarded|freedesktop trash"
  # --- Tier-0: verified ELF core dumps ----------------------------------------------------
  "tier0|core dumps|scan_core_dumps|<base>/**/core.<pid>|N/A|verified ELF process crash dumps"
  # --- Tier-0: old, user-owned, top-level /tmp FILES (opt-in via --include-tmp) -----------
  "tier0|old /tmp files (you-owned, --include-tmp)|scan_tmp_old|/tmp/<file>|N/A -- transient|stale temp files (files only)"
  # --- Tier-0: loose throwaway tool caches OUTSIDE any project ----------------------------
  "tier0|loose .pytest_cache (non-project)|scan_loose_pytest|<base>/**/.pytest_cache|auto-regenerates on next pytest|pytest cache"
  "tier0|loose .mypy_cache (non-project)|scan_loose_mypy|<base>/**/.mypy_cache|auto-regenerates on next mypy|mypy cache"
  "tier0|loose .ruff_cache (non-project)|scan_loose_ruff|<base>/**/.ruff_cache|auto-regenerates on next ruff|ruff cache"
  # --- Redownloadable: large, slow to refetch -- explicit opt-in only ----------------------
  "redownloadable|ms-playwright browsers|scan_playwright|<base>/.cache/ms-playwright|npx playwright install (slow, large download)|browser binaries"
  "redownloadable|puppeteer browsers|scan_puppeteer|<base>/.cache/puppeteer|puppeteer re-download (slow)|browser binaries"
  "redownloadable|huggingface models|scan_huggingface|<base>/.cache/huggingface|re-downloads model weights (slow, large)|HF model/dataset cache"
)

# ============================================================================================
# Output / logging helpers
# ============================================================================================
c_reset=""; c_bold=""; c_red=""; c_grn=""; c_yel=""; c_blu=""; c_cya=""; c_dim=""
if [[ -t 1 ]]; then
  c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'
  c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[34m'; c_cya=$'\033[36m'; c_dim=$'\033[2m'
fi

err()  { printf '%s[%s] ERROR:%s %s\n' "$c_red" "$PROG" "$c_reset" "$*" >&2; }
warn() { printf '%s[%s] WARN:%s %s\n'  "$c_yel" "$PROG" "$c_reset" "$*" >&2; }
info() { printf '%s\n' "$*"; }
die()  { err "$*"; exit 1; }

log_action() {
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(date -Is 2>/dev/null || date)" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

# Record a refused/skipped candidate exactly once (dedup on path+reason). This is called in
# the PARENT shell (never in a command substitution), so the audit trail actually persists.
record_skip() {
  local path="$1" reason="$2" key
  key="${path}"$'\t'"${reason}"
  [[ -n "${SEEN_SKIPS[$key]:-}" ]] && return 0
  SEEN_SKIPS["$key"]=1
  SKIPPED_ITEMS+=("0"$'\t'"$path"$'\t'"refused: $reason")
}

# Human-readable bytes.
human() {
  local b=${1:-0}
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B --format='%.1f' "$b" 2>/dev/null && return 0
  fi
  awk -v b="$b" 'BEGIN{
    split("B K M G T P",a," "); i=1; v=b+0;
    while (v>=1024 && i<6){v/=1024;i++}
    if (i==1) printf "%dB", v; else printf "%.1f%sB", v, a[i]
  }'
}

# Apparent disk usage of a path in bytes, single filesystem, no symlink follow. 0 if missing.
path_bytes() {
  local p="$1"
  [[ -e "$p" ]] || { printf '0'; return 0; }
  du -sxb -- "$p" 2>/dev/null | awk 'NR==1{print $1+0; f=1} END{if(!f)print 0}'
}

# ============================================================================================
# Help
# ============================================================================================
usage() {
  cat <<EOF
${c_bold}${PROG}${c_reset} v${VERSION} -- safe, project-aware Linux disk reporter & reclaimer (WSL2/ext4).

${c_bold}USAGE${c_reset}
  ${PROG} [options]

By default this is a ${c_bold}DRY RUN${c_reset}: it reports disk usage and a categorized list of
reclaimable items and ${c_bold}changes nothing${c_reset}. With --delete it MOVES Tier-0 items into a
dated ${c_bold}quarantine${c_reset} folder (reversible, with a RESTORE manifest). Irreversible deletion
needs the explicit --purge flag. Tier-1 (project deps/builds) is NEVER auto-removed.

${c_bold}OPTIONS${c_reset}
  -p, --root <dir>        Scan root (repeatable). Default: \$HOME (${HOME}).
  -n, --top <N>           Show top N subdirs in the du summary (0 disables). Default: ${TOP_N}.
      --tmp-age <days>    Only treat user /tmp FILES older than this as waste. Default: ${TMP_AGE_DAYS}.
      --include-tmp       Also consider stale, you-owned, loose FILES in /tmp as Tier-0.
                          Off by default. NEVER touches /tmp directories or others' files.
      --delete            Reclaim Tier-0 by MOVING it to quarantine (reversible). Prompts unless --yes.
      --purge             Reclaim Tier-0 by IRREVERSIBLE rm -rf. Implies --delete. Prompts unless --yes.
      --quarantine <dir>  Quarantine root (default: \$HOME/.cache/disk-cleanup/quarantine).
      --yes               Skip the interactive y/N confirmation (use with --delete/--purge).
      --include-redownloadable
                          Also act on large re-downloadable caches (e.g. ms-playwright,
                          huggingface). Forces a slow re-download later. Off by default.
      --json              Emit a machine-readable JSON report (report-only; never acts).
                          Cannot be combined with --delete/--purge.
  -h, --help              Show this help.

${c_bold}TIERS${c_reset}
  ${c_grn}Tier-0${c_reset}  Always-regenerating package-manager caches, trash, verified core dumps,
          loose tool caches OUTSIDE any project, and (with --include-tmp) stale loose
          /tmp files. Eligible for an action.
  ${c_yel}Tier-1${c_reset}  Project dependency/build dirs (node_modules, .venv, target, ...) and
          fnm/node/rust toolchain stores. NEVER auto-removed -- reported with restore command.
  ${c_red}Re-DL${c_reset}   Large but re-downloadable binaries/models (ms-playwright/puppeteer/
          huggingface). Reported separately; actionable ONLY with --include-redownloadable.

${c_bold}SAFETY MODEL (the triple gate)${c_reset}
  Every action target must, at collection AND again immediately before the action:
    (A) be a non-symlink whose realpath resolves strictly UNDER a scan root (or an
        opted-in /tmp) -- no symlink/mount escape (e.g. ~/foo -> /mnt/f/bar is rejected),
    (B) match a known-safe allowlist pattern, AND
    (C) NOT match the protected denylist / project graph, AND not (shallowly) CONTAIN a
        VCS dir (.git/.svn/.hg/...), a project marker (package.json, pyproject.toml, ...),
        or source files.
  Hard-refused always: /, \$HOME, scan roots, system mounts, and any path containing
  .git .ssh .gnupg .pki .config assets-golden .claude/projects, or a source/asset/secret file.

${c_bold}REVERSIBILITY${c_reset}
  --delete moves items to: \$HOME/.cache/disk-cleanup/quarantine/<timestamp>/...
  A RESTORE.txt manifest maps each quarantined copy back to its original path.
  Restore by moving it back; free the space for good with: rm -rf <quarantine dir>.

${c_bold}EXAMPLES${c_reset}
  ${PROG}                              # dry-run report only (safe; default)
  ${PROG} -n 25                        # report, bigger du summary
  ${PROG} --delete                     # MOVE Tier-0 to quarantine after a y/N prompt
  ${PROG} --delete --yes               # same, non-interactive
  ${PROG} --delete --quarantine ~/quar # move into a custom quarantine root
  ${PROG} --purge --yes                # irreversible delete of Tier-0 (last resort)
  ${PROG} --delete --include-tmp --yes # also quarantine stale loose /tmp files
  ${PROG} --delete --include-redownloadable --yes   # also quarantine ms-playwright
  ${PROG} -p ~/projects -p ~/work      # scan custom roots
  ${PROG} --json > report.json         # machine-readable report
EOF
}

# ============================================================================================
# Argument parsing
# ============================================================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--root)
        [[ $# -ge 2 ]] || die "$1 requires a directory argument"
        SCAN_ROOTS+=("$2"); shift 2 ;;
      -n|--top)
        [[ $# -ge 2 ]] || die "$1 requires a number"
        [[ "$2" =~ ^[0-9]+$ ]] || die "--top expects a non-negative integer, got: $2"
        TOP_N="$2"; shift 2 ;;
      --tmp-age)
        [[ $# -ge 2 ]] || die "$1 requires a number"
        [[ "$2" =~ ^[0-9]+$ ]] || die "--tmp-age expects a non-negative integer, got: $2"
        TMP_AGE_DAYS="$2"; shift 2 ;;
      --include-tmp) INCLUDE_TMP=1; shift ;;
      --delete)   DO_DELETE=1; shift ;;
      --purge)    DO_PURGE=1; DO_DELETE=1; shift ;;
      --yes|-y)   ASSUME_YES=1; shift ;;
      --include-redownloadable) INCLUDE_REDOWNLOADABLE=1; shift ;;
      --quarantine)
        [[ $# -ge 2 ]] || die "$1 requires a directory argument"
        QUARANTINE_DIR="$2"; shift 2 ;;
      --json)     JSON_OUT=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      --) shift; break ;;
      -*) die "Unknown option: $1 (try --help)" ;;
      *)  die "Unexpected argument: $1 (try --help)" ;;
    esac
  done

  # --json is report-only; refuse to silently swallow a destructive request.
  if [[ "$JSON_OUT" -eq 1 && "$DO_DELETE" -eq 1 ]]; then
    die "--json is report-only; do not combine it with --delete or --purge."
  fi

  # $HOME must be a real, non-empty, absolute directory for the anchored patterns to be safe.
  [[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" ]] || die "HOME must be a valid absolute directory."

  # Default scan root.
  [[ ${#SCAN_ROOTS[@]} -gt 0 ]] || SCAN_ROOTS=("$HOME")

  # Resolve & validate every scan root. Reject anything not a real, safe dir.
  local -a resolved=()
  local r rr
  for r in "${SCAN_ROOTS[@]}"; do
    rr="$(realpath -e -- "$r" 2>/dev/null || true)"
    [[ -n "$rr" ]]           || { warn "Skipping unresolvable root: $r"; continue; }
    [[ -d "$rr" ]]           || { warn "Skipping non-directory root: $r"; continue; }
    is_root_acceptable "$rr" || { warn "Refusing unsafe scan root: $rr"; continue; }
    resolved+=("$rr")
  done
  [[ ${#resolved[@]} -gt 0 ]] || die "No valid scan roots; aborting."
  SCAN_ROOTS=("${resolved[@]}")

  # Cache bases = exactly the resolved scan roots (no $HOME fallback; scope-correctness).
  CACHE_BASES=("${SCAN_ROOTS[@]}")

  # Default quarantine root lives under $HOME's cache (always local).
  [[ -n "$QUARANTINE_DIR" ]] || QUARANTINE_DIR="$LOG_DIR/quarantine"

  # Validate the quarantine root location now (cheap, fail early).
  local qrp
  qrp="$(realpath -m -- "$QUARANTINE_DIR" 2>/dev/null || true)"
  [[ -n "$qrp" ]] || die "Bad --quarantine path: $QUARANTINE_DIR"
  if path_in_system "$qrp"; then die "Refusing quarantine on an excluded mount: $qrp"; fi
  [[ "$qrp" == "/" ]] && die "Refusing quarantine at /"
  # A USER-SUPPLIED quarantine must NOT sit inside any scan root (else we'd re-scan / nest it).
  # The safe default ($LOG_DIR/quarantine) is exempt: it lives in .cache/disk-cleanup, which no
  # rule targets and which the denylist hard-refuses from any action.
  if [[ "$qrp" != "$LOG_DIR/quarantine" ]]; then
    for r in "${SCAN_ROOTS[@]}"; do
      if [[ "$qrp" == "$r" || "$qrp" == "$r/"* ]]; then
        die "Refusing --quarantine inside a scan root ($qrp under $r); choose a dir outside the roots."
      fi
    done
  fi
  QUARANTINE_DIR="$qrp"
}

# A scan root must be a real directory that is NOT "/", NOT a system/virtual mount.
is_root_acceptable() {
  local p="$1" sp
  [[ "$p" == "/" ]] && { err "Refusing scan root '/'"; return 1; }
  for sp in "${SYSTEM_PRUNE[@]}"; do
    [[ "$p" == "$sp" || "$p" == "$sp/"* ]] && { err "Refusing system/virtual path: $p"; return 1; }
  done
  return 0
}

# ============================================================================================
# find expression builders -> real bash ARRAYS (correct regardless of IFS).
# ============================================================================================
build_marker_name_expr() {
  FIND_MARKER_EXPR=()
  local m first=1
  for m in "${PROJECT_MARKERS[@]}"; do
    if [[ $first -eq 1 ]]; then FIND_MARKER_EXPR=( -name "$m" ); first=0
    else FIND_MARKER_EXPR+=( -o -name "$m" ); fi
  done
}

build_prune_expr() {
  FIND_PRUNE_EXPR=()
  local sp first=1
  for sp in "${SYSTEM_PRUNE[@]}"; do
    if [[ $first -eq 1 ]]; then FIND_PRUNE_EXPR=( -path "$sp" ); first=0
    else FIND_PRUNE_EXPR+=( -o -path "$sp" ); fi
    FIND_PRUNE_EXPR+=( -o -path "$sp/*" )
  done
}

# Discovery prune = system prune PLUS the store/cache trees (so project discovery stops at
# node_modules/.npm/.nvm/.cache/etc. and never descends into them or mislabels their markers).
build_discovery_prune_expr() {
  FIND_DISCOVERY_PRUNE_EXPR=( "${FIND_PRUNE_EXPR[@]}" )
  FIND_GIT_PRUNE_EXPR=( "${FIND_PRUNE_EXPR[@]}" )
  local n
  for n in "${DISCOVERY_PRUNE_NAMES[@]}"; do
    FIND_DISCOVERY_PRUNE_EXPR+=( -o -name "$n" )
    # The .git pass must be able to MATCH a .git dir, so do not prune it there; we still
    # prune the store/cache trees so a .git inside a toolchain store (e.g. ~/.nvm/.git)
    # is not mistaken for a user project.
    [[ "$n" == ".git" ]] && continue
    FIND_GIT_PRUNE_EXPR+=( -o -name "$n" )
  done
}

build_dep_name_expr() {
  FIND_DEP_EXPR=()
  local n first=1
  for n in "${DEP_DIR_NAMES[@]}"; do
    if [[ $first -eq 1 ]]; then FIND_DEP_EXPR=( -name "$n" ); first=0
    else FIND_DEP_EXPR+=( -o -name "$n" ); fi
  done
}

# Downward-containment expression: VCS dirs (any) + project markers (files). Used to
# protect any directory that holds something precious shallowly beneath it.
build_contain_expr() {
  FIND_CONTAIN_EXPR=()
  local n first=1
  for n in "${CONTAINED_PROTECT_DIRS[@]}"; do
    if [[ $first -eq 1 ]]; then FIND_CONTAIN_EXPR=( -name "$n" ); first=0
    else FIND_CONTAIN_EXPR+=( -o -name "$n" ); fi
  done
  for n in "${PROJECT_MARKERS[@]}"; do
    FIND_CONTAIN_EXPR+=( -o -name "$n" )
  done
}

init_find_exprs() {
  build_marker_name_expr; build_prune_expr; build_discovery_prune_expr
  build_dep_name_expr; build_contain_expr
}

# ============================================================================================
# Scope / denylist primitives
# ============================================================================================
path_in_system() {
  local p="$1" sp
  for sp in "${SYSTEM_PRUNE[@]}"; do
    [[ "$p" == "$sp" || "$p" == "$sp/"* ]] && return 0
  done
  return 1
}

# Gate (A) core: is realpath p strictly UNDER one of the scan roots, and NOT on a system mount?
under_scan_root() {
  local p="$1" r
  path_in_system "$p" && return 1
  for r in "${SCAN_ROOTS[@]}"; do
    [[ "$p" == "$r/"* ]] && return 0
  done
  return 1
}

# The action scope = the scan roots, plus /tmp ONLY when /tmp scanning was opted in. /tmp is
# never a scan root and is gated entirely behind --include-tmp (no surprise out-of-scope acts).
under_action_scope() {
  local p="$1"
  under_scan_root "$p" && return 0
  if [[ "$INCLUDE_TMP" -eq 1 ]]; then
    case "$p" in /tmp/*) return 0 ;; esac
  fi
  return 1
}

# Is realpath p inside ANY known project root?
inside_a_project() {
  local p="$1" proj
  for proj in "${!PROJECT_ROOTS[@]}"; do
    [[ "$p" == "$proj" || "$p" == "$proj/"* ]] && return 0
  done
  return 1
}

# DOWNWARD containment check (gate C, defense in depth). Returns 0 (protected) if directory p
# shallowly contains a VCS dir, a project marker, or a recognizable source file. This is the
# backstop for wholesale-selected DIRECTORIES whose own path segments look innocent but which
# hold precious children (the proven /tmp-project class, and any project the lossy discovery
# walker failed to enumerate). Cheap: bounded by -maxdepth and -quit on first hit.
dir_contains_precious() {
  local p="$1" hit
  [[ -d "$p" ]] || return 1
  # VCS dirs + project markers, up to 3 levels deep (catches monorepo/subdir layouts cheaply).
  hit="$(find -P "$p" -xdev -mindepth 1 -maxdepth 3 \
           \( "${FIND_PRUNE_EXPR[@]}" \) -prune -o \
           \( "${FIND_CONTAIN_EXPR[@]}" \) -print -quit 2>/dev/null || true)"
  [[ -n "$hit" ]] && return 0
  # Recognizable source/secret files directly within a couple of levels.
  hit="$(find -P "$p" -xdev -mindepth 1 -maxdepth 2 -type f \
           \( "${FIND_PRUNE_EXPR[@]}" \) -prune -o \
           -type f \( \
             -iname '*.c' -o -iname '*.h' -o -iname '*.cc' -o -iname '*.cpp' -o -iname '*.rs' \
             -o -iname '*.go' -o -iname '*.py' -o -iname '*.js' -o -iname '*.ts' -o -iname '*.tsx' \
             -o -iname '*.jsx' -o -iname '*.java' -o -iname '*.rb' -o -iname '*.php' -o -iname '*.sh' \
             -o -iname '*.pem' -o -iname '*.key' -o -iname '*.crt' -o -name '.env' -o -name '.env.*' \
           \) -print -quit 2>/dev/null || true)"
  [[ -n "$hit" ]] && return 0
  return 1
}

# THE DENYLIST -- gate (C). Returns 0 if path is PROTECTED (must NOT be touched).
#   $2 = "deep" (optional): also run the (more expensive) downward-containment check on dirs.
#        Callers that have already restricted the candidate shape (e.g. anchored cache paths)
#        pass nothing; wholesale/dir candidates (loose caches, /tmp files) pass "deep".
is_protected() {
  local p="$1" deep="${2:-}" r seg

  # Never the root, $HOME itself, or a scan root itself.
  [[ "$p" == "/" ]] && return 0
  [[ "$p" == "$HOME" ]] && return 0
  for r in "${SCAN_ROOTS[@]}"; do
    [[ "$p" == "$r" ]] && return 0
  done

  # Never any system/virtual path.
  path_in_system "$p" && return 0

  # Hard-refuse any path that CONTAINS a protected segment anywhere in it.
  for seg in "${HARD_REFUSE_SEG[@]}"; do
    [[ "$p" == *"/$seg" || "$p" == *"/$seg/"* ]] && return 0
  done
  # .claude/projects holds AI session transcripts -- data, never garbage.
  [[ "$p" == *"/.claude/projects" || "$p" == *"/.claude/projects/"* ]] && return 0
  # Our own quarantine/log store is off-limits to action.
  [[ "$p" == "$LOG_DIR" || "$p" == "$LOG_DIR/"* ]] && return 0

  # Never operate ON a known project root directory itself, nor anything INSIDE one (unless it
  # is an explicitly classified regenerable dep dir, which the loose-cache scanners already
  # exclude via inside_a_project). A path inside a project that reached here is protected.
  [[ -n "${PROJECT_ROOTS[$p]+x}" ]] && return 0
  if inside_a_project "$p"; then
    [[ -n "${PROTECTED_DEP_DIRS[$p]+x}" ]] || return 0
  fi

  # Refuse anything that looks like a source/config/secret/asset FILE (defense in depth).
  if [[ -f "$p" ]]; then
    case "${p,,}" in
      *.c|*.h|*.cc|*.cpp|*.hpp|*.cxx|*.rs|*.go|*.py|*.pyi|*.js|*.jsx|*.ts|*.tsx|\
      *.java|*.kt|*.rb|*.php|*.cs|*.swift|*.m|*.mm|*.sh|*.bash|*.zsh|*.lua|*.sql|\
      *.json|*.toml|*.yaml|*.yml|*.lock|*.md|*.txt|*.html|*.css|*.scss|*.vue|*.svelte|\
      *.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.wav|*.mp3|*.ogg|*.ttf|*.otf|\
      *.env|*.pem|*.key|*.crt|*.cfg|*.ini|*.conf)
        return 0 ;;
    esac
    case "${p##*/}" in
      .env|.env.*) return 0 ;;
    esac
  fi

  # DEEP (downward) check for directory candidates selected wholesale.
  if [[ "$deep" == "deep" && -d "$p" ]]; then
    dir_contains_precious "$p" && return 0
  fi

  return 1  # not protected
}

# ============================================================================================
# THE TRIPLE GATE -- the single chokepoint. On success sets global VETTED_RP to the vetted
# realpath and returns 0. On any failure records a SKIPPED audit entry (in the PARENT shell,
# so it persists) for reclaimable-looking candidates and returns 1.
#
# IMPORTANT: callers must invoke this WITHOUT command substitution, e.g.
#     if vet_candidate "$cand" "$pred"; then rp="$VETTED_RP"; ... ; fi
# so that SKIPPED_ITEMS mutations are not lost in a subshell.
#
#   $1 = raw candidate path
#   $2 = name of a safe-pattern predicate function (gate B), called with the realpath
#   $3 = "quiet" (optional): suppress the audit-trail entry on rejection
#   $4 = "deep"  (optional): enable downward-containment protection for dir candidates
# ============================================================================================
vet_candidate() {
  local raw="$1" pattern_fn="$2" quiet="${3:-}" deep="${4:-}" rp rec=1
  VETTED_RP=""
  [[ "$quiet" == "quiet" ]] && rec=0

  # (A.1) never a symlink -- never follow a link out of scope.
  if [[ -L "$raw" ]]; then (( rec )) && record_skip "$raw" "symlink"; return 1; fi
  # vanished between scan and vet -> silently skip (no audit noise).
  [[ -e "$raw" ]] || return 1

  # (A.2) realpath must resolve and stay under the action scope.
  rp="$(realpath -e -- "$raw" 2>/dev/null || true)"
  if [[ -z "$rp" ]]; then (( rec )) && record_skip "$raw" "unresolvable realpath"; return 1; fi
  if ! under_action_scope "$rp"; then (( rec )) && record_skip "$rp" "escapes scan scope (symlink/mount?)"; return 1; fi

  # (C) denylist / project graph / downward containment.
  if is_protected "$rp" "$deep"; then (( rec )) && record_skip "$rp" "protected path"; return 1; fi

  # (B) must match the supplied safe pattern.
  if ! "$pattern_fn" "$rp"; then (( rec )) && record_skip "$rp" "did not match safe pattern"; return 1; fi

  VETTED_RP="$rp"
  return 0
}

# ============================================================================================
# Safe-pattern predicates (gate B). Each returns 0 iff realpath p is a recognized member.
# Anchored to ANY cache base so custom -p roots work and a sandboxed scan never matches the
# real $HOME by accident.
# ============================================================================================
# Helper: does p equal or sit under <base>/<suffix> for SOME cache base?
_match_under_bases() {
  local p="$1" suffix="$2" base
  for base in "${CACHE_BASES[@]}"; do
    [[ "$p" == "$base/$suffix" || "$p" == "$base/$suffix/"* ]] && return 0
  done
  return 1
}

pat_tier0_cache() {
  local p="$1" suf
  for suf in \
    .cache/pip .cache/uv \
    .npm/_cacache .npm/_npx .npm/_logs \
    .cache/yarn .cache/pnpm \
    .cache/vite .cache/turbo .cache/webpack .cache/esbuild .cache/babel \
    .cache/go-build .cache/giget .cache/prisma .cache/zig \
    .cache/mesa_shader_cache .cache/fontconfig .cache/ms-playwright-mcp \
    .cache/ffmpeg-static-nodejs .cache/thumbnails
  do
    _match_under_bases "$p" "$suf" && return 0
  done
  return 1
}

pat_trash() { _match_under_bases "$1" ".local/share/Trash" && return 0; return 1; }

# /tmp predicate: FILES ONLY, you-owned, never the well-known socket dirs. Directories in
# /tmp are NEVER eligible (a directory may be an active scratch project; we refuse it).
pat_tmp_old() {
  local p="$1"
  case "$p" in
    /tmp/.X11-unix*|/tmp/.ICE-unix*|/tmp/.font-unix*|/tmp/.XIM-unix*|/tmp/.Test-unix*) return 1 ;;
    /tmp/*) ;;
    *) return 1 ;;
  esac
  # Must be a regular file (not a dir, not a socket/fifo/device).
  [[ -f "$p" && ! -L "$p" ]] || return 1
  return 0
}

# Loose throwaway tool caches (the realpath must be a dir named exactly one of these AND
# carry the tool's own cache marker, mirroring the conservative core-dump verification).
pat_loose_toolcache() {
  local p="$1" base
  base="${p##*/}"
  case "$base" in
    .pytest_cache|.mypy_cache|.ruff_cache) ;;
    *) return 1 ;;
  esac
  [[ -d "$p" ]] || return 1
  # Require a recognizable internal marker so a directory merely NAMED like a cache, but
  # repurposed as real data, is reported (refused) rather than deleted. "When in doubt,
  # report, don't delete."
  case "$base" in
    .pytest_cache)
      [[ -f "$p/CACHEDIR.TAG" || -f "$p/.gitignore" || -d "$p/v" || -f "$p/README.md" ]] || return 1 ;;
    .mypy_cache)
      [[ -f "$p/CACHEDIR.TAG" || -f "$p/.gitignore" || -d "$p/3.8" || -d "$p/3.9" || -d "$p/3.10" \
         || -d "$p/3.11" || -d "$p/3.12" || -d "$p/3.13" || -f "$p/missing_stubs" ]] \
        || { # accept if every immediate entry is a mypy cache file (*.json) or its tag
             local f only=1
             shopt -s nullglob dotglob
             for f in "$p"/*; do
               case "${f##*/}" in *.json|CACHEDIR.TAG) ;; *) only=0; break ;; esac
             done
             shopt -u nullglob dotglob
             [[ "$only" -eq 1 ]] || return 1
           } ;;
    .ruff_cache)
      [[ -f "$p/CACHEDIR.TAG" || -f "$p/.gitignore" || -d "$p/0.0.0" || -n "$(find "$p" -maxdepth 2 -name 'content-*' -print -quit 2>/dev/null)" ]] || return 1 ;;
  esac
  return 0
}

# The core-dump scanner already verifies ELF-core via `file`; scope/denylist still apply.
pat_core_dump() {
  case "${1##*/}" in core.[0-9]*) return 0 ;; esac
  return 1
}

pat_redownloadable() {
  _match_under_bases "$1" ".cache/ms-playwright" && return 0
  _match_under_bases "$1" ".cache/puppeteer" && return 0
  _match_under_bases "$1" ".cache/huggingface" && return 0
  return 1
}

# ============================================================================================
# Scanners -- each emits NUL-separated absolute candidate paths. They never follow/emit
# symlinks, never cross filesystems (-xdev), and prune the excluded mounts.
# ============================================================================================
emit_if_present() { local b; for b in "${CACHE_BASES[@]}"; do [[ -e "$b/$1" && ! -L "$b/$1" ]] && printf '%s\0' "$b/$1"; done; }

scan_cache_pip()          { emit_if_present ".cache/pip"; }
scan_cache_uv()           { emit_if_present ".cache/uv"; }
scan_npm_cacache()        { emit_if_present ".npm/_cacache"; }
scan_npm_npx()            { emit_if_present ".npm/_npx"; }
scan_npm_logs()           { emit_if_present ".npm/_logs"; }
scan_cache_yarn()         { emit_if_present ".cache/yarn"; }
scan_cache_pnpm()         { emit_if_present ".cache/pnpm"; }
scan_cache_vite()         { emit_if_present ".cache/vite"; }
scan_cache_turbo()        { emit_if_present ".cache/turbo"; }
scan_cache_webpack()      { emit_if_present ".cache/webpack"; }
scan_cache_esbuild()      { emit_if_present ".cache/esbuild"; }
scan_cache_babel()        { emit_if_present ".cache/babel"; }
scan_cache_gobuild()      { emit_if_present ".cache/go-build"; }
scan_cache_giget()        { emit_if_present ".cache/giget"; }
scan_cache_prisma()       { emit_if_present ".cache/prisma"; }
scan_cache_zig()          { emit_if_present ".cache/zig"; }
scan_cache_mesa()         { emit_if_present ".cache/mesa_shader_cache"; }
scan_cache_fontconfig()   { emit_if_present ".cache/fontconfig"; }
scan_cache_mspwmcp()      { emit_if_present ".cache/ms-playwright-mcp"; }
scan_cache_ffmpegstatic() { emit_if_present ".cache/ffmpeg-static-nodejs"; }
scan_cache_thumbnails()   { emit_if_present ".cache/thumbnails"; }
scan_trash()              { emit_if_present ".local/share/Trash"; }
scan_playwright()         { emit_if_present ".cache/ms-playwright"; }
scan_puppeteer()          { emit_if_present ".cache/puppeteer"; }
scan_huggingface()        { emit_if_present ".cache/huggingface"; }

# Core dumps: a real kernel dump is named like 'core.<pid>' AND is an ELF "core file". We
# refuse the bare name 'core' entirely (countless legit data files are named 'core'), require
# a numeric suffix, AND -- when `file` is available -- confirm it is genuinely an ELF core
# dump. If `file` is unavailable we emit nothing (conservative: better to miss a dump).
scan_core_dumps() {
  command -v file >/dev/null 2>&1 || return 0
  local r f
  for r in "${SCAN_ROOTS[@]}"; do
    [[ -d "$r" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -L "$f" ]] && continue
      case "$(file -b -- "$f" 2>/dev/null)" in
        *core\ file*|*ELF*core*) printf '%s\0' "$f" ;;
      esac
    done < <(
      find -P "$r" -xdev \
        \( "${FIND_DISCOVERY_PRUNE_EXPR[@]}" -o -name node_modules \) -prune -o \
        -type f -name 'core.[0-9]*' -print0 2>/dev/null
    )
  done
}

# Old, user-owned, top-level, REGULAR FILES directly in /tmp. NEVER directories (a /tmp dir
# may be an active scratch project -- the proven catastrophic false-positive). NEVER recurse
# into others' dirs. Gated entirely behind --include-tmp.
scan_tmp_old() {
  [[ "$INCLUDE_TMP" -eq 1 ]] || return 0
  [[ -d /tmp ]] || return 0
  find -P /tmp -mindepth 1 -maxdepth 1 -xdev -type f -user "$(id -u)" -mtime "+$TMP_AGE_DAYS" \
    ! -name '.X11-unix' ! -name '.ICE-unix' ! -name '.font-unix' \
    ! -name '.XIM-unix' ! -name '.Test-unix' -print0 2>/dev/null
}

# Loose tool caches OUTSIDE any detected project (project ones are Tier-1, handled separately).
# We prune the store trees so we never surface the thousands of caches owned by deps.
_scan_loose_named() {
  local name="$1" r p rp
  for r in "${SCAN_ROOTS[@]}"; do
    [[ -d "$r" ]] || continue
    while IFS= read -r -d '' p; do
      [[ -L "$p" ]] && continue
      rp="$(realpath -e -- "$p" 2>/dev/null || true)"
      [[ -n "$rp" ]] || continue
      inside_a_project "$rp" && continue   # in-project => Tier-1, not loose Tier-0
      printf '%s\0' "$p"
    done < <(
      find -P "$r" -xdev \
        \( "${FIND_DISCOVERY_PRUNE_EXPR[@]}" \
           -o -name node_modules -o -name site-packages -o -name dist-packages \
        \) -prune -o \
        -type l -prune -o \
        -type d -name "$name" -print0 2>/dev/null
    )
  done
}
scan_loose_pytest() { _scan_loose_named ".pytest_cache"; }
scan_loose_mypy()   { _scan_loose_named ".mypy_cache"; }
scan_loose_ruff()   { _scan_loose_named ".ruff_cache"; }

# Map a rule's scanner to its gate-(B) predicate function.
predicate_for_scanner() {
  case "$1" in
    scan_core_dumps)                       printf 'pat_core_dump' ;;
    scan_tmp_old)                          printf 'pat_tmp_old' ;;
    scan_trash)                            printf 'pat_trash' ;;
    scan_playwright|scan_puppeteer|scan_huggingface) printf 'pat_redownloadable' ;;
    scan_loose_pytest|scan_loose_mypy|scan_loose_ruff) printf 'pat_loose_toolcache' ;;
    *)                                     printf 'pat_tier0_cache' ;;
  esac
}

# Does a scanner's output need the DEEP downward-containment check? Wholesale dir/file
# candidates that are not anchored to a fixed cache suffix do (loose tool caches; /tmp files).
deep_for_scanner() {
  case "$1" in
    scan_tmp_old|scan_loose_pytest|scan_loose_mypy|scan_loose_ruff) printf 'deep' ;;
    *) printf '' ;;
  esac
}

# Is this a TOP-LEVEL /tmp entry (i.e. /tmp/<name> with no further slash)? Only such paths
# are scan_tmp_old candidates. A cache like /tmp/sandbox/.cache/pip is NOT a tmp-old item; it
# is a normal anchored cache that merely happens to live under a /tmp-rooted scan root.
_is_tmp_toplevel() {
  case "$1" in
    /tmp/*/*) return 1 ;;   # has a slash after /tmp/<name> -> not top-level
    /tmp/*)   return 0 ;;
    *)        return 1 ;;
  esac
}

# Map an arbitrary already-vetted path to its predicate (for the action-time re-vet).
# Most specific first; the /tmp branch is restricted to genuine top-level /tmp entries.
predicate_for_path() {
  local p="$1"
  if   [[ "$p" == *"/.cache/ms-playwright"* || "$p" == *"/.cache/puppeteer"* || "$p" == *"/.cache/huggingface"* ]]; then printf 'pat_redownloadable'
  elif [[ "$p" == *"/.local/share/Trash" || "$p" == *"/.local/share/Trash/"* ]]; then printf 'pat_trash'
  elif [[ "$p" == *"/.pytest_cache" || "$p" == *"/.mypy_cache" || "$p" == *"/.ruff_cache" ]]; then printf 'pat_loose_toolcache'
  elif [[ "${p##*/}" == core.[0-9]* ]]; then printf 'pat_core_dump'
  elif _is_tmp_toplevel "$p"; then printf 'pat_tmp_old'
  else printf 'pat_tier0_cache'; fi
}

deep_for_path() {
  local p="$1"
  if   _is_tmp_toplevel "$p"; then printf 'deep'
  elif [[ "$p" == *"/.pytest_cache" || "$p" == *"/.mypy_cache" || "$p" == *"/.ruff_cache" ]]; then printf 'deep'
  else printf ''; fi
}

# ============================================================================================
# PHASE 1: build the project graph (the protected set), BEFORE classifying any waste.
# ============================================================================================
build_project_graph() {
  [[ "$JSON_OUT" -eq 1 ]] || info "${c_cya}==> Phase 1: discovering projects and dependencies...${c_reset}" >&2

  local root marker_path proj_dir rp
  for root in "${SCAN_ROOTS[@]}"; do
    # File markers (package.json, pyproject.toml, ...), pruning store/cache/vendored trees.
    while IFS= read -r -d '' marker_path; do
      proj_dir="$(dirname -- "$marker_path")"
      rp="$(realpath -e -- "$proj_dir" 2>/dev/null || true)"
      [[ -n "$rp" ]] || continue
      { under_scan_root "$rp" || [[ "$rp" == "$root" ]]; } || continue
      [[ -n "${PROJECT_ROOTS[$rp]+x}" ]] && continue
      PROJECT_ROOTS["$rp"]="$(project_type "$rp")"
    done < <(
      find -P "$root" -xdev \
        \( "${FIND_DISCOVERY_PRUNE_EXPR[@]}" \) -prune -o \
        -type l -prune -o \
        -type f \( "${FIND_MARKER_EXPR[@]}" \) -print0 2>/dev/null
    )
    # .git directories mark a project root too (prune node_modules/.cache so vendored repos
    # don't flood the graph, but still capture the dir that CONTAINS each .git).
    while IFS= read -r -d '' marker_path; do
      proj_dir="$(dirname -- "$marker_path")"
      rp="$(realpath -e -- "$proj_dir" 2>/dev/null || true)"
      [[ -n "$rp" ]] || continue
      { under_scan_root "$rp" || [[ "$rp" == "$root" ]]; } || continue
      [[ -n "${PROJECT_ROOTS[$rp]+x}" ]] && continue
      PROJECT_ROOTS["$rp"]="$(project_type "$rp")"
    done < <(
      find -P "$root" -xdev \
        \( "${FIND_GIT_PRUNE_EXPR[@]}" \) -prune -o \
        -type d -name .git -print0 2>/dev/null
    )
  done

  # For each project, record its TOP-LEVEL regenerable dependency/build dirs (Tier-1). Prune
  # at the first dep-dir hit so nested dep dirs (node_modules/foo/dist) are not listed twice.
  local proj dep name restore
  for proj in "${!PROJECT_ROOTS[@]}"; do
    while IFS= read -r -d '' dep; do
      [[ -L "$dep" ]] && continue
      rp="$(realpath -e -- "$dep" 2>/dev/null || true)"
      [[ -n "$rp" ]] || continue
      under_scan_root "$rp" || continue
      # Do NOT pass "deep" here: dep dirs (node_modules/.venv) legitimately contain markers.
      is_protected "$rp" && continue
      [[ -n "${PROTECTED_DEP_DIRS[$rp]+x}" ]] && continue
      name="${rp##*/}"
      restore="$(restore_command "${PROJECT_ROOTS[$proj]}" "$name" "$proj")"
      PROTECTED_DEP_DIRS["$rp"]="$restore"
    done < <(
      find -P "$proj" -xdev -mindepth 1 \
        \( "${FIND_PRUNE_EXPR[@]}" \) -prune -o \
        -type l -prune -o \
        -type d \( "${FIND_DEP_EXPR[@]}" \) -prune -print0 2>/dev/null
    )
  done

  [[ "$JSON_OUT" -eq 1 ]] || info "${c_cya}    found ${#PROJECT_ROOTS[@]} project(s), ${#PROTECTED_DEP_DIRS[@]} regenerable dep dir(s).${c_reset}" >&2
}

project_type() {
  local d="$1"
  [[ -f "$d/package.json" ]] && { printf 'node';   return; }
  [[ -f "$d/Cargo.toml" ]]   && { printf 'rust';   return; }
  [[ -f "$d/go.mod" ]]       && { printf 'go';      return; }
  [[ -f "$d/pyproject.toml" || -f "$d/requirements.txt" || -f "$d/setup.py" || -f "$d/Pipfile" ]] \
                             && { printf 'python'; return; }
  printf 'generic'
}

restore_command() {
  local ptype="$1" depname="$2" proj="$3"
  case "$depname" in
    node_modules)
      if [[ -f "$proj/package-lock.json" ]]; then printf '(cd %q && npm ci)' "$proj"
      else printf '(cd %q && npm install)  # or pnpm install / yarn install' "$proj"; fi ;;
    .venv|venv|env|virtualenv)
      if [[ -f "$proj/requirements.txt" ]]; then
        printf '(cd %q && python -m venv %s && %s/bin/pip install -r requirements.txt)' "$proj" "$depname" "$depname"
      elif [[ -f "$proj/pyproject.toml" ]]; then
        printf '(cd %q && python -m venv %s && %s/bin/pip install -e .)' "$proj" "$depname" "$depname"
      else
        printf '(cd %q && python -m venv %s)' "$proj" "$depname"
      fi ;;
    target) printf '(cd %q && cargo build)' "$proj" ;;
    build|dist|.next|.nuxt|.svelte-kit|out)
      case "$ptype" in
        node) printf '(cd %q && npm run build)' "$proj" ;;
        rust) printf '(cd %q && cargo build)' "$proj" ;;
        *)    printf '# rebuild via the project build step (cd %q)' "$proj" ;;
      esac ;;
    __pycache__|.pytest_cache|.mypy_cache|.ruff_cache|.tox|.gradle|.turbo)
      printf '# regenerates automatically on next run' ;;
    vendor) printf '# regenerate via the project dependency install step' ;;
    *) printf '# regenerate via the project normal build/install' ;;
  esac
}

# Concrete restore command for a toolchain version store (largest Tier-1 items).
toolchain_restore() {
  local store="$1" base="${1##*/}"
  case "$store" in
    *"/.local/share/fnm")
      printf '# list/keep what you need: `fnm ls`; reinstall a version with `fnm install <version>` (or `fnm install --lts`)' ;;
    *"/.nvm/versions")
      printf '# reinstall a version with `nvm install <version>` (or `nvm install --lts`); see `nvm ls`' ;;
    *"/.rustup/toolchains")
      printf '# reinstall with `rustup toolchain install <name>` (e.g. stable); see `rustup toolchain list`' ;;
    *) printf '# re-install the pinned toolchain version(s) you use' ;;
  esac
}

# ============================================================================================
# PHASE 2: classify reclaimable items via the rule table + toolchain stores.
# Global dedup ensures a path is recorded at most once across all tiers.
# ============================================================================================
_seen() { [[ -n "${SEEN_ITEMS[$1]:-}" ]] && return 0; SEEN_ITEMS["$1"]=1; return 1; }

record_tier0()      { _seen "$1" && return 0; local b; b="$(path_bytes "$1")"; TIER0_ITEMS+=("$b"$'\t'"$1"$'\t'"$2");     TIER0_TOTAL=$((TIER0_TOTAL + b)); }
record_tier1()      { _seen "$1" && return 0; local b; b="$(path_bytes "$1")"; TIER1_DEP_ITEMS+=("$b"$'\t'"$1"$'\t'"$2"); TIER1_TOTAL=$((TIER1_TOTAL + b)); }
record_redownload() { _seen "$1" && return 0; local b; b="$(path_bytes "$1")"; REDOWNLOAD_ITEMS+=("$b"$'\t'"$1"$'\t'"$2"); REDOWNLOAD_TOTAL=$((REDOWNLOAD_TOTAL + b)); }

classify() {
  [[ "$JSON_OUT" -eq 1 ]] || info "${c_cya}==> Phase 2: classifying reclaimable items...${c_reset}" >&2

  # --- Tier-1: project dependency/build dirs (report only, restore cmd) ---
  local dep
  for dep in "${!PROTECTED_DEP_DIRS[@]}"; do
    record_tier1 "$dep" "restore: ${PROTECTED_DEP_DIRS[$dep]}"
  done

  # --- Tier-1: language/runtime version stores (project-owned, regenerable, never auto) ---
  local base v
  for base in "${CACHE_BASES[@]}"; do
    for v in "$base/.local/share/fnm" "$base/.nvm/versions" "$base/.rustup/toolchains"; do
      [[ -d "$v" && ! -L "$v" ]] && record_tier1 "$v" "restore: $(toolchain_restore "$v")"
    done
  done

  # --- Tier-0 + redownloadable: walk the RULE TABLE through the triple gate ---
  local rule tier label scanner glob restore note cand pred deep
  for rule in "${RULES[@]}"; do
    # label/glob are unpacked for readability/documentation; logic uses scanner+predicate.
    # shellcheck disable=SC2034
    IFS='|' read -r tier label scanner glob restore note <<<"$rule"
    pred="$(predicate_for_scanner "$scanner")"
    deep="$(deep_for_scanner "$scanner")"
    while IFS= read -r -d '' cand; do
      [[ -n "$cand" ]] || continue
      # NOTE: not a command substitution -> SKIPPED_ITEMS mutations persist (audit trail).
      if vet_candidate "$cand" "$pred" "" "$deep"; then
        case "$tier" in
          tier0)          record_tier0 "$VETTED_RP" "$note (restore: $restore)" ;;
          redownloadable) record_redownload "$VETTED_RP" "$note (restore: $restore)" ;;
        esac
      fi
    done < <("$scanner")
  done
}

# ============================================================================================
# Reporting
# ============================================================================================
df_summary() {
  info "${c_bold}== Filesystem usage (Linux root only; /mnt excluded) ==${c_reset}"
  df -h -x tmpfs -x devtmpfs / 2>/dev/null || df -h /
  info ""
}

du_summary() {
  [[ "$TOP_N" -gt 0 ]] || return 0
  local root
  for root in "${SCAN_ROOTS[@]}"; do
    info "${c_bold}== Top ${TOP_N} directories in ${root} (local fs only) ==${c_reset}"
    # Drop the root's own total line so --top N shows N CHILDREN, not N-1.
    du -x -h --max-depth=1 --exclude='*/.git' "$root" 2>/dev/null \
      | awk -v root="$root" '$2 != root' \
      | sort -rh | head -n "$TOP_N" | sed 's/^/  /'
    info ""
  done
}

print_projects() {
  info "${c_bold}== Detected projects (${#PROJECT_ROOTS[@]}) ==${c_reset}"
  if (( ${#PROJECT_ROOTS[@]} == 0 )); then info "  (none)"; info ""; return; fi
  local p
  for p in "${!PROJECT_ROOTS[@]}"; do printf '  %-9s %s\n' "[${PROJECT_ROOTS[$p]}]" "$p"; done | sort -k2
  info ""
}

# Print a tier group. Sorts by size descending using NUL-delimited records so paths with
# embedded TAB/newline are not split across lines.
print_group() {
  local title="$1" total="$2"; shift 2
  local -a items=("$@")
  info "${c_bold}${title}${c_reset}  ${c_grn}(total: $(human "$total"))${c_reset}"
  if [[ ${#items[@]} -eq 0 ]]; then info "  (none)"; info ""; return 0; fi
  local rec b path note rest
  # Build NUL-joined records, sort numeric-desc on the leading byte field (also NUL-delimited).
  while IFS= read -r -d '' rec; do
    [[ -n "$rec" ]] || continue
    b="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"
    path="${rest%%$'\t'*}"; note="${rest#*$'\t'}"
    printf '  %8s  %s\n' "$(human "$b")" "$path"
    [[ -n "$note" && "$note" != "$path" ]] && printf '            %s|- %s%s\n' "$c_blu" "$note" "$c_reset"
  done < <(
    { local x; for x in "${items[@]}"; do printf '%s\0' "$x"; done; } | sort -z -t$'\t' -k1,1nr
  )
  info ""
}

report_text() {
  df_summary
  du_summary
  print_projects
  print_group "== Tier-0: SAFE waste (eligible for --delete/--purge) ==" "$TIER0_TOTAL" ${TIER0_ITEMS[@]+"${TIER0_ITEMS[@]}"}
  print_group "== Tier-1: PROJECT deps/builds (NEVER auto-removed; restore cmd shown) ==" "$TIER1_TOTAL" ${TIER1_DEP_ITEMS[@]+"${TIER1_DEP_ITEMS[@]}"}
  print_group "== Re-downloadable (LARGE, SLOW to refetch; opt-in: --include-redownloadable) ==" "$REDOWNLOAD_TOTAL" ${REDOWNLOAD_ITEMS[@]+"${REDOWNLOAD_ITEMS[@]}"}

  if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
    info "${c_yel}== Refused by a safety gate (looked reclaimable; reported, NOT touched) ==${c_reset}"
    local rec path note rest
    while IFS= read -r -d '' rec; do
      [[ -n "$rec" ]] || continue
      rest="${rec#*$'\t'}"; path="${rest%%$'\t'*}"; note="${rest#*$'\t'}"
      printf '  %s  %s(%s)%s\n' "$path" "$c_yel" "$note" "$c_reset"
    done < <( { local x; for x in "${SKIPPED_ITEMS[@]}"; do printf '%s\0' "$x"; done; } )
    info ""
  fi

  local projected=$TIER0_TOTAL
  [[ "$INCLUDE_REDOWNLOADABLE" -eq 1 ]] && projected=$((projected + REDOWNLOAD_TOTAL))
  info "${c_bold}== Projected reclaim ==${c_reset}"
  info "  Tier-0 (default action):           ${c_grn}$(human "$TIER0_TOTAL")${c_reset}  (${#TIER0_ITEMS[@]} item(s))"
  if [[ "$INCLUDE_REDOWNLOADABLE" -eq 1 ]]; then
    info "  + Re-downloadable (opted in):      $(human "$REDOWNLOAD_TOTAL")  (${#REDOWNLOAD_ITEMS[@]} item(s))"
  else
    info "  Re-downloadable (NOT counted):     $(human "$REDOWNLOAD_TOTAL")  ${c_dim}(use --include-redownloadable)${c_reset}"
  fi
  info "  Tier-1 (manual only, not counted): $(human "$TIER1_TOTAL")  ${c_dim}(${#TIER1_DEP_ITEMS[@]} item(s); never auto-removed)${c_reset}"
  info "  ${c_bold}Eligible this run:                 ${c_grn}$(human "$projected")${c_reset}"
  info ""
  if [[ "$DO_DELETE" -eq 0 ]]; then
    info "${c_yel}DRY RUN: nothing changed. Re-run with --delete to MOVE Tier-0 to quarantine"
    info "(reversible), or --purge to delete irreversibly.${c_reset}"
  fi
}

json_escape() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_json_array() {
  local -a items=("$@")
  local first=1 line b path note rest
  printf '['
  for line in ${items[@]+"${items[@]}"}; do
    b="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    path="${rest%%$'\t'*}"; note="${rest#*$'\t'}"
    [[ "$note" == "$path" ]] && note=""
    [[ $first -eq 1 ]] && first=0 || printf ','
    printf '{"bytes":%s,"path":"%s","note":"%s"}' "$b" "$(json_escape "$path")" "$(json_escape "$note")"
  done
  printf ']'
}

report_json() {
  printf '{'
  printf '"version":"%s",' "$VERSION"
  printf '"dry_run":%s,' "$([[ $DO_DELETE -eq 0 ]] && echo true || echo false)"
  printf '"mode":"%s",' "$([[ $DO_PURGE -eq 1 ]] && echo purge || echo quarantine)"
  printf '"quarantine_root":"%s",' "$(json_escape "$QUARANTINE_DIR")"
  printf '"include_tmp":%s,' "$([[ $INCLUDE_TMP -eq 1 ]] && echo true || echo false)"
  printf '"scan_roots":['
  local i=0 r p
  for r in "${SCAN_ROOTS[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '"%s"' "$(json_escape "$r")"; i=$((i+1)); done
  printf '],'
  printf '"projects":['
  i=0
  for p in "${!PROJECT_ROOTS[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    printf '{"path":"%s","type":"%s"}' "$(json_escape "$p")" "${PROJECT_ROOTS[$p]}"; i=$((i+1))
  done
  printf '],'
  printf '"tier0":';          emit_json_array ${TIER0_ITEMS[@]+"${TIER0_ITEMS[@]}"};         printf ','
  printf '"tier1":';          emit_json_array ${TIER1_DEP_ITEMS[@]+"${TIER1_DEP_ITEMS[@]}"};  printf ','
  printf '"redownloadable":'; emit_json_array ${REDOWNLOAD_ITEMS[@]+"${REDOWNLOAD_ITEMS[@]}"}; printf ','
  printf '"refused":';        emit_json_array ${SKIPPED_ITEMS[@]+"${SKIPPED_ITEMS[@]}"};      printf ','
  printf '"totals":{"tier0_bytes":%s,"tier1_bytes":%s,"redownloadable_bytes":%s}' \
    "$TIER0_TOTAL" "$TIER1_TOTAL" "$REDOWNLOAD_TOTAL"
  printf '}\n'
}

# ============================================================================================
# Action: quarantine (default) or purge (Tier-0, plus Re-DL iff opted in). Every target is
# RE-VETTED through the full triple gate immediately before the action (TOCTOU defense).
# ============================================================================================
confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  if [[ ! -t 0 && ! -e /dev/tty ]]; then
    warn "No TTY for confirmation and --yes not given; aborting (no changes)."
    return 1
  fi
  local prompt="$1" ans
  printf '%s [y/N] ' "$prompt" >&2
  read -r ans </dev/tty 2>/dev/null || ans=""
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" || "$ans" == "YES" ]]
}

# Re-vet a path with its category predicate right before acting. Returns 0 only if the path
# still passes the full triple gate AND its realpath is stable (== the path we collected).
revet_for_action() {
  local path="$1" fn deep
  fn="$(predicate_for_path "$path")"
  deep="$(deep_for_path "$path")"
  # quiet (no audit double-counting); deep where the original collection used deep.
  vet_candidate "$path" "$fn" quiet "$deep" || return 1
  [[ "$VETTED_RP" == "$path" ]] || return 1
  # Loose tool caches must STILL be outside any project at action time.
  if [[ "$fn" == "pat_loose_toolcache" ]]; then
    inside_a_project "$path" && return 1
  fi
  return 0
}

do_action() {
  [[ "$DO_DELETE" -eq 1 ]] || return 0

  # Build the action list: Tier-0 always; Re-DL only if opted in.
  local -a action_paths=()
  local line path rest
  for line in ${TIER0_ITEMS[@]+"${TIER0_ITEMS[@]}"}; do
    rest="${line#*$'\t'}"; path="${rest%%$'\t'*}"; action_paths+=("$path")
  done
  if [[ "$INCLUDE_REDOWNLOADABLE" -eq 1 ]]; then
    for line in ${REDOWNLOAD_ITEMS[@]+"${REDOWNLOAD_ITEMS[@]}"}; do
      rest="${line#*$'\t'}"; path="${rest%%$'\t'*}"; action_paths+=("$path")
    done
  fi

  if [[ ${#action_paths[@]} -eq 0 ]]; then
    info "${c_grn}Nothing eligible to reclaim.${c_reset}"; return 0
  fi

  local verb mode
  if [[ "$DO_PURGE" -eq 1 ]]; then verb="${c_red}IRREVERSIBLY DELETE${c_reset}"; mode="purge"
  else verb="MOVE to quarantine"; mode="quarantine"; fi
  info ""
  info "${c_bold}About to ${verb} ${#action_paths[@]} item(s) (mode: ${mode}).${c_reset}"
  local p
  for p in "${action_paths[@]}"; do info "  target: $p"; done
  if ! confirm "Proceed?"; then
    info "${c_yel}Aborted. Nothing changed.${c_reset}"; return 0
  fi

  # Prepare the quarantine target (no-op for purge).
  local quar_base="" manifest=""
  if [[ "$DO_PURGE" -eq 0 ]]; then
    quar_base="$QUARANTINE_DIR/$(date +%Y%m%d-%H%M%S)-$$"
    # The quarantine DESTINATION is validated as a destination (not as an action target):
    # it must live strictly under the already-vetted QUARANTINE_DIR (which parse_args proved
    # is not "/", not a system mount, and -- unless it is the safe default -- not inside any
    # scan root). We do NOT run the is_protected denylist here: that gate is for SOURCES, and
    # the safe default quarantine intentionally lives under $LOG_DIR (which is_protected
    # rejects as a SOURCE). This is the fix for the always-fatal default --delete.
    case "$quar_base" in
      "$QUARANTINE_DIR"/*) : ;;
      *) die "Refusing quarantine into a path outside the validated quarantine root: $quar_base" ;;
    esac
    mkdir -p "$quar_base" || die "Cannot create quarantine dir: $quar_base"
    manifest="$quar_base/RESTORE.txt"
    {
      printf '# disk-cleanup quarantine manifest -- %s\n' "$(date -Is 2>/dev/null || date)"
      printf '# Restore an item by moving the quarantined copy back to its ORIGINAL path.\n'
      printf '# Free the space for good with:  rm -rf -- %q\n' "$quar_base"
      printf '# Format: <quarantined_copy>\\t<original_path>\n\n'
    } >"$manifest" || die "Cannot write quarantine manifest: $manifest (reversibility would be lost; aborting)."
  fi

  local rel dest acted=0
  for p in "${action_paths[@]}"; do
    # FINAL re-vet through the full triple gate immediately before touching anything.
    if ! revet_for_action "$p"; then
      warn "Skipping (failed final safety re-check): $p"; continue
    fi
    if [[ "$DO_PURGE" -eq 1 ]]; then
      printf '%s  rm -rf -- %q\n' "${c_red}[PURGE]${c_reset}" "$p"
      if rm -rf -- "$p" 2>/dev/null; then log_action "PURGE	$p"; acted=$((acted+1))
      else warn "rm failed: $p"; fi
    else
      rel="${p#/}"; dest="$quar_base/$rel"
      # Collision guard: never merge into / clobber an existing destination subtree.
      if [[ -e "$dest" ]]; then
        warn "Quarantine destination already exists; skipping to avoid clobber: $dest"; continue
      fi
      mkdir -p "$(dirname -- "$dest")" 2>/dev/null || { warn "mkdir failed; skipping: $p"; continue; }
      printf '%s  mv -- %q %q\n' "${c_grn}[QUARANTINE]${c_reset}" "$p" "$dest"
      # mv -n (no-clobber) belt-and-braces with the -e guard above.
      if mv -n -- "$p" "$dest" 2>/dev/null && [[ ! -e "$p" ]]; then
        if ! printf '%s\t%s\n' "$dest" "$p" >>"$manifest" 2>/dev/null; then
          die "Manifest write failed mid-run; aborting to preserve reversibility (already-moved items are under $quar_base)."
        fi
        log_action "QUARANTINE	$p	-> $dest"; acted=$((acted+1))
      else
        # Cross-device copy that failed mid-flight leaves a partial dest; clean it so the
        # quarantine never accrues orphaned, unmapped junk. Source is left intact.
        rm -rf -- "$dest" 2>/dev/null || true
        warn "mv failed (left in place; cleaned partial quarantine copy): $p"
      fi
    fi
  done

  info ""
  if [[ "$DO_PURGE" -eq 1 ]]; then
    info "${c_grn}Done. Purged ${acted} item(s) (irreversible).${c_reset}"
  else
    info "${c_grn}Done. Moved ${acted} item(s) to quarantine:${c_reset} $quar_base"
    info "Restore mapping: $manifest"
    info "When you are sure, free the space for good with:  rm -rf -- $(printf '%q' "$quar_base")"
  fi
  info "Action log: ${LOG_FILE}"
}

# ============================================================================================
# main
# ============================================================================================
main() {
  parse_args "$@"

  # Sanity: required tools.
  local t
  for t in find du df realpath sort awk date dirname id; do
    command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
  done

  init_find_exprs
  build_project_graph
  classify

  if [[ "$JSON_OUT" -eq 1 ]]; then
    report_json
    exit 0
  fi

  report_text
  do_action
}

main "$@"