#!/bin/sh

echo "Installing cloud-agent"
ftp -o /tmp/cloud-agent.tgz %%AGENTURL%%
tar -xzphf /tmp/cloud-agent.tgz -C /mnt/usr/local -s '/^+.*//g'
for _if in /mnt/etc/hostname.*0; do
	echo "!/usr/local/libexec/cloud-agent \"\\\$if\"" >>$_if
done

exit 0
