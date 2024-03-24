package PVE::AAB;

use strict;
use warnings;

use File::Path;
use File::Copy;
use IO::File;
use IO::Select;
use IPC::Open2;
use IPC::Open3;
use UUID;
use Cwd;
my @BASE_PACKAGES = qw(base openssh vi nano python);
my @BASE_EXCLUDES = qw(
    e2fsprogs
    jfsutils
    linux
    linux-firmware
    lvm2
    mdadm
    netctl
    pcmciautils
    reiserfsprogs
    xfsprogs
);

my $PKGDIR = "/var/cache/pacman/pkg";

my ($aablibdir, $fake_init);

sub setup_defaults($) {
    my ($dir) = @_;
    $aablibdir = $dir;
    $fake_init = "$aablibdir/scripts/init.bash";
}

setup_defaults('/usr/lib/aab');

sub write_file {
    my ($data, $file, $perm) = @_;

    die "no filename" if !$file;
    unlink $file;

    my $fh = IO::File->new ($file, O_WRONLY | O_CREAT, $perm) ||
	die "unable to open file '$file'";

    print $fh $data;
    $fh->close;
}

sub read_file {
    my ($filename) = @_;

    my $fh = IO::File->new ("<$filename") or die "failed to read $filename - $!\n";
    my $rec = '';
    while (defined (my $line = <$fh>)) {
	$rec .= $line;
    };
    return $rec;
}

sub copy_file {
    my ($a, $b) = @_;
    copy($a, $b) or die "failed to copy $a => $b: $!";
}

sub rename_file {
    my ($a, $b) = @_;
    rename($a, $b) or die "failed to rename $a => $b: $!";
}

sub symln {
    my ($a, $b) = @_;
    symlink($a, $b) or die "failed to symlink $a => $b: $!";
}

sub logmsg {
    my $self = shift;
    print STDERR @_;
    $self->writelog (@_);
}

sub writelog {
    my $self = shift;
    my $fd = $self->{logfd};
    print $fd @_;
}

sub read_config {
    my ($filename) = @_;

    my $res = {};

    my $fh = IO::File->new ("<$filename") || return $res;
    my $rec = '';

    while (defined (my $line = <$fh>)) {
	next if $line =~ m/^\#/;
	next if $line =~ m/^\s*$/;
	$rec .= $line;
    };

    close ($fh);

    chomp $rec;
    $rec .= "\n";

    while ($rec) {
	if ($rec =~ s/^Description:\s*([^\n]*)(\n\s+.*)*$//si) {
	    $res->{headline} = $1;
	    chomp $res->{headline};
	    my $long = $2;
	    $long =~ s/^\s+/ /;
	    $res->{description} = $long;
	    chomp $res->{description};
	} elsif ($rec =~ s/^([^:]+):\s*(.*\S)\s*\n//) {
	    my ($key, $value) = (lc ($1), $2);
	    if ($key eq 'source' || $key eq 'mirror') {
		push @{$res->{$key}}, $value;
	    } else {
		die "duplicate key '$key'\n" if defined ($res->{$key});
		$res->{$key} = $value;
	    }
	} else {
	    die "unable to parse config file: $rec";
	}
    }

    die "unable to parse config file" if $rec;

    $res->{architecture} = 'amd64' if $res->{architecture} eq 'x86_64';

    return $res;
}

sub new {
    my ($class, $config) = @_;

    $config = read_config ('aab.conf') if !$config;
    my $version = $config->{version};
    die "no 'version' specified\n" if !$version;
    die "no 'section' specified\n" if !$config->{section};
    die "no 'description' specified\n" if !$config->{headline};
    die "no 'maintainer' specified\n" if !$config->{maintainer};

    my $name = $config->{name} || die "no 'name' specified\n";
    $name =~ m/^[a-z][0-9a-z\-\*\.]+$/ ||
	die "illegal characters in name '$name'\n";

    my $targetname;
    if ($name =~ m/^archlinux/) {
	$targetname = "${name}_${version}_$config->{architecture}";
    } else {
	$targetname = "archlinux-${name}_${version}_$config->{architecture}";
    }

    my $self = { logfile => 'logfile',
                 config => $config,
                 targetname => $targetname,
                 incl => [@BASE_PACKAGES],
                 excl => [@BASE_EXCLUDES],
               };

    $self->{logfd} = IO::File->new($self->{logfile}, O_WRONLY | O_APPEND | O_CREAT)
	or die "unable to open log file";

    bless $self, $class;

    $self->__allocate_ve();

    return $self;
}

