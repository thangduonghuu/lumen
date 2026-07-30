#!/usr/bin/env zsh
# ai-suggest.plugin.zsh
#
# AI command suggestions, Fig/Kiro-CLI style: as you type, a debounced
# background request asks the ai-suggest-daemon for suggestions based on
# the current buffer and renders them as a bordered card below the prompt
# (see _ai_suggest_render_box) — one row per candidate, the selected row
# highlighted, a one-line description of it in the footer. Pick one from
# the list with Up/Down, accept with Tab/Right-arrow/Enter, or dismiss with
# Ctrl-G. Ctrl-Space (or $AI_SUGGEST_KEY) still asks immediately, bypassing
# the debounce, for when you don't want to wait.
#
# This card is drawn with plain ANSI text (Unicode box-drawing + 256-color
# backgrounds) via zle -M, the standard ZLE "message area" widget mechanism
# — it is NOT a native overlay window like Fig/Amazon Q for CLI use (those
# draw outside the terminal grid entirely via OS accessibility APIs, which
# is a different kind of project from a shell plugin), so corners are drawn
# with ╭╮╰╯ rather than actually rounded/anti-aliased, and there's no drop
# shadow. Functionally equivalent, visually an approximation.
#
# --- async design notes -------------------------------------------------
# An earlier version of this plugin did as-you-type suggestions via a
# `zle -F` fd handler that branched on a `"read"` marker in $2 to detect
# success. That marker never arrives on success — zsh only ever passes a
# second argument ("hup") on error/hangup — so the success branch was dead
# code and suggestions never rendered.
#
# This version's handler (_ai_suggest_fd_handler) never branches on $2 at
# all. It unconditionally drains the fd with a blocking `cat <&$fd` the
# instant the handler fires, which is safe here specifically because
# ai-suggest-client is not streaming: it makes one non-streaming call and
# prints all output right before exiting, so by the time the pipe is
# reported readable the writer is at or near EOF and the read returns
# essentially immediately. Whether the result is usable is then decided
# from the *content* (empty or not) and *staleness* (does the buffer that
# was sent still match $BUFFER), never from the hup/read argument.
#
# Debouncing is done by killing/respawning a background job that sleeps
# before calling the client, rather than a real timer: cancelling during the
# sleep (the common case while actively typing) means the expensive client
# call never happens at all. The job is a real `&` background job (not a
# `<(...)` process substitution — that does NOT reliably set $!, verified
# empirically, so it can't be killed by PID) writing into a fifo that's
# opened for reading ahead of time; only the job holds the write end, so EOF
# propagates correctly whether it finishes normally or gets killed. A
# keystroke that arrives while the client is already mid-request (past the
# sleep) is not force-killed — its result is just ignored on arrival via the
# staleness check. That's an accepted trade-off (same one most as-you-type
# AI completions make) rather than doing process-group management.
#
# Keys:
#   Ctrl-Space (or $AI_SUGGEST_KEY)     ask AI immediately (bypasses debounce)
#   Up / Down                           cycle candidates (falls back to
#                                        normal history search when no
#                                        suggestion is shown)
#   Tab / Right-arrow (at end of line)  accept the shown suggestion
#   Ctrl-G                              dismiss the current suggestion
#
# Config (set before sourcing this file):
#   AI_SUGGEST_CLIENT_BIN     path to the ai-suggest-client binary
#                             (default: "ai-suggest-client", resolved via $PATH)
#   AI_SUGGEST_KEY            manual trigger keybinding (default: '^@', i.e. Ctrl-Space)
#   AI_SUGGEST_HISTORY_COUNT  how many recent history lines to send as
#                             context (default: 5)
#   AI_SUGGEST_AUTO           1 = automatic as-you-type suggestions (default),
#                             0 = Ctrl-Space-only, like the previous MVP
#   AI_SUGGEST_DEBOUNCE_MS    debounce window for automatic suggestions in
#                             milliseconds (default: 250)
#   AI_SUGGEST_DEBUG          set to 1 to log to $AI_SUGGEST_DEBUG_LOG

[[ -o interactive ]] || return
[[ -n $ZSH_VERSION ]] || return

