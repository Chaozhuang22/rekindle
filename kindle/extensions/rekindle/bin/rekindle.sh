#!/bin/sh
# rekindle: always-on time & weather dashboard for a jailbroken Kindle.
# Target: Kindle 7th gen (KT2), FW 5.8.x, BusyBox 1.17 ash, FBInk in /usr/bin.
#
# Usage: rekindle.sh start | stop | status | run | fetch
#   start   launch the dashboard in the background (used by KUAL)
#   stop    stop it and bring the normal Kindle UI back
#   status  print whether it is running and the last weather data
#   run     run the dashboard loop in the foreground
#   fetch   fetch weather once and print the parsed values
#
# While running, pressing the power button exits back to the Kindle UI.

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/rekindle.conf"
export TZ="$TZ_POSIX"

STATE=/tmp/rekindle
PIDFILE=$STATE/pid
WEATHER_ENV=$STATE/weather.env
LOG=$DIR/rekindle.log

FONTS=/usr/java/lib/fonts
F_BOLD=$FONTS/Amazon-Ember-Bold.ttf
F_REG=$FONTS/Amazon-Ember-Regular.ttf
F_MED=$FONTS/Amazon-Ember-Medium.ttf

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"
}

trim_log() {
	[ -f "$LOG" ] || return 0
	if [ "$(wc -c <"$LOG")" -gt 200000 ]; then
		tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	fi
}

