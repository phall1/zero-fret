#!/usr/bin/env python3
"""Emit ZeroFret.xcodeproj/project.pbxproj.

Hand-maintaining 24-hex object identifiers is how pbxproj files rot. Deriving
them from a stable name keeps the file diffable and regenerable.
"""
import hashlib, os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()

def oid(key):
    return hashlib.md5(("zerofret:" + key).encode()).hexdigest()[:24].upper()

APP = "ZeroFret"
TESTS = "ZeroFretTests"
UITESTS = "ZeroFretUITests"
BUNDLE = "dev.phux.zerofret"

# path -> (group, filetype)
SWIFT = "sourcecode.swift"
app_sources = [
    "ZeroFret/App/ZeroFretApp.swift",
    "ZeroFret/Audio/AudioEngine.swift",
    "ZeroFret/Audio/RingBuffer.swift",
    "ZeroFret/Audio/Biquad.swift",
    "ZeroFret/Audio/PitchDetector.swift",
    "ZeroFret/Audio/Smoother.swift",
    "ZeroFret/Audio/NoiseGate.swift",
    "ZeroFret/Audio/PitchStability.swift",
    "ZeroFret/Audio/HarmonicScore.swift",
    "ZeroFret/Audio/TargetTracker.swift",
    "ZeroFret/Audio/DetectionWorker.swift",
    "ZeroFret/Audio/SyntheticInput.swift",
    "ZeroFret/Model/Tuning.swift",
    "ZeroFret/Model/TuningCollection.swift",
    "ZeroFret/Model/TunerState.swift",
    "ZeroFret/Model/StringAssigner.swift",
    "ZeroFret/Model/TunerEngine.swift",
    "ZeroFret/View/Theme.swift",
    "ZeroFret/View/TunerView.swift",
    "ZeroFret/View/StringCanvas.swift",
    "ZeroFret/View/TuningSheet.swift",
    "ZeroFret/View/TuningEditor.swift",
    "ZeroFret/View/SettingsView.swift",
    "ZeroFret/Haptics/TrueTick.swift",
    "ZeroFret/Haptics/BeatHaptics.swift",
]
app_resources = ["ZeroFret/Assets.xcassets"]
app_other = ["ZeroFret/App/Info.plist",
             "ZeroFret/Support/ZFAtomics.h",
             "ZeroFret/Support/ZeroFret-Bridging-Header.h"]

# The test bundle has no host app: it compiles the pure DSP/model layer itself.
# A host app would launch the real UI on the simulator, request the microphone,
# and block the run on a permission alert.
shared_with_tests = [
    "ZeroFret/Audio/RingBuffer.swift",
    "ZeroFret/Audio/Biquad.swift",
    "ZeroFret/Audio/PitchDetector.swift",
    "ZeroFret/Audio/Smoother.swift",
    "ZeroFret/Audio/NoiseGate.swift",
    "ZeroFret/Audio/PitchStability.swift",
    "ZeroFret/Audio/HarmonicScore.swift",
    "ZeroFret/Audio/TargetTracker.swift",
    "ZeroFret/Model/Tuning.swift",
    "ZeroFret/Model/TuningCollection.swift",
    "ZeroFret/Model/TunerState.swift",
    "ZeroFret/Model/StringAssigner.swift",
]
uitest_sources = [
    "ZeroFretUITests/TunerUITests.swift",
]
test_sources = [
    "ZeroFretTests/SignalHarness.swift",
    "ZeroFretTests/MusicMathTests.swift",
    "ZeroFretTests/RingBufferTests.swift",
    "ZeroFretTests/BiquadTests.swift",
    "ZeroFretTests/PitchDetectorTests.swift",
    "ZeroFretTests/SmootherTests.swift",
    "ZeroFretTests/StringAssignerTests.swift",
    "ZeroFretTests/NoiseGateTests.swift",
    "ZeroFretTests/PitchStabilityTests.swift",
    "ZeroFretTests/HarmonicScoreTests.swift",
    "ZeroFretTests/TargetTrackerTests.swift",
    "ZeroFretTests/AcceptanceTests.swift",
    "ZeroFretTests/TuningCollectionTests.swift",
    "ZeroFretTests/InstrumentTests.swift",
]

def ftype(path):
    if path.endswith(".swift"): return SWIFT
    if path.endswith(".h"): return "sourcecode.c.h"
    if path.endswith(".plist"): return "text.plist.xml"
    if path.endswith(".xcassets"): return "folder.assetcatalog"
    if path.endswith(".md"): return "net.daringfireball.markdown"
    if path.endswith(".xcconfig"): return "text.xcconfig"
    return "text"

all_files = sorted(set(app_sources + app_resources + app_other + test_sources + uitest_sources))

