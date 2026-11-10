#!/bin/sh
# rekindle: always-on time & weather dashboard for a jailbroken Kindle.
# Target: Kindle 7th gen (KT2), FW 5.8.x, BusyBox 1.17 ash, FBInk in /usr/bin.
#
# Usage: rekindle.sh start [simplistic|train] | stop | status | run [simplistic|train] | fetch
#   start   launch the dashboard in the background (used by KUAL); the layout is the
#           current weather with an hourly rain chart when rain is due (simplistic,
#           default), or the same plus a band when TRAIN_LINE is disrupted during
#           TRAIN_HOURS (train)
#   stop    stop it and bring the normal Kindle UI back
#   status  print whether it is running (and its layout) and the last weather and train data
#   run     run the dashboard loop in the foreground
#   fetch   fetch weather and train status once and print the parsed values
#
# While running, pressing the power button exits back to the Kindle UI.

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/rekindle.conf"
# Settings added after a device's rekindle.conf was written (deploy keeps that file).
: "${LOW_POWER:=auto}"
: "${QUIET_HOURS:=}"
: "${QUIET_MINUTES:=10}"
: "${TRAIN_LINE:=JK}"
: "${TRAIN_HOURS:=6-9}"
export TZ="$TZ_POSIX"

STATE=/tmp/rekindle
RTC=/sys/class/rtc/rtc1
PIDFILE=$STATE/pid
WEATHER_ENV=$STATE/weather.env
TRAIN_ENV=$STATE/train.env
# JR East's English status page for the Kanto area (HTTPS; the KT2's curl handles it).
TRAIN_URL=https://traininfo.jreast.co.jp/train_info/e/kanto.aspx
LAYOUT_FILE=$STATE/layout
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
	url="$url&forecast_days=1&forecast_hours=$RAIN_LOOKAHEAD_HOURS&timezone=$tz_enc"

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

# --- Train status -------------------------------------------------------------

