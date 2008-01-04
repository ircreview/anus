# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Save;
use strict;
use warnings;
use Data::Dumper;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'save',
	help => 'Save janus state to filesystem',
	acl => 1,
	code => sub {
		my($nick,$args) = @_;
		my $out = $Conffile::netconf{set}{save};
		my(@vars,@refs);
		keys %Janus::states;
		while (my($class,$vars) = each %Janus::states) {
			keys %$vars;
			while (my($var,$val) = each %$vars) {
				push @vars, $val;
				push @refs, '*'.$class.'::'.$var;
			}
		}
		if (open my $f, '>', $out) {
			print $f Data::Dumper->Dump(\@vars, \@refs);
			close $f;
			&Janus::jmsg($nick, 'Saved');
		} else {
			&Janus::jmsg($nick, "Could not save: $!");
		}
	}
});

1;