sub __sample_config {
    my ($self) = @_;

    my $arch = $self->{config}->{architecture};

    return <<"CFG";
lxc.arch = $arch
lxc.include = /usr/share/lxc/config/common.conf
lxc.uts.name = localhost
lxc.rootfs.path = $self->{rootfs}
lxc.mount.entry = $self->{pkgcache} $self->{pkgdir} none bind 0 0
CFG
}

sub __allocate_ve {
    my ($self) = @_;

    my $cid;
    if (my $fd = IO::File->new(".veid")) {
	$cid = <$fd>;
	chomp $cid;
	close ($fd);
    }


    $self->{working_dir} = getcwd;
    $self->{veconffile} = "$self->{working_dir}/config";
    $self->{rootfs} = "$self->{working_dir}/rootfs";
    $self->{pkgdir} = "$self->{working_dir}/rootfs/$PKGDIR";
    $self->{pkgcache} = "$self->{working_dir}/pkgcache";
    $self->{'pacman.conf'} = "$self->{working_dir}/pacman.conf";

    if ($cid) {
	$self->{veid} = $cid;
	return $cid;
    }

    my $uuid;
    my $uuid_str;
    UUID::generate($uuid);
    UUID::unparse($uuid, $uuid_str);
    $self->{veid} = $uuid_str;

    my $fd = IO::File->new (">.veid") ||
	die "unable to write '.veid'\n";
    print $fd "$self->{veid}\n";
    close ($fd);
    $self->logmsg("allocated VE $self->{veid}\n");
}

sub initialize {
    my ($self) = @_;

    my $config = $self->{config};

    $self->{logfd} = IO::File->new($self->{logfile}, O_WRONLY | O_TRUNC | O_CREAT)
	or die "unable to open log file";

    my $cdata = $self->__sample_config();

    my $fh = IO::File->new($self->{veconffile}, O_WRONLY|O_CREAT|O_EXCL) ||
	die "unable to write lxc config file '$self->{veconffile}' - $!";
    print $fh $cdata;
    close ($fh);

    if (!$config->{source} && !$config->{mirror}) {
	die "no sources/mirrors specified";
    }

    $self->write_pacman_conf();

    $self->logmsg("configured VE $self->{veid}\n");
}

sub write_pacman_conf {
    my ($self, $config_fn, $siglevel) = @_;

    my $config = $self->{config};

    $config->{source} //= [];
    $config->{mirror} //= [];

    $siglevel ||= "Never";
    $config_fn ||= $self->{'pacman.conf'};

    my $servers = "Server = ".join("\nServer = ", @{$config->{source}}, @{$config->{mirror}}) ."\n";

    my $fh = IO::File->new($config_fn, O_WRONLY | O_CREAT | O_EXCL)
        or die "unable to write pacman config file $self->{'pacman.conf'} - $!";

    my $arch = $config->{architecture};
    $arch = 'x86_64' if $arch eq 'amd64';

    print $fh <<"EOF";
[options]
HoldPkg = pacman glibc
Architecture = $arch
CheckSpace
SigLevel = $siglevel

[core]
$servers
[extra]
$servers
[community]
$servers
EOF

    print $fh "[multilib]\n$servers\n" if $config->{architecture} eq 'x86_64';

    close($fh);
}

sub ve_status {
    my ($self) = @_;

    my $veid = $self->{veid};

    my $res = { running => 0 };

    $res->{exist} = 1 if -d "$self->{rootfs}/usr";

    my $filename = "/proc/net/unix";

    # similar test is used by lcxcontainers.c: list_active_containers
    my $fh = IO::File->new ($filename, "r");
    return $res if !$fh;

    while (defined(my $line = <$fh>)) {
	if ($line =~ m/^[a-f0-9]+:\s\S+\s\S+\s\S+\s\S+\s\S+\s\d+\s(\S+)$/) {
	    my $path = $1;
	    if ($path =~ m!^@/\S+/$veid/command$!) {
		$res->{running} = 1;
	    }
	}
    }
    close($fh);

    return $res;
}

sub ve_destroy {
    my ($self) = @_;

    my $veid = $self->{veid}; # fixme

    my $vestat = $self->ve_status();
    if ($vestat->{running}) {
	$self->stop_container();
    }

    rmtree $self->{rootfs};
    unlink $self->{veconffile};
}

