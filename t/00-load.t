#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 7;

BEGIN {
    use_ok('App::MCP::CLI')
        || print "Bail out!\n";
    use_ok('App::MCP::CLI::Config')
        || print "Bail out!\n";
    use_ok('App::MCP::CLI::Command::list')
        || print "Bail out!\n";
    use_ok('App::MCP::CLI::Command::call')
        || print "Bail out!\n";
    use_ok('App::MCP::CLI::Command::interactive')
        || print "Bail out!\n";
    use_ok('App::MCP::CLI::Command::servers')
        || print "Bail out!\n";
    use_ok('App::MCP::CLI::Command::version')
        || print "Bail out!\n";
}

diag( "Testing App::MCP::CLI $App::MCP::CLI::VERSION, Perl $], $^X" );
