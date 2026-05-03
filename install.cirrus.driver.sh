#!/bin/bash

# NOTA BENE - this script should be run as root

set -euo pipefail

# Store arguments before processing, in case we need to pass them to the pre617 script
script_arguments_pre617="${@}"

# Default values for optional flags (required by set -u)
dkms_action=''
dkms=false

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [KERNEL_VERSION]

Install or remove the Cirrus Logic CS8409 HDA audio driver for MacBook Pro on Ubuntu.

OPTIONS:
  -i, --install     Install driver via DKMS
  -r, --remove      Remove DKMS-installed driver
  -u, --uninstall   Alias for --remove
  -k, --kernel VER  Specify kernel version (default: running kernel)
  -d, --dkms        Prepare files for DKMS (skip make/install)
  -h, --help        Show this help message

EXAMPLES:
  sudo $0                          Install for the running kernel
  sudo $0 -k 6.8.0-45-generic     Install for a specific kernel version
  sudo $0 -i                       Install via DKMS
  sudo $0 -r                       Remove DKMS driver

NOTE: For kernels older than 6.17, this script automatically delegates to
      install.cirrus.driver.pre617.sh.
EOF
}

while [ $# -gt 0 ]
do
    case $1 in
    -h|--help) usage; exit 0;;
    -i|--install) dkms_action='install';;
    -k|--kernel) UNAME=$2; [[ -z $UNAME ]] && echo '-k|--kernel must be followed by a kernel version' && exit 1; shift;;
    -r|--remove) dkms_action='remove';;
    -u|--uninstall) dkms_action='remove';;
    -d|--dkms) dkms=true;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 1;;
    (*) break;;
    esac
    shift
done

# Use -k value if set, otherwise fall back to positional arg or running kernel
UNAME=${UNAME:-${1:-$(uname -r)}}
kernel_version=$(echo $UNAME | cut -d '-' -f1)  #ie 6.8.0
major_version=$(echo $kernel_version | cut -d '.' -f1)
minor_version=$(echo $kernel_version | cut -d '.' -f2)

revision=$(echo $UNAME | cut -d '.' -f3)
revpart1=$(echo $revision | cut -d '-' -f1)
revpart2=$(echo $revision | cut -d '-' -f2)
revpart3=$(echo $revision | cut -d '-' -f3)

# Route to the pre-6.17 script for older kernels
if [ $major_version -lt 6 -o \( $major_version -eq 6 -a $minor_version -lt 17 \) ]; then
    exec ./install.cirrus.driver.pre617.sh $script_arguments_pre617
fi

if [ -e dkms.conf.orig ]; then
    sed -i 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"/' dkms.conf
else
    sed -i.orig 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"/' dkms.conf
fi
sed -i 's/^BUILT_MODULE_LOCATION\[0\].*$/BUILT_MODULE_LOCATION[0]="build\/hda\/codecs\/cirrus"/' dkms.conf
sed -i 's/^PRE_BUILD.*$/PRE_BUILD="install.cirrus.driver.sh -k $kernelver --dkms"/' dkms.conf

if [[ $dkms_action == 'install' ]]; then

    # Remove any non-dkms module to avoid filename conflicts under /lib/modules/{kernel}/
    update_dir="/lib/modules/${UNAME}/updates/codecs/cirrus"
    [[ -e $update_dir/snd-hda-codec-cs8409.ko ]] && rm $update_dir/snd-hda-codec-cs8409.ko && echo "removed $update_dir/snd-hda-codec-cs8409.ko"

    bash dkms.sh

    # Ubuntu installs dkms modules to updates/dkms, ignoring DEST_MODULE_LOCATION.
    # Using updates/ ensures the original kernel module is not overwritten.
    update_dir="/lib/modules/${UNAME}/updates/dkms"
    echo -e "\ncontents of $update_dir"
    ls -lA $update_dir
    exit

elif [[ $dkms_action == 'remove' ]]; then

    # dkms remove restores the archived base kernel module and removes the dkms subtree
    bash dkms.sh -r
    exit

fi

# Verify Ubuntu kernel headers are installed
if [ ! -d /usr/src/linux-headers-${UNAME} ]; then
    echo "Error: Linux kernel headers not found at /usr/src/linux-headers-${UNAME}"
    echo "Install them with: sudo apt install linux-headers-${UNAME}"
    exit 1
fi

cur_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
build_dir='build'
patch_dir="$cur_dir/patch_cirrus"
makefiles_dir="$cur_dir/makefiles"
hda_dir="$cur_dir/$build_dir/hda"
update_dir="/lib/modules/${UNAME}/updates"

[[ -d $hda_dir ]] && rm -rf $hda_dir
[[ ! -d $build_dir ]] && mkdir $build_dir

