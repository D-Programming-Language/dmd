#!/bin/bash

set -uexo pipefail

if [ -z ${N+x} ] ; then echo "Variable 'N' needs to be set."; exit 1; fi
if [ -z ${BRANCH+x} ] ; then echo "Variable 'BRANCH' needs to be set."; exit 1; fi
if [ -z ${OS_NAME+x} ] ; then echo "Variable 'OS_NAME' needs to be set."; exit 1; fi
if [ -z ${FULL_BUILD+x} ] ; then echo "Variable 'FULL_BUILD' needs to be set."; exit 1; fi
if [ -z ${MODEL+x} ] ; then echo "Variable 'MODEL' needs to be set."; exit 1; fi
if [ -z ${DMD+x} ] ; then echo "Variable 'DMD' needs to be set."; exit 1; fi

CURL_USER_AGENT="DMD-CI $(curl --version | head -n 1)"

# use faster ld.gold linker on linux
if [ "$OS_NAME" == "linux" ]; then
    mkdir -p linker
    rm -f linker/ld
    ln -s /usr/bin/ld.gold linker/ld
    NM="nm --print-size"
    export PATH="$PWD/linker:$PATH"
else
    NM=nm
fi

# clone druntime and phobos
clone() {
    local url="$1"
    local path="$2"
    local branch="$3"
    for i in {0..4}; do
        if git clone --depth=1 --branch "$branch" "$url" "$path"; then
            break
        elif [ $i -lt 4 ]; then
            sleep $((1 << $i))
        else
            echo "Failed to clone: ${url}"
            exit 1
        fi
    done
}

# build dmd, druntime, phobos
build() {
    source ~/dlang/*/activate # activate host compiler
    make -j$N -C src -f posix.mak MODEL=$MODEL HOST_DMD=$DMD ENABLE_RELEASE=1 ENABLE_WARNINGS=1 all
    make -j$N -C ../druntime -f posix.mak MODEL=$MODEL
    make -j$N -C ../phobos -f posix.mak MODEL=$MODEL
    deactivate # deactivate host compiler
}

# self-compile dmd
rebuild() {
    local build_path=generated/$OS_NAME/release/$MODEL
    local compare=${1:-0}
    # `generated` gets cleaned in the next step, so we create another _generated
    # The nested folder hierarchy is needed to conform to those specified in
    # the generated dmd.conf
    mkdir -p _${build_path}
    cp $build_path/dmd _${build_path}/host_dmd
    cp $build_path/dmd.conf _${build_path}
    make -j$N -C src -f posix.mak MODEL=$MODEL HOST_DMD=../_${build_path}/host_dmd clean
    make -j$N -C src -f posix.mak MODEL=$MODEL HOST_DMD=../_${build_path}/host_dmd ENABLE_RELEASE=1 ENABLE_WARNINGS=1 all

    # compare binaries to test reproducible build
    if [ $compare -eq 1 ]; then
        if ! diff _${build_path}/host_dmd $build_path/dmd; then
            $NM _${build_path}/host_dmd > a
            $NM $build_path/dmd > b
            diff -u a b
            exit 1
        fi
    fi
}

# test druntime, phobos, dmd
test() {
    test_dub_package
    make -j$N -C ../druntime -f posix.mak MODEL=$MODEL unittest
    make -j$N -C ../phobos -f posix.mak MODEL=$MODEL unittest
    test_dmd
}

# test dmd
test_dmd() {
    # test fewer compiler argument permutations for PRs to reduce CI load
    if [ "$FULL_BUILD" == "true" ] && [ "$OS_NAME" == "linux"  ]; then
        make -j$N -C test MODEL=$MODEL # all ARGS by default
    else
        make -j$N -C test MODEL=$MODEL ARGS="-O -inline -release"
    fi
}

# test dub package
test_dub_package() {
    source ~/dlang/*/activate # activate host compiler
    # GDC's standard library is too old for some example scripts
    if [ "${DMD:-dmd}" == "gdmd" ] ; then
        echo "Skipping DUB examples on GDC."
    else
        pushd test/dub_package
        for file in *.d ; do
            dub --single "$file"
        done
        popd
    fi
    deactivate
}

setup_repos() {
for proj in druntime phobos; do
    if [ $BRANCH != master ] && [ $BRANCH != stable ] &&
           ! git ls-remote --exit-code --heads https://github.com/dlang/$proj.git $BRANCH > /dev/null; then
        # use master as fallback for other repos to test feature branches
        clone https://github.com/dlang/$proj.git ../$proj master
    else
        clone https://github.com/dlang/$proj.git ../$proj $BRANCH
    fi
done
}

testsuite() {
    date
    for step in build test rebuild "rebuild 1" test_dmd; do
        $step
        date
    done
}

download_install_sh() {
  local mirrors location
  location="${1:-install.sh}"
  mirrors=(
    "https://dlang.org/install.sh"
    "https://downloads.dlang.org/other/install.sh"
    "https://nightlies.dlang.org/install.sh"
    "https://github.com/dlang/installer/raw/master/script/install.sh"
  )
  if [ -f "$location" ] ; then
      return
  fi
  for i in {0..4}; do
    for mirror in "${mirrors[@]}" ; do
        if curl -fsS -A "$CURL_USER_AGENT" --connect-timeout 5 --speed-time 30 --speed-limit 1024 "$mirror" -o "$location" ; then
            break 2
        fi
    done
    sleep $((1 << i))
  done
}

install_dub() {
  local url="https://github.com/dlang/dub/releases/download/v${DUB_VERSION}/dub-${DUB_VERSION}-${OS_NAME}-x86_64.tar.gz"
  local root_dir="$HOME/dlang"
  local dub="$root_dir/dub"
  local location="${dub}.tgz"
  if [ -f "${dub}" ] ; then
      return
  fi
  for i in {0..4}; do
    if curl -fsSL -A "$CURL_USER_AGENT" --connect-timeout 10 --speed-time 30 --speed-limit 1024 "$url" -o "$location" ; then
        break
    fi
    sleep $((1 << i))
  done
  tar -C "$root_dir" -zxf "$location"
}

activate_d() {
  download_install_sh "$@"
  if [ "${DMD:-dmd}" == "gdc" ] ; then
    export DUB_VERSION="1.6.0"
    install_dub
  fi
  CURL_USER_AGENT="$CURL_USER_AGENT" bash install.sh "$1" --activate
}
