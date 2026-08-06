#!/bin/zsh
#
# Checks that a release tag, the bundle version, and the release notes agree,
# before anything gets built or published. Prints the version on success.
#
#   ./scripts/validate-release.sh v0.1.0
#
set -euo pipefail

root="${0:A:h:h}"
tag="${1:-}"
info_plist="${INFO_PLIST_PATH:-$root/Resources/Info.plist}"
release_notes_dir="${RELEASE_NOTES_DIR:-$root/docs/releases}"

fail() {
    echo "Release validation failed: $1" >&2
    exit 1
}

[[ "$tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "tag must use vMAJOR.MINOR.PATCH"
[[ -f "$info_plist" ]] || fail "missing Info.plist at $info_plist"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null)" \
    || fail "CFBundleShortVersionString is missing"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null)" \
    || fail "CFBundleVersion is missing"

[[ "$version" == "${tag#v}" ]] || fail "tag ${tag#v} does not match bundle version $version"
[[ "$bundle_version" =~ '^[1-9][0-9]*$' ]] || fail "CFBundleVersion must be a positive integer"
[[ -f "$release_notes_dir/$tag.md" ]] || fail "missing release notes at $release_notes_dir/$tag.md"

echo "$version"
