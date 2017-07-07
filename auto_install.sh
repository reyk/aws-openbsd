#!/bin/sh

echo "Installing cloud-agent"
ftp -o /tmp/cloud-agent.tgz %%AGENTURL%%
tar -xzphf /tmp/cloud-agent.tgz -C /mnt/usr/local -s '/^+.*//g'
for _if in /mnt/etc/hostname.*0; do
	echo "!/usr/local/libexec/cloud-agent \"\\\$if\"" >>$_if
done

cat | chroot /mnt <<EOF
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
_syspatch=\$(syspatch -c 2>/dev/null)
if [[ -n "\$_syspatch" ]]; then
	echo "Running syspatch"
	syspatch
fi
EOF

exit 0
