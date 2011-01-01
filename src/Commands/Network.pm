# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Network;
use strict;
use warnings;
use integer;

Event::command_add({
	cmd => 'rehash',
	help => 'Reload the config and attempt to reconnect to split servers',
	section => 'Admin',
	acl => 'rehash',
	code => sub {
		my($src,$dst) = @_;
		Log::audit('Rehash by '.$src->netnick);
		Event::insert_full(+{
			type => 'REHASH',
		});
		Janus::jmsg($dst, 'Rehashed');
	},
}, {
	cmd => 'die',
	help => "Kill the anus server; does \002NOT\002 restart it",
	section => 'Admin',
	acl => 'die',
	code => sub {
		my($src,$dst,$pass) = @_;
		return Janus::jmsg($dst, "Specify the argument '".$RemoteJanus::self->id."' to confirm")
			unless $pass && $pass eq $RemoteJanus::self->id;
		Conffile::save();
		Log::audit('DIE by '.$src->netnick);
		for my $net (values %Janus::nets) {
			next if $net->jlink();
			Event::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Killed',
			});
		}
		print "Will exit in 1 second\n";
		Event::schedule(+{
			delay => 1,
			code => sub { exit 0 },
		});
	},
}, {
	cmd => 'restart',
	help => "Restart the anus server",
	section => 'Admin',
	acl => 'restart',
	code => sub {
		my($src,$dst,$pass) = @_;
		return Janus::jmsg($dst, "Specify the argument '".$RemoteJanus::self->id."' to confirm")
			unless $pass && $pass eq $RemoteJanus::self->id;
		Conffile::save();
		Log::audit('RESTART by '.$src->netnick);
		for my $net (values %Janus::nets) {
			next if $net->jlink() || $net == $Interface::network;
			Event::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Restarting...',
			});
		}
		# sechedule the actual exec at a later time to try to send the restart netsplit message around
		Event::schedule(+{
			delay => 1,
			code => sub {
				exec 'perl', 'janus.pl', $Conffile::conffile;
			},
		});
	},
}, {
	cmd => 'autoconnect',
	help => 'Enable or disable autoconnect on a network',
	section => 'Network',
	syntax => '<network> <backoff>',
	details => [
		"Enables or disables the automatic reconnection that janus makes to a network.",
		'A rehash will reread the value for the network from the anus configuration',
		'Specify backoff=0 to disable autoconnect',
		'Specify backoff=1 to autoconnect quickly',
		'Higher backoff values will increase the time between connection attempts',
		'If backoff is not specified, displays the current state',
	],
	acl => 'autoconnect',
	api => '=src =replyto $ ?#',
	code => sub {
		my($src, $dst, $id, $onoff) = @_;
		my $nconf = $Conffile::netconf{$id} or do {
			Janus::jmsg($dst, 'Cannot find network');
			return;
		};
		if (defined $onoff) {
			Log::audit("Autoconnect on $id ".($onoff ? 'enabled' : 'disabled').' by '.$src->netnick);
			$nconf->{autoconnect} = $onoff ? 1 : 0;
			$nconf->{backoff} = 0;
			$nconf->{fb_id} = $onoff;
			if ($onoff) {
				Conffile::connect_net($id);
			}
			Janus::jmsg($dst, 'Done');
		} else {
			Janus::jmsg($dst, 'Autoconnect is '.($nconf->{autoconnect} ? 'on' : 'off').
				" for $id (backoff=$nconf->{backoff}/$nconf->{fb_id})");
		}
	},
}, {
	cmd => 'netsplit',
	help => 'Split a network',
	section => 'Network',
	syntax => '<network>',
	acl => 'netsplit',
	api => '=src =replyto $',
	code => sub {
		my($src,$dst,$net) = @_;
		$net = $Janus::nets{lc $net} || $Janus::ijnets{lc $net} || $Janus::pending{lc $net};
		return unless $net;
		if ($net->isa('LocalNetwork')) {
			Log::audit("Network ".$net->name.' split by '.$src->netnick);
			Event::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Forced split by '.$src->netnick
			});
		} elsif ($net->isa('Server::InterJanus')) {
			Log::audit("Network ".$net->id.' split by '.$src->netnick);
			Event::append(+{
				type => 'JNETSPLIT',
				net => $net,
				msg => 'Forced split by '.$src->netnick
			});
		}
	},
});

1;
