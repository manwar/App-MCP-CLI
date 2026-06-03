package App::MCP::CLI::Command::call;

use strict;
use warnings;
use version;

our $VERSION   = qv('v0.0.1');
our $AUTHORITY = 'cpan:MANWAR';

use App::MCP::CLI -command;

use IPC::Open2;
use JSON::MaybeXS;
use App::MCP::CLI::Config qw(load_config resolve_server_cmd);

=encoding utf8

=head1 NAME

App::MCP::CLI::Command::call - Invoke a specific tool on an MCP server

=head1 VERSION

This module is distributed as part of L<App::MCP::CLI> v0.0.1.

=head1 SYNOPSIS

    # Invoke a tool with inline key=value arguments
    mcpcli call greet name=Alice

    # Invoke a tool and be prompted for each required argument
    mcpcli call weather

    # Override the server command for a single invocation
    MCP_SERVER="node server.js" mcpcli call add a=3 b=4

=head1 DESCRIPTION

C<App::MCP::CLI::Command::call> implements the C<call> sub-command of the
C<mcpcli> application.  It connects to an MCP server via a bidirectional
stdio pipe, performs the JSON-RPC 2.0 C<initialize> handshake, and then
dispatches a C<tools/call> request.

=head2 Argument handling

Arguments are supplied on the command line as C<key=value> pairs after the
tool name:

    mcpcli call mytool param1=hello param2=42

Numeric-looking values (integers and decimals) are cast to JSON numbers
automatically.  All other values are treated as JSON strings.

When no arguments are given, the command enters an B<interactive prompt mode>:
it first calls C<tools/list> to retrieve the tool's input schema, then
presents each property individually in the terminal, labelling required fields
in red and optional fields in the default colour.  Entering an empty value for
a required field causes the command to abort with an error message.

=head2 Output

On success the text blocks inside the C<result.content> array are printed to
standard output.  On failure the C<error.message> field from the JSON-RPC
response is printed prefixed with C<Error:>.

=head1 USAGE

    mcpcli call <tool_name> [key=value ...]

=head1 OPTIONS

This sub-command does not define additional flags beyond those inherited from
L<App::Cmd>.  Use C<mcpcli help call> for the built-in help text.

=head1 INTERNAL METHODS

=head2 opt_spec

Defines the command-line option specification passed to L<Getopt::Long::Descriptive>
via L<App::Cmd>.

=cut

sub opt_spec {
    return (
        [ 'server|s=s', 'server name from config'  ],
        [ 'config|c=s', 'path to config JSON file' ],
    );
}

=head2 description

Returns a one-line human-readable description of the command, used in the
top-level C<mcpcli help> listing.

=cut

sub description { 'Call/execute a specific tool on the server'  }

=head2 usage_desc

Returns the usage string shown by C<mcpcli help call>.

=cut

sub usage_desc  { '%c call <tool_name> [key=value key2=value2]' }

=head2 validate_args

Validates that at least one positional argument (the tool name) has been
supplied; calls C<usage_error> otherwise.

=cut

sub validate_args {
    my ($self, $opt, $args) = @_;

    $self->usage_error("You must specify a tool name to call.")
        if !@$args;
}

=head2 execute( $opt, $args )

Main entry point invoked by L<App::Cmd>.  Connects to the configured MCP
server, performs the protocol handshake, collects tool arguments (inline or
interactively), submits the C<tools/call> request, and prints the response.

=cut

