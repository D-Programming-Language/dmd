# get OS and MODEL
include osmodel.mak

ifeq (,$(TARGET_CPU))
    $(info no cpu specified, assuming X86)
    TARGET_CPU=X86
endif

ifeq (X86,$(TARGET_CPU))
    TARGET_CH = $C/code_x86.h
    TARGET_OBJS = cg87.o cgxmm.o cgsched.o cod1.o cod2.o cod3.o cod4.o ptrntab.o
else
    ifeq (stub,$(TARGET_CPU))
        TARGET_CH = $C/code_stub.h
        TARGET_OBJS = platform_stub.o
    else
        $(error unknown TARGET_CPU: '$(TARGET_CPU)')
    endif
endif

INSTALL_DIR=../../install
# can be set to override the default /etc/
SYSCONFDIR=/etc/
PGO_DIR=$(abspath pgo)

C=backend
TK=tk
ROOT=root

ifeq (osx,$(OS))
    export MACOSX_DEPLOYMENT_TARGET=10.3
endif
LDFLAGS=-lm -lstdc++ -lpthread

#ifeq (osx,$(OS))
#	HOST_CC=clang++
#else
	HOST_CC=g++
#endif
CC=$(HOST_CC)
AR=ar
GIT=git

# Host D compiler for bootstrapping
ifeq (,$(AUTO_BOOTSTRAP))
  # No bootstrap, a $(HOST_DC) installation must be available
  HOST_DC?=dmd
  HOST_DC_FULL:=$(shell which $(HOST_DC))
  ifeq (,$(HOST_DC_FULL))
    $(error '$(HOST_DC)' not found, get a D compiler or make AUTO_BOOTSTRAP=1)
  endif
  HOST_DC_RUN:=$(HOST_DC)
  HOST_DC:=$(HOST_DC_FULL)
else
  # Auto-bootstrapping, will download dmd automatically
  HOST_DMD_VER=2.067.1
  HOST_DMD_ROOT=/tmp/.host_dmd-$(HOST_DMD_VER)
  # dmd.2.067.1.osx.zip or dmd.2.067.1.freebsd-64.zip
  HOST_DMD_ZIP=dmd.$(HOST_DMD_VER).$(OS)$(if $(filter $(OS),freebsd),-$(MODEL),).zip
  # http://downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.osx.zip
  HOST_DMD_URL=http://downloads.dlang.org/releases/2.x/$(HOST_DMD_VER)/$(HOST_DMD_ZIP)
  HOST_DMD=$(HOST_DMD_ROOT)/dmd2/$(OS)/$(if $(filter $(OS),osx),bin,bin$(MODEL))/dmd
  HOST_DC=$(HOST_DMD)
  HOST_DC_RUN=$(HOST_DC) -conf=$(dir $(HOST_DC))dmd.conf
endif

# Compiler Warnings
ifdef ENABLE_WARNINGS
WARNINGS := -Wall -Wextra \
	-Wno-attributes \
	-Wno-char-subscripts \
	-Wno-deprecated \
	-Wno-empty-body \
	-Wno-format \
	-Wno-missing-braces \
	-Wno-missing-field-initializers \
	-Wno-overloaded-virtual \
	-Wno-parentheses \
	-Wno-reorder \
	-Wno-return-type \
	-Wno-sign-compare \
	-Wno-strict-aliasing \
	-Wno-switch \
	-Wno-type-limits \
	-Wno-unknown-pragmas \
	-Wno-unused-function \
	-Wno-unused-label \
	-Wno-unused-parameter \
	-Wno-unused-value \
	-Wno-unused-variable
# GCC Specific
ifeq ($(HOST_CC), g++)
WARNINGS := $(WARNINGS) \
	-Wno-logical-op \
	-Wno-narrowing \
	-Wno-unused-but-set-variable \
	-Wno-uninitialized
