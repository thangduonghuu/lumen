# _lumen_static_match / _lumen_nested_match via the real dispatcher —
# subcommand and flag tables filter by the partial word, back off once the
# argument is free-form, and tag the dangerous flags.
case_static_match() {
  BUFFER="git ch"
  _lumen_static_or_dynamic_match
  assert_ok $? 'git ch -> match'
  assert_has checkout     "${_LUMEN_LABELS[@]}"
  assert_has cherry-pick  "${_LUMEN_LABELS[@]}"
  assert_lacks push       "${_LUMEN_LABELS[@]}"

  # Per-subcommand flag table, and --force / --force-with-lease both carry
  # the danger tag the overlay uses to mark a row.
  BUFFER="git push --force"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --force            "${_LUMEN_LABELS[@]}"
  assert_has --force-with-lease "${_LUMEN_LABELS[@]}"
  local d
  for d in "${_LUMEN_DANGER[@]}"; do assert_eq 1 "$d" '--force* tagged dangerous'; done

  # Once the subcommand has its own argument, the subcommand table has
  # nothing to say — no stale candidates.
  BUFFER="git checkout somefile "
  _lumen_reset_candidates
  _lumen_static_match
  assert_fail $? 'past the subcommand -> _lumen_static_match backs off'

  # Unknown tool: no match, arrays stay empty.
  BUFFER="frobnicate wamble"
  _lumen_reset_candidates
  _lumen_static_match
  assert_fail $? 'unknown tool -> no match'
  assert_eq 0 ${#_LUMEN_LABELS} 'unknown tool -> zero candidates'

  # A flag past a positional arg still finds the verb's own flags table —
  # _lumen_nested_match's key lookup drops trailing positional words
  # (branch/container/package name, ...) instead of only matching when the
  # flag sits immediately after the verb.
  BUFFER="git checkout main -f"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -f "${_LUMEN_LABELS[@]}"

  BUFFER="docker restart mycontainer -t"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -t "${_LUMEN_LABELS[@]}"

  BUFFER="npm install lodash --save"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --save-dev "${_LUMEN_LABELS[@]}"

  # No matching flags table at any prefix length -> generic fallback, not
  # a crash or stale candidates from a shorter unrelated key.
  BUFFER="git status --"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --help "${_LUMEN_LABELS[@]}"
}
