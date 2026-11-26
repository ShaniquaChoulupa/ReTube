TARGET := iphone:clang:latest:4.3
ARCHS := armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TubeReplacerClassic

TubeReplacerClassic_FILES = trlog.m subscripts.m deviceauth.x \
	classic.x \
	signin.x \
	classicauth.m \
	../googleapp/Translators/TRRequestBuilder.m \
	../googleapp/Translators/TRJSONUtils.m \
	../common/YoutubeClientType.m \
	../common/Protobuf.m \
	../base64/NSData+Base64.m \
	../base64/NSString+Base64.m

# -I.. makes `common/...` and `base64/...` includes resolve like in the main tweak.
TubeReplacerClassic_CFLAGS = -fno-objc-arc -I.. -I../googleapp/Translators -I../common

TubeReplacerClassic_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
