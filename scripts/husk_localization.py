#!/usr/bin/env python3
"""Keep Simplifed Chinese localization wired into the checked-in Xcode project.

The IPA is built from src/app/Husk.xcodeproj as committed -- xcodegen is
deliberately not installed, so package_ipa.sh uses the checked-in project rather
than regenerating one. That means the localization resource variant groups have
to be present in project.pbxproj itself.

Upstream regenerates the project whenever it adds a source file, and a
regenerated project does not know about this fork's en.lproj / zh-Hans.lproj.
This script puts them back after a sync. It is idempotent: running it on an
already-patched project changes nothing.

Usage:  scripts/husk_localization.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "src" / "app"
PBX = APP / "Husk.xcodeproj" / "project.pbxproj"

# Fixed object ids. The literal 24-character form is what the pbxproj format
# uses; these were picked so they cannot collide with an id Xcode or xcodegen
# generates (those are effectively random).
FR = {
    "en": {"Localizable.strings": "A1B2C3D4E5F60718293A4B01",
           "InfoPlist.strings": "A1B2C3D4E5F60718293A4B03"},
    "zh-Hans": {"Localizable.strings": "A1B2C3D4E5F60718293A4B02",
                "InfoPlist.strings": "A1B2C3D4E5F60718293A4B04"},
}
VG = {"Localizable.strings": "A1B2C3D4E5F60718293A4B05",
      "InfoPlist.strings": "A1B2C3D4E5F60718293A4B06"}
BF = {"Localizable.strings": "A1B2C3D4E5F60718293A4B07",
      "InfoPlist.strings": "A1B2C3D4E5F60718293A4B08"}

MARKER = VG["Localizable.strings"]

# The variant groups live inside the "Husk" PBXGroup, the one whose path is
# `Husk`. That membership matters for the build, not just the navigator: a
# variant group with sourceTree `<group>` has its children's paths resolved
# against the enclosing group, and a group that belongs to no group at all is
# resolved against the project directory -- so `zh-Hans.lproj/...` would be
# looked for at src/app/zh-Hans.lproj/... and the build would fail with
# "Build input file cannot be found".
HUSK_GROUP = "0F8D2787A26076A289B9B8EA"
HUSK_GROUP_ANCHOR = "\t\t\t\tFA84FD81F71FF2ACDEB879A5 /* Resources */,\n"
HUSK_GROUP_CHILDREN = "".join(
    f"\t\t\t\t{VG[name]} /* {name} */,\n"
    for name in ("Localizable.strings", "InfoPlist.strings")
)
HUSK_GROUP_MARK = f"\t\t\t\t{VG['Localizable.strings']} /* Localizable.strings */,\n"


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def insert_before(text, anchor, block, what):
    if anchor not in text:
        die(f"could not find {what} anchor in project.pbxproj")
    return text.replace(anchor, block + anchor, 1)


def main():
    if not PBX.is_file():
        die(f"no project at {PBX}")

    # The strings themselves. Without these the variant groups would reference
    # files that are not on disk, which fails the build rather than the UI.
    for lang in ("en", "zh-Hans"):
        for name in ("Localizable.strings", "InfoPlist.strings"):
            if not (APP / "Husk" / f"{lang}.lproj" / name).is_file():
                die(f"missing localization resource Husk/{lang}.lproj/{name}")

    text = PBX.read_text(encoding="utf-8")

    if MARKER in text:
        # Already wired in. Still make sure both things a merge can quietly drop
        # are present: the known region (a regenerated project lists only the
        # languages it knows) and the variant groups' membership in the Husk
        # group, without which their paths resolve to the wrong directory.
        changed = False
        if "zh-Hans" not in text.split("knownRegions = (", 1)[1].split(");", 1)[0]:
            text = text.replace("knownRegions = (\n\t\t\t\tBase,\n\t\t\t\ten,\n",
                                "knownRegions = (\n\t\t\t\tBase,\n\t\t\t\ten,\n\t\t\t\t\"zh-Hans\",\n", 1)
            changed = True
            print("knownRegions: added zh-Hans")
        if HUSK_GROUP_MARK not in text:
            text = insert_before(text, HUSK_GROUP_ANCHOR, HUSK_GROUP_CHILDREN, "Husk group")
            changed = True
            print("Husk group: added the localization variant groups")
        if changed:
            PBX.write_text(text, encoding="utf-8")
        else:
            print("localization already present in project.pbxproj")
        return

    # 1. File references, one per (language, file). `name` is the language and
    #    `path` keeps the .lproj directory, which is the shape a variant group
    #    expects.
    ref_lines = []
    for lang in ("en", "zh-Hans"):
        lang_literal = lang if lang == "en" else f'"{lang}"'
        for name in ("Localizable.strings", "InfoPlist.strings"):
            ref_lines.append(
                f'\t\t{FR[lang][name]} /* {lang} */ = {{isa = PBXFileReference; '
                f'lastKnownFileType = text.plist.strings; name = {lang_literal}; '
                f'path = "{lang}.lproj/{name}"; sourceTree = "<group>"; }};\n'
            )
    ref_block = "".join(ref_lines)

    # 2. Variant groups, and the build files that put them in Resources.
    vg_lines = []
    bf_lines = []
    for name in ("Localizable.strings", "InfoPlist.strings"):
        children = "".join(
            f"\t\t\t\t{FR[lang][name]} /* {lang} */,\n" for lang in ("en", "zh-Hans")
        )
        vg_lines.append(
            f'\t\t{VG[name]} /* {name} */ = {{\n'
            f"\t\t\tisa = PBXVariantGroup;\n"
            f"\t\t\tchildren = (\n{children}\t\t\t);\n"
            f"\t\t\tname = {name};\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};\n"
        )
        bf_lines.append(
            f'\t\t{BF[name]} /* {name} in Resources */ = {{isa = PBXBuildFile; '
            f'fileRef = {VG[name]} /* {name} */; }};\n'
        )
    vg_block = "".join(vg_lines)
    bf_block = "".join(bf_lines)

    var_block = (
        "/* Begin PBXVariantGroup section */\n" + vg_block +
        "/* End PBXVariantGroup section */\n\n"
    )

    text = insert_before(text, "/* End PBXBuildFile section */", bf_block, "PBXBuildFile")
    text = insert_before(text, "/* End PBXFileReference section */", ref_block, "PBXFileReference")
    # The variant group is its own section, so it goes after the file reference
    # section rather than inside it.
    end_refs = "/* End PBXFileReference section */\n"
    text = text.replace(end_refs, end_refs + "\n" + var_block, 1)

    # 3. Resources build phase: the app target's phase is the one holding
    #    cacert.pem. Anchor on that rather than on a section header, because
    #    there can be more than one resources phase.
    anchor = "\t\t\t\t50A3A90912B5C9D90B87D9BF /* cacert.pem in Resources */,\n"
    if anchor not in text:
        die("could not find the app Resources build phase")
    files_block = "".join(
        f"\t\t\t\t{BF[name]} /* {name} in Resources */,\n"
        for name in ("InfoPlist.strings", "Localizable.strings")
    )
    text = text.replace(anchor, files_block + anchor, 1)

    # 4. The region has to be known or the compiler never emits the language.
    kr_anchor = "knownRegions = (\n\t\t\t\tBase,\n\t\t\t\ten,\n"
    if kr_anchor not in text:
        die("could not find knownRegions")
    text = text.replace(kr_anchor, kr_anchor + '\t\t\t\t"zh-Hans",\n', 1)

    # 5. Put the variant groups inside the Husk group so their paths resolve to
    #    src/app/Husk/... rather than src/app/... (see HUSK_GROUP_ANCHOR).
    text = insert_before(text, HUSK_GROUP_ANCHOR, HUSK_GROUP_CHILDREN, "Husk group")

    PBX.write_text(text, encoding="utf-8")
    print("localization wired into project.pbxproj")


if __name__ == "__main__":
    main()