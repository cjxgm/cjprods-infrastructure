use v5.26;
use utf8;
use strict;
use warnings;
use autodie;

BEGIN {
    package pkgsort v0.1.0
    {
        use Filter::Simple;

        sub extract_packages($)
        {
            my ($src) = @_;
            my %packages;
            my %deps;

            my $package = 'main';
            for (split m{\n}, $src) {
                m{^\s*package\s+([\w:]+)} and $package = $1;
                m{^\s*use\s+([\w:]+)} and push @{$deps{$package}}, $1;
                push @{$packages{$package}}, $_;
            }

            @$_ = grep { exists $packages{$_} } @$_ for values %deps;
            $_ = join("\n", @$_) for values %packages;
            $packages{$_} = [$_, $packages{$_}, $deps{$_} // []] for keys %packages;
            return \%packages;
        }

        sub build_package_depmap(\%)
        {
            my ($pkgs) = @_;
            my %depmap = map { $_->[0], $_->[2] } values %$pkgs;
            return \%depmap
        }

        sub toposort(\%)
        {
            my ($depmap) = @_;
            my %dep;
            my @sorted;
            @{$dep{$_}}{@{$depmap->{$_}}} = undef for keys %$depmap;

            while (my @resolved = sort grep { ! %{$dep{$_} // {}} } keys %dep) {
                push @sorted, @resolved;
                delete @dep{@resolved};
                delete @{$_}{@resolved} for grep { defined } values %dep;
            }

            die "Cyclic dependency detected\n" if %dep;
            return \@sorted;
        }

        sub sort_packages(\%\@)
        {
            my ($pkgs, $order) = @_;
            my @src = (
                (map {
                    my $filename = s{::}{/}rg . ".pm";
                    qq<BEGIN { \$INC{"$filename"} = 1 }>;
                } @$order),
                (map { $pkgs->{$_}[1] . "\n" } @$order),
            );


            return join "\n", @src;
        }

        FILTER {
            my $pkgs = extract_packages $_;
            my $depmap = build_package_depmap %$pkgs;
            my $order = toposort %$depmap;
            my $src = sort_packages %$pkgs, @$order;
            $_ = $src;
        };

        import();
    }
}

use Time::Piece;
use sanity;
use util;
use util::system;
use path;
use deploy;

sanity::check();
util::system::install qw[
    coreutils
    arch-install-scripts
    p7zip
    btrfs-progs
    systemd
    bash
];

util::run qw[rm -rf secrets];
util::system::un7zip "secrets.7z" if -f "secrets.7z";

my %machines = (
    master => {
        packages => [qw[systemd bash perl]],
    },
    acme => {
        packages => [qw[nginx certbot certbot-nginx]],
    },
    coordinator => {
        packages => [qw[nginx]],
    },
    ikiwiki => {
        packages => [qw[nginx fcgi]],
    },
    gitolite => {
        packages => [qw[openssh gitolite git]],
        services => [qw[sshd]],
        setup => "setup/gitolite",
    },
);

die "There must be a machine called master.\n" unless exists $machines{master};

my $master = "master-" . localtime->datetime =~ s{[^a-zA-Z0-9_-]}{_}rg;
$master .= "a" while -e path::of_machine($master);

my $master_config = $machines{master};
delete $machines{master};
my @slaves = sort keys %machines;

my $master_root = deploy::machine(undef, $master, $master_config);
util::spurt("$master_root/undeploy.sh", deploy::undo_script($master, @slaves));

# systemd creates a subvolume automatically.
# Let's replace it with a normal directory.
my $master_machine_dir = path::of_machine_dir($master_root);
util::system::delete_subvolume($master_machine_dir);
mkdir $master_machine_dir;

deploy::machine($master_root, $_, $machines{$_}) for @slaves;
deploy::enable_service($master_root, map { "systemd-nspawn\@$_" } @slaves);
deploy::enable_service($master_root, "machines.target");

util::run qw[rm -rf secrets];

print STDERR "\e[1;32mDeployment done.\nYou may want to run `machinectl start $master` to start it.\e[0m\n";

package sanity
{
    use util;

    sub foolproof()
    {
        my $rootfs = util::run qw[stat -fc%T /];
        die "/ must be on btrfs, but it's on $rootfs.\n" unless $rootfs eq 'btrfs';
        die "must run as root.\n" unless $> == 0;
    }

    sub check()
    {
        util::check_command_exists qw[
            stat
            pacman
        ];

        foolproof();
    }
}

package deploy
{
    use path;
    use util;
    use util::system;

    sub enable_service($@)
    {
        my ($root, @services) = @_;
        return unless @services;
        util::system::chroot($root, qw[systemctl enable], @services);
    }

    sub machine($$$)
    {
        my ($master_subvol, $name, $config) = @_;
        print STDERR "\e[1;32mDeploying $name...\e[0m\n";

        $config->{packages} //= [];
        $config->{services} //= [];
        $config->{spawning} //= {};

        my $root = path::of_machine($name, $master_subvol);
        util::system::create_subvolume($root, $master_subvol);
        util::system::bootstrap($root, @{$config->{packages}});
        enable_service($root, @{$config->{services}});

        my $nspawn_path = path::of_nspawn($name, $master_subvol);
        util::spurt($nspawn_path, util::system::nspawn_script(%{$config->{spawning}}));

        mkdir path::of_nspawn_dir($root);

        util::system::regenerate_machine_id($root);

        # No sane person should be using securetty.
        # Let's get rid of this ancient garbage.
        unlink "$root/etc/securetty";

        if (defined(my $setup = $config->{setup})) {
            util::run(qw[cp -r], $setup, "$root/setup");
            util::system::chroot($root, qw[bash -c], 'cd /setup; source setup.sh');
            util::run(qw[rm -rf], "$root/setup");
        }

        return $root;
    }

    sub undo_script($@)
    {
        my ($master, @slaves) = @_;
        my $master_root = path::of_machine($master);
        my $master_nspawn = path::of_nspawn($master);
        my @slave_roots = map { path::of_machine($_, $master_root) } @slaves;
        my @lines = (
            qq{echo -e "\\e[1;32mStopping $master\\e[0m..."},
            "systemctl stop systemd-nspawn\@$master",
            qq{echo -e "\\e[1;32mRemoving $master\\e[0m..."},
            (map { "btrfs sub delete $_" } @slave_roots, $master_root),
            qq{echo -e "\\e[1;32mRemoving nspawn config of $master\\e[0m..."},
            qq{rm -f "$master_nspawn"},
            qq{echo -e "\\e[1;32mUndeployed $master\\e[0m."},
            "", "",
        );
        return join "\n", @lines;
    }
}

package path
{
    sub of_machine($@) { ($_[1] // "") . "/var/lib/machines/$_[0]" }
    sub of_nspawn($@) { ($_[1] // "") . "/etc/systemd/nspawn/$_[0].nspawn" }
    sub of_machine_dir(@) { ($_[0] // "") . "/var/lib/machines" }
    sub of_nspawn_dir(@) { ($_[0] // "") . "/etc/systemd/nspawn" }
}

package util
{
    use IPC::Cmd;

    sub check_command_exists(@)
    {
        my @not_found = grep { ! IPC::Cmd::can_run($_) } @_;
        local $" = " ";
        die "Commands not found: @not_found\n" if @not_found;
    }

    sub run(@)
    {
        return unless @_;

        if (defined wantarray) {
            my ($ok, $err, undef, $stdout, $stderr) = IPC::Cmd::run(
                command => [@_],
                verbose => 0,
            );
            $stdout = join "", @$stdout;
            $stderr = join "", @$stderr;
            chomp $stderr;
            chomp $stdout;
            die "$err\n$stderr\n" unless $ok;
            $stdout;
        }

        else {
            my $cmd = $_[0];
            system $cmd @_ or return;

            local $" = " ";
            die "Failed to run $cmd: $!\n" if $? == -1;
            die "Child died unexpectedly when running $cmd: $!\n" if $? < 256;
            die "Failed to run @_\n" if $? >= 256;
        }
    }

    sub slurp(@)
    {
        return unless defined wantarray;
        local @ARGV = @_;
        local $/ unless wantarray;
        <<>>;
    }

    sub spurt($@)
    {
        my ($path, @lines) = @_;
        open my $fh, ">", $path;
        my $lines = join "\n", @lines;
        print $fh $lines;
    }
}

package util::system
{
    use util;

    sub install(@)
    {
        util::run qw[pacman -S --needed], @_;
    }

    sub bootstrap($@)
    {
        my ($dir, @args) = @_;
        util::run qw[pacstrap -cd], $dir, "--needed", @args;
    }

    sub chroot($@)
    {
        my ($root, @cmd) = @_;
        util::run qw[arch-chroot], $root, @cmd;
    }

    sub regenerate_machine_id($)
    {
        my ($root) = @_;
        unlink "$root/etc/machine-id";
        util::run qw[systemd-firstboot --setup-machine-id], "--root=$root";
    }

    sub create_subvolume($@)
    {
        my ($subvol, $snapshot) = @_;
        if (defined $snapshot) {
            util::run qw[btrfs sub snap], $snapshot, $subvol;
        } else {
            util::run qw[btrfs sub create], $subvol;
        }
    }

    sub delete_subvolume($)
    {
        util::run qw[btrfs sub delete], $_[0];
    }

    sub un7zip($)
    {
        util::run qw[7z x], $_[0];
    }

    sub nspawn_script(%)
    {
        my %opts = @_;
        my $private_network = $opts{private_network} ? "yes" : "no";
        return <<~END;
            [Exec]
            Boot=yes
            PrivateUsers=no
            NotifyReady=yes

            [Network]
            Private=$private_network
            END
    }
}

