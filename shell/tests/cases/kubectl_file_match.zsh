# _lumen_kubectl_file_match — manifest files/dirs for kubectl's -f value.
case_kubectl_file_match() {
  local d
  d=$(mktemp -d)
  cd "$d"
  mkdir k8s base
  touch deploy.yaml svc.yml cfg.json notes.txt k8s/app.yaml k8s/readme.md

  BUFFER="kubectl apply -f "
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_ok $? 'apply -f <space> -> match'
  assert_has deploy.yaml "${_LUMEN_LABELS[@]}"
  assert_has svc.yml     "${_LUMEN_LABELS[@]}"
  assert_has cfg.json    "${_LUMEN_LABELS[@]}"
  assert_has k8s/        "${_LUMEN_LABELS[@]}"
  assert_lacks notes.txt "${_LUMEN_LABELS[@]}"

  BUFFER="kubectl delete -f dep"
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_has  deploy.yaml "${_LUMEN_LABELS[@]}"
  assert_lacks svc.yml    "${_LUMEN_LABELS[@]}"
  assert_eq "kubectl delete -f deploy.yaml" "${_LUMEN_CANDIDATES[1]}" 'partial replaced'

  BUFFER="kubectl apply -f k8s/"
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_has   k8s/app.yaml "${_LUMEN_LABELS[@]}"
  assert_lacks k8s/readme.md "${_LUMEN_LABELS[@]}"

  BUFFER="kubectl apply --filename="
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_ok $? '--filename= -> match'

  BUFFER="kubectl rollout restart -f "
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_ok $? 'rollout restart -f -> match'

  # logs -f is --follow, not a filename.
  BUFFER="kubectl logs -f "
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_fail $? 'logs -f -> no match'

  # Not in a -f value slot.
  BUFFER="kubectl apply "
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_fail $? 'apply without -f -> no match'

  BUFFER="docker rm -f "
  _lumen_reset_candidates
  _lumen_kubectl_file_match
  assert_fail $? 'non-kubectl -> no match'

  cd - >/dev/null
  rm -rf "$d"
}
