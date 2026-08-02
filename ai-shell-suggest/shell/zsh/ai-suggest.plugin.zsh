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
# over a Unix socket to the ai-suggest-menubar companion app, which draws a
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
# fire-and-forget over the socket. See ai-suggest-menubar's
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
#                             panel (ai-suggest-menubar companion app,
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
# ai-suggest-menubar app (a separate menu-bar icon/toggle — see
# ai-suggest-menubar/), not from this shell. The two are different
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
typeset -gi _AI_SUGGEST_INDEX=0

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
  $'commit\t-m <message>\tRecord changes to the repository'
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
  $'clean\t[-fd]\tRemove untracked files from the working tree'
  $'restore\t<file>...\tRestore working tree files'
)

typeset -ga _AI_SUGGEST_KUBECTL_SUBCMDS=(
  $'get\t<resource>\tDisplay one or many resources'
  $'describe\t<resource> <name>\tShow detailed state of a resource'
  $'logs\t<pod>\tPrint logs for a container in a pod'
  $'apply\t-f <file>\tApply a configuration to a resource'
  $'exec\t-it <pod> -- <cmd>\tExecute a command in a container'
  $'delete\t<resource> <name>\tDelete resources'
  $'create\t-f <file>\tCreate a resource from a file or stdin'
  $'edit\t<resource> <name>\tEdit a resource on the server'
  $'rollout\t[status|undo|restart]\tManage the rollout of a resource'
  $'scale\t--replicas=<n> <resource>\tScale a resource'
  $'port-forward\t<pod> <ports>\tForward local ports to a pod'
  $'config\t[get-contexts|use-context]\tModify kubeconfig files'
  $'top\t[pod|node]\tDisplay resource (CPU/memory) usage'
  $'exec\t-it <pod> sh\tOpen a shell in a container'
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
  $'ps\t[-a]\tList containers'
  $'images\t\tList images'
  $'run\t<image>\tRun a command in a new container'
  $'build\t-t <tag> .\tBuild an image from a Dockerfile'
  $'exec\t-it <container> <cmd>\tRun a command in a running container'
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
  $'--create\t--topic <name>\tCreate a topic'
  $'--delete\t--topic <name>\tDelete a topic'
  $'--describe\t--topic <name>\tDescribe a topic'
  $'--alter\t--topic <name>\tAlter a topic'"'"'s configuration'
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
  $'--describe\t--group <id>\tDescribe a consumer group'
  $'--bootstrap-server\t<host:port>\tKafka broker to connect to'
  $'--reset-offsets\t--group <id> --topic <name>\tReset consumer group offsets'
  $'--delete\t--group <id>\tDelete a consumer group'
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
  $'ls\t[-a]\tList images'
  $'build\t-t <tag> .\tBuild an image from a Dockerfile'
  $'pull\t<image>\tPull an image from a registry'
  $'push\t<image>\tPush an image to a registry'
  $'rm\t<image>\tRemove an image'
  $'tag\t<image> <tag>\tTag an image into a repository'
  $'inspect\t<image>\tReturn low-level info on an image'
  $'history\t<image>\tShow the history of an image'
  $'prune\t[-a]\tRemove unused images'
  $'save\t-o <file> <image>\tSave an image to a tar archive'
  $'load\t-i <file>\tLoad an image from a tar archive'
)

typeset -ga _AI_SUGGEST_DOCKER_CONTAINER_SUBCMDS=(
  $'ls\t[-a]\tList containers'
  $'run\t<image>\tRun a command in a new container'
  $'exec\t-it <container> <cmd>\tRun a command in a running container'
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
  $'prune\t[-a]\tRemove unused data'
  $'info\t\tDisplay system-wide information'
  $'events\t\tGet real time events from the server'
)

