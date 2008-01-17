# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Janus;
use strict;
use warnings;
use Carp 'cluck';

# set only on released versions
our $RELEASE;

our($VERSION) = '$Rev$' =~ /(\d+)/;

=head1 Janus

Primary event multiplexer and module loader/unloader

=cut

# PUBLIC VARS
our $name;       # Name of this server
our $server;     # Message target/source: this server
our $global;     # Message target: all servers
our $time;       # Current server timestamp, used to avoid extra calls to time()
$time ||= time;

our %nets;       # by network tag
our %ijnets;     # by name (ij tag)
our %gnets;      # by guid
our %gnicks;     # by guid
our %gchans;     # by all possible keynames

=head2 Module loading

=over

=item Janus::load($module, @args)

Loads a module from a file, allowing it to register hooks as it loads and
registering it for unloading

=item Janus::unload($module)

Remove hooks and commands for a module. This is called automatically when your module
is unladed or reloaded

=item Janus::reload($module, @args)

Same as calling unload and load sequentially

=cut

# module => state (0 = unloaded, 1 = loading, 2 = loaded)
our %modules;
$modules{Janus} = 1;

our %hooks;
our %commands;
our %states;
our %rel_csum;

sub _hook; # forward since it's used in module load/unload

sub reload {
	my $module = $_[0];

	&Janus::unload if $modules{$module};
	&Janus::load;
}

sub load {
	my $module = shift;
	return 1 if $modules{$module};

	_hook(module => PRELOAD => $module);

	$modules{$module} = 1;

	my $fn = $module.'.pm';
	$fn =~ s#::#/#g;
	if (-f $fn && do $fn) {
		$modules{$module} = 2;
		_hook(module => LOAD => $module);
		2;
	} else {
		warn "Cannot load module $module: $! $@";
		$modules{$module} = 0;
	}
}

sub unload {
	my $module = $_[0];

	_hook(module => UNLOAD => $module);
	for my $t (keys %hooks) {
		for my $l (keys %{$hooks{$t}}) {
			delete $hooks{$t}{$l}{$module};
		}
	}
	for my $cmd (keys %commands) {
		warn "Command $cmd lacks class" unless $commands{$cmd}{class};
		next unless $commands{$cmd}{class} eq $module;
		delete $commands{$cmd};
	}

	delete $states{$module};
	$modules{$module} = 0;
}

sub Janus::INC {
	my($self, $name) = @_;
	open my $rv, '<', $name or return undef;
	my $module = $name;
	$module =~ s/.pm$//;
	$module =~ s#/#::#g;
	_hook(module => READ => $module, $rv);
	$modules{$module} = 1;
	&Janus::schedule({ code => sub {
		$modules{$module} = 2;
	}});
	$rv;
}

=back

=cut

our $last_check;
$last_check ||= time; # not assigned so that reloads don't skip seconds

our @qstack;
our %tqueue;

=head2 Action Hooks

The given coderef will be called with a single argument, the action hashref

Hooks, in order of execution:
  parse - possible reparse point (/msg janus *) - only for local origin
  jparse - possible reparse point - only for interjanus origin

  validate - make sure arguments are the proper type etc, to avoid crashes
    type for the validate hook is 'ALL' rather than the given type

  check - reject unauthorized and/or impossible commands
  act - Main state processing
  send (not a hook) - event is sent to local and remote networks
  cleanup - Reference deletion

validate, parse, jparse, and check hooks should return one of the tribool values:
  undef if the action was not modified
  0 if the action was modified (to detect duplicate hooks)
  1 if the action was rejected (should be dropped)

act and cleanup hooks ignore the return values. The action
hashref itself should NEVER be modified in these hooks

=over

=item Janus::hook_add([type, level, coderef]+)

Add hooks for a module. Should be called from module init

=cut

sub hook_add {
	my $module = caller;
	cluck "hook_add called outside module load" unless $modules{$module} == 1;
	while (@_) {
		my ($type, $level, $sub) = (shift, shift, shift);
		warn unless $sub;
		$hooks{$type}{$level}{$module} = $sub;
	}
}

=item Janus::command_add($cmdhash+)

Add commands (/msg janus <command> <cmdargs>). Should be called from module init

Command hashref contains:
	cmd - command name
	code - will be executed with two arguments: ($nick, $cmdargs)
	help - help text
	details - arrayref of detailed help text, one line per elt
	acl - undef/0 for all, 1 for oper-only, 2+ to be defined later

=cut

sub command_add {
	my $class = caller || 'Janus';
	cluck "command_add called outside module load" unless $modules{$class} == 1;
	for my $h (@_) {
		my $cmd = $h->{cmd};
		if (exists $commands{$cmd}) {
			my $c = $commands{$cmd}{class};
			warn "Overriding command '$cmd' from class '$c' with one from class '$class'";
		}
		$h->{class} = $class;
		$commands{$cmd} = $h;
	}
}

