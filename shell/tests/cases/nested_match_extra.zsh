# Spot-checks for the az/gcloud/aws/gh/glab/cargo/helm/terraform/pulumi/
# vagrant/systemctl depth added on top of _lumen_nested_match — one or two
# assertions per tool to prove the table is actually wired up (right name,
# reachable through the real dispatcher), not full flag-by-flag coverage.
case_nested_match_extra() {
  # az was missing from _lumen_nested_match's tool whitelist entirely, so
  # every az table below used to be unreachable no matter how complete it
  # was — this also doubles as a regression check for that whitelist entry.
  BUFFER="az vm "
  _lumen_static_or_dynamic_match
  assert_has create "${_LUMEN_LABELS[@]}"
  BUFFER="az vm create --i"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --image "${_LUMEN_LABELS[@]}"
  # Three levels deep: tool + "storage" + "account" + "create".
  BUFFER="az storage account create --s"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --sku "${_LUMEN_LABELS[@]}"

  BUFFER="gcloud compute instances create --z"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --zone "${_LUMEN_LABELS[@]}"
  BUFFER="gcloud container clusters get-credentials --r"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --region "${_LUMEN_LABELS[@]}"

  BUFFER="aws ec2 describe-instances --f"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --filters "${_LUMEN_LABELS[@]}"

  BUFFER="gh release create --d"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --draft "${_LUMEN_LABELS[@]}"
  BUFFER="gh workflow run --r"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --ref "${_LUMEN_LABELS[@]}"

  BUFFER="glab mr create --t"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --title "${_LUMEN_LABELS[@]}"

  # cargo run/test alias cargo build's flags table — adding a flag there
  # should reach all three without redefining anything.
  BUFFER="cargo test --p"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --package "${_LUMEN_LABELS[@]}"

  BUFFER="helm install myrel chart/ --c"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --create-namespace "${_LUMEN_LABELS[@]}"
  BUFFER="helm uninstall myrel --k"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --keep-history "${_LUMEN_LABELS[@]}"

  # terraform's own flags are single-dash, unlike most other tools here —
  # make sure the "-" partial check still routes to its flags table.
  BUFFER="terraform fmt -r"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -recursive "${_LUMEN_LABELS[@]}"

  BUFFER="pulumi up -s"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -s "${_LUMEN_LABELS[@]}"

  BUFFER="vagrant halt -f"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -f "${_LUMEN_LABELS[@]}"

  BUFFER="systemctl status --n"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --no-pager "${_LUMEN_LABELS[@]}"
}
