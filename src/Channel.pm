# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Channel;
use strict;
use warnings;
use Persist;
use Carp;
use Modes;

=head1 Channel

Object representing a set of linked channels

=over

=item Channel->new(arghash)

Create a new channel. Should only be called by LocalNetwork and InterJanus.

=item $chan->ts()

Timestamp for this channel

=item $chan->keyname()

Name used for this channel in interjanus communication

=item $chan->topic()

Topic text for the channel

=item $chan->topicts()

Topic set timestamp

=item $chan->topicset()

String representing the setter of the topic

=item $chan->all_modes()

Hash of modetext => modeval (see Modes.pm)

=item $chan->nets()

List of all networks this channel is on

=item $chan->str($net)

get the channel's name on a given network, or undef if the channel is
not on the network

=item $chan->is_on($net)

returns true if the channel is linked onto the given network

=cut

our(@ts, @keyname, @topic, @topicts, @topicset, @mode);

our @nicks;  # all nicks on this channel
our @nmode;  # modes of those nicks

&Persist::register_vars(qw(ts keyname topic topicts topicset mode nicks nmode));
&Persist::autoget(qw(ts keyname topic topicts topicset), all_modes => \@mode);
&Persist::autoinit(qw(ts topic topicts topicset));

my %nmodebit = (
	voice => 1,
	halfop => 2,
	op => 4,
	admin => 8,
	owner => 16,
);

=item $chan->has_nmode($mode, $nick)

Returns true if the nick has the given mode in the channel (n_* modes)

=cut

sub has_nmode {
	my($chan, $mode, $nick) = @_;
	$mode =~ s/^n_// and carp "Stripping deprecated n_ prefix";
	my $m = $nmodebit{$mode} or do {
		carp "Unknown nick mode $mode";
		return 0;
	};
	my $n = $nmode[$$chan]{$$nick} || 0;
	$n & $m;
}

=item $chan->get_nmode($nick)

Gets a hashref whose keys are the nick modes on the channel.

=cut

sub get_nmode {
	my($chan, $nick) = @_;
	my %m;
	my $n = $nmode[$$chan]{$$nick} || 0;
	$n & $nmodebit{$_} and $m{$_}++ for keys %nmodebit;
	\%m;
}

sub get_mode {
	my($chan, $itm) = @_;
	$mode[$$chan]{$itm};
}

=item $chan->all_nicks()

return a list of all nicks on the channel

=cut

sub all_nicks {
	my $chan = $_[0];
	return @{$nicks[$$chan]};
}

=item $chan->part($nick)

remove records of this nick (for quitting nicks)

=cut

sub part {
	my($chan,$nick,$fast) = @_;
	$nicks[$$chan] = [ grep { $_ != $nick } @{$nicks[$$chan]} ];
	delete $nmode[$$chan]{$$nick};
	return if $fast || @{$nicks[$$chan]};
	$chan->unhook_destroyed();
	&Janus::append({ type => 'POISON', item => $chan, reason => 'Final part' });
}