sub execute {
    my ($self, $opt, $args) = @_;

    my $config_data = load_config($opt->config);
    my ($cmd)       = resolve_server_cmd($config_data, $opt->server);

    $App::MCP::CLI::Command::SERVER_CMD = $cmd;

    my $tool_name = shift @$args;

    my $json = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1);

    my ($out, $in);
    my $pid = open2($out, $in, @$App::MCP::CLI::Command::SERVER_CMD)
        or die "Server failed: $!";

    # Standard Protocol Handshake
    print $in $json->encode({
        id      => 1,
        jsonrpc => "2.0",
        method  => "initialize",
        params  => {
            protocolVersion => "2024-11-05",
            capabilities    => {},
            clientInfo      => { name => "mcp-cli-perl", version => "1.0" }
        }
    }) . "\n";

    my $discard = <$out>;

    my %tool_args;

    # Check if arguments were passed inline
    if (@$args) {
        foreach my $arg (@$args) {
            if ($arg =~ /^([^=]+)=(.*)$/) {
                $tool_args{$1} = $self->_clean_type($2);
            }
        }
    }
    # INTERACTIVE MODE: If no arguments given, discover requirements!
    else {
        print "[-] No arguments provided. Inspecting tool schema for '$tool_name'...\n";

        # Ask server for tool list to find this tool's input schema
        print $in $json->encode({
            id      => 2,
            jsonrpc => "2.0",
            method  => "tools/list"
        }) . "\n";

        my $list_res = $json->decode(scalar <$out>);
        my ($target_tool) = grep {
            $_->{name} eq $tool_name
        } @{ $list_res->{result}{tools} // [] };

        if (!$target_tool) {
            print "\n\e[1;31mError:\e[0m Tool '$tool_name' not found on server.\n\n";

            close($in);
            close($out);
            waitpid($pid, 0);
            return;
        }

        # Parse the JSON Schema properties
        my $properties  = $target_tool->{inputSchema}{properties} // {};
        my $required    = $target_tool->{inputSchema}{required}   // [];
        my %is_required = map { $_ => 1 } @$required;

        if (keys %$properties) {
            print "\nEntering interactive prompt for '$tool_name':\n";
            foreach my $key (sort keys %$properties) {
                my $prop = $properties->{$key};
                my $desc = $prop->{description} // 'No description';
                my $type = $prop->{type} // 'string';
                my $req_label = $is_required{$key}
                                ? "\e[1;31m(required)\e[0m"
                                : "(optional)";

                # Dynamic terminal prompt
                print "=> $key $req_label [$type - $desc]: ";

                my $input = <STDIN>;
                defined($input) ? chomp($input) : ($input = '');

                if ($input eq '' && $is_required{$key}) {
                    print "\e[1;31mError: $key is required!\e[0m\n";
                    close($in);
                    close($out);
                    waitpid($pid, 0);
                    return;
                }

                if ($input ne '') {
                    $tool_args{$key} = $self->_clean_type($input);
                }
            }
            print "\n";
        }
    }

    # Execute the Tool
    print "Calling tool '$tool_name'...\n";
    my $call_payload = {
        id      => 3,
        jsonrpc => "2.0",
        method  => "tools/call",
        params  => {
            name      => $tool_name,
            arguments => \%tool_args
        }
    };

    print $in $json->encode($call_payload) . "\n";
    my $res = $json->decode(scalar <$out>);

    print "\n";
    if ($res->{error}) {
        print "\e[1;31mError:\e[0m " . $res->{error}{message} . "\n";
    } else {
        print "\e[1;32mResponse:\e[0m\n";
        my $content = $res->{result}{content} // [];
        foreach my $block (@$content) {
            if ($block->{type} eq 'text') {
                print $block->{text} . "\n";
            }
        }
    }
    print "\n";

    close($in); close($out); waitpid($pid, 0);
}

=head2 _clean_type( $value )

Helper that coerces a string value to a Perl number when it looks like an
integer or decimal, so that JSON serialization produces the correct type.
Returns the value unchanged for non-numeric strings.

=cut

sub _clean_type {
    my ($self, $val) = @_;

    if ($val =~ /^-?\d+(\.\d+)?$/) {
        return 0 + $val;
    }
    return $val;
}

=head1 SEE ALSO

=over 4

=item * L<App::MCP::CLI>

=item * L<App::MCP::CLI::Command::list>

=item * L<App::MCP::CLI::Command::interactive>

=back

=head1 AUTHOR

Mohammad Sajid Anwar, C<< <mohammad.anwar at yahoo.com> >>

=head1 REPOSITORY

L<https://github.com/manwar/App-MCP-CLI>

=head1 BUGS

Please report any bugs or feature requests through the web interface at L<https://github.com/manwar/App-MCP-CLI/issues>.
I will  be notified and then you'll automatically be notified of progress on your
bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc App::MCP::CLI

You can also look for information at:

=over 4

=item * BUG Report

L<https://github.com/manwar/App-MCP-CLI/issues>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/App-MCP-CLI>

=item * Search MetaCPAN

L<http://metacpan.org/dist/App-MCP-CLI>

=back

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2026 Mohammad Sajid Anwar.

This program  is  free software; you can redistribute it and / or modify it under
the  terms  of the the Artistic License (2.0). You may obtain  a copy of the full
license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any  use,  modification, and distribution of the Standard or Modified Versions is
governed by this Artistic License.By using, modifying or distributing the Package,
you accept this license. Do not use, modify, or distribute the Package, if you do
not accept this license.

If your Modified Version has been derived from a Modified Version made by someone
other than you,you are nevertheless required to ensure that your Modified Version
 complies with the requirements of this license.

This  license  does  not grant you the right to use any trademark,  service mark,
tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge patent license
to make,  have made, use,  offer to sell, sell, import and otherwise transfer the
Package with respect to any patent claims licensable by the Copyright Holder that
are  necessarily  infringed  by  the  Package. If you institute patent litigation
(including  a  cross-claim  or  counterclaim) against any party alleging that the
Package constitutes direct or contributory patent infringement,then this Artistic
License to you shall terminate on the date that such litigation is filed.

Disclaimer  of  Warranty:  THE  PACKAGE  IS  PROVIDED BY THE COPYRIGHT HOLDER AND
CONTRIBUTORS  "AS IS'  AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES. THE IMPLIED
WARRANTIES    OF   MERCHANTABILITY,   FITNESS   FOR   A   PARTICULAR  PURPOSE, OR
NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY YOUR LOCAL LAW. UNLESS
REQUIRED BY LAW, NO COPYRIGHT HOLDER OR CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL,  OR CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE
OF THE PACKAGE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

1; # End of App::MCP::CLI::Command::call
