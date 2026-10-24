#!/usr/bin/env python3
"""Generate a handwritten-structure Xcode pbxproj for Framekeep."""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Framekeep"


def nid(key: str) -> str:
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:24].upper()


SWIFT = sorted(p.relative_to(ROOT) for p in APP.rglob("*.swift"))
ASSET = Path("Framekeep/Resources/Assets.xcassets")
PLIST = Path("Framekeep/Info.plist")
ENT = Path("Framekeep/Framekeep.entitlements")

PROJECT = nid("project")
TARGET = nid("target")
MAIN_GROUP = nid("group.main")
PRODUCTS = nid("group.products")
SOURCES_PHASE = nid("phase.sources")
RESOURCES_PHASE = nid("phase.resources")
FRAMEWORKS_PHASE = nid("phase.frameworks")
UNLOCK_PHASE = nid("phase.unlock-codesign")
PROJECT_CONFIGS = nid("configs.project")
TARGET_CONFIGS = nid("configs.target")
PROJECT_DEBUG = nid("xcconfig.project.debug")
PROJECT_RELEASE = nid("xcconfig.project.release")
TARGET_DEBUG = nid("xcconfig.target.debug")
TARGET_RELEASE = nid("xcconfig.target.release")
PRODUCT_REF = nid("ref.product")
ASSET_REF = nid("ref.assets")
ASSET_BUILD = nid("build.assets")
PLIST_REF = nid("ref.plist")
ENT_REF = nid("ref.entitlements")


def group_id(parts: tuple[str, ...]) -> str:
    return nid("group." + "/".join(parts))


# Nested groups under Framekeep/
folders: set[tuple[str, ...]] = {("Framekeep",)}
for swift in SWIFT:
    parts = swift.parts
    for i in range(1, len(parts)):
        folders.add(parts[:i])

file_refs: dict[Path, str] = {}
build_files: dict[Path, str] = {}
for swift in SWIFT:
    file_refs[swift] = nid(f"ref.{swift}")
    build_files[swift] = nid(f"build.{swift}")


def file_ref_entry(path: Path, ref: str, extra: str = "") -> str:
    last = path.name
    return (
        f"\t\t{ref} /* {last} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {last}; "
        f"sourceTree = \"<group>\"; {extra}}};\n"
    )


lines: list[str] = []
a = lines.append
a("// !$*UTF8*$!\n")
a("{\n")
a("\tarchiveVersion = 1;\n")
a("\tclasses = {\n")
a("\t};\n")
a("\tobjectVersion = 56;\n")
a("\tobjects = {\n\n")

a("/* Begin PBXBuildFile section */\n")
for swift in SWIFT:
    a(f"\t\t{build_files[swift]} /* {swift.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[swift]} /* {swift.name} */; }};\n")
a(f"\t\t{ASSET_BUILD} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSET_REF} /* Assets.xcassets */; }};\n")
a("/* End PBXBuildFile section */\n\n")

