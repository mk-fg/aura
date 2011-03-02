#!/bin/bash

## Options
interval=$(( 3 * 3600 )) # 3h
recheck=$(( 3600 )) # 1h
activity_timeout=$(( 30 * 60 )) # 30min

gimp_cmd="nice ionice -c3 gimp"

wps_dir=~/.aura
blacklist="$wps_dir"/blacklist
log_err="$wps_dir"/picker.log
log_hist="$wps_dir"/history.log
log_curr="$wps_dir"/current
pid="$wps_dir"/picker.pid


## Commanline processing
action=
no_fork=
while [[ -n "$1" ]]; do
	case "$1" in
		-d|--daemon) action=daemon ;;
		--no-fork) no_fork=true ;;
		-n|--next)
			action=break
			pkill -HUP -F "$pid" ;;
		-b|--blacklist)
			action=break
			echo "$(cat "$log_curr")" >>"$blacklist" ;;
		-bn|-nb)
			action=break
			echo "$(cat "$log_curr")" >>"$blacklist"
			pkill -HUP -F "$pid" ;;
		-k|--kill)
			action=break
			pkill -F "$pid" ;;
		-h|--help)
			action=break
			cat <<EOF
Usage:
  $(basename "$0") paths...
  $(basename "$0") ( -d | --daemon ) [ --no-fork ] paths...
  $(basename "$0") [ -n | --next ] [ -b | --blacklist ] [ -k | --kill ] [ -h | --help ]

Set background image, randomly selected from the specified paths.

Optional --daemon flag starts instance in the background (unless --no-fork is
also specified), and picks a new image every ${interval}s afterwards.

Some options can be given instead of paths to control already-running
instance (started with --daemon flag):
  --next       cycle to then next background immediately.
  --blacklist  add current background to blacklist (skip it from now on).
  --kill       stop currently running instance.
  --help       this text

Various paths and parameters are specified in the beginning of this script.

EOF
			;;
		*) break ;;
	esac
	shift
done
[[ "$action" = break ]] && exit 0


## Pre-start sanity checks
pid_instance=
[[ -e "$pid" ]] && pid_instance=$(pgrep -F "$pid")
if [[ -n "$pid_instance" ]]; then
	echo >&2 "Detected already running instance (pid: $pid_instance)"
	exit 0
fi
bg_dirs=( "$@" )
if [[ ${#bg_dirs[@]} -eq 0 ]]; then
	echo >&2 "Error: no bg paths specified"
	exit 1
fi
mkdir -p "$wps_dir"
[[ ! -e "$blacklist" ]] && touch "$blacklist"

if [[ "$action" = daemon && -z "$no_fork" ]]; then
	setsid "$0" "$@" &
	disown
	exit 0
fi
[[ $(ps -o 'pgid=' $$) -ne $$ ]] && exec setsid "$0" "$@"

echo $$ >"$pid"


## Interruptable (by signals) sleep function hack
sleep_int() {
	[[ "$action" != daemon ]] && break
	sleep "$1" &
	echo $! >"$pid"
	wait $! &>/dev/null
	local err=$(( $? - 128 ))
	[[ "$err" -gt 0 ]] && kill "-${err}" 0
	echo $$ >"$pid"
}


## Main loop
bg_list_ts=0
bg_count=0
bg_used=0

set +m
trap : HUP # "snap outta sleep" signal
trap "trap 'exit 0' TERM; pkill -g 0" EXIT # cleanup of backgrounded processes

while :; do
	# Just sleep if there's no activity
	idle_time=$(xprintidle 2>/dev/null)
	idle_time="$(( ${idle_time:-0} / 1000 ))"
	if [[ "$idle_time" -gt "$activity_timeout" ]]; then
		sleep_int "$recheck"
		continue
	fi

	# Update bg_list array on dirs' mtime changes or when it gets empty
	bg_list_update=
	if [[ "$bg_used" -eq "$bg_count" ]]; then
		bg_used=0
		bg_list_update=true
	fi
	[[ -z "$bg_list_update" ]] &&\
	for dir in "${bg_dirs[@]}"; do
		if [[ "$(stat --printf=%Y "$dir")" -gt "$bg_list_ts" ]]; then
			bg_list_update=true
			break
		fi
	done
	if [[ -n "$bg_list_update" ]]; then
		readarray -t bg_list < <(find "${bg_dirs[@]}" -type f \( -name '*.jpg' -o -name '*.png' \))
		bg_count="${#bg_list[@]}"
	fi
	if [[ "$bg_count" -eq 0 ]]; then
		echo >&2 "Error: no bgz found in the specified paths"
		sleep_int "$recheck"
		continue
	fi

	# bg update
	ts="$(date --rfc-3339=seconds)"
	err=next
	while [[ "$err" = next && "$bg_count" -gt "$bg_used" ]]; do
		# Random bg selection
		(( bg_n=RANDOM%(bg_count+1) ))
		bg="${bg_list[$bg_n]}"
		[[ -z "$bg" ]] && continue # not particulary good idea

		# Pop selected bg from array
		unset bg_list[$bg_n]
		(( bg_used += 1 ))

		# Blacklist check
		grep -qP "^(.*/)?$(basename "$bg")$" "$blacklist" && continue

		# Actual bg setting
		echo "--- ${ts}: ${bg}" >>"$log_err"
		err=$($gimp_cmd -ib '(begin
				(catch (gimp-message "WPS-ERR:gimp_error")
					(gimp-message-set-handler ERROR-CONSOLE)
					(python-fu-lqr-wpset RUN-NONINTERACTIVE "'"${bg}"'"))
				(gimp-quit TRUE))' 2>&1 1>/dev/null |
			tee -a "$log_err" | grep -oP 'WPS-ERR:\S+')
		err="${err#*:}"
	done

	# Check for unexpected errors
	if [[ -n "$err" ]]; then
		echo >&2 "Error: Failed setting bg, see log (${log_err}) for details"
		sleep_int "$recheck"
		continue
	fi

	# History/current entry update and main cycle delay
	echo "${ts} (id: ${bg_n}): ${bg}" >>"$log_hist"
	echo "$(basename "${bg}")" >"$log_curr"
	sleep_int "$interval"
done
