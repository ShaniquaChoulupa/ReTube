TARGET := iphone:clang:latest:5.0
ARCHS := armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TubeReplacerCaptureApp
CAPTURE_APP = 1

GOOGLE_APP_FILES = $(THEOS_PROJECT_DIR)/googleapp
COMMON = $(THEOS_PROJECT_DIR)/common
COMMON_GOOGLE = $(THEOS_PROJECT_DIR)/common-google

TubeReplacerCaptureApp_FILES = $(GOOGLE_APP_FILES)/signin.x \
	remove-gplus.x \
	resumables.x \
	$(GOOGLE_APP_FILES)/crashreporter.x \
	$(GOOGLE_APP_FILES)/Translators/TRJSONUtils.m \
	$(GOOGLE_APP_FILES)/Translators/TRContiunation.m \
	$(GOOGLE_APP_FILES)/Translators/TRRequestBuilder.m \
	$(GOOGLE_APP_FILES)/general.m \
	potoken/potoken.m \
	potoken/potoken-google.m \
	$(THEOS_PROJECT_DIR)/base64/NSData+Base64.m \
	$(THEOS_PROJECT_DIR)/base64/NSString+Base64.m \
	$(COMMON)/Protobuf.m \
	$(COMMON)/YoutubeClientType.m
TubeReplacerCaptureApp_CFLAGS = -fno-objc-arc -I$(THEOS_PROJECT_DIR) -I$(THEOS_PROJECT_DIR)/captureapp -I$(THEOS_PROJECT_DIR)/googleapp -I$(THEOS_PROJECT_DIR)/googleapp/Translators -I$(THEOS_PROJECT_DIR)/base64 -DGOOGLE_APP=1
# TubeReplacerCaptureApp_LDFLAGS = ../lib/libposixshim.a

include $(THEOS_MAKE_PATH)/tweak.mk
