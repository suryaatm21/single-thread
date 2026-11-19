#!/bin/sh
# Builds build/SingleThread.app: a menu-bar app bundle with a fixed bundle ID,
# signed so macOS keeps its Accessibility grant across rebuilds.
#
#   scripts/bundle.sh                 # release build, signed with the local identity
#   SINGLE_THREAD_SIGN_IDENTITY="My Cert" scripts/bundle.sh
#
# macOS ties privacy grants to the app's code signature. An ad-hoc signature
# changes on every build, so the grant silently stops applying. A named
# signing identity (even a self-signed one) keeps the signature's identity
# stable. See "Stable signing" in the README for the one-time setup.
set -eu

cd "$(dirname "$0")/.."

identity="${SINGLE_THREAD_SIGN_IDENTITY:-single-thread local signing}"
bundle_id="local.single-thread"
app="build/SingleThread.app"

swift build -c release --product SingleThread
bin_dir="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/SingleThread" "$app/Contents/MacOS/SingleThread"
cp hooks/single-thread-hook "$app/Contents/Resources/single-thread-hook"
chmod 755 "$app/Contents/Resources/single-thread-hook"
cp scripts/Info.plist "$app/Contents/Info.plist"

# `security find-identity -p codesigning` without -v also lists self-signed
# identities that are not trusted system-wide; codesign can still use them.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$identity\""; then
  codesign --force --sign "$identity" --identifier "$bundle_id" "$app"
  echo "Signed with \"$identity\"; the Accessibility grant will survive rebuilds."
else
  codesign --force --sign - --identifier "$bundle_id" "$app"
  cat >&2 <<EOF
warning: no code-signing identity named "$identity"; signed ad hoc instead.
         macOS treats every ad-hoc rebuild as a new app, so an Accessibility
         grant stops applying after the next rebuild (System Settings still
         shows the switch on). Create the identity once; see README > Stable signing.
EOF
fi

codesign --verify "$app"
echo "Built $app"
