#!/usr/bin/bash

# no runlevels
(($$ != 1)) && exit 0

msg() {
    local mesg="$1"; shift
    printf "${mesg}\n" "$@"
}

die() {
    local mesg="$1"; shift
    printf "error: ${mesg}\n" "$@" >&2
    exit 1
}

do_exit() {
    msg "stopping init";
    exit 0
}

# lxc sends 48 for some reason with --kill instead of stopsignal
trap do_exit SIGINT SIGTERM SIGHUP SIGPWR 48

msg "starting bash init... $*"

[[ -d "/proc/$$" ]] || mount -t proc proc /proc \
    || die 'unable to mount /proc'

hostname localhost || die 'unable to set hostname'

sleep infinity &
wait
