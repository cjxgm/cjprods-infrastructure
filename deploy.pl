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
                    my $filename = s{::}{/}r . ".pm";
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

use sanity;
use util::system;
sanity::check();

util::system::install qw[
    arch-install-scripts
    gnupg
    btrfs-progs
    systemd
];

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
}

package util::system
{
    use util;

    sub install(@)
    {
        util::run qw[pacman -S --needed], @_;
    }
}

