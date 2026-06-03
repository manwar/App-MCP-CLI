package App::MCP::CLI::Command::version;

use strict;
use warnings;
use App::MCP::CLI -command;

sub description { 'Print the mcpcli version' }
sub abstract    { 'Print the mcpcli version' }
sub opt_spec    { () }

sub execute {
    my ($self, $opt, $args) = @_;
    print "mcpcli version $App::MCP::CLI::VERSION\n";
}

1;
