#!/bin/bash

### Options start

interval=$(( 3 * 3600 )) # 3h
recheck=$(( 3600 )) # 1h
activity_timeout=$(( 30 * 60 )) # 30min
max_log_size=$(( 2**20 )) # 1 MiB, current+last files are kept
monitor_count=$(xrandr --listactivemonitors 2>/dev/null | awk '/^Monitors:/ {print $2}' || echo 1)
monitor_id= # can be set to only use specific monitor id

gimp_cmd="nice ionice -c3 gimp"

wps_dir=~/.aura
favelist="$wps_dir"/favelist
blacklist="$wps_dir"/blacklist
log_err="$wps_dir"/picker.log
log_hist="$wps_dir"/history.log
log_curr="$wps_dir"/current
pid="$wps_dir"/picker.pid
hook_onchange="$wps_dir"/hook.onchange

# Cache for processed images
cache_enabled= # will be enabled if non-empty
cache_dir="$wps_dir"/cache
cache_cleanup_keep=$(( 100 * 2**20 )) # how many MiB of cached files to keep (100 MiB)
cache_cleanup_chance=8 # chance (percent) to run a cleanup routine on image change

# Resets sleep timer in daemon (if running) after oneshot script invocation
delay_daemon_on_oneshot_change=true # empty for false

# Site-local option overrides, if any
[[ -r ~/.aurarc ]] && source ~/.aurarc

### Options end


## Since pid can be re-used (and it's surprisingly common), pidfile lock is also checked
with_pid() {
	local pid_instance pid_check
	[[ ! -e "$pid" ]] && return 1
	flock -n 3 3<"$pid" && return 1
	pid_instance=$(pgrep -F "$pid")
	pid_check=$?
	if [[ -n "$1" ]]
	then
		"$@" $pid_instance
		return $?
	else return $pid_check
	fi
}

## Commanline processing
action=
force_break=
no_fork=
no_init=
reexec=
bg_paths=()

result=0
while [[ -n "$1" ]]; do
	case "$1" in
		-m|--monitor) shift; monitor_id="$1" ;;
		-m*) monitor_id="${1:2}" ;;

		-d|--daemon) action=daemon ;;
		--no-fork) no_fork=true ;;
		--no-init) no_init=true ;;

		--favepick)
			if [[ -z "$2" || ! -d "$2" ]]; then
				echo >&2 "Not a directory: $2"
				action=break force_break=true result=1
			else
				readarray -t bg_paths < <(sed 's~^[0-9]\+ ~'"${2%/}"'/~' "$favelist")
			fi ;;

		-n|--next)
			action=break
			with_pid kill -HUP
			result=$? ;;
		-f|--fave)
			action=break
			printf -v ts '%(%s)T' -1
			echo "$ts $(cat "$log_curr")" >>"$favelist" ;;
		-b|--blacklist)
			action=break
			echo "$(cat "$log_curr")" >>"$blacklist" ;;
		-bn|-nb)
			action=break
			echo "$(cat "$log_curr")" >>"$blacklist"
			with_pid kill -HUP
			result=$? ;;
		-k|--kill)
			action=break
			with_pid kill
			result=$? ;;
		-c|--current)
			action=break
			cat "$log_curr" 2>/dev/null ;;

		-x)
			reexec=true
			action=daemon ;;
		-h|--help)
			action=break force_break=true
			cat <<EOF
Usage:
  $(basename "$0") [opts] paths...
  $(basename "$0") [opts] --favepick directory
  $(basename "$0") [opts] ( -d | --daemon ) [ --no-fork ] [ --no-init ] paths...
  $(basename "$0") [ -n | --next ] [ -c | --current ] \\
    [ -f | --fave ] [ -b | --blacklist ] [ -k | --kill ] [ -h | --help ]

Set background image, randomly selected from the specified paths.
--favepick command makes it weighted-random among fave-list (see also --fave).
Blacklisted paths never get picked (see --blacklist).

--daemon command starts instance in the background (unless --no-fork is also
specified), and picks/sets a new image on start (unless --no-init is specified),
and every ${interval}s afterwards.

Some commands (or their one-letter equivalents) can be given instead of paths to
control already-running instance (started with --daemon flag):
  --next       cycle to then next background immediately.
  --fave       give +1 rating (used with --favepick) to current background image.
  --blacklist  add current background to blacklist (skip it from now on).
  --kill       stop currently running instance.
  --current    echo current background image name
  --help       this text

Options:
  -m/--monitor n  - only use specific monitor id, where 0 is the first one.

Various paths and option defaults are specified at the top of this script,
and can be overidden via site-local ~/.aurarc file.

EOF
			;;
		*) break ;;
	esac
	shift
done
[[ "$action" = break || -n "$force_break" ]] && exit $result


