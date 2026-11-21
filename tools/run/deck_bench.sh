#!/usr/bin/env bash
# deck_bench.sh: measures a 1-player Grand Prix race of an installed mkw-recomp on a Steam Deck, the same way every
# time, so the 1-player frame-rate work (docs/project/roadmap.md, section 1) has Deck numbers to go on.
#
# Why: every Deck number so far came from one contributor's runs taken by hand. Two runs of one build differ by up to
# 12 ms a frame (tools/run/ab.py), throttled stretches were filtered by hand, and MKW_AB silently compares A with A
# when the race's world clock never starts (runtime/core/diag/perf.c rt_ab). So the switches are compared inside one
# run (MKW_AB, a plain run and its inverted twin) through MKW_QUICK_RACE, whose race starts the world clock, at
# MKW_FPS=60 so the game's pacing does not hide a change (at ~30 fps that runs the game at about 0.5x: expected);
# clocks, power, CPU load and temperature are sampled beside each run, and each A/B checks that its switch engaged.
#
# Runs, in this order (about 4.5 minutes each: boot, menus at turbo speed, RACE_SECS of race, a pause):
#   base            the frame's breakdown (MKW_TRACE_TL) at MKW_FPS=60; also warms the pipeline cache for the A/Bs
#   own             the player's own settings, untouched (MKW_FPS, quality, frame generation...): the experience
#   ab-*            each switch of AB_PAIRS below at ab, a plain run and its inverted twin: the changes not yet measured
#                   (all off by default in the build, so A is today's behaviour)
#   ab-known-*      only with --only ab-known: the pairs already measured twice on a Deck (MKW_REPLAY_PAR, MKW_QUEUE_WAITS,
#                   MKW_REPLAY_CORE), to check them again on a new build
#   dc-*            only with --only dc: MKW_DRAW_CACHE=0 and 1 in the order 0 1 1 0 (read once at start, so separate
#                   runs): descriptor sets kept across frames by their contents, 'left for slower CPUs' (roadmap) and never
#                   measured on a Deck; it hung once in four runs on an RX 9070 XT (#592)
#   hang-*          only with --only hang: whether a stable pstate switch mid-race hangs a Steam Deck (one did, 19/11/2026):
#                   MKW_GPU_CLOCKS=ab every 2 s without and with MKW_PSTATE_DRAIN, and the peak held from the start, two
#                   runs each, with per-draw breadcrumbs (MKW_GPU_CRUMBS_DRAW). A hang resets the GPU: only on purpose
#   res540          the scene at 540 lines with FSR 1 to the screen, at MKW_FPS=60: the GPU's share at a lower load
#   fg-off, fg-2    MKW_FPS=30 with frame generation off, then 2x (60 shown); fg-3 (90 shown) too on an OLED
#   preset-*        only with --preset: quality Low against Console in the order L C C L, at MKW_FPS=60
#   diag-host       only with --only diag: MKW_HOST_TIME, the time each runtime call takes on the game's threads (the
#                   render thread's share of the frame that is ours, not the game's), census of the race window
#   diag-crit       only with --only diag: MKW_CRIT over 10 s of race with MKW_TRACE=sched, for tools/run/crit_path.py
#                   (which thread and state holds each frame: running, waiting for a core, a host call, a wake)
#   diag-ops        only with --only diag: MKW_TRACE=perf,draw, the replay thread's time by op and prepare_draw by stage
#   diag-wb         only with --only diag: MKW_WB_CENSUS, the write-back of what the GPU wrote, between the GPU's end and
#                   the game's release (3.1-3.2 ms a frame on a Deck, 20/11/2026)
# All runs but own use the Low quality rows (the preset of every published Deck number) and pin the display rows
# (720 lines, no frame generation, no mods, no overlay); --keep-quality keeps the player's quality and display rows.
#
# Needs: a Steam Deck in Desktop Mode, on AC power, with the game set up by this AppImage (start it once normally
# after an update), Steam's performance settings at their defaults (no TDP limit, no manual GPU clock, no frame
# limit). In the save, Smart Steering and Auto-Accelerate on: without them the kart holds A into the walls
# (tools/run/README.md, race.sh). No root, repository or Python. Results: ~/mkw-bench/<date>/ (a log per run,
# samples.csv, report.txt, sysinfo.txt) and a .tar.gz of it, read on a PC with tools/run/ab.py, summary.py, gpucmp.py.
#
# Usage: bash deck_bench.sh [--appimage PATH] [--only base,own,ab,ab-known,res540,fg,preset,diag,dc,hang] [--preset]
#                           [--keep-quality]
#                           [--race-secs N] [--dry-run]
set -uo pipefail   # no -e: the script decides itself what stops it

