ARCHS = armv7s armv7

include theos/makefiles/common.mk

ADDITIONAL_CCFLAGS  = -Qunused-arguments -w

TWEAK_NAME = itracer
itracer_FILES = Tweak.xmi tracer.mm hijack_arm.S
itracer_LIBRARIES = substrate
itracer_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