&Janus::hook_add(
	JOIN => act => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		my $on;
		$nick == $_ and $on++ for @{$nicks[$$chan]};
		push @{$nicks[$$chan]}, $nick unless $on;
		if ($act->{mode}) {
			for (keys %{$act->{mode}}) {
				warn "Unknown mode $_" unless $nmodebit{$_};
				$nmode[$$chan]{$$nick} |= $nmodebit{$_};
			}
		}
	}, PART => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$chan->part($nick, $act->{delink});
	}, KICK => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{kickee};
		my $chan = $act->{dst};
		$chan->part($nick, 0);
	}, TIMESYNC => act => sub {
		my $act = $_[0];
		my $chan = $act->{dst};
		my $ts = $act->{ts};
		if ($ts < 1000000) {
			#don't EVER destroy channel TSes with that annoying Unreal message
			warn "Not destroying channel timestamp; mode desync may happen!" if $ts;
			return;
		}
		$ts[$$chan] = $ts;
		if ($act->{wipe}) {
			$nmode[$$chan] = {};
			$mode[$$chan] = {};
		}
	}, MODE => act => sub {
		my $act = $_[0];
		local $_;
		my $chan = $act->{dst};
		my @dirs = @{$act->{dirs}};
		my @args = @{$act->{args}};
		for my $i (@{$act->{mode}}) {
			my $pm = shift @dirs;
			my $arg = shift @args;
			my $t = $Modes::mtype{$i} || '?';
			if ($t eq 'n') {
				unless (ref $arg && $arg->isa('Nick')) {
					warn "$i without nick arg!";
					next;
				}
				$nmode[$$chan]{$$arg} |= $nmodebit{$i}; # will ensure is defined
				$nmode[$$chan]{$$arg} &= ~$nmodebit{$i} if $pm eq '-';
			} elsif ($t eq 'l') {
				next unless defined $arg;
				if ($pm eq '+') {
					@{$mode[$$chan]{$i}} = ($arg, grep { $_ ne $arg } @{$mode[$$chan]{$i}});
				} else {
					@{$mode[$$chan]{$i}} = grep { $_ ne $arg } @{$mode[$$chan]{$i}};
				}
			} elsif ($t eq 'v') {
				$mode[$$chan]{$i} = $arg if $pm eq '+';
				delete $mode[$$chan]{$i} if $pm eq '-';
			} elsif ($t eq 'r') {
				my $v = 0+($mode[$$chan]{$i} || 0);
				$v |= $arg;
				$v &= ~$arg if $pm eq '-';
				$v ? $mode[$$chan]{$i} = $v : delete $mode[$$chan]{$i};
			} else {
				warn "Unknown mode '$i'";
			}
		}
	}, TOPIC => act => sub {
		my $act = $_[0];
		my $chan = $act->{dst};
		$topic[$$chan] = $act->{topic};
		$topicts[$$chan] = $act->{topicts} || $Janus::time;
		$topicset[$$chan] = $act->{topicset};
		unless ($topicset[$$chan]) {
			if ($act->{src} && $act->{src}->isa('Nick')) {
				$topicset[$$chan] = $act->{src}->homenick();
			} else {
				$topicset[$$chan] = 'janus';
			}
		}
	}
);

