#!/bin/bash
set -euo pipefail
MODE="${1:-}"
if [[ "$MODE" == "rootless" || -z "$MODE" ]]; then
    make package -j8 ARCHS="arm64 arm64e" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
fi
if [[ "$MODE" == "rootful" || -z "$MODE" ]]; then
    make clean
    make package -j8 ARCHS="arm64 arm64e" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=
fi
# this only works if you got the roothide theos fork: https://github.com/roothide/theos
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
if [[ "$MODE" == "roothide" || -z "$MODE" ]]; then
    make clean
    make package -j8 ARCHS="arm64 arm64e" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
fi

if [[ "$MODE" == "sim" ]]; then
    make clean
    make -j8 ARCHS=x86_64 TARGET="simulator:clang:latest:12.0"
    cp .theos/obj/iphone_simulator/debug/*.dylib /opt/simject/
    ldid -S /opt/simject/*.dylib
    cp -r .theos/obj/iphone_simulator/debug/LiquidAssPrefs.bundle /opt/simject/PreferenceBundles/
    cp LiquidAssPrefs/layout/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist /opt/simject/PreferenceLoader/Preferences/
    resim
fi