# TRAIN_HOURS ("START-END", whole hours, not wrapping past midnight) as TH_S and TH_E.
# Returns non-zero when it is malformed, which disables the train band.
train_hours() {
	case $TRAIN_HOURS in
	[0-9]-[0-9] | [0-9]-[0-9][0-9] | [0-9][0-9]-[0-9] | [0-9][0-9]-[0-9][0-9]) ;;
	*) return 1 ;;
	esac
	TH_S=${TRAIN_HOURS%-*} TH_E=${TRAIN_HOURS#*-}
	TH_S=$((${TH_S#0} + 0)) TH_E=$((${TH_E#0} + 0))
	[ "$TH_S" -lt "$TH_E" ]
}

# Hour of day without a leading zero, in TH.
train_hour() {
	TH=$(date +%H)
	TH=${TH#0}
}

# Whether the weather fetch should also fetch the train status: train layout, from an hour
# before TRAIN_HOURS (so the band is current at the start) until its end.
train_due() {
	[ "$LAYOUT" = train ] && train_hours || return 1
	train_hour
	[ "$TH" -ge $((TH_S - 1)) ] && [ "$TH" -lt "$TH_E" ]
}

# Fetch JR East's status page and atomically rewrite $TRAIN_ENV: T_STATUS (normal, delay,
# part or stop; the worst when the line is listed more than once), T_NAME (English line
# name without " Line") and T_FETCHED. The line is found by its symbol icon
# (ico_rosen_jk.svg for JK). JR lists only delays of 30 minutes or more; its "Notice"
# status counts as normal. Returns non-zero on failure.
fetch_train() {
	mkdir -p "$STATE"
	page=$STATE/train.html
	if ! curl -s -f -m 30 -o "$page.tmp" "$TRAIN_URL"; then
		log "train: fetch failed"
		return 1
	fi
	mv "$page.tmp" "$page"
	ico="ico_rosen_$(echo "$TRAIN_LINE" | tr 'A-Z' 'a-z').svg"
	tstate=$(tr -d '\r' <"$page" | awk -v ico="$ico" '
		/class="rosenBox"/ { want = 0; cls = "" }
		index($0, ico) { want = 1; next }
		want && name == "" && /class="name">/ {
			name = $0; sub(/.*class="name">/, "", name); sub(/<.*/, "", name); next
		}
		want && cls == "" && /class="status / {
			cls = $0; sub(/.*class="status /, "", cls); sub(/".*/, "", cls); next
		}
		want && cls != "" && /alt="/ {
			alt = $0; sub(/.*alt="/, "", alt); sub(/".*/, "", alt)
			# Unknown classes count as a delay: a false alarm beats a missed disruption.
			s = 1; st = "delay"
			if (cls == "normal" || cls == "info") { s = 0; st = "normal" }
			else if (cls == "adjust") { s = 3; st = "stop" }
			else if (alt ~ /[Cc]ancel/) { s = 2; st = "part" }
			if (!found || s > best) { best = s; worst = st }
			found = 1; want = 0; cls = ""
		}
		END {
			if (!found) exit 1
			sub(/ Line$/, "", name)
			printf "T_STATUS=%s\nT_NAME=\"%s\"\n", worst, name
		}')
	if [ -z "$tstate" ]; then
		log "train: $TRAIN_LINE not found on $TRAIN_URL"
		return 1
	fi
	{
		echo "$tstate"
		echo "T_FETCHED=$(date +%s)"
	} >"$TRAIN_ENV.tmp" && mv "$TRAIN_ENV.tmp" "$TRAIN_ENV"
	return 0
}

# What the train band shows now, in T_SHOW: empty (no band: other layout, outside
# TRAIN_HOURS, or running normally), delay, part, stop, or unknown (no status fetched
# within the last fetch interval plus 15 minutes). Sources $TRAIN_ENV.
train_state() {
	T_SHOW=""
	[ "$LAYOUT" = train ] && train_hours || return 0
	train_hour
	[ "$TH" -ge "$TH_S" ] && [ "$TH" -lt "$TH_E" ] || return 0
	T_STATUS="" T_NAME="" T_FETCHED=0
	[ -f "$TRAIN_ENV" ] && . "$TRAIN_ENV"
	: "${T_NAME:=$TRAIN_LINE}"
	if [ $(($(date +%s) - T_FETCHED)) -gt $((WEATHER_MINUTES * 60 + 900)) ]; then
		T_SHOW=unknown
	elif [ "$T_STATUS" != normal ]; then
		T_SHOW=$T_STATUS
	fi
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

# fb_refresh TOP LEFT WIDTH HEIGHT: refresh only this rectangle of the screen (non-flashing).
fb_refresh() {
	fbink -q -s top="$(px_y "$1")",left="$(px_x "$2")",width="$(px_len "$3")",height="$(px_len "$4")" >/dev/null 2>&1
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

# Compact current-weather row (y 344..472) used by the rain layout.
# Uses ICON, DESC, temp and hilo from draw.
draw_now_row() {
	fb_image "$DIR/icons/$ICON.png" 36 352 120 120
	fb_ltext "$F_BOLD" 112 344 170 "$temp"
	fb_rtext "$F_REG" 32 366 560 "$DESC"
	[ -n "$hilo" ] && fb_rtext "$F_REG" 30 412 560 "$hilo" -C GRAY5
}

# Rain banner: light gray band (56 tall) with the rain window in bold and the peak
# chance in gray. Text is drawn background-less (-O) so the band shows through.
# draw_rain_banner TOP
draw_rain_banner() {
	fb_rect "$1" 40 520 56 GRAYD
	fb_ltext "$F_BOLD" 34 $(($1 + 10)) 60 "$rain_text" -O
	fb_rtext "$F_REG" 28 $(($1 + 14)) 540 "peak $W_RAIN_MAXP%" -O -C GRAY5
}

# Train line symbol, as on JR station signs: a square outline around TRAIN_LINE.
# draw_train_sign LEFT TOP SIZE FILL COLOR
draw_train_sign() {
	fb_rect "$2" "$1" "$3" "$3" "$5"
	fb_rect $(($2 + 3)) $(($1 + 3)) $(($3 - 6)) $(($3 - 6)) "$4"
	fb_text "$F_BOLD" $(($3 * 60 / 100)) $(($2 + $3 * 20 / 100)) "$1" $((600 - $1 - $3)) "$TRAIN_LINE" -O -C "$5"
}

# Train band on dry days: the rain banner's gray band (52 tall) in the empty space between
# the divider and the weather, with the line symbol, "<line> <status>" in bold and a gray
# note on the right. Gray text when the status is unknown. Uses T_SHOW and T_NAME.
draw_train_band() {
	case $T_SHOW in
	delay) tw="delayed" tn="30+ min" ;;
	stop) tw="suspended" tn="" ;;
	part) tw="partly cancelled" tn="" ;;
	*) tw="unknown" tn="no update" ;;
	esac
	tcolor=BLACK
	[ "$T_SHOW" = unknown ] && tcolor=GRAY5
	fb_rect 352 40 520 52 GRAYD
	draw_train_sign 52 358 40 GRAYD "$tcolor"
	fb_ltext "$F_BOLD" 30 363 104 "$T_NAME $tw" -O -C "$tcolor"
	[ -n "$tn" ] && fb_rtext "$F_REG" 24 368 548 "$tn" -O -C GRAY5
}

# Rain banner while the train band is due: the train status takes the bold left side and
# the rain window moves to the gray right side (the chart below still shows the peak).
# draw_rain_train_banner TOP
draw_rain_train_banner() {
	case $T_SHOW in
	delay) tw="Delayed" ;;
	stop) tw="Suspended" ;;
	part) tw="Part cancelled" ;;
	*) tw="Unknown" ;;
	esac
	tcolor=BLACK
	[ "$T_SHOW" = unknown ] && tcolor=GRAY5
	fb_rect "$1" 40 520 56 GRAYD
	draw_train_sign 52 $(($1 + 8)) 40 GRAYD "$tcolor"
	fb_ltext "$F_BOLD" 32 $(($1 + 13)) 104 "$tw" -O -C "$tcolor"
	fb_rtext "$F_REG" 26 $(($1 + 17)) 540 "$rain_text" -O -C GRAY5
}