sub save_vars {
	my $class = caller || 'Janus';
	cluck "command_add called outside module load" unless $modules{$class} == 1;
	$states{$class} = { @_ };
}

=back

=cut

sub _hook {
	my($type, $lvl, @args) = @_;
	local $_;
	my $hook = $hooks{$type}{$lvl};
	return unless $hook;
	
	my @hookmods = sort keys %$hook; # working around a suspected bug in perl here
	for my $mod (@hookmods) {
#		print "EV: ", %$hook,"\n";
		eval {
#			print "EV_HOOK $type $lvl $mod\n";
			$hook->{$mod}->(@args);
			1;
		} or do {
			&Janus::err_jmsg(undef, "Unchecked exception in $lvl hook of $type, from module $mod: $@");
		};
	}
}

sub _mod_hook {
	my($type, $lvl, @args) = @_;
	local $_;
	my $hook = $hooks{$type}{$lvl};
	return undef unless $hook;

	my $rv = undef;
	for my $mod (sort keys %$hook) {
		eval {
#			print "MOD_HOOK $type $lvl $mod\n";
			my $r = $hook->{$mod}->(@args);
			$rv = $r if defined $r;
			1;
		} or do {
			&Janus::err_jmsg(undef, "Unchecked exception in $lvl hook of $type, from module $mod: $@");
		};
	}
	$rv;
}

sub _send {
	my $act = $_[0];
	&EventDump::debug_send($act);
	my @to;
	if (exists $act->{sendto}) {
		if ('ARRAY' eq ref $act->{sendto}) {
			@to = @{$act->{sendto}};
		} else {
			@to = $act->{sendto};
		}
	} elsif (!ref $act->{dst}) {
		# this must be an internal command, otherwise we have already complained in Actions
		return;
	} elsif ($act->{dst}->isa('Network')) {
		@to = $act->{dst};
	} else {
		@to = $act->{dst}->sendto($act);
	}
	my(%real, %jlink);
		# hash to remove duplicates
	for my $net (@to) {
		next unless $net;
		if ($net->isa('Janus')) {
			$_->jlink() or $real{$_} = $_ for values %nets;
			if ($$net == 2) {
				$jlink{$_} = $_ for values %ijnets;
			}
		} else {
			my $ij = $net->jlink();
			if (defined $ij) {
				$jlink{$ij} = $ij;
			} else {
				$real{$net} = $net;
			}
		}
	}
#	print "DBG: Sending to ".join(' ',keys %jlink, keys %real)."\n";
	if ($act->{except} && !($act->{dst} && $act->{dst} eq $act->{except})) {
		my $e = $act->{except};
		delete $real{$e};
		delete $jlink{$e};
	}
	unless ($act->{nojlink}) {
		for my $ij (values %jlink) {
			$ij->ij_send($act);
		}
	}
	for my $net (values %real) {
		$net->send($act);
	}
}

sub _runq {
	my $q = shift;
	for my $act (@$q) {
		unshift @qstack, [];
		_run($act);
		_runq(shift @qstack);
	}
}

sub _run {
	my $act = $_[0];
	if (_mod_hook('ALL', validate => $act)) {
		my $err = $act->{ERR} || 'unknown error';
		$err =~ s/\n//;
		print "Validate hook [$err] on";
		eval {
			&EventDump::debug_send($act);
			1;
		} or print "[ERR2: $@]\n";
		return;
	}
	if (_mod_hook($act->{type}, check => $act)) {
		print "Check hook stole";
		&EventDump::debug_send($act);
		return;
	}
	_hook($act->{type}, act => $act);
	_send($act);
	_hook($act->{type}, cleanup => $act);
}

=head2 Command generation

=over

=item Janus::insert_partial($action,...)

Run the given actions right now, but run any generated actions later
(use insert_full unless you need this behaviour)

=cut

sub insert_partial {
	for my $act (@_) {
		_run($act);
	}
}

=item Janus::insert_full($action,...)

Fully run the given actions (including generated ones) before returning

=cut

sub insert_full {
	for my $act (@_) {
		unshift @qstack, [];
		_run($act);
		_runq(shift @qstack);
	}
}

=item Janus::append($action,...)

Run the given actions after this one is done executing

=cut

sub append {
	push @{$qstack[0]}, @_;
}

=item Janus::jmsg($dst, $msg,...)

Send the given message(s), sourced from the janus interface,
to the given destination

=cut

sub jmsg {
	my $dst = shift;
	return unless $dst && ref $dst;
	my $type =
		$dst->isa('Nick') ? 'NOTICE' :
		$dst->isa('Channel') ? 'PRIVMSG' : '';
	local $_;
	&Janus::append(map +{
		type => 'MSG',
		src => $Interface::janus,
		dst => $dst,
		msgtype => $type,
		msg => $_,
	}, @_) if $type;
}