RACE_SECS=100        # 8 A/B blocks of 12 s (wall time from the race's start); a Grand Prix race lasts longer
AB_SECS=12
RUN_TIMEOUT=600      # boot, menus and race; a run that never reaches the race stops the bench (see run)
COOL_SECS=30         # between runs, so each starts from a similar temperature
ONLY="base,own,ab,res540,fg"
APPIMAGE=""
DRY=0
QUALITY=low
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/mkw-recomp   # where AppRun installs mkw (tools/build/release.py APPRUN)
# The switches the ab runs measure: run name, switch, what B is. Each must log 'in the B blocks ... (MKW_<NAME>' when
# set to ab, or the pair is reported void. A switch given as MKW_<NAME>=<value> is set as is (a B-block value such as
# MKW_SPLIT_US_B, which logs no such line: not checked).
# Words after the switch are set as is in both runs (what the pair needs in A and B alike).
AB_PAIRS=(   # MKW_WB_EARLY_PAR three times, on top of the profile's MKW_WB_EARLY: ~0.9 ms expected, scene term 3-6 ms
  "ab-wb-early-par-1:MKW_WB_EARLY_PAR:B = early write-back passes split over two threads"
  "ab-wb-early-par-2:MKW_WB_EARLY_PAR:B = early write-back passes split over two threads"
  "ab-wb-early-par-3:MKW_WB_EARLY_PAR:B = early write-back passes split over two threads"
)
AB_KNOWN=(
  "ab-known-replay-par:MKW_REPLAY_PAR:B = chunked recording on; Deck default off"
  "ab-known-queue-waits:MKW_QUEUE_WAITS:B = queue ordering on, the default; A = off, not shippable (#430)"
  "ab-known-replay-core:MKW_REPLAY_CORE:B = replay thread alone on a core; the Deck profile's default"
)

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "$*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --appimage) APPIMAGE=${2:?--appimage needs a path}; shift 2 ;;
    --only) ONLY=${2:?--only needs a list}; shift 2 ;;
    --preset) ONLY="$ONLY,preset"; shift ;;
    --keep-quality) QUALITY=own; shift ;;
    --race-secs) RACE_SECS=${2:?--race-secs needs seconds}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (--help lists them)" ;;
  esac
done
case "$RACE_SECS" in ''|*[!0-9]*) die "--race-secs must be a whole number of seconds" ;; esac
want() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# As root (sudo) HOME is /root, where the game was never installed: the player's own user runs it
[ "$(id -u)" = 0 ] && die "run this script as your own user, without sudo (as root it looks for the game in $HOME)"
pgrep -x mkw >/dev/null 2>&1 && die "mkw-recomp is already running: close it first"
[ -x "$DATA/mkw" ] || die "no $DATA/mkw: start the game once from its AppImage first"

# ---- the AppImage the player plays with. Every AppImage copies its mkw into $DATA at each start (AppRun), so the
# one whose mkw is byte-identical to $DATA/mkw is the one started last: chosen by content, not by date, which picked
# a download never started or the in-app update's .mkw-recomp-update/ file (launcher_update.cpp) instead. Candidates:
# --appimage; the path the start screen records for its URL handler (~/.local/share/applications/
# mkw-recomp-url.desktop, launcher.cpp); Steam's non-Steam shortcuts; then any *mkw*.AppImage under home and the cards.
is_appimage() { [ -f "$1" ] && [ -x "$1" ] && [ "$(od -An -tx1 -j8 -N3 "$1" 2>/dev/null | tr -d ' \n')" = 414902 ]; }
mkw_matches() {   # FILE: 0 its mkw is the installed one, 1 another, 2 could not be read
  local t rc=2
  t=$(mktemp -d)
  if (cd "$t" && "$1" --appimage-extract mkw >/dev/null 2>&1) && [ -f "$t/squashfs-root/mkw" ]; then
    cmp -s "$t/squashfs-root/mkw" "$DATA/mkw" && rc=0 || rc=1
  fi
  rm -rf "$t"
  return $rc
}
candidates() {
  [ -n "$APPIMAGE" ] && { readlink -f "$APPIMAGE"; return; }
  sed -n 's/^Exec="\(.*\)" --gb-install %u$/\1/p' "$HOME/.local/share/applications/mkw-recomp-url.desktop" 2>/dev/null
  grep -aohiE '/[^"[:cntrl:]]+\.appimage' "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf 2>/dev/null
  local found=() f
  while IFS= read -r -d '' f; do found+=("$f"); done < <(find "$HOME" /run/media -maxdepth 6 \( -name .mkw-recomp-update \
    -o -name .cache -o -name Trash -o -name .git -o -path "$DATA" -o -path "$HOME/.local/share/Steam" \
    -o -path "$HOME/.steam" \) -prune -o -type f -iname '*mkw*.appimage' -print0 2>/dev/null)
  [ ${#found[@]} -gt 0 ] && ls -1t -- "${found[@]}" 2>/dev/null   # newest first
}
tried=()
picked="" rt_check=""
while IFS= read -r c; do
  c=$(readlink -f "$c" 2>/dev/null) || continue
  case " ${tried[*]-} " in *" $c "*) continue ;; esac
  [ -n "$APPIMAGE" ] && [ ! -x "$c" ] && chmod +x "$c" 2>/dev/null   # only a file the player named
  is_appimage "$c" || continue
  tried+=("$c")
  mkw_matches "$c"
  case $? in
    0) picked=$c; rt_check="its runtime is the installed one"; break ;;
    2) [ -n "$APPIMAGE" ] && { picked=$c; rt_check="its runtime could not be compared with the installed one"; break; } ;;
  esac
