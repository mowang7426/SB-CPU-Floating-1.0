TARGET := iphone:clang:16.5:13.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating
SBCPUFloating_FILES = Tweak.xm
SBCPUFloating_CFLAGS = -fobjc-arc
SBCPUFloating_FRAMEWORKS = UIKit QuartzCore AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