a("/* Begin PBXFileReference section */\n")
a(f"\t\t{PRODUCT_REF} /* Framekeep.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Framekeep.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
a(f"\t\t{ASSET_REF} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};\n")
a(f"\t\t{PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n")
a(f"\t\t{ENT_REF} /* Framekeep.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Framekeep.entitlements; sourceTree = \"<group>\"; }};\n")
for swift in SWIFT:
    a(file_ref_entry(swift, file_refs[swift]))
a("/* End PBXFileReference section */\n\n")

a("/* Begin PBXFrameworksBuildPhase section */\n")
a(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{\n")
a("\t\t\tisa = PBXFrameworksBuildPhase;\n")
a("\t\t\tbuildActionMask = 2147483647;\n")
a("\t\t\tfiles = (\n")
a("\t\t\t);\n")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;\n")
a("\t\t};\n")
a("/* End PBXFrameworksBuildPhase section */\n\n")

# Groups
children_of: dict[tuple[str, ...], list[str]] = {folder: [] for folder in folders}
children_of[("Framekeep",)]  # ensure

# Map folder -> child folders and files
rel_files_by_parent: dict[tuple[str, ...], list[Path]] = {}
for swift in SWIFT:
    parent = swift.parts[:-1]
    rel_files_by_parent.setdefault(parent, []).append(swift)

for folder in sorted(folders, key=lambda x: (len(x), x)):
    if folder == ("Framekeep",):
        continue
    parent = folder[:-1]
    children_of.setdefault(parent, []).append(folder)

a("/* Begin PBXGroup section */\n")

# Root
a(f"\t\t{MAIN_GROUP} = {{\n")
a("\t\t\tisa = PBXGroup;\n")
a("\t\t\tchildren = (\n")
a(f"\t\t\t\t{group_id(('Framekeep',))} /* Framekeep */,\n")
a(f"\t\t\t\t{PRODUCTS} /* Products */,\n")
a("\t\t\t);\n")
a('\t\t\tsourceTree = "<group>";\n')
a("\t\t};\n")

a(f"\t\t{PRODUCTS} /* Products */ = {{\n")
a("\t\t\tisa = PBXGroup;\n")
a("\t\t\tchildren = (\n")
a(f"\t\t\t\t{PRODUCT_REF} /* Framekeep.app */,\n")
a("\t\t\t);\n")
a("\t\t\tname = Products;\n")
a('\t\t\tsourceTree = "<group>";\n')
a("\t\t};\n")

for folder in sorted(folders, key=lambda x: (len(x), x)):
    gid = group_id(folder)
    a(f"\t\t{gid} /* {folder[-1]} */ = {{\n")
    a("\t\t\tisa = PBXGroup;\n")
    a("\t\t\tchildren = (\n")
    if folder == ("Framekeep",):
        a(f"\t\t\t\t{PLIST_REF} /* Info.plist */,\n")
        a(f"\t\t\t\t{ENT_REF} /* Framekeep.entitlements */,\n")
        a(f"\t\t\t\t{ASSET_REF} /* Assets.xcassets */,\n")
    subfolders = sorted(
        [f for f in folders if len(f) == len(folder) + 1 and f[: len(folder)] == folder],
        key=lambda x: x[-1],
    )
    for sub in subfolders:
        a(f"\t\t\t\t{group_id(sub)} /* {sub[-1]} */,\n")
    for swift in sorted(rel_files_by_parent.get(folder, []), key=lambda p: p.name):
        a(f"\t\t\t\t{file_refs[swift]} /* {swift.name} */,\n")
    a("\t\t\t);\n")
    a(f"\t\t\tpath = {folder[-1]};\n")
    a('\t\t\tsourceTree = "<group>";\n')
    a("\t\t};\n")

a("/* End PBXGroup section */\n\n")

a("/* Begin PBXNativeTarget section */\n")
a(f"\t\t{TARGET} /* Framekeep */ = {{\n")
a("\t\t\tisa = PBXNativeTarget;\n")
a(f"\t\t\tbuildConfigurationList = {TARGET_CONFIGS} /* Build configuration list for PBXNativeTarget \"Framekeep\" */;\n")
a("\t\t\tbuildPhases = (\n")
a(f"\t\t\t\t{UNLOCK_PHASE} /* Unlock Codesign */,\n")
a(f"\t\t\t\t{SOURCES_PHASE} /* Sources */,\n")
a(f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,\n")
a(f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,\n")
a("\t\t\t);\n")
a("\t\t\tbuildRules = (\n")
a("\t\t\t);\n")
a("\t\t\tdependencies = (\n")
a("\t\t\t);\n")
a("\t\t\tname = Framekeep;\n")
a("\t\t\tproductName = Framekeep;\n")
a(f"\t\t\tproductReference = {PRODUCT_REF} /* Framekeep.app */;\n")
a("\t\t\tproductType = \"com.apple.product-type.application\";\n")
a("\t\t};\n")
a("/* End PBXNativeTarget section */\n\n")

a("/* Begin PBXProject section */\n")
a(f"\t\t{PROJECT} /* Project object */ = {{\n")
a("\t\t\tisa = PBXProject;\n")
a("\t\t\tattributes = {\n")
a("\t\t\t\tBuildIndependentTargetsInParallel = 1;\n")
a("\t\t\t\tLastSwiftUpdateCheck = 1500;\n")
a("\t\t\t\tLastUpgradeCheck = 1500;\n")
a("\t\t\t\tTargetAttributes = {\n")
a(f"\t\t\t\t\t{TARGET} = {{\n")
a("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n")
a("\t\t\t\t\t};\n")
a("\t\t\t\t};\n")
a("\t\t\t};\n")
a(f"\t\t\tbuildConfigurationList = {PROJECT_CONFIGS} /* Build configuration list for PBXProject \"Framekeep\" */;\n")
a('\t\t\tcompatibilityVersion = "Xcode 14.0";\n')
a("\t\t\tdevelopmentRegion = \"zh-Hant\";\n")
a("\t\t\thasScannedForEncodings = 0;\n")
a("\t\t\tknownRegions = (\n")
a("\t\t\t\t\"zh-Hant\",\n")
a("\t\t\t\ten,\n")
a("\t\t\t\tBase,\n")
a("\t\t\t);\n")
a(f"\t\t\tmainGroup = {MAIN_GROUP};\n")
a(f"\t\t\tproductRefGroup = {PRODUCTS} /* Products */;\n")
a('\t\t\tprojectDirPath = "";\n')
a('\t\t\tprojectRoot = "";\n')
a("\t\t\ttargets = (\n")
a(f"\t\t\t\t{TARGET} /* Framekeep */,\n")
a("\t\t\t);\n")
a("\t\t};\n")
a("/* End PBXProject section */\n\n")

a("/* Begin PBXResourcesBuildPhase section */\n")
a(f"\t\t{RESOURCES_PHASE} /* Resources */ = {{\n")
a("\t\t\tisa = PBXResourcesBuildPhase;\n")
a("\t\t\tbuildActionMask = 2147483647;\n")
a("\t\t\tfiles = (\n")
a(f"\t\t\t\t{ASSET_BUILD} /* Assets.xcassets in Resources */,\n")
a("\t\t\t);\n")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;\n")
a("\t\t};\n")
a("/* End PBXResourcesBuildPhase section */\n\n")

a("/* Begin PBXShellScriptBuildPhase section */\n")
a(f"\t\t{UNLOCK_PHASE} /* Unlock Codesign */ = {{\n")
a("\t\t\tisa = PBXShellScriptBuildPhase;\n")
a("\t\t\talwaysOutOfDate = 1;\n")
a("\t\t\tbuildActionMask = 2147483647;\n")
a("\t\t\tfiles = (\n")
a("\t\t\t);\n")
a("\t\t\tinputPaths = (\n")
a("\t\t\t);\n")
a('\t\t\tname = "Unlock Codesign";\n')
a("\t\t\toutputPaths = (\n")
a("\t\t\t);\n")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;\n")
a("\t\t\tshellPath = /bin/sh;\n")
a('\t\t\tshellScript = "\\"${SRCROOT}/scripts/unlock-codesign.sh\\"\\n";\n')
a("\t\t};\n")
a("/* End PBXShellScriptBuildPhase section */\n\n")

a("/* Begin PBXSourcesBuildPhase section */\n")
a(f"\t\t{SOURCES_PHASE} /* Sources */ = {{\n")
a("\t\t\tisa = PBXSourcesBuildPhase;\n")
a("\t\t\tbuildActionMask = 2147483647;\n")
a("\t\t\tfiles = (\n")
for swift in SWIFT:
    a(f"\t\t\t\t{build_files[swift]} /* {swift.name} in Sources */,\n")
a("\t\t\t);\n")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;\n")
a("\t\t};\n")
a("/* End PBXSourcesBuildPhase section */\n\n")

common_project = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 5.9;
"""

a("/* Begin XCBuildConfiguration section */\n")
a(f"\t\t{PROJECT_DEBUG} /* Debug */ = {{\n")
a("\t\t\tisa = XCBuildConfiguration;\n")
a("\t\t\tbuildSettings = {\n")
a(common_project)
a("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n")
a("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n")
a("\t\t\t\tENABLE_TESTABILITY = YES;\n")
a("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;\n")
a("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n")
a("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n")
a('\t\t\t\t\t"DEBUG=1",\n')
a('\t\t\t\t\t"$(inherited)",\n')
a("\t\t\t\t);\n")
a("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;\n")
a("\t\t\t\tONLY_ACTIVE_ARCH = YES;\n")
a("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n")
a("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";\n")
a("\t\t\t};\n")
a('\t\t\tname = Debug;\n')
a("\t\t};\n")

a(f"\t\t{PROJECT_RELEASE} /* Release */ = {{\n")
a("\t\t\tisa = XCBuildConfiguration;\n")
a("\t\t\tbuildSettings = {\n")
a(common_project)
a("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n")
a("\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n")
a("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;\n")
a("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n")
a("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";\n")
a("\t\t\t};\n")
a('\t\t\tname = Release;\n')
a("\t\t};\n")

target_settings = """
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = Framekeep/Framekeep.entitlements;
				CODE_SIGN_IDENTITY = "Framekeep Local Codesign";
				CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES;
				CODE_SIGN_STYLE = Manual;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = NO;
				ENABLE_DEBUG_DYLIB = NO;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Framekeep/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 0.1.0;
				OTHER_LDFLAGS = (
					"$(inherited)",
					"-lsqlite3",
				);
				OTHER_CODE_SIGN_FLAGS = "--timestamp=none";
				PRODUCT_BUNDLE_IDENTIFIER = app.framekeep.Framekeep;
				PRODUCT_NAME = Framekeep;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.9;
"""

a(f"\t\t{TARGET_DEBUG} /* Debug */ = {{\n")
a("\t\t\tisa = XCBuildConfiguration;\n")
a("\t\t\tbuildSettings = {\n")
a(target_settings)
a("\t\t\t};\n")
a('\t\t\tname = Debug;\n')
a("\t\t};\n")

a(f"\t\t{TARGET_RELEASE} /* Release */ = {{\n")
a("\t\t\tisa = XCBuildConfiguration;\n")
a("\t\t\tbuildSettings = {\n")
a(target_settings)
a("\t\t\t};\n")
a('\t\t\tname = Release;\n')
a("\t\t};\n")
a("/* End XCBuildConfiguration section */\n\n")

a("/* Begin XCConfigurationList section */\n")
a(f"\t\t{PROJECT_CONFIGS} /* Build configuration list for PBXProject \"Framekeep\" */ = {{\n")
a("\t\t\tisa = XCConfigurationList;\n")
a("\t\t\tbuildConfigurations = (\n")
a(f"\t\t\t\t{PROJECT_DEBUG} /* Debug */,\n")
a(f"\t\t\t\t{PROJECT_RELEASE} /* Release */,\n")
a("\t\t\t);\n")
a("\t\t\tdefaultConfigurationIsVisible = 0;\n")
a("\t\t\tdefaultConfigurationName = Release;\n")
a("\t\t};\n")
a(f"\t\t{TARGET_CONFIGS} /* Build configuration list for PBXNativeTarget \"Framekeep\" */ = {{\n")
a("\t\t\tisa = XCConfigurationList;\n")
a("\t\t\tbuildConfigurations = (\n")
a(f"\t\t\t\t{TARGET_DEBUG} /* Debug */,\n")
a(f"\t\t\t\t{TARGET_RELEASE} /* Release */,\n")
a("\t\t\t);\n")
a("\t\t\tdefaultConfigurationIsVisible = 0;\n")
a("\t\t\tdefaultConfigurationName = Release;\n")
a("\t\t};\n")
a("/* End XCConfigurationList section */\n")

a("\t};\n")
a(f"\trootObject = {PROJECT} /* Project object */;\n")
a("}\n")

out = ROOT / "Framekeep.xcodeproj" / "project.pbxproj"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("".join(lines), encoding="utf-8")

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET}"
               BuildableName = "Framekeep.app"
               BlueprintName = "Framekeep"
               ReferencedContainer = "container:Framekeep.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET}"
            BuildableName = "Framekeep.app"
            BlueprintName = "Framekeep"
            ReferencedContainer = "container:Framekeep.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET}"
            BuildableName = "Framekeep.app"
            BlueprintName = "Framekeep"
            ReferencedContainer = "container:Framekeep.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
scheme_path = ROOT / "Framekeep.xcodeproj" / "xcshareddata" / "xcschemes" / "Framekeep.xcscheme"
scheme_path.parent.mkdir(parents=True, exist_ok=True)
scheme_path.write_text(scheme, encoding="utf-8")
print(f"wrote {out} ({len(SWIFT)} swift files)")
print(f"wrote {scheme_path} target={TARGET}")
