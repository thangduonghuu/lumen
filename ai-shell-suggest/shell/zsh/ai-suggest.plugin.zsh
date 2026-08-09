#!/usr/bin/env zsh
# ai-suggest.plugin.zsh
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
# $AI_SUGGEST_KEY) asks immediately for the current buffer.
#
# This shell side never draws anything itself and has no idea whether the
# companion app successfully manages to show anything — it only ever sends
# "here's what to show and where the cursor is" (_ai_suggest_overlay_show)
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
#   Ctrl-Space (or $AI_SUGGEST_KEY)     ask immediately for the current buffer
#   Up / Down                           cycle candidates (falls back to
#                                        normal history search when no
#                                        suggestion is shown)
#   Tab / Right-arrow (at end of line)  accept the shown suggestion
#   Ctrl-G                              dismiss the current suggestion
#
# Config (set before sourcing this file):
#   AI_SUGGEST_KEY            manual trigger keybinding (default: '^@', i.e. Ctrl-Space)
#   AI_SUGGEST_AUTO           1 = automatic as-you-type suggestions (default),
#                             0 = Ctrl-Space-only
#   AI_SUGGEST_OVERLAY        1 = show suggestions via the native floating
#                             panel (Lumen companion app,
#                             default). 0 = don't show suggestions at all —
#                             there is no other rendering path; if the
#                             companion app isn't running, permission
#                             hasn't been granted, or the frontmost
#                             terminal can't be positioned against, nothing
#                             is shown for that keystroke (fails silently,
#                             never blocks typing).

[[ -o interactive ]] || return
[[ -n $ZSH_VERSION ]] || return

: ${AI_SUGGEST_KEY:='^@'}
: ${AI_SUGGEST_AUTO:=1}
: ${AI_SUGGEST_STATE_FILE:=$HOME/.cache/ai-suggest/enabled}
: ${AI_SUGGEST_OVERLAY:=1}
: ${AI_SUGGEST_OVERLAY_SOCK:=$HOME/.cache/ai-suggest/overlay.sock}

# Runtime on/off switch for AUTOMATIC suggestions, toggled from the
# Lumen app (a separate menu-bar icon/toggle — see
# Lumen/), not from this shell. The two are different
# processes with no shared memory, so a file is the simplest thing that
# works across both; reading one small file per keystroke is cheap enough
# not to matter. Missing file = enabled (so it works before the menu bar
# app has ever run). Deliberately does NOT gate the manual trigger
# ($AI_SUGGEST_KEY): the point of the toggle is to let automatic
# suggestions default to paused rather than always firing, not to block an
# explicit ask.
_ai_suggest_auto_enabled() {
  [[ -f $AI_SUGGEST_STATE_FILE ]] || return 0
  local content
  content=$(<$AI_SUGGEST_STATE_FILE)
  [[ $content != "0" ]]
}

# Widget names we've overridden that already had a user-defined widget
# bound to them before we got to them (e.g. Powerlevel10k's own
# `zle-line-init`, zsh's `url-quote-magic` on `self-insert`) — maps the
# original widget name to the alias we copied it under, so our wrappers can
# chain into it. Populated by _ai_suggest_wrap_widget at registration time.
typeset -gA _AI_SUGGEST_ORIG_WIDGET=()

# Registers $2 as the implementation for zle widget $1, preserving any
# pre-existing USER-DEFINED widget under that name first (`zle -A`, which
# copies rather than moves — the original keeps working standalone too) so
# other plugins that already hooked the same widget keep running instead of
# being silently replaced. Builtin (non-user) widgets don't need
# preserving — `zle .$WIDGET` already reaches those directly, no chaining
# required.
_ai_suggest_wrap_widget() {
  local widget=$1 impl=$2
  local current=${widgets[$widget]-}
  # Only preserve a widget that belongs to SOMEONE ELSE. If this plugin
  # gets sourced twice in the same shell (re-sourced manually while already
  # loaded via .zshrc, common when testing), $current on the second pass is
  # already one of our own wrappers from the first pass — aliasing that as
  # "the original" would make our own wrapper call itself, recursing
  # forever on the very next keystroke. Excluding our own `_ai_suggest_*`
  # functions here means a re-source just re-registers cleanly instead.
  if [[ $current == user:* && $current != user:_ai_suggest_* ]]; then
    local orig="_ai_suggest_orig_${widget//[^a-zA-Z0-9_]/_}"
    zle -A $widget $orig
    _AI_SUGGEST_ORIG_WIDGET[$widget]=$orig
  fi
  zle -N $widget $impl
}

# Runs whatever _ai_suggest_wrap_widget preserved for $1, if anything —
# shared by every wrapper below so "chain into the widget we replaced" is
# one call instead of the same guarded lookup repeated in each of them.
_ai_suggest_call_orig_widget() {
  (( $+_AI_SUGGEST_ORIG_WIDGET[$1] )) && zle ${_AI_SUGGEST_ORIG_WIDGET[$1]}
}

typeset -ga _AI_SUGGEST_CANDIDATES=()
typeset -ga _AI_SUGGEST_DESCRIPTIONS=()
typeset -ga _AI_SUGGEST_HINTS=()
# Explicit display text per row, decoupled from the insertable command in
# _AI_SUGGEST_CANDIDATES — e.g. for "git status " the insertable text
# includes the tool name (needed on accept), but the row should just read
# "status" since "git" is already visible in what you typed. Empty means
# "no override, fall back to the full candidate text" (see
# _ai_suggest_overlay_show); every current matcher sets this explicitly, but
# the fallback stays as a safety net for anything that doesn't.
typeset -ga _AI_SUGGEST_LABELS=()
# Per-row icon kind — "dir" (cd match) or "branch" (git branch match) from
# their respective matchers, or one of _ai_suggest_tool_icon_kind's per-tool
# identifiers ("git"/"docker"/"kubectl"/"aws"/"kafka"/...) for everything
# from the static/nested subcommand tables — parallel to
# _AI_SUGGEST_CANDIDATES, sent to the overlay companion app so it can draw a
# distinct glyph+color per row (see CandidateIcon in OverlayPanel.swift)
# instead of one generic badge for everything. "cmd" is the fallback for
# any tool without its own glyph yet.
typeset -ga _AI_SUGGEST_ICONS=()
typeset -gi _AI_SUGGEST_INDEX=0
# Per-matcher cap on how many candidates get built. The native overlay
# (OverlayContentView in OverlayPanel.swift) scrolls past whatever doesn't
# fit on screen, so this just bounds how much work each matcher's loop does
# and how far Down-arrow cycling goes — not a display constraint anymore.
typeset -gi _AI_SUGGEST_MAX_CANDIDATES=50

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
typeset -ga _AI_SUGGEST_GIT_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_KUBECTL_SUBCMDS=(
  $'get\t<resource>\tDisplay one or many resources'
  $'describe\t<resource> <name>\tShow detailed state of a resource'
  $'logs\t<pod>\tPrint logs for a container in a pod'
  $'apply\t\tApply a configuration to a resource'
  $'exec\t\tExecute a command in a container'
  $'delete\t<resource> <name>\tDelete resources'
  $'create\t\tCreate a resource from a file or stdin'
  $'edit\t<resource> <name>\tEdit a resource on the server'
  $'rollout\t[status|undo|restart]\tManage the rollout of a resource'
  $'scale\t<resource>\tScale a resource'
  $'port-forward\t<pod> <ports>\tForward local ports to a pod'
  $'config\t[get-contexts|use-context]\tModify kubeconfig files'
  $'top\t[pod|node]\tDisplay resource (CPU/memory) usage'
  $'cp\t<src> <dst>\tCopy files to/from a container'
  $'label\t<resource> <name> <key>=<val>\tUpdate labels on a resource'
  $'run\t<name> --image=<image>\tRun a particular image on the cluster'
  $'expose\t<resource> <name>\tExpose a resource as a new Service'
  $'context\t[current|use]\tView or switch kubeconfig contexts (via config)'
  $'namespace\t<name>\tSwitch active namespace (via config set-context)'
)

