#!/usr/bin/env zsh
# lumen.plugin.zsh
#
# Deterministic, no-AI command suggestions, Fig/Kiro-CLI style: as you type,
# this plugin matches $BUFFER against known, hand-picked data — a tool's
# subcommands (git/docker/kubectl/npm/yarn/pnpm, aws/gcloud/az/terraform/
# helm/gh/glab, kafka-topics/kafka-console-producer/kafka-console-consumer/
# kafka-consumer-groups/rabbitmqctl), directories under whatever path
# follows `cd`, or local git branches once a subcommand that takes one has
# been typed — and sends the result (plus where the cursor currently is)
# over a Unix socket to the Lumen companion app, which draws a
# real floating panel positioned against the terminal's actual on-screen
# location (Accessibility API) — a bordered card, one row per candidate,
# the selected row highlighted, a one-line description of it in the
# footer. Pick one from the list with Up/Down, accept with
# Tab/Right-arrow/Enter, or dismiss with Ctrl-G. Ctrl-Space (or
# $LUMEN_KEY) asks immediately for the current buffer.
#
# This shell side never draws anything itself and has no idea whether the
# companion app successfully manages to show anything — it only ever sends
# "here's what to show and where the cursor is" (_lumen_overlay_show)
# fire-and-forget over the socket. See Lumen's
# TerminalPositioner.swift for the actual rendering/positioning logic, and
# the project plan doc for why this is a real OS panel rather than ANSI
# text drawn inside the terminal grid (rounded corners, shadows, no
# character-grid confinement).
#
# Everything here resolves synchronously from local data (static tables,
# `git for-each-ref`, a directory glob) — there's no background request, no
# daemon, and no network round-trip involved. An earlier version of this
# plugin shelled out to a separate Rust daemon (ai-shell-suggest/) for
# AI-generated suggestions; that path is no longer wired up (the daemon/
# client source is still in the repo, unused) in favor of just this
# deterministic matching, which is instant and never wrong about what a
# tool's own subcommands or your own branches/directories are.
#
# Keys:
#   Ctrl-Space (or $LUMEN_KEY)     ask immediately for the current buffer
#   Up / Down                           cycle candidates (falls back to
#                                        normal history search when no
#                                        suggestion is shown)
#   Tab / Right-arrow (at end of line)  accept the shown suggestion
#   Ctrl-G                              dismiss the current suggestion
#
# Config (set before sourcing this file):
#   LUMEN_KEY            manual trigger keybinding (default: '^@', i.e. Ctrl-Space)
#   LUMEN_AUTO           1 = automatic as-you-type suggestions (default),
#                             0 = Ctrl-Space-only
#   LUMEN_OVERLAY        1 = show suggestions via the native floating
#                             panel (Lumen companion app,
#                             default). 0 = don't show suggestions at all —
#                             there is no other rendering path; if the
#                             companion app isn't running, permission
#                             hasn't been granted, or the frontmost
#                             terminal can't be positioned against, nothing
#                             is shown for that keystroke (fails silently,
#                             never blocks typing).
#   LUMEN_UPDATE_CHECK    1 = check GitHub for new releases and prompt to
#                             update on shell startup (default), 0 = never
#                             touch the network for this (the one place
#                             this plugin does — see "Update check" below).
#   LUMEN_UPDATE_CHECK_DAYS      minimum days between GitHub checks (default: 1)
#   LUMEN_UPDATE_SNOOZE_SESSIONS new terminals to wait before re-asking
#                                 about a release you already said "not now"
#                                 to (default: 5)
#   LUMEN_UPDATE_REPO     GitHub "owner/repo" to check releases against
#                             (default: 'thangduonghuu/lumen')

[[ -o interactive ]] || return
[[ -n $ZSH_VERSION ]] || return

: ${LUMEN_KEY:='^@'}
: ${LUMEN_AUTO:=1}
: ${LUMEN_STATE_FILE:=$HOME/.cache/lumen/enabled}
: ${LUMEN_OVERLAY:=1}
: ${LUMEN_OVERLAY_SOCK:=$HOME/.cache/lumen/overlay.sock}
: ${LUMEN_UPDATE_CHECK:=1}
: ${LUMEN_UPDATE_CHECK_DAYS:=1}
: ${LUMEN_UPDATE_SNOOZE_SESSIONS:=5}
: ${LUMEN_UPDATE_REPO:='thangduonghuu/lumen'}

# Runtime on/off switch for AUTOMATIC suggestions, toggled from the
# Lumen app (a separate menu-bar icon/toggle — see
# Lumen/), not from this shell. The two are different
# processes with no shared memory, so a file is the simplest thing that
# works across both; reading one small file per keystroke is cheap enough
# not to matter. Missing file = enabled (so it works before the menu bar
# app has ever run). Deliberately does NOT gate the manual trigger
# ($LUMEN_KEY): the point of the toggle is to let automatic
# suggestions default to paused rather than always firing, not to block an
# explicit ask.
_lumen_auto_enabled() {
  [[ -f $LUMEN_STATE_FILE ]] || return 0
  local content
  content=$(<$LUMEN_STATE_FILE)
  [[ $content != "0" ]]
}

# Widget names we've overridden that already had a user-defined widget
# bound to them before we got to them (e.g. Powerlevel10k's own
# `zle-line-init`, zsh's `url-quote-magic` on `self-insert`) — maps the
# original widget name to the alias we copied it under, so our wrappers can
# chain into it. Populated by _lumen_wrap_widget at registration time.
typeset -gA _LUMEN_ORIG_WIDGET=()

# Registers $2 as the implementation for zle widget $1, preserving any
# pre-existing USER-DEFINED widget under that name first (`zle -A`, which
# copies rather than moves — the original keeps working standalone too) so
# other plugins that already hooked the same widget keep running instead of
# being silently replaced. Builtin (non-user) widgets don't need
# preserving — `zle .$WIDGET` already reaches those directly, no chaining
# required.
_lumen_wrap_widget() {
  local widget=$1 impl=$2
  local current=${widgets[$widget]-}
  # Only preserve a widget that belongs to SOMEONE ELSE. If this plugin
  # gets sourced twice in the same shell (re-sourced manually while already
  # loaded via .zshrc, common when testing), $current on the second pass is
  # already one of our own wrappers from the first pass — aliasing that as
  # "the original" would make our own wrapper call itself, recursing
  # forever on the very next keystroke. Excluding our own `_lumen_*`
  # functions here means a re-source just re-registers cleanly instead.
  if [[ $current == user:* && $current != user:_lumen_* ]]; then
    local orig="_lumen_orig_${widget//[^a-zA-Z0-9_]/_}"
    zle -A $widget $orig
    _LUMEN_ORIG_WIDGET[$widget]=$orig
  fi
  zle -N $widget $impl
}

# Runs whatever _lumen_wrap_widget preserved for $1, if anything —
# shared by every wrapper below so "chain into the widget we replaced" is
# one call instead of the same guarded lookup repeated in each of them.
_lumen_call_orig_widget() {
  (( $+_LUMEN_ORIG_WIDGET[$1] )) && zle ${_LUMEN_ORIG_WIDGET[$1]}
}

typeset -ga _LUMEN_CANDIDATES=()
typeset -ga _LUMEN_DESCRIPTIONS=()
typeset -ga _LUMEN_HINTS=()
# Explicit display text per row, decoupled from the insertable command in
# _LUMEN_CANDIDATES — e.g. for "git status " the insertable text
# includes the tool name (needed on accept), but the row should just read
# "status" since "git" is already visible in what you typed. Empty means
# "no override, fall back to the full candidate text" (see
# _lumen_overlay_show); every current matcher sets this explicitly, but
# the fallback stays as a safety net for anything that doesn't.
typeset -ga _LUMEN_LABELS=()
# Per-row icon kind — "dir" (cd match) or "branch" (git branch match) from
# their respective matchers, or one of _lumen_tool_icon_kind's per-tool
# identifiers ("git"/"docker"/"kubectl"/"aws"/"kafka"/...) for everything
# from the static/nested subcommand tables — parallel to
# _LUMEN_CANDIDATES, sent to the overlay companion app so it can draw a
# distinct glyph+color per row (see CandidateIcon in OverlayPanel.swift)
# instead of one generic badge for everything. "cmd" is the fallback for
# any tool without its own glyph yet.
typeset -ga _LUMEN_ICONS=()
# Per-row danger flag ("1" or empty) for flags that are hard-to-undo —
# force-push, --hard reset, force-delete, etc. Only _lumen_static_match and
# _lumen_nested_match populate this (from a 4th tab-separated field on the
# handful of entries actually worth flagging); every other matcher leaves it
# empty, which _lumen_overlay_show treats as "not dangerous" via its
# ${_LUMEN_DANGER[$i]:-} default.
typeset -ga _LUMEN_DANGER=()
typeset -gi _LUMEN_INDEX=0
# Per-matcher cap on how many candidates get built. The native overlay
# (OverlayContentView in OverlayPanel.swift) scrolls past whatever doesn't
# fit on screen, so this just bounds how much work each matcher's loop does
# and how far Down-arrow cycling goes — not a display constraint anymore.
typeset -gi _LUMEN_MAX_CANDIDATES=50

# Static subcommand tables: `name<TAB>arg-hint<TAB>description`, ordered by
# how commonly each subcommand is actually used (not alphabetically) since
# that order is what gets shown. This exists because AI-guessed suggestions
# are a poor fit for "what are this tool's subcommands" — that's fixed,
# known data, not something to guess contextually, and guessing it adds
# both latency (a model round-trip) and unreliability (it might not even
# list the right subcommands) for a case with one obviously correct answer.
# Deliberately small and hand-picked rather than exhaustive (e.g. git has
# ~40+ porcelain commands) — this is the common-case fast path, not a
# replacement for `git help -a`.
typeset -ga _LUMEN_GIT_SUBCMDS=(
  $'status\t[pathspec...]\tShow the working tree status'
  $'add\t<file>...\tAdd file contents to the index'
  $'commit\t\tRecord changes to the repository'
  $'push\t[remote] [branch]\tUpdate remote refs along with associated objects'
  $'pull\t[remote] [branch]\tFetch from and integrate with another repository'
  $'fetch\t[remote] [branch]\tDownload objects and refs from another repository'
  $'branch\t[branch]\tList, create, or delete branches'
  $'checkout\t[branch|file|commit]\tSwitch branches or restore working tree files'
  $'switch\t[branch]\tSwitch branches'
  $'merge\t[branch]\tJoin two or more development histories together'
  $'rebase\t[branch]\tReapply commits on top of another base tip'
  $'log\t[since] [until]\tShow commit logs'
  $'diff\t[commit] [commit]\tShow changes between commits, commit and working tree'
  $'stash\t[push|pop|list]\tStash changes in a dirty working directory'
  $'reset\t[commit]\tReset current HEAD to the specified state'
  $'tag\t[tagname]\tCreate, list, delete or verify a tag object'
  $'clone\t<repo> [dir]\tClone a repository into a new directory'
  $'init\t\tCreate an empty Git repository'
  $'remote\t[add|remove|-v]\tManage the set of tracked repositories'
  $'cherry-pick\t<commit>...\tApply the changes from existing commits'
  $'revert\t<commit>\tRevert existing commits'
  $'blame\t<file>\tShow what revision and author last modified each line'
  $'show\t<commit>\tShow various types of objects'
  $'rm\t<file>...\tRemove files from the working tree and index'
  $'mv\t<src> <dst>\tMove or rename a file'
  $'clean\t\tRemove untracked files from the working tree'
  $'restore\t<file>...\tRestore working tree files'
)

# Full set of kubectl operations (the official "kubectl --help" groups:
# Basic / Deploy / Cluster Management / Troubleshooting / Advanced /
# Settings / Other), ordered by how often each is actually reached for
# rather than alphabetically. The genuinely rare ones (alpha, options,
# kustomize, convert) are left out on purpose — same "common-case fast
# path" rule as the git table. The per-<type>-<name> and per-<pod>
# argument completions for these live in _lumen_kubectl_resource_match /
# _lumen_kubectl_pod_match below.
typeset -ga _LUMEN_KUBECTL_SUBCMDS=(
  $'get\t<type> [name]\tDisplay one or many resources'
  $'describe\t<type> <name>\tShow the detailed state of a resource'
  $'logs\t<pod>\tPrint the logs for a container in a pod'
  $'apply\t-f <file>\tApply a configuration to a resource by file or stdin'
  $'exec\t<pod> -- <cmd>\tExecute a command in a container'
  $'delete\t<type> <name>\tDelete resources by file, name, or label selector'
  $'create\t-f <file>\tCreate a resource from a file or stdin'
  $'edit\t<type> <name>\tEdit a resource on the server in $EDITOR'
  $'rollout\t[status|undo|restart]\tManage the rollout of a resource'
  $'scale\t<type>/<name>\tSet a new replica count for a workload'
  $'set\t[image|env|resources]\tChange a specific feature on an existing object'
  $'port-forward\t<pod> <ports>\tForward one or more local ports to a pod'
  $'run\t<name> --image=<img>\tRun a particular image on the cluster'
  $'expose\t<type> <name>\tExpose a resource as a new Service'
  $'top\t[pod|node]\tDisplay resource (CPU/memory) usage'
  $'explain\t<type>\tShow documentation for a resource type and its fields'
  $'config\t[get-contexts|use-context]\tModify kubeconfig files'
  $'cp\t<pod>:<src> <dst>\tCopy files and directories to/from a container'
  $'label\t<type> <name> <k>=<v>\tUpdate the labels on a resource'
  $'annotate\t<type> <name> <k>=<v>\tUpdate the annotations on a resource'
  $'patch\t<type> <name> -p <patch>\tUpdate fields of a resource with a merge patch'
  $'diff\t-f <file>\tDiff a file or stdin against the live configuration'
  $'wait\t<type>/<name> --for=<cond>\tWait for a condition on one or more resources'
  $'debug\t<pod> --image=<img>\tStart a debugging session for a pod or node'
  $'attach\t<pod> -it\tAttach to a running container'
  $'auth\t[can-i|whoami]\tInspect authorization'
  $'cluster-info\t\tShow control-plane and service endpoints'
  $'api-resources\t\tList the supported API resources'
  $'api-versions\t\tList the supported API group/versions'
  $'events\t[--for <type>/<name>]\tList events, optionally watching'
  $'autoscale\t<type> <name> --max=<n>\tCreate a HorizontalPodAutoscaler for a workload'
  $'replace\t-f <file>\tReplace a resource by file or stdin'
  $'cordon\t<node>\tMark a node as unschedulable'
  $'uncordon\t<node>\tMark a node as schedulable'
  $'drain\t<node>\tEvict the pods from a node ahead of maintenance'
  $'taint\t<node> <k>=<v>:<effect>\tUpdate the taints on one or more nodes'
  $'certificate\t[approve|deny] <csr>\tApprove or deny CertificateSigningRequests'
  $'proxy\t--port=<port>\tRun a proxy to the Kubernetes API server'
  $'completion\t<shell>\tOutput shell completion code (bash|zsh|fish)'
  $'plugin\t[list]\tList and inspect installed kubectl plugins'
  $'version\t\tPrint the client and server version information'
)

typeset -ga _LUMEN_NPM_SUBCMDS=(
  $'run\t<script>\tRun a script defined in package.json'
  $'install\t[package]\tInstall dependencies (or add one)'
  $'start\t\tRun the "start" script'
  $'test\t\tRun the "test" script'
  $'uninstall\t<package>\tRemove a package'
  $'update\t[package]\tUpdate packages to the latest version'
  $'init\t\tCreate a new package.json'
  $'publish\t\tPublish a package to the registry'
  $'list\t\tList installed packages'
  $'outdated\t\tCheck for outdated packages'
  $'audit\t[fix]\tCheck for security vulnerabilities'
  $'ci\t\tClean install from package-lock.json'
  $'link\t[package]\tSymlink a package for local development'
  $'cache\t[clean|verify]\tManage the local npm cache'
  $'version\t<newversion>\tBump package.json version'
  $'exec\t<package>\tRun a package binary without installing it'
)

typeset -ga _LUMEN_DOCKER_SUBCMDS=(
  $'ps\t\tList containers'
  $'images\t\tList images'
  $'run\t<image>\tRun a command in a new container'
  $'build\t.\tBuild an image from a Dockerfile'
  $'exec\t<container>\tRun a command in a running container'
  $'logs\t<container>\tFetch the logs of a container'
  $'stop\t<container>\tStop a running container'
  $'start\t<container>\tStart a stopped container'
  $'rm\t<container>\tRemove a container'
  $'restart\t<container>\tRestart a container'
  $'kill\t<container>\tSend a signal (default SIGKILL) to a container'
  $'rmi\t<image>\tRemove an image'
  $'pull\t<image>\tPull an image from a registry'
  $'push\t<image>\tPush an image to a registry'
  $'compose\t[up|down|build]\tRun multi-container apps via docker-compose'
  $'network\t[ls|create|rm]\tManage networks'
  $'volume\t[ls|create|rm]\tManage volumes'
  $'inspect\t<container|image>\tReturn low-level info on an object'
  $'tag\t<image> <tag>\tTag an image into a repository'
  $'system\t[prune|df]\tManage Docker resources / disk usage'
  $'container\t[ls|run|exec|...]\tManage containers'
  $'image\t[ls|build|rm|...]\tManage images'
)

# DevOps/cloud tooling, same hand-picked-common-case philosophy as above.
# aws/gcloud-style CLIs are two levels deep by nature (`aws <service>
# <operation>`), so this top-level table lists services rather than
# operations directly — see the AWS_<SERVICE>_SUBCMDS tables below (picked
# up by _lumen_nested_match) for the operations themselves.
typeset -ga _LUMEN_AWS_SUBCMDS=(
  $'s3\t\tManage S3 buckets and objects'
  $'ec2\t\tManage EC2 instances and related resources'
  $'lambda\t\tManage Lambda functions'
  $'iam\t\tManage IAM users, roles, and policies'
  $'logs\t\tManage CloudWatch Logs'
  $'sts\t\tSecurity Token Service (assume-role, identity)'
  $'cloudformation\t\tManage CloudFormation stacks'
  $'ecr\t\tManage Elastic Container Registry'
  $'ecs\t\tManage Elastic Container Service'
  $'eks\t\tManage Elastic Kubernetes Service clusters'
  $'ssm\t\tSystems Manager (params, sessions, run command)'
  $'dynamodb\t\tManage DynamoDB tables and items'
  $'rds\t\tManage RDS database instances'
  $'secretsmanager\t\tManage Secrets Manager secrets'
  $'cloudwatch\t\tManage CloudWatch metrics and alarms'
  $'sns\t\tManage Simple Notification Service topics'
  $'sqs\t\tManage Simple Queue Service queues'
  $'route53\t\tManage Route 53 DNS'
  $'configure\t[list|get|set|sso]\tConfigure AWS CLI credentials and settings'
  $'sso\t[login|logout]\tAWS SSO login and configuration'
)

typeset -ga _LUMEN_TERRAFORM_SUBCMDS=(
  $'init\t\tInitialize a working directory'
  $'plan\t\tShow changes required by the current configuration'
  $'apply\t\tApply changes to reach the desired state'
  $'destroy\t\tDestroy previously-created infrastructure'
  $'validate\t\tValidate the configuration files'
  $'fmt\t\tReformat configuration files to canonical style'
  $'show\t[plan-file]\tShow the current state or a saved plan'
  $'output\t[name]\tShow output values from the state'
  $'state\t[list|show|mv|rm]\tAdvanced state management'
  $'import\t<address> <id>\tImport existing infrastructure into state'
  $'workspace\t[list|new|select|delete]\tManage workspaces'
  $'providers\t\tShow the providers required by this configuration'
  $'graph\t\tGenerate a visual graph of the configuration'
  $'taint\t<address>\tMark a resource as tainted'
  $'untaint\t<address>\tRemove the tainted mark from a resource'
  $'refresh\t\tUpdate state to match remote objects'
  $'console\t\tInteractive console for evaluating expressions'
  $'get\t\tDownload and install modules'
  $'version\t\tShow the current Terraform version'
  $'login\t\tObtain and save credentials for a host'
  $'force-unlock\t<lock-id>\tRelease a stuck lock on the state'
)

typeset -ga _LUMEN_TERRAFORM_FMT_FLAGS=(
  $'-recursive\t\tAlso process files in subdirectories'
  $'-check\t\tCheck if input is formatted; exits nonzero if not, without writing'
  $'-diff\t\tShow the formatting diff instead of (or alongside) writing it'
  $'-write=false\t\tDon'"'"'t write the changes, just report them'
)

typeset -ga _LUMEN_TERRAFORM_VALIDATE_FLAGS=(
  $'-json\t\tOutput validation results as machine-readable JSON'
)

typeset -ga _LUMEN_TERRAFORM_OUTPUT_FLAGS=(
  $'-json\t\tOutput values as a JSON object'
  $'-raw\t\tPrint a single string/number/bool value with no extra formatting'
)

typeset -ga _LUMEN_HELM_SUBCMDS=(
  $'install\t<name> <chart>\tInstall a chart'
  $'upgrade\t<name> <chart>\tUpgrade a release'
  $'uninstall\t<name>\tUninstall a release'
  $'list\t\tList releases'
  $'status\t<name>\tShow the status of a release'
  $'rollback\t<name> [revision]\tRoll back a release to a previous revision'
  $'repo\t[add|update|list]\tManage chart repositories'
  $'search\t[repo|hub] <keyword>\tSearch for charts'
  $'template\t<name> <chart>\tRender chart templates locally'
  $'get\t[values|manifest|notes] <name>\tGet extended information about a release'
  $'history\t<name>\tShow release history'
  $'pull\t<chart>\tDownload a chart'
  $'create\t<name>\tCreate a new chart'
  $'lint\t<chart>\tExamine a chart for possible issues'
  $'show\t[chart|values|readme] <chart>\tShow information about a chart'
  $'dependency\t[list|update|build]\tManage chart dependencies'
)

typeset -ga _LUMEN_GH_SUBCMDS=(
  $'pr\t[create|list|view|checkout|merge]\tManage pull requests'
  $'issue\t[create|list|view|close]\tManage issues'
  $'repo\t[clone|create|view|fork]\tManage repositories'
  $'run\t[list|view|watch|rerun]\tManage GitHub Actions workflow runs'
  $'workflow\t[list|view|run]\tManage GitHub Actions workflows'
  $'release\t[create|list|view|upload]\tManage releases'
  $'gist\t[create|list|view]\tManage gists'
  $'auth\t[login|logout|status]\tAuthenticate with GitHub'
  $'browse\t\tOpen the repository in the browser'
  $'api\t<endpoint>\tMake an authenticated GitHub API request'
  $'status\t\tShow status of relevant issues/PRs'
  $'search\t[repos|issues|prs]\tSearch GitHub'
)

typeset -ga _LUMEN_YARN_SUBCMDS=(
  $'add\t<package>\tAdd a dependency'
  $'remove\t<package>\tRemove a dependency'
  $'install\t\tInstall all dependencies'
  $'run\t<script>\tRun a script defined in package.json'
  $'dev\t\tRun the "dev" script'
  $'build\t\tRun the "build" script'
  $'start\t\tRun the "start" script'
  $'test\t\tRun the "test" script'
  $'upgrade\t[package]\tUpgrade packages'
  $'list\t\tList installed packages'
  $'why\t<package>\tShow why a package is installed'
  $'outdated\t\tCheck for outdated packages'
  $'cache\t[clean|list]\tManage the yarn cache'
  $'init\t\tCreate a new package.json'
  $'workspaces\t[list|run]\tManage yarn workspaces'
  $'dlx\t<package>\tRun a package binary without installing it'
)

typeset -ga _LUMEN_YARN_ADD_FLAGS=(
  $'-D\t\tSave as a devDependency'
  $'--dev\t\tSave as a devDependency'
)

typeset -ga _LUMEN_YARN_INSTALL_FLAGS=(
  $'--frozen-lockfile\t\tFail instead of updating yarn.lock (use in CI)'
  $'--production\t\tSkip devDependencies'
  $'--ignore-scripts\t\tSkip lifecycle scripts'
)

typeset -ga _LUMEN_PNPM_SUBCMDS=(
  $'add\t<package>\tAdd a dependency'
  $'remove\t<package>\tRemove a dependency'
  $'install\t\tInstall all dependencies'
  $'run\t<script>\tRun a script defined in package.json'
  $'dev\t\tRun the "dev" script'
  $'build\t\tRun the "build" script'
  $'start\t\tRun the "start" script'
  $'test\t\tRun the "test" script'
  $'update\t[package]\tUpdate packages'
  $'list\t\tList installed packages'
  $'why\t<package>\tShow why a package is installed'
  $'outdated\t\tCheck for outdated packages'
  $'exec\t<cmd>\tExecute a shell command in scope of the project'
  $'dlx\t<package>\tRun a package binary without installing it'
  $'init\t\tCreate a new package.json'
)

typeset -ga _LUMEN_PNPM_INSTALL_FLAGS=(
  $'--frozen-lockfile\t\tFail instead of updating pnpm-lock.yaml (use in CI)'
  $'--prod\t\tSkip devDependencies'
  $'--ignore-scripts\t\tSkip lifecycle scripts'
)

typeset -ga _LUMEN_PNPM_ADD_FLAGS=(
  $'-D\t\tSave as a devDependency'
  $'--save-dev\t\tSave as a devDependency'
)

# GitLab's counterpart to gh — same shape, but "mr" (merge request) where
# GitHub says "pr".
typeset -ga _LUMEN_GLAB_SUBCMDS=(
  $'mr\t[create|list|view|merge|checkout]\tManage merge requests'
  $'issue\t[create|list|view|close]\tManage issues'
  $'repo\t[clone|create|view|fork]\tManage repositories'
  $'ci\t[status|view|trace|retry]\tManage GitLab CI/CD pipelines'
  $'pipeline\t[list|view|run]\tManage pipelines'
  $'release\t[create|list|view]\tManage releases'
  $'auth\t[login|logout|status]\tAuthenticate with GitLab'
  $'label\t[list|create]\tManage labels'
  $'variable\t[list|set|delete]\tManage CI/CD variables'
  $'api\t<endpoint>\tMake an authenticated GitLab API request'
)

# gcloud, like aws, is a two-level "<tool> <group> <command>" CLI — this
# table lists resource groups; see _LUMEN_GCLOUD_COMPUTE_SUBCMDS/
# _GCLOUD_CONTAINER_SUBCMDS below (picked up by _lumen_nested_match)
# for the commands themselves.
typeset -ga _LUMEN_GCLOUD_SUBCMDS=(
  $'compute\t\tManage Compute Engine resources'
  $'container\t\tManage GKE clusters (Kubernetes Engine)'
  $'run\t\tManage Cloud Run services'
  $'functions\t\tManage Cloud Functions'
  $'storage\t\tManage Cloud Storage buckets and objects'
  $'iam\t\tManage IAM policies and service accounts'
  $'projects\t\tManage GCP projects'
  $'auth\t[login|list|revoke]\tManage authentication and credentials'
  $'config\t[list|set|get-value]\tManage gcloud CLI configuration'
  $'sql\t\tManage Cloud SQL instances'
  $'app\t\tManage App Engine deployments'
  $'builds\t\tManage Cloud Build jobs'
  $'logging\t\tManage Cloud Logging'
  $'pubsub\t\tManage Pub/Sub topics and subscriptions'
  $'secrets\t\tManage Secret Manager secrets'
)

typeset -ga _LUMEN_AZ_SUBCMDS=(
  $'vm\t\tManage virtual machines'
  $'aks\t\tManage Azure Kubernetes Service clusters'
  $'group\t[list|create|delete]\tManage resource groups'
  $'storage\t\tManage storage accounts, blobs, and files'
  $'webapp\t\tManage App Service web apps'
  $'functionapp\t\tManage Azure Functions'
  $'acr\t\tManage Azure Container Registry'
  $'login\t\tLog in to Azure'
  $'account\t[list|set|show]\tManage subscriptions'
  $'keyvault\t\tManage Key Vault secrets and keys'
  $'network\t\tManage virtual networks'
  $'sql\t\tManage Azure SQL databases'
  $'monitor\t\tManage Azure Monitor logs and metrics'
)

# --- deeper az sub-subcommand tables (picked up by _lumen_nested_match via
# the _LUMEN_AZ_<PATH>_SUBCMDS / _FLAGS naming convention) ------------------

typeset -ga _LUMEN_AZ_VM_SUBCMDS=(
  $'create\t\tCreate a virtual machine'
  $'list\t\tList virtual machines'
  $'show\t\tGet the details of a VM'
  $'start\t\tStart a stopped VM'
  $'stop\t\tPower off a running VM (still billed for storage)'
  $'restart\t\tRestart a VM'
  $'deallocate\t\tStop and release the compute resources of a VM (no compute billing)'
  $'delete\t\tDelete a VM'
  $'resize\t\tChange a VM'"'"'s size'
)

typeset -ga _LUMEN_AZ_VM_CREATE_FLAGS=(
  $'--resource-group\t<group>\tResource group name (required)'
  $'-g\t<group>\tResource group name (required)'
  $'--name\t<name>\tName of the VM (required)'
  $'-n\t<name>\tName of the VM (required)'
  $'--image\t<image>\tOS image, e.g. Ubuntu2204 (default: Ubuntu2204)'
  $'--size\t<size>\tVM size, e.g. Standard_D2s_v5'
  $'--admin-username\t<user>\tAdmin username for the VM'
  $'--generate-ssh-keys\t\tGenerate an SSH key pair if none exists in ~/.ssh'
  $'--location\t<location>\tRegion (defaults to the resource group'"'"'s location)'
  $'-l\t<location>\tRegion (defaults to the resource group'"'"'s location)'
)

typeset -ga _LUMEN_AZ_VM_LIST_FLAGS=(
  $'--resource-group\t<group>\tOnly list VMs in this resource group'
  $'-g\t<group>\tOnly list VMs in this resource group'
  $'--show-details\t\tInclude public IP, FQDN, and power state (slower)'
)

typeset -ga _LUMEN_AZ_VM_DELETE_FLAGS=(
  $'--resource-group\t<group>\tResource group name'
  $'-g\t<group>\tResource group name'
  $'--name\t<name>\tName of the VM'
  $'-n\t<name>\tName of the VM'
  $'--yes\t\tSkip the confirmation prompt\t1'
  $'-y\t\tSkip the confirmation prompt\t1'
  $'--no-wait\t\tDon'"'"'t wait for the delete to finish'
)

