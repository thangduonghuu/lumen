# _lumen_rm_match — the safety-sensitive one. It must only offer curated
# junk that is ACTUALLY on disk, only once flags are done and a path slot
# is open, and it must still honour the partial the user typed.
case_rm_match() {
  local d
  d=$(mktemp -d)
  cd "$d"
  mkdir node_modules dist src
  touch app.log README.md

  BUFFER="rm -rf "
  _lumen_reset_candidates
  _lumen_rm_match
  assert_ok $? 'rm -rf <space> -> match'
  assert_has node_modules "${_LUMEN_LABELS[@]}"
  assert_has dist         "${_LUMEN_LABELS[@]}"
  # Curated patterns NOT present on disk must never be offered.
  assert_lacks target  "${_LUMEN_LABELS[@]}"
  assert_lacks .gradle "${_LUMEN_LABELS[@]}"

  # Still mid-flag, no path slot yet -> nothing.
  BUFFER="rm -r"
  _lumen_reset_candidates
  _lumen_rm_match
  assert_fail $? 'rm -r (no trailing space) -> no suggestions'

  # No flags at all -> not our case.
  BUFFER="rm somefile"
  _lumen_reset_candidates
  _lumen_rm_match
  assert_fail $? 'rm without a flag -> no suggestions'

  # Partial word filters the list.
  BUFFER="rm -rf nod"
  _lumen_reset_candidates
  _lumen_rm_match
  assert_has  node_modules "${_LUMEN_LABELS[@]}"
  assert_lacks dist        "${_LUMEN_LABELS[@]}"

  rm -rf "$d"
}
