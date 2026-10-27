# Spot-checks for the go subcommand/flag tables: top-level verbs, the
# nested "go mod"/"go work" sub-subcommands, and per-verb flags reached
# through _lumen_nested_match (including after a positional arg).
case_go_match() {
  BUFFER="go ver"
  _lumen_static_or_dynamic_match
  assert_has version "${_LUMEN_LABELS[@]}"

  BUFFER="go mod "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has why "${_LUMEN_LABELS[@]}"

  BUFFER="go work "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has sync "${_LUMEN_LABELS[@]}"

  BUFFER="go build -"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -ldflags "${_LUMEN_LABELS[@]}"
  assert_has -o "${_LUMEN_LABELS[@]}"

  BUFFER="go test ./... -"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -run "${_LUMEN_LABELS[@]}"
  assert_has -race "${_LUMEN_LABELS[@]}"

  BUFFER="go mod tidy -"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -compat "${_LUMEN_LABELS[@]}"

  BUFFER="go clean -"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -modcache "${_LUMEN_LABELS[@]}"

  # -o belongs to build/test, not run.
  BUFFER="go run main.go -"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -exec "${_LUMEN_LABELS[@]}"
  assert_lacks -o "${_LUMEN_LABELS[@]}"
}