=item Janus::err_jmsg($dst, $msg,...)

Send error messages to the given destination and to standard error

=cut

sub err_jmsg {
	my $dst = shift;
	for my $v (@_) {
		local $_ = $v; # don't use $v directly as it's read-only
		s/\n/ /g;
		print STDERR "$_\n";
		if ($dst) {
			&Janus::append(+{
				type => 'MSG',
				src => $Interface::janus,
				dst => $dst,
				msgtype => ($dst->isa('Channel') ? 'PRIVMSG' : 'NOTICE'), # channel notice == annoying
				msg => $_,
			}) if $Interface::janus;
		} else {
			&Janus::insert_full({
				type => 'CHATOPS',
				src => $Interface::janus,
				sendto => [ values %nets ],
				msg => $_,
			}) if $Interface::janus;
		}
	}
}

=item Janus::schedule(TimeEvent,...)

schedule the given events for later execution

specify {time} as the time to execute

specify {repeat} to repeat the action every N seconds (the action should remove this when it is done)

specify {delay} to run the event once, N seconds from now

{code} is the subref, which is passed the event as its single argument

All other fields are available for use in passing additional arguments to the sub

=cut

sub schedule {
	for my $event (@_) {
		my $t = $time;
		$t = $event->{time} if $event->{time} && $event->{time} > $t;
		$t += $event->{repeat} if $event->{repeat};
		$t += $event->{delay} if $event->{delay};
		push @{$tqueue{$t}}, $event;
	}
}

sub in_socket {
	my($src,$line) = @_;
	return unless $src;
	eval {
		my @act = $src->parse($line);
		my $parse_hook = $src->isa('Network');
		for my $act (@act) {
			$act->{except} = $src unless exists $act->{except};
			unshift @qstack, [];
			unless (_mod_hook($act->{type}, ($parse_hook ? 'parse' : 'jparse'), $act)) {
				_run($act);
			}
			_runq(shift @qstack);
		}
		1;
	} or do {
		print "$line\n";
		&Janus::err_jmsg(undef, "Unchecked exception in parsing: $@");
	};
}

sub in_command {
	my($cmd, $nick, $text) = @_;
	$cmd = 'unk' unless exists $commands{$cmd};
	my $csub = exists $commands{$cmd}{code} ? $commands{$cmd}{code} : $commands{unk}{code};
	my $acl = $commands{$cmd}{acl} || 0;
	if ($acl == 1 && !$nick->has_mode('oper')) {
		&Janus::jmsg($nick, "You must be an IRC operator to use this command");
		return;
	}
	unshift @qstack, [];
	eval {
		$csub->($nick, $text);
		1;
	} or do {
		print "Unchecked exception: CMD=$cmd $text N=$$nick ERR=$@\n";
		&Janus::err_jmsg(undef, "Unchecked exception in janus command '$cmd': $@");
	};
	_runq(shift @qstack);
}

sub timer {
	$time = time;
	return if $time == $last_check;
	my @q;
	for ($last_check .. $time) {
		# yes it will hit some times twice... that is needed if events with delay=0 are
		# added to the queue in the same second, but after the queue has already run
		push @q, @{delete $tqueue{$_}} if exists $tqueue{$_};
	}
	$last_check = $time;
	for my $event (@q) {
		unshift @qstack, [];
		$event->{code}->($event);
		_runq(shift @qstack);
		if ($event->{repeat}) {
			my $t = $time + $event->{repeat};
			push @{$tqueue{$t}}, $event;
		}
	}
}

sub delink {
	my($net,$msg) = @_;
	return unless $net;
	if ($net->isa('Pending')) {
		my $id = $net->id();
		delete $nets{$id};
		&Connection::reassign($net, undef);
	} elsif ($net->isa('Server::InterJanus')) {
		&Janus::insert_full(+{
			type => 'JNETSPLIT',
			net => $net,
			msg => $msg,
		});
	} else {
		&Janus::insert_full(+{
			type => 'NETSPLIT',
			net => $net,
			msg => $msg,
		});
	}
}

=back

=cut

if ($RELEASE) {
	open my $rcs, ".rel-$RELEASE" or warn "Cannot open release checksum file!";
	while (<$rcs>) {
		my($s,$f) = /(\S+)\s+(.*)/ or warn "bad line: $_";
		$rel_csum{$f} = $s;
	}
	close $rcs;
}

