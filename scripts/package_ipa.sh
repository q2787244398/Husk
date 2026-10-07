#!/bin/bash
# Build Husk and package one IPA for every installer, validating the bundle before shipping it.
#
# Unsigned, deliberately -- the same artifact the official release ships. Every
# installer (TrollStore, AltStore, SideStore, Sideloadly) signs at install with
# its own method, and none of them wants a signature to already be there.
#
# The ad hoc signature this used to apply is what made the app die on its first
# launch. It carried Husk.entitlements, and the memory and
# dynamic-codesigning entitlements in it are not ones a sideloading profile
# grants: an installer that keeps them produces an app whose entitlements do not
# match the profile it was signed with, and iOS kills that app the moment it is
# opened -- an immediate crash that no log inside the app can explain, because
# the app never gets to run. Shipping unsigned leaves the entitlements to
# whoever installs it, which is the one choice that works for all of them.
#
# The validation step exists because a bundle missing CFBundleIdentifier or
# CFBundleExecutable builds and zips perfectly happily, and then fails to install
# with no useful message. Xcode does not inject those keys when a custom
# INFOPLIST_FILE is supplied without GENERATE_INFOPLIST_FILE, which is exactly how
# this project is set up.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="${DD:-/tmp/husk_ipa}"
OUT="${1:-$HOME/Desktop/Husk.ipa}"
mkdir -p "$DD"

# The .app is not the only thing that can be stale. The Xcode target links the
# dylib staged in build/ios-arm64/lib, which is filled in by build_ios.sh's qemu
# stage -- so rebuilding QEMU with plain ninja produces a new dylib that never
# reaches the app, and the IPA ships the previous one with no warning at all.
# That happened once and looked exactly like a fix that did not work.
BUILT="$HUSK_ROOT/third_party/build/qemu-10.0.12-utm/_husk_build/libqemu-aarch64-softmmu.dylib"
STAGED="$HUSK_ROOT/build/ios-arm64/lib/libqemu-aarch64-softmmu.dylib"
if [ -f "$BUILT" ] && [ "$BUILT" -nt "$STAGED" ]; then
    echo "==> staged dylib is older than the built one; restaging"
    cp "$BUILT" "$STAGED"
fi

# Regenerate the project first.
#
# project.yml globs src/app/Husk, so adding a source file there is meant to be
# all it takes -- but the checked-in .pbxproj is a build artefact of that glob,
# and nothing was regenerating it. A new file was therefore silently absent from
# the target, and the only symptom was "cannot find X in scope" for a type that
# is plainly right there on disk.
if command -v xcodegen >/dev/null 2>&1; then
    echo "==> regenerating the project from project.yml"
    (cd "$HUSK_ROOT/src/app" && xcodegen generate --quiet)
else
    echo "==> xcodegen not installed; using the checked-in project as-is" >&2
fi

echo "==> building"
xcodebuild -project "$HUSK_ROOT/src/app/Husk.xcodeproj" -scheme Husk \
    -sdk iphoneos -configuration Release -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build 2>&1 | tee "$DD/build.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

# A failed build used to sail straight past this: the previous .app is still in
# DerivedData, so validation and packaging both succeed and produce an IPA of
# the LAST build. Shipping a stale binary silently is the worst outcome here --
# it looks exactly like a fix that did not work.
if ! grep -q "BUILD SUCCEEDED" "$DD/build.log"; then
    echo "build failed; refusing to package a stale app" >&2
    grep -E "error:" "$DD/build.log" | head -10 >&2
    exit 1
fi

APP="$DD/Build/Products/Release-iphoneos/Husk.app"
[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 1; }

# Stamp the build's identity into the bundle so its logs can name themselves.
# A log from a stale install is otherwise indistinguishable from a log proving a
# fix did not work.
APP_PLIST="$DD/Build/Products/Release-iphoneos/Husk.app/Info.plist"
if [ -f "$APP_PLIST" ]; then
    COMMIT="$(git -C "$HUSK_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    git -C "$HUSK_ROOT" diff --quiet 2>/dev/null || COMMIT="$COMMIT-dirty"
    plutil -replace HuskBuildCommit -string "$COMMIT" "$APP_PLIST"
    plutil -replace HuskBuildDate -string "$(date -u '+%Y-%m-%d %H:%M UTC')" "$APP_PLIST"
    echo "==> stamped build $COMMIT"
fi

