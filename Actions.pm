# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Actions;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

# item => Class
#   multiple classes space separated
#   Begins with a ?    only checks if defined
#   '@' or '%'         unblessed array or hash
#   '$'                checks that it is a string/number
#   '!'                verifies that it is undef
#   ''                 allows anything

=head1 Actions

Basic descriptions and checking of all internal janus actions

=head2 Internal Janus events

=over

=item NETLINK Sent when a connection to/from janus is initalized 

=item BURST Sent when a connection is ready to start syncing data

=item LINKED Sent when a connection is fully linked

=item NETSPLIT Disconnects a network from janus

=item RAW Internal network action; do not intercept or inspect

=back

=head2 Nick-Network motion events

=over

=item NEWNICK Nick has connected to its home net

=item CONNECT Janus nick introduced to a remote net

=item RECONNECT Janus nick reintroduced to a remote net

=item KILL Oper (or services) removes a remote nick from their network

=item QUIT Janus nick leaves home net, possibly involuntarily

=back

=head2 Nick-Channel motion events

=over

=item JOIN Nick joins a channel, possibly coming in with some modes (op)

=item PART Nick leaves a channel

=item KICK Nick involuntarily leaves a channel

=back

=head2 Channel state changes

=over

=item MODE Basic mode change

=over 

=item n nick access level

=item l list (bans)

=item v value (key)

=item s value-on-set (limit)

=item r regular (moderate)

=item t tristate (private/secret; this is planned, not implemented)

=back

=item TIMESYNC Channel creation timestamp modification

=item TOPIC Channel topic change

=back

=head2 Nick state changes

=over

=item NICK nickname change

=item UMODE nick mode change

=item NICKINFO nick metainformation change

=back

=head2 Communication

=over

=item MSG Overall one-to-some messaging

=item WHOIS remote idle queries

=item CHATOPS internetwork administrative communication

=back

=head2 Janus commands

=over

=item LINKREQ initial request to link a channel

=item LSYNC internal sync for InterJanus channel links

=item LINK final atomic linking and mode merge

=back

=cut

my %spec = (

	NETLINK => {
		net => 'Network',
	},
	LINKED => {
		net => 'Network',
	},
	BURST => {
		net => 'Network',
	},
	NETSPLIT => {
		net => 'Network',
		msg => '$',
	},

	NEWNICK => {
		dst => 'Nick',
	},
	CONNECT => {
		dst => 'Nick',
		net => 'Network',
	}, 
	RECONNECT => {
		dst => 'Nick',
		net => 'Network',
		killed => '$', # 1 = reintroduce, 0 = renick
	},
	KILL => {
		dst => 'Nick',
		msg => '?$',
		net => 'Network',
	},
	QUIT => {
		dst => 'Nick',
		msg => '$',
		killer => '?Nick Network',
		netsplit_quit => '?$',
	},

	JOIN => {
		src => 'Nick',
		dst => 'Channel',
		mode => '?%',
	},
	PART => {
		src => 'Nick',
		dst => 'Channel',
		msg => '?$',
	},
	KICK => {
		dst => 'Channel',
		kickee => 'Nick',
		msg => '$',
	},

	MODE => {
		dst => 'Channel',
		mode => '@',
		args => '@',
	},
	TIMESYNC => {
		dst => 'Channel',
		wipe => '$',
		ts => '$',
		oldts => '$',
	},
	TOPIC => {
		dst => 'Channel',
		topicset => '$',
		topicts => '$',
		topic => '$',
		in_link => '?$',
	},

	NICK => {
		dst => 'Nick',
		nick => '$',
		nickts => '?$',
	},
	UMODE => {
		dst => 'Nick',
		mode => '@',
	},
	NICKINFO => {
		dst => 'Nick',
		item => '$',
		value => '?$',
	},

	MSG => {
		src => 'Nick Network',
		dst => 'Nick Channel',
		msgtype => '$',
		msg => '$ @',
		prefix => '?$',
	},
	WHOIS => {
		src => 'Nick',
		dst => 'Nick',
	},
	CHATOPS => {
		src => 'Nick',
		msg => '$',
	},

	LINKREQ => {
		dst => 'Network',
		net => 'Network',
		slink => '$',
		dlink => '$',
		linkfile => '?$',
		override => '?$',
	},
	LSYNC => {
		dst => 'Network',
		chan => 'Channel',
		linkto => '$',
		linkfile => '?$',
	},
	LINK => {
		chan1 => '?Channel',
		chan2 => '?Channel',
		linkfile => '?$',
	},
	DELINK => {
		net => 'Network',
		netsplit_quit => '?$',
		'split' => '?Channel',
	},

	InterJanus => {
		pass => '$',
		version => '$',
		id => '$',
		net => 'InterJanus',
	},
	PING => {},
	PONG => {},
	REHASH => {},

	XLINE => {
		dst => 'Network',
		ltype => '$',
		mask => '$',
		setter => '?$',
		expire => '$', # = 0 for permanent, = 1 for unset, = time else
		settime => '?$', # only valid if setting
		reason => '?$',  # only valid if setting
	},
);

my %default = (
	type => '$',
	src => '?Nick Network',
	dst => '?Nick Channel Network',
	except => '?Network InterJanus',
	sendto => '?@',
	nojlink => '?$',
);

for my $type (keys %spec) {
	for my $i (keys %default) {
		next if exists $spec{$type}{$i};
		$spec{$type}{$i} = $default{$i};
	}
}

&Janus::hook_add(ALL => validate => sub {
	my $act = shift;
	my $itm = $act->{type};
	my $check = $spec{$itm};
	unless ($check) {
		return undef if $itm eq 'RAW';
		print "Unknown action type $itm\n";
		return undef;
	}
	KEY: for my $k (keys %$check) {
		$@ = "Fail: Key $k in $itm";
		$_ = $$check{$k};
		my $v = $act->{$k};
		if (s/^\?//) {
			next KEY unless defined $v;
		} else {
			return 1 unless defined $v;
		}
		if (s/^~//) {
			return 1 unless eval;
		}
		my $r = 0;
		for (split /\s+/) {
			next KEY if eval {
				/\$/ ? (defined $v && '' eq ref $v) :
				/\@/ ? (ref $v && 'ARRAY' eq ref $v) :
				/\%/ ? (ref $v && 'HASH' eq ref $v) :
				$v->isa($_);
			};
		}
		$@ = "Invalid value $v for key '$k' in action $itm";
		return 1 unless $r;
	}
	for my $k (keys %$act) {
		next if exists $check->{$k};
		print "Warning: unknown key $k in action $itm\n";
	}
	undef;
});

1;