sub ve_init {
    my ($self) = @_;


    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    $self->logmsg ("initialize VE $veid\n");

    my $vestat = $self->ve_status();
    if ($vestat->{running}) {
	$self->run_command ("lxc-stop -n $veid --rcfile $conffile --kill");
    }

    rmtree $self->{rootfs};
    mkpath "$self->{rootfs}/dev";
}

sub ve_command {
    my ($self, $cmd, $input) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    if (ref ($cmd) eq 'ARRAY') {
	unshift @$cmd, 'lxc-attach', '-n', $veid, '--rcfile', $conffile,'--clear-env', '--';
	$self->run_command ($cmd, $input);
    } else {
	$self->run_command ("lxc-attach -n $veid --rcfile $conffile --clear-env -- $cmd", $input);
    }
}

sub ve_exec {
    my ($self, @cmd) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    my $reader;
    my $pid = open2($reader, "<&STDIN", 'lxc-attach', '-n', $veid, '--rcfile', $conffile, '--', @cmd)
	or die "unable to exec command";

    while (defined (my $line = <$reader>)) {
	$self->logmsg ($line);
    }

    waitpid ($pid, 0);
    my $rc = $? >> 8;

    die "ve_exec failed - status $rc\n" if $rc != 0;
}

sub run_command {
    my ($self, $cmd, $input, $getoutput, $noerr) = @_;

    my $reader = IO::File->new();
    my $writer = IO::File->new();
    my $error  = IO::File->new();

    my $orig_pid = $$;

    my $cmdstr = ref ($cmd) eq 'ARRAY' ? join (' ', @$cmd) : $cmd;

    my $pid;
    eval {
	if (ref ($cmd) eq 'ARRAY') {
	    $pid = open3 ($writer, $reader, $error, @$cmd) || die $!;
	} else {
	    $pid = open3 ($writer, $reader, $error, $cmdstr) || die $!;
	}
    };

    my $err = $@;

    # catch exec errors
    if ($orig_pid != $$) {
	$self->logmsg ("ERROR: command '$cmdstr' failed - fork failed\n");
	POSIX::_exit (1);
	kill ('KILL', $$);
    }

    die $err if $err;

    print $writer $input if defined $input;
    close $writer;

    my $select = new IO::Select;
    $select->add ($reader);
    $select->add ($error);

    my $res = '';
    my $logfd = $self->{logfd};

    while ($select->count) {
	my @handles = $select->can_read ();

	foreach my $h (@handles) {
	    my $buf = '';
	    my $count = sysread ($h, $buf, 4096);
	    if (!defined ($count)) {
		waitpid ($pid, 0);
		die "command '$cmdstr' failed: $!";
	    }
	    $select->remove ($h) if !$count;

	    print $logfd $buf;

	    $res .= $buf if $getoutput;
	}
    }

    waitpid ($pid, 0);
    my $ec = ($? >> 8);

    die "command '$cmdstr' failed with exit code $ec\n" if $ec && !$noerr;

    return wantarray ? ($res, $ec) : $res;
}

sub start_container {
    my ($self) = @_;
    my $veid = $self->{veid};
    $self->run_command(['lxc-start', '-n', $veid, '-f', $self->{veconffile}, '/usr/bin/aab_fake_init']);
}

sub stop_container {
    my ($self) = @_;
    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};
    $self->run_command ("lxc-stop -n $veid --rcfile $conffile --kill");
}

sub pacman_command {
    my ($self, $config_fn) = @_;
    my $root = $self->{rootfs};
    return (
        '/usr/bin/pacman',
        '--root', $root,
        '--config', $config_fn || $self->{'pacman.conf'},
        '--cachedir', $self->{pkgcache},
        '--noconfirm',
    );
}

sub cache_packages {
    my ($self, $packages) = @_;
    my $root = $self->{rootfs};

    $self->write_pacman_conf('pacman.caching.conf', "Optional");
    my @pacman = $self->pacman_command('pacman.caching.conf');
    my ($_res, $ec) = $self->run_command([@pacman, '-Sw', '--', @$packages], undef, undef, 1);
    $self->logmsg("ignore bad exit $ec due to unavailable keyring, the CT will verify that later.\n")
	if $ec;
}

sub mask_systemd_unit {
    my ($self, $unit) = @_;
    my $root = $self->{rootfs};
    symln '/dev/null', "$root/etc/systemd/system/$unit";
}

sub enable_systemd_unit {
    my ($self, $unit) = @_;
    my $root = $self->{rootfs};
    symln "/usr/lib/systemd/system/$unit", "$root/etc/systemd/system/multi-user.target.wants/$unit";
}

