#!/usr/bin/env zsh
# Functional tests for lumen.plugin.zsh's matching layer.
#
#   zsh -f -i shell/tests/run.zsh
#
# -i because the plugin no-ops entirely unless the shell is interactive
# (`[[ -o interactive ]] || return` at the top of the plugin); -f to skip
# the developer's own ~/.zshrc. CI runs exactly this line on Linux — the
# matching layer is portable zsh with no macOS or companion-app dependency,
# so `zsh -n` (syntax only) was the whole safety net before this.
#
# Adding a test: drop a `cases/<name>.zsh` file that defines one function
# `case_<name>`. The runner sources it and calls that function with a clean
# BUFFER, reset candidate arrays, and cwd back at the repo root.

_LUMEN_TEST_DIR=${0:A:h}
_LUMEN_REPO=${_LUMEN_TEST_DIR:h:h}

# No network, no update prompt at source time; never reach for the overlay
# socket. Matching itself is unaffected by either.
export LUMEN_UPDATE_CHECK=0
export LUMEN_OVERLAY=0

source "$_LUMEN_REPO/shell/zsh/lumen.plugin.zsh" || {
  print -u2 -- "run.zsh: could not source the plugin (interactive shell? use: zsh -f -i)"
  exit 2
}

typeset -gi _LUMEN_ASSERTS=0 _LUMEN_FAILURES=0
typeset -g  _LUMEN_CASE=""

fail() {
  print -u2 -- "  ✗ ${_LUMEN_CASE}: $1"
  (( _LUMEN_FAILURES++ ))
}

# assert_eq <expected> <actual> [label]
assert_eq() {
  (( _LUMEN_ASSERTS++ ))
  [[ "$1" == "$2" ]] || fail "${3:-assert_eq} — expected [$1], got [$2]"
}

# assert_ok <status> [label]   — status is 0
assert_ok() {
  (( _LUMEN_ASSERTS++ ))
  (( $1 == 0 )) || fail "${2:-assert_ok} — expected match (status 0), got $1"
}

# assert_fail <status> [label] — status is non-zero
assert_fail() {
  (( _LUMEN_ASSERTS++ ))
  (( $1 != 0 )) || fail "${2:-assert_fail} — expected no match (non-zero), got 0"
}

# assert_has <needle> <item>...  — needle is one of the items exactly
assert_has() {
  (( _LUMEN_ASSERTS++ ))
  local needle=$1; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  fail "expected [$needle] among: ${*:-<none>}"
}

# assert_lacks <needle> <item>...
assert_lacks() {
  (( _LUMEN_ASSERTS++ ))
  local needle=$1; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && { fail "did not expect [$needle] among: $*"; return }
  done
}

integer _found=0
for _case in "$_LUMEN_TEST_DIR"/cases/*.zsh(N); do
  _found=1
  _LUMEN_CASE=${_case:t:r}
  source "$_case"
  cd "$_LUMEN_REPO"
  BUFFER=""
  _lumen_reset_candidates
  "case_${_LUMEN_CASE}"
done
cd "$_LUMEN_REPO"

(( _found )) || { print -u2 -- "run.zsh: no cases/*.zsh found"; exit 2 }

print
if (( _LUMEN_FAILURES )); then
  print -u2 -- "FAILED — $_LUMEN_FAILURES of $_LUMEN_ASSERTS assertions"
  exit 1
fi
print -- "ok — $_LUMEN_ASSERTS assertions passed"