typeset -ga _AI_SUGGEST_NPM_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_DOCKER_SUBCMDS=(
  $'ps\t\tList containers'
  $'images\t\tList images'
  $'run\t<image>\tRun a command in a new container'
  $'build\t.\tBuild an image from a Dockerfile'
  $'exec\t<container>\tRun a command in a running container'
  $'logs\t<container>\tFetch the logs of a container'
  $'stop\t<container>\tStop a running container'
  $'start\t<container>\tStart a stopped container'
  $'rm\t<container>\tRemove a container'
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
# up by _ai_suggest_nested_match) for the operations themselves.
typeset -ga _AI_SUGGEST_AWS_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_TERRAFORM_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_HELM_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_GH_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_YARN_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_PNPM_SUBCMDS=(
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

# GitLab's counterpart to gh — same shape, but "mr" (merge request) where
# GitHub says "pr".
typeset -ga _AI_SUGGEST_GLAB_SUBCMDS=(
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
# table lists resource groups; see _AI_SUGGEST_GCLOUD_COMPUTE_SUBCMDS/
# _GCLOUD_CONTAINER_SUBCMDS below (picked up by _ai_suggest_nested_match)
# for the commands themselves.
typeset -ga _AI_SUGGEST_GCLOUD_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_AZ_SUBCMDS=(
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

# Apache Kafka's admin/producer/consumer scripts are separate binaries
# rather than one "kafka" tool with subcommands, and each takes flags
# rather than a subcommand as its first argument — but the static-match
# machinery only cares that "first word after the tool name" is a
# prefix-matchable string, and a flag like "--list" fits that just as well
# as a subcommand name does.
typeset -ga _AI_SUGGEST_KAFKA_TOPICS_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_KAFKA_CONSOLE_PRODUCER_SUBCMDS=(
  $'--topic\t<name>\tTopic to produce to'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--property\t<key=value>\tSet a producer property (e.g. parse.key=true)'
)

typeset -ga _AI_SUGGEST_KAFKA_CONSOLE_CONSUMER_SUBCMDS=(
  $'--topic\t<name>\tTopic to consume from'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--from-beginning\t\tConsume from the start of the topic'
  $'--group\t<group-id>\tConsumer group to join'
  $'--partition\t<n>\tConsume only from a specific partition'
)

typeset -ga _AI_SUGGEST_KAFKA_CONSUMER_GROUPS_SUBCMDS=(
  $'--list\t\tList all consumer groups'
  $'--describe\t\tDescribe a consumer group (use with --group)'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--reset-offsets\t\tReset consumer group offsets (use with --group/--topic)'
  $'--delete\t\tDelete a consumer group (use with --group)'
  $'--group\t<id>\tConsumer group to target'
  $'--topic\t<name>\tTopic name, paired with --reset-offsets'
)

typeset -ga _AI_SUGGEST_RABBITMQCTL_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_CARGO_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_GO_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_PIP_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_POETRY_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_MVN_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_GRADLE_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_DOTNET_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_BUNDLE_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_GEM_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_BREW_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_VAGRANT_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_PULUMI_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_HEROKU_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_VERCEL_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_NETLIFY_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_FIREBASE_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_FLYCTL_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_DOCTL_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_TURBO_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_NX_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_TMUX_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_TMUX_NEW_SESSION_FLAGS=(
  $'-s\t<name>\tName for the new session'
)
typeset -ga _AI_SUGGEST_TMUX_ATTACH_SESSION_FLAGS=(
  $'-t\t<name>\tSession to attach to'
)
typeset -ga _AI_SUGGEST_TMUX_KILL_SESSION_FLAGS=(
  $'-t\t<name>\tSession to destroy'
)
typeset -ga _AI_SUGGEST_TMUX_SPLIT_WINDOW_FLAGS=(
  $'-h\t\tSplit horizontally (side by side)'
  $'-v\t\tSplit vertically (stacked)'
)
typeset -ga _AI_SUGGEST_TMUX_NEW_WINDOW_FLAGS=(
  $'-n\t<name>\tName for the new window'
)
typeset -ga _AI_SUGGEST_TMUX_KILL_WINDOW_FLAGS=(
  $'-t\t<name>\tWindow to destroy'
)

typeset -ga _AI_SUGGEST_SYSTEMCTL_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_NVM_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_PYENV_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_RBENV_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_NPX_SUBCMDS=(
  $'--yes\t<package>\tRun a package without prompting to install it'
  $'--no-install\t<package>\tRun a package only if already installed'
  $'--package\t<package>\tSpecify the package to run a binary from'
  $'-c\t<command>\tExecute a command with the local node_modules/.bin on PATH'
)

typeset -ga _AI_SUGGEST_MINIKUBE_SUBCMDS=(
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
# hand-maintained dispatch table — see _ai_suggest_nested_match, which builds
# the variable name "_AI_SUGGEST_<TOOL>_<SUBCMD...>_SUBCMDS" (or "_FLAGS" if
# the word being completed starts with "-") from the command path so far and
# looks it up indirectly. Same hand-picked-common-case philosophy as the
# top-level tables: not exhaustive, just the subcommands/flags someone
# actually reaches for.

typeset -ga _AI_SUGGEST_DOCKER_IMAGE_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_DOCKER_CONTAINER_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_DOCKER_NETWORK_SUBCMDS=(
  $'ls\t\tList networks'
  $'create\t<name>\tCreate a network'
  $'rm\t<network>\tRemove a network'
  $'inspect\t<network>\tReturn low-level info on a network'
  $'connect\t<network> <container>\tConnect a container to a network'
  $'disconnect\t<network> <container>\tDisconnect a container from a network'
  $'prune\t\tRemove unused networks'
)

typeset -ga _AI_SUGGEST_DOCKER_VOLUME_SUBCMDS=(
  $'ls\t\tList volumes'
  $'create\t<name>\tCreate a volume'
  $'rm\t<volume>\tRemove a volume'
  $'inspect\t<volume>\tReturn low-level info on a volume'
  $'prune\t\tRemove unused volumes'
)

typeset -ga _AI_SUGGEST_DOCKER_SYSTEM_SUBCMDS=(
  $'df\t\tShow docker disk usage'
  $'prune\t\tRemove unused data'
  $'info\t\tDisplay system-wide information'
  $'events\t\tGet real time events from the server'
)

typeset -ga _AI_SUGGEST_DOCKER_COMPOSE_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_DOCKER_PS_FLAGS=(
  $'-a\t\tShow all containers (default shows just running)'
  $'-q\t\tOnly display container IDs'
  $'--filter\t<expr>\tFilter output based on conditions'
  $'--format\t<template>\tFormat output using a Go template'
)

typeset -ga _AI_SUGGEST_DOCKER_IMAGES_FLAGS=(
  $'-a\t\tShow all images (default hides intermediate images)'
  $'-q\t\tOnly display image IDs'
  $'--filter\t<expr>\tFilter output based on conditions'
)

typeset -ga _AI_SUGGEST_DOCKER_IMAGE_LS_FLAGS=("${_AI_SUGGEST_DOCKER_IMAGES_FLAGS[@]}")

typeset -ga _AI_SUGGEST_DOCKER_RUN_FLAGS=(
  $'-d\t\tRun container in the background'
  $'-it\t\tInteractive session with a tty attached'
  $'--rm\t\tAutomatically remove the container on exit'
  $'-p\t<host>:<container>\tPublish a container port to the host'
  $'-v\t<host>:<container>\tBind mount a volume'
  $'--name\t<name>\tAssign a name to the container'
  $'-e\t<key>=<value>\tSet an environment variable'
)

typeset -ga _AI_SUGGEST_DOCKER_EXEC_FLAGS=(
  $'-it\t\tInteractive session with a tty attached'
  $'-d\t\tRun the command in the background'
  $'-u\t<user>\tRun as a specific user'
  $'-w\t<dir>\tWorking directory inside the container'
)

typeset -ga _AI_SUGGEST_DOCKER_LOGS_FLAGS=(
  $'-f\t\tFollow log output'
  $'--tail\t<n>\tShow only the last n lines'
  $'-t\t\tShow timestamps'
)

typeset -ga _AI_SUGGEST_DOCKER_BUILD_FLAGS=(
  $'-t\t<tag>\tTag the built image (e.g. name:latest)'
  $'-f\t<dockerfile>\tUse an alternate Dockerfile'
  $'--no-cache\t\tDo not use cache when building'
)
typeset -ga _AI_SUGGEST_DOCKER_IMAGE_BUILD_FLAGS=("${_AI_SUGGEST_DOCKER_BUILD_FLAGS[@]}")

typeset -ga _AI_SUGGEST_DOCKER_IMAGE_SAVE_FLAGS=(
  $'-o\t<file>\tWrite the image to a file instead of stdout'
)

typeset -ga _AI_SUGGEST_DOCKER_IMAGE_LOAD_FLAGS=(
  $'-i\t<file>\tRead the image from a file instead of stdin'
)

typeset -ga _AI_SUGGEST_DOCKER_CONTAINER_EXEC_FLAGS=("${_AI_SUGGEST_DOCKER_EXEC_FLAGS[@]}")
typeset -ga _AI_SUGGEST_DOCKER_CONTAINER_LS_FLAGS=("${_AI_SUGGEST_DOCKER_PS_FLAGS[@]}")

typeset -ga _AI_SUGGEST_DOCKER_IMAGE_PRUNE_FLAGS=(
  $'-a\t\tRemove all unused images, not just dangling ones'
)
typeset -ga _AI_SUGGEST_DOCKER_SYSTEM_PRUNE_FLAGS=(
  $'-a\t\tRemove all unused images too, not just dangling ones'
)
typeset -ga _AI_SUGGEST_DOCKER_COMPOSE_UP_FLAGS=(
  $'-d\t\tRun containers in the background'
)

typeset -ga _AI_SUGGEST_GIT_STASH_SUBCMDS=(
  $'push\t\tStash changes'
  $'pop\t\tApply and remove the most recent stash'
  $'apply\t[stash]\tApply a stash without removing it'
  $'list\t\tList stashes'
  $'show\t[stash]\tShow the changes in a stash'
  $'drop\t[stash]\tRemove a stash'
  $'clear\t\tRemove all stashes'
)

typeset -ga _AI_SUGGEST_GIT_STASH_PUSH_FLAGS=(
  $'-m\t<message>\tLabel the stash with a message'
)

typeset -ga _AI_SUGGEST_GIT_REMOTE_SUBCMDS=(
  $'-v\t\tShow remote URLs'
  $'add\t<name> <url>\tAdd a remote'
  $'remove\t<name>\tRemove a remote'
  $'rename\t<old> <new>\tRename a remote'
  $'set-url\t<name> <url>\tChange a remote'"'"'s URL'
  $'show\t<name>\tShow information about a remote'
  $'prune\t<name>\tRemove stale remote-tracking branches'
)

typeset -ga _AI_SUGGEST_GIT_REMOTE_FLAGS=(
  $'-v\t\tShow remote URLs'
)

typeset -ga _AI_SUGGEST_GIT_LOG_FLAGS=(
  $'--oneline\t\tOne line per commit'
  $'--graph\t\tDraw a text-based commit graph'
  $'-p\t\tShow the full diff for each commit'
  $'--stat\t\tShow a diffstat for each commit'
  $'-n\t<count>\tLimit the number of commits'
)

typeset -ga _AI_SUGGEST_GIT_BRANCH_FLAGS=(
  $'-a\t\tList both local and remote branches'
  $'-d\t<branch>\tDelete a branch'
  $'-D\t<branch>\tForce-delete a branch'
  $'-m\t<old> <new>\tRename a branch'
  $'-v\t\tShow last commit on each branch'
)

typeset -ga _AI_SUGGEST_GIT_CHECKOUT_FLAGS=(
  $'-b\t<branch>\tCreate and switch to a new branch'
  $'--track\t<remote-branch>\tCreate a tracking branch'
  $'-f\t\tForce checkout, discarding local changes'
)

typeset -ga _AI_SUGGEST_GIT_DIFF_FLAGS=(
  $'--stat\t\tShow a diffstat instead of the full diff'
  $'--cached\t\tShow staged changes'
  $'-p\t\tGenerate output in patch format (default)'
)

# Picked up by _ai_suggest_nested_match once BUFFER is "git commit " —
# same leaf-command-falls-back-to-its-FLAGS-table path already used by
# docker images/ps/run, git log/branch/checkout/diff, kubectl get/exec (see
# that function's comment on the empty-partial fallback). Moved out of
# _AI_SUGGEST_GIT_SUBCMDS's own hint text (used to be "commit -m <message>"
# shown together on one row) so "-m" is its own follow-up suggestion after
# "commit" is picked, instead of looking like part of the subcommand name.
typeset -ga _AI_SUGGEST_GIT_COMMIT_FLAGS=(
  $'-m\t<message>\tRecord changes with the given commit message'
)

typeset -ga _AI_SUGGEST_GIT_CLEAN_FLAGS=(
  $'-f\t\tForce the removal'
  $'-d\t\tAlso remove untracked directories'
)

typeset -ga _AI_SUGGEST_NPM_CACHE_SUBCMDS=(
  $'clean\t\tClean the npm cache'
  $'verify\t\tVerify the npm cache'
  $'add\t<package>\tAdd a package to the cache'
  $'ls\t\tList the contents of the cache'
)

typeset -ga _AI_SUGGEST_NPM_INSTALL_FLAGS=(
  $'--save-dev\t\tSave to devDependencies'
  $'--save-exact\t\tPin the exact installed version'
  $'-g\t\tInstall globally'
  $'--legacy-peer-deps\t\tIgnore peer dependency conflicts'
)

typeset -ga _AI_SUGGEST_KUBECTL_CONFIG_SUBCMDS=(
  $'get-contexts\t\tList the available contexts'
  $'use-context\t<name>\tSet the current context'
  $'current-context\t\tDisplay the current context'
  $'set-context\t<name>\tSet a context entry'
  $'view\t\tDisplay the merged kubeconfig'
  $'delete-context\t<name>\tDelete a context'
)

typeset -ga _AI_SUGGEST_KUBECTL_ROLLOUT_SUBCMDS=(
  $'status\t<resource>\tShow the status of a rollout'
  $'undo\t<resource>\tRoll back to a previous revision'
  $'restart\t<resource>\tRestart a resource'
  $'history\t<resource>\tShow rollout history'
  $'pause\t<resource>\tMark a rollout as paused'
  $'resume\t<resource>\tResume a paused rollout'
)

typeset -ga _AI_SUGGEST_KUBECTL_GET_FLAGS=(
  $'-o\t<format>\tOutput format (json|yaml|wide|...)'
  $'-n\t<namespace>\tNamespace to query'
  $'--all-namespaces\t\tList across all namespaces'
  $'-w\t\tWatch for changes'
)

typeset -ga _AI_SUGGEST_KUBECTL_EXEC_FLAGS=(
  $'-it\t\tInteractive session with a tty attached'
  $'-n\t<namespace>\tNamespace of the target pod'
)

typeset -ga _AI_SUGGEST_KUBECTL_APPLY_FLAGS=(
  $'-f\t<file>\tApply a configuration from a file'
)

typeset -ga _AI_SUGGEST_KUBECTL_CREATE_FLAGS=(
  $'-f\t<file>\tCreate a resource from a file or stdin'
)

typeset -ga _AI_SUGGEST_KUBECTL_SCALE_FLAGS=(
  $'--replicas\t<n>\tSet the desired number of replicas'
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
typeset -ga _AI_SUGGEST_GENERIC_FLAGS=(
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

typeset -ga _AI_SUGGEST_AWS_S3_SUBCMDS=(
  $'ls\t[s3://bucket[/prefix]]\tList buckets or objects'
  $'cp\t<src> <dst>\tCopy files to/from S3'
  $'sync\t<src> <dst>\tSync a directory tree with S3'
  $'mv\t<src> <dst>\tMove files to/from S3'
  $'rm\t<s3-path>\tRemove an object'
  $'mb\t<s3://bucket>\tCreate a bucket'
  $'rb\t<s3://bucket>\tRemove a bucket'
  $'presign\t<s3-path>\tGenerate a presigned URL'
)

typeset -ga _AI_SUGGEST_AWS_EC2_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_AWS_LAMBDA_SUBCMDS=(
  $'list-functions\t\tList Lambda functions'
  $'invoke\t\tInvoke a function'
  $'update-function-code\t\tUpdate function code'
  $'get-function\t\tGet function configuration'
  $'create-function\t\tCreate a function'
  $'delete-function\t\tDelete a function'
  $'list-layers\t\tList Lambda layers'
)

typeset -ga _AI_SUGGEST_AWS_IAM_SUBCMDS=(
  $'list-users\t\tList IAM users'
  $'list-roles\t\tList IAM roles'
  $'get-user\t\tGet the current or named IAM user'
  $'create-role\t\tCreate a role'
  $'attach-role-policy\t\tAttach a policy to a role'
  $'list-attached-role-policies\t\tList policies attached to a role'
  $'create-access-key\t\tCreate an access key'
)

typeset -ga _AI_SUGGEST_AWS_LOGS_SUBCMDS=(
  $'tail\t<log-group>\tTail a log group in real time'
  $'describe-log-groups\t\tList log groups'
  $'describe-log-streams\t\tList log streams'
  $'get-log-events\t\tGet log events'
  $'filter-log-events\t\tFilter log events by pattern'
)

typeset -ga _AI_SUGGEST_AWS_STS_SUBCMDS=(
  $'get-caller-identity\t\tShow the current IAM identity'
  $'assume-role\t\tAssume an IAM role'
)

typeset -ga _AI_SUGGEST_AWS_CLOUDFORMATION_SUBCMDS=(
  $'deploy\t\tDeploy a stack'
  $'describe-stacks\t\tDescribe stacks'
  $'create-stack\t\tCreate a stack'
  $'update-stack\t\tUpdate a stack'
  $'delete-stack\t\tDelete a stack'
  $'list-stacks\t\tList stacks'
  $'validate-template\t\tValidate a template'
)

typeset -ga _AI_SUGGEST_AWS_ECR_SUBCMDS=(
  $'get-login-password\t\tGet a password to authenticate to ECR'
  $'describe-repositories\t\tDescribe ECR repositories'
  $'create-repository\t\tCreate a repository'
  $'list-images\t\tList images in a repository'
)

typeset -ga _AI_SUGGEST_AWS_ECS_SUBCMDS=(
  $'list-clusters\t\tList ECS clusters'
  $'list-services\t\tList services in a cluster'
  $'list-tasks\t\tList tasks in a cluster'
  $'describe-services\t\tDescribe services'
  $'update-service\t\tUpdate a service'
  $'run-task\t\tRun a one-off task'
)

typeset -ga _AI_SUGGEST_AWS_EKS_SUBCMDS=(
  $'list-clusters\t\tList EKS clusters'
  $'describe-cluster\t\tDescribe a cluster'
  $'update-kubeconfig\t\tUpdate local kubeconfig for a cluster'
  $'create-cluster\t\tCreate a cluster'
)

typeset -ga _AI_SUGGEST_AWS_SSM_SUBCMDS=(
  $'start-session\t\tStart an interactive session on an instance'
  $'get-parameter\t\tGet a parameter value'
  $'put-parameter\t\tCreate or update a parameter'
  $'describe-parameters\t\tList parameters'
  $'send-command\t\tRun a command on managed instances'
)

# Follow-up flags for the AWS_*_SUBCMDS operations above — picked up by
# _ai_suggest_nested_match once BUFFER is e.g. "aws ec2 start-instances "
# (same leaf-command-falls-back-to-its-FLAGS-table path as git commit/docker
# images; see that function's comment). Split out of each operation's own
# hint text so a required flag shows as its own follow-up suggestion
# instead of being pre-glued onto the operation name.
typeset -ga _AI_SUGGEST_AWS_EC2_START_INSTANCES_FLAGS=(
  $'--instance-ids\t<id>\tInstance ID(s) to start'
)
typeset -ga _AI_SUGGEST_AWS_EC2_STOP_INSTANCES_FLAGS=(
  $'--instance-ids\t<id>\tInstance ID(s) to stop'
)
typeset -ga _AI_SUGGEST_AWS_EC2_TERMINATE_INSTANCES_FLAGS=(
  $'--instance-ids\t<id>\tInstance ID(s) to terminate'
)
typeset -ga _AI_SUGGEST_AWS_EC2_RUN_INSTANCES_FLAGS=(
  $'--image-id\t<ami>\tAMI to launch instances from'
)
typeset -ga _AI_SUGGEST_AWS_EC2_CREATE_TAGS_FLAGS=(
  $'--resources\t<id>\tResource(s) to tag'
  $'--tags\t<tags>\tTags to apply, e.g. Key=Name,Value=foo'
)

typeset -ga _AI_SUGGEST_AWS_LAMBDA_INVOKE_FLAGS=(
  $'--function-name\t<name>\tFunction to invoke (followed by an output file)'
)
typeset -ga _AI_SUGGEST_AWS_LAMBDA_UPDATE_FUNCTION_CODE_FLAGS=(
  $'--function-name\t<name>\tFunction to update'
)
typeset -ga _AI_SUGGEST_AWS_LAMBDA_GET_FUNCTION_FLAGS=(
  $'--function-name\t<name>\tFunction to look up'
)
typeset -ga _AI_SUGGEST_AWS_LAMBDA_CREATE_FUNCTION_FLAGS=(
  $'--function-name\t<name>\tName for the new function'
)
typeset -ga _AI_SUGGEST_AWS_LAMBDA_DELETE_FUNCTION_FLAGS=(
  $'--function-name\t<name>\tFunction to delete'
)

typeset -ga _AI_SUGGEST_AWS_IAM_GET_USER_FLAGS=(
  $'--user-name\t<name>\tUser to look up (omit for the current user)'
)
typeset -ga _AI_SUGGEST_AWS_IAM_CREATE_ROLE_FLAGS=(
  $'--role-name\t<name>\tName for the new role'
)
typeset -ga _AI_SUGGEST_AWS_IAM_ATTACH_ROLE_POLICY_FLAGS=(
  $'--role-name\t<name>\tRole to attach the policy to'
  $'--policy-arn\t<arn>\tARN of the policy to attach'
)
typeset -ga _AI_SUGGEST_AWS_IAM_LIST_ATTACHED_ROLE_POLICIES_FLAGS=(
  $'--role-name\t<name>\tRole to list policies for'
)
typeset -ga _AI_SUGGEST_AWS_IAM_CREATE_ACCESS_KEY_FLAGS=(
  $'--user-name\t<name>\tUser to create the key for'
)

typeset -ga _AI_SUGGEST_AWS_LOGS_DESCRIBE_LOG_STREAMS_FLAGS=(
  $'--log-group-name\t<name>\tLog group to list streams for'
)
typeset -ga _AI_SUGGEST_AWS_LOGS_GET_LOG_EVENTS_FLAGS=(
  $'--log-group-name\t<name>\tLog group to read from'
  $'--log-stream-name\t<stream>\tLog stream to read from'
)
typeset -ga _AI_SUGGEST_AWS_LOGS_FILTER_LOG_EVENTS_FLAGS=(
  $'--log-group-name\t<name>\tLog group to search'
)

typeset -ga _AI_SUGGEST_AWS_STS_ASSUME_ROLE_FLAGS=(
  $'--role-arn\t<arn>\tARN of the role to assume'
  $'--role-session-name\t<name>\tIdentifier for the assumed-role session'
)

typeset -ga _AI_SUGGEST_AWS_CLOUDFORMATION_DEPLOY_FLAGS=(
  $'--template-file\t<file>\tLocal template file to deploy'
  $'--stack-name\t<name>\tStack to create or update'
)
typeset -ga _AI_SUGGEST_AWS_CLOUDFORMATION_CREATE_STACK_FLAGS=(
  $'--stack-name\t<name>\tName for the new stack'
  $'--template-body\t<file>\tTemplate file for the stack'
)
typeset -ga _AI_SUGGEST_AWS_CLOUDFORMATION_UPDATE_STACK_FLAGS=(
  $'--stack-name\t<name>\tStack to update'
)
typeset -ga _AI_SUGGEST_AWS_CLOUDFORMATION_DELETE_STACK_FLAGS=(
  $'--stack-name\t<name>\tStack to delete'
)
typeset -ga _AI_SUGGEST_AWS_CLOUDFORMATION_VALIDATE_TEMPLATE_FLAGS=(
  $'--template-body\t<file>\tTemplate file to validate'
)

typeset -ga _AI_SUGGEST_AWS_ECR_CREATE_REPOSITORY_FLAGS=(
  $'--repository-name\t<name>\tName for the new repository'
)
typeset -ga _AI_SUGGEST_AWS_ECR_LIST_IMAGES_FLAGS=(
  $'--repository-name\t<name>\tRepository to list images in'
)

typeset -ga _AI_SUGGEST_AWS_ECS_LIST_SERVICES_FLAGS=(
  $'--cluster\t<cluster>\tCluster to list services in'
)
typeset -ga _AI_SUGGEST_AWS_ECS_LIST_TASKS_FLAGS=(
  $'--cluster\t<cluster>\tCluster to list tasks in'
)
typeset -ga _AI_SUGGEST_AWS_ECS_DESCRIBE_SERVICES_FLAGS=(
  $'--cluster\t<cluster>\tCluster the services run in'
  $'--services\t<svc>\tService(s) to describe'
)
typeset -ga _AI_SUGGEST_AWS_ECS_UPDATE_SERVICE_FLAGS=(
  $'--cluster\t<cluster>\tCluster the service runs in'
  $'--service\t<svc>\tService to update'
)
typeset -ga _AI_SUGGEST_AWS_ECS_RUN_TASK_FLAGS=(
  $'--cluster\t<cluster>\tCluster to run the task in'
  $'--task-definition\t<td>\tTask definition to run'
)

typeset -ga _AI_SUGGEST_AWS_EKS_DESCRIBE_CLUSTER_FLAGS=(
  $'--name\t<name>\tCluster to describe'
)
typeset -ga _AI_SUGGEST_AWS_EKS_UPDATE_KUBECONFIG_FLAGS=(
  $'--name\t<name>\tCluster to update kubeconfig for'
)
typeset -ga _AI_SUGGEST_AWS_EKS_CREATE_CLUSTER_FLAGS=(
  $'--name\t<name>\tName for the new cluster'
)

typeset -ga _AI_SUGGEST_AWS_SSM_START_SESSION_FLAGS=(
  $'--target\t<instance-id>\tInstance to start the session on'
)
typeset -ga _AI_SUGGEST_AWS_SSM_GET_PARAMETER_FLAGS=(
  $'--name\t<name>\tParameter to read'
)
typeset -ga _AI_SUGGEST_AWS_SSM_PUT_PARAMETER_FLAGS=(
  $'--name\t<name>\tParameter to create or update'
  $'--value\t<value>\tValue to store'
)
typeset -ga _AI_SUGGEST_AWS_SSM_SEND_COMMAND_FLAGS=(
  $'--document-name\t<doc>\tSSM document to run'
  $'--targets\t<targets>\tTarget instance(s)'
)

typeset -ga _AI_SUGGEST_TERRAFORM_STATE_SUBCMDS=(
  $'list\t[address]\tList resources in the state'
  $'show\t<address>\tShow attributes of a resource in the state'
  $'mv\t<src> <dst>\tMove an item in the state'
  $'rm\t<address>\tRemove an item from the state'
  $'pull\t\tFetch the state and output it to stdout'
  $'push\t<file>\tUpload a local state file to the remote state'
  $'replace-provider\t<from> <to>\tReplace a provider in the state'
)

typeset -ga _AI_SUGGEST_TERRAFORM_WORKSPACE_SUBCMDS=(
  $'list\t\tList workspaces'
  $'new\t<name>\tCreate a new workspace'
  $'select\t<name>\tSelect a workspace'
  $'delete\t<name>\tDelete a workspace'
  $'show\t\tShow the current workspace name'
)

typeset -ga _AI_SUGGEST_HELM_REPO_SUBCMDS=(
  $'add\t<name> <url>\tAdd a chart repository'
  $'update\t\tUpdate information of available charts'
  $'list\t\tList chart repositories'
  $'remove\t<name>\tRemove a chart repository'
)

typeset -ga _AI_SUGGEST_GH_PR_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_GH_ISSUE_SUBCMDS=(
  $'create\t\tCreate an issue'
  $'list\t\tList issues'
  $'view\t<number>\tView an issue'
  $'close\t<number>\tClose an issue'
  $'reopen\t<number>\tReopen an issue'
  $'comment\t<number>\tAdd a comment to an issue'
)

typeset -ga _AI_SUGGEST_GH_REPO_SUBCMDS=(
  $'clone\t<repo>\tClone a repository'
  $'create\t[name]\tCreate a new repository'
  $'view\t[repo]\tView a repository'
  $'fork\t[repo]\tFork a repository'
  $'list\t[owner]\tList repositories'
)

typeset -ga _AI_SUGGEST_GH_RUN_SUBCMDS=(
  $'list\t\tList recent workflow runs'
  $'view\t[run-id]\tView a workflow run'
  $'watch\t[run-id]\tWatch a run until it completes'
  $'rerun\t<run-id>\tRerun a workflow run'
  $'cancel\t<run-id>\tCancel a workflow run'
)

typeset -ga _AI_SUGGEST_GLAB_MR_SUBCMDS=(
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

typeset -ga _AI_SUGGEST_GLAB_CI_SUBCMDS=(
  $'status\t\tShow CI/CD pipeline status for the current branch'
  $'view\t[id]\tView a pipeline'
  $'trace\t[job-id]\tTrace/follow a CI/CD job log'
  $'retry\t[job-id]\tRetry a CI/CD job'
  $'run\t\tCreate/run a new pipeline'
)

typeset -ga _AI_SUGGEST_GCLOUD_COMPUTE_SUBCMDS=(
  $'instances\t[list|create|delete|describe]\tManage VM instances'
  $'ssh\t<instance>\tSSH into a VM instance'
  $'scp\t<src> <dst>\tCopy files to/from a VM instance'
  $'networks\t[list|create|delete]\tManage VPC networks'
  $'firewall-rules\t[list|create|delete]\tManage firewall rules'
  $'disks\t[list|create|delete]\tManage persistent disks'
)

typeset -ga _AI_SUGGEST_GCLOUD_CONTAINER_SUBCMDS=(
  $'clusters\t[list|create|delete|get-credentials]\tManage GKE clusters'
  $'images\t[list|delete]\tManage container images'
  $'node-pools\t[list|create|delete]\tManage GKE node pools'
)

# On-screen row/column the cursor is at, so the box lines up under wherever
# you're actually typing instead of always sitting at the terminal's left
# margin (col), and so the native overlay (see _ai_suggest_overlay_show) can
# be positioned against the real cursor (row). Refreshed once per new prompt
# (see _ai_suggest_line_init) rather than every keystroke: the prompt's
# start position doesn't change while editing a single line, only when a
# new one is drawn, so re-querying per-keystroke would just be repeated
# syscall overhead for the same answer.
typeset -gi _AI_SUGGEST_PROMPT_ROW=1
typeset -gi _AI_SUGGEST_PROMPT_COL=1

# Asks the terminal where the cursor currently is via a DSR (Device Status
# Report) query (\e[6n) and reads back its \e[<row>;<col>R reply on the same
# stream zle reads keystrokes from. Safe to do a blocking read here: zsh's
# event loop is single-threaded/cooperative, so zle's own read loop is not
# concurrently competing for input while this widget function is running —
# there's no race to lose. Leaves _AI_SUGGEST_PROMPT_ROW/COL at 1 (today's
# top-left-margin behavior) if anything goes wrong: terminal doesn't support
# DSR, output is piped/captured, or the reply doesn't arrive within the
# timeout — this is a cosmetic nicety for the ANSI box and a required input
# for the native overlay, but never something worth blocking or erroring
# over either way.
_ai_suggest_query_cursor_pos() {
  _AI_SUGGEST_PROMPT_ROW=1
  _AI_SUGGEST_PROMPT_COL=1
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
  (( row >= 1 )) && _AI_SUGGEST_PROMPT_ROW=$row
  (( col >= 1 )) && _AI_SUGGEST_PROMPT_COL=$col
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
_ai_suggest_overlay_supported() {
  (( AI_SUGGEST_OVERLAY ))
}

# Minimal JSON string escaping — only what can actually appear in a
# candidate/description/hint: backslash, double quote, and newline/tab.
# Static-table entries and directory/branch names are hand-written or
# filesystem/git-sourced ASCII with none of these in practice, but escaping
# is cheap enough to just always do rather than assume.
_ai_suggest_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  print -rn -- "$s"
}

# Builds a JSON array literal from "$@", each element escaped and quoted.
_ai_suggest_json_str_array() {
  local -a parts
  local item
  for item in "$@"; do
    parts+=("\"$(_ai_suggest_json_escape "$item")\"")
  done
  print -rn -- "[${(j:,:)parts}]"
}

# Throttles overlay-socket sends to at most one per
# _AI_SUGGEST_OVERLAY_MIN_INTERVAL — NOT a performance tweak. Root-caused
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
# `128 err` status segment's `fatal:` line), consistent with `_ai_suggest_
# overlay_send`'s own zsocket call (not the command that ran after it)
# having wedged the shell's tty state first. `_ai_suggest_overlay_send`
# below now runs the whole zsocket lifecycle in a forked, disowned subshell
# (`&!`) instead of the interactive shell's own process — `fork()` gives
# the child its own copy of the fd table, so whatever zsocket does to it
# stays confined to that throwaway child instead of the shell every
# subsequent command actually runs in. Every real send still fires well
# within what a human can perceive while typing (>=80ms
# apart is faster than typical keystroke spacing), so this is invisible in
# normal use — it only ever skips a send when keystrokes are arriving
# faster than that.
zmodload zsh/datetime 2>/dev/null
typeset -gF _AI_SUGGEST_LAST_OVERLAY_SEND=0
typeset -gF _AI_SUGGEST_OVERLAY_MIN_INTERVAL=0.08

# Fire-and-forget send of a JSON payload to the overlay companion app.
# zsocket (zsh/net/socket) connecting to a path with nothing listening —
# socket missing entirely, stale file, or refused connection — fails
# immediately (verified: sub-10ms, no retry/hang), so this is safe to call
# unconditionally from a hot path with no timeout wrapper needed. Errors are
# swallowed on purpose: the companion app not running is an expected,
# common state (e.g. user hasn't launched it), not a failure worth surfacing
# in the middle of typing.
_ai_suggest_overlay_send() {
  local payload=$1
  # force=1 bypasses the throttle below — for a discrete, one-shot action
  # (Escape/Ctrl-G dismiss, accepting a candidate, Ctrl-Space trigger, shell
  # exit) rather than the rapid-fire-keystrokes case the throttle exists
  # for (see the big comment above _AI_SUGGEST_OVERLAY_MIN_INTERVAL). Without
  # this, a hide sent within 80ms of the show that preceded it — e.g.
  # pressing Escape right after typing, the common case — silently gets
  # dropped by the same guard, leaving the panel visibly stuck open until
  # some later keystroke happens to trigger another send.
  local -i force=${2:-0}
  if (( ! force )) && (( EPOCHREALTIME - _AI_SUGGEST_LAST_OVERLAY_SEND < _AI_SUGGEST_OVERLAY_MIN_INTERVAL )); then
    return
  fi
  _AI_SUGGEST_LAST_OVERLAY_SEND=$EPOCHREALTIME
  # Forked off (`&!`: background + disown, no job-control notification) so
  # zsocket's connect/write/close cycle runs against a *copy* of the fd
  # table made by fork(), not the interactive shell's own — see this
  # function's section doc comment above for why that isolation matters.
  (
    zmodload zsh/net/socket 2>/dev/null || exit
    zsocket $AI_SUGGEST_OVERLAY_SOCK 2>/dev/null || exit
    print -u $REPLY -r -- "$payload" 2>/dev/null
    exec {REPLY}>&- 2>/dev/null
  ) &!
}

# Sends the current _AI_SUGGEST_CANDIDATES/etc + cursor position so the
# companion app can render (or reposition) the floating panel.
_ai_suggest_overlay_show() {
  local -a label_parts
  local i lbl hint_text
  for (( i = 1; i <= ${#_AI_SUGGEST_CANDIDATES}; i++ )); do
    lbl=${_AI_SUGGEST_LABELS[$i]:-${_AI_SUGGEST_CANDIDATES[$i]%% }}
    hint_text=${_AI_SUGGEST_HINTS[$i]:-}
    [[ -n $hint_text ]] && lbl="${lbl% }${lbl:+ }${hint_text}"
    label_parts+=("$lbl")
  done

  # _AI_SUGGEST_PROMPT_ROW/COL are only refreshed once per new prompt (a
  # real DSR query, see _ai_suggest_query_cursor_pos) — re-querying the
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
  local -i offset=$(( _AI_SUGGEST_PROMPT_COL - 1 + CURSOR ))
  local -i live_row=$(( _AI_SUGGEST_PROMPT_ROW + offset / cols ))
  local -i live_col=$(( offset % cols + 1 ))

  local payload="{"
  payload+="\"candidates\":$(_ai_suggest_json_str_array "${_AI_SUGGEST_CANDIDATES[@]}"),"
  payload+="\"descriptions\":$(_ai_suggest_json_str_array "${_AI_SUGGEST_DESCRIPTIONS[@]}"),"
  payload+="\"labels\":$(_ai_suggest_json_str_array "${label_parts[@]}"),"
  payload+="\"icons\":$(_ai_suggest_json_str_array "${_AI_SUGGEST_ICONS[@]}"),"
  payload+="\"selectedIndex\":$(( _AI_SUGGEST_INDEX - 1 )),"
  payload+="\"cursorRow\":$live_row,"
  payload+="\"cursorCol\":$live_col,"
  payload+="\"columns\":${cols},"
  payload+="\"lines\":${LINES:-30}"
  payload+="}"
  _ai_suggest_overlay_send "$payload"
}

_ai_suggest_overlay_hide() {
  local -i force=${1:-0}
  _ai_suggest_overlay_send '{"hide":true}' $force
}

_ai_suggest_present_candidates() {
  _ai_suggest_overlay_supported && _ai_suggest_overlay_show
}

# Resets the candidate arrays WITHOUT telling the overlay to hide — see
# _ai_suggest_clear_display's comment for why the two are kept apart.
_ai_suggest_reset_candidates() {
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  _AI_SUGGEST_INDEX=0
}

# Actually tells the overlay to hide (if something was showing) and resets
# local state. Only call this when nothing is going to replace what's
# showing within the same keystroke/action — e.g. Ctrl-G dismiss, a fresh
# prompt line, or "the buffer no longer matches anything." Callers that
# immediately re-suggest afterward (a keystroke, accepting a candidate)
# must NOT go through here first: _ai_suggest_overlay_send throttles sends
# under _AI_SUGGEST_OVERLAY_MIN_INTERVAL apart, and a hide here followed
# microseconds later by a show would mean the hide always goes through but
# the show is *always* dropped by that same guard — not just occasionally,
# every single time, since the two calls land far closer together than any
# human keystroke ever could. That was the actual cause of suggestions
# visibly disappearing while continuing to type: every keystroke hid the
# previous suggestion successfully, then silently failed to show the new
# one. See _ai_suggest_suggest_now/_ai_suggest_trigger/_ai_suggest_accept,
# which use _ai_suggest_reset_candidates instead and only call
# _ai_suggest_overlay_hide directly, on its own, when they've already
# determined nothing else will be shown this round.
_ai_suggest_clear_display() {
  # force=1: every caller of this function is a discrete, one-shot action
  # (Escape/Ctrl-G dismiss, accept-line, a fresh prompt) — never the
  # rapid-keystrokes case _AI_SUGGEST_OVERLAY_MIN_INTERVAL guards against —
  # so the hide must never get silently dropped by that throttle.
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 )) && _ai_suggest_overlay_hide 1
  _ai_suggest_reset_candidates
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
_ai_suggest_tool_icon_kind() {
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
# if it's a tool we have a static table for (see _AI_SUGGEST_GIT_SUBCMDS),
# populates the candidate/description/hint arrays directly from it. Only
# fires while still typing the subcommand itself (no space after it yet);
# once a subcommand is chosen, its own arguments are free-form and this
# table has nothing useful to say about them (git's checkout/switch/merge/
# rebase/branch are the exception — see _ai_suggest_git_branch_match, which
# picks up exactly where this backs off).
_ai_suggest_static_match() {
  local tool="${BUFFER%% *}"
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1

  local -a table
  case "$tool" in
    git) table=("${_AI_SUGGEST_GIT_SUBCMDS[@]}") ;;
    kubectl|k) table=("${_AI_SUGGEST_KUBECTL_SUBCMDS[@]}") ;;
    npm) table=("${_AI_SUGGEST_NPM_SUBCMDS[@]}") ;;
    docker) table=("${_AI_SUGGEST_DOCKER_SUBCMDS[@]}") ;;
    aws) table=("${_AI_SUGGEST_AWS_SUBCMDS[@]}") ;;
    terraform|tf) table=("${_AI_SUGGEST_TERRAFORM_SUBCMDS[@]}") ;;
    helm) table=("${_AI_SUGGEST_HELM_SUBCMDS[@]}") ;;
    gh) table=("${_AI_SUGGEST_GH_SUBCMDS[@]}") ;;
    glab) table=("${_AI_SUGGEST_GLAB_SUBCMDS[@]}") ;;
    yarn) table=("${_AI_SUGGEST_YARN_SUBCMDS[@]}") ;;
    pnpm) table=("${_AI_SUGGEST_PNPM_SUBCMDS[@]}") ;;
    gcloud) table=("${_AI_SUGGEST_GCLOUD_SUBCMDS[@]}") ;;
    az) table=("${_AI_SUGGEST_AZ_SUBCMDS[@]}") ;;
    kafka-topics.sh|kafka-topics) table=("${_AI_SUGGEST_KAFKA_TOPICS_SUBCMDS[@]}") ;;
    kafka-console-producer.sh|kafka-console-producer) table=("${_AI_SUGGEST_KAFKA_CONSOLE_PRODUCER_SUBCMDS[@]}") ;;
    kafka-console-consumer.sh|kafka-console-consumer) table=("${_AI_SUGGEST_KAFKA_CONSOLE_CONSUMER_SUBCMDS[@]}") ;;
    kafka-consumer-groups.sh|kafka-consumer-groups) table=("${_AI_SUGGEST_KAFKA_CONSUMER_GROUPS_SUBCMDS[@]}") ;;
    rabbitmqctl) table=("${_AI_SUGGEST_RABBITMQCTL_SUBCMDS[@]}") ;;
    cargo) table=("${_AI_SUGGEST_CARGO_SUBCMDS[@]}") ;;
    go) table=("${_AI_SUGGEST_GO_SUBCMDS[@]}") ;;
    pip|pip3) table=("${_AI_SUGGEST_PIP_SUBCMDS[@]}") ;;
    poetry) table=("${_AI_SUGGEST_POETRY_SUBCMDS[@]}") ;;
    mvn) table=("${_AI_SUGGEST_MVN_SUBCMDS[@]}") ;;
    gradle) table=("${_AI_SUGGEST_GRADLE_SUBCMDS[@]}") ;;
    dotnet) table=("${_AI_SUGGEST_DOTNET_SUBCMDS[@]}") ;;
    bundle) table=("${_AI_SUGGEST_BUNDLE_SUBCMDS[@]}") ;;
    gem) table=("${_AI_SUGGEST_GEM_SUBCMDS[@]}") ;;
    brew) table=("${_AI_SUGGEST_BREW_SUBCMDS[@]}") ;;
    docker-compose) table=("${_AI_SUGGEST_DOCKER_COMPOSE_SUBCMDS[@]}") ;;
    vagrant) table=("${_AI_SUGGEST_VAGRANT_SUBCMDS[@]}") ;;
    pulumi) table=("${_AI_SUGGEST_PULUMI_SUBCMDS[@]}") ;;
    heroku) table=("${_AI_SUGGEST_HEROKU_SUBCMDS[@]}") ;;
    vercel) table=("${_AI_SUGGEST_VERCEL_SUBCMDS[@]}") ;;
    netlify) table=("${_AI_SUGGEST_NETLIFY_SUBCMDS[@]}") ;;
    firebase) table=("${_AI_SUGGEST_FIREBASE_SUBCMDS[@]}") ;;
    flyctl|fly) table=("${_AI_SUGGEST_FLYCTL_SUBCMDS[@]}") ;;
    doctl) table=("${_AI_SUGGEST_DOCTL_SUBCMDS[@]}") ;;
    turbo) table=("${_AI_SUGGEST_TURBO_SUBCMDS[@]}") ;;
    nx) table=("${_AI_SUGGEST_NX_SUBCMDS[@]}") ;;
    tmux) table=("${_AI_SUGGEST_TMUX_SUBCMDS[@]}") ;;
    systemctl) table=("${_AI_SUGGEST_SYSTEMCTL_SUBCMDS[@]}") ;;
    nvm) table=("${_AI_SUGGEST_NVM_SUBCMDS[@]}") ;;
    pyenv) table=("${_AI_SUGGEST_PYENV_SUBCMDS[@]}") ;;
    rbenv) table=("${_AI_SUGGEST_RBENV_SUBCMDS[@]}") ;;
    npx) table=("${_AI_SUGGEST_NPX_SUBCMDS[@]}") ;;
    minikube) table=("${_AI_SUGGEST_MINIKUBE_SUBCMDS[@]}") ;;
    *) return 1 ;;
  esac

  local rest="${BUFFER#$tool}"
  rest="${rest## }"
  # Already past the subcommand (it has its own argument being typed) —
  # this table doesn't cover per-subcommand arguments, so back off (see
  # _ai_suggest_git_branch_match for the git-branch-argument case).
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
      [[ "$rest" == -* ]] && table=("${_AI_SUGGEST_GENERIC_FLAGS[@]}")
      ;;
  esac

  local entry name hint desc
  local -a parts
  local icon_kind=$(_ai_suggest_tool_icon_kind "$tool")
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for entry in "${table[@]}"; do
    parts=("${(@ps:\t:)entry}")
    name=$parts[1]
    [[ "$name" == "$rest"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("$tool $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("${parts[2]:-}")
    _AI_SUGGEST_DESCRIPTIONS+=("${parts[3]:-}")
    _AI_SUGGEST_ICONS+=("$icon_kind")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Suggests directories under whatever path is being typed after `cd`, e.g.
# "cd Doc" -> "cd Documents/". Uses zsh's own glob qualifiers instead of
# `ls`/`find`: the (/N) qualifier restricts matches to directories and makes
# a no-match produce an empty list (N = NULL_GLOB) rather than a "no matches
# found" error. No trailing space on the candidate (unlike the tool tables
# below) — a path is one argument being built up incrementally, so accepting
# "Documents/" should leave the cursor ready to keep typing the next segment
# (or press Tab again to drill further), not start a new word.
_ai_suggest_cd_match() {
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
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for dir in "${matches[@]}"; do
    label="${dir%/}/"
    _AI_SUGGEST_CANDIDATES+=("$tool ${dir%/}/")
    _AI_SUGGEST_LABELS+=("$label")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("Change directory")
    _AI_SUGGEST_ICONS+=("dir")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Suggests local branch names once a git subcommand that takes one has been
# typed (checkout/switch/merge/rebase/branch) — the counterpart to
# _AI_SUGGEST_GIT_SUBCMDS for the *next* word instead of the subcommand
# itself. Runs `git for-each-ref` fresh on every call rather than caching:
# it's a local-refs-only read (no network), cheap enough per keystroke, and
# means a branch created a second ago still shows up.
_ai_suggest_git_branch_match() {
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
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for br in "${branches[@]}"; do
    [[ "$br" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("git $subcmd $br ")
    _AI_SUGGEST_LABELS+=("$br")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("Local branch")
    _AI_SUGGEST_ICONS+=("branch")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Shared by every JSON-based project-file matcher below (package.json's
# "scripts", composer.json's "scripts", deno.json(c)'s "tasks"): reads
# file $1 and prints "name<TAB>value" pairs for each key found inside the
# first top-level object under the JSON key named $2, one per line, in
# file order (current directory only — no upward search, same "just cwd"
# scope as _ai_suggest_cd_match). A crude, line-based parse rather than a
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
_ai_suggest_json_kv_block() {
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
# the generic guesses in _AI_SUGGEST_{NPM,YARN,PNPM}_SUBCMDS) suggests
# correctly, description showing the actual command it runs. Takes
# priority over _ai_suggest_nested_match/_ai_suggest_static_match (tried
# first in _ai_suggest_static_or_dynamic_match) so real project data wins
# over the generic hand-picked guesses whenever it's available, but backs
# off (returns 1) the moment there's no package.json or nothing matches,
# letting those static tables handle it — this only ever ADDS coverage,
# never removes the fallback for non-script subcommands like `install`/
# `add`.
#
# npm specifically requires the explicit "run" for arbitrary scripts —
# bare `npm <script>` only works for a handful of reserved names (start/
# test/stop/restart), which are exactly the ones already hand-picked into
# _AI_SUGGEST_NPM_SUBCMDS, so this only completes after "npm run " to
# avoid suggesting a command that would actually fail to run. yarn and
# pnpm both support invoking a script directly OR via "run", so this
# completes either shape for those two.
_ai_suggest_package_script_match() {
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
  script_lines=(${(f)"$(_ai_suggest_json_kv_block package.json scripts)"})
  (( ${#script_lines} > 0 )) || return 1

  local icon_kind=$(_ai_suggest_tool_icon_kind "$tool")
  local entry name cmd
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for entry in "${script_lines[@]}"; do
    name="${entry%%$'\t'*}"
    cmd="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("$tool $prefix$name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("${cmd:-package.json script}")
    _AI_SUGGEST_ICONS+=("$icon_kind")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
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
_ai_suggest_makefile_targets() {
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
_ai_suggest_make_match() {
  local tool="${BUFFER%% *}"
  [[ "$tool" == make ]] || return 1
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1
  local partial=""
  [[ "$BUFFER" == "$tool "* ]] && partial="${BUFFER#$tool }"
  [[ "$partial" == *' '* ]] && return 1

  local -a targets
  targets=(${(f)"$(_ai_suggest_makefile_targets)"})
  (( ${#targets} > 0 )) || return 1

  local icon_kind=$(_ai_suggest_tool_icon_kind make)
  local name
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for name in "${targets[@]}"; do
    [[ "$name" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("make $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("Makefile target")
    _AI_SUGGEST_ICONS+=("$icon_kind")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Reads recipe names out of ./justfile (falling back to ./Justfile — Just
# accepts either capitalization), one per line. A recipe definition is a
# line starting at column 0 with a bare identifier (optionally prefixed
# by "@" for a silent recipe), followed eventually by ":" that isn't
# immediately followed by "=" (":=" is Just's variable-assignment
# operator, not a recipe) — recipe bodies are always indented and never
# match this.
_ai_suggest_justfile_recipes() {
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
# ./justfile — same reasoning as _ai_suggest_make_match: no meaningful
# generic guess exists for a project's own recipe names, so this is
# Just's only source of completions.
_ai_suggest_just_match() {
  local tool="${BUFFER%% *}"
  [[ "$tool" == just ]] || return 1
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1
  local partial=""
  [[ "$BUFFER" == "$tool "* ]] && partial="${BUFFER#$tool }"
  [[ "$partial" == *' '* ]] && return 1

  local -a recipes
  recipes=(${(f)"$(_ai_suggest_justfile_recipes)"})
  (( ${#recipes} > 0 )) || return 1

  local icon_kind=$(_ai_suggest_tool_icon_kind just)
  local name
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for name in "${recipes[@]}"; do
    [[ "$name" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("just $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("Just recipe")
    _AI_SUGGEST_ICONS+=("$icon_kind")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Matches "composer run-script <partial>" against real script names read
# live from ./composer.json's "scripts" object — the PHP-ecosystem
# equivalent of _ai_suggest_package_script_match. Unlike npm/yarn/pnpm,
# Composer has no bare "composer <script>" invocation form at all, so
# this only ever completes after the explicit "run-script".
_ai_suggest_composer_match() {
  [[ "$BUFFER" == composer\ run-script\ * ]] || return 1
  local partial="${BUFFER#composer run-script }"
  [[ "$partial" == *' '* ]] && return 1

  local -a script_lines
  script_lines=(${(f)"$(_ai_suggest_json_kv_block composer.json scripts)"})
  (( ${#script_lines} > 0 )) || return 1

  local icon_kind=$(_ai_suggest_tool_icon_kind composer)
  local entry name cmd
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for entry in "${script_lines[@]}"; do
    name="${entry%%$'\t'*}"
    cmd="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("composer run-script $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("${cmd:-Composer script}")
    _AI_SUGGEST_ICONS+=("$icon_kind")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Matches "deno task <partial>" against real task names read live from
# ./deno.json's (or ./deno.jsonc's) "tasks" object — the Deno-ecosystem
# equivalent of _ai_suggest_package_script_match. Deno reserves its own
# top-level subcommands (run/test/fmt/lint/task/...), so — like npm —
# there's no bare "deno <task>" form; this only completes after "task".
_ai_suggest_deno_task_match() {
  [[ "$BUFFER" == deno\ task\ * ]] || return 1
  local partial="${BUFFER#deno task }"
  [[ "$partial" == *' '* ]] && return 1

  local file=deno.json
  [[ -f $file ]] || file=deno.jsonc
  local -a task_lines
  task_lines=(${(f)"$(_ai_suggest_json_kv_block "$file" tasks)"})
  (( ${#task_lines} > 0 )) || return 1

  local icon_kind=$(_ai_suggest_tool_icon_kind deno)
  local entry name cmd
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for entry in "${task_lines[@]}"; do
    name="${entry%%$'\t'*}"
    cmd="${entry#*$'\t'}"
    [[ "$name" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("deno task $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("${cmd:-Deno task}")
    _AI_SUGGEST_ICONS+=("$icon_kind")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Matches "<tool> <subcmd> [<subcmd2> ...] <partial>" against a nested
# static table one (or more) levels deeper than _ai_suggest_static_match: the
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
_ai_suggest_nested_match() {
  local tool="${BUFFER%% *}"
  [[ "$BUFFER" == "$tool "* ]] || return 1

  case "$tool" in
    git|kubectl|k|npm|docker|aws|terraform|tf|helm|gh|glab|gcloud|tmux) ;;
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
  # tool yet is level 1, already handled by _ai_suggest_static_match.
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
    table_var="_AI_SUGGEST_${key}_FLAGS"
    (( ${+parameters[$table_var]} )) || table_var="_AI_SUGGEST_GENERIC_FLAGS"
  else
    table_var="_AI_SUGGEST_${key}_SUBCMDS"
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
      table_var="_AI_SUGGEST_${key}_FLAGS"
      (( ${+parameters[$table_var]} )) || table_var="_AI_SUGGEST_GENERIC_FLAGS"
    fi
  fi
  # Flags and sub-subcommands both belong to the same tool, so they get the
  # same glyph — see _ai_suggest_tool_icon_kind.
  local icon_kind=$(_ai_suggest_tool_icon_kind "$tool_canon")
  (( ${+parameters[$table_var]} )) || return 1
  local -a table=("${(@P)table_var}")
  (( ${#table} > 0 )) || return 1

  local entry name
  local -a parts
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_ICONS=()
  for entry in "${table[@]}"; do
    parts=("${(@ps:\t:)entry}")
    name=$parts[1]
    [[ "$name" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("$tool ${(j: :)path} $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("${parts[2]:-}")
    _AI_SUGGEST_DESCRIPTIONS+=("${parts[3]:-}")
    _AI_SUGGEST_ICONS+=("$icon_kind")
    (( ${#_AI_SUGGEST_CANDIDATES} >= _AI_SUGGEST_MAX_CANDIDATES )) && break
  done
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
}

# Tries every no-AI-round-trip match source in order, cheapest/most-specific
# first, and stops at the first one that produces candidates. Shared entry
# point for both the automatic (_ai_suggest_suggest_now) and manual
# (_ai_suggest_trigger) paths so they never drift out of sync on what counts
# as a "static" match.
_ai_suggest_static_or_dynamic_match() {
  _ai_suggest_cd_match && return 0
  _ai_suggest_git_branch_match && return 0
  _ai_suggest_package_script_match && return 0
  _ai_suggest_make_match && return 0
  _ai_suggest_just_match && return 0
  _ai_suggest_composer_match && return 0
  _ai_suggest_deno_task_match && return 0
  _ai_suggest_nested_match && return 0
  _ai_suggest_static_match
}

# Looks for a suggestion for the CURRENT buffer and renders it. Shared by
# every caller that just changed BUFFER and wants suggestions re-evaluated
# for the new state — a keystroke (_ai_suggest_edit_wrapper) or accepting a
# candidate (_ai_suggest_accept, so picking "git add " immediately offers
# what typically follows it, chaining word-by-word instead of going silent
# until the next keystroke).
_ai_suggest_suggest_now() {
  # Whether the overlay currently has something on screen that this call
  # needs to account for — reset the local arrays now (not through
  # _ai_suggest_clear_display: see its comment for why sending hide here,
  # right before this same call likely sends a fresh show, would get that
  # show silently dropped by the overlay's send throttle).
  local -i had_candidates=$(( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
  _ai_suggest_reset_candidates

  # Explicit `return 0`, not bare `return`: a zle widget function that ends
  # with non-zero status makes zle beep, and _ai_suggest_auto_enabled
  # returns non-zero precisely when suggestions are toggled off — bare
  # `return` here would carry that failure status out and ring the
  # terminal bell on every single keystroke while suggestions are disabled.
  if ! _ai_suggest_auto_enabled; then
    (( had_candidates )) && _ai_suggest_overlay_hide
    return 0
  fi

  # Known, exact data (cd targets, git branches, tool subcommands) beats
  # everything else — no guess, no round-trip — so it both answers
  # correctly and skips the AI call entirely for this buffer.
  if _ai_suggest_static_or_dynamic_match; then
    _AI_SUGGEST_INDEX=1
    _ai_suggest_present_candidates
  elif (( had_candidates )); then
    # Buffer no longer matches anything (e.g. backspaced past a known
    # prefix) — nothing will replace what was showing, so this is the one
    # case within this call where actually hiding is correct.
    _ai_suggest_overlay_hide
  fi
}

# Wraps every buffer-editing widget: runs whatever was bound to $WIDGET
# before we took it over (another plugin's customization, e.g. zsh's own
# `url-quote-magic` on self-insert — see _ai_suggest_wrap_widget), falling
# back to the plain builtin (`zle .$WIDGET`) when nothing else had claimed
# it, then re-evaluates suggestions for the resulting buffer.
_ai_suggest_edit_wrapper() {
  # Backspacing the trailing space that just triggered a follow-up
  # suggestion (e.g. "git commit " -> "-m") should close that suggestion,
  # not re-show one — without this check, deleting back to "git commit"
  # re-matches the top-level "commit" entry against itself (same reason
  # _ai_suggest_accept_line has to guard against that self-match; see its
  # comment) and the panel looks like it never closed, just swapped back to
  # the previous suggestion instead of following the character you deleted.
  local -i deleted_trailing_space=0
  if [[ $WIDGET == backward-delete-char && $CURSOR == ${#BUFFER} && $BUFFER == *' ' ]]; then
    deleted_trailing_space=1
  fi

  if (( $+_AI_SUGGEST_ORIG_WIDGET[$WIDGET] )); then
    _ai_suggest_call_orig_widget $WIDGET
  else
    zle .$WIDGET
  fi

  if (( deleted_trailing_space )); then
    _ai_suggest_clear_display
  else
    _ai_suggest_suggest_now
  fi
}

# --- the manual, immediate trigger ------------------------------------------

_ai_suggest_trigger() {
  local -i had_candidates=$(( ${#_AI_SUGGEST_CANDIDATES} > 0 ))
  _ai_suggest_reset_candidates

  if [[ -z $BUFFER ]]; then
    (( had_candidates )) && _ai_suggest_overlay_hide 1
    zle -M "ai-suggest: dòng lệnh đang trống"
    return
  fi

  if _ai_suggest_static_or_dynamic_match; then
    _AI_SUGGEST_INDEX=1
    _ai_suggest_present_candidates
    return
  fi

  (( had_candidates )) && _ai_suggest_overlay_hide 1
  zle -M "ai-suggest: không có gợi ý cho lệnh này"
  return 1
}

# --- selection widgets --------------------------------------------------------

_ai_suggest_accept() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )); then
    # Capture the chosen candidate before resetting the arrays.
    local chosen=$_AI_SUGGEST_CANDIDATES[$_AI_SUGGEST_INDEX]
    _ai_suggest_reset_candidates
    # Candidates carry their own trailing separator baked in — a space for
    # every matcher except `cd`, which appends "/" instead (see e.g.
    # _ai_suggest_static_match's "$tool $name " vs the cd matcher's
    # "$tool ${dir%/}/"). Stripping just the space here means accepting
    # inserts only the word itself, cursor right after it — not "word " —
    # so the next suggestion (e.g. "commit" -> "-m") only appears once you
    # actually type a space yourself (self-insert already re-evaluates
    # suggestions on every keystroke, see _ai_suggest_edit_wrapper), instead
    # of popping up immediately on accept the way it used to.
    BUFFER=${chosen% }
    CURSOR=${#BUFFER}
    _ai_suggest_overlay_hide 1
  else
    zle .expand-or-complete
  fi
}

_ai_suggest_forward_char() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )) && (( CURSOR == ${#BUFFER} )); then
    _ai_suggest_accept
  elif (( $+_AI_SUGGEST_ORIG_WIDGET[forward-char] )); then
    _ai_suggest_call_orig_widget forward-char
  else
    zle .forward-char
  fi
}

_ai_suggest_next() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 1 )); then
    (( _AI_SUGGEST_INDEX = _AI_SUGGEST_INDEX % ${#_AI_SUGGEST_CANDIDATES} + 1 ))
    _ai_suggest_present_candidates
  else
    zle .down-line-or-history
  fi
}

_ai_suggest_prev() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 1 )); then
    (( _AI_SUGGEST_INDEX = (_AI_SUGGEST_INDEX - 2 + ${#_AI_SUGGEST_CANDIDATES}) % ${#_AI_SUGGEST_CANDIDATES} + 1 ))
    _ai_suggest_present_candidates
  else
    zle .up-line-or-history
  fi
}

_ai_suggest_dismiss() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )); then
    _ai_suggest_clear_display
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
_ai_suggest_dismiss_escape() {
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 )) && _ai_suggest_clear_display
  true
}

_ai_suggest_accept_line() {
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
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )) \
     && [[ "${_AI_SUGGEST_CANDIDATES[$_AI_SUGGEST_INDEX]% }" != "$BUFFER" ]]; then
    _ai_suggest_accept
    return
  fi
  _ai_suggest_clear_display
  if (( $+_AI_SUGGEST_ORIG_WIDGET[accept-line] )); then
    _ai_suggest_call_orig_widget accept-line
  else
    zle .accept-line
  fi
}

_ai_suggest_line_init() {
  _ai_suggest_clear_display
  _ai_suggest_call_orig_widget zle-line-init
  _ai_suggest_query_cursor_pos
}

# --- registration --------------------------------------------------------

zle -N _ai_suggest_trigger
zle -N _ai_suggest_accept
zle -N _ai_suggest_next
zle -N _ai_suggest_prev
zle -N _ai_suggest_dismiss
zle -N _ai_suggest_dismiss_escape
# These three (unlike the ones above) are well-known widget names other
# plugins/frameworks may already have bound — go through
# _ai_suggest_wrap_widget so anything already there (Powerlevel10k's
# zle-line-init, etc.) keeps running instead of being silently replaced.
_ai_suggest_wrap_widget forward-char _ai_suggest_forward_char
_ai_suggest_wrap_widget accept-line _ai_suggest_accept_line
_ai_suggest_wrap_widget zle-line-init _ai_suggest_line_init

bindkey "$AI_SUGGEST_KEY" _ai_suggest_trigger
bindkey '^I' _ai_suggest_accept  # Tab
# forward-char (not _ai_suggest_forward_char) is the correct widget name
# here: _ai_suggest_wrap_widget above registers our implementation UNDER
# the name "forward-char" itself (zle -N forward-char _ai_suggest_forward_char),
# the same way it takes over accept-line/zle-line-init below — it does not
# also create a separate widget literally named "_ai_suggest_forward_char".
# Binding directly to that nonexistent name is exactly what previously
# made Right-arrow/Ctrl-F fail with "No such widget `_ai_suggest_forward_char'".
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
bindkey '^[[A' _ai_suggest_prev  # Up arrow, normal cursor-key mode
bindkey '^[OA' _ai_suggest_prev  # Up arrow, application cursor-key mode
bindkey '^[[B' _ai_suggest_next  # Down arrow, normal cursor-key mode
bindkey '^[OB' _ai_suggest_next  # Down arrow, application cursor-key mode
bindkey '^G' _ai_suggest_dismiss
# Plain Escape is "undefined-key" (a no-op/beep) by default in zsh's emacs
# keymap — it's otherwise only ever a PREFIX for longer sequences like
# arrow keys (\e[A, \e[B, ...), never bound to a standalone action of its
# own, so this doesn't shadow anything. zle already disambiguates "Escape
# alone" from "the start of a longer \e-prefixed sequence" via
# $KEYTIMEOUT, the same mechanism that lets Alt-key combos coexist with a
# bare Escape binding elsewhere (e.g. vi-mode setups) — a real arrow-key
# press still resolves to its own longer binding, not this one.
#
# Bound to _ai_suggest_dismiss_escape (not the plain _ai_suggest_dismiss
# Ctrl-G uses) so pressing Escape with nothing showing is a silent no-op
# instead of send-break's beep — see that function's comment.
bindkey '^[' _ai_suggest_dismiss_escape

if (( AI_SUGGEST_AUTO )); then
  local -a _ai_suggest_watched_widgets
  _ai_suggest_watched_widgets=(
    self-insert backward-delete-char delete-char
    backward-kill-word kill-word kill-line backward-kill-line
    # The physical spacebar is bound to zsh's own `magic-space` widget by
    # default (history "!"-expansion on space), NOT `self-insert` — so
    # without watching it too, pressing space would insert the space
    # (magic-space still runs, chained via _AI_SUGGEST_ORIG_WIDGET below)
    # but never re-trigger suggestions, leaving chained follow-ups (e.g.
    # "commit" -> "-m") silent until some other, self-insert-bound key
    # was pressed.
    magic-space
  )
  local _w
  for _w in $_ai_suggest_watched_widgets; do
    _ai_suggest_wrap_widget $_w _ai_suggest_edit_wrapper
  done
  unset _w _ai_suggest_watched_widgets
fi

# Makes sure the overlay panel doesn't linger on screen once this shell
# session is gone — the normal `exit`/`accept-line` path already hides
# before running the command (see _ai_suggest_accept_line), but that
# doesn't cover Ctrl-D on an empty line or the parent terminal window
# closing (which delivers SIGHUP; zsh's default handling for that still
# runs zshexit, same as a graceful `exit`). Registered via add-zsh-hook
# rather than defining zshexit() directly so this doesn't clobber a
# zshexit function/hook some other plugin or the user's own .zshrc may
# already have.
_ai_suggest_on_shell_exit() {
  (( ${#_AI_SUGGEST_CANDIDATES} > 0 )) && _ai_suggest_overlay_hide 1
}
autoload -Uz add-zsh-hook
add-zsh-hook zshexit _ai_suggest_on_shell_exit
