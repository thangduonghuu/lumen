# kubectl: the expanded subcommand table, the resource-TYPE stage of
# _lumen_kubectl_resource_match (no cluster needed — it reads a static
# table), the deeper sub-subcommand tables, the "-" flag fallback, and the
# namespace sniffer. The NAME stage and _lumen_kubectl_pod_match both shell
# out to `kubectl get`, so they self-disable with no kubectl/cluster and
# aren't exercised here.
case_kubectl_match() {
  # Subcommands that only exist after the table was filled out.
  BUFFER="kubectl ex"
  _lumen_static_or_dynamic_match
  assert_ok $? 'kubectl ex -> match'
  assert_has exec    "${_LUMEN_LABELS[@]}"
  assert_has explain "${_LUMEN_LABELS[@]}"

  BUFFER="kubectl deb"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has debug "${_LUMEN_LABELS[@]}"

  # The two fake "subcommands" that used to be in the table are gone.
  BUFFER="kubectl "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_lacks context   "${_LUMEN_LABELS[@]}"
  assert_lacks namespace "${_LUMEN_LABELS[@]}"

  # "k" alias resolves to the same table.
  BUFFER="k wai"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has wait "${_LUMEN_LABELS[@]}"

  # Resource-type stage: "kubectl get <partial>" offers plural type names
  # from the static table, filtered by the partial.
  BUFFER="kubectl get po"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_ok $? 'kubectl get po -> resource-type match'
  assert_has pods                 "${_LUMEN_LABELS[@]}"
  assert_has poddisruptionbudgets "${_LUMEN_LABELS[@]}"
  assert_lacks deployments        "${_LUMEN_LABELS[@]}"
  # Accepted text keeps the tool + verb prefix and gains a trailing space.
  assert_has "kubectl get pods " "${_LUMEN_CANDIDATES[@]}"

  # Same for describe, and with a trailing space (empty partial) every type
  # is on offer.
  BUFFER="kubectl describe "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has services "${_LUMEN_LABELS[@]}"
  assert_has nodes    "${_LUMEN_LABELS[@]}"

  # Group-qualified forms match once you've typed past the ".".
  BUFFER="kubectl get deployments."
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has deployments.apps "${_LUMEN_LABELS[@]}"
  assert_lacks deployments    "${_LUMEN_LABELS[@]}"
  BUFFER="kubectl get cronjobs.b"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has cronjobs.batch "${_LUMEN_LABELS[@]}"

  # `kubectl explain <type>` gets the type list (incl. qualified forms) but
  # never the `kubectl get` name lookup — its next word is a field path.
  BUFFER="kubectl explain deploy"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has deployments      "${_LUMEN_LABELS[@]}"
  assert_has deployments.apps "${_LUMEN_LABELS[@]}"
  BUFFER="kubectl explain deployments "
  _lumen_reset_candidates
  _lumen_kubectl_resource_match
  assert_fail $? 'explain past the type -> no name lookup'

  # Nested targets: "set <what>" and "rollout <what>" also complete the
  # <type>/<name> that follows.
  BUFFER="kubectl set image deploy"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_ok $? 'kubectl set image deploy -> resource-type match'
  assert_has deployments "${_LUMEN_LABELS[@]}"
  assert_has "kubectl set image deployments " "${_LUMEN_CANDIDATES[@]}"

  BUFFER="kubectl rollout status "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has deployments  "${_LUMEN_LABELS[@]}"
  assert_has statefulsets "${_LUMEN_LABELS[@]}"
  # rollout only works on those four kinds — not the whole resource table.
  assert_lacks secrets "${_LUMEN_LABELS[@]}"
  assert_lacks pods    "${_LUMEN_LABELS[@]}"

  BUFFER="kubectl rollout undo deploy"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has deployments "${_LUMEN_LABELS[@]}"

  # Bare "set" / "rollout" (no target word yet) still fall through to the
  # nested sub-subcommand tables, unchanged.
  BUFFER="kubectl set im"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has image "${_LUMEN_LABELS[@]}"
  BUFFER="kubectl rollout st"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has status "${_LUMEN_LABELS[@]}"

  # Once the target is a complete "type/name", the resource matcher is done
  # (the user is typing container=image next).
  BUFFER="kubectl set image deploy/web "
  _lumen_reset_candidates
  _lumen_kubectl_resource_match
  assert_fail $? 'complete type/name target -> resource matcher backs off'

  # Typing "-" is a flag, not a resource type: the resource matcher backs
  # off and _lumen_nested_match serves the get flag table instead.
  BUFFER="kubectl get -"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --all-namespaces "${_LUMEN_LABELS[@]}"
  assert_has -A               "${_LUMEN_LABELS[@]}"
  assert_lacks pods           "${_LUMEN_LABELS[@]}"

  # Deeper tables reachable through _lumen_nested_match.
  BUFFER="kubectl top "
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has pod  "${_LUMEN_LABELS[@]}"
  assert_has node "${_LUMEN_LABELS[@]}"

  BUFFER="kubectl auth can"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has can-i "${_LUMEN_LABELS[@]}"

  BUFFER="kubectl rollout u"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has undo "${_LUMEN_LABELS[@]}"

  # Past the resource name -> nothing stale from the resource matcher.
  BUFFER="kubectl get pods web extra "
  _lumen_reset_candidates
  _lumen_kubectl_resource_match
  assert_fail $? 'two names typed -> resource matcher backs off'

  # Namespace sniffer feeds the live lookups.
  BUFFER="kubectl logs -n prod api-xyz"
  assert_eq prod "$(_lumen_kubectl_ns)" '-n <ns> extracted'
  BUFFER="kubectl logs --namespace=staging api-xyz"
  assert_eq staging "$(_lumen_kubectl_ns)" '--namespace=<ns> extracted'
  BUFFER="kubectl get pods"
  assert_eq "" "$(_lumen_kubectl_ns)" 'no namespace flag -> empty'

  # Type stage: the name and its short alias are separate rows, each
  # matched independently, instead of one "pods po" row that always shows
  # both regardless of what was typed.
  BUFFER="kubectl get p"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has pods "${_LUMEN_LABELS[@]}"
  assert_has po   "${_LUMEN_LABELS[@]}"
  BUFFER="kubectl get pods"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has  pods "${_LUMEN_LABELS[@]}"
  assert_lacks po  "${_LUMEN_LABELS[@]}"

  # A flag past the already-typed TYPE (and/or NAME) still resolves to the
  # verb's own flags table, not the generic fallback.
  BUFFER="kubectl get pods -o"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has -o "${_LUMEN_LABELS[@]}"

  # Verbs with no dedicated flags table before this fix (kubectl expose)
  # and nested "set <what>" flags (kubectl set image) both resolve once
  # their type/name arguments are already typed.
  BUFFER="kubectl expose deployments.apps app1-deploy --port"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --port "${_LUMEN_LABELS[@]}"

  BUFFER="kubectl set image deploy/web app=nginx:1.27 --dry"
  _lumen_reset_candidates
  _lumen_static_or_dynamic_match
  assert_has --dry-run "${_LUMEN_LABELS[@]}"
}
