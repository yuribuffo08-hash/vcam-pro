TARGET := iphone:clang:16.5:16.5
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = vcamPrefs

vcamPrefs_FILES = VCAMPrefsListController.m
vcamPrefs_FRAMEWORKS = UIKit MobileCoreServices
vcamPrefs_PRIVATE_FRAMEWORKS = Preferences
vcamPrefs_INSTALL_PATH = /Library/PreferenceBundles
vcamPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
