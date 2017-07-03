# OpenBSD cloud images

Cloud playground for OpenBSD kids.

Running whatever is in this repo will propably end up destroying a
kitten factory.

## Prerequisites

* shell access to OpenBSD 6.1 with internet connection available.
* minimum 3GB free space of /tmp.
* doas configured; for building as a root the "permit nopass keepenv root as root" in /etc/doas.conf is enough.

* For AWS:
    * ec2-api-tools, awscli, and vmdktool packages installed.
    * shell environment variables available.

            export AWS_ACCESS_KEY_ID=YOUR_AWS_ACCES_KEY;  
            export AWS_SECRET_ACCESS_KEY=YOUR_AWS_SECRET_KEY;  

    * Identity and Access Management on AWS configured.
> YOUR_AWS_ACCES_KEY and YOUR_AWS_SECRET_KEY should have AmazonEC2FullAccess and AmazonS3FullAccess policies assigned.

* For Azure:
    * azure-cli, azure-vhd-utils, and qemu packages installed.
    * Azure CLI 2.0 configured

            az login

## Script Usage

```shell
create-az.sh [-inr]
    -i "/path/to/image"
    -n only create the RAW/VHD images
    -r "release (e.g 6.0; default to current)"
```

## References

https://github.com/ajacoutot/aws-openbsd

## Build example

### Create and upload an OpenBSD 6.1 image for Azure

```shell
doas create-az.sh -r 6.1
```

### Upload the same image for AWS

```shell
doas create-ami.sh -i /tmp/az-img.WK3nz1nBCV/openbsd-6.1-amd64-20170703160607
```