sub bootstrap {
    my ($self, $include, $exclude) = @_;
    my $root = $self->{rootfs};

    my @pacman = $self->pacman_command();

    print "Fetching package database...\n";
    mkpath $self->{pkgcache};
    mkpath $self->{pkgdir};
    mkpath "$root/var/lib/pacman";
    $self->run_command([@pacman, '-Syy']);

    print "Figuring out what to install...\n";
    my $incl = { map { $_ => 1 } @{$self->{incl}} };
    my $excl = { map { $_ => 1 } @{$self->{excl}} };

    foreach my $addinc (@$include) {
	$incl->{$addinc} = 1;
	delete $excl->{$addinc};
    }
    foreach my $addexc (@$exclude) {
	$excl->{$addexc} = 1;
	delete $incl->{$addexc};
    }

    my $expand = sub {
	my ($lst) = @_;
	foreach my $inc (keys %$lst) {
	    my $group;
	    eval { $group = $self->run_command([@pacman, '-Sqg', $inc], undef, 1); };
	    if ($group && !$@) {
		# add the group
		delete $lst->{$inc};
		$lst->{$_} = 1 foreach split(/\s+/, $group);
	    }
	}
    };

    $expand->($incl);
    $expand->($excl);

    my $packages = [ grep { !$excl->{$_} } keys %$incl ];

    print "Setting up basic environment...\n";
    mkpath "$root/etc";
    mkpath "$root/usr/bin";

    my $data = "# UNCONFIGURED FSTAB FOR BASE SYSTEM\n";
    write_file ($data, "$root/etc/fstab", 0644);

    write_file ("", "$root/etc/resolv.conf", 0644);
    write_file("localhost\n", "$root/etc/hostname", 0644);
    $self->run_command(['install', '-m0755', $fake_init, "$root/usr/bin/aab_fake_init"]);

    unlink "$root/etc/localtime";
    symln '/usr/share/zoneinfo/UTC', "$root/etc/localtime";

    print "Caching packages...\n";
    $self->cache_packages($packages);
    #$self->copy_packages();

    print "Creating device nodes for package manager...\n";
    $self->create_dev();

    print "Installing package manager and essentials...\n";
    # inetutils for 'hostname' for our init
    $self->run_command([@pacman, '-S', 'pacman', 'inetutils', 'archlinux-keyring']);

    print "Setting up pacman for installation from cache...\n";
    my $file = "$root/etc/pacman.d/mirrorlist";
    my $backup = "${file}.aab_orig";
    if (!-f $backup) {
	rename_file($file, $backup);
	write_file("Server = file://$PKGDIR\n", $file);
    }

    print "Populating keyring...\n";
    $self->populate_keyring();

    print "Removing device nodes...\n";
    $self->cleanup_dev();

    print "Starting container...\n";
    $self->start_container();

    print "Installing packages...\n";
    $self->ve_command(['pacman', '-S', '--needed', '--noconfirm', '--', @$packages]);

    print "Masking problematic systemd units...\n";
    for  my $unit (qw(sys-kernel-config.mount sys-kernel-debug.mount systemd-journald-audit.socket systemd-resolved.service)) {
	$self->mask_systemd_unit($unit);
    }

    print "Enable systemd services...\n";
    for my $unit (qw(sshd.service)) {
        $self->enable_systemd_unit($unit);
    }
}

# devices needed for gnupg to function:
my $devs = {
    '/dev/null'    => ['c', '1', '3'],
    '/dev/random'  => ['c', '1', '9'], # fake /dev/random (really urandom)
    '/dev/urandom' => ['c', '1', '9'],
    '/dev/tty'     => ['c', '5', '0'],
};

sub cleanup_dev {
    my ($self) = @_;
    my $root = $self->{rootfs};

    # remove temporary device files
    unlink "${root}$_" foreach keys %$devs;
}

sub create_dev {
    my ($self) = @_;
    my $root = $self->{rootfs};

    local $SIG{INT} = $SIG{TERM} = sub { $self->cleanup_dev; };

    # we want to replace /dev/random, so delete devices first
    $self->cleanup_dev();

    foreach my $dev (keys %$devs) {
	my ($type, $major, $minor) = @{$devs->{$dev}};
	system('mknod', "${root}${dev}", $type, $major, $minor);
    }
}