# Status bar inputs: battery level, charging, weather fetch time and whether it is stale.
# Sources $WEATHER_ENV. STATUS_KEY changes exactly when the status bar would look different.
read_status() {
	ST_FETCHED="" ST_OFFLINE=0
	if [ -f "$WEATHER_ENV" ]; then
		. "$WEATHER_ENV"
		ST_FETCHED=$W_FETCHED
		[ $(($(date +%s) - W_FETCHED)) -gt 7200 ] && ST_OFFLINE=1
	fi
	ST_LVL=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
	ST_CHG=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
	STATUS_KEY="$ST_LVL $ST_CHG $ST_FETCHED $ST_OFFLINE"
}

# Bottom status bar on the content margins (x 40..560, same as the divider):
# place + weather freshness on the left, battery on the right. Gray, so it stays
# below the clock and weather; the battery turns black at <=20 % when not charging.
# Draws from the last read_status into a cleared area.
draw_status() {
	DRAWN_STATUS=$STATUS_KEY
	footer=$PLACE
	if [ -n "$ST_FETCHED" ]; then
		when=$(date -d "@$ST_FETCHED" '+%H:%M' 2>/dev/null)
		if [ "$ST_OFFLINE" = 1 ]; then
			footer="$PLACE · weather offline since $when"
		else
			footer="$PLACE · updated $when"
		fi
	fi
	fb_ltext "$F_REG" 22 770 40 "$footer" -C GRAY5

	lvl=$ST_LVL charging=$ST_CHG
	[ -n "$lvl" ] || return 0
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

	# Percentage right-aligned 8 px before the glyph; while charging, a bolt the height of
	# the battery body 5 px before that.
	fb_rtext "$F_REG" 22 770 $((gx - 8)) "$lvl%" -C "$color"
	if [ "$charging" = 1 ]; then
		fb_image "$DIR/icons/bolt.png" $((RTEXT_LEFT - 14)) 774 9 14
	fi
}