endif
# Clang Specific
ifeq ($(HOST_CC), clang++)
WARNINGS := $(WARNINGS) \
	-Wno-tautological-constant-out-of-range-compare \
	-Wno-tautological-compare \
	-Wno-constant-logical-operand \
	-Wno-self-assign -Wno-self-assign
# -Wno-sometimes-uninitialized
endif
else
# Default Warnings
WARNINGS := -Wno-deprecated -Wstrict-aliasing
# Clang Specific
ifeq ($(HOST_CC), clang++)
WARNINGS := $(WARNINGS) \
    -Wno-logical-op-parentheses \
    -Wno-dynamic-class-memaccess \
    -Wno-switch
endif
endif

OS_UPCASE := $(shell echo $(OS) | tr '[a-z]' '[A-Z]')

MMD=-MMD -MF $(basename $@).deps

# Default compiler flags for all source files
CFLAGS := $(WARNINGS) \
	-fno-exceptions -fno-rtti \
	-D__pascal= -DMARS=1 -DTARGET_$(OS_UPCASE)=1 -DDM_TARGET_CPU_$(TARGET_CPU)=1 \
	$(MODEL_FLAG)
# GCC Specific
ifeq ($(HOST_CC), g++)
CFLAGS := $(CFLAGS) \
    -std=gnu++98
endif
# Default D compiler flags for all source files
DFLAGS=

ifneq (,$(DEBUG))
ENABLE_DEBUG := 1
endif

# Append different flags for debugging, profiling and release.
ifdef ENABLE_DEBUG
CFLAGS += -g -g3 -DDEBUG=1 -DUNITTEST
DFLAGS += -g -debug
else
CFLAGS += -O2
DFLAGS += -O -inline
endif
ifdef ENABLE_PROFILING
CFLAGS  += -pg -fprofile-arcs -ftest-coverage
LDFLAGS += -pg -fprofile-arcs -ftest-coverage
endif
ifdef ENABLE_PGO_GENERATE
CFLAGS  += -fprofile-generate=${PGO_DIR}
endif
ifdef ENABLE_PGO_USE
CFLAGS  += -fprofile-use=${PGO_DIR} -freorder-blocks-and-partition
endif
ifdef ENABLE_LTO
CFLAGS  += -flto
LDFLAGS += -flto
endif

# Uniqe extra flags if necessary
DMD_FLAGS  := -I$(ROOT) -Wuninitialized
GLUE_FLAGS := -I$(ROOT) -I$(TK) -I$(C)
BACK_FLAGS := -I$(ROOT) -I$(TK) -I$(C) -I. -DDMDV2=1
ROOT_FLAGS := -I$(ROOT)

ifeq ($(OS), osx)
ifeq ($(MODEL), 64)
D_OBJC := 1
endif
endif

DMD_OBJS = \
	access.o attrib.o \
	cast.o \
	class.o \
	constfold.o cond.o \
	declaration.o dsymbol.o \
	enum.o expression.o func.o nogc.o \
	id.o \
	identifier.o impcnvtab.o import.o inifile.o init.o inline.o \
	lexer.o link.o mangle.o mars.o module.o mtype.o \
	cppmangle.o opover.o optimize.o \
	parse.o scope.o statement.o \
	struct.o template.o \
	version.o utf.o staticassert.o \
	entity.o doc.o macro.o \
	hdrgen.o delegatize.o interpret.o traits.o \
	builtin.o ctfeexpr.o clone.o aliasthis.o \
	arrayop.o json.o unittests.o \
	imphint.o argtypes.o apply.o sapply.o sideeffect.o \
	intrange.o canthrow.o target.o nspace.o errors.o \
	escape.o tokens.o globals.o

ifeq ($(D_OBJC),1)
	DMD_OBJS += objc.o
else
	DMD_OBJS += objc_stubs.o
endif

ROOT_OBJS = \
	rmem.o port.o man.o stringtable.o response.o \
	aav.o speller.o outbuffer.o object.o \
	filename.o file.o async.o checkedint.o \
	newdelete.o

