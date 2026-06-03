package App::MCP::CLI::Command::interactive;

use strict;
use warnings;
use version;

our $VERSION   = qv('v0.0.1');
our $AUTHORITY = 'cpan:MANWAR';

use App::MCP::CLI -command;

use IPC::Open2;
use HTTP::Tiny;
use JSON::MaybeXS;
use App::MCP::CLI::Config qw(load_config resolve_server_cmd);

=encoding utf8

=head1 NAME

App::MCP::CLI::Command::interactive - Agent REPL that routes natural-language queries to MCP tools via a local LLM

=head1 VERSION

This module is distributed as part of L<App::MCP::CLI> v0.0.1.

=head1 SYNOPSIS

    # Start an interactive session against a named server in your config file
    mcpcli interactive --server myserver

    # Alias: the 'chat' sub-command is identical
    mcpcli chat --server myserver

    # Use a local Perl script as the server with a custom model
    mcpcli interactive --server ./server.pl --model llama3

    # Point at an SSE server by URL
    mcpcli interactive --server http://localhost:8080/sse

    # Override every option explicitly
    mcpcli interactive \
        --server   myserver       \
        --provider ollama         \
        --model    qwen2.5:1.5b   \
        --config   /etc/mcp/config.json

=head1 DESCRIPTION

C<App::MCP::CLI::Command::interactive> implements the C<interactive> (alias
C<chat>) sub-command of the C<mcpcli> application.  It starts a Read-Eval-Print
Loop (REPL) that:

=over 4

=item 1.

Connects to the MCP server specified by C<--server> (either as a stdio
subprocess or via HTTP/SSE).

=item 2.

Retrieves the full tool catalogue from the server with C<tools/list>.

=item 3.

Enters a prompt loop where each user message is forwarded to a local LLM
(currently only B<Ollama> is supported) together with the tool catalogue
and a structured JSON dispatch schema.

=item 4.

If the LLM decides to invoke a tool (C<action: "call_tool">), the command
optionally asks the user for confirmation before executing the C<tools/call>
request and summarising the raw result via a second LLM call.

=item 5.

If no tool is needed (C<action: "reply">), the LLM's plain-text answer is
printed directly.

=back

Type C<exit> or C<quit> (case-insensitive) at the prompt to end the session.

=head1 TRANSPORT MODES

=head2 stdio (default)

The server is launched as a child process via C<IPC::Open2>.  Messages are
exchanged as newline-delimited JSON on its stdin/stdout.  This is the simplest
mode and works with any compliant MCP server script.

=head2 HTTP/SSE

When the resolved server endpoint begins with C<http://> or C<https://>, or
when the config entry contains a C<url> key or C<transport: sse>, the client
connects in SSE mode.  It first makes a C<GET> request to the SSE endpoint to
obtain the dynamic C<POST> URL broadcast by the C<endpoint> event, then sends
all subsequent JSON-RPC messages as C<POST> requests to that URL.

=head1 CONFIGURATION FILE

The command accepts a JSON configuration file (C<--config>) with the following
optional top-level keys:

=over 4

=item C<mcpServers> (object)

A map of server alias names to server descriptor objects.  Each descriptor may
contain:

=over 4

=item C<command> (string) — executable to launch (stdio mode).

=item C<args> (array of strings) — additional arguments for the executable.

=item C<env> (object) — environment variables to set before launching.

=item C<url> (string) — SSE endpoint URL (SSE mode).

=item C<transport> (string) — set to C<"sse"> to force SSE mode even when no
C<url> is given.

=back

=item C<confirmTools> (boolean, default true)

When true, the agent pauses before executing any tool call and asks the user
for explicit confirmation.  Set to C<false> to allow autonomous execution.

=back

The configuration file is searched in the following order when C<--config> is
not given:

=over 4

=item 1. C<./server_config.json> in the current directory.

=item 2. C<./mcp-config.json> in the current directory.

=item 3. C<$HOME/.config/mcp-cli/config.json>.

=back

Example configuration:

    {
      "confirmTools": true,
      "mcpServers": {
        "myserver": {
          "command": "node",
          "args": ["/opt/mcp/server.js"],
          "env": { "DEBUG": "1" }
        },
        "remote": {
          "url": "http://mcp.example.com/sse"
        }
      }
    }

