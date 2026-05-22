dnl Copyright (C) 2017  Trevor Woerner <twoerner@gmail.com>

AC_INIT([Rockchip rkdeveloptool], 1.32, [Eddie Cai <eddie.cai.linux@gmail.com>], rkdeveloptool)
AC_PREREQ([2.68])
AC_CONFIG_SRCDIR(main.cpp)
AC_CONFIG_AUX_DIR(cfg)
AM_INIT_AUTOMAKE([foreign no-dist-gzip dist-bzip2 1.9 subdir-objects])
AM_CONFIG_HEADER(cfg/config.h)

SUBDIRS=""

AC_PROG_CPP
AC_PROG_CXX
AC_PROG_CXXCPP
AC_PROG_MAKE_SET
AC_PROG_INSTALL
AC_PROG_LN_S

AC_CANONICAL_HOST
case "$host_os" in
	freebsd*)
		CPPFLAGS="$CFLAGS -I/usr/local/include"
		LDFLAGS="$LDFLAGS -L/usr/local/lib"
		;;
	openbsd*)
		CPPFLAGS="$CFLAGS -I/usr/local/include"
		LDFLAGS="$LDFLAGS -L/usr/local/lib"
		;;
	*)
		;;
esac


PKG_CHECK_MODULES(LIBUSB1,libusb-1.0)
PKG_CHECK_MODULES(OPENSSL_CRYPTO, libcrypto)

AC_ARG_ENABLE([static],
	[AS_HELP_STRING([--enable-static],
		[statically link libusb-1.0 and libcrypto (libc and libstdc++ stay dynamic; default: no)])],
	[case "$enableval" in
		yes|no) enable_static=$enableval ;;
		*) AC_MSG_ERROR([--enable-static accepts only "yes" or "no" (got: $enableval)]) ;;
	esac],
	[enable_static=no])

if test "x$enable_static" = "xyes"; then
	if test "x$ac_cv_env_LIBUSB1_LIBS_set" = "xset"; then
		AC_MSG_WARN([--enable-static overrides LIBUSB1_LIBS from environment])
	fi
	if test "x$ac_cv_env_OPENSSL_CRYPTO_LIBS_set" = "xset"; then
		AC_MSG_WARN([--enable-static overrides OPENSSL_CRYPTO_LIBS from environment])
	fi

	# Resolve the absolute path to a static archive, preferring the Homebrew opt
	# symlink so 'brew upgrade' does not strand the build with a stale Cellar
	# path. Validates that pkg-config emits the expected -l token then builds
	# the link line with exact token matching (awk, not sed).
	#   $1: pkg-config module name (e.g. libusb-1.0)
	#   $2: dynamic -l flag pkg-config emits (e.g. -lusb-1.0)
	#   $3: archive filename (e.g. libusb-1.0.a)
	#   $4: Homebrew opt formula name (e.g. libusb)
	# Sets rkd_static_libs to the final link line.
	_rkd_resolve_static () {
		_libdir=`$PKG_CONFIG --variable=libdir "$1"`
		if test -z "$_libdir"; then
			AC_MSG_RESULT([pkg-config gave no libdir])
			AC_MSG_ERROR([$1.pc lacks libdir])
		fi
		case "$_libdir" in
			*" "*|*"	"*)
				AC_MSG_RESULT([libdir contains whitespace])
				AC_MSG_ERROR([libdir contains whitespace and is not supported: $_libdir]) ;;
		esac
		for _prefix in /opt/homebrew /usr/local; do
			if test -f "$_prefix/opt/$4/lib/$3"; then
				_libdir="$_prefix/opt/$4/lib"
				break
			fi
		done
		if test ! -f "$_libdir/$3"; then
			AC_MSG_RESULT([not found])
			AC_MSG_ERROR([$3 not found at $_libdir])
		fi
		AC_MSG_RESULT([$_libdir/$3])
		_raw=`$PKG_CONFIG --static --libs "$1"`
		case " $_raw " in
			*" $2 "*) ;;
			*) AC_MSG_ERROR([pkg-config --static --libs $1 lacks $2 (got: $_raw); cannot force static link]) ;;
		esac
		rkd_static_libs=`echo "$_raw" | awk -v archive="$_libdir/$3" -v drop="$2" '{
			out = archive
			for (i = 1; i <= NF; i++) {
				if ($i == drop) continue
				if ($i ~ /^-L/) continue
				out = out " " $i
			}
			print out
		}'`
	}

	AC_MSG_CHECKING([for libusb-1.0 static archive])
	_rkd_resolve_static libusb-1.0 -lusb-1.0 libusb-1.0.a libusb
	LIBUSB1_LIBS=$rkd_static_libs

	AC_MSG_CHECKING([for libcrypto static archive])
	_rkd_resolve_static libcrypto -lcrypto libcrypto.a openssl@3
	OPENSSL_CRYPTO_LIBS=$rkd_static_libs
fi

AC_CONFIG_FILES([Makefile])

AC_OUTPUT