lines = []
def w(s=""): lines.append(s)

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")
w()

# ---- PBXBuildFile ----
w("/* Begin PBXBuildFile section */")
build_files = []   # (id, fileref, comment)
for p in app_sources:
    build_files.append((oid("bf:app:" + p), oid("fr:" + p), os.path.basename(p), "app"))
for p in app_resources:
    build_files.append((oid("bf:appres:" + p), oid("fr:" + p), os.path.basename(p), "appres"))
for p in shared_with_tests:
    build_files.append((oid("bf:test:" + p), oid("fr:" + p), os.path.basename(p), "test"))
for p in test_sources:
    build_files.append((oid("bf:test:" + p), oid("fr:" + p), os.path.basename(p), "test"))
for p in uitest_sources:
    build_files.append((oid("bf:uitest:" + p), oid("fr:" + p), os.path.basename(p), "uitest"))
for bid, fid, name, kind in build_files:
    w(f"\t\t{bid} /* {name} in {'Resources' if kind=='appres' else 'Sources'} */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};")
w("/* End PBXBuildFile section */")
w()

# ---- PBXFileReference ----
w("/* Begin PBXFileReference section */")
for p in all_files:
    w(f'\t\t{oid("fr:"+p)} /* {os.path.basename(p)} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype(p)}; path = {os.path.basename(p)}; sourceTree = "<group>"; }};')
