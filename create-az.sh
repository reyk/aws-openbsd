#!/bin/sh
#
# Copyright (c) 2017 Reyk Floeter <reyk@openbsd.org>
# Copyright (c) 2015, 2016 Antoine Jacoutot <ajacoutot@openbsd.org>
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

# Create and upload an OpenBSD image for Azure

set -e
umask 022

################################################################################
NAME=openbsd				# Azure has some naming restrictions
LOCATION=westeurope			# This is where we are!
IMGSIZE=30				# Azure: >=30G for public images
#RELEASE=				# eg. 6.1, comment out for snapshots
TIMESTAMP=$(date "+%Y%m%d%H%M%S")

AZ_RG=${NAME}${TIMESTAMP}		# Azure: resource group
AZ_SA=${AZ_RG}s				# Azure: storage account
AZ_CN=${AZ_RG}c				# Azure: container name
AZ_VM=${AZ_RG}vm			# Azure: VM name
AZ_BLOB=${AZ_RG}.vhd			# Azure: BLOB name

VM_SSHUSER=azure-user			# These VM settings are only examples:
VM_SSHKEY=${HOME}/.ssh/id_rsa.pub	# Azure only supports RSA public keys
VM_SKU=Standard_LRS			# Premium_LRS, Standard_LRS
VM_SIZE=Standard_DS2_v2			# Standard_A2 etc.