GLUE_OBJS = \
	glue.o msc.o s2ir.o todt.o e2ir.o tocsym.o \
	toobj.o toctype.o toelfdebug.o toir.o \
	irstate.o typinf.o iasm.o


ifeq ($(D_OBJC),1)
	GLUE_OBJS += objc_glue.o
else
	GLUE_OBJS += objc_glue_stubs.o
endif

ifeq (osx,$(OS))
    GLUE_OBJS += libmach.o scanmach.o
else
    GLUE_OBJS += libelf.o scanelf.o
endif

#GLUE_OBJS=gluestub.o

BACK_OBJS = go.o gdag.o gother.o gflow.o gloop.o var.o el.o \
	glocal.o os.o nteh.o evalu8.o cgcs.o \
	rtlsym.o cgelem.o cgen.o cgreg.o out.o \
	blockopt.o cg.o type.o dt.o \
	debug.o code.o ee.o symbol.o \
	cgcod.o cod5.o outbuf.o \
	bcomplex.o aa.o ti_achar.o \
	ti_pvoid.o pdata.o cv8.o backconfig.o \
	divcoeff.o dwarf.o \
	ph2.o util2.o eh.o tk.o strtold.o \
	$(TARGET_OBJS)

ifeq (osx,$(OS))
	BACK_OBJS += machobj.o
else
	BACK_OBJS += elfobj.o
endif

SRC = win32.mak posix.mak osmodel.mak \
	mars.c enum.c struct.c dsymbol.c import.c idgen.d impcnvgen.c \
	identifier.c mtype.c expression.c optimize.c template.h \
	template.c lexer.c declaration.c cast.c cond.h cond.c link.c \
	aggregate.h parse.c statement.c constfold.c version.h version.c \
	inifile.c module.c scope.c init.h init.c attrib.h \
	attrib.c opover.c class.c mangle.c func.c nogc.c inline.c \
	access.c complex_t.h \
	identifier.h parse.h \
	scope.h enum.h import.h mars.h module.h mtype.h dsymbol.h \
	declaration.h lexer.h expression.h statement.h \
	utf.h utf.c staticassert.h staticassert.c \
	entity.c \
	doc.h doc.c macro.h macro.c hdrgen.h hdrgen.c arraytypes.h \
	delegatize.c interpret.c traits.c cppmangle.c \
	builtin.c clone.c lib.h arrayop.c \
	aliasthis.h aliasthis.c json.h json.c unittests.c imphint.c \
	argtypes.c apply.c sapply.c sideeffect.c \
	intrange.h intrange.c canthrow.c target.c target.h \
	scanmscoff.c scanomf.c ctfe.h ctfeexpr.c \
	ctfe.h ctfeexpr.c visitor.h nspace.h nspace.c errors.h errors.c \
	escape.c tokens.h tokens.c globals.h globals.c objc.c objc.h objc_stubs.c

ROOT_SRC = $(ROOT)/root.h \
	$(ROOT)/array.h \
	$(ROOT)/rmem.h $(ROOT)/rmem.c $(ROOT)/port.h $(ROOT)/port.c \
	$(ROOT)/man.c $(ROOT)/newdelete.c \
	$(ROOT)/checkedint.h $(ROOT)/checkedint.c \
	$(ROOT)/stringtable.h $(ROOT)/stringtable.c \
	$(ROOT)/response.c $(ROOT)/async.h $(ROOT)/async.c \
	$(ROOT)/aav.h $(ROOT)/aav.c \
	$(ROOT)/longdouble.h $(ROOT)/longdouble.c \
	$(ROOT)/speller.h $(ROOT)/speller.c \
	$(ROOT)/outbuffer.h $(ROOT)/outbuffer.c \
	$(ROOT)/object.h $(ROOT)/object.c \
	$(ROOT)/filename.h $(ROOT)/filename.c \
	$(ROOT)/file.h $(ROOT)/file.c