typeset -ga _LUMEN_AZ_AKS_SUBCMDS=(
  $'create\t\tCreate a managed Kubernetes cluster'
  $'get-credentials\t\tDownload cluster credentials into kubeconfig'
  $'list\t\tList managed clusters'
  $'show\t\tShow details of a managed cluster'
  $'delete\t\tDelete a managed cluster'
  $'scale\t\tScale the node count of a node pool'
  $'upgrade\t\tUpgrade a cluster to a newer Kubernetes version'
  $'start\t\tStart a stopped cluster'
  $'stop\t\tStop a running cluster'
)

typeset -ga _LUMEN_AZ_AKS_CREATE_FLAGS=(
  $'--resource-group\t<group>\tResource group name (required)'
  $'-g\t<group>\tResource group name (required)'
  $'--name\t<name>\tName of the cluster (required)'
  $'-n\t<name>\tName of the cluster (required)'
  $'--node-count\t<n>\tNumber of nodes in the default node pool (default: 3)'
  $'--node-vm-size\t<size>\tVM size for the nodes'
  $'--generate-ssh-keys\t\tGenerate an SSH key pair if none exists in ~/.ssh'
  $'--kubernetes-version\t<ver>\tKubernetes version to use'
)

typeset -ga _LUMEN_AZ_AKS_GET_CREDENTIALS_FLAGS=(
  $'--resource-group\t<group>\tResource group name (required)'
  $'-g\t<group>\tResource group name (required)'
  $'--name\t<name>\tName of the cluster (required)'
  $'-n\t<name>\tName of the cluster (required)'
  $'--overwrite-existing\t\tOverwrite the existing kubeconfig entry for this cluster'
  $'--admin\t\tGet cluster admin credentials instead of user credentials'
)

typeset -ga _LUMEN_AZ_GROUP_SUBCMDS=(
  $'create\t\tCreate a resource group'
  $'list\t\tList resource groups'
  $'delete\t\tDelete a resource group'
  $'show\t\tGet a resource group'
  $'exists\t\tCheck whether a resource group exists'
  $'update\t\tUpdate a resource group'
)

typeset -ga _LUMEN_AZ_GROUP_CREATE_FLAGS=(
  $'--name\t<name>\tName of the new resource group (required)'
  $'-n\t<name>\tName of the new resource group (required)'
  $'--location\t<location>\tRegion, e.g. westus (required)'
  $'-l\t<location>\tRegion, e.g. westus (required)'
  $'--tags\t<k=v ...>\tSpace-separated tags'
)

typeset -ga _LUMEN_AZ_GROUP_DELETE_FLAGS=(
  $'--name\t<name>\tName of the resource group'
  $'-n\t<name>\tName of the resource group'
  $'--yes\t\tDon'"'"'t prompt for confirmation — deletes every resource inside the group\t1'
  $'-y\t\tDon'"'"'t prompt for confirmation — deletes every resource inside the group\t1'
  $'--no-wait\t\tDon'"'"'t wait for the delete to finish'
)

typeset -ga _LUMEN_AZ_GROUP_LIST_FLAGS=(
  $'--tag\t<k=v>\tFilter by a single tag'
)

typeset -ga _LUMEN_AZ_STORAGE_SUBCMDS=(
  $'account\t\tManage storage accounts'
  $'container\t\tManage blob containers'
  $'blob\t\tManage blobs'
  $'share\t\tManage file shares'
  $'queue\t\tManage queues'
)

typeset -ga _LUMEN_AZ_STORAGE_ACCOUNT_SUBCMDS=(
  $'create\t\tCreate a storage account'
  $'list\t\tList storage accounts'
  $'delete\t\tDelete a storage account'
  $'show\t\tShow storage account properties'
  $'show-connection-string\t\tGet the connection string for a storage account'
)

typeset -ga _LUMEN_AZ_STORAGE_ACCOUNT_CREATE_FLAGS=(
  $'--name\t<name>\tName of the storage account (required)'
  $'-n\t<name>\tName of the storage account (required)'
  $'--resource-group\t<group>\tResource group name (required)'
  $'-g\t<group>\tResource group name (required)'
  $'--location\t<location>\tRegion'
  $'-l\t<location>\tRegion'
  $'--sku\t<sku>\tReplication SKU, e.g. Standard_LRS, Standard_GRS, Premium_LRS'
)

typeset -ga _LUMEN_AZ_STORAGE_CONTAINER_SUBCMDS=(
  $'create\t\tCreate a container in a storage account'
  $'list\t\tList containers in a storage account'
  $'delete\t\tMark a container for deletion'
  $'exists\t\tCheck whether a container exists'
)

typeset -ga _LUMEN_AZ_STORAGE_CONTAINER_CREATE_FLAGS=(
  $'--name\t<name>\tName of the container (required)'
  $'-n\t<name>\tName of the container (required)'
  $'--account-name\t<account>\tStorage account name'
)

typeset -ga _LUMEN_AZ_STORAGE_BLOB_SUBCMDS=(
  $'upload\t\tUpload a file as a blob'
  $'download\t\tDownload a blob to a file'
  $'list\t\tList blobs in a container'
  $'delete\t\tDelete a blob'
  $'show\t\tGet the details of a blob'
)

typeset -ga _LUMEN_AZ_STORAGE_BLOB_UPLOAD_FLAGS=(
  $'--container-name\t<name>\tContainer to upload into (required)'
  $'-c\t<name>\tContainer to upload into (required)'
  $'--name\t<name>\tName to give the blob (required)'
  $'--file\t<path>\tLocal file to upload (required)'
  $'-f\t<path>\tLocal file to upload (required)'
  $'--account-name\t<account>\tStorage account name'
)

typeset -ga _LUMEN_AZ_STORAGE_BLOB_DOWNLOAD_FLAGS=(
  $'--container-name\t<name>\tContainer to download from (required)'
  $'-c\t<name>\tContainer to download from (required)'
  $'--name\t<name>\tBlob to download (required)'
  $'--file\t<path>\tLocal path to save to (required)'
  $'-f\t<path>\tLocal path to save to (required)'
  $'--account-name\t<account>\tStorage account name'
)

typeset -ga _LUMEN_AZ_WEBAPP_SUBCMDS=(
  $'create\t\tCreate a web app'
  $'list\t\tList web apps'
  $'delete\t\tDelete a web app'
  $'deploy\t\tDeploy code to a web app'
)

typeset -ga _LUMEN_AZ_WEBAPP_CREATE_FLAGS=(
  $'--name\t<name>\tName of the web app (required)'
  $'-n\t<name>\tName of the web app (required)'
  $'--resource-group\t<group>\tResource group name (required)'
  $'-g\t<group>\tResource group name (required)'
  $'--plan\t<plan>\tApp Service plan name (required)'
)

typeset -ga _LUMEN_AZ_ACR_SUBCMDS=(
  $'create\t\tCreate a container registry'
  $'list\t\tList container registries'
  $'login\t\tLog in to a registry'
  $'delete\t\tDelete a registry'
)

typeset -ga _LUMEN_AZ_ACR_CREATE_FLAGS=(
  $'--name\t<name>\tName of the registry (required)'
  $'-n\t<name>\tName of the registry (required)'
  $'--resource-group\t<group>\tResource group name (required)'
  $'-g\t<group>\tResource group name (required)'
  $'--sku\t<sku>\tBasic, Standard, or Premium'
)

# Apache Kafka's admin/producer/consumer scripts are separate binaries
# rather than one "kafka" tool with subcommands, and each takes flags
# rather than a subcommand as its first argument — but the static-match
# machinery only cares that "first word after the tool name" is a
# prefix-matchable string, and a flag like "--list" fits that just as well
# as a subcommand name does.
typeset -ga _LUMEN_KAFKA_TOPICS_SUBCMDS=(
  $'--list\t\tList all topics'
  $'--create\t\tCreate a topic (use with --topic)'
  $'--delete\t\tDelete a topic (use with --topic)'
  $'--describe\t\tDescribe a topic (use with --topic)'
  $'--alter\t\tAlter a topic'"'"'s configuration (use with --topic)'
  $'--topic\t<name>\tTopic name, paired with --create/--delete/--describe/--alter'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--partitions\t<n>\tNumber of partitions (with --create/--alter)'
  $'--replication-factor\t<n>\tReplication factor (with --create)'
)

typeset -ga _LUMEN_KAFKA_CONSOLE_PRODUCER_SUBCMDS=(
  $'--topic\t<name>\tTopic to produce to'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--property\t<key=value>\tSet a producer property (e.g. parse.key=true)'
)

typeset -ga _LUMEN_KAFKA_CONSOLE_CONSUMER_SUBCMDS=(
  $'--topic\t<name>\tTopic to consume from'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--from-beginning\t\tConsume from the start of the topic'
  $'--group\t<group-id>\tConsumer group to join'
  $'--partition\t<n>\tConsume only from a specific partition'
)

typeset -ga _LUMEN_KAFKA_CONSUMER_GROUPS_SUBCMDS=(
  $'--list\t\tList all consumer groups'
  $'--describe\t\tDescribe a consumer group (use with --group)'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--reset-offsets\t\tReset consumer group offsets (use with --group/--topic)'
  $'--delete\t\tDelete a consumer group (use with --group)'
  $'--group\t<id>\tConsumer group to target'
  $'--topic\t<name>\tTopic name, paired with --reset-offsets'
)

typeset -ga _LUMEN_RABBITMQCTL_SUBCMDS=(
  $'status\t\tShow broker status'
  $'cluster_status\t\tShow cluster status'
  $'list_queues\t[vhost]\tList queues'
  $'list_exchanges\t[vhost]\tList exchanges'
  $'list_bindings\t[vhost]\tList bindings'
  $'list_connections\t\tList connections'
  $'list_channels\t\tList channels'
  $'list_vhosts\t\tList virtual hosts'
  $'list_users\t\tList users'
  $'add_user\t<user> <password>\tCreate a user'
  $'delete_user\t<user>\tDelete a user'
  $'set_permissions\t<user>\tSet user permissions on a vhost'
  $'list_permissions\t[vhost]\tList permissions on a vhost'
  $'add_vhost\t<vhost>\tCreate a virtual host'
  $'delete_vhost\t<vhost>\tDelete a virtual host'
  $'set_user_tags\t<user> <tag>\tSet tags for a user (e.g. administrator)'
  $'stop_app\t\tStop the RabbitMQ application (keep the node running)'
  $'start_app\t\tStart the RabbitMQ application'
  $'purge_queue\t<queue>\tPurge messages from a queue'
)

# --- language/build tool tables ---------------------------------------------

typeset -ga _LUMEN_CARGO_SUBCMDS=(
  $'build\t\tCompile the current package'
  $'run\t\tRun a binary or example of the local package'
  $'test\t\tRun the tests'
  $'check\t\tCheck a package for errors without building'
  $'add\t<crate>\tAdd a dependency'
  $'remove\t<crate>\tRemove a dependency'
  $'update\t\tUpdate dependencies in Cargo.lock'
  $'install\t<crate>\tInstall a Rust binary'
  $'uninstall\t<crate>\tUninstall a Rust binary'
  $'new\t<path>\tCreate a new Cargo package'
  $'init\t\tCreate a new Cargo package in the current directory'
  $'publish\t\tUpload a package to crates.io'
  $'clean\t\tRemove generated artifacts'
  $'doc\t\tBuild documentation'
  $'bench\t\tRun benchmarks'
  $'clippy\t\tRun the Clippy linter'
  $'fmt\t\tFormat source code'
  $'search\t<query>\tSearch crates.io for crates'
  $'tree\t\tDisplay the dependency tree'
)

typeset -ga _LUMEN_CARGO_BUILD_FLAGS=(
  $'--release\t\tBuild with optimizations, in release mode'
  $'-p\t<spec>\tBuild only the specified package'
  $'--package\t<spec>\tBuild only the specified package'
  $'--features\t<features>\tSpace/comma-separated list of features to activate'
  $'--bin\t<name>\tBuild only the specified binary'
  $'--example\t<name>\tBuild only the specified example'
  $'--target\t<triple>\tBuild for the specified target triple'
  $'--offline\t\tRun without accessing the network'
  $'--locked\t\tAssert Cargo.lock is up to date, without updating it'
  $'--manifest-path\t<path>\tPath to Cargo.toml'
)
typeset -ga _LUMEN_CARGO_RUN_FLAGS=("${_LUMEN_CARGO_BUILD_FLAGS[@]}")
typeset -ga _LUMEN_CARGO_TEST_FLAGS=("${_LUMEN_CARGO_BUILD_FLAGS[@]}")

typeset -ga _LUMEN_GO_SUBCMDS=(
  $'build\t\tCompile packages and dependencies'
  $'run\t<file>\tCompile and run a Go program'
  $'test\t\tRun tests'
  $'get\t<package>\tAdd dependencies and update go.mod'
  $'install\t<package>\tCompile and install packages'
  $'mod\t[init|tidy|download|vendor]\tManage go.mod'
  $'fmt\t\tFormat source code'
  $'vet\t\tReport likely mistakes in packages'
  $'generate\t\tRun generate directives'
  $'doc\t\tShow documentation for a package or symbol'
  $'env\t\tPrint Go environment information'
  $'clean\t\tRemove object files and cached files'
  $'list\t\tList packages or modules'
  $'work\t[init|use|edit]\tManage go.work workspace files'
)

typeset -ga _LUMEN_PIP_SUBCMDS=(
  $'install\t<package>\tInstall a package'
  $'uninstall\t<package>\tUninstall a package'
  $'list\t\tList installed packages'
  $'freeze\t\tOutput installed packages in requirements format'
  $'show\t<package>\tShow information about an installed package'
  $'download\t<package>\tDownload packages without installing'
  $'wheel\t<package>\tBuild wheel archives for packages'
  $'check\t\tVerify installed packages have compatible dependencies'
  $'config\t[list|get|set]\tManage pip configuration'
  $'cache\t[list|remove|purge]\tManage pip'"'"'s wheel cache'
)

typeset -ga _LUMEN_POETRY_SUBCMDS=(
  $'install\t\tInstall dependencies from pyproject.toml'
  $'add\t<package>\tAdd a dependency'
  $'remove\t<package>\tRemove a dependency'
  $'update\t\tUpdate dependencies to latest versions'
  $'build\t\tBuild a package (sdist/wheel)'
  $'publish\t\tPublish a package to PyPI'
  $'run\t<cmd>\tRun a command within the project'"'"'s environment'
  $'shell\t\tSpawn a shell within the project'"'"'s environment'
  $'new\t<path>\tCreate a new Python project'
  $'init\t\tAdd Poetry to an existing project'
  $'show\t[package]\tShow information about a dependency'
  $'lock\t\tLock dependencies without installing'
  $'env\t[info|list|use|remove]\tManage Poetry environments'
  $'check\t\tValidate pyproject.toml'
)

typeset -ga _LUMEN_MVN_SUBCMDS=(
  $'clean\t\tRemove build artifacts'
  $'compile\t\tCompile source code'
  $'test\t\tRun tests'
  $'package\t\tPackage compiled code (jar/war)'
  $'install\t\tInstall the package into the local repository'
  $'deploy\t\tDeploy the package to a remote repository'
  $'validate\t\tValidate the project is correct'
  $'verify\t\tRun checks to verify the package is valid'
  $'site\t\tGenerate project documentation'
  $'dependency:tree\t\tShow the dependency tree'
)

typeset -ga _LUMEN_GRADLE_SUBCMDS=(
  $'build\t\tAssemble and test the project'
  $'test\t\tRun tests'
  $'run\t\tRun the project'
  $'clean\t\tDelete build directory'
  $'assemble\t\tAssemble outputs without running tests'
  $'check\t\tRun all checks (including tests)'
  $'dependencies\t\tDisplay the dependency tree'
  $'tasks\t\tList available tasks'
  $'init\t\tInitialize a new Gradle project'
  $'wrapper\t\tGenerate the Gradle wrapper files'
)

typeset -ga _LUMEN_DOTNET_SUBCMDS=(
  $'build\t\tBuild a project and its dependencies'
  $'run\t\tRun source code without explicit build/publish'
  $'test\t\tRun unit tests'
  $'new\t<template>\tCreate a new project, config file, or solution'
  $'add\t[package|reference]\tAdd a package or project reference'
  $'remove\t[package|reference]\tRemove a package or project reference'
  $'restore\t\tRestore dependencies for a project'
  $'publish\t\tPublish for deployment'
  $'clean\t\tClean build outputs'
  $'watch\t\tRun and restart on file changes'
  $'pack\t\tCreate a NuGet package'
  $'nuget\t[push|locals]\tManage NuGet packages'
)

typeset -ga _LUMEN_BUNDLE_SUBCMDS=(
  $'install\t\tInstall gems from the Gemfile'
  $'update\t\tUpdate gems to the latest allowed version'
  $'exec\t<cmd>\tRun a command in the bundle'"'"'s context'
  $'add\t<gem>\tAdd a gem to the Gemfile'
  $'remove\t<gem>\tRemove a gem from the Gemfile'
  $'list\t\tList gems in the bundle'
  $'show\t<gem>\tShow the source location of a gem'
  $'init\t\tGenerate a new Gemfile'
  $'check\t\tVerify dependencies are satisfied'
  $'outdated\t\tList outdated gems'
  $'lock\t\tGenerate a Gemfile.lock without installing'
)

typeset -ga _LUMEN_GEM_SUBCMDS=(
  $'install\t<gem>\tInstall a gem'
  $'uninstall\t<gem>\tUninstall a gem'
  $'list\t\tList installed gems'
  $'update\t[gem]\tUpdate installed gems'
  $'search\t<query>\tSearch for gems on RubyGems.org'
  $'build\t<gemspec>\tBuild a gem from a gemspec'
  $'push\t<gem>\tPush a gem to RubyGems.org'
  $'specification\t<gem>\tShow a gem'"'"'s specification'
  $'which\t<lib>\tLocate a library file'
)

# --- system/infra/PaaS tool tables ------------------------------------------

typeset -ga _LUMEN_BREW_SUBCMDS=(
  $'install\t<formula>\tInstall a formula or cask'
  $'uninstall\t<formula>\tUninstall a formula or cask'
  $'update\t\tFetch the newest version of Homebrew and formulae'
  $'upgrade\t[formula]\tUpgrade outdated formulae/casks'
  $'list\t\tList installed formulae/casks'
  $'search\t<text>\tSearch for formulae/casks'
  $'info\t<formula>\tShow information about a formula/cask'
  $'tap\t[user/repo]\tTap a formula repository'
  $'untap\t<user/repo>\tRemove a tapped repository'
  $'services\t[list|start|stop|restart]\tManage background services'
  $'cleanup\t\tRemove old versions of installed formulae'
  $'doctor\t\tCheck your system for potential problems'
  $'outdated\t\tList installed formulae with updates available'
  $'link\t<formula>\tSymlink a formula'"'"'s installed files'
  $'unlink\t<formula>\tRemove symlinks for a formula'
)

typeset -ga _LUMEN_VAGRANT_SUBCMDS=(
  $'up\t\tStart and provision the vagrant environment'
  $'halt\t\tStop the vagrant machine'
  $'destroy\t\tStop and delete the vagrant machine'
  $'ssh\t\tSSH into the vagrant machine'
  $'status\t\tShow the state of the vagrant machine'
  $'provision\t\tRe-run provisioners'
  $'reload\t\tRestart the vagrant machine, loading new config'
  $'box\t[list|add|remove]\tManage Vagrant boxes'
  $'init\t\tInitialize a new Vagrantfile'
  $'suspend\t\tSuspend the vagrant machine'
  $'resume\t\tResume a suspended vagrant machine'
  $'global-status\t\tShow status of all known vagrant environments'
  $'plugin\t[install|list|uninstall]\tManage Vagrant plugins'
)

typeset -ga _LUMEN_VAGRANT_DESTROY_FLAGS=(
  $'-f\t\tDestroy without confirmation\t1'
  $'--force\t\tDestroy without confirmation\t1'
)

typeset -ga _LUMEN_VAGRANT_UP_FLAGS=(
  $'--provision\t\tForce provisioners to run'
)

typeset -ga _LUMEN_VAGRANT_SSH_FLAGS=(
  $'-c\t<command>\tRun a single command over SSH instead of an interactive session'
  $'--command\t<command>\tRun a single command over SSH instead of an interactive session'
)

typeset -ga _LUMEN_VAGRANT_HALT_FLAGS=("${_LUMEN_VAGRANT_DESTROY_FLAGS[@]}")

typeset -ga _LUMEN_PULUMI_SUBCMDS=(
  $'up\t\tCreate or update resources in a stack'
  $'destroy\t\tDestroy resources in a stack'
  $'preview\t\tShow a preview of changes'
  $'stack\t[init|select|ls|output]\tManage stacks'
  $'config\t[set|get|list]\tManage stack configuration'
  $'new\t<template>\tCreate a new project'
  $'login\t\tLog in to a Pulumi backend'
  $'logout\t\tLog out of a Pulumi backend'
  $'refresh\t\tRefresh state to match real infrastructure'
  $'import\t\tImport existing infrastructure into a stack'
  $'plugin\t[install|ls]\tManage plugins'
  $'whoami\t\tShow the current logged-in user'
)

typeset -ga _LUMEN_PULUMI_UP_FLAGS=(
  $'--yes\t\tSkip the interactive approval prompt'
  $'-s\t<stack>\tThe stack to operate on (defaults to the current stack)'
  $'--stack\t<stack>\tThe stack to operate on (defaults to the current stack)'
  $'--config-file\t<file>\tUse config values from this file instead of the stack config'
  $'-t\t<urn>\tOnly update this resource (repeatable)'
  $'--target\t<urn>\tOnly update this resource (repeatable)'
  $'--diff\t\tShow a detailed diff of the changes'
  $'--skip-preview\t\tSkip the preview step'
)
typeset -ga _LUMEN_PULUMI_DESTROY_FLAGS=("${_LUMEN_PULUMI_UP_FLAGS[@]}")

typeset -ga _LUMEN_HEROKU_SUBCMDS=(
  $'apps\t\tList your Heroku apps'
  $'create\t[name]\tCreate a new app'
  $'deploy\t\tDeploy the app'
  $'logs\t\tDisplay recent log output'
  $'run\t<cmd>\tRun a one-off process in a dyno'
  $'config\t[get|set|unset]\tManage config vars'
  $'addons\t\tList add-ons for an app'
  $'ps\t\tList dynos for an app'
  $'releases\t\tList releases for an app'
  $'domains\t\tList domains for an app'
  $'login\t\tLog in to Heroku'
  $'logout\t\tLog out of Heroku'
  $'maintenance\t[on|off]\tToggle maintenance mode'
)

typeset -ga _LUMEN_VERCEL_SUBCMDS=(
  $'deploy\t\tDeploy the current directory'
  $'dev\t\tRun a local development server'
  $'build\t\tBuild the project locally'
  $'env\t[ls|add|rm|pull]\tManage environment variables'
  $'domains\t\tManage domains'
  $'login\t\tLog in to Vercel'
  $'logout\t\tLog out of Vercel'
  $'ls\t\tList deployments'
  $'rm\t<deployment>\tRemove a deployment'
  $'link\t\tLink the current directory to a Vercel project'
  $'whoami\t\tShow the current logged-in user'
  $'project\t[ls|add|rm]\tManage projects'
  $'teams\t[ls|switch]\tManage teams'
)

typeset -ga _LUMEN_NETLIFY_SUBCMDS=(
  $'deploy\t\tDeploy the site'
  $'dev\t\tRun a local development server'
  $'build\t\tBuild the site'
  $'env\t[list|set|unset]\tManage environment variables'
  $'link\t\tLink the current directory to a Netlify site'
  $'login\t\tLog in to Netlify'
  $'logout\t\tLog out of Netlify'
  $'init\t\tCreate or connect a Netlify site'
  $'open\t\tOpen the site in your browser'
  $'status\t\tShow status of the linked site'
  $'sites\t[list|create|delete]\tManage sites'
  $'functions\t[list|create|invoke]\tManage serverless functions'
)

typeset -ga _LUMEN_FIREBASE_SUBCMDS=(
  $'deploy\t\tDeploy to Firebase'
  $'init\t\tSet up a new Firebase project'
  $'login\t\tLog in to Firebase'
  $'logout\t\tLog out of Firebase'
  $'serve\t\tRun the local emulator server'
  $'functions\t[log|shell|config]\tManage Cloud Functions'
  $'emulators:start\t\tStart the local Firebase emulators'
  $'use\t[alias]\tSet the active Firebase project'
  $'projects:list\t\tList Firebase projects'
  $'hosting:channel:deploy\t<channel>\tDeploy to a hosting preview channel'
)

typeset -ga _LUMEN_FLYCTL_SUBCMDS=(
  $'deploy\t\tDeploy the app'
  $'launch\t\tCreate and configure a new app'
  $'status\t\tShow app status'
  $'logs\t\tView app logs'
  $'scale\t[count|vm]\tScale an app'
  $'apps\t[list|create|destroy]\tManage apps'
  $'machine\t[list|start|stop|restart]\tManage Fly machines'
  $'volumes\t[list|create|destroy]\tManage volumes'
  $'secrets\t[list|set|unset]\tManage app secrets'
  $'ssh\t[console|shell]\tSSH into a running machine'
  $'open\t\tOpen the app in your browser'
  $'destroy\t<app>\tDestroy an app'
)

typeset -ga _LUMEN_DOCTL_SUBCMDS=(
  $'compute\t[droplet|image|ssh]\tManage Droplets and related resources'
  $'apps\t[list|create|update]\tManage App Platform apps'
  $'databases\t[list|create|connection]\tManage managed databases'
  $'kubernetes\t[cluster|options]\tManage DOKS clusters'
  $'auth\t[init|list|switch]\tManage doctl authentication'
  $'account\t\tShow account details'
  $'projects\t[list|create]\tManage projects'
  $'registry\t[login|repository]\tManage container registries'
)

# --- monorepo/session/version-manager tool tables ---------------------------

typeset -ga _LUMEN_TURBO_SUBCMDS=(
  $'run\t<task>\tRun a task across the monorepo'
  $'build\t\tRun the "build" task'
  $'dev\t\tRun the "dev" task'
  $'link\t\tLink the repo to a remote cache'
  $'unlink\t\tUnlink the repo from a remote cache'
  $'login\t\tLog in to Vercel remote cache'
  $'logout\t\tLog out of Vercel remote cache'
  $'prune\t<scope>\tGenerate a pruned subset of the monorepo'
  $'gen\t\tRun code generators'
)

typeset -ga _LUMEN_NX_SUBCMDS=(
  $'run\t<project>:<target>\tRun a target for a project'
  $'build\t[project]\tBuild a project'
  $'test\t[project]\tTest a project'
  $'generate\t<schematic>\tRun a generator/schematic'
  $'g\t<schematic>\tAlias for generate'
  $'serve\t[project]\tServe a project'
  $'lint\t[project]\tLint a project'
  $'e2e\t[project]\tRun end-to-end tests for a project'
  $'graph\t\tShow the project dependency graph'
  $'affected\t[build|test|lint]\tRun a target for affected projects only'
  $'migrate\t<version>\tMigrate to a new Nx version'
)

typeset -ga _LUMEN_TMUX_SUBCMDS=(
  $'new-session\t\tCreate a new session'
  $'attach-session\t\tAttach to an existing session'
  $'list-sessions\t\tList sessions'
  $'kill-session\t\tDestroy a session'
  $'split-window\t\tSplit the current pane'
  $'new-window\t\tCreate a new window'
  $'kill-window\t\tDestroy a window'
  $'list-windows\t\tList windows'
  $'detach\t\tDetach the current client'
  $'rename-session\t<name>\tRename a session'
  $'source-file\t<file>\tExecute commands from a config file'
)

typeset -ga _LUMEN_TMUX_NEW_SESSION_FLAGS=(
  $'-s\t<name>\tName for the new session'
)
typeset -ga _LUMEN_TMUX_ATTACH_SESSION_FLAGS=(
  $'-t\t<name>\tSession to attach to'
)
typeset -ga _LUMEN_TMUX_KILL_SESSION_FLAGS=(
  $'-t\t<name>\tSession to destroy'
)
typeset -ga _LUMEN_TMUX_SPLIT_WINDOW_FLAGS=(
  $'-h\t\tSplit horizontally (side by side)'
  $'-v\t\tSplit vertically (stacked)'
)
typeset -ga _LUMEN_TMUX_NEW_WINDOW_FLAGS=(
  $'-n\t<name>\tName for the new window'
)
typeset -ga _LUMEN_TMUX_KILL_WINDOW_FLAGS=(
  $'-t\t<name>\tWindow to destroy'
)

typeset -ga _LUMEN_SYSTEMCTL_SUBCMDS=(
  $'start\t<unit>\tStart a unit'
  $'stop\t<unit>\tStop a unit'
  $'restart\t<unit>\tRestart a unit'
  $'status\t<unit>\tShow runtime status of a unit'
  $'enable\t<unit>\tEnable a unit to start on boot'
  $'disable\t<unit>\tDisable a unit from starting on boot'
  $'reload\t<unit>\tReload a unit'"'"'s configuration'
  $'is-active\t<unit>\tCheck whether a unit is active'
  $'is-enabled\t<unit>\tCheck whether a unit is enabled'
  $'list-units\t\tList loaded units'
  $'daemon-reload\t\tReload systemd manager configuration'
)

typeset -ga _LUMEN_SYSTEMCTL_ENABLE_FLAGS=(
  $'--now\t\tAlso start the unit immediately, not just on the next boot'
)

typeset -ga _LUMEN_SYSTEMCTL_STATUS_FLAGS=(
  $'-l\t\tDon'"'"'t ellipsize unit names or output'
  $'--full\t\tDon'"'"'t ellipsize unit names or output'
  $'--no-pager\t\tDo not pipe output into a pager'
)

typeset -ga _LUMEN_NVM_SUBCMDS=(
  $'install\t<version>\tInstall a Node.js version'
  $'use\t<version>\tSwitch to a Node.js version'
  $'list\t\tList installed Node.js versions'
  $'ls\t\tAlias for list'
  $'alias\t[name] [version]\tManage version aliases'
  $'current\t\tShow the currently active Node.js version'
  $'uninstall\t<version>\tUninstall a Node.js version'
  $'run\t<version> <args>\tRun a script with a specific Node.js version'
  $'exec\t<version> <cmd>\tRun a command with a specific Node.js version'
  $'which\t[version]\tShow the path to a Node.js version'
)

typeset -ga _LUMEN_PYENV_SUBCMDS=(
  $'install\t<version>\tInstall a Python version'
  $'uninstall\t<version>\tUninstall a Python version'
  $'versions\t\tList installed Python versions'
  $'version\t\tShow the current Python version'
  $'global\t<version>\tSet the global Python version'
  $'local\t<version>\tSet the local (per-directory) Python version'
  $'shell\t<version>\tSet the Python version for the current shell'
  $'rehash\t\tRebuild shim executables'
  $'which\t<command>\tShow the path to a command'
  $'root\t\tShow the pyenv root directory'
)