: ${AI_SUGGEST_CLIENT_BIN:=ai-suggest-client}
: ${AI_SUGGEST_KEY:='^@'}
: ${AI_SUGGEST_HISTORY_COUNT:=5}
: ${AI_SUGGEST_AUTO:=1}
: ${AI_SUGGEST_DEBOUNCE_MS:=250}
: ${AI_SUGGEST_DEBUG:=0}
: ${AI_SUGGEST_DEBUG_LOG:=/tmp/ai-suggest-debug.log}

typeset -ga _AI_SUGGEST_CANDIDATES=()
typeset -ga _AI_SUGGEST_DESCRIPTIONS=()
typeset -ga _AI_SUGGEST_HINTS=()
# Explicit display text per row, decoupled from the insertable command in
# _AI_SUGGEST_CANDIDATES — e.g. for "git status " the insertable text
# includes the tool name (needed on accept), but the row should just read
# "status" since "git" is already visible in what you typed. Empty means
# "no override, fall back to the full candidate text" (see
# _ai_suggest_render_box) — that's the case for history/AI suggestions,
# which aren't a "tool subcommand" and have no shorter label to prefer.
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
)

# Background-request bookkeeping for automatic (debounced) suggestions.
typeset -g _AI_SUGGEST_PENDING_PID=
typeset -g _AI_SUGGEST_PENDING_FD=
typeset -g _AI_SUGGEST_PENDING_BUFFER=
typeset -g _AI_SUGGEST_HISTORY_MATCH=
typeset -gF _AI_SUGGEST_DEBOUNCE_SEC=$(( AI_SUGGEST_DEBOUNCE_MS / 1000.0 ))

_ai_suggest_debug() {
  (( AI_SUGGEST_DEBUG )) || return
  print -r -- "[$(date '+%H:%M:%S')] $*" >> $AI_SUGGEST_DEBUG_LOG
}

# Replaces whatever portion of region_highlight covers the POSTDISPLAY
# range (start >= $#BUFFER) with $@, leaving anything else (e.g. a syntax
# highlighter's entries for the actual typed command, start < $#BUFFER)
# untouched. This is the box's ONLY coloring mechanism — see the long
# comment on _ai_suggest_render_box for why raw ANSI codes aren't used.
_ai_suggest_set_region_highlight() {
  local -i buf_len=${#BUFFER}
  local -a kept=()
  local entry
  for entry in "${region_highlight[@]}"; do
    (( ${entry%% *} < buf_len )) && kept+=("$entry")
  done
  region_highlight=("${kept[@]}" "$@")
}

_ai_suggest_clear_display() {
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  _AI_SUGGEST_HINTS=()
  _AI_SUGGEST_LABELS=()
  _AI_SUGGEST_INDEX=0
  POSTDISPLAY=""
  _ai_suggest_set_region_highlight
}

# Matches $BUFFER against a known "<tool> <partial-subcommand>" shape and,
# if it's a tool we have a static table for (see _AI_SUGGEST_GIT_SUBCMDS),
# populates the candidate/description/hint arrays directly from it — no AI
# call involved. Only fires while still typing the subcommand itself (no
# space after it yet); once a subcommand is chosen, its own arguments are
# free-form and this table has nothing useful to say about them, so normal
# history/AI suggestions take back over.
_ai_suggest_static_match() {
  local tool="${BUFFER%% *}"
  [[ "$BUFFER" == "$tool" || "$BUFFER" == "$tool "* ]] || return 1

  local -a table
  case "$tool" in
    git) table=("${_AI_SUGGEST_GIT_SUBCMDS[@]}") ;;
    kubectl|k) table=("${_AI_SUGGEST_KUBECTL_SUBCMDS[@]}") ;;
    npm) table=("${_AI_SUGGEST_NPM_SUBCMDS[@]}") ;;
    docker) table=("${_AI_SUGGEST_DOCKER_SUBCMDS[@]}") ;;
    *) return 1 ;;
  esac

  local rest="${BUFFER#$tool}"
  rest="${rest## }"
  # Already past the subcommand (it has its own argument being typed) —
  # this table doesn't cover per-subcommand arguments, so back off and let
  # history/AI suggestions handle it instead.
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

