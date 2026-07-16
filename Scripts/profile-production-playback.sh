#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
LIBRARY_ROOT=${TEXTMOUTH_PROFILE_LIBRARY_ROOT:-$HOME/.TextMouth}
SELECTION=${TEXTMOUTH_PROFILE_SELECTION:-random}
PLAY_SECONDS=${TEXTMOUTH_PROFILE_PLAY_SECONDS:-15}
RENDER_CHARACTERS=${TEXTMOUTH_PROFILE_RENDER_CHARACTERS:-5000}
CONFIGURATION=${TEXTMOUTH_PROFILE_CONFIGURATION:-Release}

cd "$REPOSITORY_ROOT"
xcodegen generate
xcodebuild test \
  -project TextMouth.xcodeproj \
  -scheme TextMouth \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -only-testing:TextMouthProductionTests/ProductionPlaybackProfilingTests \
  TEXTMOUTH_PROFILE_LIBRARY_ROOT="$LIBRARY_ROOT" \
  TEXTMOUTH_PROFILE_SELECTION="$SELECTION" \
  TEXTMOUTH_PROFILE_PLAY_SECONDS="$PLAY_SECONDS" \
  TEXTMOUTH_PROFILE_RENDER_CHARACTERS="$RENDER_CHARACTERS" \
  ENABLE_TESTABILITY=YES \
  2>&1 | tee /tmp/textmouth-production-profile.log

rg 'PERF_PROFILE' /tmp/textmouth-production-profile.log