typeset -ga _LUMEN_RBENV_SUBCMDS=(
  $'install\t<version>\tInstall a Ruby version'
  $'uninstall\t<version>\tUninstall a Ruby version'
  $'versions\t\tList installed Ruby versions'
  $'version\t\tShow the current Ruby version'
  $'global\t<version>\tSet the global Ruby version'
  $'local\t<version>\tSet the local (per-directory) Ruby version'
  $'shell\t<version>\tSet the Ruby version for the current shell'
  $'rehash\t\tRebuild shim executables'
  $'which\t<command>\tShow the path to a command'
  $'root\t\tShow the rbenv root directory'
)

typeset -ga _LUMEN_NPX_SUBCMDS=(
  $'--yes\t<package>\tRun a package without prompting to install it'
  $'--no-install\t<package>\tRun a package only if already installed'
  $'--package\t<package>\tSpecify the package to run a binary from'
  $'-c\t<command>\tExecute a command with the local node_modules/.bin on PATH'
)

typeset -ga _LUMEN_MINIKUBE_SUBCMDS=(
  $'start\t\tStart a local Kubernetes cluster'
  $'stop\t\tStop a running cluster'
  $'delete\t\tDelete a cluster'
  $'status\t\tShow the status of a cluster'
  $'dashboard\t\tOpen the Kubernetes dashboard'
  $'kubectl\t<args>\tRun a kubectl command against the cluster'
  $'ssh\t\tSSH into the cluster'
  $'addons\t[list|enable|disable]\tManage cluster addons'
  $'service\t<name>\tOpen a service in the browser'
  $'tunnel\t\tCreate a network route to services'
  $'profile\t[list|set]\tManage minikube profiles'
  $'config\t[get|set|view]\tManage minikube configuration'
)

# --- nested (sub-subcommand and flag) tables --------------------------------
#
# Counterpart to the top-level *_SUBCMDS tables above, but one level deeper:
# the sub-subcommands of a subcommand that is itself a management command
# (`docker image` -> ls/build/rm/...) or the flags of a specific, possibly
# nested, subcommand (`docker ps` -> -a/-q/..., `docker image ls` -> -a/-q/...).
# Looked up by naming convention from the words actually typed rather than a
# hand-maintained dispatch table — see _lumen_nested_match, which builds
# the variable name "_LUMEN_<TOOL>_<SUBCMD...>_SUBCMDS" (or "_FLAGS" if
# the word being completed starts with "-") from the command path so far and
# looks it up indirectly. Same hand-picked-common-case philosophy as the
# top-level tables: not exhaustive, just the subcommands/flags someone
# actually reaches for.

typeset -ga _LUMEN_DOCKER_IMAGE_SUBCMDS=(
  $'ls\t\tList images'
  $'build\t.\tBuild an image from a Dockerfile'
  $'pull\t<image>\tPull an image from a registry'
  $'push\t<image>\tPush an image to a registry'
  $'rm\t<image>\tRemove an image'
  $'tag\t<image> <tag>\tTag an image into a repository'
  $'inspect\t<image>\tReturn low-level info on an image'
  $'history\t<image>\tShow the history of an image'
  $'prune\t\tRemove unused images'
  $'save\t<image>\tSave an image to a tar archive'
  $'load\t\tLoad an image from a tar archive'
)

typeset -ga _LUMEN_DOCKER_CONTAINER_SUBCMDS=(
  $'ls\t\tList containers'
  $'run\t<image>\tRun a command in a new container'
  $'exec\t<container>\tRun a command in a running container'
  $'logs\t<container>\tFetch the logs of a container'
  $'stop\t<container>\tStop a running container'
  $'start\t<container>\tStart a stopped container'
  $'restart\t<container>\tRestart a container'
  $'rm\t<container>\tRemove a container'
  $'inspect\t<container>\tReturn low-level info on a container'
  $'cp\t<src> <dst>\tCopy files to/from a container'
  $'stats\t[container]\tDisplay live resource usage statistics'
  $'prune\t\tRemove all stopped containers'
)

typeset -ga _LUMEN_DOCKER_NETWORK_SUBCMDS=(
  $'ls\t\tList networks'
  $'create\t<name>\tCreate a network'
  $'rm\t<network>\tRemove a network'
  $'inspect\t<network>\tReturn low-level info on a network'
  $'connect\t<network> <container>\tConnect a container to a network'
  $'disconnect\t<network> <container>\tDisconnect a container from a network'
  $'prune\t\tRemove unused networks'
)

typeset -ga _LUMEN_DOCKER_VOLUME_SUBCMDS=(
  $'ls\t\tList volumes'
  $'create\t<name>\tCreate a volume'
  $'rm\t<volume>\tRemove a volume'
  $'inspect\t<volume>\tReturn low-level info on a volume'
  $'prune\t\tRemove unused volumes'
)

typeset -ga _LUMEN_DOCKER_SYSTEM_SUBCMDS=(
  $'df\t\tShow docker disk usage'
  $'prune\t\tRemove unused data'
  $'info\t\tDisplay system-wide information'
  $'events\t\tGet real time events from the server'
)

typeset -ga _LUMEN_DOCKER_COMPOSE_SUBCMDS=(
  $'up\t\tCreate and start containers'
  $'down\t\tStop and remove containers, networks'
  $'build\t\tBuild or rebuild services'
  $'ps\t\tList containers'
  $'logs\t[service]\tView output from containers'
  $'exec\t<service> <cmd>\tExecute a command in a running container'
  $'restart\t[service]\tRestart services'
  $'stop\t[service]\tStop services'
  $'start\t[service]\tStart services'
  $'pull\t[service]\tPull service images'
  $'config\t\tValidate and view the compose file'
)

typeset -ga _LUMEN_DOCKER_PS_FLAGS=(
  $'-a\t\tShow all containers (default shows just running)'
  $'-q\t\tOnly display container IDs'
  $'--filter\t<expr>\tFilter output based on conditions'
  $'--format\t<template>\tFormat output using a Go template'
)

typeset -ga _LUMEN_DOCKER_IMAGES_FLAGS=(
  $'-a\t\tShow all images (default hides intermediate images)'
  $'-q\t\tOnly display image IDs'
  $'--filter\t<expr>\tFilter output based on conditions'
)

typeset -ga _LUMEN_DOCKER_IMAGE_LS_FLAGS=("${_LUMEN_DOCKER_IMAGES_FLAGS[@]}")

typeset -ga _LUMEN_DOCKER_RUN_FLAGS=(
  $'-d\t\tRun container in the background'
  $'-it\t\tInteractive session with a tty attached'
  $'--rm\t\tAutomatically remove the container on exit'
  $'-p\t<host>:<container>\tPublish a container port to the host'
  $'-v\t<host>:<container>\tBind mount a volume'
  $'--name\t<name>\tAssign a name to the container'
  $'-e\t<key>=<value>\tSet an environment variable'
)

typeset -ga _LUMEN_DOCKER_RMI_FLAGS=(
  $'-f\t\tForce removal, even if the image has multiple tags or is in use\t1'
  $'--force\t\tForce removal, even if the image has multiple tags or is in use\t1'
)

typeset -ga _LUMEN_DOCKER_START_FLAGS=(
  $'-a\t\tAttach to the container'"'"'s output'
  $'-i\t\tAttach the container'"'"'s stdin, keeping it interactive'
)

typeset -ga _LUMEN_DOCKER_EXEC_FLAGS=(
  $'-it\t\tInteractive session with a tty attached'
  $'-d\t\tRun the command in the background'
  $'-u\t<user>\tRun as a specific user'
  $'-w\t<dir>\tWorking directory inside the container'
)

typeset -ga _LUMEN_DOCKER_LOGS_FLAGS=(
  $'-f\t\tFollow log output'
  $'--tail\t<n>\tShow only the last n lines'
  $'-t\t\tShow timestamps'
)

typeset -ga _LUMEN_DOCKER_BUILD_FLAGS=(
  $'-t\t<tag>\tTag the built image (e.g. name:latest)'
  $'-f\t<dockerfile>\tUse an alternate Dockerfile'
  $'--no-cache\t\tDo not use cache when building'
)
typeset -ga _LUMEN_DOCKER_IMAGE_BUILD_FLAGS=("${_LUMEN_DOCKER_BUILD_FLAGS[@]}")

typeset -ga _LUMEN_DOCKER_IMAGE_SAVE_FLAGS=(
  $'-o\t<file>\tWrite the image to a file instead of stdout'
)

typeset -ga _LUMEN_DOCKER_IMAGE_LOAD_FLAGS=(
  $'-i\t<file>\tRead the image from a file instead of stdin'
)