w(f'\t\t{oid("prod:app")} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
w(f'\t\t{oid("prod:uitests")} /* {UITESTS}.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {UITESTS}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
w(f'\t\t{oid("prod:tests")} /* {TESTS}.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {TESTS}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
for p in ["README.md", "zero-fret-og-spec.md", "LICENSE",
          "Config/Base.xcconfig", "Config/Signing.example.xcconfig"]:
    w(f'\t\t{oid("fr:"+p)} /* {os.path.basename(p)} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype(p)}; path = {os.path.basename(p)}; sourceTree = "<group>"; }};')
w("/* End PBXFileReference section */")
w()

# ---- PBXFrameworksBuildPhase ----
w("/* Begin PBXFrameworksBuildPhase section */")
for t in ("app", "tests", "uitests"):
    w(f"\t\t{oid('frameworks:'+t)} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
w("/* End PBXFrameworksBuildPhase section */")
w()

# ---- PBXGroup ----
def group(key, name, children, path=None):
    label = f" /* {name} */" if name else ""
    w(f"\t\t{oid('grp:'+key)}{label} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for cid, cname in children:
        w(f"\t\t\t\t{cid} /* {cname} */,")
    w("\t\t\t);")
    if path is not None:
        w(f"\t\t\tpath = {path};")
    elif name:
        w(f"\t\t\tname = {name};")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")

w("/* Begin PBXGroup section */")

subgroups = {
    "App": ["ZeroFret/App/ZeroFretApp.swift", "ZeroFret/App/Info.plist"],
    "Audio": [p for p in app_sources if p.startswith("ZeroFret/Audio/")],
    "Model": [p for p in app_sources if p.startswith("ZeroFret/Model/")],
    "View": [p for p in app_sources if p.startswith("ZeroFret/View/")],
    "Haptics": [p for p in app_sources if p.startswith("ZeroFret/Haptics/")],
    "Support": ["ZeroFret/Support/ZFAtomics.h", "ZeroFret/Support/ZeroFret-Bridging-Header.h"],
}
for name, members in subgroups.items():
    group("ZeroFret/" + name, name,
          [(oid("fr:" + p), os.path.basename(p)) for p in sorted(members)], path=name)

group("ZeroFret", APP,
      [(oid("grp:ZeroFret/" + n), n) for n in subgroups]
      + [(oid("fr:ZeroFret/Assets.xcassets"), "Assets.xcassets")],
      path=APP)

group("ZeroFretTests", TESTS,
      [(oid("fr:" + p), os.path.basename(p)) for p in test_sources], path=TESTS)

group("Config", "Config",
      [(oid("fr:Config/Base.xcconfig"), "Base.xcconfig"),
       (oid("fr:Config/Signing.example.xcconfig"), "Signing.example.xcconfig")], path="Config")

group("ZeroFretUITests", UITESTS,
      [(oid("fr:" + p), os.path.basename(p)) for p in uitest_sources], path=UITESTS)

group("Products", "Products",
      [(oid("prod:app"), APP + ".app"), (oid("prod:tests"), TESTS + ".xctest"),
       (oid("prod:uitests"), UITESTS + ".xctest")])

group("root", "", [
    (oid("fr:README.md"), "README.md"),
    (oid("fr:LICENSE"), "LICENSE"),
    (oid("fr:zero-fret-og-spec.md"), "zero-fret-og-spec.md"),
    (oid("grp:Config"), "Config"),
    (oid("grp:ZeroFret"), APP),
    (oid("grp:ZeroFretTests"), TESTS),
    (oid("grp:ZeroFretUITests"), UITESTS),
    (oid("grp:Products"), "Products"),
])
w("/* End PBXGroup section */")
w()

# ---- PBXNativeTarget ----
w("/* Begin PBXNativeTarget section */")
def native_target(key, name, product_ref, product_type, phases, deps=()):
    w(f"\t\t{oid('target:'+key)} /* {name} */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {oid('cfglist:target:'+key)} /* Build configuration list for PBXNativeTarget \"{name}\" */;")
    w("\t\t\tbuildPhases = (")
    for pid, pname in phases:
        w(f"\t\t\t\t{pid} /* {pname} */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    for d in deps:
        w(f"\t\t\t\t{d} /* PBXTargetDependency */,")
    w("\t\t\t);")
    w(f"\t\t\tname = {name};")
    w(f"\t\t\tproductName = {name};")
    w(f"\t\t\tproductReference = {product_ref} /* {name}.{'app' if key=='app' else 'xctest'} */;")
    w(f'\t\t\tproductType = "{product_type}";')
    w("\t\t};")

native_target("app", APP, oid("prod:app"), "com.apple.product-type.application",
              [(oid("sources:app"), "Sources"),
               (oid("frameworks:app"), "Frameworks"),
               (oid("resources:app"), "Resources")])
native_target("tests", TESTS, oid("prod:tests"), "com.apple.product-type.bundle.unit-test",
              [(oid("sources:tests"), "Sources"),
               (oid("frameworks:tests"), "Frameworks")])
native_target("uitests", UITESTS, oid("prod:uitests"), "com.apple.product-type.bundle.ui-testing",
              [(oid("sources:uitests"), "Sources"),
               (oid("frameworks:uitests"), "Frameworks")],
              deps=[oid("dep:app")])
w("/* End PBXNativeTarget section */")
w()

# ---- PBXTargetDependency ----
w("/* Begin PBXTargetDependency section */")
w(f"\t\t{oid('dep:app')} /* PBXTargetDependency */ = {{")
w("\t\t\tisa = PBXTargetDependency;")
w(f"\t\t\ttarget = {oid('target:app')} /* {APP} */;")
w(f"\t\t\ttargetProxy = {oid('proxy:app')} /* PBXContainerItemProxy */;")
w("\t\t};")
w("/* End PBXTargetDependency section */")
w()
w("/* Begin PBXContainerItemProxy section */")
w(f"\t\t{oid('proxy:app')} /* PBXContainerItemProxy */ = {{")
w("\t\t\tisa = PBXContainerItemProxy;")
w(f"\t\t\tcontainerPortal = {oid('project')} /* Project object */;")
w("\t\t\tproxyType = 1;")
w(f"\t\t\tremoteGlobalIDString = {oid('target:app')};")
w(f"\t\t\tremoteInfo = {APP};")
w("\t\t};")
w("/* End PBXContainerItemProxy section */")
w()

# ---- PBXProject ----
w("/* Begin PBXProject section */")
w(f"\t\t{oid('project')} /* Project object */ = {{")
w("\t\t\tisa = PBXProject;")
w("\t\t\tattributes = {")
w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w("\t\t\t\tLastSwiftUpdateCheck = 2660;")
w("\t\t\t\tLastUpgradeCheck = 2660;")
w("\t\t\t\tTargetAttributes = {")
w(f"\t\t\t\t\t{oid('target:app')} = {{")
w("\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;")
w("\t\t\t\t\t};")
w(f"\t\t\t\t\t{oid('target:tests')} = {{")
w("\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;")
w("\t\t\t\t\t};")
w(f"\t\t\t\t\t{oid('target:uitests')} = {{")
w("\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;")
w(f"\t\t\t\t\t\tTestTargetID = {oid('target:app')};")
w("\t\t\t\t\t};")
w("\t\t\t\t};")
w("\t\t\t};")
w(f"\t\t\tbuildConfigurationList = {oid('cfglist:project')} /* Build configuration list for PBXProject \"{APP}\" */;")
w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
w("\t\t\tdevelopmentRegion = en;")
w("\t\t\thasScannedForEncodings = 0;")
w("\t\t\tknownRegions = (")
w("\t\t\t\ten,")
w("\t\t\t\tBase,")
w("\t\t\t);")
w(f"\t\t\tmainGroup = {oid('grp:root')};")
w(f"\t\t\tproductRefGroup = {oid('grp:Products')} /* Products */;")
w("\t\t\tprojectDirPath = \"\";")
w("\t\t\tprojectRoot = \"\";")
w("\t\t\ttargets = (")
w(f"\t\t\t\t{oid('target:app')} /* {APP} */,")
w(f"\t\t\t\t{oid('target:tests')} /* {TESTS} */,")
w(f"\t\t\t\t{oid('target:uitests')} /* {UITESTS} */,")
w("\t\t\t);")
w("\t\t};")
w("/* End PBXProject section */")
w()

# ---- PBXResourcesBuildPhase ----
w("/* Begin PBXResourcesBuildPhase section */")
w(f"\t\t{oid('resources:app')} /* Resources */ = {{")
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for bid, fid, name, kind in build_files:
    if kind == "appres":
        w(f"\t\t\t\t{bid} /* {name} in Resources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXResourcesBuildPhase section */")
w()

# ---- PBXSourcesBuildPhase ----
w("/* Begin PBXSourcesBuildPhase section */")
for key, kind in (("app", "app"), ("tests", "test"), ("uitests", "uitest")):
    w(f"\t\t{oid('sources:'+key)} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for bid, fid, name, k in build_files:
        if k == kind:
            w(f"\t\t\t\t{bid} /* {name} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
w("/* End PBXSourcesBuildPhase section */")
w()

# ---- XCBuildConfiguration ----
PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
    "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
    "CLANG_WARN_STRICT_PROTOTYPES": "YES",
    "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": "5.0",
}
PROJECT_DEBUG = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
}
PROJECT_RELEASE = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}
APP_COMMON = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_ASSET_PATHS": '""',
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "ZeroFret/App/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
    "MARKETING_VERSION": "1.1",
    "PRODUCT_BUNDLE_IDENTIFIER": "$(inherited)" if False else BUNDLE,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_OBJC_BRIDGING_HEADER": '"ZeroFret/Support/ZeroFret-Bridging-Header.h"',
    "TARGETED_DEVICE_FAMILY": '"1,2"',
}
TEST_COMMON = {
    "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "1.1",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE + ".tests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_OBJC_BRIDGING_HEADER": '"ZeroFret/Support/ZeroFret-Bridging-Header.h"',
    "TARGETED_DEVICE_FAMILY": '"1,2"',
}

UITEST_COMMON = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "1.1",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE + ".uitests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "TARGETED_DEVICE_FAMILY": '"1,2"',
    "TEST_TARGET_NAME": APP,
}

def build_config(key, name, settings, base=False):
    w(f"\t\t{oid('cfg:'+key+':'+name)} /* {name} */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    if base:
        w(f"\t\t\tbaseConfigurationReference = {oid('fr:Config/Base.xcconfig')} /* Base.xcconfig */;")
    w("\t\t\tbuildSettings = {")
    for k in sorted(settings):
        w(f"\t\t\t\t{k} = {settings[k]};")
    w("\t\t\t};")
    w(f"\t\t\tname = {name};")
    w("\t\t};")

w("/* Begin XCBuildConfiguration section */")
build_config("project", "Debug", {**PROJECT_COMMON, **PROJECT_DEBUG})
build_config("project", "Release", {**PROJECT_COMMON, **PROJECT_RELEASE})
build_config("target:app", "Debug", APP_COMMON, base=True)
build_config("target:app", "Release", APP_COMMON, base=True)
build_config("target:tests", "Debug", TEST_COMMON, base=True)
build_config("target:tests", "Release", TEST_COMMON, base=True)
build_config("target:uitests", "Debug", UITEST_COMMON, base=True)
build_config("target:uitests", "Release", UITEST_COMMON, base=True)
w("/* End XCBuildConfiguration section */")
w()

# ---- XCConfigurationList ----
w("/* Begin XCConfigurationList section */")
def cfg_list(key, label):
    w(f"\t\t{oid('cfglist:'+key)} /* Build configuration list for {label} */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{oid('cfg:'+key+':Debug')} /* Debug */,")
    w(f"\t\t\t\t{oid('cfg:'+key+':Release')} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
cfg_list("project", f'PBXProject "{APP}"')
cfg_list("target:app", f'PBXNativeTarget "{APP}"')
cfg_list("target:tests", f'PBXNativeTarget "{TESTS}"')
cfg_list("target:uitests", f'PBXNativeTarget "{UITESTS}"')
w("/* End XCConfigurationList section */")
w()

w("\t};")
w(f"\trootObject = {oid('project')} /* Project object */;")
w("}")

out_dir = os.path.join(ROOT, f"{APP}.xcodeproj")
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "project.pbxproj"), "w") as f:
    f.write("\n".join(lines) + "\n")
print("wrote", os.path.join(out_dir, "project.pbxproj"))
