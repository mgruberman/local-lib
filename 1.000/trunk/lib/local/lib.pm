use strict;
use warnings;

package local::lib;

use 5.8.1; # probably works with earlier versions but I'm not supporting them
           # (patches would, of course, be welcome)

use File::Spec ();
use File::Path ();
use Carp ();
use Config;

our $VERSION = '1.000000'; # 1.0.0

sub import {
  my ($class, $path) = @_;
  $path = $class->resolve_path($path);
  $class->setup_local_lib_for($path);
}

sub compose;

sub compose {
  my @methods = @_;
  my $last = pop(@methods);
  if (@methods) {
    \sub {
      my ($obj, @args) = @_;
      $obj->${compose @methods}(
        $obj->$last(@args)
      );
    };
  } else {
    \sub {
      shift->$last(@_);
    };
  }
}

=for test

package local::lib;

{ package Foo; sub foo { -$_[1] } sub bar { $_[1]+2 } sub baz { $_[1]+3 } }
my $foo = bless({}, 'Foo');                                                 
ok($foo->${compose qw(foo bar baz)}(10) == -15);

=cut

sub resolve_path {
  my ($class, $path) = @_;
  $class->${compose qw(
    resolve_relative_path
    resolve_home_path
    resolve_empty_path
  )}($path);
}

sub resolve_empty_path {
  my ($class, $path) = @_;
  if (defined $path) {
    $path;
  } else {
    '~/perl5';
  }
}

=for test classmethod setup

my $c = 'local::lib';

=cut

=for test classmethod

is($c->resolve_empty_path, '~/perl5');
is($c->resolve_empty_path('foo'), 'foo');

=cut

sub resolve_home_path {
  my ($class, $path) = @_;
  return $path unless ($path =~ /^~/);
  my ($user) = ($path =~ /^~([^\/]+)/); # can assume ^~ so undef for 'us'
  my $tried_file_homedir;
  my $homedir = do {
    if (eval { require File::HomeDir } && $File::HomeDir::VERSION >= 0.65) {
      $tried_file_homedir = 1;
      if (defined $user) {
        File::HomeDir->users_home($user);
      } else {
        File::HomeDir->my_homedir;
      }
    } else {
      if (defined $user) {
        (getpwnam $user)[7];
      } else {
        if (defined $ENV{HOME}) {
          $ENV{HOME};
        } else {
          (getpwuid $<)[7];
        }
      }
    }
  };
  unless (defined $homedir) {
    Carp::croak(
      "Couldn't resolve homedir for "
      .(defined $user ? $user : 'current user')
      .($tried_file_homedir ? '' : ' - consider installing File::HomeDir')
    );
  }
  $path =~ s/^~[^\/]*/$homedir/;
  $path;
}

sub resolve_relative_path {
  my ($class, $path) = @_;
  File::Spec->rel2abs($path);
}

=for test classmethod

local *File::Spec::rel2abs = sub { shift; 'FOO'.shift; };
is($c->resolve_relative_path('bar'),'FOObar');

=cut

sub setup_local_lib_for {
  my ($class, $path) = @_;
  $class->ensure_dir_structure_for($path);
  if ($0 eq '-') {
    $class->print_environment_vars_for($path);
    exit 0;
  } else {
    $class->setup_env_hash_for($path);
  }
}

sub modulebuildrc_path {
  my ($class, $path) = @_;
  File::Spec->catfile($path, '.modulebuildrc');
}

sub install_base_bin_path {
  my ($class, $path) = @_;
  File::Spec->catdir($path, 'bin');
}

sub install_base_perl_path {
  my ($class, $path) = @_;
  File::Spec->catdir($path, 'lib', 'perl5');
}

sub install_base_arch_path {
  my ($class, $path) = @_;
  File::Spec->catdir($class->install_base_perl_path($path), $Config{archname});
}

sub ensure_dir_structure_for {
  my ($class, $path) = @_;
  unless (-d $path) {
    warn "Attempting to create directory ${path}\n";
  }
  File::Path::mkpath($path);
  my $modulebuildrc_path = $class->modulebuildrc_path($path);
  if (-e $modulebuildrc_path) {
    unless (-f _) {
      Carp::croak("${modulebuildrc_path} exists but is not a plain file");
    }
  } else {
    warn "Attempting to create file ${modulebuildrc_path}\n";
    open MODULEBUILDRC, '>', $modulebuildrc_path
      || Carp::croak("Couldn't open ${modulebuildrc_path} for writing: $!");
    print MODULEBUILDRC qq{--install_base  ${path}\n}
      || Carp::croak("Couldn't write line to ${modulebuildrc_path}: $!");
    close MODULEBUILDRC
      || Carp::croak("Couldn't close file ${modulebuildrc_path}: $@");
  }
}

sub INTERPOLATE_PATH () { 1 }
sub LITERAL_PATH     () { 0 }

sub print_environment_vars_for {
  my ($class, $path) = @_;
  my @envs = $class->build_environment_vars_for($path, LITERAL_PATH);
  my $out = '';
  while (@envs) {
    my ($name, $value) = (shift(@envs), shift(@envs));
    $value =~ s/(\\")/\\$1/g;
    $out .= qq{export ${name}="${value}"\n};
  }
  print $out;
}

sub setup_env_hash_for {
  my ($class, $path) = @_;
  my %envs = $class->build_environment_vars_for($path, INTERPOLATE_PATH);
  @ENV{keys %envs} = values %envs;
}

sub build_environment_vars_for {
  my ($class, $path, $interpolate) = @_;
  return (
    MODULEBUILDRC => $class->modulebuildrc_path($path),
    PERL_MM_OPT => "INSTALL_BASE=${path}",
    PERL5LIB => join(':',
                  $class->install_base_perl_path($path),
                  $class->install_base_arch_path($path),
                ),
    PATH => join(':',
              $class->install_base_bin_path($path),
              ($interpolate == INTERPOLATE_PATH
                ? $ENV{PATH}
                : '$PATH')
             ),
  )
}

=for test classmethod

File::Path::rmtree('t/var/splat');

$c->resolve_relative_path('t/var/splat');

ok(-d 't/var/splat');

ok(-f 't/var/splat/.modulebuildrc');

=head1 NAME

local::lib - create and use a local lib/ for perl modules with PERL5LIB

=head1 SYNOPSIS

In code -

  use local::lib; # sets up a local lib at ~/perl5

  use local::lib '~/foo'; # same, but ~/foo

From the shell -

  $ perl -Mlocal::lib
  export MODULEBUILDRC=/home/username/perl/.modulebuildrc
  export PERL_MM_OPT='INSTALL_BASE=/home/username/perl'
  export PERL5LIB='/home/username/perl/lib/perl5:/home/username/perl/lib/perl5/i386-linux'
  export PATH="/home/username/perl/bin:$PATH"

=head1 AUTHOR

Matt S Trout <mst@shadowcat.co.uk> http://www.shadowcat.co.uk/

=head1 LICENSE

This library is free software under the same license as perl itself

=cut

1;