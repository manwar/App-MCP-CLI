#!/usr/bin/env perl

use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME               => 'App::MCP::CLI',
    AUTHOR             => q{Mohammad Sajid Anwar <mohammad.anwar@yahoo.com>},
    VERSION_FROM       => 'lib/App/MCP/CLI.pm',
    ABSTRACT_FROM      => 'lib/App/MCP/CLI.pm',
    LICENSE            => 'artistic_2',
    EXE_FILES          => [ 'script/mcpcli' ],
    MIN_PERL_VERSION   => 5.014,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'App::Cmd'          => '0.330',
        'IPC::Open2'        => 0,
        'HTTP::Tiny'        => 0,
        'JSON::MaybeXS'     => 0,
        'Text::Table::Tiny' => 0,
        'File::Spec'        => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'App-MCP-CLI-*' },
    (eval { ExtUtils::MakeMaker->VERSION(6.46) } ? (META_MERGE => {
        'meta-spec' => { version => 2 },
        provides    => {
            'App::MCP::CLI' => {
                file    => 'lib/App/MCP/CLI.pm',
                version => MM->parse_version('lib/App/MCP/CLI.pm')
            },
            'App::MCP::CLI::Config' => {
                file    => 'lib/App/MCP/CLI/Config.pm',
                version => MM->parse_version('lib/App/MCP/CLI/Config.pm')
            },
            'App::MCP::CLI::Command::list' => {
                file    => 'lib/App/MCP/CLI/Command/list.pm',
                version => MM->parse_version('lib/App/MCP/CLI/Command/list.pm')
            },
            'App::MCP::CLI::Command::call' => {
                file    => 'lib/App/MCP/CLI/Command/call.pm',
                version => MM->parse_version('lib/App/MCP/CLI/Command/call.pm')
            },
            'App::MCP::CLI::Command::interactive' => {
                file    => 'lib/App/MCP/CLI/Command/interactive.pm',
                version => MM->parse_version('lib/App/MCP/CLI/Command/interactive.pm')
            },
            'App::MCP::CLI::Command::servers' => {
                file    => 'lib/App/MCP/CLI/Command/servers.pm',
                version => MM->parse_version('lib/App/MCP/CLI/Command/servers.pm')
            },
            'App::MCP::CLI::Command::version' => {
                file    => 'lib/App/MCP/CLI/Command/version.pm',
                version => MM->parse_version('lib/App/MCP/CLI/Command/version.pm')
            },
        },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/manwar/App-MCP-CLI.git',
                web  => 'https://github.com/manwar/App-MCP-CLI',
            },
            bugtracker => {
                web    => 'https://github.com/manwar/App-MCP-CLI/issues'
            },
        }})
     : ()
    ),
);
