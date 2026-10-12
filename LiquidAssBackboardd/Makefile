ifeq ($(THEOS_CURRENT_ARCH),arm64e)
TARGET := iphone:clang:latest:14.0
else
TARGET := iphone:clang:latest:12.0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssBackboardd

LiquidAssBackboardd_FILES     = $(wildcard *.mm)
LiquidAssBackboardd_CFLAGS    = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions $(LG_AVAILABILITY_CFLAGS)
LiquidAssBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
LiquidAssBackboardd_LDFLAGS   = -lc++
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
LiquidAssBackboardd_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