echo "==> validating bundle"
PLIST="$APP/Info.plist"
rc=0
for key in CFBundleIdentifier CFBundleExecutable CFBundleName \
           CFBundlePackageType CFBundleVersion CFBundleShortVersionString \
           MinimumOSVersion UIDeviceFamily; do
    val="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
    if [ -z "$val" ]; then
        echo "  MISSING  $key   <-- the app will not install" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$key" "$(echo "$val" | head -1)"
    fi
done

# The executable named in the plist must actually exist.
EXE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)"
if [ -n "$EXE" ] && [ ! -f "$APP/$EXE" ]; then
    echo "  MISSING  executable '$EXE' named by CFBundleExecutable" >&2
    rc=1
elif [ -n "$EXE" ]; then
    printf "  ok       %-28s %s\n" "executable present" "$EXE"
fi

# Both dylibs must be embedded, or the app dies at launch with a dyld error.
#
# ANGLE is checked here because it was not, and an IPA shipped without it: the
# app reached qemu_egl_init_dpy_cocoa and aborted with "Couldn't open
# @rpath/libANGLE-shared.dylib". Everything else in this validation passed. A
# check that covers one of two required libraries is a check that reports
# success on a bundle that cannot launch.
for lib in libqemu-aarch64-softmmu.dylib libANGLE-shared.dylib; do
    if [ ! -f "$APP/Frameworks/$lib" ]; then
        echo "  MISSING  Frameworks/$lib" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "${lib%%-*} dylib embedded" \
            "$(du -h "$APP/Frameworks/$lib" | cut -f1)"
    fi
done

# Guest images, firmware, and blank disk seeds required by first launch.
for f in vmlinuz-virt initramfs-virt husk-jit.js \
         edk2-aarch64-code.fd lineage-efi-vars-seed.fd lineage-vdb-seed.qcow2; do
    if [ ! -f "$APP/$f" ]; then
        echo "  MISSING  $f" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$f" "$(du -h "$APP/$f" | cut -f1)"
    fi
done

# Built-in StikJIT's helper. Without it the app still installs and runs with
# StikDebug, but its JIT setup would offer a method that can only fail.
for f in "$APP/PlugIns/HuskJITHelper.appex/HuskJITHelper" \
         "$APP/Frameworks/StikJIT.framework/StikJIT" \
         "$APP/Frameworks/StikJIT.framework/Info.plist"; do
    if [ ! -f "$f" ]; then
        echo "  MISSING  ${f#$APP/}" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$(basename "$f")" "${f#$APP/}"
    fi
done

# The Simplified Chinese localization, and the English one beside it. Both are
# hand-maintained variant groups in the checked-in project, so a regenerated or
# merged project can drop them without the build noticing -- the app would then
# install and run in English for everyone. Fail instead.
for f in en.lproj/Localizable.strings zh-Hans.lproj/Localizable.strings \
         en.lproj/InfoPlist.strings zh-Hans.lproj/InfoPlist.strings; do
    if [ ! -f "$APP/$f" ]; then
        echo "  MISSING  $f" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$(basename "$f")" "$f"
    fi
done

[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

echo "==> packaging"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
SAPP="$STAGE/Payload/$(basename "$APP")"

# Ship it unsigned (see the top of this file). The build already ran with
# CODE_SIGNING_ALLOWED=NO, so there should be nothing to strip -- but check, and
# refuse to package if a signature is there anyway. A signature in the bundle is
# the difference between an IPA an installer re-signs cleanly and one that
# crashes the moment it is opened, and that failure looks nothing like a
# packaging error.
signed=0
while IFS= read -r f; do
    if codesign -d "$f" >/dev/null 2>&1; then
        echo "  SIGNED   ${f#$SAPP/}  <-- the IPA must ship unsigned" >&2
        signed=1
    fi
done < <(find "$SAPP" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
if find "$SAPP" \( -name _CodeSignature -o -name embedded.mobileprovision \) -print -quit | grep -q .; then
    echo "  SIGNED   _CodeSignature / embedded.mobileprovision  <-- the IPA must ship unsigned" >&2
    signed=1
fi
if [ $signed -ne 0 ]; then
    echo "==> bundle carries a signature; refusing to package" >&2
    rm -rf "$STAGE"
    exit 1
fi
echo "  ok       bundle is unsigned"

TMP_IPA="$STAGE/Husk.ipa"
( cd "$STAGE" && zip -qry "$TMP_IPA" Payload )

# Atomic replace so a half-written IPA never sits where the good one was.
mv -f "$TMP_IPA" "$OUT"
rm -rf "$STAGE"
echo "==> $OUT  ($(du -h "$OUT" | cut -f1))"
