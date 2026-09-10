# Shared validation and privacy-safe diagnostics for ws-browser and ws-open.
# Only these fixed events may cross into the journal. Never log argv, URLs,
# native/bridge output, page titles, workspace names, or session names.
ws_browser_log() {
  case "${1:-}" in
    adapter-normal-launch|adapter-private-launch|adapter-new-window|adapter-route|adapter-invalid-invocation|exec-failed|\
    route-invalid-url|route-origin-pane|route-origin-window|route-new-window|route-opened-group-requested|route-opened-ungrouped|\
    group-name-too-long|group-color-unavailable|\
    fallback-missing-hyprctl|fallback-missing-jq|fallback-missing-tmux|fallback-tmux-session|fallback-local-clients|fallback-local-workspace|fallback-no-session|\
    fallback-client-activity|fallback-remote-client|fallback-active-workspace|fallback-workspace-lookup|fallback-special-workspace|\
    fallback-window-query|fallback-target-inactive|fallback-multiple-windows|fallback-window-changed|\
    fallback-bridge-unavailable|fallback-bridge-timeout|fallback-bridge-no-window|fallback-bridge-ambiguous-window|\
    fallback-bridge-invalid-request|fallback-bridge-create-failed|fallback-bridge-error) ;;
    *) return 0 ;;
  esac
  # A separate logger process keeps the URL-bearing launcher's argv out of
  # journald's _CMDLINE metadata. Bound delivery; logging cannot block opening.
  timeout 0.2s logger --socket-errors=off --tag ws-browser -- \
    "request=$$ event=$1" >/dev/null 2>&1 || :
}

ws_browser_valid_url() {
  (( $# == 1 )) || return 1
  [[ -n $1 ]] && (( ${#1} <= 4096 )) || return 1
  [[ $1 =~ ^[hH][tT][tT][pP][sS]?:// ]] || return 1
  [[ "$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177')" == "$1" ]]
}

ws_browser_exec() {
  # Successful exec preserves native launch semantics and exit status. Only an
  # exec failure returns here; a launch event is an attempt, not GUI readiness.
  shopt -s execfail
  exec "$@"
  local status=$?
  ws_browser_log exec-failed
  exit "$status"
}
