#!/usr/bin/env zsh
# ai-suggest.plugin.zsh
#
# AI command suggestions, Fig/Kiro-CLI style: as you type, a debounced
# background request asks the ai-suggest-daemon for suggestions based on
# the current buffer, and this shell side sends them (plus where the cursor
# currently is) over a Unix socket to the ai-suggest-menubar companion app,
# which draws a real floating panel positioned against the terminal's
# actual on-screen location (Accessibility API) — a bordered card, one row
# per candidate, the selected row highlighted, a one-line description of it
# in the footer. Pick one from the list with Up/Down, accept with
# Tab/Right-arrow/Enter, or dismiss with Ctrl-G. Ctrl-Space (or
# $AI_SUGGEST_KEY) still asks immediately, bypassing the debounce, for when
# you don't want to wait.
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
#   AI_SUGGEST_KILL_DAEMON_ON_EXIT  1 = kill the shared ai-suggest-daemon
#                             when this shell exits (default), 0 = leave it
#                             running for other shells/sessions to reuse
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

: ${AI_SUGGEST_CLIENT_BIN:=ai-suggest-client}
: ${AI_SUGGEST_KEY:='^@'}
: ${AI_SUGGEST_HISTORY_COUNT:=5}
: ${AI_SUGGEST_AUTO:=1}
: ${AI_SUGGEST_DEBOUNCE_MS:=250}
: ${AI_SUGGEST_DEBUG:=0}
: ${AI_SUGGEST_DEBUG_LOG:=/tmp/ai-suggest-debug.log}
: ${AI_SUGGEST_STATE_FILE:=$HOME/.cache/ai-suggest/enabled}
: ${AI_SUGGEST_KILL_DAEMON_ON_EXIT:=1}
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
# _ai_suggest_overlay_show) — that's the case for history/AI suggestions,
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
typeset -gF _AI_SUGGEST_DEBOUNCE_SEC=$(( AI_SUGGEST_DEBOUNCE_MS / 1000.0 ))

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
# candidate/description/hint: backslash, double quote, and the control
# characters sanitize_field() (client.rs) doesn't already strip for
# AI-sourced text. Static-table entries are hand-written ASCII with none of
# these, so this mostly matters for AI-sourced candidates once that path is
# back on.
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
  zmodload zsh/net/socket 2>/dev/null || return
  zsocket $AI_SUGGEST_OVERLAY_SOCK 2>/dev/null || return
  print -u $REPLY -r -- "$payload" 2>/dev/null
  exec {REPLY}>&- 2>/dev/null
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

