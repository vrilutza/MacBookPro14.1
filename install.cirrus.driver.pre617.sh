#!/bin/bash

# NOTA BENE - this script should be run as root
# Handles kernels older than 6.17 on Ubuntu.

set -euo pipefail

# Default values for optional flags (required by set -u)
dkms_action=''
dkms=false

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [KERNEL_VERSION]

Install or remove the Cirrus Logic CS8409 HDA audio driver for MacBook Pro on Ubuntu.
This script handles kernels older than 6.17.

OPTIONS:
  -i, --install     Install driver via DKMS
  -r, --remove      Remove DKMS-installed driver
  -u, --uninstall   Alias for --remove
  -k, --kernel VER  Specify kernel version (default: running kernel)
  -d, --dkms        Prepare files for DKMS (skip make/install)
  -h, --help        Show this help message

EXAMPLES:
  sudo $0                           Install for the running kernel
  sudo $0 -k 5.15.0-105-generic    Install for a specific kernel version
  sudo $0 -i                        Install via DKMS
  sudo $0 -r                        Remove DKMS driver
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
kernel_version=$(echo $UNAME | cut -d '-' -f1)  #ie 5.15.0
major_version=$(echo $kernel_version | cut -d '.' -f1)
minor_version=$(echo $kernel_version | cut -d '.' -f2)

revision=$(echo $UNAME | cut -d '.' -f3)
revpart1=$(echo $revision | cut -d '-' -f1)
revpart2=$(echo $revision | cut -d '-' -f2)
revpart3=$(echo $revision | cut -d '-' -f3)

# Kernels < 5.13 use the old "snd-hda-codec-cirrus" module name
if [ $major_version -eq 5 -a $minor_version -lt 13 ]; then
    if [ -e dkms.conf.orig ]; then
        sed -i 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cirrus"/' dkms.conf
    else
        sed -i.orig 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cirrus"/' dkms.conf
    fi
    PATCH_CIRRUS=true
else
    if [ -e dkms.conf.orig ]; then
        sed -i 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"/' dkms.conf
    else
        sed -i.orig 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"/' dkms.conf
    fi
    PATCH_CIRRUS=false
fi

sed -i 's/^BUILT_MODULE_LOCATION\[0\].*$/BUILT_MODULE_LOCATION[0]="build\/hda"/' dkms.conf
sed -i 's/^PRE_BUILD.*$/PRE_BUILD="install.cirrus.driver.pre617.sh -k $kernelver --dkms"/' dkms.conf

find_cs8409_module() {
    find /lib/modules/"$UNAME" -type f -name 'snd-hda-codec-cs8409.ko*' 2>/dev/null | sort | head -n1 || true
}

ensure_cs8409_module_in_updates() {
    local module_path
    module_path="$(find_cs8409_module)"
    local preferred_dir="/lib/modules/${UNAME}/updates/codecs/cirrus"

    if [ -z "$module_path" ]; then
        echo "Warning: CS8409 module not found under /lib/modules/$UNAME."
        return 1
    fi

    mkdir -p "$preferred_dir"
    if [[ "$module_path" != "$preferred_dir/"* ]]; then
        cp -a "$module_path" "$preferred_dir/"
        echo "Copied CS8409 driver from $module_path to $preferred_dir/"
    fi

    depmod -a "$UNAME"
}

if [[ $dkms_action == 'install' ]]; then

    # Remove any non-dkms module to avoid filename conflicts under /lib/modules/{kernel}/
    update_dir="/lib/modules/${UNAME}/updates"
    [[ -e $update_dir/snd-hda-codec-cs8409.ko ]] && rm $update_dir/snd-hda-codec-cs8409.ko && echo "removed $update_dir/snd-hda-codec-cs8409.ko"

    bash dkms.sh
    ensure_cs8409_module_in_updates || true

    echo -e "\ncontents of $update_dir"
    find /lib/modules/"${UNAME}"/updates -type f -name 'snd-hda-codec-cs8409.ko*' 2>/dev/null | sort || true
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
hda_dir="$cur_dir/$build_dir/hda"
update_dir="/lib/modules/${UNAME}/updates"

[[ -d $hda_dir ]] && rm -rf $hda_dir
[[ ! -d $build_dir ]] && mkdir $build_dir

# Ubuntu kernels are significantly modified from mainline (extensive backports).
# We must use the Ubuntu kernel source, not a mainline tarball.
# NOTE: HWE kernels are NOT supported — there is no linux-source-* package for them.
if [ ! -e /usr/src/linux-source-$kernel_version.tar.bz2 ]; then
    echo "Error: Ubuntu kernel source not found: /usr/src/linux-source-$kernel_version.tar.bz2"
    echo "Install it with: sudo apt install linux-source-$kernel_version"
    echo "NOTE: This does not work for HWE kernels."
    exit 1
fi

# Pre-6.17 kernels have HDA source at sound/pci/hda (moved to sound/hda in 6.17)
tar --strip-components=3 -xvf /usr/src/linux-source-$kernel_version.tar.bz2 \
    --directory=build/ linux-source-$kernel_version/sound/pci/hda

mv $hda_dir/Makefile $hda_dir/Makefile.orig
cp $patch_dir/Makefile $patch_dir/patch_cirrus_* $hda_dir

pushd $hda_dir > /dev/null

# Supported Ubuntu kernel range: 5.13–6.16
# iscurrent: 1 = known-good, 2 = newer than tested (may have issues), -1 = too old
current_major=5
current_minor_ubuntu=15
current_rev_ubuntu=47
latest_rev_ubuntu=71

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

if [ $major_version -eq 5 -a $minor_version -lt 13 ]; then
    patch -b -p2 <../../patch_patch_cirrus.c.diff
else
    patch -b -p2 <../../patch_patch_cs8409.c.diff

    if [ $iscurrent -ge 0 ]; then
        patch -b -p2 <../../patch_patch_cs8409.h.diff
    else
        patch -b -p2 <../../patches/patch_patch_cs8409.h.ubuntu.pre51547.diff
    fi

    if [ $iscurrent -ge 0 ]; then
        patch -b -p2 <../../patch_patch_cirrus_apple.h.diff
    fi
fi

popd > /dev/null

[[ ! $dkms_action == 'install' ]] && [[ ! -d $update_dir ]] && mkdir $update_dir

if [[ ! $dkms = true ]]; then
    if [ $PATCH_CIRRUS = true ]; then
        make PATCH_CIRRUS=1
        make install PATCH_CIRRUS=1
    else
        make KERNELRELEASE=$UNAME
        make install KERNELRELEASE=$UNAME
    fi
    ensure_cs8409_module_in_updates || true
    echo -e "\ncontents of $update_dir"
    find /lib/modules/"${UNAME}"/updates -type f -name 'snd-hda-codec-cs8409.ko*' 2>/dev/null | sort || true
fi
