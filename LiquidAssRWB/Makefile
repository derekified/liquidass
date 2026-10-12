ifeq ($(THEOS_CURRENT_ARCH),arm64e)
TARGET := iphone:clang:latest:14.0
else
TARGET := iphone:clang:latest:12.0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssRWB

LiquidAssRWB_FILES = $(wildcard *.x) ../Shared/LGSharedSupport.m
LiquidAssRWB_CFLAGS = -fobjc-arc $(LG_AVAILABILITY_CFLAGS) -include $(CURDIR)/../Shared/LGHookSafety.h
LiquidAssRWB_FRAMEWORKS = UIKit
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
LiquidAssRWB_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