_ai_suggest_debug() {
  (( AI_SUGGEST_DEBUG )) || return
  print -r -- "[$(date '+%H:%M:%S')] $*" >> $AI_SUGGEST_DEBUG_LOG
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
  # the AI suggestion path handle it instead.
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

  # Toggled off (menu bar icon) after this request was already sent —
  # _ai_suggest_edit_wrapper's check only covers *scheduling*, not a
  # response that was already in flight when the toggle flipped, so it has
  # to be re-checked here too or a suggestion could still show up right
  # after being disabled.
  _ai_suggest_auto_enabled || return

  local -a lines
  lines=("${(@f)output}")
  lines=(${lines:#})
  (( ${#lines} == 0 )) && return

  _ai_suggest_parse_lines "${lines[@]}"
  _AI_SUGGEST_INDEX=1
  # Historical note from when suggestions were drawn as an ANSI box (now
  # removed in favor of the native overlay, see _ai_suggest_overlay_show):
  # POSTDISPLAY/region_highlight changes made from inside a zle -F callback
  # were verified NOT to reach the screen no matter which redisplay call
  # followed (zle -R, zle -I + -R, zle redisplay, zle reset-prompt all
  # tried — none worked here), a real difference from a normal widget
  # context where the same box-drawing code rendered correctly. zle -M was
  # the one thing proven to redraw reliably from this specific context, so
  # this path degraded to a plain-text one-line notice instead of the box.
  # This constraint was specific to POSTDISPLAY/zle redisplay — the overlay
  # is a plain socket write with no zle redisplay involved, so it likely
  # doesn't apply anymore, but that's untested since this whole path is
  # currently unreachable (AI suggestions off for this phase). Re-verify
  # when re-enabling AI rather than assuming either way. State is fully
  # populated either way, so Tab accepts the top suggestion immediately
  # even before this notices; pressing Up/Down/Tab runs through a normal
  # (non-async) widget invocation and upgrades to the full display then.
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

# Looks for a suggestion for the CURRENT buffer and renders it. Shared by
# every caller that just changed BUFFER and wants suggestions re-evaluated
# for the new state — a keystroke (_ai_suggest_edit_wrapper) or accepting a
# candidate (_ai_suggest_accept, so picking "git add " immediately offers
# what typically follows it, chaining word-by-word instead of going silent
# until the next keystroke).
#
# AI suggestions are intentionally OFF for this phase (see the project goal
# doc) — only the known-tool table (git/docker/kubectl/npm) ever produces a
# candidate here. _ai_suggest_schedule (the debounced AI path) is not
# called; re-enabling it is the next phase's work, not a code change buried
# in this function.
_ai_suggest_suggest_now() {
  _ai_suggest_clear_display
  # Explicit `return 0`, not bare `return`: a zle widget function that ends
  # with non-zero status makes zle beep, and _ai_suggest_auto_enabled
  # returns non-zero precisely when suggestions are toggled off — bare
  # `return` here would carry that failure status out and ring the
  # terminal bell on every single keystroke while suggestions are disabled.
  _ai_suggest_auto_enabled || return 0

  # Known-tool subcommand list (e.g. typing "git ") beats everything else:
  # it's exact, known data, not a guess, and needs no round-trip — so it
  # both answers "what are git's subcommands" correctly (an AI guess might
  # not) and skips the AI call entirely for this buffer.
  if _ai_suggest_static_match; then
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
  _ai_suggest_cancel_pending
  _ai_suggest_clear_display

  if [[ -z $BUFFER ]]; then
    zle -M "ai-suggest: dòng lệnh đang trống"
    return
  fi

  if _ai_suggest_static_match; then
    _AI_SUGGEST_INDEX=1
    _ai_suggest_present_candidates
    return
  fi

  # AI suggestions are off for this phase (see the project goal doc) — the
  # known-tool table above is the only suggestion source right now, so a
  # buffer it doesn't cover just gets an explicit "nothing here" message
  # instead of silently trying (and, previously, silently failing/timing
  # out on) an AI round-trip.
  zle -M "ai-suggest: không có gợi ý tĩnh cho lệnh này (AI đang tắt ở giai đoạn này)"
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
    _ai_suggest_cancel_pending
    _ai_suggest_suggest_now
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
    _ai_suggest_cancel_pending
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
  _ai_suggest_cancel_pending
  _ai_suggest_clear_display
  if (( $+_AI_SUGGEST_ORIG_WIDGET[accept-line] )); then
    _ai_suggest_call_orig_widget accept-line
  else
    zle .accept-line
  fi
}

_ai_suggest_line_init() {
  _ai_suggest_cancel_pending
  _ai_suggest_clear_display
  _ai_suggest_call_orig_widget zle-line-init
  _ai_suggest_query_cursor_pos
}

# Kills the shared ai-suggest-daemon when this shell exits, so it doesn't
# keep running in the background once every terminal that ever asked for a
# suggestion is closed. Safe even with other ai-suggest shells still open:
# ai-suggest-client auto-spawns a fresh daemon on its next request (see
# spawn_daemon() in client.rs) — worst case another session pays one extra
# daemon-startup on its next keystroke/Ctrl-Space.
_ai_suggest_zshexit() {
  (( AI_SUGGEST_KILL_DAEMON_ON_EXIT )) || return
  command pkill -f '/ai-suggest-daemon$' 2>/dev/null
  return 0
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

autoload -Uz add-zsh-hook
add-zsh-hook zshexit _ai_suggest_zshexit

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
