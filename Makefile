# iOS 12.5.7 (A7/A8) devices are arm64-only, so the arm64 slice deploys to 12.0.
# clang >= 12 cannot emit a valid arm64e slice for deployments below 14.0.
ifeq ($(THEOS_CURRENT_ARCH),arm64e)
export TARGET 			:= iphone:clang:latest:14.0
else
export TARGET 			:= iphone:clang:latest:12.0
endif
export ARCHS 			:= arm64 arm64e
export USE_DEPS 		:= 1
THEOS_PACKAGE_SCHEME	?=

ifeq ($(shell uname -s),Darwin)
CCACHE := $(shell command -v ccache 2>/dev/null)
export TARGET_CC 		:= $(CCACHE) $(shell xcrun -f clang)
export TARGET_CXX 		:= $(CCACHE) $(shell xcrun -f clang++)
endif

export LG_AVAILABILITY_CFLAGS := -Werror=unguarded-availability -Werror=unguarded-availability-new \
                                 -Werror=objc-method-access

INSTALL_TARGET_PROCESSES = backboardd SpringBoard chronod WidgetRenderer-Default WidgetRenderer-CarPlay assistivetouchd
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = liquidass

liquidass_FILES     = Tweak.x \
                      $(wildcard Hooks/*.x) \
                      $(wildcard LiquidAssPrefs/LGPrefsLiquid*.m) \
                      $(wildcard Shared/*.[xm])
liquidass_CFLAGS    = -fobjc-arc $(LG_AVAILABILITY_CFLAGS) -include $(CURDIR)/Shared/LGHookSafety.h
liquidass_USE_MODULES = 0
liquidass_FRAMEWORKS = UIKit QuartzCore CoreText CoreGraphics CoreMotion
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
liquidass_LIBRARIES += roothide
endif


include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += LiquidAssBackboardd LiquidAssRWB LiquidAssPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
