#!/bin/sh
#
# Copyright (c) 2017 Reyk Floeter <reyk@openbsd.org>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# Create an auto-installing OpenBSD VM image

set -e
umask 022

################################################################################
NAME=openbsd
IMGSIZE=30
#RELEASE=
TIMESTAMP=$(date "+%Y%m%d%H%M%S")

ARCH=$(uname -m)
MIRROR=${MIRROR:=https://mirror.leaseweb.net}
AGENTURL=https://github.com/reyk/cloud-agent/releases/download/v0.1
CLOUDURL=$PWD/data #https://raw.githubusercontent.com/reyk/cloud-openbsd/master
################################################################################
_WRKDIR= _LOG= _IMG= _REL=
################################################################################

# rdsetroot is built from files in OpenBSD's /usr/src/distrib/common/
_RDSR="rdsetroot.tar.gz"
_RDSRSRC="elf32.c elf64.c elfrdsetroot.c"

usage() {
	echo "usage: ${0##*/} [-n]" \
		" [-r release] [-s size] [-i image|.vhd] [-a agent-url]" >&2
	exit 1
}

log() {
	echo "*** ${0##*/}:" $@
	echo "# ${0##*/}:" $@ >> ${_LOG}
}

err() {
	log $@
	exit 1
}

run() {
	echo $@ >> ${_LOG}
	$@ || err $@
}

create_img() {
	local _MNT=${_WRKDIR}/mnt
	local _p _m
	local _VNDEV=$(vnconfig -l | grep 'not in use' | head -1 |
		cut -d ':' -f1)

	if [[ -z ${_VNDEV} ]]; then
		echo "${0##*/}: no vnd(4) device available"
		exit 1
	fi

	if [[ -z "$_IMG" ]]; then
		_IMG=${_WRKDIR}/${NAME}-${RELEASE:-$(uname -r)}-${ARCH}-${TIMESTAMP}
	fi

	#
	# Create a customized bsd.rd including autoinstall(8)
	#

	log Getting additional sources
	(
		cd ${_WRKDIR}
		for _f in ${_RDSR} auto_install.{conf,sh}; do
			run ftp -mVo $_f $CLOUDURL/$_f
		done
	)

	# ...now fetch the bsd.rd installer
	log "Fetching bsd.rd from ${MIRROR:##*//}"
	(
		cd ${_WRKDIR}
		for _f in bsd.rd SHA256.sig; do
			run ftp -V ${MIRROR}/pub/OpenBSD/${RELEASE:-snapshots}/${ARCH}/$_f
		done
		run signify -Vep /etc/signify/openbsd-${_REL}-base.pub \
			-x SHA256.sig -m SHA256
		run sha256 -C SHA256 bsd.rd
	)

	# ...this is needed to modify the bsd.rd image
	log Creating rdsetroot tool
	(
		cd ${_WRKDIR}
		run tar -xzphf ${_RDSR}
		run cc -Wno-all -Wno-tautological-compare \
			-o rdsetroot $_RDSRSRC;
	)

	log Extracting boot image from bsd.rd
	( cd ${_WRKDIR} && rdsetroot -x bsd.rd bsd.fs;)

	log Mounting and patching boot image
	vnconfig ${_VNDEV} ${_WRKDIR}/bsd.fs
	install -d ${_MNT}
	run mount /dev/${_VNDEV}a ${_MNT}

	for _f in auto_install.{conf,sh}; do
		cat ${_WRKDIR}/$_f | sed \
			-e "s|%%MIRROR%%|${MIRROR:##*//}|g" \
			-e "s|%%RELEASE%%|${RELEASE:-snapshots}|g" \
			-e "s|%%RELEASE%%|${RELEASE:-snapshots}|g" \
			-e "s|%%AGENTURL%%|${AGENTURL}|g" \
			>${_MNT}/$_f
	done
	chmod 0755 ${_MNT}/auto_install.sh

	# Patch installer to add install script for cloud-agent
	sed -i -e '/-x \/mnt\/\$MODE.site/i\
	[[ -x /auto_$MODE.sh ]] && /auto_$MODE.sh
	' ${_MNT}/install.sub
	sed -i -e 's/ 5/ 0/g' ${_MNT}/.profile

	log Unmounting the boot image
	umount ${_MNT}
	run vnconfig -u ${_VNDEV}

	log Updating bsd.rd with new boot image
	( cd ${_WRKDIR} && rdsetroot bsd.rd bsd.fs;)

	#
	# Create a bootable install disk including our bsd.rd
	#

	log Creating install disk image
	vmctl create ${_IMG} -s ${IMGSIZE}G

	# default disklabel automatic allocation with the following change:
	# - OpenBSD partition offset starts at 1M (due to Azure requirement)
	log Creating and mounting image filesystem
	run vnconfig ${_VNDEV} ${_IMG}
	echo 'e 3\na6\n\n1M\n*\nflag 3\nupdate\nw\nq\n' | \
		fdisk -e ${_VNDEV} >/dev/null
	echo 'z\na\na\n\n*\n\n\nw\nq' | \
		disklabel -E ${_VNDEV} >/dev/null
	newfs /dev/r${_VNDEV}a
	install -d ${_MNT}
	mount /dev/${_VNDEV}a ${_MNT}

	log "Installing bsd.rd kernel"
	mv ${_WRKDIR}/bsd.rd ${_MNT}

	log "Installing master boot record"
	installboot -r ${_MNT} ${_VNDEV} /usr/mdec/biosboot /usr/mdec/boot

	log "Configuring the image"
	install -d ${_MNT}/etc
	echo "stty com0 9600\nset tty com0\nboot bsd.rd" >${_MNT}/etc/boot.conf

	log "Unmounting the image"
	umount ${_MNT}
	vnconfig -u ${_VNDEV}

	log "Removing downloaded and temporary files"
	rm -f ${_WRKDIR}/bsd.rd ${_AGENT} || true # non-fatal
	rm -f ${_WRKDIR}/SHA256{,.sig} || true # non-fatal
	rm -r ${_MNT} || true # non-fatal

	log "Image available at: ${_IMG}"
}

geturl() {
	case $1 in
	ftp:*|https:*|http:*|file:*)	echo $1;;
	*)				echo file:$1;;
	esac
}

while getopts a:b:i:m:r:s: arg; do
	case ${arg} in
	a)	AGENTURL="${OPTARG}";;
	i)	_IMG="${OPTARG}";;
	m)	MIRROR="${OPTARG}";;
	r)	RELEASE="${OPTARG}";;
	s)	IMGSIZE="${OPTARG}";;
	*)	usage;;
	esac
done

_WRKDIR=$(mktemp -d -p ${TMPDIR:=/tmp} auto-img.XXXXXXXXXX)
_REL=$(echo ${RELEASE:-$(uname -r)} | tr -d '.')
_LOG=${_WRKDIR}/create.log
AGENTURL=${AGENTURL:-file:///home/$USER}/cloud-agent-${RELEASE:-$(uname -r)-current}-${ARCH}.tgz
AGENTURL=$(geturl $AGENTURL)
CLOUDURL=$(geturl $CLOUDURL)
MIRROR=$(geturl $MIRROR)

create_img

exit 0