# Renders _AI_SUGGEST_CANDIDATES as a bordered card below the prompt: one
# row per candidate (badge + the part of the command past what's already
# typed), the selected row highlighted, and a footer with that row's
# description plus a keybinding hint. Width is sized to the widest row
# needed (candidate or footer text), capped to the terminal width so it
# never wraps.
#
# Colored via region_highlight (zle's named-highlight-spec mechanism —
# "fg=NNN", "bg=NNN", the same thing zsh-syntax-highlighting uses), NOT
# raw ANSI escape codes embedded in the string, even though the latter is
# the obvious first approach (and was this function's original
# implementation, built on zle -M). Verified empirically (byte-level, via
# a real pty) that zle -M sanitizes its message: any raw ESC byte (0x1B) in
# the string arrives at the terminal as the literal two characters `^[`
# instead of being interpreted, in every configuration tested — plain
# prompt and Powerlevel10k alike — while zle's own prompt/highlight escape
# codes in the very same byte stream came through correctly. Embedding raw
# ANSI directly in POSTDISPLAY doesn't fare any better (confirmed
# separately — comes out interleaved/corrupted). region_highlight is the
# one path that reliably survives: zle generates the actual escape bytes
# itself from the spec at redraw time, so there's nothing for it to
# mis-sanitize.
#
# Because of this, the function has two halves that must stay in sync: it
# builds one PLAIN (no color codes) string for POSTDISPLAY, and in the same
# pass records region_highlight entries as (start end spec) triples, where
# start/end are absolute character offsets into BUFFER+POSTDISPLAY — i.e.
# counted from $#BUFFER, since that's where POSTDISPLAY begins on screen.
_ai_suggest_render_box() {
  (( ${#_AI_SUGGEST_CANDIDATES} == 0 )) && { POSTDISPLAY=""; _ai_suggest_set_region_highlight; return }

  local hint='Tab · ^G'
  local -i buf_len=${#BUFFER}
  local -i width=28
  (( width < ${#hint} + 12 )) && width=$(( ${#hint} + 12 ))

  local cand label hint_text
  local -a labels
  local -i idx=0
  for cand in "${_AI_SUGGEST_CANDIDATES[@]}"; do
    (( idx++ ))
    # Prefer the explicit label (see _AI_SUGGEST_LABELS) when one was set —
    # e.g. "status" rather than "git status", since "git" is already
    # visible in what you typed. Falls back to the full candidate text
    # (trailing space trimmed) for history/AI suggestions, which have no
    # shorter label. Either way this is always the FULL word, never just
    # what's left after the typed prefix (typing "git s" still shows
    # "status", not "tatus") — a row should read the same regardless of
    # how much of it you've already typed.
    label=${_AI_SUGGEST_LABELS[$idx]:-${cand%% }}
    # Static-table entries (see _ai_suggest_static_match) carry a decorative
    # argument hint, e.g. "status" -> "status [pathspec...]". Purely
    # cosmetic: accepting the row still inserts $cand as-is, not this text.
    hint_text=${_AI_SUGGEST_HINTS[$idx]:-}
    [[ -n $hint_text ]] && label="${label% }${label:+ }${hint_text}"
    labels+=("$label")
    (( ${#label} + 6 > width )) && width=$(( ${#label} + 6 ))
  done

  local -i term_cols=${COLUMNS:-80}
  local -i max_width=$(( term_cols > 8 ? term_cols - 4 : 40 ))
  (( width > max_width )) && width=$max_width

  local empty=""
  local border_line="${(l:width::─:)empty}"

  local post=$'\n'
  local -a rh=()
  local -i pos=$(( buf_len + 1 ))  # +1: the leading \n above

  local top="╭${border_line}╮"
  rh+=("$pos $(( pos + ${#top} )) fg=238")
  post+=$top
  pos+=${#top}

  local -i i=1 avail fill content_len sel row_start badge_start label_start label_end
  local pad sel_desc=""
  for label in "${labels[@]}"; do
    avail=$(( width - 5 ))
    (( avail < 4 )) && avail=4
    (( ${#label} > avail )) && label="${label:0:$((avail-1))}…"

    content_len=$(( 5 + ${#label} ))
    fill=$(( width - content_len ))
    (( fill < 0 )) && fill=0
    pad=${(l:fill:)empty}

    post+=$'\n'
    (( pos++ ))
    row_start=$pos

    post+="│"
    rh+=("$pos $((pos+1)) fg=238")
    (( pos++ ))

    sel=0
    (( i == _AI_SUGGEST_INDEX )) && sel=1

    badge_start=$pos
    post+=" \$ "
    if (( sel )); then
      rh+=("$badge_start $((badge_start+4)) bg=24")
      rh+=("$((badge_start+1)) $((badge_start+3)) bg=97,fg=255")
    else
      rh+=("$badge_start $((badge_start+4)) bg=97,fg=255")
    fi
    (( pos += 4 ))

    label_start=$pos
    post+=" ${label}${pad}"
    label_end=$(( pos + 1 + ${#label} + ${#pad} ))
    if (( sel )); then
      rh+=("$label_start $label_end bg=24,fg=255,bold")
      sel_desc=${_AI_SUGGEST_DESCRIPTIONS[$i]}
    else
      rh+=("$label_start $label_end fg=252")
    fi
    pos=$label_end

    post+="│"
    rh+=("$pos $((pos+1)) fg=238")
    (( pos++ ))

    (( i++ ))
  done

  post+=$'\n'
  (( pos++ ))
  local mid="├${border_line}┤"
  rh+=("$pos $((pos+${#mid})) fg=238")
  post+=$mid
  pos+=${#mid}

  post+=$'\n'
  (( pos++ ))

  [[ -z $sel_desc ]] && sel_desc="Tab để dùng gợi ý này"
  avail=$(( width - ${#hint} - 3 ))
  (( avail < 4 )) && avail=4
  (( ${#sel_desc} > avail )) && sel_desc="${sel_desc:0:$((avail-1))}…"
  content_len=$(( ${#sel_desc} + ${#hint} + 2 ))
  fill=$(( width - content_len ))
  (( fill < 1 )) && fill=1
  pad=${(l:fill:)empty}

  post+="│"
  rh+=("$pos $((pos+1)) fg=238")
  (( pos++ ))

  post+=" "
  (( pos++ ))

  rh+=("$pos $((pos+${#sel_desc})) fg=244")
  post+=$sel_desc
  pos+=${#sel_desc}

  post+=$pad
  pos+=${#pad}

  rh+=("$pos $((pos+${#hint})) fg=240")
  post+=$hint
  pos+=${#hint}

  post+=" "
  (( pos++ ))

  post+="│"
  rh+=("$pos $((pos+1)) fg=238")
  (( pos++ ))

  post+=$'\n'
  (( pos++ ))
  local bot="╰${border_line}╯"
  rh+=("$pos $((pos+${#bot})) fg=238")
  post+=$bot

  POSTDISPLAY=$post
  _ai_suggest_set_region_highlight "${rh[@]}"
}

# --- background request lifecycle (shared by manual + automatic paths) -----

# Cancels/cleans up any in-flight or pending automatic request. Safe to call
# when nothing is pending.
_ai_suggest_cancel_pending() {
  if [[ -n $_AI_SUGGEST_PENDING_FD ]]; then
    zle -F $_AI_SUGGEST_PENDING_FD
    exec {_AI_SUGGEST_PENDING_FD}<&- 2>/dev/null
  fi
  # Guard against a malformed/empty PID: kill'ing "0" would signal the
  # *entire foreground process group*, not a specific job. Only kill things
  # that look like an actual positive PID.
  if [[ -n $_AI_SUGGEST_PENDING_PID && $_AI_SUGGEST_PENDING_PID == <->  && $_AI_SUGGEST_PENDING_PID != 0 ]]; then
    kill $_AI_SUGGEST_PENDING_PID 2>/dev/null
  fi
  _AI_SUGGEST_PENDING_PID=
  _AI_SUGGEST_PENDING_FD=
  _AI_SUGGEST_PENDING_BUFFER=
}

_ai_suggest_fd_handler() {
  local fd=$1
  zle -F $fd
  local output
  output=$(command cat <&$fd 2>/dev/null)
  exec {fd}<&- 2>/dev/null

  # Superseded by a newer request already (its cleanup already ran) — ignore.
  [[ $fd == $_AI_SUGGEST_PENDING_FD ]] || return
  local sent_buffer=$_AI_SUGGEST_PENDING_BUFFER
  _AI_SUGGEST_PENDING_FD=
  _AI_SUGGEST_PENDING_PID=
  _AI_SUGGEST_PENDING_BUFFER=

  _ai_suggest_debug "auto: received for buffer='$sent_buffer' raw=${(qq)output}"

  # Buffer moved on since this request was sent — result is stale, discard.
  [[ $sent_buffer == $BUFFER ]] || return

  local -a lines
  lines=("${(@f)output}")
  lines=(${lines:#})
  (( ${#lines} == 0 )) && return

  _ai_suggest_parse_lines "${lines[@]}"
  _AI_SUGGEST_INDEX=1
  # Not _ai_suggest_render_box here: verified empirically (a handler that
  # logs every step, POSTDISPLAY included) that POSTDISPLAY/region_highlight
  # changes made from inside a zle -F callback do NOT reach the screen no
  # matter which redisplay call follows (zle -R, zle -I + -R, zle redisplay,
  # zle reset-prompt all tried — none worked here) — a real difference from
  # a normal widget context, where the exact same box-drawing code (manual
  # trigger, the instant history-match path) renders correctly. zle -M is
  # the one thing proven to redraw reliably from this specific context, so
  # this path degrades to a plain-text one-line notice instead of the box.
  # State is fully populated either way, so Tab accepts the top suggestion
  # immediately even though the box itself isn't shown yet; pressing
  # Up/Down/Tab runs through a normal (non-async) widget invocation and
  # upgrades to the real box right then.
  _ai_suggest_notify_async
}

# Async-safe (see _ai_suggest_fd_handler) stand-in for the box: a single
# plain-text zle -M line, since coloring it hits the same dead end the box
# itself did (verified: zle -M does not interpret raw ANSI OR %F{...}-style
# prompt color codes — both come out as literal text — so there is no
# colored option here, only plain).
_ai_suggest_notify_async() {
  (( ${#_AI_SUGGEST_CANDIDATES} == 0 )) && return
  local top=$_AI_SUGGEST_CANDIDATES[1]
  local -i buf_len=${#BUFFER}
  local label=$top
  [[ "${top:0:$buf_len}" == "$BUFFER" && ${#top} -gt $buf_len ]] && label=${top:$buf_len}
  zle -M "ai-suggest: ${#_AI_SUGGEST_CANDIDATES} gợi ý — ${BUFFER}${label} — Tab dùng, ↑/↓ xem thêm"
  zle -R
  _ai_suggest_debug "notify_async: done"
}

# ai-suggest-client prints one candidate per line as `command<TAB>description`
# (description may be empty). Splits that into the two parallel global
# arrays the renderer reads.
_ai_suggest_parse_lines() {
  _AI_SUGGEST_CANDIDATES=()
  _AI_SUGGEST_DESCRIPTIONS=()
  local line
  local -a parts
  for line in "$@"; do
    # The `p` flag is required for `\t` in the (s:...:) delimiter to be
    # interpreted as an actual tab — plain (s:\t:) takes it as the two
    # literal characters backslash+t instead (verified empirically: (s:...:)
    # does not expand backslash escapes or $variables in its argument).
    parts=("${(@ps:\t:)line}")
    _AI_SUGGEST_CANDIDATES+=("$parts[1]")
    _AI_SUGGEST_DESCRIPTIONS+=("${parts[2]:-}")
  done
}

# Schedules a debounced automatic request for the current buffer, cancelling
# any previous pending one first (this *is* the debounce: a keystroke that
# arrives during the sleep below kills it before the client ever runs).
_ai_suggest_schedule() {
  _ai_suggest_cancel_pending
  [[ -z $BUFFER ]] && return

  local -a history_args
  history_args=(${(f)"$(fc -ln -${AI_SUGGEST_HISTORY_COUNT} 2>/dev/null)"})

  # A plain `<(...)` process substitution does NOT reliably populate $! in
  # zsh, so it can't be killed by PID (verified empirically — it stays 0).
  # Instead: a real `&` background job (whose $! IS reliable) writes into a
  # fifo we've already opened for reading; unlinking right after opening
  # keeps only the two live fds around, no stray path to clean up. Because
  # we hold ONLY a read fd (never `<>` read-write) and the job holds the
  # only write fd, EOF propagates correctly the instant the job exits —
  # whether it finished normally or was killed.
  local fifo="${TMPDIR:-/tmp}/ai-suggest-$$-${RANDOM}.fifo"
  command mkfifo "$fifo" 2>/dev/null || return

  # `exec` into the client as the sleep's tail command: it replaces the
  # subshell's process image in place (same PID) instead of forking a
  # grandchild, so $_AI_SUGGEST_PENDING_PID keeps pointing at whatever is
  # actually running — the sleep, or later the real client process — and
  # `kill` in _ai_suggest_cancel_pending reliably reaches it either way.
  {
    sleep $_AI_SUGGEST_DEBOUNCE_SEC
    exec "$AI_SUGGEST_CLIENT_BIN" "$BUFFER" "$PWD" "${history_args[@]}" 2>>$AI_SUGGEST_DEBUG_LOG
  } > "$fifo" &!
  # `&!` backgrounds and disowns in one step, which (unlike plain `&` +
  # `disown`) also suppresses the "[1] 12345" job-start line zsh would
  # otherwise print into the middle of the current input line.
  _AI_SUGGEST_PENDING_PID=$!

  local fd
  exec {fd}< "$fifo"
  command rm -f "$fifo"

  _AI_SUGGEST_PENDING_FD=$fd
  _AI_SUGGEST_PENDING_BUFFER=$BUFFER
  zle -F $fd _ai_suggest_fd_handler
}

# Instant (in-process, no subprocess) fallback: most-recent history entry
# that starts with the current buffer, plain prefix comparison (BUFFER may
# contain glob metacharacters that must not be pattern-matched — same
# reasoning as _ai_suggest_render_box). This exists because the AI
# roundtrip (network + local-model inference) can easily take seconds,
# which is longer than most typing pauses; without this, the card would
# almost never appear except when the user stops typing entirely for
# several seconds. Bounded to the last 2000 history events so a huge
# HISTSIZE can't make every keystroke pay for a full-history scan.
_ai_suggest_history_match() {
  _AI_SUGGEST_HISTORY_MATCH=
  [[ -z $BUFFER ]] && return
  local buf_len=${#BUFFER}
  local -i i floor=$(( HISTCMD - 2000 ))
  (( floor < 1 )) && floor=1
  local entry
  for (( i = HISTCMD; i >= floor; i-- )); do
    entry=$history[$i]
    [[ -z $entry || $entry == "$BUFFER" ]] && continue
    if [[ "${entry:0:$buf_len}" == "$BUFFER" ]]; then
      _AI_SUGGEST_HISTORY_MATCH=$entry
      return
    fi
  done
}

# Wraps every buffer-editing builtin widget: runs the real builtin (via
# `zle .$WIDGET`, using zsh's own record of which widget we were invoked
# as), clears any now-stale ghost text, shows an instant history-based
# suggestion if one matches (see _ai_suggest_history_match), then schedules
# a debounced AI request that will override it if a better answer arrives
# in time.
_ai_suggest_edit_wrapper() {
  zle .$WIDGET
  _ai_suggest_clear_display

  # Known-tool subcommand list (e.g. typing "git ") beats everything else:
  # it's exact, known data, not a guess, and needs no round-trip — so it
  # both answers "what are git's subcommands" correctly (an AI guess might
  # not) and skips the AI call entirely for this buffer.
  if _ai_suggest_static_match; then
    _AI_SUGGEST_INDEX=1
    _ai_suggest_render_box
    return
  fi

  _ai_suggest_history_match
  if [[ -n $_AI_SUGGEST_HISTORY_MATCH ]]; then
    _AI_SUGGEST_CANDIDATES=($_AI_SUGGEST_HISTORY_MATCH)
    _AI_SUGGEST_DESCRIPTIONS=('Từ lịch sử lệnh')
    _AI_SUGGEST_HINTS=('')
    _AI_SUGGEST_INDEX=1
    _ai_suggest_render_box
  fi
  _ai_suggest_schedule
}

# --- the manual, immediate trigger ------------------------------------------

_ai_suggest_trigger() {
  _ai_suggest_cancel_pending
  _ai_suggest_clear_display

  if [[ -z $BUFFER ]]; then
    zle -M "ai-suggest: dòng lệnh đang trống"
    return
  fi

  if _ai_suggest_static_match; then
    _AI_SUGGEST_INDEX=1
    _ai_suggest_render_box
    return
  fi

  if ! command -v "$AI_SUGGEST_CLIENT_BIN" >/dev/null 2>&1; then
    zle -M "ai-suggest: không tìm thấy '$AI_SUGGEST_CLIENT_BIN' trong \$PATH"
    _ai_suggest_debug "trigger: client_bin '$AI_SUGGEST_CLIENT_BIN' not found on PATH"
    return 1
  fi

  zle -M "ai-suggest: đang hỏi AI..."
  zle -R

  local -a history_args
  history_args=(${(f)"$(fc -ln -${AI_SUGGEST_HISTORY_COUNT} 2>/dev/null)"})

  _ai_suggest_debug "trigger: buffer='$BUFFER' cwd=$PWD"

  local -a lines
  lines=("${(@f)$("$AI_SUGGEST_CLIENT_BIN" "$BUFFER" "$PWD" "${history_args[@]}" 2>>${AI_SUGGEST_DEBUG_LOG})}")
  # command substitution can leave one trailing empty element if stdout ended
  # with a newline; drop blank lines.
  lines=(${lines:#})

  _ai_suggest_debug "trigger: received ${#lines} line(s): ${(j:; :)lines}"

  if (( ${#lines} == 0 )); then
    zle -M "ai-suggest: không có gợi ý (kiểm tra daemon/ollama, hoặc AI_SUGGEST_DEBUG=1)"
    return 1
  fi

  _ai_suggest_parse_lines "${lines[@]}"
  _AI_SUGGEST_INDEX=1
  _ai_suggest_render_box
}

# --- selection widgets --------------------------------------------------------

_ai_suggest_accept() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )); then
    BUFFER=$_AI_SUGGEST_CANDIDATES[$_AI_SUGGEST_INDEX]
    CURSOR=${#BUFFER}
    _ai_suggest_cancel_pending
    _ai_suggest_clear_display
  else
    zle .expand-or-complete
  fi
}

_ai_suggest_forward_char() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )) && (( CURSOR == ${#BUFFER} )); then
    _ai_suggest_accept
  else
    zle .forward-char
  fi
}

_ai_suggest_next() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 1 )); then
    (( _AI_SUGGEST_INDEX = _AI_SUGGEST_INDEX % ${#_AI_SUGGEST_CANDIDATES} + 1 ))
    _ai_suggest_render_box
  else
    zle .down-line-or-history
  fi
}

_ai_suggest_prev() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 1 )); then
    (( _AI_SUGGEST_INDEX = (_AI_SUGGEST_INDEX - 2 + ${#_AI_SUGGEST_CANDIDATES}) % ${#_AI_SUGGEST_CANDIDATES} + 1 ))
    _ai_suggest_render_box
  else
    zle .up-line-or-history
  fi
}

_ai_suggest_dismiss() {
  if (( ${#_AI_SUGGEST_CANDIDATES} > 0 )); then
    _ai_suggest_cancel_pending
    _ai_suggest_clear_display
  else
    zle .send-break
  fi
}

_ai_suggest_accept_line() {
  _ai_suggest_cancel_pending
  _ai_suggest_clear_display
  zle .accept-line
}

_ai_suggest_line_init() {
  _ai_suggest_cancel_pending
  _ai_suggest_clear_display
}

# --- registration --------------------------------------------------------

zle -N _ai_suggest_trigger
zle -N _ai_suggest_accept
zle -N _ai_suggest_next
zle -N _ai_suggest_prev
zle -N _ai_suggest_dismiss
zle -N forward-char _ai_suggest_forward_char
zle -N accept-line _ai_suggest_accept_line
zle -N zle-line-init _ai_suggest_line_init

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
    zle -N $_w _ai_suggest_edit_wrapper
  done
  unset _w _ai_suggest_watched_widgets
fi