# Bands redrawn between full redraws (canvas units, full content width): the clock text
# box (its height equals the font px) and the status bar line drawn by draw_status.
CLOCK_TOP=62 CLOCK_H=220
STATUS_TOP=770 STATUS_H=22

draw_clock() {
	fb_text "$F_BOLD" 220 $CLOCK_TOP 0 0 "$(date '+%H:%M')"
}

# Redraw and refresh only the status bar, and only when its content changed.
refresh_status() {
	read_status
	[ "$STATUS_KEY" = "$DRAWN_STATUS" ] && return 0
	fb_rect $STATUS_TOP 40 520 $STATUS_H WHITE
	draw_status
	fb_refresh $STATUS_TOP 40 520 $STATUS_H
}

# Minute tick between full redraws: clear, redraw and refresh only the clock band, and the
# status bar only when it changed; the rest of the screen is not touched.
draw_partial() {
	fb_rect $CLOCK_TOP 0 600 $CLOCK_H WHITE
	draw_clock
	fb_refresh $CLOCK_TOP 0 600 $CLOCK_H
	refresh_status
}

# draw FLASH: redraw and refresh the whole screen (FLASH=1: black flash, clears ghosting).
draw() {
	flash=$1
	read_status
	train_state
	DRAWN_TRAIN=$T_SHOW

	fbink -q -b -k >/dev/null 2>&1

	fb_text "$F_REG" 34 28 0 0 "$(date '+%A, %-d %B')"
	draw_clock
	fb_rect 330 40 520 3 BLACK

	if [ -n "$ST_FETCHED" ]; then
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
			# Rain: compact weather row, rain banner (shared with the train status), hourly chart.
			draw_now_row
			if [ -n "$T_SHOW" ]; then
				draw_rain_train_banner 494
			else
				draw_rain_banner 494
			fi
			draw_rain_chart 586 120
		else
			# Dry: nothing about rain; the weather grows into the space below the train band.
			[ -n "$T_SHOW" ] && draw_train_band
			fb_image "$DIR/icons/$ICON.png" 40 420 200 200
			fb_ltext "$F_BOLD" 160 410 270 "$temp"
			fb_ltext "$F_REG" 36 600 276 "$DESC"
			[ -n "$hilo" ] && fb_ltext "$F_REG" 32 648 276 "$hilo" -C GRAY5
		fi
	else
		[ -n "$T_SHOW" ] && draw_train_band
		fb_text "$F_MED" 40 500 0 0 "Fetching weather…"
	fi

	draw_status

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
	echo 0 >"$RTC/wakealarm" 2>/dev/null
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	lipc-set-prop com.lab126.powerd preventScreenSaver 0
	start framework >/dev/null 2>&1
}

# --- Low power ---------------------------------------------------------------
# Between minute ticks the Kindle suspends to RAM (the e-ink keeps the image at no cost)
# and an RTC alarm wakes it at the next minute. The radio is only powered for the weather
# fetch and NTP sync. LOW_POWER: auto = only on battery (while charging, stay awake and
# online so SSH works), always, never.

low_power() {
	case $LOW_POWER in
	never) return 1 ;;
	always) return 0 ;;
	esac
	[ "$ST_CHG" != 1 ]
}

# Wait up to $1 seconds for wifi to connect. Returns non-zero on timeout.
wifi_wait() {
	wtry=0
	while [ "$wtry" -lt "$1" ]; do
		sleep 1
		[ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = CONNECTED ] && return 0
		wtry=$((wtry + 1))
	done
	return 1
}

