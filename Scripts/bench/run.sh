#!/bin/zsh
#
# Offline scenario benchmark.
#
# Every threshold in the detection path was chosen by running this, not by ear.
# It compiles the app's real DSP sources — not a copy of them — against
# synthesised material and reports what a tuner is actually judged on: how long
# it takes to show a reading, how long it keeps showing one as the note decays,
# how accurate and how steady that reading is, and how often it invents one when
# nothing is being played.
#
#   ./Scripts/bench/run.sh          metrics table
#   ./Scripts/bench/run.sh sweep    threshold sweep (edit sweep-main.swift)
#
# The signals model a phone microphone: two cascaded highpasses for the
# low-frequency rolloff, an unplugged solid-body whose fundamental barely
# radiates, an acoustic with the other five strings ringing, glottal-pulse
# speech, and pink room tone with mains hum.
set -e
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../.." && pwd)
OUT="$D/.build"
mkdir -p "$OUT"

SRC=(
  "$R/ZeroFret/Audio/PitchDetector.swift"
  "$R/ZeroFret/Audio/Biquad.swift"
  "$R/ZeroFret/Audio/NoiseGate.swift"
  "$R/ZeroFret/Audio/Smoother.swift"
  "$R/ZeroFret/Audio/PitchStability.swift"
  "$R/ZeroFret/Audio/HarmonicScore.swift"
  "$R/ZeroFret/Audio/TargetTracker.swift"
  "$R/ZeroFret/Model/StringAssigner.swift"
  "$R/ZeroFret/Model/Tuning.swift"
)

if [[ "$1" == "sweep" ]]; then
  swiftc -O -module-name zfsweep -o "$OUT/sweep" "${SRC[@]}" \
    "$D/sig.swift" "$D/sweep.swift" "$D/sweep-main.swift"
  "$OUT/sweep"
else
  swiftc -O -o "$OUT/bench" "${SRC[@]}" "$D/sig.swift" "$D/main.swift"
  "$OUT/bench"
fi