is_running() {
	[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

# --- Weather ---------------------------------------------------------------

# Extract the body of a top-level JSON object, e.g. "current":{...}.
# Open-Meteo responses are a single line and these objects contain no nested braces.
json_obj() {
	sed -n "s/.*\"$2\":{\([^}]*\)}.*/\1/p" "$1"
}

# Scalar number from an object body.
json_num() {
	echo "$1" | sed -n "s/.*\"$2\":\(-\{0,1\}[0-9.]*\).*/\1/p"
}

# Array body (comma separated) from an object body.
json_arr() {
	echo "$1" | sed -n "s/.*\"$2\":\[\([^]]*\)\].*/\1/p"
}

# Fetch the forecast and atomically rewrite $WEATHER_ENV. Returns non-zero on failure.
fetch_weather() {
	mkdir -p "$STATE"
	tz_enc=$(echo "$TZ_IANA" | sed 's#/#%2F#g')
	url="http://api.open-meteo.com/v1/forecast?latitude=$LATITUDE&longitude=$LONGITUDE"
	url="$url&current=temperature_2m,weather_code,precipitation,is_day"
	url="$url&hourly=precipitation_probability,precipitation"
	url="$url&daily=temperature_2m_max,temperature_2m_min"
	url="$url&forecast_days=2&forecast_hours=$RAIN_LOOKAHEAD_HOURS&timezone=$tz_enc"

	json=$STATE/weather.json
	if ! curl -s -f -m 20 -o "$json.tmp" "$url"; then
		log "weather: fetch failed"
		return 1
	fi
	mv "$json.tmp" "$json"

	cur=$(json_obj "$json" current)
	hourly=$(json_obj "$json" hourly)
	daily=$(json_obj "$json" daily)

	temp=$(json_num "$cur" temperature_2m)
	code=$(json_num "$cur" weather_code)
	precip=$(json_num "$cur" precipitation)
	is_day=$(json_num "$cur" is_day)
	if [ -z "$temp" ] || [ -z "$code" ]; then
		log "weather: unexpected response: $(cut -c1-300 "$json" 2>/dev/null)"
		return 1
	fi

	tmax=$(json_arr "$daily" temperature_2m_max | cut -d, -f1)
	tmin=$(json_arr "$daily" temperature_2m_min | cut -d, -f1)

	# Per-hour series for the rain chart (hour, probability, rainy flag), the first rainy
	# hour, the hour that rainy run ends (empty if it outlasts the window), and the max probability.
	rain=$(awk -v times="$(json_arr "$hourly" time)" \
		-v probs="$(json_arr "$hourly" precipitation_probability)" \
		-v amts="$(json_arr "$hourly" precipitation)" \
		-v thr="$RAIN_PROBABILITY" '
		BEGIN {
			n = split(times, t, ","); split(probs, p, ","); split(amts, a, ",")
			hours = ""; ps = ""; wets = ""; at = ""; stop = ""; maxp = 0
			for (i = 1; i <= n; i++) {
				gsub(/"/, "", t[i]); hr = substr(t[i], 12, 5)
				pv = (p[i] == "null") ? 0 : p[i] + 0
				av = (a[i] == "null") ? 0 : a[i] + 0
				wet = (pv >= thr || av >= 0.1) ? 1 : 0
				if (pv > maxp) maxp = pv
				if (at == "" && wet) at = hr
				else if (at != "" && stop == "" && !wet) stop = hr
				sep = (i > 1) ? " " : ""
				hours = hours sep hr
				ps = ps sep sprintf("%d", pv)
				wets = wets sep wet
			}
			printf "W_HOURS=\"%s\"\nW_PROBS=\"%s\"\nW_WET=\"%s\"\n", hours, ps, wets
			printf "W_RAIN_AT=\"%s\"\nW_RAIN_END=\"%s\"\nW_RAIN_MAXP=%d\n", at, stop, maxp
		}')

	{
		echo "W_TEMP=$temp"
		echo "W_CODE=$code"
		echo "W_PRECIP=${precip:-0}"
		echo "W_IS_DAY=${is_day:-1}"
		echo "W_TMAX=$tmax"
		echo "W_TMIN=$tmin"
		echo "$rain"
		echo "W_FETCHED=$(date +%s)"
	} >"$WEATHER_ENV.tmp" && mv "$WEATHER_ENV.tmp" "$WEATHER_ENV"
	return 0
}

# Round a decimal to the nearest integer (handles negatives).
round() {
	awk -v v="$1" 'BEGIN { printf "%.0f", v }'
}

# WMO weather code -> icon name (day/night aware) and short description.
describe() {
	code=$1
	day=$2
	sfx=night
	[ "$day" = 1 ] && sfx=day
	case $code in
	0) ICON=clear-$sfx; DESC="Clear" ;;
	1) ICON=partly-$sfx; DESC="Mainly clear" ;;
	2) ICON=partly-$sfx; DESC="Partly cloudy" ;;
	3) ICON=cloudy; DESC="Overcast" ;;
	45 | 48) ICON=fog; DESC="Fog" ;;
	51 | 53 | 55) ICON=drizzle; DESC="Drizzle" ;;
	56 | 57) ICON=drizzle; DESC="Freezing drizzle" ;;
	61) ICON=rain; DESC="Light rain" ;;
	63) ICON=rain; DESC="Rain" ;;
	65) ICON=rain; DESC="Heavy rain" ;;
	66 | 67) ICON=rain; DESC="Freezing rain" ;;
	71) ICON=snow; DESC="Light snow" ;;
	73) ICON=snow; DESC="Snow" ;;
	75) ICON=snow; DESC="Heavy snow" ;;
	77) ICON=snow; DESC="Snow grains" ;;
	80) ICON=rain; DESC="Light showers" ;;
	81) ICON=rain; DESC="Showers" ;;
	82) ICON=rain; DESC="Heavy showers" ;;
	85 | 86) ICON=snow; DESC="Snow showers" ;;
	95) ICON=thunder; DESC="Thunderstorm" ;;
	96 | 99) ICON=thunder; DESC="Thunderstorm, hail" ;;
	*) ICON=cloudy; DESC="Code $code" ;;
	esac
	case $code in
	71 | 73 | 75 | 77 | 85 | 86) WET_NOW="Snowing now" ;;
	5? | 6? | 8? | 9?) WET_NOW="Raining now" ;;
	*) WET_NOW="" ;;
	esac
}

# --- Drawing ---------------------------------------------------------------

