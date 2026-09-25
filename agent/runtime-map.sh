#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Says how each group of processes is run: in a container, as a systemd
# service, under pm2, or from someone's shell.
#
# The process exporter reports a group's CPU and memory but not what started
# it — its template cannot see a process's cgroup, which is where that is
# written. So this reads /proc itself, groups processes exactly as the
# exporter does (the same PROCESS_GROUP_* patterns, else the program name),
# and writes one line per group:
#
#   process_runtime_info{groupname="nginx",runtime="docker"} 1
#
# The Host Overview dashboard joins that onto the group's metrics to show a
# Runtime column. Where a group runs in more than one way, the one most of
# its processes use is reported.
#
# Written to the textfile directory the host collector reads, the same way
# the backup service reports its runs.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PROC=${PROC_PATH:-/rootfs/proc}
OUT=${TEXTFILE_DIR:-/var/lib/node-textfile}/process_runtime.prom
GROUP_FILE=${PROCESS_GROUPS_FILE:-/run/process-groups.tsv}
INTERVAL=${PROCESS_RUNTIME_SECONDS:-60}

log() { echo "runtime-map: $*" >&2; }

# How a cgroup path says a process was started.
classify() {
  local cgroup="$1" unit
  case "$cgroup" in
    *kubepods*)                     echo kubernetes ;;
    */docker-*|*/docker/*|*docker.service*) echo docker ;;
    *containerd*|*/crio-*)          echo containerd ;;
    # A bare container id, which is how the cgroupfs driver and Docker
    # Desktop name them.
    *[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
                                    echo docker ;;
    *.service*)
      # pm2's own unit is pm2-<user>.service, which is worth telling apart
      # from an ordinary service.
      unit="${cgroup##*/}"; unit="${unit%%.service*}"
      case "$unit" in
        pm2*|*pm2*) echo pm2 ;;
        *)          echo systemd ;;
      esac ;;
    *.scope*|*user.slice*|*session-*) echo user ;;
    *)                              echo host ;;
  esac
}

# The same grouping the exporter does: the first PROCESS_GROUP_ pattern whose
# regular expression matches the command line, otherwise the program's name.
patterns=(); names=()
load_groups() {
  patterns=(); names=()
  [[ -r "$GROUP_FILE" ]] || return 0
  local pattern name
  while IFS=$'\t' read -r pattern name; do
    [[ -n "$pattern" && -n "$name" ]] || continue
    patterns+=("$pattern"); names+=("$name")
  done < "$GROUP_FILE"
}

collect() {
  declare -A seen=()
  local dir cmdline part cgroup group runtime i

  for dir in "$PROC"/[0-9]*; do
    [[ -r "$dir/cmdline" ]] || continue
    cmdline=""
    # Read the NUL-separated command line without spawning anything.
    while IFS= read -r -d '' part; do cmdline+="$part "; done < "$dir/cmdline" 2>/dev/null
    # No command line means a kernel thread, which the exporter skips too.
    [[ -n "$cmdline" ]] || continue

    group=""
    for i in "${!patterns[@]}"; do
      if [[ "$cmdline" =~ ${patterns[i]} ]]; then group="${names[i]}"; break; fi
    done
    if [[ -z "$group" ]]; then
      read -r group < "$dir/comm" 2>/dev/null || continue
      [[ -n "$group" ]] || continue
    fi

    # A process can exit between the listing and this read; that is normal.
    cgroup="$(tr '\n' ' ' < "$dir/cgroup" 2>/dev/null)" || continue
    [[ -n "$cgroup" ]] || continue
    runtime="$(classify "$cgroup")"
    seen["$group|$runtime"]=$(( ${seen["$group|$runtime"]:-0} + 1 ))
  done

  # One runtime per group: the one most of its processes run under, so the
  # join in the dashboard stays one-to-one.
  local key g r count best
  declare -A top=() top_count=()
  for key in "${!seen[@]}"; do
    g="${key%%|*}"; r="${key##*|}"; count="${seen[$key]}"
    best="${top_count[$g]:-0}"
    if (( count > best )); then top["$g"]="$r"; top_count["$g"]="$count"; fi
  done

  {
    echo "# HELP process_runtime_info How a group of processes is run."
    echo "# TYPE process_runtime_info gauge"
    for g in "${!top[@]}"; do
      # The group name is a label value: quotes and backslashes are escaped.
      local escaped="${g//\\/\\\\}"
      escaped="${escaped//\"/\\\"}"
      echo "process_runtime_info{groupname=\"$escaped\",runtime=\"${top[$g]}\"} 1"
    done
  } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
}

log "reporting how processes are run every ${INTERVAL}s"
while true; do
  load_groups
  collect || log "WARNING could not read $PROC this time"
  sleep "$INTERVAL"
done
