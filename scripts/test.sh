#!/bin/sh
# Runs the unit tests.
#
# Some Command Line Tools installs (seen with Swift 6.4) intermittently fail to
# load the swift-testing macro plugin and stop with "plugin for module
# 'TestingMacros' not found". Pointing the compiler at the active toolchain's
# plugin directory avoids it. Extra arguments go to `swift test`.
set -eu
cd "$(dirname "$0")/.."
toolchain="$(dirname "$(dirname "$(xcrun --find swift)")")"
plugins="$toolchain/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