done < <(candidates)
if [ -z "$picked" ]; then
  echo "no AppImage here holds the runtime installed in $DATA (the one the game started from last). Tried:" >&2
  [ ${#tried[@]} -gt 0 ] && printf '  - %s\n' "${tried[@]}" >&2 || echo "  (no executable mkw-recomp AppImage found)" >&2
  die "Start the game once from the AppImage you play with (it installs its runtime), quit, then run this script again; or name it with --appimage PATH."
fi
APPIMAGE=$picked
for d in "$(dirname "$APPIMAGE")"/.mkw-recomp-update; do
  [ -f "$d/ready" ] && echo "note: an update is downloaded but not installed ($(head -n1 "$d/ready")): this measures the version you play"
done

# ---- the game folder, read as cfg.c's cfg_init does: the launcher's mkw.ini may select another one in a line the
# runtime writes 'game_dir = "<path>"' (lower case, quoted; the key is read in any case, with or without MKW_), a
# relative value under the launcher's real folder, and MKW_GAME_DIR in the environment before all of it
GD=$DATA GD_FROM=default
gline=$(grep -iE '^[[:space:]]*(mkw_)?game_dir[[:space:]]*=' "$DATA/mkw.ini" 2>/dev/null | tr -d '\r' | tail -n1)
gval=$(printf '%s' "$gline" | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/')
if [ -n "$gval" ]; then
  case "$gval" in /*) GD=$gval ;; *) GD="$(readlink -f "$DATA")/$gval" ;; esac
  GD_FROM="mkw.ini: $gline"
fi
[ -n "${MKW_GAME_DIR:-}" ] && GD=$MKW_GAME_DIR GD_FROM="MKW_GAME_DIR in the environment"

# ---- the game files: --seconds starts the game without the start screen, which is what sets up again after an
# update. Every problem is listed, not only the first. Not checked: setup-state.json's "ready", which only a setup
# prepared by the in-app update writes (tools/prepare/prepare.py, args.next); game code of another version is caught
# by the first run itself ('built for another version of the runtime', run below).
problems=()
port=$(grep -o '"port": "[^"]*"' "$GD/setup-state.json" 2>/dev/null | cut -d'"' -f4)
[ -f "$GD/setup-state.json" ] || problems+=("no setup-state.json in $GD: the game was never set up there")
[ -f "$GD/mkwgame.so" ] || problems+=("no mkwgame.so in $GD: the game code was never built there")
if [ ${#problems[@]} -gt 0 ]; then
  echo "the game files are not ready (AppImage $APPIMAGE; game folder $GD, from $GD_FROM):" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  die "Start $APPIMAGE normally once, let its start screen finish setting up, quit the game, then run this script again."
fi
# The phase table MKW_QUICK_RACE presses by (runtime/core/diag/seqwatch.c): without it no press fires and every run
# would wait for its timeout. The setup writes it in its last step (0.1.14 and later), after the optional warm-up, so
# a setup stopped during the warm-up leaves a game that plays but has none. Then it is made the setup's way, from the
# game folder's exefs/main with the AppImage's own Python and tools/prepare/seqnodes.py, into the bench folder (the
# game folder is not touched), and MKW_SEQ_NODES points the runs at it.
SEQ_MADE=""
seqtab=$(ls "$GD"/seq_nodes-*.tsv 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')
if [ -z "$seqtab" ]; then
  SEQ_MADE=$(mktemp -d)/seq_nodes.tsv
  mnt_out=$(mktemp)
  "$APPIMAGE" --appimage-mount > "$mnt_out" 2>/dev/null &
  mpid=$!
  for _ in $(seq 100); do [ -s "$mnt_out" ] && break; sleep 0.1; done
  mnt=$(head -n1 "$mnt_out")
  if [ -n "$mnt" ] && [ -x "$mnt/setup/python/bin/python3" ]; then
    LD_LIBRARY_PATH="$mnt/lib" "$mnt/setup/python/bin/python3" -I "$mnt/setup/src/tools/prepare/seqnodes.py" \
      --exefs "$GD/exefs" --out "$SEQ_MADE" >/dev/null 2>&1
  fi
  kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null; rm -f "$mnt_out"
  [ -s "$SEQ_MADE" ] || die "no seq_nodes-*.tsv in $GD (its setup did not reach its last step) and it could not be made from $GD/exefs. Start $APPIMAGE normally, press Set up again on its start screen and let it finish, then run this script again."
  seqtab="none in the game folder: made from its exefs/main for these runs"
fi
echo "AppImage $APPIMAGE ($rt_check)"
echo "game folder $GD (from $GD_FROM), set up by ${port:-an unknown version}; phase table: ${seqtab% }"

# ---- checks that spoil a measurement: not a Deck, on battery, a fan fault (the firmware then holds the CPU at
# 400 MHz: PR #351, #461), a GPU clock set by hand (MKW_GPU_CLOCKS then holds nothing: vk_pstate.c), no room for logs
product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
case "$product" in Jupiter|Galileo) ;; *) echo "warning: product '$product' is not a Steam Deck (Jupiter, Galileo); going on" ;; esac
ac=$(cat /sys/class/power_supply/ACAD/online 2>/dev/null || echo "?")
[ "$ac" = 1 ] || echo "warning: not on AC power (ACAD online=$ac): the battery's power limits change the numbers"
for f in /sys/class/hwmon/hwmon*/fan1_fault; do
  [ -r "$f" ] && [ "$(cat "$f" 2>/dev/null)" = 1 ] && echo "warning: $f reports a fan fault: the Deck will throttle"
done
f=$(ls /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null | head -1)
CARD=$([ -n "$f" ] && dirname "$f")
HWMON=$([ -n "$CARD" ] && ls -d "$CARD"/hwmon/hwmon* 2>/dev/null | head -1)
level=$([ -n "$CARD" ] && cat "$CARD/power_dpm_force_performance_level" 2>/dev/null)
if [ -n "$level" ] && [ "$level" != auto ]; then
  echo "warning: the GPU clock level is '$level', not 'auto' (Steam's manual GPU clock?): MKW_GPU_CLOCKS holds nothing"
fi
pcap=$([ -n "$HWMON" ] && cat "$HWMON/power1_cap" 2>/dev/null)
[ -n "$pcap" ] && [ "$pcap" -lt 15000000 ] && echo "warning: the APU power cap is $((pcap / 1000000)) W: Steam's TDP limit is on"
free_mb=$(df -Pm "$HOME" | awk 'NR == 2 { print $4 }')
[ "${free_mb:-0}" -ge 2048 ] || die "only ${free_mb:-?} MB free in $HOME: at least 2048 needed for the logs"

OUT="$HOME/mkw-bench/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# The environment of every run. MKW_QUICK_RACE=gp reaches a Grand Prix's first race by itself (runtime/input/
# input_script.c) with the menus at turbo speed (MKW_TURBO=until) and the movies skipped; MKW_SEQ_UNTIL=ReadyRace
# starts the measured part and the world clock there, and MKW_SEQ_EXIT ends the run RACE_SECS later (wall time).
# --seconds is a safety limit on that same clock. A log on stderr keeps the player's logs/mkw.log and its rotation
# untouched (runtime/core/boot/main.c log_open); nothing set here is written to mkw.ini (cfg_set is the menus' only).
COMMON=(MKW_QUICK_RACE=gp MKW_SEQ_WATCH=1 MKW_SEQ_UNTIL=ReadyRace "MKW_SEQ_EXIT=$RACE_SECS" MKW_SEED=1
        MKW_TURBO=until MKW_SKIP_MOVIES=1 MKW_ASSUME_FOCUS=1 MKW_TRACE=perf)
if [ -n "$SEQ_MADE" ]; then   # the phase table made above, kept with the results
  cp "$SEQ_MADE" "$OUT/seq_nodes.tsv" && rm -rf "$(dirname "$SEQ_MADE")"
  COMMON+=("MKW_SEQ_NODES=$OUT/seq_nodes.tsv")
fi
# What the player's mkw.ini would otherwise slip into a measurement: frame generation at MKW_FPS=60 doubles the
# presents and adds GPU work 'gpu avg' does not count; mods, the overlay and another resolution change the frame. A
# later assignment wins in env, so a run can still set MKW_FRAMEGEN or MKW_RESOLUTION after these.
PIN=(MKW_FRAMEGEN=off MKW_PERF_OVERLAY=off MKW_MODS= MKW_ROMFS_MODS=)
# The quality preset's four rows (runtime/ui/menu/settings_tabs.cpp kPresets; MKW_QUALITY itself is read by nothing)
LOW=(MKW_ANISO=game MKW_TEX_QUALITY=quarter MKW_DETAIL_DISTANCE=1 MKW_SHADOW_SIZE=1024)
CONSOLE=(MKW_ANISO=game MKW_TEX_QUALITY=full MKW_DETAIL_DISTANCE=2 MKW_SHADOW_SIZE=console)
if [ "$QUALITY" = low ]; then
  QROWS=("${LOW[@]}")
  PIN+=(MKW_RESOLUTION=720 MKW_UPSCALER=bilinear MKW_OPERATION_MODE=docked MKW_VK_PRESENT=fifo)
else
  QROWS=()
fi

{
  echo "date: $(date -Is)"
  echo "product: $product ($(cat /sys/class/dmi/id/board_vendor 2>/dev/null))"
  grep -E '^(PRETTY_NAME|VERSION_ID|BUILD_ID)=' /etc/os-release 2>/dev/null
  echo "kernel: $(uname -r)"
  grep -m1 'model name' /proc/cpuinfo
  grep -E '^(MemTotal|SwapTotal):' /proc/meminfo
  echo "appimage: $APPIMAGE ($(stat -c %y "$APPIMAGE" 2>/dev/null)); $rt_check"
  echo "game folder: $GD (from $GD_FROM); set up by: ${port:-?}; phase tables: $seqtab"
  echo "ac: $ac; gpu clock level: ${level:-?}; apu power cap: ${pcap:-?} uW"
  for k in scaling_driver scaling_governor energy_performance_preference; do
    echo "cpu0 $k: $(cat /sys/devices/system/cpu/cpu0/cpufreq/$k 2>/dev/null)"
  done
  echo "options: race ${RACE_SECS}s, A/B blocks ${AB_SECS}s, runs '$ONLY', quality $QUALITY"
  echo "common env: ${COMMON[*]}"
  echo "pinned (all runs but own): ${PIN[*]} ${QROWS[*]}"
} > "$OUT/sysinfo.txt"
cp "$DATA/mkw.ini" "$OUT/launcher-mkw.ini" 2>/dev/null
[ "$GD" != "$DATA" ] && cp "$GD/mkw.ini" "$OUT/mkw.ini" 2>/dev/null

# ---- the sampler: every 2 s the time (epoch, to line samples up with each run's race start in NAME.race_t0), the
# total CPU load, the mean CPU clock, the GPU's shader clock and load, the APU's power, cap and temperature, the fan
# and the AC state; a throttled stretch or outside load shows here
sampler() {
  local fan="" h ptot="" pidl=""
  for h in /sys/class/hwmon/hwmon*; do [ -r "$h/fan1_input" ] && fan=$h && break; done
  echo "epoch,time,run,cpu_busy_pct,cpu_mhz,gpu_sclk_mhz,gpu_busy_pct,apu_power_w,apu_power_cap_w,apu_temp_c,fan_rpm,ac"
  while :; do
    local u n s i w q sq st tot idl load="" cpu sclk="" busy="" pw="" cap="" temp="" rpm="" acn run
    read -r _ u n s i w q sq st _ < /proc/stat
    tot=$((u + n + s + i + w + q + sq + st)); idl=$((i + w))
    [ -n "$ptot" ] && [ $((tot - ptot)) -gt 0 ] && load=$(( 100 * ((tot - ptot) - (idl - pidl)) / (tot - ptot) ))
    ptot=$tot; pidl=$idl
    cpu=$(awk '{ s += $1; c++ } END { if (c) printf "%.0f", s / c / 1000 }' \
      /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
    if [ -n "$CARD" ]; then
      sclk=$(awk '/\*/ { gsub(/[^0-9]/, "", $2); print $2 }' "$CARD/pp_dpm_sclk" 2>/dev/null)
      busy=$(cat "$CARD/gpu_busy_percent" 2>/dev/null)
    fi
    if [ -n "$HWMON" ]; then
      pw=$(cat "$HWMON/power1_average" 2>/dev/null || cat "$HWMON/power1_input" 2>/dev/null)
      cap=$(cat "$HWMON/power1_cap" 2>/dev/null)
      temp=$(cat "$HWMON/temp1_input" 2>/dev/null)
    fi
    [ -n "$fan" ] && rpm=$(cat "$fan/fan1_input" 2>/dev/null)
    acn=$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)
    run=$(cat "$OUT/.current" 2>/dev/null)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$(date +%H:%M:%S)" "${run:--}" "$load" "$cpu" \
      "$sclk" "$busy" \
      "$( [ -n "$pw" ] && awk -v v="$pw" 'BEGIN { printf "%.1f", v / 1e6 }')" \
      "$( [ -n "$cap" ] && awk -v v="$cap" 'BEGIN { printf "%.1f", v / 1e6 }')" \
      "$( [ -n "$temp" ] && awk -v v="$temp" 'BEGIN { printf "%.0f", v / 1000 }')" "$rpm" "$acn"
    sleep 2
  done
}

# ---- a quick view of each run from its log. The real analysis is tools/run/ab.py on the PC (means, both twins).
# medians: per side (all race windows, wholly-A, wholly-B; the race's first window left out, as ab.py does) the
# count and the median frame interval, replay and GPU time, then the pipelines built and draws skipped in the race
# (a cold pipeline cache shows there), then the race's time-weighted game speed and its windows under 0.98x
medians() {
  awk '
    function med(a, n,   i, j, t) {
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
      if (!n) return -1
      return n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
    }
    /seq: watch off at the start of/ { race = 1 }
    race && /game: speed [0-9.]+x over [0-9.]+ s/ {
      match($0, /speed [0-9.]+x/); sp = substr($0, RSTART + 6, RLENGTH - 7) + 0
      match($0, /over [0-9.]+ s/); du = substr($0, RSTART + 5, RLENGTH - 7) + 0
      swt += sp * du; sdu += du; nsp++; if (sp < 0.98) slow++
    }
    /perf: frame [0-9]+: gpu avg [0-9.]+ ms/ && side != "" {
      match($0, /gpu avg [0-9.]+/); g = substr($0, RSTART + 8, RLENGTH - 8)
      gp["all", ++gn["all"]] = g; if (side != "all") gp[side, ++gn[side]] = g
      side = ""; next
    }
    /interval avg [0-9.]+ ms.*replay avg [0-9.]+ ms; ab [0-9]+\/[0-9]+; world -?[0-9.]+ s/ {
      side = ""
      match($0, /world -?[0-9.]+ s/); w = substr($0, RSTART + 6, RLENGTH - 8)
      if (w ~ /^-/) next
      if (!started) { started = 1; next }
      match($0, /interval avg [0-9.]+/); iv = substr($0, RSTART + 13, RLENGTH - 13)
      match($0, /replay avg [0-9.]+/); rp = substr($0, RSTART + 11, RLENGTH - 11)
      match($0, /ab [0-9]+\/[0-9]+/); split(substr($0, RSTART + 3, RLENGTH - 3), ab, "/")
      if (match($0, /pipelines built in background [0-9]+/)) built += substr($0, RSTART + 30, RLENGTH - 30)
      if (match($0, /draws skipped pending [0-9]+/)) skipped += substr($0, RSTART + 22, RLENGTH - 22)
      n = ++cnt["all"]; ivs["all", n] = iv; rps["all", n] = rp; side = "all"
      if (ab[2] > 0 && (ab[1] == 0 || ab[1] == ab[2])) {
        s = ab[1] == 0 ? "A" : "B"; n = ++cnt[s]; ivs[s, n] = iv; rps[s, n] = rp; side = s
      }
    }
    END {
      split("all A B", sides, " ")
      for (k = 1; k <= 3; k++) {
        s = sides[k]; if (!cnt[s]) continue
        delete x; for (i = 1; i <= cnt[s]; i++) x[i] = ivs[s, i] + 0; mi = med(x, cnt[s])
        delete x; for (i = 1; i <= cnt[s]; i++) x[i] = rps[s, i] + 0; mr = med(x, cnt[s])
        delete x; for (i = 1; i <= gn[s]; i++) x[i] = gp[s, i] + 0; mg = med(x, gn[s])
        printf "%s %d %.2f %.2f %.2f\n", s, cnt[s], mi, mr, mg
      }
      printf "cold %d %d\n", built, skipped
      printf "speed %.2f %d %d\n", sdu ? swt / sdu : -1, nsp, slow
    }' "$1"
}

report() {   # NAME RC SECONDS [SWITCH]: a few lines in report.txt; NAME.med keeps the medians for the pair summary
  local LC_ALL=C   # awk prints '.', and bash's printf parses with the locale's decimal point (fr_FR: ',')
  local name=$1 rc=$2 secs=$3 sw=${4:-} log="$OUT/$1.log" started fatal why x
  medians "$log" > "$OUT/$name.med"
  started=$(grep -c 'seq: watch off at the start of' "$log" 2>/dev/null)
  fatal=$(grep -m1 -E 'FATAL|fatal signal|device lost|VK_ERROR_DEVICE_LOST|the GPU has not finished submission' "$log" 2>/dev/null)
  {
    printf '%s: exit %s after %ss; race reached: %s\n' "$name" "$rc" "$secs" "$([ "${started:-0}" -gt 0 ] && echo yes || echo NO)"
    [ -n "$fatal" ] && printf '  FATAL: %s\n' "$fatal"
    if [ -n "$sw" ]; then   # the switch must say it acts in the B blocks, else the A/B compared A with A
      if ! grep -qE "in the B blocks.*\\(${sw}[),]" "$log" || grep -q 'stable pstate .* was refused' "$log"; then
        why=$(grep -m1 -E "\(${sw}|vk: GPU clocks" "$log")
        printf '  A/B VOID: %s did not act in the B blocks (%s)\n' "$sw" "${why:-no line about it in the log}"
      fi
    fi
    while read -r s a b c d; do
      case "$s" in
        all) printf '  race   %3d windows: frame %6.2f ms, replay %6.2f ms' "$a" "$b" "$c"
             [ "$d" != "-1.00" ] && printf ', gpu %6.2f ms' "$d"; echo ;;
        A|B) [ -n "$sw" ] || continue
             printf '  %s      %3d windows: frame %6.2f ms, replay %6.2f ms' "$s" "$a" "$b" "$c"
             [ "$d" != "-1.00" ] && printf ', gpu %6.2f ms' "$d"; echo ;;
        cold) [ "$a" -gt 0 ] || [ "$b" -gt 0 ] && printf '  in the race: %s pipelines built, %s draws skipped while they built\n' "$a" "$b" ;;
        speed) [ "$b" -gt 0 ] && printf '  game speed %.2fx over the race (%s of %s windows under 0.98x)%s\n' "$a" "$c" "$b" \
                 "$(grep -q 'MKW_FPS=60' "$OUT/$name.env" 2>/dev/null && echo '; about 0.5x is expected at MKW_FPS=60')" ;;
      esac
    done < "$OUT/$name.med"
    case "$name" in
      diag-host) awk '/^\[host\] host time: /{on = 1} on && n++ < 14' "$log" | sed 's/^\[host\] /  /' ;;
      diag-crit) [ -s "$OUT/crit.bin" ] && echo "  crit.bin written ($(du -k "$OUT/crit.bin" | cut -f1) KiB): tools/run/crit_path.py reads it" \
                   || echo "  no crit.bin: $(grep -m1 'crit: ' "$log")" ;;
      diag-ops) grep -E 'perf: (replay ops|prepare_draw per draw)' "$log" | tail -2 | sed 's/^\[host\] /  /' | cut -c1-400 ;;
      diag-wb) grep 'merged write-backs' "$log" | tail -1 | sed 's/^\[host\] /  /' | cut -c1-400 ;;
      fg-off) ;;
      fg-*) x=$(grep 'vk: frame generation [0-9]x:' "$log" | tail -1)
            [ -n "$x" ] && printf '  %s\n' "${x#*vk: }" || \
              printf '  FRAME GENERATION DID NOT RUN (%s)\n' "$(grep -m1 -E 'frame generation (off|is on but|: no memory)' "$log")"
            echo "  (gpu avg leaves out frame generation's own GPU work: see gpu_busy_pct in samples.csv)" ;;
    esac
  } | tee -a "$OUT/report.txt"
}

