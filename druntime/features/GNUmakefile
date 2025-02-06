SED:=sed
ifeq ($(OS),$(filter $(OS),freebsd osx))
    SED_INPLACE:=-i ''
else
    SED_INPLACE:=-i''
endif

export FEATURE_TMPDIR:=$(CURDIR)/features/tmp
export CC

src/core/sys/linux/config.d: src/core/sys/linux/config.d.in
	@cp $< $@
	@if [ "$(OS)" = linux ] \
	    && ./features/cc_has_function.sh 'closefrom' '#include <unistd.h>'; \
	then \
	$(SED) $(SED_INPLACE) "s/@HAVE_CLOSEFROM@/true/" $@; \
	else \
	$(SED) $(SED_INPLACE) "s/@HAVE_CLOSEFROM@/false/" $@; \
	fi
