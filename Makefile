TARGET := iphone:clang:16.5:14.0

ARCHS = arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating

SBCPUFloating_FILES = Tweak.xm

SBCPUFloating_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
