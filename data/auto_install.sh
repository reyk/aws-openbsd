#!/bin/sh

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# This is sometimes needed to fix-up the mirror URL
echo "https://%%MIRROR%%/pub/OpenBSD" > /etc/installurl

echo "Installing cloud-agent"
ftp -o /tmp/cloud-agent-%%AGENTVER%%.tgz %%AGENTURL%%
pkg_add -Dunsigned /tmp/cloud-agent-%%AGENTVER%%.tgz
for _if in /etc/hostname.*0; do
	echo "!/usr/local/libexec/cloud-agent -U root \"\\\$if\"" >>$_if
done

_syspatch=$(syspatch -c 2>/dev/null)
if [[ -n "$_syspatch" ]]; then
	# installer copies mp kernels afterwards, so fake it for syspatch
	cp /bsd /bsd.sp

	# Determine which kernel image is used (NCPU is not exported)
	NCPU=$(sysctl -n hw.ncpufound)
	if [ $NCPU -gt 1 ]; then
		export REORDER_KERNEL=GENERIC.MP
	else
		export REORDER_KERNEL=GENERIC
	fi

	# There is currently no better way to patch reorder_kernel
	sed -i.dist 's/KERNEL=\${KERNEL%#\*}/KERNEL=${REORDER_KERNEL:-${KERNEL%#*}}/g' \
		/usr/libexec/reorder_kernel

	echo "Running syspatch"
	syspatch
fi

exit 0