typeset -ga _LUMEN_DOCKER_CONTAINER_EXEC_FLAGS=("${_LUMEN_DOCKER_EXEC_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_CONTAINER_LS_FLAGS=("${_LUMEN_DOCKER_PS_FLAGS[@]}")

typeset -ga _LUMEN_DOCKER_IMAGE_RM_FLAGS=("${_LUMEN_DOCKER_RMI_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_IMAGE_PRUNE_FLAGS=(
  $'-a\t\tRemove all unused images, not just dangling ones'
)
typeset -ga _LUMEN_DOCKER_SYSTEM_PRUNE_FLAGS=(
  $'-a\t\tRemove all unused images too, not just dangling ones'
)
typeset -ga _LUMEN_DOCKER_NETWORK_PRUNE_FLAGS=(
  $'-f\t\tDon'"'"'t prompt for confirmation'
  $'--force\t\tDon'"'"'t prompt for confirmation'
)
typeset -ga _LUMEN_DOCKER_VOLUME_PRUNE_FLAGS=("${_LUMEN_DOCKER_NETWORK_PRUNE_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_COMPOSE_UP_FLAGS=(
  $'-d\t\tRun containers in the background'
  $'--build\t\tBuild images before starting containers'
  $'--force-recreate\t\tRecreate containers even if their configuration hasn'"'"'t changed'
)

typeset -ga _LUMEN_DOCKER_STOP_FLAGS=(
  $'-t\t<seconds>\tSeconds to wait before killing the container (default 10)'
  $'--time\t<seconds>\tSeconds to wait before killing the container (default 10)'
)

typeset -ga _LUMEN_DOCKER_RM_FLAGS=(
  $'-f\t\tForce removal of a running container\t1'
  $'--force\t\tForce removal of a running container\t1'
  $'-v\t\tAlso remove anonymous volumes associated with the container'
)

typeset -ga _LUMEN_DOCKER_RESTART_FLAGS=(
  $'-t\t<seconds>\tSeconds to wait before killing the container (default 10)'
  $'--time\t<seconds>\tSeconds to wait before killing the container (default 10)'
)

typeset -ga _LUMEN_DOCKER_KILL_FLAGS=(
  $'-s\t<signal>\tSignal to send (default SIGKILL)'
  $'--signal\t<signal>\tSignal to send (default SIGKILL)'
)
typeset -ga _LUMEN_DOCKER_CONTAINER_RM_FLAGS=("${_LUMEN_DOCKER_RM_FLAGS[@]}")
# "docker container <x>" is the modern long form of "docker <x>" for
# run/logs/stop/start — same flags, so alias rather than duplicate.
typeset -ga _LUMEN_DOCKER_CONTAINER_RUN_FLAGS=("${_LUMEN_DOCKER_RUN_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_CONTAINER_LOGS_FLAGS=("${_LUMEN_DOCKER_LOGS_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_CONTAINER_STOP_FLAGS=("${_LUMEN_DOCKER_STOP_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_CONTAINER_START_FLAGS=("${_LUMEN_DOCKER_START_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_CONTAINER_PRUNE_FLAGS=(
  $'-f\t\tDon'"'"'t prompt for confirmation'
  $'--force\t\tDon'"'"'t prompt for confirmation'
)

typeset -ga _LUMEN_DOCKER_COMPOSE_DOWN_FLAGS=(
  $'-v\t\tAlso remove named volumes declared in the compose file'
  $'--volumes\t\tAlso remove named volumes declared in the compose file'
  $'--rmi\t<all|local>\tAlso remove images used by the services'
)

typeset -ga _LUMEN_DOCKER_COMPOSE_LOGS_FLAGS=(
  $'-f\t\tFollow log output'
  $'--follow\t\tFollow log output'
  $'--tail\t<n>\tShow only the last n lines'
)

typeset -ga _LUMEN_DOCKER_COMPOSE_EXEC_FLAGS=("${_LUMEN_DOCKER_EXEC_FLAGS[@]}")
typeset -ga _LUMEN_DOCKER_COMPOSE_BUILD_FLAGS=(
  $'--no-cache\t\tBuild without using any cached layers'
)

typeset -ga _LUMEN_GIT_STASH_SUBCMDS=(
  $'push\t\tStash changes'
  $'pop\t\tApply and remove the most recent stash'
  $'apply\t[stash]\tApply a stash without removing it'
  $'list\t\tList stashes'
  $'show\t[stash]\tShow the changes in a stash'
  $'drop\t[stash]\tRemove a stash'
  $'clear\t\tRemove all stashes'
)

typeset -ga _LUMEN_GIT_STASH_PUSH_FLAGS=(
  $'-m\t<message>\tLabel the stash with a message'
)

typeset -ga _LUMEN_GIT_REMOTE_SUBCMDS=(
  $'-v\t\tShow remote URLs'
  $'add\t<name> <url>\tAdd a remote'
  $'remove\t<name>\tRemove a remote'
  $'rename\t<old> <new>\tRename a remote'
  $'set-url\t<name> <url>\tChange a remote'"'"'s URL'
  $'show\t<name>\tShow information about a remote'
  $'prune\t<name>\tRemove stale remote-tracking branches'
)

typeset -ga _LUMEN_GIT_REMOTE_FLAGS=(
  $'-v\t\tShow remote URLs'
)

typeset -ga _LUMEN_GIT_LOG_FLAGS=(
  $'--oneline\t\tOne line per commit'
  $'--graph\t\tDraw a text-based commit graph'
  $'-p\t\tShow the full diff for each commit'
  $'--stat\t\tShow a diffstat for each commit'
  $'-n\t<count>\tLimit the number of commits'
)

typeset -ga _LUMEN_GIT_BRANCH_FLAGS=(
  $'-a\t\tList both local and remote branches'
  $'-d\t<branch>\tDelete a branch'
  $'-D\t<branch>\tForce-delete a branch\t1'
  $'-m\t<old> <new>\tRename a branch'
  $'-v\t\tShow last commit on each branch'
)

typeset -ga _LUMEN_GIT_CHECKOUT_FLAGS=(
  $'-b\t<branch>\tCreate and switch to a new branch'
  $'--track\t<remote-branch>\tCreate a tracking branch'
  $'-f\t\tForce checkout, discarding local changes\t1'
)

typeset -ga _LUMEN_GIT_DIFF_FLAGS=(
  $'--stat\t\tShow a diffstat instead of the full diff'
  $'--cached\t\tShow staged changes'
  $'-p\t\tGenerate output in patch format (default)'
)

# Picked up by _lumen_nested_match once BUFFER is "git commit " —
# same leaf-command-falls-back-to-its-FLAGS-table path already used by
# docker images/ps/run, git log/branch/checkout/diff, kubectl get/exec (see
# that function's comment on the empty-partial fallback). Moved out of
# _LUMEN_GIT_SUBCMDS's own hint text (used to be "commit -m <message>"
# shown together on one row) so "-m" is its own follow-up suggestion after
# "commit" is picked, instead of looking like part of the subcommand name.
typeset -ga _LUMEN_GIT_COMMIT_FLAGS=(
  $'-m\t<message>\tRecord changes with the given commit message'
  $'-a\t\tStage all tracked, modified files before committing'
  $'--amend\t\tReplace the tip of the current branch with a new commit'
)

typeset -ga _LUMEN_GIT_PUSH_FLAGS=(
  $'--force-with-lease\t\tForce-push, but abort if the remote has commits you haven'"'"$'t seen\t1'
  $'-f\t\tForce-push, overwriting the remote branch unconditionally\t1'
  $'--force\t\tForce-push, overwriting the remote branch unconditionally\t1'
  $'-u\t\tSet the upstream (tracking) branch for this push'
  $'--set-upstream\t\tSet the upstream (tracking) branch for this push'
  $'--tags\t\tPush tags along with commits'
  $'--delete\t<branch>\tDelete a remote branch\t1'
)

typeset -ga _LUMEN_GIT_REBASE_FLAGS=(
  $'-i\t\tInteractively edit, squash, or reorder commits before replaying them'
  $'--continue\t\tResume a rebase after resolving a conflict'
  $'--abort\t\tCancel the rebase and restore the branch to its pre-rebase state'
  $'--skip\t\tSkip the current commit and continue the rebase'
  $'--onto\t<newbase>\tRebase onto a different base than the one rebase would pick'
)

typeset -ga _LUMEN_GIT_MERGE_FLAGS=(
  $'--no-ff\t\tAlways create a merge commit, even if a fast-forward is possible'
  $'--squash\t\tCombine all incoming commits into one set of pending changes'
  $'--abort\t\tCancel the merge and restore the pre-merge state'
  $'-m\t<message>\tSet the merge commit message'
)

typeset -ga _LUMEN_GIT_ADD_FLAGS=(
  $'-p\t\tInteractively choose which hunks to stage'
  $'-A\t\tStage all changes, including new and deleted files'
  $'-u\t\tStage modified and deleted files, but not new ones'
  $'-n\t\tShow what would be staged without staging it'
)

typeset -ga _LUMEN_GIT_PULL_FLAGS=(
  $'--rebase\t\tRebase local commits on top of the fetched branch instead of merging'
  $'--no-rebase\t\tMerge the fetched branch instead of rebasing'
  $'--ff-only\t\tRefuse to pull unless it can fast-forward'
)

typeset -ga _LUMEN_GIT_FETCH_FLAGS=(
  $'--all\t\tFetch all remotes'
  $'--prune\t\tRemove remote-tracking branches that no longer exist on the remote'
  $'--tags\t\tFetch all tags'
)

typeset -ga _LUMEN_GIT_TAG_FLAGS=(
  $'-a\t<tagname>\tCreate an annotated tag'
  $'-d\t<tagname>\tDelete a tag'
  $'-l\t\tList tags'
  $'-m\t<message>\tSet the annotated tag'"'"'s message'
)

typeset -ga _LUMEN_GIT_CHERRY_PICK_FLAGS=(
  $'--continue\t\tResume after resolving a conflict'
  $'--abort\t\tCancel the cherry-pick and restore the pre-cherry-pick state'
  $'-x\t\tAppend a line noting which commit this was cherry-picked from'
  $'-n\t\tApply the changes without committing'
)

typeset -ga _LUMEN_GIT_RESTORE_FLAGS=(
  $'--staged\t\tUnstage: restore the index from HEAD, leaving the working tree alone'
  $'--source\t<commit>\tRestore from a specific commit instead of the index'
  $'-p\t\tInteractively choose which hunks to restore'
)

typeset -ga _LUMEN_GIT_SWITCH_FLAGS=(
  $'-c\t<branch>\tCreate a new branch and switch to it'
  $'--create\t<branch>\tCreate a new branch and switch to it'
)

typeset -ga _LUMEN_GIT_REVERT_FLAGS=(
  $'-n\t\tApply the revert without committing'
  $'--no-commit\t\tApply the revert without committing'
  $'--continue\t\tResume after resolving a conflict'
  $'--abort\t\tCancel the revert and restore the pre-revert state'
)

typeset -ga _LUMEN_GIT_RM_FLAGS=(
  $'--cached\t\tUntrack the file, keeping it on disk'
  $'-r\t\tRemove a directory recursively'
)

typeset -ga _LUMEN_GIT_CLONE_FLAGS=(
  $'--depth\t<n>\tCreate a shallow clone with history truncated to n commits'
  $'-b\t<branch>\tClone and check out a specific branch'
  $'--branch\t<branch>\tClone and check out a specific branch'
  $'--recurse-submodules\t\tAlso clone and initialize submodules'
)

typeset -ga _LUMEN_GIT_CLEAN_FLAGS=(
  $'-f\t\tForce the removal\t1'
  $'-d\t\tAlso remove untracked directories'
)

typeset -ga _LUMEN_GIT_RESET_FLAGS=(
  $'--soft\t\tMove HEAD only; keep the index and working tree unchanged'
  $'--mixed\t\tMove HEAD and reset the index; keep the working tree unchanged (default)'
  $'--hard\t\tMove HEAD and reset the index AND working tree, discarding local changes\t1'
  $'--merge\t\tReset the index and HEAD, but keep uncommitted changes not touched by the reset'
  $'--keep\t\tLike --merge, but abort if the reset would touch uncommitted changes'
)

typeset -ga _LUMEN_NPM_CACHE_SUBCMDS=(
  $'clean\t\tClean the npm cache'
  $'verify\t\tVerify the npm cache'
  $'add\t<package>\tAdd a package to the cache'
  $'ls\t\tList the contents of the cache'
)

typeset -ga _LUMEN_NPM_INSTALL_FLAGS=(
  $'--save-dev\t\tSave to devDependencies'
  $'--save-exact\t\tPin the exact installed version'
  $'-g\t\tInstall globally'
  $'--legacy-peer-deps\t\tIgnore peer dependency conflicts'
)

typeset -ga _LUMEN_NPM_CI_FLAGS=(
  $'--production\t\tSkip devDependencies'
  $'--legacy-peer-deps\t\tIgnore peer dependency conflicts'
)

typeset -ga _LUMEN_NPM_UNINSTALL_FLAGS=(
  $'--save-dev\t\tAlso remove it from devDependencies'
  $'-g\t\tUninstall a global package'
)

typeset -ga _LUMEN_NPM_UPDATE_FLAGS=(
  $'--save\t\tUpdate the version ranges in package.json too'
  $'-g\t\tUpdate global packages'
)

typeset -ga _LUMEN_NPM_PUBLISH_FLAGS=(
  $'--tag\t<tag>\tPublish under a dist-tag other than latest'
  $'--access\t<public|restricted>\tSet package visibility'
  $'--dry-run\t\tShow what would be published without publishing it'
  $'--otp\t<code>\tOne-time password for accounts with 2FA'
)

typeset -ga _LUMEN_NPM_RUN_FLAGS=(
  $'--silent\t\tSuppress npm'"'"'s own log output for the script'
  $'--if-present\t\tExit quietly if the script isn'"'"'t defined'
)

typeset -ga _LUMEN_KUBECTL_CONFIG_SUBCMDS=(
  $'get-contexts\t\tList the available contexts'
  $'use-context\t<name>\tSet the current context'
  $'current-context\t\tDisplay the current context'
  $'set-context\t<name>\tSet a context entry (--namespace / --cluster / --user)'
  $'view\t\tDisplay the merged kubeconfig'
  $'delete-context\t<name>\tDelete a context'
  $'rename-context\t<old> <new>\tRename a context'
  $'set-cluster\t<name>\tSet a cluster entry'
  $'set-credentials\t<name>\tSet a user entry'
  $'get-clusters\t\tList the clusters defined in the kubeconfig'
  $'get-users\t\tList the users defined in the kubeconfig'
  $'unset\t<property>\tUnset an individual value in the kubeconfig'
)

typeset -ga _LUMEN_KUBECTL_ROLLOUT_SUBCMDS=(
  $'status\t<resource>\tShow the status of a rollout'
  $'undo\t<resource>\tRoll back to a previous revision'
  $'restart\t<resource>\tRestart a resource'
  $'history\t<resource>\tShow rollout history'
  $'pause\t<resource>\tMark a rollout as paused'
  $'resume\t<resource>\tResume a paused rollout'
)

typeset -ga _LUMEN_KUBECTL_ROLLOUT_UNDO_FLAGS=(
  $'--to-revision\t<n>\tRoll back to a specific revision instead of the previous one'
)

typeset -ga _LUMEN_KUBECTL_GET_FLAGS=(
  $'-o\t<format>\tOutput format (json|yaml|wide|name|jsonpath=...|custom-columns=...)'
  $'-n\t<namespace>\tNamespace to query'
  $'-A\t\tList across all namespaces'
  $'--all-namespaces\t\tList across all namespaces'
  $'-l\t<selector>\tFilter by label selector (e.g. app=web,tier!=cache)'
  $'--field-selector\t<sel>\tFilter by field (e.g. status.phase=Running)'
  $'-w\t\tWatch for changes'
  $'--show-labels\t\tShow all labels as the last column'
  $'--sort-by\t<jsonpath>\tSort the rows by this field'
  $'--no-headers\t\tOmit the header row'
)

typeset -ga _LUMEN_KUBECTL_EXEC_FLAGS=(
  $'-it\t\tInteractive session with a tty attached'
  $'-i\t\tKeep stdin open on the container'
  $'-t\t\tAllocate a tty'
  $'-c\t<container>\tContainer within the pod, if it has more than one'
  $'-n\t<namespace>\tNamespace of the target pod'
  $'--\t<cmd> [args...]\tEverything after -- is the command to run in the container'
)

typeset -ga _LUMEN_KUBECTL_APPLY_FLAGS=(
  $'-f\t<file>\tApply a configuration from a file, directory, or URL'
  $'-k\t<dir>\tApply a kustomization directory'
  $'-R\t\tRecurse into directories given to -f'
  $'--server-side\t\tApply on the API server (server-side apply)'
  $'--prune\t\tDelete resources no longer in the applied set\t1'
  $'--dry-run\t<client|server>\tPreview without persisting changes'
  $'-n\t<namespace>\tNamespace to apply into'
)

typeset -ga _LUMEN_KUBECTL_CREATE_FLAGS=(
  $'-f\t<file>\tCreate a resource from a file or stdin'
  $'-k\t<dir>\tCreate from a kustomization directory'
  $'--dry-run\t<client|server>\tPreview without persisting the change'
  $'--save-config\t\tKeep the config so it can be used by future kubectl apply calls'
  $'--validate\t<true|false|strict|warn|ignore>\tValidate the object against its schema'
  $'-n\t<namespace>\tNamespace to create into'
)

typeset -ga _LUMEN_KUBECTL_SCALE_FLAGS=(
  $'--replicas\t<n>\tSet the desired number of replicas'
  $'--current-replicas\t<n>\tOnly scale if the current replica count matches'
  $'-n\t<namespace>\tNamespace of the workload'
  $'--all\t\tScale all resources of the given type in the namespace'
)

typeset -ga _LUMEN_KUBECTL_EXPOSE_FLAGS=(
  $'--port\t<port>\tPort the new Service listens on'
  $'--target-port\t<port>\tPort on the pod containers to forward to'
  $'--protocol\t<TCP|UDP|SCTP>\tProtocol for the Service (default TCP)'
  $'--name\t<name>\tName for the new Service (defaults to the source resource name)'
  $'--type\t<ClusterIP|NodePort|LoadBalancer|ExternalName>\tService type to create'
  $'--selector\t<k=v,...>\tSelector instead of the source resource labels'
  $'-l\t<k=v,...>\tLabels to apply to the new Service'
  $'--external-ip\t<ip>\tAdditional external IP to accept traffic for'
  $'--session-affinity\t<None|ClientIP>\tEnable sticky sessions'
  $'--dry-run\t<client|server>\tPreview without creating the Service'
  $'-n\t<namespace>\tNamespace to create the Service in'
)

typeset -ga _LUMEN_KUBECTL_DELETE_FLAGS=(
  $'--force\t\tSkip graceful termination (use with --grace-period=0 on a stuck pod)\t1'
  $'--grace-period\t<seconds>\tSeconds to allow for graceful termination; 0 forces immediate deletion'
  $'--now\t\tShut down with a 1-second grace period'
  $'-n\t<namespace>\tNamespace of the resource'
  $'-l\t<selector>\tDelete every resource matching this label selector\t1'
  $'-f\t<file>\tDelete the resources described in a file'
  $'--all\t\tDelete all resources of the given type in the namespace\t1'
)

typeset -ga _LUMEN_KUBECTL_LOGS_FLAGS=(
  $'-f\t\tStream logs continuously'
  $'--follow\t\tStream logs continuously'
  $'--previous\t\tShow logs from the previous (crashed/restarted) instance of the container'
  $'--tail\t<n>\tShow only the last n lines'
  $'--since\t<dur>\tOnly logs newer than this (e.g. 10m, 1h)'
  $'--timestamps\t\tPrefix every line with an RFC3339 timestamp'
  $'--all-containers\t\tGet logs from every container in the pod'
  $'-n\t<namespace>\tNamespace of the pod'
  $'-c\t<container>\tContainer within the pod, if it has more than one'
)

typeset -ga _LUMEN_KUBECTL_RUN_FLAGS=(
  $'-it\t\tAttach an interactive TTY to the container'
  $'--rm\t\tDelete the pod once it exits'
  $'--image\t<image>\tImage to run'
  $'--restart\t<Always|OnFailure|Never>\tRestart policy for the created pod'
  $'--env\t<KEY=VALUE>\tSet an environment variable (repeatable)'
  $'--port\t<port>\tPort the container exposes'
  $'--command\t-- <cmd>\tUse the args after -- as the entrypoint, not arguments'
  $'--dry-run\t<client|server>\tPreview the object without creating it'
  $'-n\t<namespace>\tNamespace to run the pod in'
)

typeset -ga _LUMEN_KUBECTL_PORT_FORWARD_FLAGS=(
  $'--address\t<addr>\tLocal addresses to listen on (default 127.0.0.1)'
  $'-n\t<namespace>\tNamespace of the target pod'
)

typeset -ga _LUMEN_KUBECTL_ATTACH_FLAGS=(
  $'-i\t\tKeep stdin open on the container'
  $'-t\t\tAllocate a tty'
  $'-c\t<container>\tContainer within the pod, if it has more than one'
  $'--pod-running-timeout\t<dur>\tHow long to wait for the pod to start running (default 1m0s)'
  $'-n\t<namespace>\tNamespace of the target pod'
)

# --- deeper kubectl sub-subcommand tables (picked up by _lumen_nested_match
# via the _LUMEN_KUBECTL_<PATH>_SUBCMDS / _FLAGS naming convention) ----------

typeset -ga _LUMEN_KUBECTL_SET_SUBCMDS=(
  $'image\t<type>/<name> <container>=<img>\tUpdate the image of a pod template'
  $'env\t<type>/<name> <KEY>=<VALUE>\tSet environment variables on a pod template'
  $'resources\t<type>/<name>\tSet CPU/memory requests and limits'
  $'serviceaccount\t<type>/<name> <sa>\tSet the ServiceAccount of a pod template'
  $'selector\t<type>/<name> <k>=<v>\tSet the selector on a resource'
  $'subject\t<rolebinding> --user/--group\tUpdate the subjects of a RoleBinding'
)

typeset -ga _LUMEN_KUBECTL_SET_IMAGE_FLAGS=(
  $'--dry-run\t<client|server>\tPreview without persisting the change'
  $'--local\t\tRun the command against the input, not the live cluster'
  $'-n\t<namespace>\tNamespace of the resource'
  $'--all\t\tApply to every resource in the namespace of the given type'
)

typeset -ga _LUMEN_KUBECTL_SET_ENV_FLAGS=(
  $'--list\t\tList the currently set environment variables'
  $'--overwrite\t<true|false>\tAllow overwriting an already-set variable (default true)'
  $'--from\t<configmap|secret>:<name>\tPopulate variables from a ConfigMap or Secret'
  $'--dry-run\t<client|server>\tPreview without persisting the change'
  $'-n\t<namespace>\tNamespace of the resource'
)

typeset -ga _LUMEN_KUBECTL_SET_RESOURCES_FLAGS=(
  $'--limits\t<cpu=,memory=>\tSet resource limits (e.g. cpu=200m,memory=512Mi)'
  $'--requests\t<cpu=,memory=>\tSet resource requests (e.g. cpu=100m,memory=256Mi)'
  $'--dry-run\t<client|server>\tPreview without persisting the change'
  $'-n\t<namespace>\tNamespace of the resource'
)

typeset -ga _LUMEN_KUBECTL_SET_SERVICEACCOUNT_FLAGS=(
  $'--dry-run\t<client|server>\tPreview without persisting the change'
  $'-n\t<namespace>\tNamespace of the resource'
)

typeset -ga _LUMEN_KUBECTL_SET_SELECTOR_FLAGS=(
  $'--resource-version\t<v>\tOnly update if this matches the current resource version'
  $'--dry-run\t<client|server>\tPreview without persisting the change'
  $'-n\t<namespace>\tNamespace of the resource'
)

typeset -ga _LUMEN_KUBECTL_AUTH_SUBCMDS=(
  $'can-i\t<verb> <resource>\tCheck whether an action is allowed'
  $'whoami\t\tShow the identity kubectl is authenticating as'
  $'reconcile\t-f <file>\tReconcile RBAC role and rolebinding objects'
)

typeset -ga _LUMEN_KUBECTL_AUTH_CAN_I_FLAGS=(
  $'--list\t\tList everything the current user is allowed to do'
  $'--as\t<user>\tCheck as another user (impersonation)'
  $'-A\t\tCheck across all namespaces'
  $'-n\t<namespace>\tNamespace to check in'
)

typeset -ga _LUMEN_KUBECTL_TOP_SUBCMDS=(
  $'pod\t[name]\tShow CPU/memory usage for pods'
  $'node\t[name]\tShow CPU/memory usage for nodes'
)

typeset -ga _LUMEN_KUBECTL_TOP_POD_FLAGS=(
  $'-n\t<namespace>\tNamespace to query'
  $'-A\t\tShow pods across all namespaces'
  $'--containers\t\tBreak the usage out per container'
  $'-l\t<selector>\tFilter by label selector'
  $'--sort-by\t<cpu|memory>\tSort the rows by this metric'
)

typeset -ga _LUMEN_KUBECTL_TOP_NODE_FLAGS=(
  $'--sort-by\t<cpu|memory>\tSort the rows by this metric'
  $'--no-headers\t\tOmit the header row'
)

typeset -ga _LUMEN_KUBECTL_CERTIFICATE_SUBCMDS=(
  $'approve\t<csr>\tApprove a CertificateSigningRequest'
  $'deny\t<csr>\tDeny a CertificateSigningRequest'
)

typeset -ga _LUMEN_KUBECTL_PLUGIN_SUBCMDS=(
  $'list\t\tList the kubectl plugins found on $PATH'
)

typeset -ga _LUMEN_KUBECTL_DESCRIBE_FLAGS=(
  $'-n\t<namespace>\tNamespace of the resource'
  $'-A\t\tDescribe matching resources across all namespaces'
  $'-l\t<selector>\tDescribe every resource matching this label selector'
  $'--show-events\t\tInclude the related events (default true)'
)

typeset -ga _LUMEN_KUBECTL_DEBUG_FLAGS=(
  $'-it\t\tAttach an interactive TTY to the debug container'
  $'--image\t<image>\tImage to use for the debug container'
  $'--target\t<container>\tShare the process namespace of this container'
  $'--profile\t<profile>\tDebugging profile (legacy|general|baseline|restricted|netadmin)'
  $'-c\t<name>\tName to give the new debug container'
  $'--copy-to\t<name>\tCopy the pod into a new one with this name instead of editing it'
  $'-n\t<namespace>\tNamespace of the target'
)

typeset -ga _LUMEN_KUBECTL_WAIT_FLAGS=(
  $'--for\t<condition>\tWhat to wait for (e.g. condition=Ready, delete, jsonpath=...)'
  $'--timeout\t<dur>\tHow long to wait before giving up (e.g. 60s, 5m; 0 = forever)'
  $'-n\t<namespace>\tNamespace of the resource'
  $'--all\t\tWait on every resource of the given type in the namespace'
  $'-l\t<selector>\tWait on resources matching this label selector'
)

typeset -ga _LUMEN_KUBECTL_DRAIN_FLAGS=(
  $'--ignore-daemonsets\t\tDon'"'"'t fail on DaemonSet-managed pods'
  $'--delete-emptydir-data\t\tAllow eviction of pods using emptyDir volumes (data is lost)\t1'
  $'--force\t\tAlso evict pods not managed by a controller\t1'
  $'--grace-period\t<seconds>\tGrace period for each pod eviction; -1 uses the pod default'
  $'--timeout\t<dur>\tGive up after this long'
  $'--disable-eviction\t\tForce-delete pods, bypassing PodDisruptionBudgets\t1'
)

typeset -ga _LUMEN_KUBECTL_ROLLOUT_STATUS_FLAGS=(
  $'-w\t\tWatch the rollout status until it finishes (default true)'
  $'--timeout\t<dur>\tGive up watching after this long (0 = forever)'
  $'--revision\t<n>\tPin the status check to a specific revision'
  $'-n\t<namespace>\tNamespace of the workload'
)

typeset -ga _LUMEN_KUBECTL_ROLLOUT_RESTART_FLAGS=(
  $'-n\t<namespace>\tNamespace of the workload'
  $'-l\t<selector>\tRestart every workload matching this label selector'
)

# Resource-type words kubectl itself accepts (plural, plus the short alias
# in the hint column) — used by _lumen_kubectl_resource_match to complete
# the TYPE word of "kubectl get <type>" / "describe <type> <name>" / ...
# Hand-picked common set ordered by how often each is reached for; kubectl
# knows a few hundred more once CRDs are counted, this is the fast path.
typeset -ga _LUMEN_KUBECTL_RESOURCE_TYPES=(
  $'pods\tpo\tSmallest deployable compute units'
  $'services\tsvc\tStable network endpoint for a set of pods'
  $'deployments\tdeploy\tDeclarative updates for pods and ReplicaSets'
  $'replicasets\trs\tKeeps a stable set of replica pods running'
  $'statefulsets\tsts\tWorkloads with a stable identity and storage'
  $'daemonsets\tds\tRuns a pod on every (matching) node'
  $'jobs\t\tRun-to-completion workloads'
  $'cronjobs\tcj\tJobs on a repeating schedule'
  $'configmaps\tcm\tNon-confidential key/value configuration'
  $'secrets\t\tConfidential key/value data'
  $'ingresses\ting\tHTTP/S routing rules into the cluster'
  $'namespaces\tns\tVirtual cluster partitions'
  $'nodes\tno\tWorker machines in the cluster'
  $'persistentvolumeclaims\tpvc\tA pod'"'"'s request for storage'
  $'persistentvolumes\tpv\tA piece of provisioned cluster storage'
  $'endpoints\tep\tThe backing addresses for a Service'
  $'serviceaccounts\tsa\tIdentity for the processes in a pod'
  $'events\tev\tCluster events (also: kubectl events)'
  $'horizontalpodautoscalers\thpa\tScales a workload on observed metrics'
  $'replicationcontrollers\trc\tLegacy pod replication (prefer Deployments)'
  $'roles\t\tNamespaced RBAC permission set'
  $'rolebindings\t\tGrants a Role within a namespace'
  $'clusterroles\t\tCluster-wide RBAC permission set'
  $'clusterrolebindings\t\tGrants a ClusterRole cluster-wide'
  $'storageclasses\tsc\tClasses of dynamically provisioned storage'
  $'networkpolicies\tnetpol\tPod-level network traffic rules'
  $'poddisruptionbudgets\tpdb\tCaps how many pods a disruption may remove'
  $'resourcequotas\tquota\tConstrains aggregate resource usage in a namespace'
  $'limitranges\tlimits\tDefault / min / max limits per object'
  $'customresourcedefinitions\tcrd\tExtends the API with new resource kinds'
  # Group-qualified forms (RESOURCE.GROUP), the spelling `kubectl explain`
  # and `kubectl api-resources` print — reach for these to disambiguate
  # from a same-named CRD. Listed last because the bare plural above is
  # what you type day to day; matched only once you'"'"'ve typed past the ".".
  $'deployments.apps\t\tapps/v1 Deployment, fully qualified'
  $'replicasets.apps\t\tapps/v1 ReplicaSet, fully qualified'
  $'statefulsets.apps\t\tapps/v1 StatefulSet, fully qualified'
  $'daemonsets.apps\t\tapps/v1 DaemonSet, fully qualified'
  $'jobs.batch\t\tbatch/v1 Job, fully qualified'
  $'cronjobs.batch\t\tbatch/v1 CronJob, fully qualified'
  $'ingresses.networking.k8s.io\t\tnetworking.k8s.io/v1 Ingress, fully qualified'
)

# `kubectl rollout` only operates on these four kinds — a much shorter list
# than the full resource table, so _lumen_kubectl_resource_match swaps to
# it when the verb is rollout instead of offering "rollout status secrets".
typeset -ga _LUMEN_KUBECTL_ROLLOUT_TYPES=(
  $'deployments\tdeploy\tDeclarative updates for pods and ReplicaSets'
  $'daemonsets\tds\tRuns a pod on every (matching) node'
  $'statefulsets\tsts\tWorkloads with a stable identity and storage'
  $'replicasets\trs\tKeeps a stable set of replica pods running'
  $'deployments.apps\t\tapps/v1 Deployment, fully qualified'
  $'daemonsets.apps\t\tapps/v1 DaemonSet, fully qualified'
  $'statefulsets.apps\t\tapps/v1 StatefulSet, fully qualified'
  $'replicasets.apps\t\tapps/v1 ReplicaSet, fully qualified'
)

# Last-resort fallback when typing "-" at a position with no hand-picked
# *_FLAGS table of its own (most subcommands don't have one — only the ones
# above do) — so "something" always shows up instead of nothing. These are
# widely-adopted CLI conventions (getopt-style long/short pairs most tools
# that support the concept at all spell the same way), not universal
# guarantees — a given subcommand may not implement a given one. That's an
# acceptable tradeoff for a fallback of last resort: an offered flag that
# a particular tool happens not to support is a no-op/an error the user
# immediately sees and ignores, which costs far less than this table
# staying empty and suggesting nothing at all.
typeset -ga _LUMEN_GENERIC_FLAGS=(
  $'-h\t\tShow help for this command'
  $'--help\t\tShow help for this command'
  $'--version\t\tShow version information'
  $'-v\t\tEnable verbose output'
  $'--verbose\t\tEnable verbose output'
  $'-q\t\tSuppress non-essential output'
  $'--quiet\t\tSuppress non-essential output'
  $'--debug\t\tShow debug-level output'
  $'-y\t\tAutomatically answer yes to prompts'
  $'--yes\t\tAutomatically answer yes to prompts'
  $'-f\t\tForce the operation, skipping normal safety checks'
  $'--force\t\tForce the operation, skipping normal safety checks'
  $'-n\t\tDry run — show what would happen without making changes'
  $'--dry-run\t\tShow what would happen without making changes'
  $'-o\t<file>\tWrite output to a file'
  $'--output\t<file>\tWrite output to a file'
  $'--no-color\t\tDisable colored output'
  $'--json\t\tOutput in JSON format'
  $'--config\t<file>\tUse a specific configuration file'
)

typeset -ga _LUMEN_AWS_S3_SUBCMDS=(
  $'ls\t[s3://bucket[/prefix]]\tList buckets or objects'
  $'cp\t<src> <dst>\tCopy files to/from S3'
  $'sync\t<src> <dst>\tSync a directory tree with S3'
  $'mv\t<src> <dst>\tMove files to/from S3'
  $'rm\t<s3-path>\tRemove an object'
  $'mb\t<s3://bucket>\tCreate a bucket'
  $'rb\t<s3://bucket>\tRemove a bucket'
  $'presign\t<s3-path>\tGenerate a presigned URL'
)

typeset -ga _LUMEN_AWS_S3_SYNC_FLAGS=(
  $'--delete\t\tRemove destination files that don'"'"$'t exist in the source (destructive)\t1'
  $'--exclude\t<pattern>\tExclude files matching a pattern'
  $'--dryrun\t\tShow what would be synced without transferring anything'
)

typeset -ga _LUMEN_AWS_EC2_SUBCMDS=(
  $'describe-instances\t\tDescribe EC2 instances'
  $'start-instances\t\tStart an instance'
  $'stop-instances\t\tStop an instance'
  $'terminate-instances\t\tTerminate an instance'
  $'describe-security-groups\t\tDescribe security groups'
  $'describe-vpcs\t\tDescribe VPCs'
  $'describe-subnets\t\tDescribe subnets'
  $'describe-images\t\tDescribe AMIs'
  $'run-instances\t\tLaunch new instances'
  $'create-tags\t\tTag a resource'
)

typeset -ga _LUMEN_AWS_LAMBDA_SUBCMDS=(
  $'list-functions\t\tList Lambda functions'
  $'invoke\t\tInvoke a function'
  $'update-function-code\t\tUpdate function code'
  $'get-function\t\tGet function configuration'
  $'create-function\t\tCreate a function'
  $'delete-function\t\tDelete a function'
  $'list-layers\t\tList Lambda layers'
)

typeset -ga _LUMEN_AWS_IAM_SUBCMDS=(
  $'list-users\t\tList IAM users'
  $'list-roles\t\tList IAM roles'
  $'get-user\t\tGet the current or named IAM user'
  $'create-role\t\tCreate a role'
  $'attach-role-policy\t\tAttach a policy to a role'
  $'list-attached-role-policies\t\tList policies attached to a role'
  $'create-access-key\t\tCreate an access key'
)

typeset -ga _LUMEN_AWS_LOGS_SUBCMDS=(
  $'tail\t<log-group>\tTail a log group in real time'
  $'describe-log-groups\t\tList log groups'
  $'describe-log-streams\t\tList log streams'
  $'get-log-events\t\tGet log events'
  $'filter-log-events\t\tFilter log events by pattern'
)

typeset -ga _LUMEN_AWS_STS_SUBCMDS=(
  $'get-caller-identity\t\tShow the current IAM identity'
  $'assume-role\t\tAssume an IAM role'
)

typeset -ga _LUMEN_AWS_CLOUDFORMATION_SUBCMDS=(
  $'deploy\t\tDeploy a stack'
  $'describe-stacks\t\tDescribe stacks'
  $'create-stack\t\tCreate a stack'
  $'update-stack\t\tUpdate a stack'
  $'delete-stack\t\tDelete a stack'
  $'list-stacks\t\tList stacks'
  $'validate-template\t\tValidate a template'
)

typeset -ga _LUMEN_AWS_ECR_SUBCMDS=(
  $'get-login-password\t\tGet a password to authenticate to ECR'
  $'describe-repositories\t\tDescribe ECR repositories'
  $'create-repository\t\tCreate a repository'
  $'list-images\t\tList images in a repository'
)

typeset -ga _LUMEN_AWS_ECS_SUBCMDS=(
  $'list-clusters\t\tList ECS clusters'
  $'list-services\t\tList services in a cluster'
  $'list-tasks\t\tList tasks in a cluster'
  $'describe-services\t\tDescribe services'
  $'update-service\t\tUpdate a service'
  $'run-task\t\tRun a one-off task'
)

typeset -ga _LUMEN_AWS_EKS_SUBCMDS=(
  $'list-clusters\t\tList EKS clusters'
  $'describe-cluster\t\tDescribe a cluster'
  $'update-kubeconfig\t\tUpdate local kubeconfig for a cluster'
  $'create-cluster\t\tCreate a cluster'
)

typeset -ga _LUMEN_AWS_SSM_SUBCMDS=(
  $'start-session\t\tStart an interactive session on an instance'
  $'get-parameter\t\tGet a parameter value'
  $'put-parameter\t\tCreate or update a parameter'
  $'describe-parameters\t\tList parameters'
  $'send-command\t\tRun a command on managed instances'
)

# Follow-up flags for the AWS_*_SUBCMDS operations above — picked up by
# _lumen_nested_match once BUFFER is e.g. "aws ec2 start-instances "
# (same leaf-command-falls-back-to-its-FLAGS-table path as git commit/docker
# images; see that function's comment). Split out of each operation's own
# hint text so a required flag shows as its own follow-up suggestion
# instead of being pre-glued onto the operation name.
typeset -ga _LUMEN_AWS_EC2_START_INSTANCES_FLAGS=(
  $'--instance-ids\t<id>\tInstance ID(s) to start'
)
typeset -ga _LUMEN_AWS_EC2_STOP_INSTANCES_FLAGS=(
  $'--instance-ids\t<id>\tInstance ID(s) to stop'
)
typeset -ga _LUMEN_AWS_EC2_TERMINATE_INSTANCES_FLAGS=(
  $'--instance-ids\t<id>\tInstance ID(s) to terminate'
)
typeset -ga _LUMEN_AWS_EC2_RUN_INSTANCES_FLAGS=(
  $'--image-id\t<ami>\tAMI to launch instances from'
  $'--instance-type\t<type>\tInstance type (e.g. t3.micro)'
  $'--key-name\t<name>\tKey pair for SSH access'
  $'--security-group-ids\t<sg-id>\tSecurity group(s) to attach'
  $'--subnet-id\t<subnet-id>\tSubnet to launch into'
  $'--count\t<n>\tNumber of instances to launch'
)
typeset -ga _LUMEN_AWS_EC2_DESCRIBE_INSTANCES_FLAGS=(
  $'--instance-ids\t<id>\tLimit to specific instance ID(s)'
  $'--filters\t<Name=,Values=>\tFilter by attribute, e.g. Name=instance-type,Values=t3.micro'
  $'--query\t<jmespath>\tShape the output with a JMESPath expression'
)
typeset -ga _LUMEN_AWS_EC2_CREATE_TAGS_FLAGS=(
  $'--resources\t<id>\tResource(s) to tag'
  $'--tags\t<tags>\tTags to apply, e.g. Key=Name,Value=foo'
)

typeset -ga _LUMEN_AWS_LAMBDA_INVOKE_FLAGS=(
  $'--function-name\t<name>\tFunction to invoke (followed by an output file)'
)
typeset -ga _LUMEN_AWS_LAMBDA_UPDATE_FUNCTION_CODE_FLAGS=(
  $'--function-name\t<name>\tFunction to update'
)
typeset -ga _LUMEN_AWS_LAMBDA_GET_FUNCTION_FLAGS=(
  $'--function-name\t<name>\tFunction to look up'
)
typeset -ga _LUMEN_AWS_LAMBDA_CREATE_FUNCTION_FLAGS=(
  $'--function-name\t<name>\tName for the new function'
)
typeset -ga _LUMEN_AWS_LAMBDA_DELETE_FUNCTION_FLAGS=(
  $'--function-name\t<name>\tFunction to delete'
)

typeset -ga _LUMEN_AWS_IAM_GET_USER_FLAGS=(
  $'--user-name\t<name>\tUser to look up (omit for the current user)'
)
typeset -ga _LUMEN_AWS_IAM_CREATE_ROLE_FLAGS=(
  $'--role-name\t<name>\tName for the new role'
)
typeset -ga _LUMEN_AWS_IAM_ATTACH_ROLE_POLICY_FLAGS=(
  $'--role-name\t<name>\tRole to attach the policy to'
  $'--policy-arn\t<arn>\tARN of the policy to attach'
)
typeset -ga _LUMEN_AWS_IAM_LIST_ATTACHED_ROLE_POLICIES_FLAGS=(
  $'--role-name\t<name>\tRole to list policies for'
)
typeset -ga _LUMEN_AWS_IAM_CREATE_ACCESS_KEY_FLAGS=(
  $'--user-name\t<name>\tUser to create the key for'
)

typeset -ga _LUMEN_AWS_LOGS_DESCRIBE_LOG_STREAMS_FLAGS=(
  $'--log-group-name\t<name>\tLog group to list streams for'
)
typeset -ga _LUMEN_AWS_LOGS_GET_LOG_EVENTS_FLAGS=(
  $'--log-group-name\t<name>\tLog group to read from'
  $'--log-stream-name\t<stream>\tLog stream to read from'
)
typeset -ga _LUMEN_AWS_LOGS_FILTER_LOG_EVENTS_FLAGS=(
  $'--log-group-name\t<name>\tLog group to search'
)

typeset -ga _LUMEN_AWS_STS_ASSUME_ROLE_FLAGS=(
  $'--role-arn\t<arn>\tARN of the role to assume'
  $'--role-session-name\t<name>\tIdentifier for the assumed-role session'
)

typeset -ga _LUMEN_AWS_CLOUDFORMATION_DEPLOY_FLAGS=(
  $'--template-file\t<file>\tLocal template file to deploy'
  $'--stack-name\t<name>\tStack to create or update'
)
typeset -ga _LUMEN_AWS_CLOUDFORMATION_CREATE_STACK_FLAGS=(
  $'--stack-name\t<name>\tName for the new stack'
  $'--template-body\t<file>\tTemplate file for the stack'
)
typeset -ga _LUMEN_AWS_CLOUDFORMATION_UPDATE_STACK_FLAGS=(
  $'--stack-name\t<name>\tStack to update'
)
typeset -ga _LUMEN_AWS_CLOUDFORMATION_DELETE_STACK_FLAGS=(
  $'--stack-name\t<name>\tStack to delete'
)
typeset -ga _LUMEN_AWS_CLOUDFORMATION_VALIDATE_TEMPLATE_FLAGS=(
  $'--template-body\t<file>\tTemplate file to validate'
)

typeset -ga _LUMEN_AWS_ECR_CREATE_REPOSITORY_FLAGS=(
  $'--repository-name\t<name>\tName for the new repository'
)
typeset -ga _LUMEN_AWS_ECR_LIST_IMAGES_FLAGS=(
  $'--repository-name\t<name>\tRepository to list images in'
)

typeset -ga _LUMEN_AWS_ECS_LIST_SERVICES_FLAGS=(
  $'--cluster\t<cluster>\tCluster to list services in'
)
typeset -ga _LUMEN_AWS_ECS_LIST_TASKS_FLAGS=(
  $'--cluster\t<cluster>\tCluster to list tasks in'
)
typeset -ga _LUMEN_AWS_ECS_DESCRIBE_SERVICES_FLAGS=(
  $'--cluster\t<cluster>\tCluster the services run in'
  $'--services\t<svc>\tService(s) to describe'
)
typeset -ga _LUMEN_AWS_ECS_UPDATE_SERVICE_FLAGS=(
  $'--cluster\t<cluster>\tCluster the service runs in'
  $'--service\t<svc>\tService to update'
)
typeset -ga _LUMEN_AWS_ECS_RUN_TASK_FLAGS=(
  $'--cluster\t<cluster>\tCluster to run the task in'
  $'--task-definition\t<td>\tTask definition to run'
)

typeset -ga _LUMEN_AWS_EKS_DESCRIBE_CLUSTER_FLAGS=(
  $'--name\t<name>\tCluster to describe'
)
typeset -ga _LUMEN_AWS_EKS_UPDATE_KUBECONFIG_FLAGS=(
  $'--name\t<name>\tCluster to update kubeconfig for'
)
typeset -ga _LUMEN_AWS_EKS_CREATE_CLUSTER_FLAGS=(
  $'--name\t<name>\tName for the new cluster'
)

typeset -ga _LUMEN_AWS_SSM_START_SESSION_FLAGS=(
  $'--target\t<instance-id>\tInstance to start the session on'
)
typeset -ga _LUMEN_AWS_SSM_GET_PARAMETER_FLAGS=(
  $'--name\t<name>\tParameter to read'
)
typeset -ga _LUMEN_AWS_SSM_PUT_PARAMETER_FLAGS=(
  $'--name\t<name>\tParameter to create or update'
  $'--value\t<value>\tValue to store'
)
typeset -ga _LUMEN_AWS_SSM_SEND_COMMAND_FLAGS=(
  $'--document-name\t<doc>\tSSM document to run'
  $'--targets\t<targets>\tTarget instance(s)'
)

typeset -ga _LUMEN_TERRAFORM_STATE_SUBCMDS=(
  $'list\t[address]\tList resources in the state'
  $'show\t<address>\tShow attributes of a resource in the state'
  $'mv\t<src> <dst>\tMove an item in the state'
  $'rm\t<address>\tRemove an item from the state'
  $'pull\t\tFetch the state and output it to stdout'
  $'push\t<file>\tUpload a local state file to the remote state'
  $'replace-provider\t<from> <to>\tReplace a provider in the state'
)

typeset -ga _LUMEN_TERRAFORM_WORKSPACE_SUBCMDS=(
  $'list\t\tList workspaces'
  $'new\t<name>\tCreate a new workspace'
  $'select\t<name>\tSelect a workspace'
  $'delete\t<name>\tDelete a workspace'
  $'show\t\tShow the current workspace name'
)

typeset -ga _LUMEN_TERRAFORM_DESTROY_FLAGS=(
  $'-auto-approve\t\tSkip the interactive approval prompt before destroying'
  $'-target\t<address>\tOnly target a specific resource or module'
)

typeset -ga _LUMEN_TERRAFORM_APPLY_FLAGS=(
  $'-auto-approve\t\tSkip the interactive approval prompt before applying'
  $'-var\t<key=value>\tSet a value for an input variable'
  $'-var-file\t<file>\tSet variable values from a file'
  $'-target\t<address>\tOnly target a specific resource or module'
)

typeset -ga _LUMEN_TERRAFORM_PLAN_FLAGS=(
  $'-var\t<key=value>\tSet a value for an input variable'
  $'-var-file\t<file>\tSet variable values from a file'
  $'-out\t<file>\tSave the generated plan to a file'
  $'-target\t<address>\tOnly target a specific resource or module'
)

typeset -ga _LUMEN_TERRAFORM_INIT_FLAGS=(
  $'-upgrade\t\tUpgrade provider/module versions to the latest allowed by the config'
  $'-reconfigure\t\tReconfigure the backend, ignoring any saved configuration'
)

typeset -ga _LUMEN_HELM_REPO_SUBCMDS=(
  $'add\t<name> <url>\tAdd a chart repository'
  $'update\t\tUpdate information of available charts'
  $'list\t\tList chart repositories'
  $'remove\t<name>\tRemove a chart repository'
)

typeset -ga _LUMEN_HELM_INSTALL_FLAGS=(
  $'-f\t<file>\tSet values from a YAML file'
  $'--values\t<file>\tSet values from a YAML file'
  $'--set\t<key=value>\tSet a value on the command line'
  $'-n\t<namespace>\tNamespace to install into'
  $'--namespace\t<namespace>\tNamespace to install into'
  $'--dry-run\t\tSimulate the install without making changes'
  $'--create-namespace\t\tCreate the release namespace if it doesn'"'"'t exist'
  $'--atomic\t\tRoll back on failure; implies --wait'
  $'--version\t<constraint>\tChart version to install (e.g. 1.1.1 or ^2.0.0)'
  $'--wait\t\tWait until all resources are ready before marking the release successful'
)
typeset -ga _LUMEN_HELM_UPGRADE_FLAGS=("${_LUMEN_HELM_INSTALL_FLAGS[@]}")

typeset -ga _LUMEN_HELM_UNINSTALL_FLAGS=(
  $'--keep-history\t\tRemove resources but retain the release record for history/rollback'
  $'-n\t<namespace>\tNamespace of the release'
  $'--namespace\t<namespace>\tNamespace of the release'
  $'--dry-run\t\tSimulate the uninstall without removing anything'
)

typeset -ga _LUMEN_HELM_ROLLBACK_FLAGS=(
  $'-n\t<namespace>\tNamespace of the release'
  $'--namespace\t<namespace>\tNamespace of the release'
  $'--wait\t\tWait until all resources are ready before marking the rollback successful'
)

typeset -ga _LUMEN_HELM_TEMPLATE_FLAGS=(
  $'-f\t<file>\tSet values from a YAML file'
  $'--values\t<file>\tSet values from a YAML file'
  $'--set\t<key=value>\tSet a value on the command line'
)

typeset -ga _LUMEN_GH_PR_SUBCMDS=(
  $'create\t\tCreate a pull request'
  $'list\t\tList pull requests'
  $'view\t[number]\tView a pull request'
  $'checkout\t<number>\tCheck out a pull request locally'
  $'merge\t[number]\tMerge a pull request'
  $'diff\t[number]\tView a pull request diff'
  $'review\t[number]\tReview a pull request'
  $'close\t[number]\tClose a pull request'
  $'status\t\tShow status of relevant pull requests'
)

typeset -ga _LUMEN_GH_PR_CREATE_FLAGS=(
  $'--title\t<text>\tTitle for the pull request'
  $'--body\t<text>\tBody text for the pull request'
  $'--draft\t\tCreate the pull request as a draft'
  $'--base\t<branch>\tBranch to merge into'
)

typeset -ga _LUMEN_GH_PR_MERGE_FLAGS=(
  $'--squash\t\tSquash all commits into one before merging'
  $'--rebase\t\tRebase commits onto the base branch before merging'
  $'--merge\t\tCreate a merge commit'
  $'--delete-branch\t\tDelete the local and remote branch after merging'
)

typeset -ga _LUMEN_GH_ISSUE_SUBCMDS=(
  $'create\t\tCreate an issue'
  $'list\t\tList issues'
  $'view\t<number>\tView an issue'
  $'close\t<number>\tClose an issue'
  $'reopen\t<number>\tReopen an issue'
  $'comment\t<number>\tAdd a comment to an issue'
)

typeset -ga _LUMEN_GH_ISSUE_CREATE_FLAGS=(
  $'--title\t<text>\tTitle for the issue'
  $'--body\t<text>\tBody text for the issue'
)

typeset -ga _LUMEN_GH_REPO_SUBCMDS=(
  $'clone\t<repo>\tClone a repository'
  $'create\t[name]\tCreate a new repository'
  $'view\t[repo]\tView a repository'
  $'fork\t[repo]\tFork a repository'
  $'list\t[owner]\tList repositories'
)

typeset -ga _LUMEN_GH_RUN_SUBCMDS=(
  $'list\t\tList recent workflow runs'
  $'view\t[run-id]\tView a workflow run'
  $'watch\t[run-id]\tWatch a run until it completes'
  $'rerun\t<run-id>\tRerun a workflow run'
  $'cancel\t<run-id>\tCancel a workflow run'
)

typeset -ga _LUMEN_GH_RELEASE_SUBCMDS=(
  $'create\t<tag>\tCreate a release'
  $'list\t\tList releases'
  $'view\t<tag>\tView a release'
  $'delete\t<tag>\tDelete a release\t1'
  $'upload\t<tag> <files>\tUpload assets to a release'
  $'download\t[tag]\tDownload assets from a release'
  $'edit\t<tag>\tEdit a release'
)

typeset -ga _LUMEN_GH_RELEASE_CREATE_FLAGS=(
  $'-t\t<text>\tTitle for the release'
  $'--title\t<text>\tTitle for the release'
  $'-n\t<text>\tRelease notes text'
  $'--notes\t<text>\tRelease notes text'
  $'-d\t\tSave the release as a draft'
  $'--draft\t\tSave the release as a draft'
  $'-p\t\tMark the release as a prerelease'
  $'--prerelease\t\tMark the release as a prerelease'
  $'--generate-notes\t\tAuto-generate release notes from merged PRs'
  $'--target\t<branch|commit>\tBranch or commit to tag from (defaults to the default branch)'
)

typeset -ga _LUMEN_GH_WORKFLOW_SUBCMDS=(
  $'list\t\tList workflows'
  $'run\t<workflow>\tRun a workflow'
  $'view\t<workflow>\tView a workflow'
  $'enable\t<workflow>\tEnable a workflow'
  $'disable\t<workflow>\tDisable a workflow'
)

typeset -ga _LUMEN_GH_WORKFLOW_RUN_FLAGS=(
  $'-f\t<key=value>\tSet a string input field for the workflow'
  $'--raw-field\t<key=value>\tSet a string input field for the workflow'
  $'-F\t<key=value>\tSet a typed input field (JSON-inferred type)'
  $'--field\t<key=value>\tSet a typed input field (JSON-inferred type)'
  $'-r\t<branch>\tBranch or tag to run the workflow on'
  $'--ref\t<branch>\tBranch or tag to run the workflow on'
)

typeset -ga _LUMEN_GLAB_MR_SUBCMDS=(
  $'create\t\tCreate a merge request'
  $'list\t\tList merge requests'
  $'view\t[id]\tView a merge request'
  $'checkout\t<id>\tCheck out a merge request locally'
  $'merge\t[id]\tMerge a merge request'
  $'diff\t[id]\tView a merge request diff'
  $'approve\t[id]\tApprove a merge request'
  $'close\t[id]\tClose a merge request'
  $'update\t[id]\tUpdate a merge request'
)

typeset -ga _LUMEN_GLAB_MR_CREATE_FLAGS=(
  $'-t\t<text>\tTitle for the merge request'
  $'--title\t<text>\tTitle for the merge request'
  $'-d\t<text>\tDescription for the merge request'
  $'--description\t<text>\tDescription for the merge request'
  $'--draft\t\tCreate as a draft merge request'
  $'-b\t<branch>\tTarget branch to merge into'
  $'--target-branch\t<branch>\tTarget branch to merge into'
  $'-s\t<branch>\tSource branch (defaults to the current branch)'
  $'--source-branch\t<branch>\tSource branch (defaults to the current branch)'
  $'-y\t\tSkip the submission confirmation prompt'
  $'--yes\t\tSkip the submission confirmation prompt'
  $'-l\t<label>\tAdd label(s) to the merge request'
  $'--label\t<label>\tAdd label(s) to the merge request'
)

typeset -ga _LUMEN_GLAB_CI_SUBCMDS=(
  $'status\t\tShow CI/CD pipeline status for the current branch'
  $'view\t[id]\tView a pipeline'
  $'trace\t[job-id]\tTrace/follow a CI/CD job log'
  $'retry\t[job-id]\tRetry a CI/CD job'
  $'run\t\tCreate/run a new pipeline'
)

typeset -ga _LUMEN_GLAB_CI_STATUS_FLAGS=(
  $'-b\t<branch>\tCheck pipeline status for a specific branch'
  $'--branch\t<branch>\tCheck pipeline status for a specific branch'
  $'-l\t\tShow status in real time until the pipeline ends'
  $'--live\t\tShow status in real time until the pipeline ends'
  $'-c\t\tShow status in compact format'
  $'--compact\t\tShow status in compact format'
)

typeset -ga _LUMEN_GLAB_CI_TRACE_FLAGS=(
  $'-b\t<branch>\tBranch to search for the job'
  $'--branch\t<branch>\tBranch to search for the job'
  $'-p\t<pipeline-id>\tPipeline ID to search for the job'
  $'--pipeline-id\t<pipeline-id>\tPipeline ID to search for the job'
)

typeset -ga _LUMEN_GCLOUD_COMPUTE_SUBCMDS=(
  $'instances\t[list|create|delete|describe]\tManage VM instances'
  $'ssh\t<instance>\tSSH into a VM instance'
  $'scp\t<src> <dst>\tCopy files to/from a VM instance'
  $'networks\t[list|create|delete]\tManage VPC networks'
  $'firewall-rules\t[list|create|delete]\tManage firewall rules'
  $'disks\t[list|create|delete]\tManage persistent disks'
)

typeset -ga _LUMEN_GCLOUD_CONTAINER_SUBCMDS=(
  $'clusters\t[list|create|delete|get-credentials]\tManage GKE clusters'
  $'images\t[list|delete]\tManage container images'
  $'node-pools\t[list|create|delete]\tManage GKE node pools'
)

typeset -ga _LUMEN_GCLOUD_COMPUTE_INSTANCES_SUBCMDS=(
  $'create\t\tCreate a VM instance'
  $'list\t\tList instances'
  $'delete\t\tDelete one or more instances'
  $'describe\t\tShow details of an instance'
  $'start\t\tStart a stopped instance'
  $'stop\t\tStop a running instance'
  $'restart\t\tRestart an instance'
  $'ssh\t\tSSH into an instance'
)

typeset -ga _LUMEN_GCLOUD_COMPUTE_INSTANCES_CREATE_FLAGS=(
  $'--zone\t<zone>\tZone to create the instance in'
  $'--machine-type\t<type>\tMachine type, e.g. e2-medium'
  $'--image\t<image>\tSpecific OS image to use'
  $'--image-family\t<family>\tLatest image from this family, e.g. debian-12'
  $'--image-project\t<project>\tProject that owns --image/--image-family'
  $'--network\t<network>\tVPC network to attach to'
  $'--subnet\t<subnet>\tSubnet to attach to'
)

typeset -ga _LUMEN_GCLOUD_COMPUTE_INSTANCES_LIST_FLAGS=(
  $'--zones\t<zone,...>\tOnly list instances in these zones'
  $'--filter\t<expr>\tFilter results by a resource-key expression'
)

typeset -ga _LUMEN_GCLOUD_COMPUTE_INSTANCES_DELETE_FLAGS=(
  $'--zone\t<zone>\tZone the instance is in'
  $'--quiet\t\tSkip the confirmation prompt\t1'
)

typeset -ga _LUMEN_GCLOUD_CONTAINER_CLUSTERS_SUBCMDS=(
  $'create\t\tCreate a GKE cluster'
  $'list\t\tList clusters'
  $'delete\t\tDelete a cluster'
  $'describe\t\tShow details of a cluster'
  $'get-credentials\t\tFetch cluster credentials for kubectl'
  $'resize\t\tResize a cluster'"'"'s node pool'
)

typeset -ga _LUMEN_GCLOUD_CONTAINER_CLUSTERS_CREATE_FLAGS=(
  $'--zone\t<zone>\tZone for a zonal cluster'
  $'--region\t<region>\tRegion for a regional cluster'
  $'--num-nodes\t<n>\tNodes per zone (default: 3)'
  $'--machine-type\t<type>\tMachine type for the nodes'
  $'--cluster-version\t<ver>\tKubernetes version to install'
)

typeset -ga _LUMEN_GCLOUD_CONTAINER_CLUSTERS_GET_CREDENTIALS_FLAGS=(
  $'--location\t<loc>\tZone or region of the cluster (preferred over --zone/--region)'
  $'--zone\t<zone>\tZone, for a zonal cluster'
  $'--region\t<region>\tRegion, for a regional cluster'
)

typeset -ga _LUMEN_GCLOUD_RUN_SUBCMDS=(
  $'deploy\t\tDeploy a container image to Cloud Run'
  $'services\t\tManage Cloud Run services'
  $'revisions\t\tManage Cloud Run revisions'
  $'jobs\t\tManage Cloud Run jobs'
)

typeset -ga _LUMEN_GCLOUD_RUN_DEPLOY_FLAGS=(
  $'--image\t<image>\tContainer image to deploy'
  $'--region\t<region>\tRegion to deploy into'
  $'--allow-unauthenticated\t\tAllow public, unauthenticated access'
  $'--no-allow-unauthenticated\t\tRequire authentication for all requests'
  $'--memory\t<amount>\tMemory per instance, e.g. 512Mi, 4Gi'
  $'--cpu\t<n>\tCPU per instance: fractional, 1, 2, 4, or 8'
  $'--port\t<port>\tContainer port to receive requests on'
  $'--min-instances\t<n>\tMinimum instances kept warm'
  $'--max-instances\t<n>\tMaximum concurrent instances'
)

# On-screen row/column the cursor is at, so the box lines up under wherever
# you're actually typing instead of always sitting at the terminal's left
# margin (col), and so the native overlay (see _lumen_overlay_show) can
# be positioned against the real cursor (row). Refreshed once per new prompt
# (see _lumen_line_init) rather than every keystroke: the prompt's
# start position doesn't change while editing a single line, only when a
# new one is drawn, so re-querying per-keystroke would just be repeated
# syscall overhead for the same answer.
typeset -gi _LUMEN_PROMPT_ROW=1
typeset -gi _LUMEN_PROMPT_COL=1

# Asks the terminal where the cursor currently is via a DSR (Device Status
# Report) query (\e[6n) and reads back its \e[<row>;<col>R reply on the same
# stream zle reads keystrokes from. Safe to do a blocking read here: zsh's
# event loop is single-threaded/cooperative, so zle's own read loop is not
# concurrently competing for input while this widget function is running —
# there's no race to lose. Leaves _LUMEN_PROMPT_ROW/COL at 1 (today's
# top-left-margin behavior) if anything goes wrong: terminal doesn't support
# DSR, output is piped/captured, or the reply doesn't arrive within the
# timeout — this is a cosmetic nicety for the ANSI box and a required input
# for the native overlay, but never something worth blocking or erroring
# over either way.
_lumen_query_cursor_pos() {
  _LUMEN_PROMPT_ROW=1
  _LUMEN_PROMPT_COL=1
  [[ -t 1 ]] || return
  local reply char
  print -n $'\e[6n' > /dev/tty 2>/dev/null || return
  local -i n=0
  while (( n < 32 )); do
    read -t 0.2 -k 1 char < /dev/tty 2>/dev/null || return
    reply+=$char
    (( n++ ))
    [[ $char == R ]] && break
  done
  [[ $reply == $'\e['*R ]] || return
  reply=${reply#$'\e['}
  reply=${reply%R}
  local row=${reply%%;*}
  local col=${reply#*;}
  [[ $row == <-> ]] || return
  [[ $col == <-> ]] || return
  (( row >= 1 )) && _LUMEN_PROMPT_ROW=$row
  (( col >= 1 )) && _LUMEN_PROMPT_COL=$col
}

# --- native overlay (Kiro CLI/Fig-style floating panel) ---------------------
#
# The overlay is a real NSPanel owned by the Lumen companion
# app, positioned against the terminal's actual on-screen pixel location
# via its own Accessibility-API lookup — drawn entirely outside the
# terminal's character grid, so it can do real rounded corners and shadows
# instead of ╭╮╰╯ box-drawing characters. This shell side only ever sends
# "here's what to show and where the cursor is" over a Unix socket — it has
# no idea whether the companion app successfully manages to position
# anything, by design (a synchronous round-trip here would reintroduce
# exactly the kind of blocking call this plugin has spent a lot of effort
# avoiding elsewhere). There is no other rendering path: if the companion
# app isn't running, Accessibility permission hasn't been granted, or the
# frontmost terminal can't be positioned against (see
# Lumen/Sources/Lumen/TerminalPositioner.swift),
# nothing shows for that keystroke — never an error, never a block.
_lumen_overlay_supported() {
  (( LUMEN_OVERLAY ))
}

# JSON string escaping for a candidate/description/hint. Static-table
# entries and branch names are ASCII in practice, but cp/mv/ln/rm and
# git-add candidates are real filenames and can contain any byte except
# NUL — a lone backslash, an embedded newline, or a raw control char. Any
# unescaped U+0000–U+001F makes the whole payload invalid JSON, which the
# app then silently drops, so every control char has to go.
_lumen_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  # Escape any remaining C0 control char as \u00XX. Guarded so the common
  # control-free case stays a single pattern test rather than 29 scans.
  if [[ $s == *[[:cntrl:]]* ]]; then
    local -a _hex=(0 1 2 3 4 5 6 7 8 9 a b c d e f)
    local i
    for i in {1..31}; do
      (( i == 9 || i == 10 || i == 13 )) && continue  # \t \n \r done above
      s=${s//${(#)i}/\\u00${_hex[(i>>4)+1]}${_hex[(i&15)+1]}}
    done
  fi
  print -rn -- "$s"
}

# Builds a JSON array literal from "$@", each element escaped and quoted.
_lumen_json_str_array() {
  local -a parts
  local item
  for item in "$@"; do
    parts+=("\"$(_lumen_json_escape "$item")\"")
  done
  print -rn -- "[${(j:,:)parts}]"
}

# Throttles overlay-socket sends to at most one per
# _LUMEN_OVERLAY_MIN_INTERVAL — NOT a performance tweak. Root-caused
# 2026-08-01: connecting+closing this Unix socket on every single keystroke
# (a fast typing burst easily fires 15-20 sends within a few hundred ms)
# corrupts the shell's own terminal I/O state badly enough that the NEXT
# foreground command's real stdout/stderr never reaches the terminal at
# all — reproduced down to a bare zsocket-connect-close loop with no AI/git
# involved, so it's a genuine zsh/pty interaction bug triggered by send
# *frequency*, not anything about this plugin's payload. The throttle only
# lowers how *often* this fires, though, and a single typed command (e.g.
# typing "git push" itself, each character matching the static table and
# triggering a send) is still enough to trip it and corrupt the interactive
# shell before that very command is even submitted — reproduced 2026-08-02:
# `git push` on a branch with no upstream printed nothing (not even the
# `128 err` status segment's `fatal:` line), consistent with `_lumen_
# overlay_send`'s own zsocket call (not the command that ran after it)
# having wedged the shell's tty state first. `_lumen_overlay_send`
# below now runs the whole zsocket lifecycle in a forked, disowned subshell
# (`&!`) instead of the interactive shell's own process — `fork()` gives
# the child its own copy of the fd table, so whatever zsocket does to it
# stays confined to that throwaway child instead of the shell every
# subsequent command actually runs in. Every real send still fires well
# within what a human can perceive while typing (>=80ms
# apart is faster than typical keystroke spacing), so this is invisible in
# normal use — a send that lands inside the window is never just dropped,
# though: see _lumen_overlay_schedule_flush below for what happens to
# it instead.
zmodload zsh/datetime 2>/dev/null
typeset -gF _LUMEN_LAST_OVERLAY_SEND=0
typeset -gF _LUMEN_OVERLAY_MIN_INTERVAL=0.08
# Holds the most recent payload a throttled call couldn't send yet, and the
# fd of the in-flight timer counting down to when it can. Together these
# turn the throttle above into a trailing-flush debounce instead of a hard
# drop: a burst of keystrokes inside one window (fast typing, held
# Backspace) still ends with the panel showing its correct, final state,
# not frozen on whichever mid-burst prefix happened to win the throttle.
typeset -g _LUMEN_OVERLAY_PENDING_PAYLOAD=""
typeset -gi _LUMEN_OVERLAY_FLUSH_FD=-1

# Fire-and-forget send of a JSON payload to the overlay companion app.
# zsocket (zsh/net/socket) connecting to a path with nothing listening —
# socket missing entirely, stale file, or refused connection — fails
# immediately (verified: sub-10ms, no retry/hang), so this is safe to call
# unconditionally from a hot path with no timeout wrapper needed. Errors are
# swallowed on purpose: the companion app not running is an expected,
# common state (e.g. user hasn't launched it), not a failure worth surfacing
# in the middle of typing.
_lumen_overlay_send() {
  local payload=$1
  # force=1 bypasses the throttle below — for a discrete, one-shot action
  # (Escape/Ctrl-G dismiss, accepting a candidate, Ctrl-Space trigger, shell
  # exit) rather than the rapid-fire-keystrokes case the throttle exists
  # for (see the big comment above _LUMEN_OVERLAY_MIN_INTERVAL). Without
  # this, a hide sent within 80ms of the show that preceded it — e.g.
  # pressing Escape right after typing, the common case — would go through
  # the same debounce path as a throttled show, leaving the panel visibly
  # stuck open until the scheduled flush (or a later keystroke) catches up.
  local -i force=${2:-0}
  if (( ! force )) && (( EPOCHREALTIME - _LUMEN_LAST_OVERLAY_SEND < _LUMEN_OVERLAY_MIN_INTERVAL )); then
    # Trailing-flush debounce, not a hard drop: remember this payload —
    # overwriting whatever an earlier keystroke in the same burst queued,
    # since only the newest state matters — and make sure a flush is
    # scheduled for the moment the throttle window clears. That's what
    # keeps a burst that ends mid-window (fast typing, held Backspace) from
    # leaving the panel frozen on a stale, in-between suggestion.
    _LUMEN_OVERLAY_PENDING_PAYLOAD=$payload
    _lumen_overlay_schedule_flush
    return
  fi
  _lumen_overlay_send_now "$payload"
}

# Does the actual zsocket send, bypassing the throttle entirely — called
# either directly (send allowed right now) or later, from the flush
# handler below (send was queued and the window has since cleared).
_lumen_overlay_send_now() {
  local payload=$1
  _LUMEN_LAST_OVERLAY_SEND=$EPOCHREALTIME
  # This send supersedes anything still queued from an earlier, throttled
  # call (including the case where this very call *is* that queued
  # payload) — clear it so a stale flush can't re-fire after a force=1
  # send (e.g. Escape) has already put the panel in its final state.
  _LUMEN_OVERLAY_PENDING_PAYLOAD=""
  # Forked off (`&!`: background + disown, no job-control notification) so
  # zsocket's connect/write/close cycle runs against a *copy* of the fd
  # table made by fork(), not the interactive shell's own — see this
  # function's section doc comment above for why that isolation matters.
  (
    zmodload zsh/net/socket 2>/dev/null || exit
    zsocket $LUMEN_OVERLAY_SOCK 2>/dev/null || exit
    print -u $REPLY -r -- "$payload" 2>/dev/null
    exec {REPLY}>&- 2>/dev/null
  ) &!
}

# Arranges for _LUMEN_OVERLAY_PENDING_PAYLOAD to actually get sent once
# the current throttle window ends, instead of sitting there unsent until
# some later keystroke happens to call _lumen_overlay_send again (which
# may never come — the user may just pause to read what's on screen). Uses
# `zle -F`, the same mechanism async-completion plugins use, to register a
# handler that zle's own idle loop invokes once a backgrounded timer fd
# becomes readable — this wakes the panel up while the shell is sitting at
# the prompt waiting for the next key, without blocking that wait itself.
# A no-op if a flush is already scheduled: _LUMEN_OVERLAY_PENDING_PAYLOAD
# is updated in place by the caller, so the one flush already in flight
# picks up whatever's newest when it fires — at most one extra background
# process per throttle window, not one per dropped keystroke.
_lumen_overlay_schedule_flush() {
  (( _LUMEN_OVERLAY_FLUSH_FD >= 0 )) && return
  local -F remaining=$(( _LUMEN_OVERLAY_MIN_INTERVAL - (EPOCHREALTIME - _LUMEN_LAST_OVERLAY_SEND) ))
  local -i centis
  # zselect's timeout is in centiseconds; round up by 1 so the flush never
  # fires a hair before the throttle window it's waiting out actually ends.
  (( centis = remaining > 0 ? remaining * 100 + 1 : 1 ))
  exec {_LUMEN_OVERLAY_FLUSH_FD}< <(
    # zselect (zsh/zselect) is a builtin sub-second sleep — no watched fds,
    # just the timeout — so this doesn't need to fork/exec an external
    # `sleep` binary on top of the subshell fork already happening here. If
    # the module can't load, the `print` below still runs immediately, so
    # this degrades to "flush right away" rather than "never flush".
    zmodload zsh/zselect 2>/dev/null
    zselect -t $centis 2>/dev/null
    print -n x
  )
  zle -F $_LUMEN_OVERLAY_FLUSH_FD _lumen_overlay_flush_handler
}

# zle -F callback for _lumen_overlay_schedule_flush: the throttle
# window has cleared, so send whatever's currently pending — the newest
# state at the time this fires, not necessarily the payload that triggered
# the scheduling — and deregister.
_lumen_overlay_flush_handler() {
  local -i fd=$1
  zle -F $fd
  exec {fd}<&-
  _LUMEN_OVERLAY_FLUSH_FD=-1
  (( ${#_LUMEN_OVERLAY_PENDING_PAYLOAD} )) && _lumen_overlay_send_now "$_LUMEN_OVERLAY_PENDING_PAYLOAD"
}

# Sends the current _LUMEN_CANDIDATES/etc + cursor position so the
# companion app can render (or reposition) the floating panel.
_lumen_overlay_show() {
  local -a label_parts
  local i lbl hint_text
  for (( i = 1; i <= ${#_LUMEN_CANDIDATES}; i++ )); do
    lbl=${_LUMEN_LABELS[$i]:-${_LUMEN_CANDIDATES[$i]%% }}
    hint_text=${_LUMEN_HINTS[$i]:-}
    [[ -n $hint_text ]] && lbl="${lbl% }${lbl:+ }${hint_text}"
    label_parts+=("$lbl")
  done

  # _LUMEN_PROMPT_ROW/COL are only refreshed once per new prompt (a
  # real DSR query, see _lumen_query_cursor_pos) — re-querying the
  # terminal on every keystroke would mean a round-trip escape-sequence
  # read in the hot path, exactly the kind of latency risk this plugin
  # otherwise avoids. Instead, the LIVE column is derived locally: zsh
  # already knows $CURSOR (position within BUFFER) for free, so the
  # on-screen column is just the prompt's start column plus how far into
  # the buffer the cursor is — pure arithmetic, no extra terminal query —
  # wrapped across rows if the buffer is long enough to overflow the
  # terminal width. This is what makes the panel track the cursor
  # horizontally as you type, matching Kiro CLI, instead of staying
  # anchored where the prompt started.
  local -i cols=${COLUMNS:-80}
  local -i offset=$(( _LUMEN_PROMPT_COL - 1 + CURSOR ))
  local -i live_row=$(( _LUMEN_PROMPT_ROW + offset / cols ))
  local -i live_col=$(( offset % cols + 1 ))

  local payload="{"
  payload+="\"candidates\":$(_lumen_json_str_array "${_LUMEN_CANDIDATES[@]}"),"
  payload+="\"descriptions\":$(_lumen_json_str_array "${_LUMEN_DESCRIPTIONS[@]}"),"
  payload+="\"labels\":$(_lumen_json_str_array "${label_parts[@]}"),"
  payload+="\"icons\":$(_lumen_json_str_array "${_LUMEN_ICONS[@]}"),"
  local -a danger_parts
  for (( i = 1; i <= ${#_LUMEN_CANDIDATES}; i++ )); do
    danger_parts+=("${_LUMEN_DANGER[$i]:-}")
  done
  payload+="\"danger\":$(_lumen_json_str_array "${danger_parts[@]}"),"
  payload+="\"selectedIndex\":$(( _LUMEN_INDEX - 1 )),"
  payload+="\"cursorRow\":$live_row,"
  payload+="\"cursorCol\":$live_col,"
  payload+="\"columns\":${cols},"
  payload+="\"lines\":${LINES:-30}"
  payload+="}"
  _lumen_overlay_send "$payload"
}

_lumen_overlay_hide() {
  local -i force=${1:-0}
  _lumen_overlay_send '{"hide":true}' $force
}

_lumen_present_candidates() {
  _lumen_overlay_supported && _lumen_overlay_show
}

# Resets the candidate arrays WITHOUT telling the overlay to hide — see
# _lumen_clear_display's comment for why the two are kept apart.
_lumen_reset_candidates() {
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  _LUMEN_DANGER=()
  _LUMEN_INDEX=0
}

# Actually tells the overlay to hide (if something was showing) and resets
# local state. Only call this when nothing is going to replace what's
# showing within the same keystroke/action — e.g. Ctrl-G dismiss, a fresh
# prompt line, or "the buffer no longer matches anything." Callers that
# immediately re-suggest afterward (a keystroke, accepting a candidate)
# must NOT go through here first: _lumen_overlay_send throttles sends
# under _LUMEN_OVERLAY_MIN_INTERVAL apart, and a hide here followed
# microseconds later by a show would mean the hide always goes through
# (force=1) but the show *always* hits the throttle — not just
# occasionally, every single time, since the two calls land far closer
# together than any human keystroke ever could. The show is no longer
# lost outright (it gets queued and flushed once the window clears, see
# _lumen_overlay_schedule_flush), but it's still needless churn and a
# real, if brief, moment where the panel visibly disappears mid-typing.
# See _lumen_suggest_now/_lumen_trigger/_lumen_accept,
# which use _lumen_reset_candidates instead and only call
# _lumen_overlay_hide directly, on its own, when they've already
# determined nothing else will be shown this round.
_lumen_clear_display() {
  # force=1: every caller of this function is a discrete, one-shot action
  # (Escape/Ctrl-G dismiss, accept-line, a fresh prompt) — never the
  # rapid-keystrokes case _LUMEN_OVERLAY_MIN_INTERVAL guards against —
  # so the hide must never get silently dropped by that throttle.
  (( ${#_LUMEN_CANDIDATES} > 0 )) && _lumen_overlay_hide 1
  _lumen_reset_candidates
}

# Maps a tool name (as typed, so "k"/"tf" included) to the icon identifier
# the overlay companion app knows how to draw a distinct glyph+color for
# (see CandidateIcon in OverlayPanel.swift) — one entry per tool this
# plugin has a static table for, grouped where several binaries are really
# "the same kind of thing" (kafka's four scripts all get "kafka"; aws/
# gcloud/az all get their own cloud-provider identity rather than sharing
# one generic "cloud" bucket, since which cloud you're in is exactly the
# thing worth telling apart at a glance). Falls back to "cmd" — the
# original plain "$" badge — for any tool without a specific glyph, so
# adding a new *_SUBCMDS table later doesn't require touching this list to
# stay visually correct, just look a little more generic until it's added.
_lumen_tool_icon_kind() {
  case "$1" in
    git) print -n git ;;
    docker) print -n docker ;;
    kubectl|k) print -n kubectl ;;
    npm) print -n npm ;;
    yarn) print -n yarn ;;
    pnpm) print -n pnpm ;;
    aws) print -n aws ;;
    gcloud) print -n gcloud ;;
    az) print -n az ;;
    terraform|tf) print -n terraform ;;
    helm) print -n helm ;;
    gh) print -n gh ;;
    glab) print -n glab ;;
    kafka-topics|kafka-topics.sh|kafka-console-producer|kafka-console-producer.sh|kafka-console-consumer|kafka-console-consumer.sh|kafka-consumer-groups|kafka-consumer-groups.sh)
      print -n kafka ;;
    rabbitmqctl) print -n rabbitmq ;;
    make) print -n make ;;
    just) print -n just ;;
    composer) print -n composer ;;
    deno) print -n deno ;;
    cargo) print -n cargo ;;
    go) print -n go ;;
    pip|pip3) print -n pip ;;
    poetry) print -n poetry ;;
    mvn) print -n maven ;;
    gradle) print -n gradle ;;
    dotnet) print -n dotnet ;;
    bundle) print -n bundler ;;
    gem) print -n rubygems ;;
    brew) print -n homebrew ;;
    docker-compose) print -n docker ;;
    vagrant) print -n vagrant ;;
    pulumi) print -n pulumi ;;
    heroku) print -n heroku ;;
    vercel) print -n vercel ;;
    netlify) print -n netlify ;;
    firebase) print -n firebase ;;
    flyctl|fly) print -n flyctl ;;
    doctl) print -n digitalocean ;;
    turbo) print -n turborepo ;;
    nx) print -n nx ;;
    tmux) print -n tmux ;;
    systemctl) print -n systemd ;;
    nvm) print -n nodejs ;;
    pyenv) print -n python ;;
    rbenv) print -n ruby ;;
    npx) print -n npm ;;
    minikube) print -n kubectl ;;
    *) print -n cmd ;;
  esac
}

