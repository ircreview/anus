# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::List;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'list',
	help => 'List channels available for linking',
	details => [
		"Syntax: \002LIST\002 network|*",
	],
	code => sub {
		my($nick,$args) = @_;

		if ($args && $args =~ /^\S+$/ && $Janus::nets{$args}) {
			my $avail = $Link::request{$args} || {};
			my @out;
			for my $chan (sort keys %$avail) {
				next unless $avail->{$chan}{mode};
				# TODO filter out rejected channels
				if ($nick->has_mode('oper')) {
					push @out, $chan.' '.$avail->{$chan}{mask}.' '.gmtime($avail->{$chan}{time});
				} else {
					push @out, $chan;
				}
			}
			if (@out) {
				&Janus::jmsg($nick, @out);
			} else {
				&Janus::jmsg($nick, 'No shared channels for that network');
			}
		} elsif ($args && $args eq '*') {
			for my $net (sort keys %Janus::nets) {
				my $avail = $Link::request{$net} or next;
				my @out;
				for my $chan (sort keys %$avail) {
					next unless $avail->{$chan}{mode};
					# TODO filter out rejected channels
					if ($nick->has_mode('oper')) {
						push @out, $net.$chan.' '.$avail->{$chan}{mask}.' '.gmtime($avail->{$chan}{time});
					} else {
						push @out, $net.$chan;
					}
				}
				&Janus::jmsg($nick, @out);
			}
		} else {
			&Janus::jmsg($nick, "Syntax: LIST network");
		}
	},
});

1;