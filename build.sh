#!/bin/bash
# Builds BudSwitch.app, installs it to ~/Applications, and (re)launches it.
# RELEASE=1, which release.sh sets, builds the release instead and leaves it in build/: universal, with
# the hardened runtime and secure timestamp that notarization requires.
set -euo pipefail
cd "$(dirname "$0")"

app="build/BudSwitch.app"
installed="$HOME/Applications/BudSwitch.app"
release="${RELEASE:-}"

# Developer ID first: its designated requirement names the team, not the certificate, so the Bluetooth
# permission survives rebuilds and carries over to and from the release. Apple Development keeps it only
# across builds from the same certificate; ad hoc signing ("-") asks again after every build.
identities="$(security find-identity -v -p codesigning | grep -v REVOKED || true)"
identity="${SIGN_IDENTITY:-$(awk '/"Developer ID Application:/ { print $2; exit }' <<<"$identities")}"
identity="${identity:-$(awk '/"Apple Development:/ { print $2; exit }' <<<"$identities")}"

build=(swift build -c release)
sign=(codesign --force --sign "${identity:--}")
if [[ -n "$release" ]]; then
  build+=(--arch arm64 --arch x86_64)
  sign+=(--options runtime --timestamp)
fi

"${build[@]}"
bin="$("${build[@]}" --show-bin-path)"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/BudSwitch" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
"${sign[@]}" "$app"
[[ -z "$release" ]] || exit 0

pkill -x BudSwitch || true
while pgrep -x BudSwitch >/dev/null; do sleep 0.1; done
mkdir -p "$HOME/Applications"
rm -rf "$installed"
cp -R "$app" "$installed"
open "$installed"