# Ubuntu kernels are significantly modified from mainline (extensive backports).
# We must use the Ubuntu kernel source, not a mainline tarball.
# NOTE: HWE kernels are NOT supported — there is no linux-source-* package for them.
if [ ! -e /usr/src/linux-source-$kernel_version.tar.bz2 ]; then

    echo "Ubuntu kernel source not found: /usr/src/linux-source-$kernel_version.tar.bz2"
    echo "Attempting to download linux-source-$kernel_version via apt-get download..."

    # Use /tmp so that _apt sandbox user can read the downloaded .deb.
    # apt-get download fails with "Permission denied" when the target directory
    # lives under a home dir that _apt cannot access (APT sandbox, Ubuntu 20.04+).
    local_tmp_deb=$(mktemp -d /tmp/macbook-src-XXXXXX)
    pushd "$local_tmp_deb" > /dev/null

    set +e
    apt-get download linux-source-$kernel_version
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to download linux-source-$kernel_version."
        echo "Install manually with: sudo apt install linux-source-$kernel_version"
        popd > /dev/null
        rm -rf "$local_tmp_deb"
        exit 1
    fi
    set -e

    echo "Extracting kernel sound/hda source..."
    dpkg-deb -x *.deb .
    # Cache tarball so subsequent runs skip the 193MB download
    cp usr/src/linux-source-*/linux-source-*.tar.bz2 \
        /usr/src/linux-source-$kernel_version.tar.bz2 2>/dev/null || true
    tar --strip-components=2 -xvf usr/src/linux-source-*/linux-source-*.tar.bz2 \
        --directory="$cur_dir/$build_dir" linux-source-$kernel_version/sound/hda

    popd > /dev/null
    rm -rf "$local_tmp_deb"

else
    tar --strip-components=2 -xvf /usr/src/linux-source-$kernel_version.tar.bz2 \
        --directory="$cur_dir/$build_dir" linux-source-$kernel_version/sound/hda
fi

# Replace upstream Makefiles with our custom ones
mv $hda_dir/Makefile $hda_dir/Makefile.orig
mv $hda_dir/common/Makefile $hda_dir/common/Makefile.orig
mv $hda_dir/codecs/Makefile $hda_dir/codecs/Makefile.orig
mv $hda_dir/codecs/cirrus/Makefile $hda_dir/codecs/cirrus/Makefile.orig

cp $makefiles_dir/Makefile $hda_dir
cp $makefiles_dir/Makefile_common $hda_dir/common/Makefile
cp $makefiles_dir/Makefile_codecs $hda_dir/codecs/Makefile
cp $makefiles_dir/Makefile_cirrus $hda_dir/codecs/cirrus/Makefile

# Copy Cirrus patch headers
cp $patch_dir/cirrus_apple.h $hda_dir/codecs/cirrus
cp $patch_dir/patch_cirrus_boot84.h $hda_dir/codecs/cirrus
cp $patch_dir/patch_cirrus_new84.h $hda_dir/codecs/cirrus
cp $patch_dir/patch_cirrus_real84.h $hda_dir/codecs/cirrus
cp $patch_dir/patch_cirrus_real84_i2c.h $hda_dir/codecs/cirrus

pushd $hda_dir > /dev/null

# Ubuntu 6.17 is the current tested/supported kernel version.
# iscurrent: 1 = known-good range, 2 = newer than tested (may have issues), -1 = too old
current_major=6
current_minor_ubuntu=17
current_rev_ubuntu=6
latest_rev_ubuntu=6

if [ $major_version -gt $current_major ]; then
    iscurrent=2
elif [ $major_version -eq $current_major -a $minor_version -gt $current_minor_ubuntu ]; then
    iscurrent=2
elif [ $major_version -eq $current_major -a $minor_version -eq $current_minor_ubuntu -a $revpart2 -gt $latest_rev_ubuntu ]; then
    iscurrent=2
elif [ $major_version -eq $current_major -a $minor_version -eq $current_minor_ubuntu -a $revpart2 -ge $current_rev_ubuntu ]; then
    iscurrent=1
else
    iscurrent=-1
fi

if [ $iscurrent -gt 1 ]; then
    echo "Warning: kernel version is newer than tested — build problems may occur"
fi

patch -b -p1 <../../patch_cs8409.c.diff

if [ $iscurrent -ge 0 ]; then
    patch -b -p1 <../../patch_cs8409.h.diff
else
    echo "Error: patch for this older kernel version is not implemented"
    exit 1
fi

popd > /dev/null

[[ ! $dkms_action == 'install' ]] && [[ ! -d $update_dir ]] && mkdir $update_dir

if [[ ! $dkms = true ]]; then
    # dwarves provides pahole, required for BTF generation during kernel module build.
    # Without it the build emits "pahole version differs from the one used to build the kernel".
    apt-get install -y --no-install-recommends dwarves 2>/dev/null || true
    make KERNELRELEASE=$UNAME
    make install KERNELRELEASE=$UNAME
    echo -e "\ncontents of $update_dir/codecs/cirrus"
    ls -lA $update_dir/codecs/cirrus
fi
