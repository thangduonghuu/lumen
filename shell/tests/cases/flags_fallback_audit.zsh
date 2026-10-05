# Regression tests for a broad audit: every tool/verb pair that takes a
# positional arg (resource, container, package, version, ...) but had no
# dedicated *_FLAGS table, so once that arg was typed, suggestions fell
# back to the generic top-level -h/--help list — or, for the tools caught
# by the second bug below, to nothing at all. One or two assertions per
# tool, proving the table is wired up through the real dispatcher, not
# full flag-by-flag coverage (see nested_match_extra.zsh for the established
# pattern this follows).
case_flags_fallback_audit() {
  # The more severe half of the audit: pip/brew/go/gem/poetry/bundle/nvm/
  # pyenv/rbenv/nx/turbo/minikube/dotnet/heroku/vercel/firebase/flyctl were
  # missing from _lumen_nested_match's tool whitelist entirely (same class
  # of bug as the az case in nested_match_extra.zsh), so *no* flags table
  # for these tools was ever reachable — worse than the generic fallback,
  # since _lumen_version_manager_match/_lumen_brew_match back off once a
  # flag starts, leaving nothing to pick up the slack. Confirms the
  # whitelist fix, not just the tables themselves.
  BUFFER="pip install requests "
  _lumen_static_or_dynamic_match
  assert_has -U "${_LUMEN_LABELS[@]}"

  BUFFER="brew install wget "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --cask "${_LUMEN_LABELS[@]}"

  BUFFER="go get github.com/foo/bar "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -u "${_LUMEN_LABELS[@]}"

  BUFFER="nvm install 20 "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --lts "${_LUMEN_LABELS[@]}"

  BUFFER="pyenv local 3.12 "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --unset "${_LUMEN_LABELS[@]}"

  BUFFER="nx generate component "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --dry-run "${_LUMEN_LABELS[@]}"

  BUFFER="dotnet new console "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -o "${_LUMEN_LABELS[@]}"

  BUFFER="vercel rm myapp "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -y "${_LUMEN_LABELS[@]}"

  # --- tools that were already in the whitelist, just missing per-verb
  # tables for these specific positional-arg verbs ---------------------

  BUFFER="kubectl cordon node-1 "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -l "${_LUMEN_LABELS[@]}"
  BUFFER="kubectl rollout history deploy/web "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --revision "${_LUMEN_LABELS[@]}"

  BUFFER="docker network create mynet "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -d "${_LUMEN_LABELS[@]}"
  BUFFER="docker container restart web1 "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -t "${_LUMEN_LABELS[@]}"

  BUFFER="git blame README.md "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -L "${_LUMEN_LABELS[@]}"
  BUFFER="git remote add origin "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -f "${_LUMEN_LABELS[@]}"

  BUFFER="terraform import aws_instance.x i-123 "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -var "${_LUMEN_LABELS[@]}"

  BUFFER="helm status myrelease "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -n "${_LUMEN_LABELS[@]}"

  BUFFER="gh issue close 42 "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -c "${_LUMEN_LABELS[@]}"

  BUFFER="glab mr checkout 7 "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -b "${_LUMEN_LABELS[@]}"

  BUFFER="aws s3 cp file s3://bucket/ "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --recursive "${_LUMEN_LABELS[@]}"

  BUFFER="cargo add serde "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --dev "${_LUMEN_LABELS[@]}"

  BUFFER="systemctl start nginx "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --now "${_LUMEN_LABELS[@]}"
}
