package GeoDNS;
use strict;
use warnings;
use Net::DNS::RR;
use Countries qw(continent);
use Geo::IP;
use List::Util qw/max shuffle/;
use Carp qw(carp croak);
use JSON qw();
use Data::Dumper;

our $VERSION  = '1.1';
our $REVISION = ('$Rev$' =~ m/(\d+)/x)[0];
my $HeadURL = ('$HeadURL$'
                 =~ m!https?:(//[^/]+.*)(?:/lib.*)!x)[0];

my $gi = Geo::IP->new(GEOIP_STANDARD);

sub new {
  my $class = shift;
  my %args  = @_;

  $args{interface} ||= 'unknown_interface';

  $args{config} = {};
  $args{stats}->{started} = time;

  return bless \%args, $class;
}

sub config {
  my ($self, $base) = @_;
  return $self->{config} unless $base;
  return $self->{config}->{bases}->{$base}; # returns undef on "invalid" base
}

sub reply_handler {
  my $self = shift;

  $self->check_config();

  my ($qname, $qclass, $qtype, $peerhost) = @_;
  $qname = lc $qname . '.';

  # warn "$peerhost | $qname | $qtype $qclass \n";

  my $stats = $self->{stats};

  $stats->{qname}->{$qname}++;
  $stats->{qtype}->{$qtype}++;
  $stats->{queries}++;

  my ($base, $qgroup) = $self->find_base($qname);
  $base or return 'SERVFAIL';

  my $config_base = $self->config($base);

  my (@ans, @auth, @add);

  # when are we supposed to add the SOA record and when the NS records here?
  push @auth, @{ ($self->_get_ns_records($config_base))[0] };
  push @add,  @{ ($self->_get_ns_records($config_base))[1] };

  if ($qname eq $base and $qtype =~ m/^(NS|SOA)$/x) {
    if ($qtype eq 'SOA') {
      push @ans, $self->_get_soa_record($config_base);
    }
    if ($qtype eq 'NS') {
      # don't need the authority section for this request ...
      @auth = @add = ();
      push @ans, @{ ($self->_get_ns_records($config_base))[0] };
      push @add, @{ ($self->_get_ns_records($config_base))[1] };
    }
    return ('NOERROR', \@ans, \@auth, \@add, { aa => 1 });
  }

  if ($config_base->{groups}->{$qgroup}) {

    my @hosts;
    if ($qtype =~ m/^(A|ANY|TXT)$/x) {
      my (@groups) = $self->pick_groups($config_base, $peerhost, $qgroup);
      for my $group (@groups) { 
	push @hosts, $self->pick_hosts($config_base, $group);
	last if @hosts; 
	  # add ">= 2" to force at least two hosts even if the second one won't be as local 
      }
    }
    
    if ($qtype eq 'A' or $qtype eq 'ANY') {
      for my $host (@hosts) {
          push @ans, Net::DNS::RR->new(
                                       name => $qname,
                                       ttl => $config_base->{ttl},
                                       type => 'A',
                                       address => $host->{ip}
                                       );
      }
    } 

    if ($qtype eq 'TXT' or $qtype eq 'ANY') {
      for my $host (@hosts) {
          push @ans, Net::DNS::RR->new(
                                       name => $qname,
                                       ttl => $config_base->{ttl},
                                       type => 'TXT',
                                       txtdata => ($host->{ip} eq $host->{name} 
                                                   ? "$host->{ip}-$host->{weight}"
                                                   : "$host->{ip}/$host->{name}-$host->{weight}"
                                                  ),
                                       );
      }
    } 

    @auth = ($self->_get_soa_record($config_base)) unless @ans;

    # mark the answer as authoritive (by setting the 'aa' flag
    return ('NOERROR', \@ans, \@auth, \@add, { aa => 1 });

  }
  elsif ($config_base->{ns}->{$qname}) {
    push @ans, grep { $_->address eq $config_base->{ns}->{$qname} } @{ ($self->_get_ns_records($config_base))[1] };
    @add = grep { $_->address ne $config_base->{ns}->{$qname} } @add;
    return ('NOERROR', \@ans, \@auth, \@add, { aa => 1 });
 }

  elsif ($qname =~ m/^status\.\Q$base\E$/x) {
    my $uptime = (time - $stats->{started}) || 1;
    # TODO: convert to 2w3d6h format ...
    my $status = sprintf '%s, upt: %i, q: %i, %.2f/qps',
      $self->{interface}, $uptime, $stats->{queries}, $stats->{queries}/$uptime;
      warn Data::Dumper->Dump([\$stats], [qw(stats)]);
    push @ans, Net::DNS::RR->new("$qname. 1 IN TXT '$status'") if $qtype eq 'TXT' or $qtype eq 'ANY';
    return ('NOERROR', \@ans, \@auth, \@add, { aa => 1 });
  }
  elsif ($qname =~ m/^version\.\Q$base\E$/x) {
    my $version = "$self->{interface}, v$VERSION/$REVISION $HeadURL";
    push @ans, Net::DNS::RR->new("$qname. 1 IN TXT '$version'") if $qtype eq 'TXT' or $qtype eq 'ANY';
    return ('NOERROR', \@ans, \@auth, \@add, { aa => 1 });
  }
  else {
    @auth = $self->_get_soa_record($config_base);
    return ('NXDOMAIN', [], \@auth, [], { aa => 1 });
  }

}


sub _get_ns_records {
  my ($self, $config_base) = @_;
  my (@ans, @add);
  my $base = $config_base->{base};
  for my $ns (keys %{ $config_base->{ns} }) {
    push @ans, Net::DNS::RR->new("$base 86400 IN NS $ns.");
    push @add, Net::DNS::RR->new("$ns. 86400 IN A $config_base->{ns}->{$ns}")
      if $config_base->{ns}->{$ns};
  }
  return (\@ans, \@add);
}

sub _get_soa_record {
  my ($self, $config_base) = @_;
  return Net::DNS::RR->new
    ("$config_base->{base}. 3600 IN SOA $config_base->{primary_ns};
      support.bitnames.com. $config_base->{serial} 5400 5400 2419200 $config_base->{ttl}");
}

sub pick_groups {
  my $self        = shift;
  my $config_base = shift; 
  my $client_ip   = shift;
  my $qgroup      = shift;

  my $country   = lc($gi->country_code_by_addr($client_ip) || 'us');
  my $continent = continent($country) || 'north-america';

  my @candidates = ($country);
  push @candidates, $continent
    unless $continent eq 'asia';
  push @candidates, '';  

  my @groups;

  for my $candidate (@candidates) {
    my $group = join '.', grep { $_ } $qgroup,$candidate;
    push @groups, $group if $config_base->{groups}->{$group};
  }
		     
  return @groups;
}

sub pick_hosts {
  my ($self, $config_base, $group_name) = @_;

  my $group = $config_base->{groups}->{$group_name};
  return unless $group and $group->{servers};

  my @answer;
  my $max = $config_base->{max_hosts} || 2;

  my $loop = 0;

  unless ($group->{total_weight}) {
      # find total weight;
      my $total = 0;
      my @servers = ();
      for (sort { $a->[1] <=> $b->[1] } @{$group->{servers}}) {
          $total += $_->[1];
          push @servers, [0,$_];
      }
      $group->{servers} = \@servers;
      $group->{total_weight} = $total;
  }

  my $total_weight = $group->{total_weight};

  #warn Data::Dumper->Dump([\{$group->{servers}}], [qw(servers)]);

  my @picked;

  while ($total_weight and @answer < $max) {
    last if ++$loop > 10;  # bad configuration could make us loop ...

    my $n = int(rand( $total_weight ));
    my $host;
    my $total = 0;
    for (@{$group->{servers}}) {
        next if $_->[0];
        $total += $_->[1]->[1];
        if ($total > $n) {
            push @picked, $_;
            $_->[0] = 1;
            $total_weight -= $_->[1]->[1];
            $host = $_->[1];
            last;
        }
    }

    my $hostname = $host->[0];

    my $ip = $hostname =~ m/^\d{1,3}(.\d{1,3}){3}$/x ? $hostname : $config_base->{hosts}->{$hostname}->{ip};

    push @answer, ({ name => $hostname, ip => $ip, weight => $host->[1] });
  }

  map { $_->[0] = 0 } @picked;

  return @answer;
}


sub find_base {
  # should we cache these?
  my ($self, $qname) = @_;
  my $base;
  map { $base = $_ if $qname =~ m/(?:^|\.)\Q$_\E$/x
          and (!$base or length $_ > length $base)
      } keys %{ $self->config->{bases} };

  return $base unless $base and wantarray;

  my ($qgroup) = ($qname =~ m/(?:(.*)\.)? # "group name"
                              \Q$base\E$  # anchor in the base name
                            /x);

  return ($base, $qgroup || '');
}

sub load_config {
  my $self     = shift;
  my $filename = shift or confess "load_config requires a filename";

  my $config = {};
  $config->{last_config_check} = time;
  $config->{files} = [];

  _read_config( $config, $filename );

  delete $config->{base};

  # warn Data::Dumper->Dump([\$config], [qw(config)]);

  # the default serial is timestamp of the newest config file. 
  $config->{serial} = max map {$_->[1]} @{ $config->{files} }
    unless $config->{serial} and $config->{serial} =~ m/^\d+$/;
  $config->{ttl}    = 180 unless $config->{ttl} and $config->{ttl} !~ m/\D/;

  for my $base (keys %{$config->{bases}}) {
    my $config_base = $config->{bases}->{$base};

    # for the old style configs we do this when the first NS is set,
    # but we don't have that cleanup for "pure" json configs
    unless ($config_base->{primary_ns}) {
        ($config_base->{primary_ns}) = keys %{$config_base->{ns}} if $config_base->{ns};
    }

    for my $f (qw(ns primary_ns ttl serial)) {
      $config_base->{$f} = $config->{$f} or die "default $f needed but not set"
	unless $config_base->{$f};
    }

    die "no ns configured in the config file for base $base"
      unless $config_base->{ns};
  }

  # use Data::Dumper;
  # warn Data::Dumper->Dump([\$config], [qw(config)]);

  $self->{config} = $config;

  return 1;
}

my @config_file_stack;

sub _read_config {
  my $config = shift;
  my $file = shift;

  if (grep {$_ eq $file} @config_file_stack) {
    die "Oops, recursive inclusion of $file - parent(s): ", join ', ', @config_file_stack;
  }

  open my $fh, '<', $file
    or warn "Can't open config file: $file: $!\n" and return;

  push @config_file_stack, $file;

  push @{ $config->{files} }, [$file, (stat($file))[9]];

  while (<$fh>) {
    chomp;
    s/^\s+//;
    s/\s+$//;
    next if /^\#/ or /^$/;
    last if /^__END__$/;

    if (s/^base\s+//) {
      my ($base_name, $json_file) = split /\s+/, $_;
      $base_name .= '.' unless $base_name =~ m/\.$/;
      $config->{base} = $base_name;
      if ($json_file) {
          open my $json_fh, '<', $json_file or warn "Could not open $json_file: $!\n" and next;
          push @{ $config->{files} }, [$json_file, (stat($json_file))[9]];
          my $json = eval { local $/ = undef; <$json_fh> };
          close $json_fh;
          $config->{bases}->{$base_name} = JSON::jsonToObj($json);
      }
      $config->{bases}->{$base_name}->{base} = $base_name;
      next;
    }
    elsif (s/^include\s+//) {
      _read_config($config, $_);
      next;
    }

    unless ($config->{base}) {
      if (s/^ns\s+//) {
	my ($name, $ip) = split /\s+/, $_;
        $name .= '.' unless $name =~ m/\.$/;
	$config->{ns}->{$name} = $ip;
	$config->{primary_ns} = $name
	  unless $config->{primary_ns};
	next;
      }
      elsif (s/^(serial|ttl|primary_ns)\s+//) {
	$config->{$1} = $_;
        next;
      }
    }

    die "Bad configuration: [$_], no base defined\n"
      unless $config->{base};

    my $base = $config->{base};
    my $config_base = $config->{bases}->{$base};

    if (s/^ns\s+//) {
      my ($name, $ip) = split /\s+/, $_;
      $name .= '.' unless $name =~ m/\.$/;  # TODO: refactor this so these lines aren't duplicated
                                            # with the ones above
      $config_base->{ns}->{$name} = $ip;
      $config_base->{primary_ns} = $name
	unless $config_base->{primary_ns};
    }
    elsif (s/^(serial|ttl|primary_ns|max_hosts)\s+//) {
      $config_base->{$1} = $_;
    }
    else {
      s/^\s*10+\s+//;
      my ($host, $ip, $groups) = split(/\s+/,$_,3);
      die "Bad configuration line: [$_]\n" unless $groups;
      $host = "$host." unless $host =~ m/\.$/;
      $config_base->{hosts}->{$host} = { ip => $ip };
      for my $group_name (split /\s+/, $groups) {
	$group_name = '' if $group_name eq '@';
	$config_base->{groups}->{$group_name}->{servers} ||= [];
	push @{$config_base->{groups}->{$group_name}->{servers}}, [ $host, 1 ];
      }
    }
  }
  pop @config_file_stack;
  return 1;
}

sub check_config {
  my $self = shift;
  return unless time >= ($self->config->{last_config_check} + 30);
  my ($first_file) = (@{$self->config->{files}})[0];
  cluck 'No "first_file' unless $first_file;
  #return unless $first_file;
  for my $file (@{$self->config->{files}}) {
    do { load_config($first_file); last }
      if (stat($file->[0]))[9] != $file->[1]
  }
  return 1;
}

1;


__END__

=head1 NAME

GeoDNS

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item new

Instantiates a new GeoDNS object.

=item reply_handler

=item pick_groups

=item pick_hosts

=item pick_host

=item load_config($file_name)

Loads the specified configuration file (usually pgeodns.conf).
Supplemental files are loaded via "include" statements or implicit
JSON file loads from the "base" statement.

=item config

Returns the current configuration hash for the object instance.

=item check_config

Checks if any of the configuration files have changed and initiates a
reload if any file has changed since the last load.  It skips checking
unless it's been more than 30 seconds since the last check.

Called automatically from the reply_handler.

=item find_base($name)

Given a domain name, returns the longest matching configured "base".

=back

=head1 COPYRIGHT

Copyright 2004-2007 Ask Bjoern Hansen and Develooper LLC.  This work
is distributed under the Apache License 2.0 (see the F<LICENSE> file
for more details).