ARCH=$(uname -m)
MIRROR=${MIRROR:=https://mirror.leaseweb.net/pub/OpenBSD}
AGENTURL=https://github.com/reyk/cloud-agent/releases/download/v0.1
RC_CLOUD=$PWD/rc.cloud
PKG_DEPS="azure-cli azure-vhd-utils qemu"
################################################################################
_WRKDIR= _VHD= _LOG= _IMG= _REL=
################################################################################

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
	local _AGENT=${_WRKDIR}/$(basename $AGENTURL)
	local _p _m
	local _VNDEV=$(vnconfig -l | grep 'not in use' | head -1 |
		cut -d ':' -f1)

	_IMG=${_WRKDIR}/${NAME}-${RELEASE:-$(uname -r)}-${ARCH}-${TIMESTAMP}

	if [[ -z ${_VNDEV} ]]; then
		echo "${0##*/}: no vnd(4) device available"
		exit 1
	fi

	# fetch agent first to validate the URL before doing anything else
	log "Fetching $_AGENT"
	run ftp -V -o ${_AGENT} ${AGENTURL}

	# ...now fetch the sets before installing anything
	log "Fetching sets from ${MIRROR:##*//}"
	( cd ${_WRKDIR} &&
		run ftp -V ${MIRROR}/${RELEASE:-snapshots}/${ARCH}/{bsd{,.mp,.rd},{base,comp,game,man,xbase,xshare,xfont,xserv}${_REL}.tgz} )

	mkdir -p ${_MNT}

	log Creating image container
	vmctl create ${_IMG} -s ${IMGSIZE}G

	# default disklabel automatic allocation with the following changes:
	# - OpenBSD partition offset starts at 1M (due to Azure)
	# - swap is removed (Azure policy for OS disk in public images)
	# - a is extend to use the available space from swap
	log Creating and mounting image filesystem
	run vnconfig ${_VNDEV} ${_IMG}
	echo 'e 3\na6\n\n1M\n*\nflag 3\nupdate\nw\nq\n' | fdisk -e ${_VNDEV}
	echo 'z\nA\nd b\nm a\n\n*\n\n\nw\nq\n' | \
		disklabel -EF ${_WRKDIR}/fstab ${_VNDEV}
	awk '$2~/^\//{sub(/^.+\./,"",$1);print $1, $2}' ${_WRKDIR}/fstab |
		while read _p _m; do
			newfs /dev/r${_VNDEV}${_p}
			install -d ${_MNT}${_m}
			mount /dev/${_VNDEV}${_p} ${_MNT}${_m}
		done

	log "Extracting sets"
	for i in ${_WRKDIR}/*${_REL}.tgz ${_MNT}/var/sysmerge/{,x}etc.tgz; do
		echo $(basename ${i})
		tar -xzphf $i -C ${_MNT}
	done

	log "Installing $(basename $_AGENT)"
	tar -xzphf ${_AGENT} -C ${_MNT}/usr/local -s '/^+.*//g'

	log "Installing MP kernel"
	mv ${_WRKDIR}/bsd* ${_MNT}
	mv ${_MNT}/bsd ${_MNT}/bsd.sp
	mv ${_MNT}/bsd.mp ${_MNT}/bsd
	chown 0:0 ${_MNT}/bsd*

	log "Creating devices"
	( cd ${_MNT}/dev && sh ./MAKEDEV all )

	log "Storing entropy for the initial boot"
	dd if=/dev/random of=${_MNT}/var/db/host.random bs=65536 count=1 \
		status=none
	dd if=/dev/random of=${_MNT}/etc/random.seed bs=512 count=1 \
		status=none
	chmod 600 ${_MNT}/var/db/host.random ${_MNT}/etc/random.seed

	log "Installing master boot record"
	installboot -r ${_MNT} ${_VNDEV}

	log "Configuring the image"
	echo ${MIRROR} >${_MNT}/etc/installurl
	sed -e "s#\(/home ffs rw\)#\1,nodev,nosuid#" \
		-e "s#\(/tmp ffs rw\)#\1,nodev,nosuid#" \
		-e "s#\(/usr ffs rw\)#\1,nodev#" \
		-e "s#\(/usr/X11R6 ffs rw\)#\1,nodev#" \
		-e "s#\(/usr/local ffs rw\)#\1,wxallowed,nodev#" \
		-e "s#\(/usr/obj ffs rw\)#\1,nodev,nosuid#" \
		-e "s#\(/usr/src ffs rw\)#\1,nodev,nosuid#" \
		-e "s#\(/var ffs rw\)#\1,nodev,nosuid#" \
		-e '1h;1d;$!H;$!d;G' \
		${_WRKDIR}/fstab >${_MNT}/etc/fstab
	sed -i "s,^tty00.*,tty00	\"/usr/libexec/getty std.9600\"	vt220   on  secure," \
		${_MNT}/etc/ttys
	echo "stty com0 9600" >${_MNT}/etc/boot.conf
	echo "set tty com0" >>${_MNT}/etc/boot.conf
	for i in ${_MNT}/etc/hostname.{xnf,hvn,vio}0; do
		echo "dhcp" >${i}
		echo "!/usr/local/libexec/cloud-agent \"\\\$if\"" >>${i}
		chmod 0640 ${i}
	done
	echo "127.0.0.1\tlocalhost" >${_MNT}/etc/hosts
	echo "::1\t\tlocalhost" >>${_MNT}/etc/hosts
	sed -i "s/^#\(PermitRootLogin\) .*/\1 no/" ${_MNT}/etc/ssh/sshd_config
	chroot ${_MNT} ln -sf /usr/share/zoneinfo/UTC /etc/localtime
	chroot ${_MNT} ldconfig /usr/local/lib /usr/X11R6/lib
	chroot ${_MNT} rcctl disable sndiod
	chroot ${_MNT} sha256 -h /var/db/kernel.SHA256 /bsd

	# If the rc.cloud file is not found, fallback to the sysmerge method.
	if [[ -s "$RC_CLOUD" ]]; then
		log "Creating /etc/rc for first boot initialization"
		mv ${_MNT}/etc/rc ${_MNT}/etc/rc.orig
		cp $RC_CLOUD ${_MNT}/etc/rc
	else
		log "Creating /etc/rc.sysmerge to update and reboot kernel"
		cat >${_MNT}/etc/rc.sysmerge <<EOF
_reboot=false
_syspatch=\$(syspatch -c 2>/dev/null)
if [[ -n "\$_syspatch" ]]; then
	echo "running syspatch..."
	syspatch
	_reboot=true
fi
if typeset -f reorder_kernel >/dev/null; then
	echo "relinking to create unique kernel..."
	reorder_kernel
	_reboot=true
fi
\$_reboot && exec reboot
EOF
	fi

	log "Unmounting the image"
	awk '$2~/^\//{sub(/^.+\./,"",$1);print $1, $2}' ${_WRKDIR}/fstab |
		tail -r | while read _p _m; do
			umount ${_MNT}${_m}
		done
	vnconfig -u ${_VNDEV}

	log "Removing downloaded and temporary files"
	rm ${_WRKDIR}/*${_REL}.tgz ${_AGENT} || true # non-fatal
	rm ${_WRKDIR}/fstab || true # non-fatal
	rm -r ${_MNT} || true # non-fatal

	log "Image available at: ${_IMG}"
}

create_vhd() {
	local _DSTIMG=${_IMG}

	_VHD=${_WRKDIR}/$(basename ${_IMG:%.img}.vhd)

	log Create image from raw disk

	run dd if=/dev/zero of=${_DSTIMG} \
	    seek=$(($IMGSIZE * 1024)) bs=1M count=1

	run qemu-img convert -f raw -O vpc -o subformat=fixed,force_size \
		${_DSTIMG} ${_VHD}
}

create_blob() {
	local AZ_URI=https://${AZ_SA}.blob.core.windows.net/${AZ_CN}/${AZ_BLOB}
	local AZ_SK AZ_CS

	log Creating blob: ${AZ_BLOB}

	log Create new resource group and storage account
	run az group create -l $LOCATION -n ${AZ_RG}
	run az storage account create -g ${AZ_RG} \
		-l $LOCATION -n ${AZ_SA} --sku Standard_LRS

	log Export newly-created storage account settings
	AZ_SK=$(az storage account keys list -g ${AZ_RG} -n ${AZ_SA} \
		--query "[?keyName=='key1'].value" -o tsv)
	AZ_CS=$(az storage account show-connection-string \
		-g ${AZ_RG} -n ${AZ_SA} -o tsv)

	export AZURE_STORAGE_ACCESS_KEY=${AZ_SK}
	export AZURE_STORAGE_CONNECTION_STRING=${AZ_CS}
	export AZURE_STORAGE_ACCOUNT=${AZ_SA}

	#log AZURE_STORAGE_ACCESS_KEY=${AZ_SK}
	#log AZURE_STORAGE_CONNECTION_STRING=${AZ_CS}
	log AZURE_STORAGE_ACCOUNT=${AZ_SA}

	log Create container for VM images
	run az storage container create -n ${AZ_CN}

	log Uploading image

	# These tools need more resources, bump the ulimits
	ulimit -m $(ulimit -Hm)
	ulimit -d $(ulimit -Hd)

	# a) Upload with Azure CLI 2.0 is slow and uses too much CPU/RAM
	#run az storage blob upload -c ${AZ_CN} -f ${_VHD} -n ${AZ_BLOB} \
	#	--max-connections 4

	# b) Upload with Azure CLI 1.0 is also slow and fails on OpenBSD
	#run azure storage blob upload --container ${AZ_CN} \
	#	-f ${_VHD} -b ${AZ_BLOB}

	# c) Upload with azure-vhd-utils is fast b/c it skips empty blocks
	run azure-vhd-utils upload \
		--stgaccountname ${AZ_SA} --stgaccountkey ${AZ_SK} \
		--containername ${AZ_CN} --localvhdpath ${_VHD} \
		--blobname ${AZ_BLOB}

	log Use the following example command to create a VM
	run echo az vm create -g ${AZ_RG} -n ${AZ_VM} --image ${AZ_URI} \
		--ssh-key-value ${VM_SSHKEY:-${HOME}/.ssh/id_rsa.pub} \
		--authentication-type ssh \
		--admin-username ${VM_SSHUSER:-azure-user} \
		--public-ip-address-dns-name ${AZ_VM} \
		--os-type linux --nsg-rule SSH \
		--storage-account $AZ_SA --storage-container-name ${AZ_CN} \
		--storage-sku ${VM_SKU:-Standard_LRS} --use-unmanaged-disk \
		--size ${VM_SIZE:-Standard_DS2_v2}
}

CREATE_BLOB=true
while getopts i:nr:s: arg; do
	case ${arg} in
	a)	AGENTURL="${OPTARG}";;
	i)	_IMG="${OPTARG}";;
	n)	CREATE_BLOB=false;;
	s)	IMGSIZE="${OPTARG}";;
	r)	RELEASE="${OPTARG}";;
	*)	usage;;
	esac
done

_WRKDIR=$(mktemp -d -p ${TMPDIR:=/tmp} az-img.XXXXXXXXXX)
_REL=$(echo ${RELEASE:-$(uname -r)} | tr -d '.')
_LOG=${_WRKDIR}/create.log
AGENTURL=${AGENTURL:-file:///home/$USER}/cloud-agent-${RELEASE:-$(uname -r)-current}-${ARCH}.tgz

for _p in ${PKG_DEPS}; do
	if ! pkg_info -qe ${_p}-*; then
		err needs the ${_p} package
	fi
done

if [[ -z $_IMG ]]; then
	create_img
fi

if [[ ! -s $_IMG ]]; then
	err source image or VHD not valid
elif [[ "${_IMG##*.}" == "vhd" ]]; then
	_VHD=${_IMG}
	AZ_BLOB=$(basename ${_VHD})
else
	create_vhd
fi

if $CREATE_BLOB; then
	create_blob
fi

exit 0
