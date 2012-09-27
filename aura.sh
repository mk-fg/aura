#!/bin/bash

## Options
interval=$(( 3 * 3600 )) # 3h
recheck=$(( 3600 )) # 1h
activity_timeout=$(( 30 * 60 )) # 30min
max_log_size=$(( 1024 * 1024 )) # 1M, current+last files are kept

gimp_cmd="nice ionice -c3 gimp"

wps_dir=~/.aura
blacklist="$wps_dir"/blacklist
log_err="$wps_dir"/picker.log
log_hist="$wps_dir"/history.log
log_curr="$wps_dir"/current
pid="$wps_dir"/picker.pid
hook_onchange="$wps_dir"/hook.onchange


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
no_fork=
no_init=
reexec=
urandom=

result=0
while [[ -n "$1" ]]; do
	case "$1" in
		-d|--daemon) action=daemon ;;
		--no-fork) no_fork=true ;;
		--no-init) no_init=true ;;
		-n|--next)
			action=break
			with_pid kill -HUP
			result=$? ;;
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
		-x)
			reexec=true
			action=daemon ;;
		-c|--current)
			action=break
			cat "$log_curr" 2>/dev/null ;;
		-h|--help)
			action=break
			cat <<EOF
Usage:
  $(basename "$0") paths...
  $(basename "$0") ( -d | --daemon ) [ --no-fork ] [ --no-init ] paths...
  $(basename "$0") [ -n | --next ] [ -b | --blacklist ] [ -k | --kill ] [ -h | --help ]

Set background image, randomly selected from the specified paths.

Optional --daemon flag starts instance in the background (unless --no-fork is
also specified), and picks/sets a new image on start (unless --no-init is specified),
and every ${interval}s afterwards.

Some options (or their one-letter equivalents) can be given instead of paths to
control already-running instance (started with --daemon flag):
  --next       cycle to then next background immediately.
  --blacklist  add current background to blacklist (skip it from now on).
  --kill       stop currently running instance.
  --current    echo current background image name
  --help       this text

Various paths and parameters are specified in the beginning of this script.

EOF
			;;
		*) break ;;
	esac
	shift
done
[[ "$action" = break ]] && exit $result


## Pre-start sanity checks
bg_paths=( "$@" )
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

# Try to use /dev/urandom, if available,
#  because $RANDOM in bash is limited to 0-32k integer range.
# Apart from hard-limit on image selection, it also introduces huge rounding bias.
which od &>/dev/null && [[ -e /dev/urandom ]]\
	&& od -An -tu4 -w4 -N4 /dev/urandom >/dev/null && urandom=true


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

## Log update with rotation
log() {
	[[ -e "$1" && "$(stat --format=%s "$1")" -gt "$max_log_size" ]] && mv "$1"{,.old}
	echo "$2" >>"$1"
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
	for dir in "${bg_paths[@]}"; do
		if [[ "$(stat --printf=%Y "$dir")" -gt "$bg_list_ts" ]]; then
			bg_list_update=true
			break
		fi
	done
	if [[ -n "$bg_list_update" ]]; then
		readarray -t bg_list < <(find "${bg_paths[@]}" -type f \( -name '*.jpg' -o -name '*.png' \))
		bg_count="${#bg_list[@]}"
	fi
	if [[ "$bg_count" -eq 0 ]]; then
		echo >&2 "Error: no bgz found in the specified paths"
		sleep_int "$recheck"
		continue
	fi

	# bg update
	ts="$(date --rfc-3339=seconds)"
	[[ -z "$no_init" ]] && err=next || err=
	while [[ "$err" = next && "$bg_count" -gt "$bg_used" ]]; do
		# Random bg selection (with some rounding bias, hopefully insignificant)
		[[ -n "$urandom" ]] && randint=$(od -An -tu4 -w4 -N4 /dev/urandom) || randint=$RANDOM
		(( bg_n=randint%(bg_count+1) ))
		bg="${bg_list[$bg_n]}"
		[[ -z "$bg" ]] && continue # not particulary good idea

		# Pop selected bg from array
		unset bg_list[$bg_n]
		(( bg_used += 1 ))

		# Blacklist check
		grep -q "^\(.*/\)\?$(basename "$bg")$" "$blacklist" && continue

		# Actual bg setting
		log "$log_err" "--- ${ts}: ${bg}"
		err=$($gimp_cmd -ib "(catch\
					(gimp-message \"WPS-ERR:gimp_error\")\
					(gimp-message-set-handler ERROR-CONSOLE)\
					(python-fu-lqr-wpset RUN-NONINTERACTIVE \"${bg}\"))\
				(gimp-quit TRUE)" 2>&1 1>/dev/null |
			tee -a "$log_err" | grep -o 'WPS-ERR:.\+')
		err="${err#*:}"
	done

	# Check for unexpected errors
	if [[ -n "$err" ]]; then
		echo >&2 "Error: Failed setting bg, see log (${log_err}) for details"
		sleep_int "$recheck"
		continue
	fi

	# Try running the hook script
	[[ -z "$no_init" && -x "$hook_onchange" ]] && "$hook_onchange"

	# History/current entry update and main cycle delay
	no_init= # reset oneshot --no-init flag
	log "$log_hist" "${ts} (id: ${bg_n}): ${bg}"
	echo "$(basename "${bg}")" >"$log_curr"
	sleep_int "$interval"
done
