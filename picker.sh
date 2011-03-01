#!/bin/bash
set +m

## Options
bg_dirs=( "$@" )

interval=$(( 3 * 3600 )) # 3h
recheck=$(( 3600 )) # 1h
activity_timeout=$(( 30 * 60 )) # 30min

gimp_cmd="nice ionice -c3 gimp"

wps_dir=~/.wps
blacklist="$wps_dir"/blacklist
log_err="$wps_dir"/picker.log
log_hist="$wps_dir"/history.log
log_curr="$wps_dir"/current
pid="$wps_dir"/picker.pid


## Oneshot actions
action=
while [[ -n "$1" ]]; do
	case "$1" in
		-d|--daemonize) action=daemonize ;;
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
	$(basename "$0") [ -d | --daemonize ] paths...
	$(basename "$0") [ -n | --next ] [ -b | --blacklist ]
	$(basename "$0") [ -k | --kill ]
	$(basename "$0") [ -h | --help ]

Set background, randomly selected from the specified paths, and change
it every ${interval}s afterwards.
Optional --daemonize flag starts instance in the background.

Some options can be given instead of paths to control already-running
instance:
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
pid_instance=$(pgrep -F "$pid")
if [[ -n "$pid_instance" ]]; then
	echo >&2 "Detected already running instance (pid: $pid_instance)"
	exit 0
fi
if [[ ${#bg_dirs[@]} -eq 0 ]]; then
	echo >&2 "Error: no bg paths specified"
	exit 1
fi
mkdir -p "$wps_dir"
[[ ! -e "$blacklist" ]] && touch "$blacklist"

if [[ "$action" = daemonize ]]; then
	setsid "$0" "$@" &
	disown
	exit 0
fi
[[ $(ps -o 'pgid=' $$) -ne $$ ]] && exec setsid "$0" "$@"

echo $$ >"$pid"


## Interruptable (by signals) sleep function hack
sleep_int() {
	sleep "$1" &
	echo $! >"$pid"
	wait $!
	local err=$?
	[[ "$err" -gt 0 ]] && kill -$(( $err - 128 )) 0
	echo $$ >"$pid"
}


## Main loop
bg_list_ts=0
bg_count=0

trap : HUP # "snap outta sleep" signal

while :; do
	# Just sleep if there's no activity
	idle_time="$(( $(xprintidle) / 1000 ))"
	if [[ "$idle_time" -gt "$activity_timeout" ]]; then
		sleep_int "$recheck"
		continue
	fi

	# Update bg_list array on dirs' mtime changes
	mtime_update=
	for dir in "${bg_dirs[@]}"; do
		if [[ "$(stat --printf=%Y "$dir")" -gt "$bg_list_ts" ]]; then
			mtime_update=true
			break
		fi
	done
	if [[ -n "$mtime_update" ]]; then
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
	while [[ "$err" = next ]]; do
		# Random bg selection
		(( bg_n=RANDOM%bg_count ))
		bg="${bg_list[$bg_n]}"

		# Blacklist check
		grep -qP "^(.*/)?$(basename $bg)$" "$blacklist" && continue

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