# Turn wifi on (when it is off) and wait for it to connect. Returns non-zero on timeout.
# RADIO_OFF tracks whether wifi_down switched the radio off. On a timeout the radio is
# power-cycled once and the failure is logged with wifid's last messages.
wifi_up() {
	if [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = CONNECTED ]; then
		RADIO_OFF=0
		return 0
	fi
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	RADIO_OFF=0
	wifi_wait 45 && return 0
	log "wifi: not connected after 45 s (cmState=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null))"
	grep -e wifid /var/log/messages 2>/dev/null | grep -v -e getcmState -e getprofileData | tail -n 6 | while read -r wline; do log "wifid: $wline"; done
	dmesg 2>/dev/null | grep -i -e ar600 -e wifi_card -e mmc | tail -n 4 | while read -r wline; do log "dmesg: $wline"; done
	# Cycle only on the first failures: each extra try keeps the radio on for another 45 s.
	[ "${fetch_fails:-0}" -lt 2 ] || return 1
	lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
	sleep 3
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	wifi_wait 45 && return 0
	log "wifi: still not connected after radio cycle (cmState=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null))"
	return 1
}

# Radio off. wifid unloads the ath6kl_sdio driver (and cfg80211) about 2 s after the switch,
# and the driver powers the chip down on unload. A suspend before that leaves the kernel
# believing the chip is still powered: every later load fails with "device power already
# on!" until a reboot. So wait (up to 20 s) until both modules are gone.
wifi_down() {
	lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
	RADIO_OFF=1
	wtry=0
	while [ "$wtry" -lt 20 ] && grep -q -e '^ath6kl_sdio ' -e '^cfg80211 ' /proc/modules; do
		sleep 1
		wtry=$((wtry + 1))
	done
	[ "$wtry" -lt 20 ] || log "wifi: driver still loaded 20 s after radio off"
}