### MODE SPLIT ###
eval($Janus::lmode eq 'Bridge' ? '#line '.__LINE__.' "'.__FILE__.qq{"\n}.q[#[[]]
### BRIDGE MODE ###
sub nets {
	values %Janus::nets;
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
	$out .= ' ts='.$ij->ijstr($ts[$$chan]);
	$out .= ' topic='.$ij->ijstr($topic[$$chan]);
	$out .= ' topicts='.$ij->ijstr($topicts[$$chan]);
	$out .= ' topicset='.$ij->ijstr($topicset[$$chan]);
	$out .= ' mode='.$ij->ijstr($mode[$$chan]);
	$out .= ' name='.$ij->ijstr($keyname[$$chan]);
	$out;
}

sub _init {
	my($c, $ifo) = @_;
	{	no warnings 'uninitialized';
		$mode[$$c] = $ifo->{mode} || {};
		$nicks[$$c] = [];
		$nmode[$$c] = {};
		$topicts[$$c] += 0;
		$ts[$$c] += 0;
		$ts[$$c] = ($Janus::time + 60) if $ts[$$c] < 1000000;
	}
	$keyname[$$c] = $ifo->{name};
}

sub _destroy {
	my $c = $_[0];
	$keyname[$$c];
}

sub str {
	my($chan,$net) = @_;
	$keyname[$$chan];
}

sub is_on {
	1
}

sub sendto {
	values %Janus::nets;
}

sub unhook_destroyed {
	my $chan = shift;
	&LocalNetwork::replace_chan(undef, $keyname[$$chan], undef);
}

1 ] : '#line '.__LINE__.' "'.__FILE__.qq{"\n}.q[#[[]]
### LINK MODE ###
our @homenet; # controlling network of this channel
our @names;   # channel's name on the various networks
our @nets;    # networks this channel is shared to

&Persist::register_vars(qw(homenet names nets));
&Persist::autoinit(qw(homenet));
&Persist::autoget(qw(homenet));

sub nets {
	values %{$nets[${$_[0]}]};
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
	$out .= ' ts='.$ij->ijstr($ts[$$chan]);
	$out .= ' topic='.$ij->ijstr($topic[$$chan]);
	$out .= ' topicts='.$ij->ijstr($topicts[$$chan]);
	$out .= ' topicset='.$ij->ijstr($topicset[$$chan]);
	$out .= ' mode='.$ij->ijstr($mode[$$chan]);
	$out .= ' homenet='.$ij->ijstr($homenet[$$chan]);
	my %nnames = map { $_->gid(), $names[$$chan]{$$_} } values %{$nets[$$chan]};
	$out .= ' names='.$ij->ijstr(\%nnames);
	$out;
}

sub _init {
	my($c, $ifo) = @_;
	{	no warnings 'uninitialized';
		$mode[$$c] = $ifo->{mode} || {};
		$nicks[$$c] = [];
		$nmode[$$c] = {};
		$topicts[$$c] += 0;
		$ts[$$c] += 0;
		$ts[$$c] = ($Janus::time + 60) if $ts[$$c] < 1000000;
	}
	if ($ifo->{net}) {
		my $net = $ifo->{net};
		my $kn = $net->gid().lc $ifo->{name};
		$homenet[$$c] = $net;
		$nets[$$c]{$$net} = $net;
		$names[$$c]{$$net} = $ifo->{name};
	} else {
		my $names = $ifo->{names} || {};
		$names[$$c] = {};
		$nets[$$c] = {};
		for my $id (keys %$names) {
			my $name = $names->{$id};
			my $net = $Janus::gnets{$id} or warn next;
			$names[$$c]{$$net} = $name;
			$nets[$$c]{$$net} = $net;
			if ($net == $homenet[$$c] && 1 < scalar keys %$names) {
				$keyname[$$c] = $net->gid().lc $name;
			}
		}
	}
	join ',', sort map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
}

sub _destroy {
	my $c = $_[0];
	join ',', sort map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
}

sub _modecpy {
	my($chan, $src) = @_;
	for my $txt (keys %{$mode[$$src]}) {
		my $m = $mode[$$src]{$txt};
		$m = [ @$m ] if ref $m;
		$mode[$$chan]{$txt} = $m;
	}
}

sub add_net {
	my($chan, $src) = @_;
	my $net = $homenet[$$src];
	my $sname = $src->str($net);

	my $joinnets = [ values %{$nets[$$chan]} ];
	my %burstmap;
	for my $n (@$joinnets) {
		my $jl = $n->jlink;
		$burstmap{$$jl} = $jl if $jl;
	}
	my $burstnets = [ $net, values %burstmap ];

	$nets[$$chan]{$$net} = $net;
	$names[$$chan]{$$net} = $sname;

	my $dstname = $chan->homenet->name;
	&Debug::info("Link ".$net->name."$sname into $dstname $keyname[$$chan] ($$net:$$src -> $$chan)");

	my $tsctl = ($ts[$$src] <=> $ts[$$chan]);

	if ($tsctl < 0) {
		&Debug::info("Resetting timestamp from $ts[$$chan] to $ts[$$src]");
		&Janus::insert_full(+{
			type => 'TIMESYNC',
			dst => $chan,
			wipe => 0,
			ts => $ts[$$src],
			oldts => $ts[$$chan],
		});
	}

	unless ($net->jlink) {
		$net->replace_chan($sname, $chan);
		$net->send({
			type => 'CHANBURST',
			before => $src,
			after => $chan,
		});

		if ($tsctl > 0) {
			delete $nmode[$$src];
		}
	}

	my $jto = [ $net, @$joinnets ];

	&Janus::append({
		type => 'JOIN',
		src => $Interface::janus,
		dst => $chan,
		nojlink => 1,
		sendto => $jto,
	});

	for my $nick (@{$nicks[$$chan]}) {
		$nick->rejoin($chan, $src);
		next if $nick->jlink;
		if ($$nick == 1) {
			# janus nick already on channel
			@$jto = $net;
			next;
		}
		# Every network must send JOINs for its own nicks
		# to all networks
		&Janus::append(+{
			type => 'JOIN',
			src => $nick,
			dst => $chan,
			mode => $chan->get_nmode($nick),
			sendto => $burstnets,
		});
	}

	unless ($net->jlink) {
		for my $nick (@{$nicks[$$src]}) {
			if ($$nick == 1) {
				@$jto = grep { $_ != $net } @$jto;
				next;
			}
			# source network must also send JOINs to everyone. However, since
			# it is local, we can omit sending it to ourselves.
			&Janus::append(+{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				mode => $src->get_nmode($nick),
				sendto => $joinnets,
			});
		}
	}
	&Janus::append({ type => 'POISON', item => $src, reason => 'migrated away' });
}

sub migrate_from {
	my $chan = shift;
	&Debug::info("Migrating nicks to $$chan from", map $$_, @_);
	my %burstmap;
	for my $n ($chan->nets) {
		$burstmap{$$n} = $n;
		my $jl = $n->jlink;
		$burstmap{$$jl} = $jl if $jl;
	}

	for my $src (@_) {
		next if $$src == $$chan;
		for my $net ($src->nets) {
			my $name = $src->str($net);
			$net->replace_chan($name, $chan) if $net->isa('LocalNetwork');
		}
		my %tomap = %burstmap;
		delete $tomap{$$_} for $src->nets;
		my $burstto = [ values %tomap ];

		for my $nick (@{$nicks[$$src]}) {
			$nick->rejoin($chan, $src);
			next if $$nick == 1 || $nick->jlink;
			&Janus::append(+{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				mode => $chan->get_nmode($nick),
				sendto => $burstto,
			});
		}
		&Janus::append({ type => 'POISON', item => $src, reason => 'migrated away' });
	}
}

sub str {
	my($chan,$net) = @_;
	return undef unless $net;
	return $keyname[$$chan] if $net == $Interface::network;
	$names[$$chan]{$$net};
}

sub is_on {
	my($chan, $net) = @_;
	exists $nets[$$chan]{$$net};
}

sub sendto {
	my($chan,$act) = @_;
	values %{$nets[$$chan]};
}

sub real_keyname {
	my $chan = shift;
	my $hn = $homenet[$$chan];
	$hn->gid . lc $chan->str($hn);
}

sub unhook_destroyed {
	my $chan = shift;
	# destroy channel
	for my $id (keys %{$nets[$$chan]}) {
		my $net = $nets[$$chan]{$id};
		my $name = $names[$$chan]{$id};
		my $c = delete $Janus::gchans{$net->gid().lc $name};
		if ($c && $c ne $chan) {
			&Debug::err("Corrupted unhook! $$c found where $$chan expected");
			$Janus::gchans{$net->gid().lc $name} = $c;
			next;
		}
		next if $net->jlink();
		$net->replace_chan($name, undef);
	}
}

sub del_remoteonly {
	my $chan = shift;
	if (@{$nicks[$$chan]}) {
		my @nets = values %{$nets[$$chan]};
		my $cij = undef;
		for my $net (@nets) {
			my $ij = $net->jlink();
			return unless $ij;
			$ij = $ij->parent() while $ij->parent();
			return if $cij && $cij ne $ij;
			$cij = $ij;
		}
		# all networks are on the same ij network. We can't see you anymore
		for my $nick (@{$nicks[$$chan]}) {
			&Janus::append({
				type => 'PART',
				src => $nick,
				dst => $chan,
				msg => 'Delink of invisible channel',
				delink => 1,
				nojlink => 1,
			});
		}
	}
	$chan->unhook_destroyed();
	&Janus::append({ type => 'POISON', item => $chan, reason => 'delink gone' });
}

&Janus::hook_add(
	CHANLINK => check => sub {
		my $act = shift;
		my $schan = $act->{in};
		unless ($schan) {
			my $net = $act->{net};
			my $name = $act->{name};
			if ($net->isa('LocalNetwork')) {
				$schan = $net->chan($name, 1);
			} else {
				$schan = Channel->new(net => $net, name => $name, ts => $act->{dst}->ts);
			}
		}
		if ($act->{dst} == $schan) {
			&Debug::err("Not linking a channel to itself ($$schan)");
			return 1;
		}
		if (1 < scalar $schan->nets) {
			&Debug::err("Channel already linked ($$schan)");
			return 1;
		}

		$act->{in} = $schan;
		undef;
	}, CHANLINK => act => sub {
		my $act = shift;
		my $dchan = $act->{dst};
		my $schan = $act->{in};

		my $kn = $dchan->real_keyname;
		$keyname[$$dchan] = $kn;

		my $gchan = $Janus::gchans{$kn} || $dchan;
		$Janus::gchans{$kn} = $dchan;

		if ($dchan == $gchan) {
			$dchan->add_net($schan);
		} else {
			$dchan->migrate_from($schan, $gchan);
		}
	}, DELINK => check => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		if ($net == $homenet[$$chan]) {
			my $slow_quit = $act->{netsplit_quit} ? 2 : 0;
			for my $on (values %{$nets[$$chan]}) {
				next if $on == $net;
				&Janus::append(+{
					type => 'DELINK',
					net => $on,
					dst => $chan,
					netsplit_quit => $slow_quit,
					nojlink => 1,
				});
			}
		}
		unless (exists $nets[$$chan]{$$net}) {
			&Debug::warn("Cannot delink: channel $$chan is not on network #$$net");
			return 1;
		}
		undef;
	}, DELINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		return if $net == $homenet[$$chan];
		$act->{sendto} = [ values %{$nets[$$chan]} ]; # before the splitting
		delete $nets[$$chan]{$$net} or warn;

		my $name = delete $names[$$chan]{$$net};

		my $split = Channel->new(
			net => $net,
			name => $name,
			ts => $ts[$$chan],
		);
		$topic[$$split] = $topic[$$chan];
		$topicts[$$split] = $topicts[$$chan];
		$topicset[$$split] = $topicset[$$chan];

		$act->{split} = $split;
		$split->_modecpy($chan);
		delete $Janus::gchans{$split->real_keyname};
		$net->replace_chan($name, $split) unless $net->jlink();

		my @presplit = @{$nicks[$$chan]};
		$nicks[$$split] = [ @presplit ];
		$nmode[$$split] = { %{$nmode[$$chan]} };

		my $delink_lvl = $act->{netsplit_quit};
		$delink_lvl++;

		my @parts;

		for my $nick (@presplit) {
			# we need to insert the nick into the split off channel before the delink
			# PART is sent, because code is allowed to assume a PARTed nick was actually
			# in the channel it is parting from; this also keeps the channel from being
			# prematurely removed from the list.
			my %part = (
				type => 'PART',
				src => $nick,
				msg => 'Channel delinked',
				delink => $delink_lvl,
			);
			if ($delink_lvl == 1) {
				# standard delink command
				$part{nojlink} = 1;
			} elsif ($delink_lvl == 2) {
				# delink from a non-homenet netsplit
				$part{sendto} = [];
			} elsif ($delink_lvl == 3) {
				# delink from a homenet netsplit
				$part{nojlink} = 1;
			}

			warn "c$$chan/n$$nick:no HN", next unless $nick->homenet;
			if ($nick->homenet eq $net) {
				$nick->rejoin($split, $chan);
				$part{dst} = $chan,
			} else {
				$part{dst} = $split;
			}
			push @parts, \%part;
		}
		&Janus::insert_full(@parts);
	}, DELINK => cleanup => sub {
		my $act = shift;
		del_remoteonly($act->{dst});
		del_remoteonly($act->{split}) if $act->{split};
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my @clean;
		for my $chan ($net->all_chans()) {
			warn "Channel not on network!" unless $chan->is_on($net);
			push @clean, +{
				type => 'DELINK',
				dst => $chan,
				net => $net,
				netsplit_quit => 1,
				except => $net,
				nojlink => 1,
			};
		}
		&Janus::insert_full(@clean);
	}, NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		&Persist::poison($_) for $net->all_chans();
	},
);

1 ]) or die $@;

=back

=cut

1;
