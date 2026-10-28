#!/bin/bash
# Publishes a version: a notarized zip, the tag, the GitHub release, then the Homebrew cask.
# Usage: ./release.sh 1.0.1, with its notes in release-notes/1.0.1.md or NOTES=file.md.
# DRY_RUN=1 builds, notarizes and writes the cask, but publishes nothing.
set -euo pipefail
# NOTES may be relative to where the release started: resolve it before moving to the repo.
notes_source="${NOTES:-}"
[[ -z "$notes_source" || "$notes_source" == /* ]] || notes_source="$PWD/$notes_source"
cd "$(dirname "$0")"

repo="EQuimper/BudSwitch"
tap_repo="${BUDSWITCH_TAP_REPO:-EQuimper/homebrew-tap}"
plist="Resources/Info.plist"
out="$PWD/build/releases"
version="${1:-}"
dry_run="${DRY_RUN:-}"
# Emanuel Quimper's own team signs every release, so the Bluetooth permission carries over from one to
# the next. Apple notarizes it with a keychain profile made by `xcrun notarytool store-credentials`;
# Layout's serves the same team.
developer_id="Developer ID Application: Emanuel Quimper (KJ9VT8V982)"
notary_profile="${BUDSWITCH_NOTARY_PROFILE:-layout-notary}"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
# A dry run reports what a real release would refuse, then carries on.
refuse() {
  if [[ -n "$dry_run" ]]; then printf 'Warning: %s\n' "$*" >&2; else fail "$*"; fi
}
plist_value() { plutil -extract "$1" raw -o - "$2"; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: ./release.sh x.y.z"
tag="v$version"
current="$(plist_value CFBundleShortVersionString "$plist")"
build="$(plist_value CFBundleVersion "$plist")"

[[ "$(git symbolic-ref --short -q HEAD || true)" == main ]] || refuse "releases are cut from main"
[[ -z "$(git status --porcelain)" ]] || refuse "uncommitted changes are not part of the release"
if git remote get-url origin >/dev/null 2>&1; then
  git fetch --quiet --tags origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || refuse "main differs from origin/main: push or pull first"
else
  refuse "no origin remote: gh repo create $repo --public --source . --push"
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then fail "$tag already exists"; fi
if [[ "$(printf '%s\n' "$current" "$version" | sort -V | tail -n 1)" != "$version" ]]; then
  fail "$version is lower than the current version, $current"
fi
# The GitHub release shows these notes: written for people, and committed with the release.
if [[ -z "$notes_source" && -f "release-notes/$version.md" ]]; then
  notes_source="$PWD/release-notes/$version.md"
fi
if [[ -n "$notes_source" ]]; then
  [[ -f "$notes_source" ]] || fail "NOTES=$notes_source is not a file"
else
  refuse "no release notes: write release-notes/$version.md or pass NOTES=file.md"
fi
[[ -n "$dry_run" ]] || gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
# Captured, not piped into grep -q: under pipefail, grep leaving early can fail the whole pipe.
identities="$(security find-identity -v -p codesigning)"
[[ "$identities" == *"\"$developer_id\""* ]] || fail "$developer_id is not in the keychain"
# Releases notarized before the certificate expires keep working; new ones need its successor.
expiry="$(security find-certificate -c "$developer_id" -p | openssl x509 -noout -enddate \
  | cut -d= -f2 | tr -s ' ')"
days_left=$((($(LC_ALL=C date -j -f '%b %d %T %Y %Z' "$expiry" +%s) - $(date +%s)) / 86400))
((days_left > 0)) || fail "$developer_id expired on $expiry"
if ((days_left <= 60)); then
  printf 'Warning: %s expires in %d days (%s).\n' "$developer_id" "$days_left" "$expiry" >&2
fi
xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
  || fail "notarytool can't use the keychain profile $notary_profile (BUDSWITCH_NOTARY_PROFILE names another)"

work="$(mktemp -d "${TMPDIR:-/tmp}/budswitch-release.XXXXXX")"
tree="$work/tree"
tagged=""
pushed=""
cleanup() {
  # A tag that never reached origin must not block the next attempt.
  if [[ -n "$tagged" && -z "$pushed" ]]; then git tag -d "$tag" >/dev/null 2>&1 || true; fi
  git worktree remove --force "$tree" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
# Build from a separate checkout: edits in this working tree cannot leak into the release.
git worktree add --quiet --detach "$tree" HEAD

bumped=""
if [[ "$version" != "$current" ]]; then
  build=$((build + 1))
  plutil -replace CFBundleShortVersionString -string "$version" "$tree/$plist"
  plutil -replace CFBundleVersion -string "$build" "$tree/$plist"
  git -C "$tree" commit --quiet -m "Release $version" -- "$plist"
  bumped=1
fi
commit="$(git -C "$tree" rev-parse HEAD)"
short="$(git -C "$tree" rev-parse --short HEAD)"

(cd "$tree" && SIGN_IDENTITY="$developer_id" RELEASE=1 ./build.sh)
app="$tree/build/BudSwitch.app"
bundle_id="$(plist_value CFBundleIdentifier "$app/Contents/Info.plist")"
[[ "$(plist_value CFBundleShortVersionString "$app/Contents/Info.plist")" == "$version" ]] \
  || fail "the build does not report version $version"
signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
signer="$(awk '/^Authority=/ { sub(/^Authority=/, ""); print; exit }' <<<"$signature")"
[[ "$signer" == "$developer_id" ]] \
  || refuse "the build is signed by ${signer:-an ad hoc signature}, not $developer_id"
[[ "$signature" == *"flags="*"(runtime)"* ]] \
  || refuse "the build lacks the hardened runtime, which notarization requires"
# The README promises Intel Macs too.
archs="$(lipo -archs "$app/Contents/MacOS/BudSwitch")"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] \
  || refuse "BudSwitch is $archs only, not universal (arm64 and x86_64)"

mkdir -p "$out"
zip="$out/BudSwitch-$version.zip"
notes="$out/BudSwitch-$version-notes.md"
rm -f "$zip"

# Apple scans the app; the ticket stapled to it then lets Gatekeeper open it offline.
notarize() {
  local result status id
  result="$(xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait \
    --output-format json)" || fail "notarytool could not submit $(basename "$1")"
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    if [[ -n "$id" ]]; then xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2; fi
    fail "notarization of $(basename "$1") ended as ${status:-unknown}"
  fi
  printf 'Notarized %s (%s)\n' "$(basename "$1")" "$id"
}
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarize.zip"
notarize "$work/notarize.zip"
xcrun stapler staple -q "$app" || fail "could not staple the ticket to BudSwitch.app"
spctl --assess --type exec "$app" 2>/dev/null || fail "Gatekeeper rejects BudSwitch.app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
sha256="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"

previous="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$commit" 2>/dev/null || true)"
if [[ -n "$notes_source" ]]; then
  cp "$notes_source" "$notes"
elif [[ -n "$previous" ]]; then
  # Only a dry run gets here: the commit subjects stand in for the notes. Leave out the release
  # commit itself, which only changes the version.
  git log --no-merges --format='- %s' "$previous..$commit${bumped:+^}" > "$notes"
else
  printf '%s\n' 'First release.' > "$notes"
fi

# The whole cask is rewritten on each release: the tap repository only has to exist.
write_cask() {
  cat <<EOF
cask "budswitch" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/$repo/releases/download/v#{version}/BudSwitch-#{version}.zip"
  name "BudSwitch"
  desc "Menu bar switch that moves headphones between this computer and an iPhone"
  homepage "https://github.com/$repo"

  depends_on macos: :sonoma

  app "BudSwitch.app"

  uninstall quit: "$bundle_id"

  zap trash: "~/Library/Preferences/$bundle_id.plist"
end
EOF
}

printf '\nBudSwitch %s (build %s) from %s, signed by %s\n' \
  "$version" "$build" "$short" "${signer:-an ad hoc signature}"
printf '  %s\n' "$zip" "$notes"
if [[ -n "$dry_run" ]]; then
  write_cask > "$out/budswitch.rb"
  printf '%s\n' "Dry run: nothing was pushed or published. Cask preview: $out/budswitch.rb"
  exit 0
fi

git tag -a "$tag" -m "BudSwitch $version" -m "Signing identity: $signer" "$commit"
tagged=1
# Atomic: main and the tag reach origin together, or neither does.
git push --atomic --quiet origin "$commit:refs/heads/main" "refs/tags/$tag" \
  || fail "push rejected: nothing was published"
pushed=1
gh release create "$tag" "$zip" --repo "$repo" --title "BudSwitch $version" \
  --notes-file "$notes" --verify-tag \
  || fail "$tag is pushed but the GitHub release failed; retry: gh release create $tag $zip" \
    "--repo $repo --title 'BudSwitch $version' --notes-file $notes"

# This checkout catches up with the release commit, unless it moved on meanwhile.
if [[ -n "$bumped" && "$(git symbolic-ref --short -q HEAD || true)" == main ]]; then
  git merge --ff-only --quiet "$commit" \
    || printf '%s\n' "Warning: run git pull to get the release commit." >&2
fi

write_cask > "$out/budswitch.rb"
if gh repo view "$tap_repo" >/dev/null 2>&1; then
  git clone --quiet --depth 1 "https://github.com/$tap_repo.git" "$work/tap"
  mkdir -p "$work/tap/Casks"
  cp "$out/budswitch.rb" "$work/tap/Casks/budswitch.rb"
  git -C "$work/tap" add Casks/budswitch.rb
  git -C "$work/tap" commit --quiet -m "budswitch $version"
  git -C "$work/tap" push --quiet origin HEAD:refs/heads/main
  printf '%s\n' "Cask $version published in $tap_repo."
else
  printf '%s\n' "No $tap_repo repository: the cask was not published ($out/budswitch.rb)."
fi