pair_summary() {   # NAME LABEL: B - A of the plain run (d) and the inverted one (i): change (d+i)/2, scene (d-i)/2
  local LC_ALL=C
  awk -v label="$2" '
    FNR == 1 { f++ }
    $1 == "A" { a[f, 1] = $3; a[f, 2] = $4; a[f, 3] = $5 }
    $1 == "B" { b[f, 1] = $3; b[f, 2] = $4; b[f, 3] = $5 }
    END {
      if (!((1, 1) in a) || !((1, 1) in b) || !((2, 1) in a) || !((2, 1) in b)) { print "  pair: missing A or B windows"; exit }
      split("frame replay gpu", what, " ")
      printf "  PAIR (%s), B - A with the scene balanced:", label
      for (k = 1; k <= 3; k++) {
        if (a[1, k] < 0 || b[1, k] < 0 || a[2, k] < 0 || b[2, k] < 0) continue
        d = b[1, k] - a[1, k]; i = b[2, k] - a[2, k]
        printf " %s %+.2f ms (scene %.2f)", what[k], (d + i) / 2, (d - i) / 2
      }
      print ""
    }' "$OUT/$1.med" "$OUT/$1-inv.med" | tee -a "$OUT/report.txt"
}

GAME_PID="" WATCHER_PID=""
stop_all() {
  [ -n "$GAME_PID" ] && { kill -KILL -- "-$GAME_PID" 2>/dev/null || kill -KILL "$GAME_PID" 2>/dev/null; }
  [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
  [ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null
}
pack() {
  rm -f "$OUT/.current"
  tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" && echo "results: $OUT.tar.gz"
}
finish() { stop_all; pack; exit "$1"; }
trap 'echo; echo "interrupted"; finish 130' INT TERM HUP

wait_quiet() {   # Steam's shader processing after an install or update takes several of the 4 cores
  local waited=0
  while pgrep -x fossilize_replay >/dev/null 2>&1 && [ "$waited" -lt 900 ]; do
    [ "$waited" = 0 ] && echo "waiting for Steam's shader processing (fossilize_replay) to finish..."
    sleep 30; waited=$((waited + 30))
  done
}

run() {   # NAME [SWITCH] -- VAR=VALUE...: one game run with COMMON and the given variables
  local name=$1 sw="" log t0 rc
  shift
  [ "${1:-}" != -- ] && { sw=$1; shift; }
  shift   # the --
  log="$OUT/$name.log"
  printf '\n[%s] %s: %s\n' "$(date +%H:%M:%S)" "$name" "$*" | tee -a "$OUT/report.txt"
  [ "$DRY" = 1 ] && return 0
  printf '%s\n' "${COMMON[@]}" "$@" > "$OUT/$name.env"
  wait_quiet
  ps -eo pcpu,comm --sort=-pcpu | head -8 > "$OUT/$name.ps-start"
  echo "$name" > "$OUT/.current"
  : > "$log"
  # the race's start in epoch seconds, to line samples.csv up with the A/B blocks (B: floor((t-t0)/AB_SECS)%4 in 1,2;
  # the other way round for -inv runs)
  ( until grep -q 'seq: watch off at the start of' "$log" 2>/dev/null; do sleep 0.5; done
    date +%s.%N > "$OUT/$name.race_t0" ) &
  WATCHER_PID=$!
  t0=$SECONDS
  # In the background, so a trapped Ctrl-C interrupts wait at once; timeout puts itself and the game in a process
  # group of its own (its PID: env execs timeout), which stop_all kills
  env "${COMMON[@]}" "$@" timeout -s KILL "$RUN_TIMEOUT" "$APPIMAGE" --seconds $((RACE_SECS + 30)) > "$log" 2>&1 &
  GAME_PID=$!
  wait "$GAME_PID"; rc=$?
  GAME_PID=""
  kill "$WATCHER_PID" 2>/dev/null; wait "$WATCHER_PID" 2>/dev/null; WATCHER_PID=""
  echo "-" > "$OUT/.current"
  ps -eo pcpu,comm --sort=-pcpu | head -8 > "$OUT/$name.ps-end"
  report "$name" "$rc" $((SECONDS - t0)) "$sw"
  if ! grep -q 'seq: watch off at the start of' "$log"; then
    # MKW_SEQ_EXIT and --seconds both count from the race's start: whatever kept this run from it (a FATAL, the menu
    # presses stuck on an unexpected screen) would make every next run wait its whole timeout
    echo "$name never reached the race: $(grep -m1 -E 'FATAL|fatal signal|seq: no |no node' "$log" || echo "see $log")" \
      | tee -a "$OUT/report.txt"
    grep -q 'built for another version of the runtime' "$log" && \
      echo "the game code was built by another version: start $APPIMAGE normally once and let its start screen set up again" \
        | tee -a "$OUT/report.txt"
    echo "stopping here: the next runs would fail the same way" | tee -a "$OUT/report.txt"
    finish 1
  fi
  sleep "$COOL_SECS"
}

ab_pair() {   # NAME SWITCH LABEL: the switch at ab, a plain run and its inverted twin (tools/run/ab.py balances them)
  local first=${2%% *} extra=() set sw
  [ "$first" != "$2" ] && read -r -a extra <<< "${2#* }"
  set="$first=ab" sw=$first
  case "$first" in *=*) set=$first sw="" ;; esac   # MKW_<NAME>=<value>: set as is, its engagement not checked
  run "$1" $sw -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_TRACE_TL=1 "MKW_AB=$AB_SECS" ${extra[@]+"${extra[@]}"} "$set"
  run "$1-inv" $sw -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_TRACE_TL=1 "MKW_AB=$AB_SECS" MKW_AB_INVERT=1 ${extra[@]+"${extra[@]}"} "$set"
  [ "$DRY" = 1 ] || pair_summary "$1" "$3"
}

n=0 dcn=0
want base && n=$((n + 1)); want own && n=$((n + 1)); want res540 && n=$((n + 1))
want ab && n=$((n + 2 * ${#AB_PAIRS[@]})); want ab-known && n=$((n + 2 * ${#AB_KNOWN[@]})); want hang && n=$((n + 6)); want dc && n=$((n + 4))
want fg && n=$((n + 2)) && [ "$product" = Galileo ] && n=$((n + 1)); want preset && n=$((n + 4))
want diag && n=$((n + 4))
echo "mkw-recomp Deck bench: $n runs, about $((n * (RACE_SECS + 150 + COOL_SECS) / 60)) minutes; results in $OUT"
echo "Leave the Deck plugged in and do not touch it until it says done (Ctrl-C stops it and keeps what was measured)."
[ "$DRY" = 1 ] || { sampler > "$OUT/samples.csv" 2>/dev/null & SAMPLER_PID=$!; }

want base && run base -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_TRACE_TL=1
want own && run own --
if want diag; then
  run diag-host -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_HOST_TIME=1
  run diag-crit -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_TRACE=perf,sched MKW_CRIT=w30-40 "MKW_CRIT_OUT=$OUT/crit.bin"
  run diag-ops -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_TRACE=perf,draw
  run diag-wb -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_WB_CENSUS=1
fi
PAIRS=()
want ab && PAIRS+=("${AB_PAIRS[@]}")
want ab-known && PAIRS+=("${AB_KNOWN[@]}")
for spec in "${PAIRS[@]}"; do   # name:switch:label
  ab_pair "${spec%%:*}" "$(printf '%s' "$spec" | cut -d: -f2)" "$(printf '%s' "$spec" | cut -d: -f3-)"
done
if want dc; then
  for v in 0 1 1 0; do run "dc-$v-$((++dcn))" -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_TRACE_TL=1 "MKW_DRAW_CACHE=$v"; done
fi
if want hang; then
  for i in 1 2; do
    run "hang-switch-$i" MKW_GPU_CLOCKS -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_AB=2 MKW_GPU_CLOCKS=ab MKW_PSTATE_DRAIN=0 MKW_GPU_CRUMBS_DRAW=1
    run "hang-drain-$i" MKW_GPU_CLOCKS -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_AB=2 MKW_GPU_CLOCKS=ab MKW_PSTATE_DRAIN=1 MKW_GPU_CRUMBS_DRAW=1
    run "hang-peak-$i" -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=60 MKW_GPU_CLOCKS=peak MKW_GPU_CRUMBS_DRAW=1
  done
fi
want res540 && run res540 -- "${PIN[@]}" "${QROWS[@]}" MKW_RESOLUTION=540 MKW_UPSCALER=fsr MKW_FPS=60 MKW_TRACE_TL=1
if want fg; then
  # MKW_FRAMEGEN has no ab (runtime/gfx/vk/device/vk_framegen.c reads it each frame), hence separate runs: what they
  # answer is whether the game still holds 30 fps at full speed with the made frames' GPU work beside it
  run fg-off -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=30 MKW_FRAMEGEN=off
  run fg-2 -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=30 MKW_FRAMEGEN=2
  [ "$product" = Galileo ] && run fg-3 -- "${PIN[@]}" "${QROWS[@]}" MKW_FPS=30 MKW_FRAMEGEN=3
fi
if want preset; then
  # quality is read at start (restart-only rows), so separate runs in the order L C C L
  run preset-low-1 -- "${PIN[@]}" "${LOW[@]}" MKW_FPS=60
  run preset-console-1 -- "${PIN[@]}" "${CONSOLE[@]}" MKW_FPS=60
  run preset-console-2 -- "${PIN[@]}" "${CONSOLE[@]}" MKW_FPS=60
  run preset-low-2 -- "${PIN[@]}" "${LOW[@]}" MKW_FPS=60
fi

echo
echo "done: copy $OUT.tar.gz to the PC (a USB key, scp, KDE Connect) for tools/run/ab.py and summary.py"
finish 0