# The layout is authored on a 600x800 canvas (Kindle Basic/Touch). layout_init scales it
# uniformly to the real screen and centers it, so the same numbers work on 758x1024 and
# 1072x1448 Paperwhites. Every helper below takes canvas coordinates.
# REKINDLE_VIEW=WxH overrides the target size (testing other sizes on one device).
layout_init() {
	eval "$(fbink -e | tr ';' '\n' | grep -e '^viewWidth=' -e '^viewHeight=')"
	SCR_W=${viewWidth:-600}
	SCR_H=${viewHeight:-800}
	tw=$SCR_W th=$SCR_H
	if [ -n "$REKINDLE_VIEW" ]; then
		tw=${REKINDLE_VIEW%x*} th=${REKINDLE_VIEW#*x}
	fi
	# Scale in thousandths: the smaller of the two axis ratios, so nothing overflows.
	S=$((tw * 1000 / 600))
	[ $((th * 1000 / 800)) -lt "$S" ] && S=$((th * 1000 / 800))
	OX=$(((SCR_W - 600 * S / 1000) / 2))
	OY=$(((SCR_H - 800 * S / 1000) / 2))
}

# Canvas -> device: positions (offset + scale) and lengths (scale, at least 1 px).
px_x() { echo $((OX + $1 * S / 1000)); }
px_y() { echo $((OY + $1 * S / 1000)); }
px_len() {
	v=$(($1 * S / 1000))
	[ "$v" -lt 1 ] && v=1
	echo "$v"
}

# Text helpers: nothing is refreshed (-b); `--` lets text start with "-" (negative temperatures).
# fb_text FONT PX TOP LEFT RIGHT TEXT [extra fbink flags...]: centered in the [LEFT, 600-RIGHT] band.
fb_text() {
	font=$1 px=$(px_len "$2") top=$(px_y "$3") left=$(px_x "$4") text=$6
	right=$((SCR_W - $(px_x $((600 - $5)))))
	shift 6
	fbink -q -b -m "$@" -t regular="$font",px="$px",top="$top",left="$left",right="$right" -- "$text" >/dev/null 2>&1
}

# fb_ltext FONT PX TOP LEFT TEXT [extra fbink flags...]: left edge at LEFT.
fb_ltext() {
	font=$1 px=$(px_len "$2") top=$(px_y "$3") left=$(px_x "$4") text=$5
	shift 5
	fbink -q -b "$@" -t regular="$font",px="$px",top="$top",left="$left" -- "$text" >/dev/null 2>&1
}

# fb_rtext FONT PX TOP RIGHT_EDGE TEXT [extra fbink flags...]: right edge at RIGHT_EDGE.
# Sets RTEXT_LEFT to the text's left edge (canvas units) for placing things before it.
fb_rtext() {
	rfont=$1 rpx=$(px_len "$2") rtop=$(px_y "$3") rtext=$5
	w=$(text_width "$rfont" "$rpx" "$rtext")
	rx=$(($(px_x "$4") - ${w:-0}))
	RTEXT_LEFT=$(((rx - OX) * 1000 / S))
	shift 5
	fbink -q -b "$@" -t regular="$rfont",px="$rpx",top="$rtop",left="$rx" -- "$rtext" >/dev/null 2>&1
}

fb_rect() {
	# fb_rect TOP LEFT WIDTH HEIGHT COLOR
	fbink -q -b -B "$5" -k top="$(px_y "$1")",left="$(px_x "$2")",width="$(px_len "$3")",height="$(px_len "$4")" >/dev/null 2>&1
}

# fb_image FILE X Y W H: draw an icon scaled to W x H canvas px.
fb_image() {
	fbink -q -b -g file="$1",x="$(px_x "$2")",y="$(px_y "$3")",w="$(px_len "$4")",h="$(px_len "$5")" >/dev/null 2>&1
}

# Width in device px of TEXT at device PX in FONT, measured without drawing (fgless + bgless).
text_width() {
	fbink -q -b -O -T -E -t regular="$1",px="$2",top=0,left=0 -- "$3" 2>/dev/null |
		sed -n 's/.*lastRect_Width=\([0-9]*\).*/\1/p'
}

# Hourly rain chart on the content margins (x 40..560): one bar per forecast hour,
# height = precipitation probability, black when the hour counts as rainy, light gray
# otherwise; a dotted line marks RAIN_PROBABILITY and every third hour is labelled below.
# draw_rain_chart TOP HEIGHT
draw_rain_chart() {
	ct=$1 ch=$2
	set -- $W_PROBS
	n=$#
	[ "$n" -gt 0 ] || return 0
	pitch=$((520 / n))
	bw=$((pitch - 8))
	ty=$((ct + ch - RAIN_PROBABILITY * ch / 100))
	x=40
	while [ "$x" -lt 560 ]; do
		fb_rect "$ty" "$x" 4 2 GRAY5
		x=$((x + 10))
	done
	hrs="$W_HOURS " wets="$W_WET "
	i=0
	for p in $W_PROBS; do
		hr=${hrs%% *} hrs=${hrs#* }
		wet=${wets%% *} wets=${wets#* }
		bh=$((p * ch / 100))
		[ "$bh" -lt 3 ] && bh=3
		color=GRAYA
		[ "$wet" = 1 ] && color=BLACK
		x=$((40 + i * pitch + 4))
		fb_rect $((ct + ch - bh)) "$x" "$bw" "$bh" "$color"
		[ $((i % 3)) -eq 0 ] && fb_ltext "$F_REG" 20 $((ct + ch + 8)) $((x - 2)) "$hr" -C GRAY5
		i=$((i + 1))
	done
}

# Bottom status bar on the content margins (x 40..560, same as the divider):
# place + weather freshness on the left, battery on the right. Gray, so it stays
# below the clock and weather; the battery turns black at <=20 % when not charging.
draw_status() {
	fb_ltext "$F_REG" 22 770 40 "$1" -C GRAY5

	lvl=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
	[ -n "$lvl" ] || return 0
	charging=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
	color=GRAY5
	[ "$charging" != 1 ] && [ "$lvl" -le 20 ] && color=BLACK

	# Outline glyph: 28x14 body + 3x6 nub, right edge at x=560.
	gx=529
	fill=$((lvl * 20 / 100))
	[ "$fill" -lt 2 ] && fill=2
	fb_rect 774 "$gx" 28 14 "$color"
	fb_rect 776 $((gx + 2)) 24 10 WHITE
	fb_rect 778 $((gx + 4)) "$fill" 6 "$color"
	fb_rect 778 $((gx + 28)) 3 6 "$color"

	# Percentage right-aligned 8 px before the glyph; bolt before that while charging.
	fb_rtext "$F_REG" 22 770 $((gx - 8)) "$lvl%" -C "$color"
	if [ "$charging" = 1 ]; then
		fb_image "$DIR/icons/bolt.png" $((RTEXT_LEFT - 20)) 770 14 22
	fi
}

draw() {
	flash=$1
	now=$(date +%s)

	fbink -q -b -k >/dev/null 2>&1

	fb_text "$F_REG" 34 28 0 0 "$(date '+%A, %-d %B')"
	fb_text "$F_BOLD" 220 62 0 0 "$(date '+%H:%M')"
	fb_rect 330 40 520 3 BLACK

	if [ -f "$WEATHER_ENV" ]; then
		. "$WEATHER_ENV"
		describe "$W_CODE" "$W_IS_DAY"
		temp="$(round "$W_TEMP")°"
		hilo=""
		[ -n "$W_TMAX" ] && [ -n "$W_TMIN" ] && hilo="$(round "$W_TMAX")° / $(round "$W_TMIN")°"

		# Rain banner text when rain is falling or expected within the lookahead window.
		if [ -n "$WET_NOW" ] || awk -v p="$W_PRECIP" 'BEGIN { exit !(p > 0) }'; then
			word=Raining
			[ "$WET_NOW" = "Snowing now" ] && word=Snowing
			if [ -n "$W_RAIN_END" ] && [ "$W_RAIN_AT" = "${W_HOURS%% *}" ]; then
				rain_text="$word until $W_RAIN_END"
			else
				rain_text="$word now"
			fi
		elif [ -n "$W_RAIN_AT" ] && [ -n "$W_RAIN_END" ]; then
			rain_text="Rain $W_RAIN_AT–$W_RAIN_END"
		elif [ -n "$W_RAIN_AT" ]; then
			rain_text="Rain from $W_RAIN_AT"
		else
			rain_text=""
		fi

		if [ -n "$rain_text" ]; then
			# Rain: compact weather row, black banner, hourly chart.
			fb_image "$DIR/icons/$ICON.png" 36 352 120 120
			fb_ltext "$F_BOLD" 112 344 170 "$temp"
			fb_rtext "$F_REG" 32 366 560 "$DESC"
			[ -n "$hilo" ] && fb_rtext "$F_REG" 30 412 560 "$hilo" -C GRAY5
			fb_rect 494 40 520 64 BLACK
			fb_ltext "$F_BOLD" 38 503 60 "$rain_text" -h
			fb_rtext "$F_REG" 30 509 540 "peak $W_RAIN_MAXP%" -h
			draw_rain_chart 586 120
		else
			# Dry: nothing about rain; the weather grows into the space.
			fb_image "$DIR/icons/$ICON.png" 40 420 200 200
			fb_ltext "$F_BOLD" 160 410 270 "$temp"
			fb_ltext "$F_REG" 36 600 276 "$DESC"
			[ -n "$hilo" ] && fb_ltext "$F_REG" 32 648 276 "$hilo" -C GRAY5
		fi

		age=$((now - W_FETCHED))
		if [ "$age" -gt 7200 ]; then
			footer="$PLACE · weather offline since $(date -d "@$W_FETCHED" '+%H:%M' 2>/dev/null)"
		else
			footer="$PLACE · updated $(date -d "@$W_FETCHED" '+%H:%M' 2>/dev/null)"
		fi
	else
		fb_text "$F_MED" 40 500 0 0 "Fetching weather…"
		footer="$PLACE"
	fi

	draw_status "$footer"

	if [ "$flash" = 1 ]; then
		fbink -q -f -s >/dev/null 2>&1
	else
		fbink -q -s >/dev/null 2>&1
	fi
}

# --- Kindle UI control ------------------------------------------------------

ui_off() {
	lipc-set-prop com.lab126.powerd preventScreenSaver 1
	stop framework >/dev/null 2>&1
	# Give the framework a moment to release the screen.
	sleep 3
}

ui_on() {
	fbink -q -c -m -M -t regular="$F_MED",px=36 "Returning to Kindle…" >/dev/null 2>&1
	lipc-set-prop com.lab126.powerd preventScreenSaver 0
	start framework >/dev/null 2>&1
}

# Input device of the power button: the first device in /proc/bus/input/devices whose
# name looks like a power key (KT2: "max77696-onkey"; other models' names are expected to
# contain "pwrkey", "power" or "gpio-keys"). Falls back to event0.
power_key_device() {
	dev=$(awk '
		/^N: Name=/ { name = tolower($0) }
		/^H: Handlers=/ && name ~ /onkey|pwrkey|power|gpio-keys/ {
			if (match($0, /event[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
		}' /proc/bus/input/devices 2>/dev/null)
	echo "/dev/input/${dev:-event0}"
}

# --- Main loop -------------------------------------------------------------

run() {
	mkdir -p "$STATE"
	if is_running; then
		echo "already running (pid $(cat "$PIDFILE"))"
		return 1
	fi
	echo $$ >"$PIDFILE"
	trim_log
	log "start"

	WATCH_PID=""
	SLEEP_PID=""
	trap 'shutdown' TERM INT HUP

	ui_off
	layout_init
	log "screen ${SCR_W}x${SCR_H}, scale $S/1000"

	# Power button: read its input device directly. powerd ignores the button
	# while preventScreenSaver is set, so its screensaver events never fire.
	key_dev=$(power_key_device)
	log "power button device $key_dev"
	main_pid=$$
	(
		dd if="$key_dev" bs=16 count=1 >/dev/null 2>&1 &&
			log "power button pressed" &&
			kill -TERM "$main_pid" 2>/dev/null
	) &
	WATCH_PID=$!

	last_fetch=0
	last_ntp=0
	first=1
	while :; do
		now=$(date +%s)
		min=$(date +%M)
		min=${min#0}

		flash=0
		if [ "$first" = 1 ] || [ $((min % FULL_REFRESH_MINUTES)) -eq 0 ]; then
			flash=1
		fi
		draw "$flash"
		first=0

		if [ $((now - last_fetch)) -ge $((WEATHER_MINUTES * 60 - 30)) ]; then
			if fetch_weather; then
				last_fetch=$now
				draw 0
			fi
		fi

		if [ $((now - last_ntp)) -ge 3600 ]; then
			if ntpdate "$NTP_SERVER" >/dev/null 2>&1; then
				last_ntp=$now
			else
				log "ntp: sync with $NTP_SERVER failed"
				last_ntp=$((now - 3000)) # retry in ~10 minutes
			fi
		fi

		sec=$(date +%S)
		sec=${sec#0}
		sleep $((60 - sec)) &
		SLEEP_PID=$!
		wait "$SLEEP_PID"
	done
}

shutdown() {
	trap '' TERM INT HUP
	log "stop"
	# Children: the minute sleep and the power-button watcher (plus the watcher's dd).
	# When started via setsid we lead our own process group: signal all of it
	# (TERM is ignored here now, so this process survives).
	if [ "$(cut -d' ' -f5 /proc/$$/stat)" = "$$" ]; then
		kill -TERM -$$ 2>/dev/null
	else
		[ -n "$WATCH_PID" ] && pkill -P "$WATCH_PID" 2>/dev/null
		pkill -P $$ 2>/dev/null
	fi
	rm -f "$PIDFILE"
	ui_on
	exit 0
}

case "$1" in
start)
	if is_running; then
		echo "rekindle already running"
		exit 0
	fi
	mkdir -p "$STATE"
	setsid "$0" run >>"$LOG" 2>&1 </dev/null &
	;;
stop)
	if is_running; then
		kill -TERM "$(cat "$PIDFILE")"
	else
		echo "rekindle not running"
	fi
	;;
status)
	if is_running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "stopped"; fi
	[ -f "$WEATHER_ENV" ] && cat "$WEATHER_ENV"
	;;
run)
	run
	;;
fetch)
	fetch_weather && cat "$WEATHER_ENV"
	;;
*)
	echo "usage: $0 start|stop|status|run|fetch" >&2
	exit 2
	;;
esac
