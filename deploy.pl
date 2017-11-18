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
    arch-install-scripts
    gnupg
    btrfs-progs
    systemd
    bash
];

my $BAWN_ROOT = "/opt/bawn";
my $DATA_ROOT = "/data";
my $NSPAWN_ROOT = path::of_nspawn_dir();
my $undeploy_script = "$BAWN_ROOT/undeploy.sh";

my $template = "master-" . localtime->datetime =~ s{[^a-zA-Z0-9_-]}{_}rg;
$template .= "a" while -e path::of_machine($template);

util::run("bash", $undeploy_script) if -f $undeploy_script;
mkdir $BAWN_ROOT unless -d $BAWN_ROOT;
mkdir $DATA_ROOT unless -d $DATA_ROOT;
mkdir $NSPAWN_ROOT unless -d $NSPAWN_ROOT;

print STDERR "\e[1;32mBootstrapping template...\e[0m\n";
my $machine_tmpl = path::of_machine($template);
my $nspawn_tmpl = path::of_nspawn($template);
util::system::create_subvolume($machine_tmpl);
util::spurt($nspawn_tmpl, util::system::nspawn_script());
util::system::bootstrap($machine_tmpl, qw[systemd bash perl]);
util::system::delete_subvolume(path::of_machine_dir($machine_tmpl));
mkdir path::of_machine_dir($machine_tmpl);

my %machines = (
    acme => {
        packages => [qw[nginx certbot certbot-nginx]],
    },
    coordinator => {
        packages => [qw[nginx]],
    },
    ikiwiki => {
        packages => [qw[nginx fcgi]],
    },
);
deploy::machine($machine_tmpl, $_, $machines{$_}) for sort keys %machines;
deploy::enable_service($machine_tmpl, map { "systemd-nspawn\@$_" } sort keys %machines);

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
    use util::system;

    sub enable_service($@)
    {
        my ($root, @services) = @_;
        return unless @services;
        util::system::chroot($root, qw[systemctl enable], @services);
    }

    sub machine($$$)
    {
        my ($tmpl_subvol, $name, $config) = @_;
        print STDERR "\e[1;32mDeploying $name...\e[0m\n";

        $config->{packages} //= [];
        $config->{services} //= [];

        my $machine_path = path::of_machine($name, $tmpl_subvol);
        util::system::create_subvolume($machine_path, $tmpl_subvol);
        util::system::bootstrap($machine_path, @{$config->{packages}});
        enable_service($machine_path, @{$config->{services}});
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

    sub nspawn_script(%)
    {
        my %opts = @_;
        my $private_network = $opts{private_network} ? "Yes" : "No";
        return <<~END;
            [Exec]
            Boot=yes
            PrivateUsers=no

            [Network]
            Private=$private_network
            END
    }
}

