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
pid="$wps_dir"/picker.pid


## Pre-start sanity checks
if [[ ${#bg_dirs[@]} -eq 0 ]]; then
	echo >&2 "Error: no bg paths specified"
	exit 1
fi
mkdir -p "$wps_dir"
[[ ! -e "$blacklist" ]] && touch "$blacklist"
echo $$ >"$pid"


## Function to select bg from bg_list and rescale/set it
bg_cycle() {
	[[ "$bg_count" -eq 0 ]] && return 1 # no bgz to choose from

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

	[[ -n "$err" ]] && return 1 || return 0
}

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
	bg_cycle

	# Check for unexpected errors
	if [[ $? -gt 0 ]]; then
		echo >&2 "Error: Failed setting bg, see log (${log_err}) for details"
		sleep_int "$recheck"
		continue
	fi

	# History entry and main cycle delay
	echo "${ts} (id: ${bg_n}): ${bg}" >>"$log_hist"
	sleep_int "$interval"
done