# Minutes between ticks, in TICK: 1, or QUIET_MINUTES during QUIET_HOURS ("START-END" in
# hours, wrapping past midnight, e.g. 23-6). QUIET_MINUTES must be a divisor of 60 so that
# ticks and the hour boundaries line up; anything else disables quiet hours. Values are
# matched as text first: arithmetic on 08/09 is an error in BusyBox ash, and 0 divides by zero.
tick_minutes() {
	TICK=1
	case $QUIET_HOURS in
	[0-9]-[0-9] | [0-9]-[0-9][0-9] | [0-9][0-9]-[0-9] | [0-9][0-9]-[0-9][0-9]) ;;
	*) return 0 ;;
	esac
	case $QUIET_MINUTES in
	1 | 2 | 3 | 4 | 5 | 6 | 10 | 12 | 15 | 20 | 30) ;;
	*) return 0 ;;
	esac
	qs=${QUIET_HOURS%-*} qe=${QUIET_HOURS#*-}
	qs=$((${qs#0} + 0)) qe=$((${qe#0} + 0))
	qh=$(date +%H)
	qh=${qh#0}
	if [ "$qs" -le "$qe" ]; then
		[ "$qh" -ge "$qs" ] && [ "$qh" -lt "$qe" ] && TICK=$QUIET_MINUTES
	else
		{ [ "$qh" -ge "$qs" ] || [ "$qh" -lt "$qe" ]; } && TICK=$QUIET_MINUTES
	fi
	return 0
}

# Suspend until the next tick (the next minute, or the next QUIET_MINUTES boundary in quiet
# hours). Returns non-zero when it did not really sleep (no usable alarm, suspend refused,
# or woken at once by e.g. the charger): the caller then waits awake instead.
suspend_until_next_tick() {
	tick_minutes
	tmin=$(date +%M)
	sec=$(date +%S)
	tmin=${tmin#0}
	sec=${sec#0}
	delay=$(((TICK - tmin % TICK) * 60 - sec))
	[ "$delay" -ge 4 ] || return 1
	echo 0 >"$RTC/wakealarm" 2>/dev/null
	echo "+$delay" >"$RTC/wakealarm" 2>/dev/null
	[ -n "$(cat "$RTC/wakealarm" 2>/dev/null)" ] || return 1
	t0=$(date +%s)
	echo mem >/sys/power/state 2>/dev/null
	[ $(($(date +%s) - t0)) -ge 2 ] || return 1
	# The RTC and the system clock can differ by under a second: do not tick early.
	tmin=$(date +%M)
	sec=$(date +%S)
	tmin=${tmin#0}
	sec=${sec#0}
	[ $(((tmin + 1) % TICK)) -eq 0 ] && [ "$sec" -ge 55 ] && sleep $((60 - sec))
	return 0
}

# Awake wait until the next minute boundary. USR1 (a powerd event) interrupts `wait`;
# the sleep keeps running, so refresh the status bar and wait again.
wait_next_minute() {
	sec=$(date +%S)
	sec=${sec#0}
	sleep $((60 - sec)) &
	SLEEP_PID=$!
	until wait "$SLEEP_PID"; do
		kill -0 "$SLEEP_PID" 2>/dev/null || break
		refresh_status
	done
}

# Weather fetch and NTP sync, when due, inside one wifi window. Failures back off
# (1, 2, 5, 10, then 30 minutes) instead of retrying every tick. In the train layout a
# successful weather fetch is followed by the train status fetch around TRAIN_HOURS.
# Uses and updates next_fetch, next_ntp and fetch_fails; needs $now.
sync_network() {
	# Charger plugged in (or LOW_POWER=never) after a low-power stretch: radio back on.
	if [ "$RADIO_OFF" = 1 ] && ! low_power; then
		wifi_up
	fi

	fetch_due=0 ntp_due=0
	[ "$now" -ge "$next_fetch" ] && fetch_due=1
	[ "$now" -ge "$next_ntp" ] && ntp_due=1
	if [ $((fetch_due + ntp_due)) -eq 0 ]; then
		# Unplugged after an awake stretch: do not leave the radio idling until the next window.
		if low_power && [ "$RADIO_OFF" = 0 ]; then
			wifi_down
		fi
		return 0
	fi

	radio_off=0 online=1
	if low_power; then
		radio_off=1
		wifi_up || online=0
	fi

	redraw=0
	if [ "$fetch_due" = 1 ]; then
		if [ "$online" = 1 ] && fetch_weather; then
			fetch_fails=0
			next_fetch=$((now + WEATHER_MINUTES * 60 - 30))
			redraw=1
			train_due && fetch_train
		else
			fetch_fails=$((fetch_fails + 1))
			case $fetch_fails in
			1) backoff=60 ;;
			2) backoff=120 ;;
			3) backoff=300 ;;
			4) backoff=600 ;;
			*) backoff=1800 ;;
			esac
			next_fetch=$((now + backoff))
		fi
	fi
	if [ "$ntp_due" = 1 ]; then
		if [ "$online" = 1 ] && ntpdate "$NTP_SERVER" >/dev/null 2>&1; then
			next_ntp=$((now + 3600))
		else
			log "ntp: sync with $NTP_SERVER failed"
			next_ntp=$((now + 1800))
		fi
	fi

	[ "$radio_off" = 1 ] && wifi_down
	[ "$redraw" = 1 ] && draw 0
	return 0
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
	echo "$LAYOUT" >"$LAYOUT_FILE"
	trim_log
	log "start ($LAYOUT layout)"

	WATCH_PID=""
	EVENT_PID=""
	SLEEP_PID=""
	trap 'shutdown' TERM INT HUP
	# Power events (charger plugged/unplugged, battery level) redraw the status bar now
	# rather than at the next minute tick.
	trap ':' USR1

	ui_off
	layout_init
	log "screen ${SCR_W}x${SCR_H}, scale $S/1000"

	# Power button: read its input device directly. powerd ignores the button
	# while preventScreenSaver is set, so its screensaver events never fire.
	key_dev=$(power_key_device)
	log "power button device $key_dev"
	main_pid=$$
	(
		# One fd, one struct input_event (16 bytes on 32-bit ARM) at a time: type, code and
		# value start at byte 8 (hex char 25). Act only on a key press (type 1, value 1);
		# after a suspend the read can return early without an event.
		while ev=$(dd bs=16 count=1 2>/dev/null | hexdump -v -e '16/1 "%02x "' | cut -c25-); do
			case $ev in
			"01 00 "??" 00 01 00 00 00"*)
				log "power button pressed"
				kill -TERM "$main_pid" 2>/dev/null
				exit 0
				;;
			"") sleep 1 ;;
			esac
		done <"$key_dev"
	) &
	WATCH_PID=$!

	# powerd broadcasts charging, notCharging, USBPlugin, USBUnplug and battLevelChanged;
	# on any of them, poke the main loop to re-read the status.
	(
		lipc-wait-event -m com.lab126.powerd '*' 2>/dev/null |
			while read -r _; do kill -USR1 "$main_pid" 2>/dev/null || break; done
	) &
	EVENT_PID=$!

	RADIO_OFF=0
	next_fetch=0
	next_ntp=0
	fetch_fails=0
	first=1
	last_day=""
	while :; do
		set -- $(date '+%s %M %j')
		now=$1 min=${2#0} today=$3

		# Full redraw (with flash) at start and every FULL_REFRESH_MINUTES; full redraw
		# for the new date after midnight or when the train band changes (TRAIN_HOURS start
		# and end, status going stale); otherwise only the clock and changed status bar.
		train_state
		if [ "$first" = 1 ] || [ $((min % FULL_REFRESH_MINUTES)) -eq 0 ]; then
			draw 1
		elif [ "$today" != "$last_day" ] || [ "$T_SHOW" != "$DRAWN_TRAIN" ]; then
			draw 0
		else
			draw_partial
		fi
		last_day=$today
		first=0

		sync_network

		if ! { low_power && suspend_until_next_tick; }; then
			wait_next_minute
		fi
	done
}

shutdown() {
	trap '' TERM INT HUP
	log "stop"
	# Children: the minute sleep, the power-button watcher (plus its dd) and the powerd
	# event watcher (plus its lipc-wait-event). When started via setsid we lead our own
	# process group: signal all of it (TERM is ignored here now, so this process survives).
	if [ "$(cut -d' ' -f5 /proc/$$/stat)" = "$$" ]; then
		kill -TERM -$$ 2>/dev/null
	else
		[ -n "$WATCH_PID" ] && pkill -P "$WATCH_PID" 2>/dev/null
		[ -n "$EVENT_PID" ] && pkill -P "$EVENT_PID" 2>/dev/null
		pkill -P $$ 2>/dev/null
	fi
	rm -f "$PIDFILE"
	ui_on
	exit 0
}

# Layout argument for start/run: simplistic (default) or train.
layout_arg() {
	case "${1:-simplistic}" in
	simplistic | train) echo "${1:-simplistic}" ;;
	*)
		echo "unknown layout '$1' (use simplistic or train)" >&2
		exit 2
		;;
	esac
}

case "$1" in
start)
	layout=$(layout_arg "$2") || exit 2
	if is_running; then
		echo "rekindle already running"
		exit 0
	fi
	mkdir -p "$STATE"
	setsid "$0" run "$layout" >>"$LOG" 2>&1 </dev/null &
	;;
stop)
	if is_running; then
		kill -TERM "$(cat "$PIDFILE")"
	else
		echo "rekindle not running"
	fi
	;;
status)
	if is_running; then
		echo "running (pid $(cat "$PIDFILE"), $(cat "$LAYOUT_FILE" 2>/dev/null) layout)"
	else
		echo "stopped"
	fi
	[ -f "$WEATHER_ENV" ] && cat "$WEATHER_ENV"
	[ -f "$TRAIN_ENV" ] && cat "$TRAIN_ENV"
	;;
run)
	LAYOUT=$(layout_arg "$2") || exit 2
	run
	;;
fetch)
	fetch_weather && cat "$WEATHER_ENV"
	fetch_train && cat "$TRAIN_ENV"
	;;
*)
	echo "usage: $0 start [simplistic|train]|stop|status|run [simplistic|train]|fetch" >&2
	exit 2
	;;
esac