typeset -ga _AI_SUGGEST_DOCKER_COMPOSE_SUBCMDS=(
  $'up\t[-d]\tCreate and start containers'
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

typeset -ga _AI_SUGGEST_GIT_STASH_SUBCMDS=(
  $'push\t[-m <message>]\tStash changes'
  $'pop\t\tApply and remove the most recent stash'
  $'apply\t[stash]\tApply a stash without removing it'
  $'list\t\tList stashes'
  $'show\t[stash]\tShow the changes in a stash'
  $'drop\t[stash]\tRemove a stash'
  $'clear\t\tRemove all stashes'
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
  $'start-instances\t--instance-ids <id>\tStart an instance'
  $'stop-instances\t--instance-ids <id>\tStop an instance'
  $'terminate-instances\t--instance-ids <id>\tTerminate an instance'
  $'describe-security-groups\t\tDescribe security groups'
  $'describe-vpcs\t\tDescribe VPCs'
  $'describe-subnets\t\tDescribe subnets'
  $'describe-images\t\tDescribe AMIs'
  $'run-instances\t--image-id <ami>\tLaunch new instances'
  $'create-tags\t--resources <id> --tags <tags>\tTag a resource'
)

typeset -ga _AI_SUGGEST_AWS_LAMBDA_SUBCMDS=(
  $'list-functions\t\tList Lambda functions'
  $'invoke\t--function-name <name> <outfile>\tInvoke a function'
  $'update-function-code\t--function-name <name>\tUpdate function code'
  $'get-function\t--function-name <name>\tGet function configuration'
  $'create-function\t--function-name <name>\tCreate a function'
  $'delete-function\t--function-name <name>\tDelete a function'
  $'list-layers\t\tList Lambda layers'
)

typeset -ga _AI_SUGGEST_AWS_IAM_SUBCMDS=(
  $'list-users\t\tList IAM users'
  $'list-roles\t\tList IAM roles'
  $'get-user\t[--user-name <name>]\tGet the current or named IAM user'
  $'create-role\t--role-name <name>\tCreate a role'
  $'attach-role-policy\t--role-name <name> --policy-arn <arn>\tAttach a policy to a role'
  $'list-attached-role-policies\t--role-name <name>\tList policies attached to a role'
  $'create-access-key\t--user-name <name>\tCreate an access key'
)

typeset -ga _AI_SUGGEST_AWS_LOGS_SUBCMDS=(
  $'tail\t<log-group>\tTail a log group in real time'
  $'describe-log-groups\t\tList log groups'
  $'describe-log-streams\t--log-group-name <name>\tList log streams'
  $'get-log-events\t--log-group-name <name> --log-stream-name <stream>\tGet log events'
  $'filter-log-events\t--log-group-name <name>\tFilter log events by pattern'
)

typeset -ga _AI_SUGGEST_AWS_STS_SUBCMDS=(
  $'get-caller-identity\t\tShow the current IAM identity'
  $'assume-role\t--role-arn <arn> --role-session-name <name>\tAssume an IAM role'
)

typeset -ga _AI_SUGGEST_AWS_CLOUDFORMATION_SUBCMDS=(
  $'deploy\t--template-file <file> --stack-name <name>\tDeploy a stack'
  $'describe-stacks\t\tDescribe stacks'
  $'create-stack\t--stack-name <name> --template-body <file>\tCreate a stack'
  $'update-stack\t--stack-name <name>\tUpdate a stack'
  $'delete-stack\t--stack-name <name>\tDelete a stack'
  $'list-stacks\t\tList stacks'
  $'validate-template\t--template-body <file>\tValidate a template'
)

typeset -ga _AI_SUGGEST_AWS_ECR_SUBCMDS=(
  $'get-login-password\t\tGet a password to authenticate to ECR'
  $'describe-repositories\t\tDescribe ECR repositories'
  $'create-repository\t--repository-name <name>\tCreate a repository'
  $'list-images\t--repository-name <name>\tList images in a repository'
)

typeset -ga _AI_SUGGEST_AWS_ECS_SUBCMDS=(
  $'list-clusters\t\tList ECS clusters'
  $'list-services\t--cluster <cluster>\tList services in a cluster'
  $'list-tasks\t--cluster <cluster>\tList tasks in a cluster'
  $'describe-services\t--cluster <cluster> --services <svc>\tDescribe services'
  $'update-service\t--cluster <cluster> --service <svc>\tUpdate a service'
  $'run-task\t--cluster <cluster> --task-definition <td>\tRun a one-off task'
)

typeset -ga _AI_SUGGEST_AWS_EKS_SUBCMDS=(
  $'list-clusters\t\tList EKS clusters'
  $'describe-cluster\t--name <name>\tDescribe a cluster'
  $'update-kubeconfig\t--name <name>\tUpdate local kubeconfig for a cluster'
  $'create-cluster\t--name <name>\tCreate a cluster'
)

typeset -ga _AI_SUGGEST_AWS_SSM_SUBCMDS=(
  $'start-session\t--target <instance-id>\tStart an interactive session on an instance'
  $'get-parameter\t--name <name>\tGet a parameter value'
  $'put-parameter\t--name <name> --value <value>\tCreate or update a parameter'
  $'describe-parameters\t\tList parameters'
  $'send-command\t--document-name <doc> --targets <targets>\tRun a command on managed instances'
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
# The overlay is a real NSPanel owned by the ai-suggest-menubar companion
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
# ai-suggest-menubar/Sources/ai-suggest-menubar/TerminalPositioner.swift),
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
  (( EPOCHREALTIME - _AI_SUGGEST_LAST_OVERLAY_SEND < _AI_SUGGEST_OVERLAY_MIN_INTERVAL )) && return
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
  payload+="\"selectedIndex\":$(( _AI_SUGGEST_INDEX - 1 )),"
  payload+="\"cursorRow\":$live_row,"
  payload+="\"cursorCol\":$live_col,"
  payload+="\"columns\":${cols},"
  payload+="\"lines\":${LINES:-30}"
  payload+="}"
  _ai_suggest_overlay_send "$payload"
}

_ai_suggest_overlay_hide() {
  _ai_suggest_overlay_send '{"hide":true}'
}

_ai_suggest_present_candidates() {
  _ai_suggest_overlay_supported && _ai_suggest_overlay_show
}

_ai_suggest_clear_display() {
  # Only worth telling the overlay to hide if something was actually shown —
  # this runs on every keystroke (via _ai_suggest_suggest_now), including
  # the common case of plain typing with nothing displayed, so skipping the
  # socket round-trip when there's nothing to hide keeps that hot path free
  # of unnecessary overhead.
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )); then
    _ai_suggest_overlay_hide
  fi
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_INDEX=0
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
    *) return 1 ;;
  esac

  local rest="${BUFFER#$tool}"
  rest="${rest## }"
  # Already past the subcommand (it has its own argument being typed) —
  # this table doesn't cover per-subcommand arguments, so back off (see
  # _ai_suggest_git_branch_match for the git-branch-argument case).
  [[ "$rest" == *' '* ]] && return 1

  local entry name hint desc
  local -a parts
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  for entry in "${table[@]}"; do
    parts=("${(@ps:\t:)entry}")
    name=$parts[1]
    [[ "$name" == "$rest"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("$tool $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("${parts[2]:-}")
    _AI_SUGGEST_DESCRIPTIONS+=("${parts[3]:-}")
    (( ${#_AI_SUGGEST_CANDIDATES} >= 9 )) && break
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
  matches=( ${rest}*(/N) )
  (( ${#matches} == 0 )) && return 1

  local dir label
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  for dir in "${matches[@]}"; do
    label="${dir%/}/"
    _AI_SUGGEST_CANDIDATES+=("$tool ${dir%/}/")
    _AI_SUGGEST_LABELS+=("$label")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("Change directory")
    (( ${#_AI_SUGGEST_CANDIDATES} >= 9 )) && break
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
  for br in "${branches[@]}"; do
    [[ "$br" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("git $subcmd $br ")
    _AI_SUGGEST_LABELS+=("$br")
    _AI_SUGGEST_HINTS+=("")
    _AI_SUGGEST_DESCRIPTIONS+=("Local branch")
    (( ${#_AI_SUGGEST_CANDIDATES} >= 9 )) && break
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
    git|kubectl|k|npm|docker|aws|terraform|tf|helm|gh|glab|gcloud) ;;
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

  local table_var
  if [[ "$partial" == -* ]]; then
    table_var="_AI_SUGGEST_${key}_FLAGS"
  else
    table_var="_AI_SUGGEST_${key}_SUBCMDS"
  fi
  (( ${+parameters[$table_var]} )) || return 1
  local -a table=("${(@P)table_var}")
  (( ${#table} > 0 )) || return 1

  local entry name
  local -a parts
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  for entry in "${table[@]}"; do
    parts=("${(@ps:\t:)entry}")
    name=$parts[1]
    [[ "$name" == "$partial"* ]] || continue
    _AI_SUGGEST_CANDIDATES+=("$tool ${(j: :)path} $name ")
    _AI_SUGGEST_LABELS+=("$name")
    _AI_SUGGEST_HINTS+=("${parts[2]:-}")
    _AI_SUGGEST_DESCRIPTIONS+=("${parts[3]:-}")
    (( ${#_AI_SUGGEST_CANDIDATES} >= 9 )) && break
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
  _ai_suggest_clear_display
  # Explicit `return 0`, not bare `return`: a zle widget function that ends
  # with non-zero status makes zle beep, and _ai_suggest_auto_enabled
  # returns non-zero precisely when suggestions are toggled off — bare
  # `return` here would carry that failure status out and ring the
  # terminal bell on every single keystroke while suggestions are disabled.
  _ai_suggest_auto_enabled || return 0

  # Known, exact data (cd targets, git branches, tool subcommands) beats
  # everything else — no guess, no round-trip — so it both answers
  # correctly and skips the AI call entirely for this buffer.
  if _ai_suggest_static_or_dynamic_match; then
    _AI_SUGGEST_INDEX=1
    _ai_suggest_present_candidates
  fi
}

# Wraps every buffer-editing widget: runs whatever was bound to $WIDGET
# before we took it over (another plugin's customization, e.g. zsh's own
# `url-quote-magic` on self-insert — see _ai_suggest_wrap_widget), falling
# back to the plain builtin (`zle .$WIDGET`) when nothing else had claimed
# it, then re-evaluates suggestions for the resulting buffer.
_ai_suggest_edit_wrapper() {
  if (( $+_AI_SUGGEST_ORIG_WIDGET[$WIDGET] )); then
    _ai_suggest_call_orig_widget $WIDGET
  else
    zle .$WIDGET
  fi
  _ai_suggest_suggest_now
}

# --- the manual, immediate trigger ------------------------------------------

_ai_suggest_trigger() {
  _ai_suggest_clear_display

  if [[ -z $BUFFER ]]; then
    zle -M "ai-suggest: dòng lệnh đang trống"
    return
  fi

  if _ai_suggest_static_or_dynamic_match; then
    _AI_SUGGEST_INDEX=1
    _ai_suggest_present_candidates
    return
  fi

  zle -M "ai-suggest: không có gợi ý cho lệnh này"
  return 1
}

# --- selection widgets --------------------------------------------------------

_ai_suggest_accept() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )); then
    # Capture the chosen candidate before clearing: _ai_suggest_clear_display
    # resets _AI_SUGGEST_CANDIDATES too, so reading it after would accept
    # an empty string.
    local chosen=$_AI_SUGGEST_CANDIDATES[$_AI_SUGGEST_INDEX]
    _ai_suggest_clear_display
    BUFFER=$chosen
    CURSOR=${#BUFFER}
    # `cd` suggestions are a flat directory listing, not a chain to walk
    # word-by-word the way "git add" -> "git add <file>" is — accepting one
    # should just complete the path and stop, not immediately pop up the
    # next directory level's list on top of it.
    [[ "$chosen" == cd\ * ]] || _ai_suggest_suggest_now
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
# These three (unlike the ones above) are well-known widget names other
# plugins/frameworks may already have bound — go through
# _ai_suggest_wrap_widget so anything already there (Powerlevel10k's
# zle-line-init, etc.) keeps running instead of being silently replaced.
_ai_suggest_wrap_widget forward-char _ai_suggest_forward_char
_ai_suggest_wrap_widget accept-line _ai_suggest_accept_line
_ai_suggest_wrap_widget zle-line-init _ai_suggest_line_init

bindkey "$AI_SUGGEST_KEY" _ai_suggest_trigger
bindkey '^I' _ai_suggest_accept          # Tab
bindkey '^[[C' _ai_suggest_forward_char  # Right arrow (xterm)
bindkey '^F' _ai_suggest_forward_char
bindkey '^[[A' _ai_suggest_prev          # Up arrow
bindkey '^[[B' _ai_suggest_next          # Down arrow
bindkey '^G' _ai_suggest_dismiss

if (( AI_SUGGEST_AUTO )); then
  local -a _ai_suggest_watched_widgets
  _ai_suggest_watched_widgets=(
    self-insert backward-delete-char delete-char
    backward-kill-word kill-word kill-line backward-kill-line
  )
  local _w
  for _w in $_ai_suggest_watched_widgets; do
    _ai_suggest_wrap_widget $_w _ai_suggest_edit_wrapper
  done
  unset _w _ai_suggest_watched_widgets
fi