GLUE_SRC = glue.c msc.c s2ir.c todt.c e2ir.c tocsym.c \
	toobj.c toctype.c tocvdebug.c toir.h toir.c \
	libmscoff.c scanmscoff.c irstate.h irstate.c typinf.c iasm.c \
	toelfdebug.c libomf.c scanomf.c libelf.c scanelf.c libmach.c scanmach.c \
	tk.c eh.c gluestub.c objc_glue.c objc_glue_stubs.c

BACK_SRC = \
	$C/cdef.h $C/cc.h $C/oper.h $C/ty.h $C/optabgen.c \
	$C/global.h $C/code.h $C/type.h $C/dt.h $C/cgcv.h \
	$C/el.h $C/iasm.h $C/rtlsym.h \
	$C/bcomplex.c $C/blockopt.c $C/cg.c $C/cg87.c $C/cgxmm.c \
	$C/cgcod.c $C/cgcs.c $C/cgcv.c $C/cgelem.c $C/cgen.c $C/cgobj.c \
	$C/cgreg.c $C/var.c $C/strtold.c \
	$C/cgsched.c $C/cod1.c $C/cod2.c $C/cod3.c $C/cod4.c $C/cod5.c \
	$C/code.c $C/symbol.c $C/debug.c $C/dt.c $C/ee.c $C/el.c \
	$C/evalu8.c $C/go.c $C/gflow.c $C/gdag.c \
	$C/gother.c $C/glocal.c $C/gloop.c $C/newman.c \
	$C/nteh.c $C/os.c $C/out.c $C/outbuf.c $C/ptrntab.c $C/rtlsym.c \
	$C/type.c $C/melf.h $C/mach.h $C/mscoff.h $C/bcomplex.h \
	$C/cdeflnx.h $C/outbuf.h $C/token.h $C/tassert.h \
	$C/elfobj.c $C/cv4.h $C/dwarf2.h $C/exh.h $C/go.h \
	$C/dwarf.c $C/dwarf.h $C/aa.h $C/aa.c $C/tinfo.h $C/ti_achar.c \
	$C/ti_pvoid.c $C/platform_stub.c $C/code_x86.h $C/code_stub.h \
	$C/machobj.c $C/mscoffobj.c \
	$C/xmm.h $C/obj.h $C/pdata.c $C/cv8.c $C/backconfig.c $C/divcoeff.c \
	$C/md5.c $C/md5.h \
	$C/ph2.c $C/util2.c \
	$(TARGET_CH)

TK_SRC = \
	$(TK)/filespec.h $(TK)/mem.h $(TK)/list.h $(TK)/vec.h \
	$(TK)/filespec.c $(TK)/mem.c $(TK)/vec.c $(TK)/list.c

DEPS = $(patsubst %.o,%.deps,$(DMD_OBJS) $(ROOT_OBJS) $(GLUE_OBJS) $(BACK_OBJS))

all: dmd

auto-tester-build: dmd checkwhitespace ddmd
.PHONY: auto-tester-build

frontend.a: $(DMD_OBJS)
	$(AR) rcs frontend.a $(DMD_OBJS)

root.a: $(ROOT_OBJS)
	$(AR) rcs root.a $(ROOT_OBJS)

glue.a: $(GLUE_OBJS)
	$(AR) rcs glue.a $(GLUE_OBJS)

backend.a: $(BACK_OBJS)
	$(AR) rcs backend.a $(BACK_OBJS)

ifdef ENABLE_LTO
dmd: $(DMD_OBJS) $(ROOT_OBJS) $(GLUE_OBJS) $(BACK_OBJS)
	$(HOST_CC) -o dmd $(MODEL_FLAG) $^ $(LDFLAGS)
else
dmd: frontend.a root.a glue.a backend.a
	$(HOST_CC) -o dmd $(MODEL_FLAG) frontend.a root.a glue.a backend.a $(LDFLAGS)
