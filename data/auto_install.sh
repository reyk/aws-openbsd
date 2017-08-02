#!/bin/sh

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# This is sometimes needed to fix-up the mirror URL
echo "https://%%MIRROR%%/pub/OpenBSD" > /etc/installurl

echo "Installing cloud-agent"
ftp -o /tmp/cloud-agent-%%AGENTVER%%.tgz %%AGENTURL%%
pkg_add -Dunsigned /tmp/cloud-agent-%%AGENTVER%%.tgz
for _if in /etc/hostname.*0; do
	echo "!/usr/local/libexec/cloud-agent \"\\\$if\"" >>$_if
done

_syspatch=$(syspatch -c 2>/dev/null)
if [[ -n "$_syspatch" ]]; then
	echo "Running syspatch"
	syspatch
fi

exit 0
