#!/usr/bin/env python3
"""iphone_release.py: what every Release build of the iPhone app shares, defined once.

Two tools build the iPhone app for a device: Scripts/ios/app-size.py (unsigned, to measure the app) and
Scripts/ios/install-on-device.py (signed, to install it on the user's own iPhone). Both take their target, product
names, and small-code build settings from here, so that the app a person installs is built the way the app that was
measured is. Importing this module runs nothing.
"""
import sys

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

import size_settings  # noqa: E402  (the caller puts Scripts/ on sys.path; python3 -I does not)

# The target, which the scheme of the same name builds, and the SDK of a device build.
TARGET = "TextMouthiOS"
SDK = "iphoneos"
# The folder Xcode puts a Release device build's products in, and the product's name (project.yml sets it to TextMouth,
# as the Mac app's).
PRODUCTS_FOLDER = "Release-iphoneos"
APP_NAME = "TextMouth.app"


def release_settings(profile=size_settings.AUTO, environ=None):
    """The build settings of a small Release build for a device, as `NAME=VALUE` words for xcodebuild's command line:
    arm64 only, no index store and no code coverage (a build for use needs neither), -Osize, the size settings of
    `profile` (Scripts/size_settings.py: "full", "light", or "auto", which is full on GitHub Actions and light on a
    Mac), and the strip an archive does (DEPLOYMENT_POSTPROCESSING=YES: a plain build leaves the symbol table in the
    executable, 14.1 MB of the iPhone app's 27.5 MB on November 16, 2026; the target's own STRIP_INSTALLED_PRODUCT=YES
    and STRIP_STYLE=all then apply). Raises size_settings.UsageError for a profile it does not know."""
    return ["ARCHS=arm64", "COMPILER_INDEX_STORE_ENABLE=NO", "CLANG_COVERAGE_MAPPING=NO",
            "SWIFT_OPTIMIZATION_LEVEL=-Osize", *size_settings.settings(profile=profile, environ=environ),
            "DEPLOYMENT_POSTPROCESSING=YES"]


def app_path(derived_data):
    """The built app inside `derived_data`: Build/Products/Release-iphoneos/TextMouth.app, as a string."""
    return f"{derived_data}/Build/Products/{PRODUCTS_FOLDER}/{APP_NAME}"