&Janus::hook_add(
	NETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->name();
		$gnets{$net->gid()} = $net;
		$nets{$id} = $net;
	}, NETSPLIT => jparse => sub {
		my $act = shift;
		delete $act->{netsplit_quit};
		undef;
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->name();
		delete $gnets{$net->gid()};
		delete $nets{$id};
	}, JNETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->id();
		$ijnets{$id} = $net;
	}, JNETSPLIT => check => sub {
		my $act = shift;
		my $net = $act->{net};
		my $eq = $ijnets{$net->id()};
		return 1 if $eq && $eq ne $net;
		undef;
	}, JNETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		delete $ijnets{$net->id()};
		my @allnets = values %nets;
		for my $snet (@allnets) {
			next unless $snet->jlink() && $net eq $snet->jlink();
			&Janus::insert_full(+{
				type => 'NETSPLIT',
				net => $snet,
				msg => $act->{msg},
				netsplit_quit => 1,
			});
		}
	}, module => READ => sub {
		$_[0] =~ /([0-9A-Za-z_:]+)/;
		my $mod = $1;
		my $fn = $mod.'.pm';
		$fn =~ s#::#/#g;
		return unless -f $fn;
		my $ver = '?';
		no warnings 'exec';
		my $csum = '';
		my $sha = `sha1sum $fn 2>/dev/null`;
		if ($sha && $sha =~ /^(.{8})(.{32})/) {
			$ver = 'x'.$1;
			$csum = $1.$2;
			no strict 'refs';
			no warnings 'once';
			${$mod.'::SHA_UID'} = $1;
		} else {
			$sha = `sha1 $fn 2>/dev/null`;
			if ($sha =~ / = (.{8})(.{32})/) {
				$ver = 'x'.$1;
				$csum = $1.$2;
				no strict 'refs';
				no warnings 'once';
				${$mod.'::SHA_UID'} = $1;
			} else {
				print "Cannot checksum module - check that you have sha1sum installed\n";
			}
		}
		my $git = `git rev-parse --verify HEAD 2>/dev/null`;
		if ($git) {
			unless (`git diff-index HEAD $fn`) {
				# this file is not modified from the current head
				`git rev-parse HEAD` =~ /^(.{8})/;
				$ver = 'g'.$1;
				# ok, we have the ugly name... now look for a tag
				`git name-rev --tags --name-only HEAD` =~ /^(.*?)(?:^0)?$/;
				my $tag = $1;
				if ($tag ne 'undefined' && $tag !~ /~/) {
					# we are actually on this tag
					$ver = 't'.$tag;
				}
			}
		}
		my $svn = `svn info $fn 2>/dev/null`;
		if ($svn) {
			unless (`svn st $fn`) {
				if ($svn =~ /Revision: (\d+)/) {
					$ver = 'r'.$1;
				} else {
					warn "Cannot parse `svn info` output for $mod ($fn)";
				}
			}
		}
		if ($RELEASE && $rel_csum{$fn}) {
			if ($rel_csum{$fn} eq $csum) {
				$ver = $RELEASE;
			}
		}
		do {
			no strict 'refs';
			no warnings 'once';
			${$mod.'::VERSION_NAME'} = $ver;
		};
	},
);

&Janus::command_add({
	cmd => 'help',
	help => 'The text you are reading now',
	code => sub {
		my($nick,$arg) = @_;
		if ($arg && $arg =~ /(\S+)/ && exists $commands{lc $1}) {
			$arg = lc $1;
			my $det = $commands{$arg}{details};
			if (ref $det) {
				&Janus::jmsg($nick, @$det);
			} elsif ($commands{$arg}{help}) {
				&Janus::jmsg($nick, "$arg - $commands{$arg}{help}");
			} else {
				&Janus::jmsg($nick, 'No help for that command');
			}
		} else {
			my @cmds;
			my $all = $nick->has_mode('oper') || ($arg && lc $arg eq 'all');
			my $synlen = 0;
			for my $cmd (sort keys %commands) {
				my $h = $commands{$cmd}{help};
				next unless $h;
				next if $commands{$cmd}{acl} && !$all;
				push @cmds, $cmd;
				$synlen = length $cmd if length $cmd > $synlen;
			}
			&Janus::jmsg($nick, 'Available commands: ');
			&Janus::jmsg($nick, map {
				sprintf " \002\%-${synlen}s\002  \%s", uc $_, $commands{$_}{help};
			} @cmds);
		}
	}
}, {
	cmd => 'unk',
	code => sub {
		&Janus::jmsg($_[0], 'Unknown command. Use "help" to see available commands');
	},
});

_hook(module => READ => 'Janus');

$modules{Janus} = 2;

unless ($server) {
	my $one = 1;
	my $two = 2;
	$server = bless \$one;
	$global = bless \$two;
	unshift @INC, $server;
}

sub gid {
	my $inst = shift;
	$$inst == 1 ? $name : '*';
}

# we load these modules down here because their loading uses
# some of the subs defined above
eval q[
	use Connection;
	use EventDump;
	1;
] or die $@;

1;