endif

clean:
	rm -f $(DMD_OBJS) $(ROOT_OBJS) $(GLUE_OBJS) $(BACK_OBJS) dmd optab.o id.o impcnvgen idgen id.c id.h \
		impcnvtab.c optabgen debtab.c optab.c cdxxx.c elxxx.c fltables.c \
		tytab.c verstr.h core \
		*.cov *.deps *.gcda *.gcno *.a \
		$(GENSRC) $(MAGICPORT)
	@[ ! -d ${PGO_DIR} ] || echo You should issue manually: rm -rf ${PGO_DIR}

######## Download and install the last dmd buildable without dmd

ifneq (,$(AUTO_BOOTSTRAP))
.PHONY: host-dmd
host-dmd: ${HOST_DMD}

${HOST_DMD}:
	mkdir -p ${HOST_DMD_ROOT}
	TMPFILE=$$(mktemp deleteme.XXXXXXXX) && curl -fsSL ${HOST_DMD_URL} > $${TMPFILE}.zip && \
		unzip -qd ${HOST_DMD_ROOT} $${TMPFILE}.zip && rm $${TMPFILE}.zip
endif

######## generate a default dmd.conf

define DEFAULT_DMD_CONF
[Environment32]
DFLAGS=-I%@P%/../../druntime/import -I%@P%/../../phobos -L-L%@P%/../../phobos/generated/$(OS)/release/32$(if $(filter $(OS),osx),, -L--export-dynamic)

[Environment64]
DFLAGS=-I%@P%/../../druntime/import -I%@P%/../../phobos -L-L%@P%/../../phobos/generated/$(OS)/release/64$(if $(filter $(OS),osx),, -L--export-dynamic)
endef

export DEFAULT_DMD_CONF

dmd.conf:
	[ -f $@ ] || echo "$$DEFAULT_DMD_CONF" > $@

######## optabgen generates some source

optabgen: $C/optabgen.c $C/cc.h $C/oper.h
	$(CC) $(CFLAGS) -I$(TK) $< -o optabgen
	./optabgen

optabgen_output = debtab.c optab.c cdxxx.c elxxx.c fltables.c tytab.c
$(optabgen_output) : optabgen

######## idgen generates some source

idgen_output = id.h id.c
$(idgen_output) : idgen

idgen: idgen.d $(HOST_DC)
	$(HOST_DC_RUN) idgen.d
	./idgen

######### impcnvgen generates some source

impcnvtab_output = impcnvtab.c
$(impcnvtab_output) : impcnvgen

impcnvgen : mtype.h impcnvgen.c
	$(CC) $(CFLAGS) -I$(ROOT) impcnvgen.c -o impcnvgen
	./impcnvgen

#########

# Create (or update) the verstr.h file.
# The file is only updated if the VERSION file changes, or, only when RELEASE=1
# is not used, when the full version string changes (i.e. when the git hash or
# the working tree dirty states changes).
# The full version string have the form VERSION-devel-HASH(-dirty).
# The "-dirty" part is only present when the repository had uncommitted changes
# at the moment it was compiled (only files already tracked by git are taken
# into account, untracked files don't affect the dirty state).
VERSION := $(shell cat ../VERSION)
ifneq (1,$(RELEASE))
VERSION_GIT := $(shell printf "`$(GIT) rev-parse --short HEAD`"; \
       test -n "`$(GIT) status --porcelain -uno`" && printf -- -dirty)