=head1 OPTIONS

=over 4

=item C<--server|-s> I<name_or_path>

B<(Required)> The MCP server to connect to.  Can be:

=over 4

=item * A key in the C<mcpServers> section of the config file.

=item * A C<.pl> file path (launched with the current Perl interpreter).

=item * An C<http://> or C<https://> URL (SSE mode).

=item * A bare shell command string (split on whitespace).

=back

=item C<--provider|-p> I<name>  (default: C<ollama>)

The LLM provider to use for query routing and result summarisation.  Only
C<ollama> is currently supported.

=item C<--model|-m> I<name>  (default: C<qwen2.5:1.5b>)

The Ollama model tag to query.  Any model available on the local Ollama
instance (L<http://localhost:11434>) can be specified.

=item C<--config|-c> I<path>

Path to a JSON configuration file.  See L</CONFIGURATION FILE> above.

=back

=head1 INTERNAL METHODS

=cut

sub description { 'Start an interactive agent shell with an MCP server' }
sub abstract    { 'Start an interactive agent shell with an MCP server' }

=head2 command_names

Returns C<qw(interactive chat)> so that the sub-command can be invoked by
either name.

=cut

sub command_names {
    return qw(interactive chat);
}

=head2 opt_spec

Defines the command-line option specification passed to L<Getopt::Long::Descriptive>
via L<App::Cmd>.

=cut

sub opt_spec {
    return (
        [ 'server|s=s',
          'MCP server command, script path, or server name from config'
        ],
        [ 'provider|p=s',
          'LLM provider name (e.g., ollama)',
          { default => 'ollama' }
        ],
        [ 'model|m=s',
          'LLM model to query (e.g., qwen2.5:1.5b)',
          { default => 'qwen2.5:1.5b' }
        ],
        [ 'config|c=s',
          'Path to MCP configuration JSON file'
        ],
    );
}

=head2 execute( $opt, $args )

Main entry point.  Resolves the server, connects to it, retrieves tools,
and runs the agent REPL until the user types C<exit>/C<quit> or sends EOF.

=cut

sub execute {
    my ($self, $opt, $args) = @_;

    my $json = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1);

    my $config_data  = load_config($opt->config);
    my $server_input = $opt->server // $args->[0];

    if (!$server_input) {
        print STDERR "ERROR: You must specify an MCP server name or path.\n";
        print STDERR "Usage: ./mcp-cli.pl chat --server <server_name_or_file>\n";
        if ($config_data && $config_data->{mcpServers}) {
            print STDERR "Available configured servers: "
                . join(", ", sort keys %{ $config_data->{mcpServers} }) . "\n";
        }
        exit 1;
    }

    $self->{confirm_tools} = 1;
    if ($config_data && exists $config_data->{confirmTools}) {
        $self->{confirm_tools} = $config_data->{confirmTools} ? 1 : 0;
    }

    my ($cmd, $sse_url) = resolve_server_cmd($config_data, $server_input);
    my $is_sse = defined $sse_url ? 1 : 0;

    my ($out, $in, $pid);
    my ($ua_mcp, $mcp_post_url);

    if ($is_sse) {
        print "[-] Connecting to MCP Server via HTTP/SSE: $sse_url\n";
        $ua_mcp = HTTP::Tiny->new(timeout => 60);

        # Establish the SSE Handshake and grab the dynamic client posting
        # endpoint. According to the MCP Specification, the SSE server
        # broadcasts an 'endpoint' event.
        # HTTP::Tiny does not support streaming callbacks, so we fetch the
        # SSE response in full and parse the endpoint event from the body.
        my $res = $ua_mcp->get($sse_url, {
            headers => { 'Accept' => 'text/event-stream' }
        });

        if (!$res->{success}) {
            die "Error: Failed to connect to SSE endpoint ($res->{status}): $res->{reason}\n";
        }

        my $response_text = $res->{content} // '';
        if ($response_text =~ /event:\s*endpoint\s*\ndata:\s*([^\n]+)/s ||
            $response_text =~ /data:\s*([^\n]+)/s) {
            my $match = $1;
            $match =~ s/^\s+|\s+$//g;
            if ($match =~ /^https?:\/\//i) {
                $mcp_post_url = $match;
            } else {
                my ($proto) = $sse_url =~ /^(https?:\/\/[^\/]+)/i;
                $mcp_post_url = $proto . $match;
            }
        }

        if (!$mcp_post_url) {
            die "Error: Failed to obtain a valid HTTP POST client endpoint from SSE stream.\n";
        }
        print "[-] SSE Channel Established. Target Post Route: $mcp_post_url\n";

    } else {
        $App::MCP::CLI::Command::SERVER_CMD = $cmd;
        print "[-] Launching Local Pipe MCP Server: @$App::MCP::CLI::Command::SERVER_CMD\n";
        $pid = open2($out, $in, @$App::MCP::CLI::Command::SERVER_CMD)
            or die "Failed to boot server: $!";
    }

    my $send_mcp_request = sub {
        my ($payload) = @_;

        my $raw_payload = $json->encode($payload);
        if ($is_sse) {
            my $post_res = $ua_mcp->post(
                $mcp_post_url,
                {
                    headers => { 'content-type' => 'application/json' },
                    content => $raw_payload,
                }
            );

            if (!$post_res->{success}) {
                die "MCP HTTP Transport Exception ($post_res->{status}): $post_res->{reason}";
            }

            return $json->decode($post_res->{content} || '{}');
        }
        else {
            print $in $raw_payload . "\n";
            my $line = <$out>;
            return $json->decode(scalar $line);
        }
    };

    my $init_res = $send_mcp_request->({
        id      => 1,
        jsonrpc => "2.0",
        method  => "initialize",
        params  => {
            protocolVersion => "2024-11-05",
            capabilities    => {},
            clientInfo      => {
                name    => "mcp-interactive-client",
                version => "1.0"
            }
        }
    });

    my $list_res = $send_mcp_request->({
        id      => 2,
        jsonrpc => "2.0",
        method  => "tools/list"
    });

    my $tools = $list_res->{result}{tools} // [];

    print "[+] Connected to MCP Server. Found " . scalar(@$tools) . " tool(s).\n";
    print "[-] Connected to LLM provider '" . $opt->provider . "' using model '" . $opt->model . "'.\n";
    print "[-] Starting agent loop. Type 'exit' or 'quit' to end session.\n\n";

    $self->{provider} = $opt->provider;
    $self->{model}    = $opt->model;

    while (1) {
        print "\e[1;36mYou>\e[0m ";

        my $user_query = <STDIN>;
        last if !defined $user_query;
        chomp($user_query);
        last if $user_query =~ /^(exit|quit)$/i;
        next if $user_query eq '';

        print "Thinking...\n";

        my $decision = $self->_ask_llm($user_query, $tools);

        if ($decision && $decision->{action} eq 'call_tool') {
            my $tool_name = $decision->{tool};
            my $tool_args = $decision->{arguments};

            print " -> \e[1;33m[Agent decided to call tool '$tool_name' with args: " .
                  $json->encode($tool_args) .
                  "]\e[0m\n";

            my $proceed = 1;
            if ($self->{confirm_tools}) {
                print " -> \e[1;35m[Security] Allow execution of '$tool_name'? (y/N):\e[0m ";
                my $ans = <STDIN>;
                chomp($ans) if defined $ans;
                if (lc($ans // '') ne 'y') {
                    print "[-] Execution aborted by user request.\n\n";
                    $proceed = 0;
                }
            }

            if ($proceed) {
                # Execute the tool via our unified abstraction helper
                my $tool_res = $send_mcp_request->({
                    id      => 3,
                    jsonrpc => "2.0",
                    method  => "tools/call",
                    params  => {
                        name      => $tool_name,
                        arguments => $tool_args
                    }
                });

                my $content_blocks = $tool_res->{result}{content} // [];
                my $raw_result = join("\n", map { $_->{text} }
                                 grep {
                                     $_->{type} eq 'text'
                                 } @$content_blocks);

                my $final_reply = $self->_summarize_with_llm($user_query, $raw_result);
                print "\e[1;32mResponse:\e[0m $final_reply\n\n";
            }
        }
        elsif ($decision && $decision->{action} eq 'reply') {
            print "\e[1;32mResponse:\e[0m " . $decision->{answer} . "\n\n";
        }
        else {
            print "\e[1;31mResponse:\e[0m Failed to parse structural response from LLM.\n\n";
        }
    }

    if (!$is_sse) {
        close($in); close($out); waitpid($pid, 0);
    }

    print "[-] Session Closed.\n";
}

=head2 _ask_llm( $query, $tools )

Sends C<$query> together with the serialised C<$tools> array to the Ollama
C</api/generate> endpoint.  The system prompt instructs the model to respond
with a bare JSON object in one of two forms:

    { "action": "call_tool", "tool": "<name>", "arguments": { ... } }
    { "action": "reply",     "answer": "<text>" }

Returns the decoded hashref, or a synthetic C<reply> hashref on error.

=cut

sub _ask_llm {
    my ($self, $query, $tools) = @_;

    if (lc($self->{provider}) ne 'ollama') {
        return {
            action => 'reply',
            answer => "Error: Provider '" . $self->{provider} . "' is not supported. Please configure '--provider ollama'."
        };
    }

    my $ua   = HTTP::Tiny->new(timeout => 30);
    my $json = JSON::MaybeXS->new(utf8 => 1);

    my $system_prompt = "You are an AI assistant with access to these local tools:\n"
                      . $json->encode($tools) . "\n"
                      . "If the user request requires a tool, respond ONLY with a JSON object like: {\"action\":\"call_tool\",\"tool\":\"tool_name\",\"arguments\":{...}}\n"
                      . "If no tool is needed, respond with: {\"action\":\"reply\",\"answer\":\"your text answer here\"}\n"
                      . "Respond with valid raw JSON only, no markdown blocks.";

    my $res = $ua->post(
        'http://localhost:11434/api/generate',
        {
            headers => { 'content-type' => 'application/json' },
            content => $json->encode({
                model  => $self->{model},
                prompt => "$system_prompt\n\nUser Question: $query",
                stream => JSON::MaybeXS::false()
            })
        }
    );

    if ($res->{success}) {
        # Raw text body resides inside the 'content' key
        my $body = $json->decode($res->{content});
        my $raw_response = $body->{response};

        $raw_response =~ s/\`{3}(?:json)?//g;
        $raw_response =~ s/\`{3}//g;
        $raw_response =~ s/^\s+|\s+$//g;

        my $parsed = eval { $json->decode($raw_response) };
        if ($@) {
            return { action => 'reply', answer => $raw_response };
        }

        return $parsed;
    }

    return {
        action => 'reply',
        answer => "HTTP Error ($res->{status}): $res->{reason}"
    };
}

=head2 _summarize_with_llm( $query, $result )

Sends the original C<$query> and the raw tool C<$result> text to Ollama and
asks for a concise natural-language summary.  Returns the summary string, or
the raw C<$result> on failure.

=cut

sub _summarize_with_llm {
    my ($self, $query, $result) = @_;

    if (lc($self->{provider}) ne 'ollama') {
        return $result;
    }

    my $ua   = HTTP::Tiny->new(timeout => 30);
    my $json = JSON::MaybeXS->new(utf8 => 1);

    my $prompt = "The user asked: '$query'. The tool returned this raw result data:\n$result\n"
               . "Provide a brief, natural language response answering the user's question based on this data.";

    my $res = $ua->post(
        'http://localhost:11434/api/generate',
        {
            headers => { 'content-type' => 'application/json' },
            content => $json->encode({
                model  => $self->{model},
                prompt => $prompt,
                stream => JSON::MaybeXS::false()
            })
        }
    );

    if ($res->{success}) {
        my $body = eval { $json->decode($res->{content}) };
        return $body ? $body->{response} : $result;
    }

    return "HTTP Error ($res->{status}): $res->{reason}";
}

=head1 DEPENDENCIES

In addition to the core L<App::MCP::CLI> dependencies, this command requires:

=over 4

=item * L<HTTP::Tiny> — for Ollama API calls and SSE transport.

=back

A running L<Ollama|https://ollama.com> instance on C<http://localhost:11434>
is required for the LLM routing functionality.

=head1 SEE ALSO

=over 4

=item * L<App::MCP::CLI>

=item * L<App::MCP::CLI::Command::list>

=item * L<App::MCP::CLI::Command::call>

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

1; # End of App::MCP::CLI::Command::interactive
