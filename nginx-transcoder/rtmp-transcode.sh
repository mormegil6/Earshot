#!/bin/sh
# The RTMP route's transcoder. nginx-rtmp's exec line (nginx.conf and
# nginx-no-ssl.conf, application live) runs this once per published stream;
# it picks the programme's Opus rate from the stream's channel count and then
# becomes ffmpeg.
#
# FEWER THAN FOUR CHANNELS ARE REFUSED, ON PURPOSE. An ambisonic stream has at
# least four channels, and the guest stall guard depends on a push with fewer
# producing nothing: it ends such a session after 45 s with "no playable output"
# instead of letting it squat the slot for the three-hour cap. That used to
# happen by accident. The same libopus limit that rejects 1536k for four
# channels also rejected the old fixed 1024k below four (256 kb/s a channel,
# so 256k for mono, 512k for stereo, 768k for three), so a mono push died at
# encoder start. A per-channel rate would encode it (96k), publish a one-channel
# programme and break that guard (test-guest-endpoint.sh, T5-stall, fails with
# "end reason not surfaced (got: 'session cap')"). So the refusal is now explicit.
# Four channels and up are encoded as before.
#
# WHY THE RATE CANNOT BE ONE LITERAL. The programme is encoded at 96 kb/s per
# channel on both contribution routes: 1536k for third order (16 channels) and
# 384k for first order (4), the rates the SRT direct listeners already use
# (direct-dash-gate.sh knows the shape from its port). FFmpeg's libopus wrapper
# refuses any rate above 256 kb/s per channel when the encoder opens
# (libopusenc.c: "The bit rate ... is unsupported", EINVAL), so a literal
# 1536k on the exec line stopped every first-order RTMP transcode before its
# first segment, and nginx-rtmp respawned it into the same refusal every few
# seconds. Measured 2026-10-03: 1536k encodes 16 channels and is refused for
# 4; 1024k, the literal before that, sits exactly at the 4-channel ceiling.
#
# HOW. One short probe of the stream that was just published decodes a single
# audio frame through ashowinfo, which prints channels:N. Then exec, so the
# process nginx-rtmp started, and later signals, IS the ffmpeg doing the work:
# no shell stays between them, and the process is still called ffmpeg for
# anything that looks for it by name. If the probe yields no count, the rate
# falls back to 1024k, which both supported layouts (4 and 16 channels)
# accept. The choice is logged either way, to the same log the dashboard's
# encoder tile reads.
#
# The probe is a second, short-lived subscriber to the stream. wait_key and
# wait_video apply to it as to any player, so it returns within about one GOP
# of the publish; -rw_timeout bounds it if the stream stalls first.
#
# usage, from the exec line:
#   rtmp-transcode.sh <publish name> <dash name> <keep-alive codec> [FFMPEG_FLAGS...]
# nginx-rtmp splits the line on whitespace, so FFMPEG_FLAGS arrives as
# separate arguments, exactly as the inline ffmpeg line used to receive it.
# The publish name is network-derived and attacker-controlled: it is used only
# inside the rtmp:// input URL, never in a path (the comment above the exec
# line in nginx-no-ssl.conf says why that is safe and the output path is not).
#
# Option order is the inline line's, and it matters: ${FFMPEG_FLAGS} comes
# after the programme's -b:a:0, so a -b:a there still overrides the rate, and
# before the keep-alive's options, so it cannot inflate the silent track.
set -u
# nginx-rtmp starts exec'd programs with an empty environment, and the shell's
# fallback search path has no /usr/local/bin, where this image keeps ffmpeg:
# without this line the script cannot find ffmpeg at all.
PATH=/usr/local/bin:/usr/bin:/bin
export PATH
name=$1 dash=$2 keepalive=$3
shift 3
# Test hooks (never set under nginx-rtmp, which starts this with an empty
# environment): read from another URL or file, write the DASH output elsewhere.
src="${RTMP_TRANSCODE_SRC:-rtmp://127.0.0.1/live/$name}"
outdir="${RTMP_TRANSCODE_OUT:-/opt/data/dash}"

ch=$(ffmpeg -hide_banner -nostdin -rw_timeout 15000000 -analyzeduration 5M -i "$src" \
       -map 0:a:0 -frames:a 1 -af ashowinfo -f null - 2>&1 \
     | sed -n 's/.* channels:\([0-9][0-9]*\) .*/\1/p' | head -n 1)
case "$ch" in
    ''|*[!0-9]*|0) rate=1024k; why="probe found no channel count" ;;
    1|2|3)         echo "rtmp-transcode: $ch channel(s), refused: an ambisonic stream needs at least 4" >&2
                   exit 1 ;;
    *)             rate=$((ch * 96))k; why="$ch channels" ;;
esac
echo "rtmp-transcode: $why, programme at $rate" >&2

exec ffmpeg -analyzeduration 10M -i "$src" -f lavfi -i anullsrc=r=48000:cl=stereo \
    -map 0:v:0 -map 0:a:0 -map 1:a:0 -strict -2 \
    -c:a:0 libopus -mapping_family:a:0 255 -b:a:0 "$rate" -shortest \
    "$@" -c:a:1 "$keepalive" -b:a:1 8k -ac:a:1 2 \
    -f dash "$outdir/$dash.mpd"
