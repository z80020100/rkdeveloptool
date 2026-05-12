## Copyright (C) 2017  Trevor Woerner <twoerner@gmail.com>

SUBDIRS =
DIST_SUBDIRS = cfg

AM_CPPFLAGS = -Wall -Werror -Wextra -Wreturn-type -fno-strict-aliasing -D_FILE_OFFSET_BITS=64 -D_LARGE_FILE $(LIBUSB1_CFLAGS)

bin_PROGRAMS = rkdeveloptool afptool img_unpack

rkdeveloptool_SOURCES = main.cpp \
	crc.cpp DefineHeader.h Endian.h DefineHeader.h Property.hpp \
	RKBoot.cpp RKBoot.h \
	RKComm.cpp RKComm.h \
	RKDevice.cpp RKDevice.h \
	RKImage.cpp RKImage.h \
	RKLog.cpp RKLog.h \
	RKScan.cpp RKScan.h \
	gpt.h
rkdeveloptool_LDADD = $(LIBUSB1_LIBS)

afptool_SOURCES  = rockchip-tool/afptool.cpp
afptool_CPPFLAGS = $(AM_CPPFLAGS) -Wno-error -Wno-unused-result -I$(top_srcdir)/rockchip-tool
afptool_CXXFLAGS = -std=gnu++11

img_unpack_SOURCES  = rockchip-tool/img_unpack.cpp
img_unpack_CPPFLAGS = $(AM_CPPFLAGS) -Wno-error -Wno-unused-result -DUSE_OPENSSL $(OPENSSL_CRYPTO_CFLAGS) -I$(top_srcdir)/rockchip-tool
img_unpack_CXXFLAGS = -std=gnu++11
img_unpack_LDADD    = $(OPENSSL_CRYPTO_LIBS)

clean-local::
	rm -fr log