# Matches $BUFFER against a known "<tool> <partial-subcommand>" shape and,
# if it's a tool we have a static table for (see _LUMEN_GIT_SUBCMDS),
# populates the candidate/description/hint arrays directly from it. Only
# fires while still typing the subcommand itself (no space after it yet);
# once a subcommand is chosen, its own arguments are free-form and this
# table has nothing useful to say about them (git's checkout/switch/merge/
# rebase/branch are the exception — see _lumen_git_branch_match, which
# picks up exactly where this backs off).
_lumen_static_match() {
  local tool="${BUFFER%% *}"
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1

  local -a table
  case "$tool" in
    git) table=("${_LUMEN_GIT_SUBCMDS[@]}") ;;
    kubectl|k) table=("${_LUMEN_KUBECTL_SUBCMDS[@]}") ;;
    npm) table=("${_LUMEN_NPM_SUBCMDS[@]}") ;;
    docker) table=("${_LUMEN_DOCKER_SUBCMDS[@]}") ;;
    aws) table=("${_LUMEN_AWS_SUBCMDS[@]}") ;;
    terraform|tf) table=("${_LUMEN_TERRAFORM_SUBCMDS[@]}") ;;
    helm) table=("${_LUMEN_HELM_SUBCMDS[@]}") ;;
    gh) table=("${_LUMEN_GH_SUBCMDS[@]}") ;;
    glab) table=("${_LUMEN_GLAB_SUBCMDS[@]}") ;;
    yarn) table=("${_LUMEN_YARN_SUBCMDS[@]}") ;;
    pnpm) table=("${_LUMEN_PNPM_SUBCMDS[@]}") ;;
    gcloud) table=("${_LUMEN_GCLOUD_SUBCMDS[@]}") ;;
    az) table=("${_LUMEN_AZ_SUBCMDS[@]}") ;;
    kafka-topics.sh|kafka-topics) table=("${_LUMEN_KAFKA_TOPICS_SUBCMDS[@]}") ;;
    kafka-console-producer.sh|kafka-console-producer) table=("${_LUMEN_KAFKA_CONSOLE_PRODUCER_SUBCMDS[@]}") ;;
    kafka-console-consumer.sh|kafka-console-consumer) table=("${_LUMEN_KAFKA_CONSOLE_CONSUMER_SUBCMDS[@]}") ;;
    kafka-consumer-groups.sh|kafka-consumer-groups) table=("${_LUMEN_KAFKA_CONSUMER_GROUPS_SUBCMDS[@]}") ;;
    rabbitmqctl) table=("${_LUMEN_RABBITMQCTL_SUBCMDS[@]}") ;;
    cargo) table=("${_LUMEN_CARGO_SUBCMDS[@]}") ;;
    go) table=("${_LUMEN_GO_SUBCMDS[@]}") ;;
    pip|pip3) table=("${_LUMEN_PIP_SUBCMDS[@]}") ;;
    poetry) table=("${_LUMEN_POETRY_SUBCMDS[@]}") ;;
    mvn) table=("${_LUMEN_MVN_SUBCMDS[@]}") ;;
    gradle) table=("${_LUMEN_GRADLE_SUBCMDS[@]}") ;;
    dotnet) table=("${_LUMEN_DOTNET_SUBCMDS[@]}") ;;
    bundle) table=("${_LUMEN_BUNDLE_SUBCMDS[@]}") ;;
    gem) table=("${_LUMEN_GEM_SUBCMDS[@]}") ;;
    brew) table=("${_LUMEN_BREW_SUBCMDS[@]}") ;;
    docker-compose) table=("${_LUMEN_DOCKER_COMPOSE_SUBCMDS[@]}") ;;
    vagrant) table=("${_LUMEN_VAGRANT_SUBCMDS[@]}") ;;
    pulumi) table=("${_LUMEN_PULUMI_SUBCMDS[@]}") ;;
    heroku) table=("${_LUMEN_HEROKU_SUBCMDS[@]}") ;;
    vercel) table=("${_LUMEN_VERCEL_SUBCMDS[@]}") ;;
    netlify) table=("${_LUMEN_NETLIFY_SUBCMDS[@]}") ;;
    firebase) table=("${_LUMEN_FIREBASE_SUBCMDS[@]}") ;;
    flyctl|fly) table=("${_LUMEN_FLYCTL_SUBCMDS[@]}") ;;
    doctl) table=("${_LUMEN_DOCTL_SUBCMDS[@]}") ;;
    turbo) table=("${_LUMEN_TURBO_SUBCMDS[@]}") ;;
    nx) table=("${_LUMEN_NX_SUBCMDS[@]}") ;;
    tmux) table=("${_LUMEN_TMUX_SUBCMDS[@]}") ;;
    systemctl) table=("${_LUMEN_SYSTEMCTL_SUBCMDS[@]}") ;;
    nvm) table=("${_LUMEN_NVM_SUBCMDS[@]}") ;;
    pyenv) table=("${_LUMEN_PYENV_SUBCMDS[@]}") ;;
    rbenv) table=("${_LUMEN_RBENV_SUBCMDS[@]}") ;;
    npx) table=("${_LUMEN_NPX_SUBCMDS[@]}") ;;
    minikube) table=("${_LUMEN_MINIKUBE_SUBCMDS[@]}") ;;
    *) return 1 ;;
  esac

  local rest="${BUFFER#$tool}"
  rest="${rest## }"
  # Already past the subcommand (it has its own argument being typed) —
  # this table doesn't cover per-subcommand arguments, so back off (see
  # _lumen_git_branch_match for the git-branch-argument case).
  [[ "$rest" == *' '* ]] && return 1

  # Typing "-" before ever picking a subcommand (e.g. "docker -", "git -")
  # — none of these top-level tables' entries are named "-something", so
  # swap in the generic -h/--help/--version-and-friends fallback instead of
  # leaving the subcommand table in place, where it would just filter down
  # to zero matches. Exception: kafka-topics/kafka-console-*/kafka-
  # consumer-groups's own top-level tables ARE already flag-shaped (their
  # first arg is a flag like --list, not a subcommand) — leave those alone
  # so their real, tool-specific entries keep matching instead of being
  # replaced by the generic ones.
  case "$tool" in
    kafka-topics.sh|kafka-topics|kafka-console-producer.sh|kafka-console-producer| \
    kafka-console-consumer.sh|kafka-console-consumer|kafka-consumer-groups.sh|kafka-consumer-groups)
      ;;
    *)
      [[ "$rest" == -* ]] && table=("${_LUMEN_GENERIC_FLAGS[@]}")
      ;;
  esac

  local entry name hint desc
  local -a parts
  local icon_kind=$(_lumen_tool_icon_kind "$tool")
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  _LUMEN_DANGER=()
  for entry in "${table[@]}"; do
    parts=("${(@ps:\t:)entry}")
    name=$parts[1]
    [[ "$name" == "$rest"* ]] || continue
    _LUMEN_CANDIDATES+=("$tool $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("${parts[2]:-}")
    _LUMEN_DESCRIPTIONS+=("${parts[3]:-}")
    _LUMEN_ICONS+=("$icon_kind")
    _LUMEN_DANGER+=("${parts[4]:-}")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests directories under whatever path is being typed after `cd`, e.g.
# "cd Doc" -> "cd Documents/". Uses zsh's own glob qualifiers instead of
# `ls`/`find`: the (/N) qualifier restricts matches to directories and makes
# a no-match produce an empty list (N = NULL_GLOB) rather than a "no matches
# found" error. No trailing space on the candidate (unlike the tool tables
# below) — a path is one argument being built up incrementally, so accepting
# "Documents/" should leave the cursor ready to keep typing the next segment
# (or press Tab again to drill further), not start a new word.
_lumen_cd_match() {
  local tool="${BUFFER%% *}"
  [[ "$tool" == "cd" ]] || return 1
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1

  local rest="${BUFFER#$tool}"
  rest="${rest## }"
  [[ "$rest" == *' '* ]] && return 1

  local -a matches
  # (#i) makes the glob case-insensitive for the rest of the pattern (every
  # path segment, not just the first) — without it, plain-glob matching is
  # case-sensitive, so typing "cd p" would only ever find lowercase-p
  # directories like "projects" and silently skip "Pictures"/"Personal".
  # local_options confines EXTENDED_GLOB to this function call instead of
  # leaking the option into the interactive shell that's about to run
  # whatever's on BUFFER.
  setopt local_options extended_glob
  matches=( (#i)${rest}*(/N) )
  (( ${#matches} == 0 )) && return 1

  local dir label
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for dir in "${matches[@]}"; do
    label="${dir%/}/"
    _LUMEN_CANDIDATES+=("$tool ${dir%/}/")
    _LUMEN_LABELS+=("$label")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Change directory")
    _LUMEN_ICONS+=("dir")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests local branch names once a git subcommand that takes one has been
# typed (checkout/switch/merge/rebase/branch) — the counterpart to
# _LUMEN_GIT_SUBCMDS for the *next* word instead of the subcommand
# itself. Runs `git for-each-ref` fresh on every call rather than caching:
# it's a local-refs-only read (no network), cheap enough per keystroke, and
# means a branch created a second ago still shows up.
_lumen_git_branch_match() {
  [[ "$BUFFER" == git\ * ]] || return 1
  local rest="${BUFFER#git }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    checkout|switch|merge|rebase|branch) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  # A flag (checkout -b, branch -d, ...), not the start of a branch name —
  # back off rather than offering nonsense completions for it.
  [[ "$partial" == -* ]] && return 1

  # Cheap, no-network check that also keeps `git for-each-ref` from being
  # run (and erroring) in a directory that isn't a git work tree at all.
  git rev-parse --is-inside-work-tree &>/dev/null || return 1

  local -a branches
  branches=(${(f)"$(command git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"})
  (( ${#branches} == 0 )) && return 1

  local br
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for br in "${branches[@]}"; do
    [[ "$br" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("git $subcmd $br ")
    _LUMEN_LABELS+=("$br")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Local branch")
    _LUMEN_ICONS+=("branch")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real remote names once "git remote <subcmd>" needs one
# (remove/rename/set-url/show/prune) — replaces the static "<name>"
# placeholder from _LUMEN_GIT_REMOTE_SUBCMDS. "add" is deliberately excluded
# since its argument is a name the user is choosing, not an existing one.
# `git remote` (no args) is itself the local, no-network listing — it does
# not contact the remote host, just reads .git/config.
_lumen_git_remote_match() {
  [[ "$BUFFER" == git\ remote\ * ]] || return 1
  local rest="${BUFFER#git remote }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    remove|rename|set-url|show|prune) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  git rev-parse --is-inside-work-tree &>/dev/null || return 1

  local -a remotes
  remotes=(${(f)"$(command git remote 2>/dev/null)"})
  (( ${#remotes} == 0 )) && return 1

  local r
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for r in "${remotes[@]}"; do
    [[ "$r" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("git remote $subcmd $r ")
    _LUMEN_LABELS+=("$r")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Remote")
    _LUMEN_ICONS+=("git")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real stash refs (stash@{0}, stash@{1}, ...) once "git stash
# <subcmd>" needs one (apply/show/drop) — replaces the static "[stash]"
# placeholder from _LUMEN_GIT_STASH_SUBCMDS. "pop" isn't included since that
# table gives it no placeholder to begin with (defaults to the latest
# stash). The "{"/"}" in a ref like "stash@{0}" are safe here — accepting a
# candidate is a plain string assignment to BUFFER (see _lumen_accept), not
# something the shell re-parses for globbing.
_lumen_git_stash_match() {
  [[ "$BUFFER" == git\ stash\ * ]] || return 1
  local rest="${BUFFER#git stash }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    apply|show|drop) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  git rev-parse --is-inside-work-tree &>/dev/null || return 1

  local -a stashes
  stashes=(${(f)"$(command git stash list --format='%gd' 2>/dev/null)"})
  (( ${#stashes} == 0 )) && return 1

  local s
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for s in "${stashes[@]}"; do
    [[ "$s" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("git stash $subcmd $s ")
    _LUMEN_LABELS+=("$s")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Stash")
    _LUMEN_ICONS+=("git")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real staged file paths once "git restore --staged" needs one,
# replacing the placeholder from _LUMEN_GIT_RESTORE_FLAGS with the actual
# files currently in the index — the "which files did I just add" list, via
# `git diff --cached --name-only` (local, no-network, same as every other
# git plumbing read this file already uses). Only completes a single
# trailing file, same one-arg limitation as the other dynamic matchers
# above (e.g. _lumen_git_branch_match) — a second already-typed filename
# before the partial backs this off, same as everywhere else here.
_lumen_git_restore_staged_match() {
  [[ "$BUFFER" == git\ restore\ --staged\ * ]] || return 1
  local partial="${BUFFER#git restore --staged }"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  git rev-parse --is-inside-work-tree &>/dev/null || return 1

  local -a files
  files=(${(f)"$(command git diff --cached --name-only 2>/dev/null)"})
  (( ${#files} == 0 )) && return 1

  local f
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for f in "${files[@]}"; do
    [[ "$f" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("git restore --staged $f ")
    _LUMEN_LABELS+=("$f")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Staged file")
    _LUMEN_ICONS+=("git")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real container names once a docker subcommand that takes one has
# been typed (exec/logs/stop/start/rm/restart/kill) — the docker
# counterpart to _lumen_git_branch_match, replacing the static "<container>"
# placeholder from _LUMEN_DOCKER_SUBCMDS with actual containers. Lists both
# running and stopped containers (`docker ps -a`) rather than filtering per
# subcommand (e.g. only-running for stop/exec) — same "don't guess state
# semantics, just show what's there" approach as the branch matcher not
# distinguishing current vs. other branches; the status text in the
# description column is enough for the user to judge. Runs fresh on every
# call, no caching, same reasoning as git for-each-ref above.
_lumen_docker_container_match() {
  [[ "$BUFFER" == docker\ * ]] || return 1
  local rest="${BUFFER#docker }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    exec|logs|stop|start|rm|restart|kill) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  command -v docker &>/dev/null || return 1

  local -a lines
  lines=(${(f)"$(command docker ps -a --format '{{.Names}}'$'\t''{{.Status}}' 2>/dev/null)"})
  (( ${#lines} == 0 )) && return 1

  local entry name cstatus
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${lines[@]}"; do
    name="${entry%%$'\t'*}"
    cstatus="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("docker $subcmd $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${cstatus:-Container}")
    _LUMEN_ICONS+=("docker")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real local image names (repository:tag) once a docker subcommand
# that takes one has been typed (run/rmi/tag/push) — the image counterpart
# to _lumen_docker_container_match above, replacing the static "<image>"
# placeholder from _LUMEN_DOCKER_SUBCMDS. Skips dangling "<none>:<none>"
# entries since they aren't addressable by that name (you'd need the image
# ID instead, which this matcher doesn't cover). pull is deliberately left
# to the static "<image>" hint rather than handled here — its argument is
# whatever's in the remote registry, not something enumerable from local
# images. Only completes the first word, same as the container matcher:
# "tag <image> <tag>"'s second, free-form arg is unaffected.
_lumen_docker_image_match() {
  [[ "$BUFFER" == docker\ * ]] || return 1
  local rest="${BUFFER#docker }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    run|rmi|tag|push) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  command -v docker &>/dev/null || return 1

  local -a lines
  lines=(${(f)"$(command docker images --format '{{.Repository}}:{{.Tag}}'$'\t''{{.Size}}' 2>/dev/null)"})
  (( ${#lines} == 0 )) && return 1

  local entry name size
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${lines[@]}"; do
    name="${entry%%$'\t'*}"
    [[ "$name" == '<none>:<none>' ]] && continue
    [[ "$name" == "$partial"* ]] || continue
    size="${entry#*$'\t'}"
    _LUMEN_CANDIDATES+=("docker $subcmd $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${size:-Image}")
    _LUMEN_ICONS+=("docker")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real network names once "docker network <subcmd>" needs one
# (rm/inspect/connect/disconnect) — the network counterpart to
# _lumen_docker_container_match/_lumen_docker_image_match above, replacing
# the static "<network>" placeholder from _LUMEN_DOCKER_NETWORK_SUBCMDS.
# "create" is excluded (its argument is a new name, not an existing one).
# Only completes the first word — "connect <network> <container>" and
# "disconnect <network> <container>"'s second, free-form arg is unaffected.
_lumen_docker_network_match() {
  [[ "$BUFFER" == docker\ network\ * ]] || return 1
  local rest="${BUFFER#docker network }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    rm|inspect|connect|disconnect) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  command -v docker &>/dev/null || return 1

  local -a networks
  networks=(${(f)"$(command docker network ls --format '{{.Name}}' 2>/dev/null)"})
  (( ${#networks} == 0 )) && return 1

  local n
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for n in "${networks[@]}"; do
    [[ "$n" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("docker network $subcmd $n ")
    _LUMEN_LABELS+=("$n")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Network")
    _LUMEN_ICONS+=("docker")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real volume names once "docker volume <subcmd>" needs one
# (rm/inspect) — the volume counterpart to _lumen_docker_network_match
# above, replacing the static "<volume>" placeholder from
# _LUMEN_DOCKER_VOLUME_SUBCMDS. "create" is excluded (its argument is a new
# name, not an existing one).
_lumen_docker_volume_match() {
  [[ "$BUFFER" == docker\ volume\ * ]] || return 1
  local rest="${BUFFER#docker volume }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    rm|inspect) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  command -v docker &>/dev/null || return 1

  local -a volumes
  volumes=(${(f)"$(command docker volume ls --format '{{.Name}}' 2>/dev/null)"})
  (( ${#volumes} == 0 )) && return 1

  local v
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for v in "${volumes[@]}"; do
    [[ "$v" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("docker volume $subcmd $v ")
    _LUMEN_LABELS+=("$v")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Volume")
    _LUMEN_ICONS+=("docker")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Pulls "-n <ns>" / "--namespace <ns>" / "--namespace=<ns>" out of the
# current buffer so a kubectl resource lookup queries the namespace the
# user is actually targeting instead of always "default". Prints the
# namespace, or nothing if none is on the line. This is the only
# mid-command flag the two kubectl matchers below understand — see their
# comment on why anything else makes them back off.
_lumen_kubectl_ns() {
  local -a w=(${(z)BUFFER})
  local -i i
  for (( i = 1; i <= ${#w}; i++ )); do
    case "${w[i]}" in
      -n|--namespace)
        [[ -n "${w[i+1]:-}" && "${w[i+1]}" != -* ]] && { print -r -- "${w[i+1]}"; return 0 }
        ;;
      -n=*|--namespace=*) print -r -- "${w[i]#*=}"; return 0 ;;
    esac
  done
  return 0
}

# Suggests real pod names once a kubectl subcommand whose first argument is
# a bare pod name has been typed (logs/exec/attach/port-forward/debug) —
# the kubectl counterpart to _lumen_docker_container_match, replacing the
# static "<pod>" hint from _LUMEN_KUBECTL_SUBCMDS with actual pods from
# `kubectl get pods` (their phase shown in the description column, the way
# the docker matcher shows container status). Honours a leading "-n <ns>"
# but backs off if any *other* flag sits between the subcommand and the
# name — the live lookup and the rebuilt candidate only understand the
# plain shape, same scope the docker matchers keep. Runs `kubectl get
# pods` fresh on every keystroke (no cache, same as the git/docker
# matchers); it is a read-only call and stays silent when there is no
# reachable cluster.
_lumen_kubectl_pod_match() {
  local tool="${BUFFER%% *}"
  case "$tool" in kubectl|k) ;; *) return 1 ;; esac
  [[ "$BUFFER" == "$tool "* ]] || return 1

  local -a words=(${(z)BUFFER})
  local verb="${words[2]:-}"
  case "$verb" in
    logs|exec|attach|port-forward|debug) ;;
    *) return 1 ;;
  esac

  local partial=""
  if [[ "$BUFFER" != *' ' ]]; then
    partial="${words[-1]}"
    words=("${(@)words[1,-2]}")
  fi
  [[ "$partial" == -* ]] && return 1
  [[ "$partial" == *' '* ]] && return 1

  # The pod name is the first plain argument after the verb, so if one is
  # already sitting there we're past it — back off. A few value-taking
  # flags have their value stepped over so "kubectl exec -it <pod>" still
  # counts zero plain args, not one.
  local -i i plain=0
  for (( i = 3; i <= ${#words}; i++ )); do
    case "${words[i]}" in
      -n|--namespace|-c|--container|--context) (( i++ )) ;;
      -*) ;;
      *) (( plain++ )) ;;
    esac
  done
  (( plain == 0 )) || return 1

  command -v kubectl &>/dev/null || return 1

  local ns; ns="$(_lumen_kubectl_ns)"
  local -a lines
  # --request-timeout caps the per-keystroke cost when the API server is
  # routable but silent (connection-refused already fails instantly).
  lines=(${(f)"$(command kubectl get pods ${ns:+--namespace=$ns} --no-headers --request-timeout=2s 2>/dev/null)"})
  (( ${#lines} == 0 )) && return 1

  local entry name pstatus
  local -a f
  local icon_kind=$(_lumen_tool_icon_kind kubectl)
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  _LUMEN_DANGER=()
  for entry in "${lines[@]}"; do
    f=(${=entry})
    name="${f[1]}"
    pstatus="${f[3]:-Pod}"   # NAME READY STATUS RESTARTS AGE
    [[ -n "$name" && "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("${BUFFER%$partial}${name} ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${ns:+[$ns] }${pstatus}")
    _LUMEN_ICONS+=("$icon_kind")
    _LUMEN_DANGER+=("")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests resource TYPES and then real resource NAMES for the kubectl
# subcommands that take a "<type> <name>" (or "<type>/<name>") target:
#
#   kubectl get po|                    -> pods, poddisruptionbudgets, ...  (type stage)
#   kubectl get pods web|              -> web-7c9f... (name stage, via `kubectl get pods`)
#   kubectl describe svc/ap|           -> svc/api-gateway (combined type/name word)
#   kubectl set image deploy/w|        -> deploy/web  (nested "set <what>" target)
#   kubectl rollout status deploy|     -> deployments (nested "rollout <what>" target)
#
# Covers the one-word verbs (get/describe/delete/edit/label/annotate/patch/
# scale/autoscale/expose/wait), `explain` (type only — its next word is a
# field path, not a resource name), and the two-word `set <image|env|
# resources|serviceaccount|selector>` / `rollout <status|undo|restart|
# history|pause|resume>` targets. Types come from the static
# _LUMEN_KUBECTL_RESOURCE_TYPES table (no cluster needed); names run
# `kubectl get <type>` live. Same "plain shape plus an optional leading
# -n <ns>" constraint and no-caching policy as _lumen_kubectl_pod_match.
_lumen_kubectl_resource_match() {
  local tool="${BUFFER%% *}"
  case "$tool" in kubectl|k) ;; *) return 1 ;; esac
  [[ "$BUFFER" == "$tool "* ]] || return 1

  local -a words=(${(z)BUFFER})
  local partial=""
  if [[ "$BUFFER" != *' ' ]]; then
    partial="${words[-1]}"
    words=("${(@)words[1,-2]}")
  fi
  [[ "$partial" == *' '* ]] && return 1

  # Resolve the command "verb path" — one word for the plain verbs, two for
  # the nested "set <what>" / "rollout <what>" targets — and the word index
  # its positional args start at.
  local verb="${words[2]:-}" verb2="${words[3]:-}"
  local -i posstart=3
  local -i explain_only=0 rollout_target=0
  case "$verb" in
    get|describe|delete|edit|label|annotate|patch|scale|autoscale|expose|wait) ;;
    explain) explain_only=1 ;;
    set)
      case "$verb2" in
        image|env|resources|serviceaccount|selector) posstart=4 ;;
        *) return 1 ;;
      esac ;;
    rollout)
      case "$verb2" in
        status|undo|restart|history|pause|resume) posstart=4; rollout_target=1 ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac

  # A flag can show up anywhere past the verb — "kubectl get pods -o wide",
  # "kubectl expose deploy app1 --port ..." — not just right after the verb
  # word. _lumen_nested_match keys its flag-table lookup off every word in
  # the path, so once TYPE/NAME are already typed that key no longer
  # matches any table and it falls back to the generic, irrelevant flag
  # list. Resolve the verb's own _FLAGS table directly here instead, using
  # the same _LUMEN_KUBECTL_<VERB>_FLAGS convention nested_match uses.
  if [[ "$partial" == -* ]]; then
    local flag_key="${(U)verb}"
    (( posstart == 4 )) && flag_key+="_${(U)verb2}"
    local flags_table_var="_LUMEN_KUBECTL_${flag_key}_FLAGS"
    (( ${+parameters[$flags_table_var]} )) || return 1
    local -a flags_table=("${(@P)flags_table_var}")
    (( ${#flags_table} > 0 )) || return 1

    local fentry fname icon_kind=$(_lumen_tool_icon_kind kubectl)
    local -a fparts
    _LUMEN_CANDIDATES=(); _LUMEN_DESCRIPTIONS=(); _LUMEN_HINTS=()
    _LUMEN_LABELS=(); _LUMEN_ICONS=(); _LUMEN_DANGER=()
    for fentry in "${flags_table[@]}"; do
      fparts=("${(@ps:\t:)fentry}")
      fname="${fparts[1]}"
      [[ "$fname" == "$partial"* ]] || continue
      _LUMEN_CANDIDATES+=("${BUFFER%$partial}${fname} ")
      _LUMEN_LABELS+=("$fname")
      _LUMEN_HINTS+=("${fparts[2]:-}")
      _LUMEN_DESCRIPTIONS+=("${fparts[3]:-}")
      _LUMEN_ICONS+=("$icon_kind")
      _LUMEN_DANGER+=("${fparts[4]:-}")
      (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
    done
    (( ${#_LUMEN_CANDIDATES} > 0 ))
    return
  fi

  # Plain args already sitting after the verb path: 0 -> we're completing
  # the type; 1 -> that arg is the type and we're completing the name;
  # more -> past it, back off. Values of the common value-taking flags are
  # stepped over.
  local -i i
  local -a plain=()
  for (( i = posstart; i <= ${#words}; i++ )); do
    case "${words[i]}" in
      -n|--namespace|-l|--selector|-o|--output|--context|--field-selector) (( i++ )) ;;
      -*) ;;
      *) plain+=("${words[i]}") ;;
    esac
  done
  (( ${#plain} <= 1 )) || return 1
  # A "type/name" arg is already a complete reference — nothing left to
  # complete (the user has moved on to container=image / KEY=VALUE / ...).
  (( ${#plain} == 1 )) && [[ "${plain[1]}" == */* ]] && return 1
  # `kubectl explain <type>` has no resource-name argument (its second word
  # is a field path like `pods.spec.containers`), so once the type is in,
  # there is nothing here to offer.
  (( explain_only && ${#plain} >= 1 )) && return 1

  local icon_kind=$(_lumen_tool_icon_kind kubectl)
  local ns; ns="$(_lumen_kubectl_ns)"
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  _LUMEN_DANGER=()

  # --- type stage: filter the static resource-type table ------------------
  if (( ${#plain} == 0 )) && [[ "$partial" != */* ]]; then
    local entry name short desc
    local -a parts type_table
    if (( rollout_target )); then
      type_table=("${_LUMEN_KUBECTL_ROLLOUT_TYPES[@]}")
    else
      type_table=("${_LUMEN_KUBECTL_RESOURCE_TYPES[@]}")
    fi
    # Each entry can surface as two distinct rows — the full name and its
    # short alias — rather than one row with the alias jammed onto the end
    # of the name, so "po" matches and reads as its own candidate instead
    # of always trailing "pods".
    for entry in "${type_table[@]}"; do
      parts=("${(@ps:\t:)entry}")
      name="${parts[1]}"
      short="${parts[2]:-}"
      desc="${parts[3]:-}"
      if [[ "$name" == "$partial"* ]]; then
        _LUMEN_CANDIDATES+=("${BUFFER%$partial}${name} ")
        _LUMEN_LABELS+=("$name")
        _LUMEN_HINTS+=("")
        _LUMEN_DESCRIPTIONS+=("$desc")
        _LUMEN_ICONS+=("$icon_kind")
        _LUMEN_DANGER+=("")
        (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
      fi
      if [[ -n "$short" && "$short" == "$partial"* ]]; then
        _LUMEN_CANDIDATES+=("${BUFFER%$partial}${short} ")
        _LUMEN_LABELS+=("$short")
        _LUMEN_HINTS+=("")
        _LUMEN_DESCRIPTIONS+=("Short for $name")
        _LUMEN_ICONS+=("$icon_kind")
        _LUMEN_DANGER+=("")
        (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
      fi
    done
    (( ${#_LUMEN_CANDIDATES} > 0 ))
    return
  fi

  # --- name stage: `kubectl get <type>` ---------------------------------
  [[ "$verb" == explain ]] && return 1   # guarded above; also covers "explain foo/bar"
  local rtype namepart prefix
  if (( ${#plain} == 1 )); then
    rtype="${plain[1]}"
    namepart="$partial"
    prefix="${BUFFER%$partial}"
  else
    # combined "type/name" still being typed as one word
    rtype="${partial%%/*}"
    namepart="${partial#*/}"
    prefix="${BUFFER%$partial}${rtype}/"
  fi
  [[ -n "$rtype" ]] || return 1
  command -v kubectl &>/dev/null || return 1

  local -a lines
  lines=(${(f)"$(command kubectl get "$rtype" ${ns:+--namespace=$ns} --no-headers --request-timeout=2s 2>/dev/null)"})
  (( ${#lines} == 0 )) && return 1

  local entry name desc
  local -a f
  for entry in "${lines[@]}"; do
    f=(${=entry})
    name="${f[1]}"
    [[ -n "$name" && "$name" == "$namepart"* ]] || continue
    case "$rtype" in
      po|pod|pods) desc="${f[3]:-Pod}" ;;          # NAME READY STATUS ...
      *)           desc="${f[2]:-$rtype}" ;;       # 2nd column varies by type
    esac
    _LUMEN_CANDIDATES+=("${prefix}${name} ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${ns:+[$ns] }${desc}")
    _LUMEN_ICONS+=("$icon_kind")
    _LUMEN_DANGER+=("")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Shared by every JSON-based project-file matcher below (package.json's
# "scripts", composer.json's "scripts", deno.json(c)'s "tasks"): reads
# file $1 and prints "name<TAB>value" pairs for each key found inside the
# first top-level object under the JSON key named $2, one per line, in
# file order (current directory only — no upward search, same "just cwd"
# scope as _lumen_cd_match). A crude, line-based parse rather than a
# real JSON parser: assumes the standard single-key-per-line formatting
# every real tool that WRITES these files actually produces, and that the
# block's closing brace is the first "}" line after the key — good enough
# for the common case (this project's long-standing philosophy for all
# the static tables above, applied here to a dynamic source instead), not
# a guarantee against hand-mangled or unusually-formatted JSON. A key
# whose value isn't a plain string (Composer allows an array of commands
# for one script) still prints, just with an empty value — a usable
# candidate, only the description preview is missing. Prints nothing and
# returns 1 if the file doesn't exist or has no such block.
_lumen_json_kv_block() {
  local file=$1 key=$2
  [[ -f $file ]] || return 1
  local line
  local -i in_block=0 found=0
  while IFS= read -r line; do
    if (( ! in_block )); then
      [[ "$line" == *"\"$key\""* ]] && in_block=1
      continue
    fi
    [[ "$line" == *'}'* ]] && break
    if [[ "$line" =~ '"([^"]+)"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"' ]]; then
      print -r -- "${match[1]}"$'\t'"${match[2]}"
      found=1
    elif [[ "$line" =~ '^[[:space:]]*"([^"]+)"[[:space:]]*:' ]]; then
      print -r -- "${match[1]}"$'\t'
      found=1
    fi
  done < "$file"
  (( found ))
}

# Matches "<tool> <partial>" (bare, yarn/pnpm only — see below) or "<tool>
# run <partial>" (npm/yarn/pnpm) against real script names read live from
# ./package.json, so e.g. a repo with a custom "start" script (not one of
# the generic guesses in _LUMEN_{NPM,YARN,PNPM}_SUBCMDS) suggests
# correctly, description showing the actual command it runs. Takes
# priority over _lumen_nested_match/_lumen_static_match (tried
# first in _lumen_static_or_dynamic_match) so real project data wins
# over the generic hand-picked guesses whenever it's available, but backs
# off (returns 1) the moment there's no package.json or nothing matches,
# letting those static tables handle it — this only ever ADDS coverage,
# never removes the fallback for non-script subcommands like `install`/
# `add`.
#
# npm specifically requires the explicit "run" for arbitrary scripts —
# bare `npm <script>` only works for a handful of reserved names (start/
# test/stop/restart), which are exactly the ones already hand-picked into
# _LUMEN_NPM_SUBCMDS, so this only completes after "npm run " to
# avoid suggesting a command that would actually fail to run. yarn and
# pnpm both support invoking a script directly OR via "run", so this
# completes either shape for those two.
_lumen_package_script_match() {
  local tool="${BUFFER%% *}"
  case "$tool" in
    npm|yarn|pnpm) ;;
    *) return 1 ;;
  esac
  [[ "$BUFFER" == "$tool "* ]] || return 1

  local rest="${BUFFER#$tool }"
  local prefix="" partial="$rest"
  if [[ "$tool" == npm ]]; then
    [[ "$rest" == run\ * ]] || return 1
    prefix="run "
    partial="${rest#run }"
  elif [[ "$rest" == run\ * ]]; then
    prefix="run "
    partial="${rest#run }"
  fi
  [[ "$partial" == *' '* ]] && return 1

  local -a script_lines
  script_lines=(${(f)"$(_lumen_json_kv_block package.json scripts)"})
  (( ${#script_lines} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind "$tool")
  local entry name cmd
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${script_lines[@]}"; do
    name="${entry%%$'\t'*}"
    cmd="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("$tool $prefix$name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${cmd:-package.json script}")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Matches "npm uninstall <partial>" / "yarn remove <partial>" / "pnpm
# remove <partial>" against real dependency names read live from
# ./package.json's "dependencies" and "devDependencies" blocks (reusing
# _lumen_json_kv_block, same as the script matcher above) — replaces the
# static "<package>" placeholder from _LUMEN_{NPM,YARN,PNPM}_SUBCMDS with
# packages actually installed in this project, description showing the
# version range from package.json. Each tool's uninstall subcommand name
# differs (npm keeps "install"/"uninstall" as a pair; yarn/pnpm use
# "remove"), so unlike the script matcher this hard-codes one subcommand
# per tool rather than trying to unify them.
_lumen_package_dep_match() {
  local tool="${BUFFER%% *}"
  local subcmd
  case "$tool" in
    npm) subcmd=uninstall ;;
    yarn|pnpm) subcmd=remove ;;
    *) return 1 ;;
  esac
  [[ "$BUFFER" == "$tool $subcmd" || "$BUFFER" == "$tool $subcmd "* ]] || return 1

  local partial="${BUFFER#$tool $subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  local -a dep_lines
  dep_lines=(${(f)"$(_lumen_json_kv_block package.json dependencies)"} ${(f)"$(_lumen_json_kv_block package.json devDependencies)"})
  (( ${#dep_lines} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind "$tool")
  local entry name ver
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${dep_lines[@]}"; do
    name="${entry%%$'\t'*}"
    ver="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("$tool $subcmd $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${ver:-Dependency}")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Reads target names out of ./Makefile (falling back to ./makefile, then
# ./GNUmakefile — the same lookup order `make` itself uses), one per
# line. A target definition is a line starting at column 0 (recipe lines
# are always tab/space-indented and never match this) with a bare
# identifier immediately followed by ":" that isn't itself immediately
# followed by "=" (":=" / "::=" are variable-assignment operators, not a
# target). Special targets like .PHONY/.DEFAULT start with "." and are
# naturally excluded since the match requires an alphanumeric first
# character — this means a real target declared alongside one in a
# `.PHONY: build test` line still gets picked up from its own actual
# `build:`/`test:` definition line elsewhere in the file.
_lumen_makefile_targets() {
  local file
  for file in Makefile makefile GNUmakefile; do
    [[ -f $file ]] && break
    file=""
  done
  [[ -n $file ]] || return 1
  local line
  local -i found=0
  while IFS= read -r line; do
    if [[ "$line" =~ '^([A-Za-z0-9][A-Za-z0-9_.%/-]*)[[:space:]]*:([^=]|$)' ]]; then
      print -r -- "${match[1]}"
      found=1
    fi
  done < "$file"
  (( found ))
}

# Matches "make <partial>" against real target names read live from
# ./Makefile — `make` has no static subcommand table of its own (unlike
# npm/yarn/pnpm, there's no meaningful generic guess for what a
# project's targets are called), so this is its only source of
# completions. Backs off with nothing when there's no Makefile here.
_lumen_make_match() {
  local tool="${BUFFER%% *}"
  [[ "$tool" == make ]] || return 1
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1
  local partial=""
  [[ "$BUFFER" == "$tool "* ]] && partial="${BUFFER#$tool }"
  [[ "$partial" == *' '* ]] && return 1

  local -a targets
  targets=(${(f)"$(_lumen_makefile_targets)"})
  (( ${#targets} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind make)
  local name
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for name in "${targets[@]}"; do
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("make $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Makefile target")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Reads recipe names out of ./justfile (falling back to ./Justfile — Just
# accepts either capitalization), one per line. A recipe definition is a
# line starting at column 0 with a bare identifier (optionally prefixed
# by "@" for a silent recipe), followed eventually by ":" that isn't
# immediately followed by "=" (":=" is Just's variable-assignment
# operator, not a recipe) — recipe bodies are always indented and never
# match this.
_lumen_justfile_recipes() {
  local file
  for file in justfile Justfile; do
    [[ -f $file ]] && break
    file=""
  done
  [[ -n $file ]] || return 1
  local line
  local -i found=0
  while IFS= read -r line; do
    if [[ "$line" =~ '^@?([A-Za-z_][A-Za-z0-9_-]*)[^:]*:([^=]|$)' ]]; then
      print -r -- "${match[1]}"
      found=1
    fi
  done < "$file"
  (( found ))
}

# Matches "just <partial>" against real recipe names read live from
# ./justfile — same reasoning as _lumen_make_match: no meaningful
# generic guess exists for a project's own recipe names, so this is
# Just's only source of completions.
_lumen_just_match() {
  local tool="${BUFFER%% *}"
  [[ "$tool" == just ]] || return 1
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1
  local partial=""
  [[ "$BUFFER" == "$tool "* ]] && partial="${BUFFER#$tool }"
  [[ "$partial" == *' '* ]] && return 1

  local -a recipes
  recipes=(${(f)"$(_lumen_justfile_recipes)"})
  (( ${#recipes} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind just)
  local name
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for name in "${recipes[@]}"; do
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("just $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Just recipe")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Matches "composer run-script <partial>" against real script names read
# live from ./composer.json's "scripts" object — the PHP-ecosystem
# equivalent of _lumen_package_script_match. Unlike npm/yarn/pnpm,
# Composer has no bare "composer <script>" invocation form at all, so
# this only ever completes after the explicit "run-script".
_lumen_composer_match() {
  [[ "$BUFFER" == composer\ run-script\ * ]] || return 1
  local partial="${BUFFER#composer run-script }"
  [[ "$partial" == *' '* ]] && return 1

  local -a script_lines
  script_lines=(${(f)"$(_lumen_json_kv_block composer.json scripts)"})
  (( ${#script_lines} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind composer)
  local entry name cmd
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${script_lines[@]}"; do
    name="${entry%%$'\t'*}"
    cmd="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("composer run-script $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${cmd:-Composer script}")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Matches "deno task <partial>" against real task names read live from
# ./deno.json's (or ./deno.jsonc's) "tasks" object — the Deno-ecosystem
# equivalent of _lumen_package_script_match. Deno reserves its own
# top-level subcommands (run/test/fmt/lint/task/...), so — like npm —
# there's no bare "deno <task>" form; this only completes after "task".
_lumen_deno_task_match() {
  [[ "$BUFFER" == deno\ task\ * ]] || return 1
  local partial="${BUFFER#deno task }"
  [[ "$partial" == *' '* ]] && return 1

  local file=deno.json
  [[ -f $file ]] || file=deno.jsonc
  local -a task_lines
  task_lines=(${(f)"$(_lumen_json_kv_block "$file" tasks)"})
  (( ${#task_lines} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind deno)
  local entry name cmd
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${task_lines[@]}"; do
    name="${entry%%$'\t'*}"
    cmd="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("deno task $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${cmd:-Deno task}")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Matches "rake <partial>" against real task names read live from `rake -T`
# — the Ruby-ecosystem equivalent of _lumen_make_match, but shelling out
# instead of parsing the project file directly: a Rakefile is arbitrary
# Ruby code (define_task, loops, conditionals, imported .rake files from
# other gems), not a declarative format like package.json/Makefile, so
# there's no reliable way to read task names off the file itself — `rake
# -T`'s "rake <name>[params]  # description" listing is rake's own answer,
# already resolved. Requires an actual Rakefile in the directory before
# even trying, both to back off fast in a non-Ruby project and to avoid
# rake's own "No Rakefile found" error output.
_lumen_rake_match() {
  [[ "$BUFFER" == rake || "$BUFFER" == rake\ * ]] || return 1
  local partial=""
  [[ "$BUFFER" == rake\ * ]] && partial="${BUFFER#rake }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  [[ -f Rakefile || -f rakefile || -f Rakefile.rb ]] || return 1
  command -v rake &>/dev/null || return 1

  local -a lines
  lines=(${(f)"$(command rake -T 2>/dev/null)"})
  (( ${#lines} == 0 )) && return 1

  local line name desc
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for line in "${lines[@]}"; do
    [[ "$line" == rake\ * ]] || continue
    name="${line#rake }"
    name="${name%% *}"
    desc="${line#*# }"
    [[ "$desc" == "$line" ]] && desc=""
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("rake $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${desc:-Rake task}")
    _LUMEN_ICONS+=("cmd")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Prints the immediate child key names of the first top-level object found
# under JSON key $2 in file $1, one per line — the same job as
# _lumen_json_kv_block above, but for blocks whose values are themselves
# objects rather than plain strings (turbo.json's "tasks"/"pipeline": each
# task name maps to a config object like {"dependsOn": [...], "outputs":
# [...]}, not a shell-command string). _lumen_json_kv_block's "stop at the
# first line containing a '}'" rule can't be reused here — that first '}'
# usually just closes the FIRST task's own config object, not the whole
# block, which would silently cut off every task after it. This tracks
# brace depth instead: only a key line seen while depth==1 (a direct child
# of the block's own opening "{", not nested inside some task's config) is
# a real task name.
_lumen_json_object_keys_block() {
  local file=$1 key=$2
  [[ -f $file ]] || return 1
  local line
  local -i in_block=0 depth=0 found=0
  while IFS= read -r line; do
    if (( ! in_block )); then
      if [[ "$line" == *"\"$key\""* ]]; then
        in_block=1
        depth=1
      fi
      continue
    fi
    if (( depth == 1 )) && [[ "$line" =~ '^[[:space:]]*"([^"]+)"[[:space:]]*:' ]]; then
      print -r -- "${match[1]}"
      found=1
    fi
    local -i opens=${#${(S)line//[^\{]/}} closes=${#${(S)line//[^\}]/}}
    (( depth += opens - closes ))
    (( depth <= 0 )) && break
  done < "$file"
  (( found ))
}

# Matches "turbo run <partial>" against real task names read live from
# ./turbo.json's "tasks" object (Turborepo >=2.0) or, if that's not found,
# its older "pipeline" object (<2.0) — replacing the static "<project>:
# <target>" guess from _LUMEN_TURBO_SUBCMDS with the monorepo's actual
# declared tasks.
_lumen_turbo_task_match() {
  [[ "$BUFFER" == turbo\ run\ * ]] || return 1
  local partial="${BUFFER#turbo run }"
  [[ "$partial" == *' '* ]] && return 1

  [[ -f turbo.json ]] || return 1
  local -a task_names
  task_names=(${(f)"$(_lumen_json_object_keys_block turbo.json tasks)"})
  (( ${#task_names} > 0 )) || task_names=(${(f)"$(_lumen_json_object_keys_block turbo.json pipeline)"})
  (( ${#task_names} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind turbo)
  local name
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for name in "${task_names[@]}"; do
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("turbo run $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Turborepo task")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Reads task names out of ./Taskfile.yml (falling back to Taskfile.yaml) —
# go-task's project file, the cross-language answer to Makefile that a
# growing number of Go/polyglot projects use instead. YAML has no braces to
# depth-track like turbo.json above, so this tracks INDENTATION instead:
# once the "tasks:" line is found, the first key line seen underneath it
# fixes the expected indent for every sibling task name (however many
# spaces that project's YAML actually uses), and only lines at exactly that
# indent count as task names — a task's own nested "desc:"/"cmds:"
# properties are indented further and so never match, and a line indented
# LESS than that means the tasks: block has ended (back to a root-level
# YAML key) and scanning stops.
_lumen_taskfile_tasks() {
  local file=Taskfile.yml
  [[ -f $file ]] || file=Taskfile.yaml
  [[ -f $file ]] || return 1
  local line indent="" pattern
  local -i in_block=0 found=0
  while IFS= read -r line; do
    if (( ! in_block )); then
      [[ "$line" =~ '^tasks:[[:space:]]*$' ]] && in_block=1
      continue
    fi
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ -z "$indent" ]]; then
      [[ "$line" =~ '^([[:space:]]+)[A-Za-z0-9_.:-]+:' ]] || break
      indent="${match[1]}"
    fi
    [[ "$line" == "${indent}"* ]] || break
    pattern="^${indent}([A-Za-z0-9_.:-]+):"
    if [[ "$line" =~ $pattern ]]; then
      print -r -- "${match[1]}"
      found=1
    fi
  done < "$file"
  (( found ))
}

# Matches "task <partial>" against real task names read live from
# ./Taskfile.yml.
_lumen_task_match() {
  [[ "$BUFFER" == task || "$BUFFER" == task\ * ]] || return 1
  local partial=""
  [[ "$BUFFER" == task\ * ]] && partial="${BUFFER#task }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  local -a tasks
  tasks=(${(f)"$(_lumen_taskfile_tasks)"})
  (( ${#tasks} > 0 )) || return 1

  local name
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for name in "${tasks[@]}"; do
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("task $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Taskfile task")
    _LUMEN_ICONS+=("cmd")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Prints "name<TAB>target" for each entry under pyproject.toml's
# "[tool.poetry.scripts]" table — Poetry's equivalent of package.json's
# "scripts" (console-script entry points, invoked via "poetry run <name>"),
# TOML rather than JSON so it needs its own small parser: scan for the
# "[tool.poetry.scripts]" header, then read "name = "target"" lines until
# the next "[...]" table header or EOF.
_lumen_poetry_script_names() {
  local file=pyproject.toml
  [[ -f $file ]] || return 1
  local line
  local -i in_block=0 found=0
  while IFS= read -r line; do
    if (( ! in_block )); then
      [[ "$line" =~ '^\[tool\.poetry\.scripts\][[:space:]]*$' ]] && in_block=1
      continue
    fi
    [[ "$line" == \[* ]] && break
    if [[ "$line" =~ '^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*"([^"]*)"' ]]; then
      print -r -- "${match[1]}"$'\t'"${match[2]}"
      found=1
    elif [[ "$line" =~ "^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*'([^']*)'" ]]; then
      print -r -- "${match[1]}"$'\t'"${match[2]}"
      found=1
    fi
  done < "$file"
  (( found ))
}

# Matches "poetry run <partial>" against real script names read live from
# ./pyproject.toml's "[tool.poetry.scripts]" table — the Python/Poetry
# equivalent of _lumen_package_script_match, description showing the
# module:function target each script points to.
_lumen_poetry_script_match() {
  [[ "$BUFFER" == poetry\ run\ * ]] || return 1
  local partial="${BUFFER#poetry run }"
  [[ "$partial" == *' '* ]] && return 1

  local -a script_lines
  script_lines=(${(f)"$(_lumen_poetry_script_names)"})
  (( ${#script_lines} > 0 )) || return 1

  local icon_kind=$(_lumen_tool_icon_kind poetry)
  local entry name target
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${script_lines[@]}"; do
    name="${entry%%$'\t'*}"
    target="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("poetry run $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("${target:-Poetry script}")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real installed Node.js versions once "nvm use/uninstall" needs
# one, replacing the static "<version>" placeholder from _LUMEN_NVM_SUBCMDS.
# Unlike git/docker, nvm has no standalone binary — it's a shell function
# loaded from nvm.sh — so this calls it directly (no "command" prefix,
# which would just fail with "command not found"). `nvm ls --no-colors`'s
# output mixes version lines with a current-version arrow, aliases, and
# "N/A" — rather than parse that format, this just regex-extracts every
# "vX.Y.Z" token and de-dupes (the "u" in "${(fu)...}"), which is what
# every line with a real version in it contains regardless of the
# surrounding decoration.
_lumen_nvm_match() {
  [[ "$BUFFER" == nvm\ * ]] || return 1
  local rest="${BUFFER#nvm }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    use|uninstall) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  (( ${+functions[nvm]} )) || command -v nvm &>/dev/null || return 1

  local -a versions
  versions=(${(fu)"$(nvm ls --no-colors 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"})
  (( ${#versions} == 0 )) && return 1

  local v icon_kind=$(_lumen_tool_icon_kind nvm)
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for v in "${versions[@]}"; do
    [[ "$v" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("nvm $subcmd $v ")
    _LUMEN_LABELS+=("$v")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Installed Node.js version")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Shared by _lumen_pyenv_match/_lumen_rbenv_match below: both tools print
# one clean version string per line via "versions --bare" (no decoration to
# strip, unlike nvm above), so the two matchers only differ in which
# binary/subcommand table they read from. $1 is the tool name (pyenv/
# rbenv), used for both the binary to run and the icon lookup.
_lumen_version_manager_match() {
  local tool=$1
  [[ "$BUFFER" == "$tool "* ]] || return 1
  local rest="${BUFFER#$tool }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    global|local|shell|uninstall) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  command -v "$tool" &>/dev/null || return 1

  local -a versions
  versions=(${(f)"$(command "$tool" versions --bare 2>/dev/null)"})
  (( ${#versions} == 0 )) && return 1

  local v icon_kind=$(_lumen_tool_icon_kind "$tool")
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for v in "${versions[@]}"; do
    [[ "$v" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("$tool $subcmd $v ")
    _LUMEN_LABELS+=("$v")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Installed version")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}
_lumen_pyenv_match() { _lumen_version_manager_match pyenv }
_lumen_rbenv_match() { _lumen_version_manager_match rbenv }

# Suggests real installed formula/cask names once a brew subcommand that
# takes one has been typed (uninstall/info/link/unlink) — replaces the
# static "<formula>" placeholder from _LUMEN_BREW_SUBCMDS. "install" and
# "search" are deliberately excluded: their argument is any formula in the
# whole Homebrew catalog, not something enumerable from local state, same
# reasoning as leaving `docker pull`/`npx` alone.
_lumen_brew_match() {
  [[ "$BUFFER" == brew\ * ]] || return 1
  local rest="${BUFFER#brew }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    uninstall|info|link|unlink) ;;
    *) return 1 ;;
  esac
  [[ "$rest" == "$subcmd" || "$rest" == "$subcmd "* ]] || return 1

  local partial="${rest#$subcmd}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1
  [[ "$partial" == -* ]] && return 1

  command -v brew &>/dev/null || return 1

  local -a formulas
  formulas=(${(f)"$(command brew list --formula 2>/dev/null)"} ${(f)"$(command brew list --cask 2>/dev/null)"})
  (( ${#formulas} == 0 )) && return 1

  local f icon_kind=$(_lumen_tool_icon_kind brew)
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for f in "${formulas[@]}"; do
    [[ "$f" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("brew $subcmd $f ")
    _LUMEN_LABELS+=("$f")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("Installed formula")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests real tmux session names once "-t" needs one after
# attach/attach-session/kill-session/switch-client/switch — replaces the
# static "<name>" placeholder from _LUMEN_TMUX_ATTACH_SESSION_FLAGS/
# _LUMEN_TMUX_KILL_SESSION_FLAGS. Unlike the other matchers here, the
# argument follows a flag rather than being positional, so this looks for
# "-t" as the token immediately before the partial instead of stripping a
# leading subcommand.
_lumen_tmux_session_match() {
  [[ "$BUFFER" == tmux\ * ]] || return 1
  local rest="${BUFFER#tmux }"
  rest="${rest## }"
  local subcmd="${rest%% *}"
  case "$subcmd" in
    attach|attach-session|kill-session|switch-client|switch) ;;
    *) return 1 ;;
  esac

  local after="${rest#$subcmd}"
  after="${after## }"
  [[ "$after" == "-t" || "$after" == -t\ * ]] || return 1
  local partial="${after#-t}"
  partial="${partial## }"
  [[ "$partial" == *' '* ]] && return 1

  command -v tmux &>/dev/null || return 1

  local -a sessions
  sessions=(${(f)"$(command tmux list-sessions -F '#S' 2>/dev/null)"})
  (( ${#sessions} == 0 )) && return 1

  local s icon_kind=$(_lumen_tool_icon_kind tmux)
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for s in "${sessions[@]}"; do
    [[ "$s" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("tmux $subcmd -t $s ")
    _LUMEN_LABELS+=("$s")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("tmux session")
    _LUMEN_ICONS+=("$icon_kind")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Matches "<tool> <subcmd> [<subcmd2> ...] <partial>" against a nested
# static table one (or more) levels deeper than _lumen_static_match: the
# sub-subcommands of a subcommand that is itself a management command (e.g.
# "docker image" -> ls/build/rm/..., "git stash" -> push/pop/list/...), or
# the flags of a specific — possibly nested — subcommand once the word being
# typed starts with "-" (e.g. "docker ps -" -> -a/-q/..., "docker image ls
# -" -> -a/-q/...). No hand-maintained dispatch table for this: the variable
# name is derived from the command path actually typed so far — tool plus
# each subcommand word, non-alnum characters turned into "_" and upper-cased,
# joined by "_", with a "_SUBCMDS" or "_FLAGS" suffix (see the "nested
# (sub-subcommand and flag) tables" block above the git tables) — and looked
# up indirectly via zsh's ${(P)} parameter flag. A path with nothing defined
# for it (docker's `run` doesn't have its own sub-subcommands, most
# subcommands don't have a hand-picked flag table) just means no table
# exists at that name, so this backs off same as any other non-match.
_lumen_nested_match() {
  local tool="${BUFFER%% *}"
  [[ "$BUFFER" == "$tool "* ]] || return 1

  case "$tool" in
    git|kubectl|k|npm|docker|aws|terraform|tf|helm|gh|glab|gcloud|az|tmux|vagrant|cargo|yarn|pnpm|pulumi|systemctl) ;;
    *) return 1 ;;
  esac

  local -a words
  words=(${(z)BUFFER})
  (( ${#words} >= 2 )) || return 1

  local partial=""
  if [[ "$BUFFER" != *' ' ]]; then
    partial=${words[-1]}
    words=("${(@)words[1,-2]}")
  fi
  # Need the tool plus at least one already-typed (complete) subcommand word
  # beyond it — a bare "<tool> <partial>" with nothing finished past the
  # tool yet is level 1, already handled by _lumen_static_match.
  (( ${#words} >= 2 )) || return 1
  [[ "$partial" == *' '* ]] && return 1

  local tool_canon=$tool
  [[ "$tool" == "k" ]] && tool_canon="kubectl"
  [[ "$tool" == "tf" ]] && tool_canon="terraform"

  local -a path=("${(@)words[2,-1]}")
  local seg key="${(U)tool_canon}"
  for seg in "${path[@]}"; do
    key+="_${(U)seg//[^a-zA-Z0-9]/_}"
  done

  # Tries each candidate table name in priority order and commits to the
  # first one that actually exists — never falls through past a table that
  # exists but happens to filter down to zero matches later (that's a real
  # "no match", not "try the next fallback"), only past ones with no data
  # at this path at all.
  local table_var
  if [[ "$partial" == -* ]]; then
    # A flag can follow any number of positional args past the verb —
    # "kubectl get pods -o wide", "git checkout main -f", "docker restart
    # mycontainer -t 5" — not just sit right after it. The full path key
    # built above only matches a table when nothing positional came
    # between the verb and the flag, so try it first and then
    # progressively drop trailing (positional) words until a real
    # per-verb *_FLAGS table turns up, landing on the verb's own table
    # instead of a nonsense key salted with a resource/branch/container
    # name.
    local -a kpath=("${(@)path}")
    local ktool="${(U)tool_canon//[^a-zA-Z0-9]/_}" kkey kseg candidate
    table_var=""
    while true; do
      kkey="$ktool"
      for kseg in "${kpath[@]}"; do
        kkey+="_${(U)kseg//[^a-zA-Z0-9]/_}"
      done
      candidate="_LUMEN_${kkey}_FLAGS"
      if (( ${+parameters[$candidate]} )); then
        table_var="$candidate"
        break
      fi
      (( ${#kpath} == 0 )) && break
      kpath=("${(@)kpath[1,-2]}")
    done
    [[ -n "$table_var" ]] || table_var="_LUMEN_GENERIC_FLAGS"
  else
    table_var="_LUMEN_${key}_SUBCMDS"
    # A "leaf" command with only a *_FLAGS table and no sub-subcommands of
    # its own (docker ps/images/run/exec/logs, git log/branch/checkout/
    # diff, kubectl get/exec, ...) has nothing under *_SUBCMDS at all —
    # without this fallback, finishing that word and hitting space (partial
    # == "") would show nothing until the user remembered to type "-"
    # themselves first, unlike every sibling command that has real
    # sub-subcommands (e.g. "docker image " suggests immediately). Falling
    # back to the flags table here means "docker images " now offers
    # -a/-q/--filter right away, same as "docker images -" already did.
    if (( ! ${+parameters[$table_var]} )); then
      table_var="_LUMEN_${key}_FLAGS"
      (( ${+parameters[$table_var]} )) || table_var="_LUMEN_GENERIC_FLAGS"
    fi
  fi
  # Flags and sub-subcommands both belong to the same tool, so they get the
  # same glyph — see _lumen_tool_icon_kind.
  local icon_kind=$(_lumen_tool_icon_kind "$tool_canon")
  (( ${+parameters[$table_var]} )) || return 1
  local -a table=("${(@P)table_var}")
  (( ${#table} > 0 )) || return 1

  local entry name
  local -a parts
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  _LUMEN_DANGER=()
  for entry in "${table[@]}"; do
    parts=("${(@ps:\t:)entry}")
    name=$parts[1]
    [[ "$name" == "$partial"* ]] || continue
    _LUMEN_CANDIDATES+=("$tool ${(j: :)path} $name ")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("${parts[2]:-}")
    _LUMEN_DESCRIPTIONS+=("${parts[3]:-}")
    _LUMEN_ICONS+=("$icon_kind")
    _LUMEN_DANGER+=("${parts[4]:-}")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Suggests common deletable files/folders when typing `rm` with flags like
# -rf, -r, -f. Scans the current directory for common build artifacts,
# dependencies, caches, and temporary files that users typically want to
# remove. Each suggestion shows whether it exists in the current directory
# and what type of artifact it is (build/dependency/cache/system).
_lumen_rm_match() {
  [[ "$BUFFER" == rm\ * ]] || return 1
  local rest="${BUFFER#rm }"
  rest="${rest## }"
  
  # Must have at least one flag (typically -rf, -r, -f, etc.)
  # and be typing a path argument after the flags
  [[ "$rest" == -* ]] || return 1
  
  # Extract the partial path being typed (after all flags)
  local partial=""
  local -a words=(${(z)BUFFER})
  local -i i
  local found_path=0
  
  # Skip "rm" and all flag arguments to find the path being typed
  for (( i=2; i <= ${#words}; i++ )); do
    if [[ "${words[i]}" != -* ]]; then
      found_path=1
      partial="${words[i]}"
      break
    fi
  done
  
  # If buffer ends with space after flags, ready for path suggestions
  if [[ "$BUFFER" == *' ' && "$found_path" == 0 ]]; then
    partial=""
  elif [[ "$found_path" == 0 ]]; then
    # Still typing flags, not ready for path suggestions yet
    return 1
  fi
  
  # Don't suggest if user has moved past the first argument (already typing second path)
  [[ "$partial" == *' '* ]] && return 1
  
  # Common patterns to suggest for deletion
  # Format: "name<TAB>description<TAB>category"
  local -a deletion_patterns=(
    $'.build\tSwift build artifacts\tBuild artifacts'
    $'build\tCompiled output directory\tBuild artifacts'
    $'dist\tDistribution/build output\tBuild artifacts'
    $'target\tRust/Java build directory\tBuild artifacts'
    $'out\tBuild output directory\tBuild artifacts'
    $'bin\tBinary output directory\tBuild artifacts'
    $'obj\tObject files directory\tBuild artifacts'
    $'.gradle\tGradle cache directory\tBuild artifacts'
    $'DerivedData\tXcode build artifacts\tBuild artifacts'
    $'node_modules\tNode.js dependencies\tDependencies'
    $'vendor\tPHP/Ruby dependencies\tDependencies'
    $'.bundle\tBundler dependencies cache\tDependencies'
    $'bower_components\tBower dependencies\tDependencies'
    $'jspm_packages\tJSPM dependencies\tDependencies'
    $'.cache\tGeneric cache directory\tCache'
    $'.npm\tnpm package cache\tCache'
    $'.yarn\tYarn cache directory\tCache'
    $'.pnpm-store\tpnpm store cache\tCache'
    $'.next\tNext.js build cache\tCache'
    $'.nuxt\tNuxt.js build cache\tCache'
    $'.vite\tVite cache directory\tCache'
    $'.turbo\tTurborepo cache\tCache'
    $'.parcel-cache\tParcel bundler cache\tCache'
    $'__pycache__\tPython bytecode cache\tCache'
    $'.pytest_cache\tPytest cache directory\tCache'
    $'.mypy_cache\tMypy type checker cache\tCache'
    $'.ruff_cache\tRuff linter cache\tCache'
    $'.tox\tTox testing cache\tCache'
    $'.coverage\tCoverage.py data file\tTemp files'
    $'.DS_Store\tmacOS folder metadata\tSystem files'
    $'Thumbs.db\tWindows thumbnail cache\tSystem files'
    $'desktop.ini\tWindows folder settings\tSystem files'
    $'*.log\tLog files\tTemp files'
    $'tmp\tTemporary files directory\tTemp files'
    $'.tmp\tHidden temporary files\tTemp files'
    $'temp\tTemporary files directory\tTemp files'
    $'logs\tLog files directory\tTemp files'
    $'coverage\tTest coverage reports\tTemp files'
    $'.nyc_output\tIstanbul coverage data\tTemp files'
  )
  
  # Find matches that exist in current directory
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  
  local entry name hint desc
  local -a parts matches
  setopt local_options extended_glob
  
  for entry in "${deletion_patterns[@]}"; do
    parts=("${(@ps:\t:)entry}")
    name=$parts[1]
    hint=$parts[2]
    desc=$parts[3]
    
    # Check if this pattern matches the partial input
    [[ "$name" == "$partial"* ]] || continue
    
    # Only suggest patterns that actually exist in the current directory —
    # no point offering to delete a .gradle cache in a folder that has no
    # .gradle.
    matches=( ${~name}(N) )
    (( ${#matches} > 0 )) || continue

    _LUMEN_CANDIDATES+=("rm ${rest%$partial}${name}")
    _LUMEN_LABELS+=("$name")
    _LUMEN_HINTS+=("$hint")
    _LUMEN_DESCRIPTIONS+=("$desc")
    _LUMEN_ICONS+=("dir")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done

  # Real files/directories in the working directory matching the partial —
  # on top of the curated junk-pattern list above, so an ordinary folder
  # like "assets" or "my-notes" (not a recognized build/cache pattern)
  # still shows up. Same case-insensitive glob _lumen_cd_match uses for cd,
  # but without the dirs-only qualifier since rm removes files too.
  if (( ${#_LUMEN_CANDIDATES} < _LUMEN_MAX_CANDIDATES )); then
    local -a fs_matches
    fs_matches=( (#i)${partial}*(N) )
    local fentry flabel ficon fdesc existing already
    for fentry in "${fs_matches[@]}"; do
      if [[ -d "$fentry" ]]; then
        flabel="${fentry%/}/"
        ficon="dir"
        fdesc="Directory"
      else
        flabel="$fentry"
        ficon=""
        fdesc="File"
      fi

      already=0
      for existing in "${_LUMEN_LABELS[@]}"; do
        [[ "${existing%/}" == "${flabel%/}" ]] && { already=1; break }
      done
      (( already )) && continue

      _LUMEN_CANDIDATES+=("rm ${rest%$partial}${flabel}")
      _LUMEN_LABELS+=("$flabel")
      _LUMEN_HINTS+=("")
      _LUMEN_DESCRIPTIONS+=("$fdesc")
      _LUMEN_ICONS+=("$ficon")
      (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
    done
  fi

  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Generic real-filesystem path completion shared by plain path-argument
# Unix commands (cp/mv/ln) that don't have "subcommands" the way git/docker
# do — just flags followed by one or more path arguments. Always completes
# the LAST word on the buffer, whichever argument position that happens to
# be (source or destination) — not worth telling those apart, the same way
# regular shell tab-completion doesn't either.
_lumen_path_arg_match() {
  local tool=$1 verb=$2
  [[ "$BUFFER" == "$tool "* ]] || return 1

  local -a words=(${(z)BUFFER})
  local partial=""
  [[ "$BUFFER" == *' ' ]] || partial="${words[-1]}"
  [[ "$partial" == -* ]] && return 1

  local -a matches
  setopt local_options extended_glob
  matches=( (#i)${partial}*(N) )
  (( ${#matches} == 0 )) && return 1

  local entry label icon
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${matches[@]}"; do
    if [[ -d "$entry" ]]; then
      label="${entry%/}/"
      icon="dir"
    else
      label="$entry"
      icon=""
    fi
    _LUMEN_CANDIDATES+=("${BUFFER%$partial}${label}")
    _LUMEN_LABELS+=("$label")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("$verb target")
    _LUMEN_ICONS+=("$icon")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}
_lumen_cp_match() { _lumen_path_arg_match cp Copy }
_lumen_mv_match() { _lumen_path_arg_match mv Move }
_lumen_ln_match() { _lumen_path_arg_match ln Link }

# Suggests running processes for kill/pkill/killall from the live process
# table (`ps`) — the process-table counterpart to
# _lumen_docker_container_match, using local `ps` output instead of
# `docker ps` as the data source. kill takes a PID, so its candidates
# insert the PID; pkill/killall take a process NAME, so theirs insert the
# name instead — same underlying process list, different column becomes
# the insertable text.
_lumen_kill_match() {
  local tool="${BUFFER%% *}"
  case "$tool" in
    kill|pkill|killall) ;;
    *) return 1 ;;
  esac
  [[ "$BUFFER" == "$tool "* ]] || return 1

  # Complete the LAST word on the buffer, same as _lumen_path_arg_match —
  # covers both the plain "kill 123" case and "kill -9 123" (a flag before
  # the target is normal for kill), plus a second target after the first
  # ("kill 111 22").
  local -a words=(${(z)BUFFER})
  local rest=""
  [[ "$BUFFER" == *' ' ]] || rest="${words[-1]}"
  [[ "$rest" == -* ]] && return 1

  local -a lines
  lines=(${(f)"$(command ps -axo pid=,comm= 2>/dev/null)"})
  (( ${#lines} == 0 )) && return 1

  local entry pid pname insertable desc
  local -a fields seen_names
  _LUMEN_CANDIDATES=()
  _LUMEN_DESCRIPTIONS=()
  _LUMEN_HINTS=()
  _LUMEN_LABELS=()
  _LUMEN_ICONS=()
  for entry in "${lines[@]}"; do
    # ${=entry} forces whitespace word-splitting regardless of SH_WORD_SPLIT,
    # collapsing the leading spaces macOS's `ps -o pid=` right-pads numeric
    # PIDs with (plain ${entry%% *}/${entry#* } trimming leaves those in,
    # yielding an empty pid) — comm can't contain spaces (it's a path), so a
    # 2-field split is safe.
    fields=(${=entry})
    pid="${fields[1]}"
    pname="${fields[2]:t}" # ps -o comm= reports a full path on macOS — basename only

    if [[ "$tool" == "kill" ]]; then
      [[ "$pid" == "$rest"* ]] || continue
      insertable="$pid"
      desc="$pname"
    else
      [[ "$pname" == "$rest"* ]] || continue
      (( ${seen_names[(Ie)$pname]} )) && continue
      seen_names+=("$pname")
      insertable="$pname"
      desc="pid $pid"
    fi

    _LUMEN_CANDIDATES+=("${BUFFER%$rest}${insertable}")
    _LUMEN_LABELS+=("$insertable")
    _LUMEN_HINTS+=("")
    _LUMEN_DESCRIPTIONS+=("$desc")
    _LUMEN_ICONS+=("")
    (( ${#_LUMEN_CANDIDATES} >= _LUMEN_MAX_CANDIDATES )) && break
  done
  (( ${#_LUMEN_CANDIDATES} > 0 ))
}

# Tries every no-AI-round-trip match source in order, cheapest/most-specific
# first, and stops at the first one that produces candidates. Shared entry
# point for both the automatic (_lumen_suggest_now) and manual
# (_lumen_trigger) paths so they never drift out of sync on what counts
# as a "static" match.
_lumen_static_or_dynamic_match() {
  _lumen_cd_match && return 0
  _lumen_rm_match && return 0
  _lumen_cp_match && return 0
  _lumen_mv_match && return 0
  _lumen_ln_match && return 0
  _lumen_kill_match && return 0
  _lumen_git_branch_match && return 0
  _lumen_git_remote_match && return 0
  _lumen_git_stash_match && return 0
  _lumen_git_restore_staged_match && return 0
  _lumen_docker_container_match && return 0
  _lumen_docker_image_match && return 0
  _lumen_docker_network_match && return 0
  _lumen_docker_volume_match && return 0
  _lumen_kubectl_pod_match && return 0
  _lumen_kubectl_resource_match && return 0
  _lumen_package_script_match && return 0
  _lumen_package_dep_match && return 0
  _lumen_nvm_match && return 0
  _lumen_pyenv_match && return 0
  _lumen_rbenv_match && return 0
  _lumen_brew_match && return 0
  _lumen_tmux_session_match && return 0
  _lumen_make_match && return 0
  _lumen_just_match && return 0
  _lumen_composer_match && return 0
  _lumen_deno_task_match && return 0
  _lumen_rake_match && return 0
  _lumen_turbo_task_match && return 0
  _lumen_task_match && return 0
  _lumen_poetry_script_match && return 0
  _lumen_nested_match && return 0
  _lumen_static_match
}

# Looks for a suggestion for the CURRENT buffer and renders it. Shared by
# every caller that just changed BUFFER and wants suggestions re-evaluated
# for the new state — a keystroke (_lumen_edit_wrapper) or accepting a
# candidate (_lumen_accept, so picking "git add " immediately offers
# what typically follows it, chaining word-by-word instead of going silent
# until the next keystroke).
_lumen_suggest_now() {
  # Whether the overlay currently has something on screen that this call
  # needs to account for — reset the local arrays now (not through
  # _lumen_clear_display: see its comment for why sending hide here,
  # right before this same call likely sends a fresh show, would get that
  # show silently dropped by the overlay's send throttle).
  local -i had_candidates=$(( ${#_LUMEN_CANDIDATES} > 0 ))
  _lumen_reset_candidates

  # Explicit `return 0`, not bare `return`: a zle widget function that ends
  # with non-zero status makes zle beep, and _lumen_auto_enabled
  # returns non-zero precisely when suggestions are toggled off — bare
  # `return` here would carry that failure status out and ring the
  # terminal bell on every single keystroke while suggestions are disabled.
  if ! _lumen_auto_enabled; then
    (( had_candidates )) && _lumen_overlay_hide
    return 0
  fi

  # Known, exact data (cd targets, git branches, tool subcommands) beats
  # everything else — no guess, no round-trip — so it both answers
  # correctly and skips the AI call entirely for this buffer.
  if _lumen_static_or_dynamic_match; then
    _LUMEN_INDEX=1
    _lumen_present_candidates
  elif (( had_candidates )); then
    # Buffer no longer matches anything (e.g. backspaced past a known
    # prefix) — nothing will replace what was showing, so this is the one
    # case within this call where actually hiding is correct.
    _lumen_overlay_hide
  fi
}

# Wraps every buffer-editing widget: runs whatever was bound to $WIDGET
# before we took it over (another plugin's customization, e.g. zsh's own
# `url-quote-magic` on self-insert — see _lumen_wrap_widget), falling
# back to the plain builtin (`zle .$WIDGET`) when nothing else had claimed
# it, then re-evaluates suggestions for the resulting buffer.
# Set for the duration of a `bracketed-paste` dispatch (see
# _lumen_edit_wrapper) — including the nested self-insert calls that
# happen *inside* it, not just the outer call itself. Needed because
# bracketed-paste handlers (confirmed for oh-my-zsh's bundled
# bracketed-paste-magic via /tmp/lumen-paste-debug.log, 2026-08-13:
# one `bracketed-paste` dispatch immediately followed by dozens of
# individual `self-insert` calls, one per pasted character) commonly read
# the whole paste up front, then loop over it *in memory*, replaying it as
# a run of ordinary self-insert dispatches — purely so other plugins
# (syntax highlighting, etc.) still see every character go through the
# normal path. Each of those nested calls has $WIDGET==self-insert like
# any real keystroke, and crucially $PENDING==0 throughout (there's
# nothing left to read from the terminal — the whole paste was already
# consumed before the loop started), so neither of those alone can tell a
# paste-replay character apart from a real one. This flag can.
typeset -gi _LUMEN_IN_PASTE=0

_lumen_edit_wrapper() {
  # Backspacing the trailing space that just triggered a follow-up
  # suggestion (e.g. "git commit " -> "-m") should close that suggestion,
  # not re-show one — without this check, deleting back to "git commit"
  # re-matches the top-level "commit" entry against itself (same reason
  # _lumen_accept_line has to guard against that self-match; see its
  # comment) and the panel looks like it never closed, just swapped back to
  # the previous suggestion instead of following the character you deleted.
  local -i deleted_trailing_space=0
  if [[ $WIDGET == backward-delete-char && $CURSOR == ${#BUFFER} && $BUFFER == *' ' ]]; then
    deleted_trailing_space=1
  fi

  local -i is_paste_dispatch=0
  if [[ $WIDGET == bracketed-paste ]]; then
    is_paste_dispatch=1
    _LUMEN_IN_PASTE=1
  fi

  if (( $+_LUMEN_ORIG_WIDGET[$WIDGET] )); then
    _lumen_call_orig_widget $WIDGET
  else
    zle .$WIDGET
  fi

  (( is_paste_dispatch )) && _LUMEN_IN_PASTE=0

  # A paste (bracketed-paste — terminals send the whole blob as one event,
  # not a run of individual keystrokes) drops in a complete command someone
  # already knows they want to run, not a partial word to keep exploring —
  # showing a suggestion for it is noise, not help. Worse, without this
  # case a paste that momentarily looks like a flag prefix mid-insert can
  # leave a stale suggestion on screen with nothing left to correct it
  # afterward, since a paste is one atomic buffer change with no further
  # per-character events to re-evaluate on. So: run the real paste (still
  # inserts the text normally) but always clear rather than suggest.
  if [[ $WIDGET == bracketed-paste ]] || (( deleted_trailing_space )); then
    _lumen_clear_display
  elif (( _LUMEN_IN_PASTE )); then
    # One of the nested self-insert replay calls described above — see
    # the comment on _LUMEN_IN_PASTE. Re-matching/re-rendering for
    # every one of these about-to-be-superseded intermediate states is
    # exactly what produces the paste flicker; skip them. The outer
    # bracketed-paste branch above already clears the display once the
    # whole paste is done.
    :
  else
    _lumen_suggest_now
  fi
}

# --- the manual, immediate trigger ------------------------------------------

_lumen_trigger() {
  local -i had_candidates=$(( ${#_LUMEN_CANDIDATES} > 0 ))
  _lumen_reset_candidates

  if [[ -z $BUFFER ]]; then
    (( had_candidates )) && _lumen_overlay_hide 1
    zle -M "lumen: command line is empty"
    return
  fi

  if _lumen_static_or_dynamic_match; then
    _LUMEN_INDEX=1
    _lumen_present_candidates
    return
  fi

  (( had_candidates )) && _lumen_overlay_hide 1
  zle -M "lumen: no suggestions for this command"
  return 1
}

# --- selection widgets --------------------------------------------------------

_lumen_accept() {
  if (( ${#_LUMEN_CANDIDATES} > 0 )); then
    # Capture the chosen candidate before resetting the arrays.
    local chosen=$_LUMEN_CANDIDATES[$_LUMEN_INDEX]
    _lumen_reset_candidates
    # Candidates carry their own trailing separator baked in — a space for
    # every matcher except `cd`, which appends "/" instead (see e.g.
    # _lumen_static_match's "$tool $name " vs the cd matcher's
    # "$tool ${dir%/}/"). Stripping just the space here means accepting
    # inserts only the word itself, cursor right after it — not "word " —
    # so the next suggestion (e.g. "commit" -> "-m") only appears once you
    # actually type a space yourself (self-insert already re-evaluates
    # suggestions on every keystroke, see _lumen_edit_wrapper), instead
    # of popping up immediately on accept the way it used to.
    BUFFER=${chosen% }
    CURSOR=${#BUFFER}
    _lumen_overlay_hide 1
  else
    zle .expand-or-complete
  fi
}

_lumen_forward_char() {
  if (( ${#_LUMEN_CANDIDATES} > 0 )) && (( CURSOR == ${#BUFFER} )); then
    _lumen_accept
  elif (( $+_LUMEN_ORIG_WIDGET[forward-char] )); then
    _lumen_call_orig_widget forward-char
  else
    zle .forward-char
  fi
}

_lumen_next() {
  if (( ${#_LUMEN_CANDIDATES} > 1 )); then
    (( _LUMEN_INDEX = _LUMEN_INDEX % ${#_LUMEN_CANDIDATES} + 1 ))
    _lumen_present_candidates
  else
    zle .down-line-or-history
  fi
}

_lumen_prev() {
  if (( ${#_LUMEN_CANDIDATES} > 1 )); then
    (( _LUMEN_INDEX = (_LUMEN_INDEX - 2 + ${#_LUMEN_CANDIDATES}) % ${#_LUMEN_CANDIDATES} + 1 ))
    _lumen_present_candidates
  else
    zle .up-line-or-history
  fi
}

_lumen_dismiss() {
  if (( ${#_LUMEN_CANDIDATES} > 0 )); then
    _lumen_clear_display
  else
    zle .send-break
  fi
}

# Escape-specific dismiss: unlike Ctrl-G above, this does nothing at all
# (no beep) when there's no suggestion to dismiss, rather than falling
# through to send-break's own beep. send-break beeping when there's
# nothing to abort is normal, long-standing zsh behavior for Ctrl-G at the
# top-level prompt (harmless there since Ctrl-G is a deliberate, rare
# keypress) — but Escape gets pressed on reflex far more often, "just in
# case something is showing," and beeping every single one of those times
# reads as broken rather than as the same expected zsh convention.
_lumen_dismiss_escape() {
  (( ${#_LUMEN_CANDIDATES} > 0 )) && _lumen_clear_display
  true
}

_lumen_accept_line() {
  # A suggestion is showing AND accepting it would actually change BUFFER:
  # Enter accepts it (like Tab) instead of running the line — same as
  # picking it and pressing Enter again to actually run it, so an
  # accidental Enter never runs the wrong command.
  #
  # The equality check (candidate trimmed of its one trailing space vs.
  # BUFFER) matters because the static table's prefix match still matches
  # a subcommand against itself once you've typed it in full — e.g.
  # BUFFER="git push" still shows "push" as the (only) candidate. Without
  # this check, Enter would "accept" a no-op (re-insert the exact same
  # text) instead of running the command, so finishing a known subcommand
  # and pressing Enter would silently need a second Enter to do anything.
  if (( ${#_LUMEN_CANDIDATES} > 0 )) \
     && [[ "${_LUMEN_CANDIDATES[$_LUMEN_INDEX]% }" != "$BUFFER" ]]; then
    _lumen_accept
    return
  fi
  _lumen_clear_display
  if (( $+_LUMEN_ORIG_WIDGET[accept-line] )); then
    _lumen_call_orig_widget accept-line
  else
    zle .accept-line
  fi
}

_lumen_line_init() {
  _lumen_clear_display
  _lumen_call_orig_widget zle-line-init
  _lumen_query_cursor_pos
}

# --- registration --------------------------------------------------------

zle -N _lumen_trigger
zle -N _lumen_accept
zle -N _lumen_next
zle -N _lumen_prev
zle -N _lumen_dismiss
zle -N _lumen_dismiss_escape
# These three (unlike the ones above) are well-known widget names other
# plugins/frameworks may already have bound — go through
# _lumen_wrap_widget so anything already there (Powerlevel10k's
# zle-line-init, etc.) keeps running instead of being silently replaced.
_lumen_wrap_widget forward-char _lumen_forward_char
_lumen_wrap_widget accept-line _lumen_accept_line
_lumen_wrap_widget zle-line-init _lumen_line_init

bindkey "$LUMEN_KEY" _lumen_trigger
bindkey '^I' _lumen_accept  # Tab
# forward-char (not _lumen_forward_char) is the correct widget name
# here: _lumen_wrap_widget above registers our implementation UNDER
# the name "forward-char" itself (zle -N forward-char _lumen_forward_char),
# the same way it takes over accept-line/zle-line-init below — it does not
# also create a separate widget literally named "_lumen_forward_char".
# Binding directly to that nonexistent name is exactly what previously
# made Right-arrow/Ctrl-F fail with "No such widget `_lumen_forward_char'".
bindkey '^[[C' forward-char  # Right arrow, normal cursor-key mode (xterm)
bindkey '^[OC' forward-char  # Right arrow, application cursor-key mode
bindkey '^F' forward-char
# Arrow keys send one of two different escape sequences depending on
# whether the terminal is in normal ("\e[X") or application/DECCKM
# ("\eOX") cursor-key mode — which mode is active isn't under this
# plugin's control (some terminal wrappers/multiplexers switch it, e.g.
# observed with Kiro CLI's own pty layer). Binding only the "\e[X" form
# left "\eOX" silently falling through to zsh's own default
# up/down-line-or-beginning-search — suggestions would still render, but
# the arrow keys wouldn't cycle them at all (just beep, same as normal
# history search beeping with nothing left to search). Bind both forms to
# be correct regardless of which mode the terminal happens to be in.
bindkey '^[[A' _lumen_prev  # Up arrow, normal cursor-key mode
bindkey '^[OA' _lumen_prev  # Up arrow, application cursor-key mode
bindkey '^[[B' _lumen_next  # Down arrow, normal cursor-key mode
bindkey '^[OB' _lumen_next  # Down arrow, application cursor-key mode
bindkey '^G' _lumen_dismiss
# Plain Escape is "undefined-key" (a no-op/beep) by default in zsh's emacs
# keymap — it's otherwise only ever a PREFIX for longer sequences like
# arrow keys (\e[A, \e[B, ...), never bound to a standalone action of its
# own, so this doesn't shadow anything. zle already disambiguates "Escape
# alone" from "the start of a longer \e-prefixed sequence" via
# $KEYTIMEOUT, the same mechanism that lets Alt-key combos coexist with a
# bare Escape binding elsewhere (e.g. vi-mode setups) — a real arrow-key
# press still resolves to its own longer binding, not this one.
#
# Bound to _lumen_dismiss_escape (not the plain _lumen_dismiss
# Ctrl-G uses) so pressing Escape with nothing showing is a silent no-op
# instead of send-break's beep — see that function's comment.
bindkey '^[' _lumen_dismiss_escape

if (( LUMEN_AUTO )); then
  local -a _lumen_watched_widgets
  _lumen_watched_widgets=(
    self-insert backward-delete-char delete-char
    backward-kill-word kill-word kill-line backward-kill-line
    # The physical spacebar is bound to zsh's own `magic-space` widget by
    # default (history "!"-expansion on space), NOT `self-insert` — so
    # without watching it too, pressing space would insert the space
    # (magic-space still runs, chained via _LUMEN_ORIG_WIDGET below)
    # but never re-trigger suggestions, leaving chained follow-ups (e.g.
    # "commit" -> "-m") silent until some other, self-insert-bound key
    # was pressed.
    magic-space
    # Terminal pastes arrive as this one widget (see _lumen_edit_
    # wrapper's bracketed-paste case) rather than a run of self-insert
    # calls — has to be watched separately or a paste leaves whatever was
    # already showing stuck on screen with no further event to clear it.
    bracketed-paste
  )
  local _w
  for _w in $_lumen_watched_widgets; do
    _lumen_wrap_widget $_w _lumen_edit_wrapper
  done
  unset _w _lumen_watched_widgets
fi

# Makes sure the overlay panel doesn't linger on screen once this shell
# session is gone — the normal `exit`/`accept-line` path already hides
# before running the command (see _lumen_accept_line), but that
# doesn't cover Ctrl-D on an empty line or the parent terminal window
# closing (which delivers SIGHUP; zsh's default handling for that still
# runs zshexit, same as a graceful `exit`). Registered via add-zsh-hook
# rather than defining zshexit() directly so this doesn't clobber a
# zshexit function/hook some other plugin or the user's own .zshrc may
# already have.
_lumen_on_shell_exit() {
  (( ${#_LUMEN_CANDIDATES} > 0 )) && _lumen_overlay_hide 1
}
autoload -Uz add-zsh-hook
add-zsh-hook zshexit _lumen_on_shell_exit

# --- update check ---------------------------------------------------------
#
# Same idea as oh-my-zsh's own update nag: on new-shell startup, check
# whether a newer GitHub release exists and, if so, ask once whether to
# update — with "not now" snoozing the ask for a few more terminals rather
# than repeating it every single time. This is the one place this plugin
# ever touches the network (everything else is local-only by design, see
# the file header) — LUMEN_UPDATE_CHECK=0 turns it off entirely.
#
# Only meaningful for a git-clone install (the one the README documents):
# "update" means `git pull` in place, since that's also how the plugin
# file itself got here. State lives next to the existing overlay-toggle
# state file ($HOME/.cache/lumen/), shared across every open terminal, so
# the snooze countdown and the "already checked today" stamp both apply
# globally rather than per-tab.

_LUMEN_UPDATE_DIR=${LUMEN_STATE_FILE:h}
_LUMEN_UPDATE_STAMP_FILE=$_LUMEN_UPDATE_DIR/update_last_check
_LUMEN_UPDATE_LATEST_FILE=$_LUMEN_UPDATE_DIR/update_latest
_LUMEN_UPDATE_SNOOZE_FILE=$_LUMEN_UPDATE_DIR/update_snooze

# True (0) if $1 is a strictly newer "vX.Y.Z"-style tag than $2.
_lumen_version_gt() {
  local -a a b
  a=(${(s:.:)${1#v}})
  b=(${(s:.:)${2#v}})
  local i
  for i in 1 2 3; do
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
  done
  return 1
}

# The tag reachable from the currently checked-out commit — i.e. "what
# `git pull` would move you off of," not necessarily the latest tag that
# exists anywhere in the repo (e.g. on a branch other than the one
# actually checked out).
_lumen_local_version() {
  git -C "$_LUMEN_REPO_ROOT" describe --tags --abbrev=0 2>/dev/null
}

# Fires at most once every $LUMEN_UPDATE_CHECK_DAYS: shells out to curl in
# a disowned background job (`&!`) so a slow/offline network never delays
# the prompt this file exists to show, and writes the result for the
# *next* shell startup to pick up — this run's prompt (if any) only ever
# reflects what a previous check already found. If the background job
# gets killed mid-request (e.g. the terminal window closes before curl
# returns), the stamp file is simply never written, so the next shell to
# start just retries — no separate failure handling needed.
_lumen_update_fetch_async() {
  command -v curl >/dev/null 2>&1 || return
  local now=$(date +%s) last=0
  [[ -f $_LUMEN_UPDATE_STAMP_FILE ]] && last=$(<$_LUMEN_UPDATE_STAMP_FILE)
  (( now - last < LUMEN_UPDATE_CHECK_DAYS * 86400 )) && return
  (
    local tag
    tag=$(curl -fsSL --max-time 5 \
      "https://api.github.com/repos/$LUMEN_UPDATE_REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    mkdir -p "$_LUMEN_UPDATE_DIR"
    echo "$now" > "$_LUMEN_UPDATE_STAMP_FILE"
    [[ -n $tag ]] && echo "$tag" > "$_LUMEN_UPDATE_LATEST_FILE"
  ) &!
}

# `git pull` in place, then rebuild+relaunch the menu bar app — mirrors
# how the plugin itself and the app both got installed per the README
# (git clone + ./build.sh), so updating uses the same two steps by hand.
_lumen_update_perform() {
  print -P "%F{cyan}Updating Lumen…%f"
  # A dirty working tree almost certainly means someone is actively
  # developing on this checkout (this repo itself, for instance) —
  # `git pull` there risks clobbering or conflicting with uncommitted
  # work, so bail and let them update by hand instead of guessing.
  if [[ -n $(git -C "$_LUMEN_REPO_ROOT" status --porcelain 2>/dev/null) ]]; then
    print -P "%F{yellow}$_LUMEN_REPO_ROOT has local changes — update manually (git pull) to avoid clobbering them.%f"
    return 1
  fi
  if ! git -C "$_LUMEN_REPO_ROOT" pull --ff-only; then
    print -P "%F{red}git pull failed — update manually.%f"
    return 1
  fi
  # Clear cached state so the next shell compares against what we just
  # pulled instead of immediately re-flagging the version we're leaving.
  rm -f "$_LUMEN_UPDATE_SNOOZE_FILE" "$_LUMEN_UPDATE_LATEST_FILE"
  if [[ -x "$_LUMEN_REPO_ROOT/Lumen/build.sh" ]]; then
    print -P "%F{cyan}Rebuilding the menu bar app…%f"
    if ( cd "$_LUMEN_REPO_ROOT/Lumen" && ./build.sh ); then
      pkill -x Lumen 2>/dev/null
      open "$_LUMEN_REPO_ROOT/Lumen/Lumen.app"
      print -P "%F{green}Updated to $(_lumen_local_version) and relaunched Lumen.app.%f"
    else
      print -P "%F{yellow}git pull succeeded but the rebuild failed — run Lumen/build.sh manually.%f"
    fi
  fi
}

# Synchronous, but only ever runs against an already-cached result (see
# _lumen_update_fetch_async above) — never itself waits on the network.
_lumen_update_maybe_prompt() {
  [[ -f $_LUMEN_UPDATE_LATEST_FILE ]] || return
  local latest=$(<$_LUMEN_UPDATE_LATEST_FILE)
  local local_ver=$(_lumen_local_version)
  [[ -n $latest && -n $local_ver ]] || return
  _lumen_version_gt "$latest" "$local_ver" || return

  if [[ -f $_LUMEN_UPDATE_SNOOZE_FILE ]]; then
    local -a snooze=(${(s: :)"$(<$_LUMEN_UPDATE_SNOOZE_FILE)"})
    local snoozed_ver=${snooze[1]:-} snoozed_left=${snooze[2]:-0}
    if [[ $snoozed_ver == $latest ]] && (( snoozed_left > 0 )); then
      echo "$latest $(( snoozed_left - 1 ))" > $_LUMEN_UPDATE_SNOOZE_FILE
      return
    fi
  fi

  print -P "%F{cyan}✨ Lumen %F{green}$latest%f is available %F{8}(you have $local_ver)%f"
  local reply
  if read -q "reply?Update now? [y/N] "; then
    print
    _lumen_update_perform
  else
    print
    echo "$latest $LUMEN_UPDATE_SNOOZE_SESSIONS" > $_LUMEN_UPDATE_SNOOZE_FILE
    print -P "%F{8}Not now — I'll ask again in $LUMEN_UPDATE_SNOOZE_SESSIONS new terminals (or run 'lumen-update' anytime).%f"
  fi
}

# Manual override — force an update right now regardless of the cached
# latest-version check or snooze state, for anyone who doesn't want to
# wait for the prompt.
lumen-update() { _lumen_update_perform }

# Set unconditionally (cheap, no network) so `lumen-update` still works as
# a manual override even with LUMEN_UPDATE_CHECK=0 — that variable only
# gates the automatic background check + startup prompt below.
_LUMEN_REPO_ROOT=${0:A:h:h:h}

if (( LUMEN_UPDATE_CHECK )) && [[ -d $_LUMEN_REPO_ROOT/.git ]]; then
  _lumen_update_fetch_async
  _lumen_update_maybe_prompt
fi