VERSION := $(addsuffix -devel$(if $(VERSION_GIT),-$(VERSION_GIT)),$(VERSION))
endif
$(shell test \"$(VERSION)\" != "`cat verstr.h 2> /dev/null`" \
		&& printf \"$(VERSION)\" > verstr.h )

#########

$(DMD_OBJS) $(GLUE_OBJS) : $(idgen_output) $(impcnvgen_output)
$(BACK_OBJS) : $(optabgen_output)


# Specific dependencies other than the source file for all objects
########################################################################
# If additional flags are needed for a specific file add a _CFLAGS as a
# dependency to the object file and assign the appropriate content.

cg.o: fltables.c

cgcod.o: cdxxx.c

cgelem.o: elxxx.c

debug.o: debtab.c

iasm.o: CFLAGS += -fexceptions

inifile.o: CFLAGS += -DSYSCONFDIR='"$(SYSCONFDIR)"'

mars.o: verstr.h

var.o: optab.c tytab.c


# Generic rules for all source files
########################################################################
# Search the directory $(C) for .c-files when using implicit pattern
# matching below.
vpath %.c $(C)

$(DMD_OBJS): %.o: %.c posix.mak
	@echo "  (CC)  DMD_OBJS   $<"
	$(CC) -c $(CFLAGS) $(DMD_FLAGS) $(MMD) $<

$(BACK_OBJS): %.o: %.c posix.mak
	@echo "  (CC)  BACK_OBJS  $<"
	$(CC) -c $(CFLAGS) $(BACK_FLAGS) $(MMD) $<

$(GLUE_OBJS): %.o: %.c posix.mak
	@echo "  (CC)  GLUE_OBJS  $<"
	$(CC) -c $(CFLAGS) $(GLUE_FLAGS) $(MMD) $<

$(ROOT_OBJS): %.o: $(ROOT)/%.c posix.mak
	@echo "  (CC)  ROOT_OBJS  $<"
	$(CC) -c $(CFLAGS) $(ROOT_FLAGS) $(MMD) $<


-include $(DEPS)

######################################################

install: all
	$(eval bin_dir=$(if $(filter $(OS),osx), bin, bin$(MODEL)))
	mkdir -p $(INSTALL_DIR)/$(OS)/$(bin_dir)
	cp dmd $(INSTALL_DIR)/$(OS)/$(bin_dir)/dmd
	cp ../ini/$(OS)/$(bin_dir)/dmd.conf $(INSTALL_DIR)/$(OS)/$(bin_dir)/dmd.conf
	cp backendlicense.txt $(INSTALL_DIR)/dmd-backendlicense.txt
	cp boostlicense.txt $(INSTALL_DIR)/dmd-boostlicense.txt

######################################################

checkwhitespace: $(HOST_DC)
	$(HOST_DC_RUN) -run checkwhitespace $(SRC) $(GLUE_SRC) $(ROOT_SRC)

######################################################

gcov:
	gcov access.c
	gcov aliasthis.c
	gcov apply.c
	gcov arrayop.c
	gcov attrib.c
	gcov builtin.c
	gcov canthrow.c
	gcov cast.c
	gcov class.c
	gcov clone.c
	gcov cond.c
	gcov constfold.c
	gcov declaration.c
	gcov delegatize.c
	gcov doc.c
	gcov dsymbol.c
	gcov e2ir.c
	gcov eh.c
	gcov entity.c
	gcov enum.c
	gcov expression.c
	gcov func.c
	gcov nogc.c
	gcov glue.c
	gcov iasm.c
	gcov identifier.c
	gcov imphint.c
	gcov import.c
	gcov inifile.c
	gcov init.c
	gcov inline.c
	gcov interpret.c
	gcov ctfeexpr.c
	gcov irstate.c
	gcov json.c
	gcov lexer.c
ifeq (osx,$(OS))
	gcov libmach.c
else
	gcov libelf.c
endif
	gcov link.c
	gcov macro.c
	gcov mangle.c
	gcov mars.c
	gcov module.c
	gcov msc.c
	gcov mtype.c
	gcov nspace.c
ifeq ($(D_OBJC),1)
	gcov objc.c
	gcov objc_glue.c
else
	gcov objc_stubs.c
	gcov objc_glue_stubs.c
endif
	gcov opover.c
	gcov optimize.c
	gcov parse.c
	gcov scope.c
	gcov sideeffect.c
	gcov statement.c
	gcov staticassert.c
	gcov s2ir.c
	gcov struct.c
	gcov template.c
	gcov tk.c
	gcov tocsym.c
	gcov todt.c
	gcov toobj.c
	gcov toctype.c
	gcov toelfdebug.c
	gcov typinf.c
	gcov utf.c
	gcov version.c
	gcov intrange.c
	gcov target.c

#	gcov hdrgen.c
#	gcov tocvdebug.c

######################################################

zip:
	-rm -f dmdsrc.zip
	zip dmdsrc $(SRC) $(ROOT_SRC) $(GLUE_SRC) $(BACK_SRC) $(TK_SRC)

######################################################

../changelog.html: ../changelog.dd
	$(HOST_DC_RUN) -Df$@ $<

############################# DDMD stuff ############################

MAGICPORTDIR = magicport
MAGICPORTSRC = \
	$(MAGICPORTDIR)/magicport2.d $(MAGICPORTDIR)/ast.d \
	$(MAGICPORTDIR)/scanner.d $(MAGICPORTDIR)/tokens.d \
	$(MAGICPORTDIR)/parser.d $(MAGICPORTDIR)/dprinter.d \
	$(MAGICPORTDIR)/typenames.d $(MAGICPORTDIR)/visitor.d \
	$(MAGICPORTDIR)/namer.d

MAGICPORT = $(MAGICPORTDIR)/magicport2

$(MAGICPORT) : $(MAGICPORTSRC) $(HOST_DC)
	$(HOST_DC_RUN) -of$(MAGICPORT) $(MAGICPORTSRC)

GENSRC=access.d aggregate.d aliasthis.d apply.d \
	argtypes.d arrayop.d arraytypes.d \
	attrib.d builtin.d canthrow.d dcast.d \
	dclass.d clone.d cond.d constfold.d \
	cppmangle.d ctfeexpr.d declaration.d \
	delegatize.d doc.d dsymbol.d \
	denum.d expression.d func.d \
	hdrgen.d id.d identifier.d imphint.d \
	dimport.d dinifile.d inline.d init.d \
	dinterpret.d json.d lexer.d link.d \
	dmacro.d dmangle.d mars.d \
	dmodule.d mtype.d opover.d optimize.d \
	parse.d sapply.d dscope.d sideeffect.d \
	statement.d staticassert.d dstruct.d \
	target.d dtemplate.d traits.d dunittest.d \
	utf.d dversion.d visitor.d lib.d \
	nogc.d nspace.d errors.d tokens.d \
	globals.d escape.d \
	$(ROOT)/aav.d $(ROOT)/outbuffer.d $(ROOT)/stringtable.d \
	$(ROOT)/file.d $(ROOT)/filename.d $(ROOT)/speller.d \
	$(ROOT)/man.d $(ROOT)/response.d

MANUALSRC= \
	intrange.d complex.d \
	entity.d backend.d \
	$(ROOT)/array.d $(ROOT)/longdouble.d \
	$(ROOT)/rootobject.d $(ROOT)/port.d \
	$(ROOT)/rmem.d

ifeq ($(D_OBJC),1)
	GENSRC += objc.d
else
	MANUALSRC += objc.di objc_stubs.d
endif

mars.d : $(SRC) $(ROOT_SRC) magicport.json $(MAGICPORT) id.c impcnvtab.c
	$(MAGICPORT) . .

DSRC= $(GENSRC) $(MANUALSRC)

ddmd: mars.d $(MANUALSRC) newdelete.o glue.a backend.a $(HOST_DC)
	CC=$(HOST_CC) $(HOST_DC_RUN) $(MODEL_FLAG) $(DSRC) -ofddmd newdelete.o glue.a backend.a -vtls -J.. -d $(DFLAGS)

#############################

.DELETE_ON_ERROR: # GNU Make directive (delete output files on error)
