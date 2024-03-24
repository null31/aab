# Arch Linux Appliance Builder

This is a fork of [Proxmox AAB project](https://git.proxmox.com/) with the goal of building an updated Arch Linux LXC template for use with PVE, also to prevent removal of `pacman keyring`; disable `systemd-resolved` and enable `sshd`.

## Requirements for building
The best way to build this template is running inside of an Arch Linux environment and will need the following packages: **`lxc make perl-uuid`**

Also to prevent an error when starting the container, you need to enable devices cgroup since LXC will apply [device cgroup limits](https://github.com/lxc/lxc/issues/2268#issuecomment-380019126).

```Shell
mount -o remount,rw /sys/fs/cgroup
mkdir /sys/fs/cgroup/devices
mount -t cgroup devices -o devices /sys/fs/cgroup/devices
mount -o remount,ro /sys/fs/cgroup
```

## To enable/disable services and install additional packages

Go to the file `PVE/AAB.pm` and search for the following lines:
- Add new packages: `my @BASE_PACKAGES`
- Disable service: `print "Masking problematic systemd units...\n";`
- Enable serivce: `print "Enable systemd services...\n";`

## Usage

### with Make
  - `make aab.conf`
  - run as root `make build-current`
  - go drink mate or kofi while is creating and compacting the template
  - when done will have the following file `archlinux-base_${DATE}-1_${ARCH}.tar.zst`
  - upload to your PVE and enjoy~

### or step by step

### 1. Create an aab.conf file describing your template.
  - `make aab.conf`
  - edit the source argument inside of `aab.conf` and change to a mirror of your choice

### 2. Run as root:
  - `./aab init`
  - `./aab bootstrap`

### 3. Maybe install additional packages
  - `./aab install base-devel`

### 4. Create the archive and clean up:
  - `./aab finalize`
  - `./aab cleanup`