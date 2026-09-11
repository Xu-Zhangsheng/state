#!/bin/zsh

set -euo pipefail

root_dir="${0:A:h:h}"
developer_dir="/Applications/Xcode.app/Contents/Developer"
derived_data="${root_dir}/.build/universal-installer"
products="${derived_data}/Build/Products/Release"
staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/stasis-installer.XXXXXX")"
payload="${staging_dir}/Payload"
component_plist="${staging_dir}/components.plist"
marketing_version="${STASIS_MARKETING_VERSION:-0.2.4}"
build_number="${STASIS_BUILD_NUMBER:-411}"
release_label="${STASIS_RELEASE_LABEL:-release}"
output="${STASIS_OUTPUT:-${root_dir}/dist/Stasis-${marketing_version}-universal.pkg}"

cleanup() {
  /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT

DEVELOPER_DIR="$developer_dir" /usr/bin/xcodebuild \
  -project "${root_dir}/stasis.xcodeproj" \
  -scheme stasis \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO \
  build

/bin/mkdir -p \
  "$payload/Applications" \
  "$payload/Library/PrivilegedHelperTools" \
  "$payload/Library/LaunchDaemons" \
  "$payload/Library/Stasis" \
  "${root_dir}/dist"

/usr/bin/ditto "${products}/stasis.app" "$payload/Applications/Stasis.app"
/bin/cp "${products}/charging-helper" \
  "$payload/Library/PrivilegedHelperTools/com.srimanachanta.stasis.charging-helper"
/usr/bin/ditto "${products}/smc_power.framework" \
  "$payload/Library/Stasis/smc_power.framework"
/bin/cp "${root_dir}/ChargingHelper/com.srimanachanta.stasis.charging-helper.legacy.plist" \
  "$payload/Library/LaunchDaemons/com.srimanachanta.stasis.charging-helper.legacy.plist"

# Build products can inherit Finder metadata from the working copy. Remove it
# from the staged payload before signing so the package passes strict validation.
/usr/bin/xattr -cr "$payload"

/usr/bin/codesign --force --sign - \
  "$payload/Library/Stasis/smc_power.framework"
/usr/bin/codesign --force --sign - \
  --entitlements "${root_dir}/Packaging/ChargingHelper.entitlements" \
  "$payload/Library/PrivilegedHelperTools/com.srimanachanta.stasis.charging-helper"

while IFS= read -r nested; do
  /usr/bin/codesign --force --sign - "$nested"
done < <(/usr/bin/find "$payload/Applications/Stasis.app/Contents" -depth \
  \( -name '*.framework' -o -name '*.xpc' \) -print)
/usr/bin/codesign --force --sign - \
  "$payload/Applications/Stasis.app/Contents/Library/LaunchDaemons/charging-helper"
/usr/bin/codesign --force --sign - "$payload/Applications/Stasis.app"

/usr/bin/codesign --verify --deep --strict "$payload/Applications/Stasis.app"
/usr/bin/codesign --verify --strict \
  "$payload/Library/PrivilegedHelperTools/com.srimanachanta.stasis.charging-helper"

/bin/chmod 0755 "${root_dir}/Packaging/scripts/postinstall"

# pkgbuild otherwise treats application bundles as relocatable. If another
# Stasis bundle exists in DerivedData or dist, Installer can target that copy
# instead of /Applications. Mark every discovered bundle as non-relocatable so
# Beta installs and downgrades always operate on the explicit payload path.
/usr/bin/pkgbuild --analyze --root "$payload" "$component_plist"
component_index=0
stasis_component_index=""
while /usr/libexec/PlistBuddy \
  -c "Print :${component_index}:RootRelativeBundlePath" \
  "$component_plist" >/dev/null 2>&1; do
  component_path="$(/usr/libexec/PlistBuddy \
    -c "Print :${component_index}:RootRelativeBundlePath" \
    "$component_plist")"

  # Only application bundles participate in Installer's relocation search.
  # Framework entries may not contain BundleIsRelocatable at all, so trying
  # to Set that key on every entry makes an otherwise valid build fail.
  if [[ "$component_path" == "Applications/Stasis.app" ]]; then
    stasis_component_index="$component_index"
    /usr/libexec/PlistBuddy \
      -c "Set :${component_index}:BundleIsRelocatable false" \
      "$component_plist"
    /usr/libexec/PlistBuddy \
      -c "Set :${component_index}:BundleOverwriteAction upgrade" \
      "$component_plist"
  fi
  component_index=$((component_index + 1))
done

if [[ -z "$stasis_component_index" ]] || \
  [[ "$(/usr/libexec/PlistBuddy \
    -c "Print :${stasis_component_index}:BundleIsRelocatable" \
    "$component_plist")" != "false" ]]; then
  echo "error: failed to mark Applications/Stasis.app as non-relocatable" >&2
  exit 1
fi

/usr/bin/pkgbuild \
  --root "$payload" \
  --scripts "${root_dir}/Packaging/scripts" \
  --component-plist "$component_plist" \
  --identifier com.srimanachanta.stasis.installer \
  --version "$marketing_version" \
  --install-location / \
  "$output"

echo "$output"
