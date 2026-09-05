TARGET := iphone:clang:16.5:16.5
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPro

VCamPro_FILES = src/Tweak.x src/VCamEngine.m src/VCamPreviewController.m src/VCamWebInjector.m
VCamPro_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreGraphics CoreImage QuartzCore WebKit AudioToolbox
VCamPro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += vcamPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
