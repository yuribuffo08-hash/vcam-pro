TARGET := iphone:clang:16.5:16.5
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = vcamPrefs

vcamPrefs_FILES = VCAMPrefsListController.m
vcamPrefs_FRAMEWORKS = UIKit MobileCoreServices
vcamPrefs_PRIVATE_FRAMEWORKS = Preferences
vcamPrefs_INSTALL_PATH = /Library/PreferenceBundles
vcamPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceBundles/vcamPrefs.bundle$(ECHO_END)
	$(ECHO_NOTHING)cp -r Resources/* $(THEOS_STAGING_DIR)/Library/PreferenceBundles/vcamPrefs.bundle/$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/vcamPrefs.plist$(ECHO_END)