## Pre-start sanity checks
[[ ${#bg_paths[@]} -eq 0 ]] && bg_paths=( "$@" )
if [[ ${#bg_paths[@]} -eq 0 ]]; then
	echo >&2 "Error: no bg paths specified"
	exit 1
fi
if [[ "$action" = daemon ]] && pid_instance=$(with_pid echo); then
	echo >&2 "Detected already running instance (pid: $pid_instance)"
	exit 0
fi
mkdir -p "$wps_dir"
[[ ! -e "$blacklist" ]] && touch "$blacklist"

if [[ -z "$reexec" ]]; then
	if [[ "$action" = daemon && -z "$no_fork" ]]; then
		setsid "$0" -x "$@" &
		disown
		exit 0
	fi
	[[ $(ps -o 'pgid=' $$) -ne $$ ]] && exec setsid "$0" -x "$@"
fi

if [[ "$action" = daemon ]]; then
	touch "$pid"
	exec 3<"$pid"
	flock 3
	echo $$ >"$pid"
fi


## Interruptable and extensible (by signals) sleep function hack
trap_action= # set from trap handlers
sleep_int() {
	[[ "$action" != daemon ]] && {
		[[ -n "$delay_daemon_on_oneshot_change" ]] && with_pid kill -USR1
		return 1
	}
	sleep "$1" &
	echo $! >"$pid"
	trap_action=
	wait $! &>/dev/null
	local err=$(( $? - 128 ))
	[[ "$err" -gt 0 ]] && kill "-${err}" 0
	echo $$ >"$pid"
	# Sleep extension via recursion - hopefully this won't get too deep
	[[ "$trap_action" != timer_reset ]] || sleep_int "$interval"
	return 0
}

## Log update with rotation
log() {
	[[ -e "$1" && "$(stat --format=%s "$1")" -gt "$max_log_size" ]] && mv "$1"{,.old}
	echo "$2" >>"$1"
}

## Cache parameters
[[ -n "$cache_enabled" ]] && {
	[[ ! -e "$cache_dir" ]] && { mkdir -p "$cache_dir" || exit 1; }
	export LQR_WPSET_CACHE_DIR="$cache_dir"
	export LQR_WPSET_CACHE_SIZE="$cache_cleanup_keep"
	export LQR_WPSET_CACHE_CLEANUP="$cache_cleanup_chance"
}

## Monitors
mon_seq=0
[[ -n "$monitor_id" ]] && mon_seq=$monitor_id\
	|| { [[ $monitor_count -gt 1 ]] && mon_seq=$(seq 0 $(($monitor_count-1))); }


## Main loop
bg_list_ts=0
bg_count=0
bg_used=0

set +m
trap trap_action=next HUP # "snap outta sleep" signal
trap trap_action=timer_reset USR1 # "reset sleep" signal
trap "trap 'exit 0' TERM; pkill -g 0" EXIT # cleanup of backgrounded processes

while :; do
	# Just sleep if there's no activity
	idle_time=$(xprintidle 2>/dev/null)
	idle_time="$(( ${idle_time:-0} / 1000 ))"
	if [[ "$idle_time" -gt "$activity_timeout" ]]; then
		sleep_int "$recheck" || break
		continue
	fi

	# Update bg_list array on dirs' mtime changes or when it gets empty
	bg_list_update=
	[[ "$bg_count" -ne 0 ]] || bg_list_update=t
	[[ "$bg_used" -eq 0 ]] || {
		[[ "$(($bg_count-$bg_used))" -ge "$monitor_count" ]]\
			|| { bg_list_update=t; bg_used=0; }
		[[ -n "$bg_list_update" ]]\
			|| for dir in "${bg_paths[@]}"; do
				[[ "$(stat --printf=%Y "$dir")" -le "$bg_list_ts" ]]\
					|| { bg_list_update=t; break; }
			done
	}
	if [[ -n "$bg_list_update" ]]; then
		readarray -t bg_list < <(
			find "${bg_paths[@]}" -type f \( -name '*.jpg' -o -name '*.png' \) | shuf )
		bg_count="${#bg_list[@]}"
	fi
	if [[ "$bg_count" -eq 0 ]]; then
		echo >&2 "Error: no bgz found in the specified paths"
		sleep_int "$recheck" || break
		continue
	fi

	# bg update
	ts="$(date --rfc-3339=seconds)"
	for n in $mon_seq; do
		export LQR_WPSET_MONITOR=$n
		[[ -z "$no_init" ]] && err=next || err=
		while [[ "$err" = next ]]; do
			[[ "$bg_used" -lt "$bg_count" ]] || { err=; break; }
			bg_n=$(shuf -n1 -i 0-$(($bg_count-1)))
			bg="${bg_list[$bg_n]}"
			[[ -z "$bg" ]] && continue # not particulary good idea

			# Pop selected bg from array
			unset bg_list[$bg_n]
			(( bg_used += 1 ))

			# Blacklist check
			grep -q "^\(.*/\)\?$(basename "$bg")$" "$blacklist" && continue

			# Actual bg setting
			log "$log_err" "--- ${ts}: [monitor-${n}] ${bg}"
			err=$($gimp_cmd -ib "(catch\
						(gimp-message \"WPS-ERR:gimp_error\")\
						(gimp-message-set-handler ERROR-CONSOLE)\
						(python-fu-lqr-wpset RUN-NONINTERACTIVE \"${bg}\"))\
					(gimp-quit TRUE)" 2>&1 1>/dev/null |
				tee -a "$log_err" | grep -o 'WPS-ERR:.\+')
			err="${err#*:}"
		done
	done

	# Check for unexpected errors
	if [[ -n "$err" ]]; then
		echo >&2 "Error: Failed setting bg, see log (${log_err}) for details"
		sleep_int "$recheck" || break
		continue
	fi

	# Try running the hook script
	[[ -z "$no_init" && -x "$hook_onchange" ]] && "$hook_onchange"

	# History/current entry update and main cycle delay
	no_init= # reset oneshot --no-init flag
	log "$log_hist" "${ts} (id: ${bg_n}): ${bg}"
	echo "$(basename "${bg}")" >"$log_curr"
	sleep_int "$interval" || break
done