sub populate_keyring {
    my ($self) = @_;
    my $root = $self->{rootfs};

    # generate weak master key and populate the keyring
    system('unshare', '--fork', '--pid', 'chroot', "$root", 'pacman-key', '--init') == 0
	or die "failed to initialize keyring: $?";
    system('unshare', '--fork', '--pid', 'chroot', "$root", 'pacman-key', '--populate') == 0
	or die "failed to populate keyring: $?";

}

sub install {
    my ($self, $pkglist) = @_;

    $self->cache_packages($pkglist);
    $self->ve_command(['pacman', '-S', '--needed', '--noconfirm', '--', @$pkglist]);
}

sub write_config {
    my ($self, $filename, $size) = @_;

    my $config = $self->{config};

    my $data = '';

    $data .= "Name: $config->{name}\n";
    $data .= "Version: $config->{version}\n";
    $data .= "Type: lxc\n";
    $data .= "OS: archlinux\n";
    $data .= "Section: $config->{section}\n";
    $data .= "Maintainer: $config->{maintainer}\n";
    $data .= "Architecture: $config->{architecture}\n";
    $data .= "Infopage: https://www.archlinux.org\n";
    $data .= "Installed-Size: $size\n";

    # optional
    $data .= "Infopage: $config->{infopage}\n" if $config->{infopage};
    $data .= "ManageUrl: $config->{manageurl}\n" if $config->{manageurl};
    $data .= "Certified: $config->{certified}\n" if $config->{certified};

    # description
    $data .= "Description: $config->{headline}\n";
    $data .= "$config->{description}\n" if $config->{description};

    write_file ($data, $filename, 0644);
}

sub finalize {
    my ($self, $compressor) = @_;

    my $use_zstd = 1;
    if (defined($compressor)) {
	if ($compressor =~ /^\s*--zstd?\s*$/) {
	    $use_zstd = 1;
	} elsif ($compressor =~ /^\s*--(?:gz|gzip)\s*$/) {
	    $use_zstd = 0; # just boolean for now..
	} else {
	    die "finalize: unknown compressor '$compressor'!\n";
	}
    }

    my $rootdir = $self->{rootfs};

    print "Stopping container...\n";
    $self->stop_container();

    print "Rolling back mirrorlist changes...\n";
    my $file = "$rootdir/etc/pacman.d/mirrorlist";
    unlink $file;
    rename_file($file.'.aab_orig', $file);

    # experienced user can change it anytime and others do well to start out with an updatable system..
    my $mirrors = eval { read_file($file) } // '';
    $mirrors = "\nServer = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch\n\n" . $mirrors;
    write_file($mirrors, $file, 0644);

    my $sizestr = $self->run_command("du -sm $rootdir", undef, 1);
    my $size;
    if ($sizestr =~ m/^(\d+)\s+\Q$rootdir\E$/) {
	$size = $1;
    } else {
	die "unable to detect size\n";
    }
    $self->logmsg ("uncompressed size: $size MB\n");

    $self->write_config ("$rootdir/etc/appliance.info", $size);

    $self->logmsg ("creating final appliance archive\n");

    my $compressor_ext = $use_zstd ? 'zst' : 'gz';

    my $target = "$self->{targetname}.tar";
    unlink $target;
    unlink "$target.$compressor_ext";

    $self->run_command ("tar cpf $target --numeric-owner -C '$rootdir' ./etc/appliance.info");
    $self->run_command ("tar rpf $target --numeric-owner -C '$rootdir' --exclude ./etc/appliance.info .");

    $self->logmsg ("compressing archive ($compressor_ext)\n");
    if ($use_zstd) {
	$self->run_command ("zstd -19 --rm $target");
    } else {
	$self->run_command ("gzip -9 $target");
    }

    my $target_size = int(-s "$target.$compressor_ext") >> 20;
    $self->logmsg ("created '$target.$compressor_ext' with size: $target_size MB\n");
}

sub enter {
    my ($self) = @_;
    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    my $vestat = $self->ve_status();
    if (!$vestat->{exist}) {
	$self->logmsg ("Please create the appliance first (bootstrap)");
	return;
    }

    if (!$vestat->{running}) {
	$self->start_container();
    }

    system ("lxc-attach -n $veid --rcfile $conffile --clear-env");
}

sub clean {
    my ($self, $all) = @_;

    unlink $self->{logfile};
    unlink $self->{'pacman.conf'}, 'pacman.caching.conf';
    $self->ve_destroy();
    unlink '.veid';
    unlink $self->{veconffile};

    rmtree $self->{pkgcache} if $all;
}

1;
