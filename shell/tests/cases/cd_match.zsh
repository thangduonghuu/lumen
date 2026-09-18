# _lumen_cd_match — directories only, case-insensitive, trailing slash on
# the label so accepting one leaves the cursor ready to keep drilling.
case_cd_match() {
  local d
  d=$(mktemp -d)
  cd "$d"
  mkdir Documents Downloads projects
  touch notes.txt

  BUFFER="cd Do"
  _lumen_reset_candidates
  _lumen_cd_match
  assert_ok $? 'cd Do -> match'
  assert_has Documents/ "${_LUMEN_LABELS[@]}"
  assert_has Downloads/ "${_LUMEN_LABELS[@]}"

  # Case-insensitive: lowercase query still finds the capitalised dirs.
  BUFFER="cd do"
  _lumen_reset_candidates
  _lumen_cd_match
  assert_has Documents/ "${_LUMEN_LABELS[@]}"

  # A file that matches the prefix is never offered — cd takes dirs only.
  BUFFER="cd not"
  _lumen_reset_candidates
  _lumen_cd_match
  assert_fail $? 'cd not -> notes.txt (a file) is not a candidate'

  # Not the cd command.
  BUFFER="cdr Do"
  _lumen_reset_candidates
  _lumen_cd_match
  assert_fail $? 'cdr is not cd'

  rm -rf "$d"
}
