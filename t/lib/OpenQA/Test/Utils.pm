package OpenQA::Test::Utils;

use strict;
use warnings;

use base 'Exporter';

use IO::Socket::INET;
use Mojolicious;
use POSIX '_exit';
use OpenQA::Worker;
use OpenQA::Worker::Common;
use Config::IniFiles;
use Data::Dumper 'Dumper';
use OpenQA::Utils qw(log_error log_info log_debug);
use OpenQA::WebSockets::Client;
use OpenQA::Scheduler::Client;
use Mojo::Home;
use Mojo::File 'path';
use Cwd qw(abs_path getcwd);
use Test::More;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::Server::Daemon;

BEGIN {
    if (!$ENV{MOJO_HOME}) {
        # override default home as Mojo gets it wrong for our sub apps
        # This 'require' is here because the 'home detect' method
        # relies on %INC, which is only populated when the module is
        # loaded: see #870 and #876
        require OpenQA::Utils;
        $ENV{MOJO_HOME} = Mojo::Home->new->detect('OpenQA::Utils');
    }
}

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = (
    qw(redirect_output standard_worker),
    qw(create_webapi create_websocket_server create_scheduler create_live_view_handler),
    qw(create_worker unresponsive_worker wait_for_worker setup_share_dir),
    qw(kill_service unstable_worker client_output fake_asset_server),
    qw(cache_minion_worker cache_worker_service)
);

sub cache_minion_worker {
    process(
        sub {

            # this service can be very noisy
            require OpenQA::Worker::Cache::Service;
            local $ENV{MOJO_MODE} = 'test';
            OpenQA::Worker::Cache::Service->run(qw(minion worker));
            Devel::Cover::report() if Devel::Cover->can('report');
            _exit(0);
        })->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0);
}

sub cache_worker_service {
    process(
        sub {

            # this service can be very noisy
            require OpenQA::Worker::Cache::Service;
            local $ENV{MOJO_MODE} = 'test';
            OpenQA::Worker::Cache::Service->run(qw(daemon -l http://*:7844));
            Devel::Cover::report() if Devel::Cover->can('report');
            _exit(0);
        })->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0);
}

sub fake_asset_server {
    my $mock = Mojolicious->new;
    $mock->mode('test');
    $mock->routes->get(
        '/tests/:job/asset/:type/:filename' => sub {
            my $c        = shift;
            my $id       = $c->stash('job');
            my $type     = $c->stash('type');
            my $filename = $c->stash('filename');
            return $c->render(status => 404, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-404/;
            return $c->render(status => 400, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-400/;
            return $c->render(status => 500, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-500/;
            return $c->render(status => 503, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-503/;

            if ($filename =~ /sle-12-SP3-x86_64-0368-589/) {
                $c->res->headers->content_length(10);
                $c->inactivity_timeout(1);
                $c->res->headers->content_type('text/plain');
                $c->res->body('Six!!!');
                $c->rendered(200);
            }

            if (my ($size) = ($filename =~ /sle-12-SP3-x86_64-0368-200_?([0-9]+)?\@/)) {
                my $our_etag = 'andi $a3, $t1, 41399';

                my $browser_etag = $c->req->headers->header('If-None-Match');
                if ($browser_etag && $browser_etag eq $our_etag) {
                    $c->res->body('');
                    $c->rendered(304);
                }
                else {
                    $c->res->headers->content_length($size // 1024);
                    $c->inactivity_timeout(1);
                    $c->res->headers->content_type('text/plain');
                    $c->res->headers->header('ETag' => $our_etag);
                    $c->res->body("\0" x ($size // 1024));
                    $c->rendered(200);
                }
            }
        });

    $mock->routes->get(
        '/' => sub {
            my $c = shift;
            return $c->render(status => 200, text => "server is running");
        });
    return $mock;
}

sub redirect_output {
    my ($buf) = @_;
    open my $FD, '>', $buf;
    *STDOUT = $FD;
    *STDERR = $FD;
}

sub kill_service {
    my $pid = shift;
    return unless $pid;
    my $forced = shift;
    kill POSIX::SIGTERM => $pid;
    kill POSIX::SIGKILL => $pid if $forced;
    waitpid($pid, 0);
}

sub wait_for_worker {
    my $schema = shift;
    my $id     = shift;
    for (0 .. 10) {
        sleep 2;
        diag('Attempt for worker: ' . $id);
        my $w = $schema->resultset("Workers")->find($id);
        last if defined $w && !$w->dead;
    }
}

sub create_webapi {
    my $mojoport = shift;
    diag("Starting WebUI service. Port: $mojoport");

    my $startingpid = $$;
    my $mojopid     = fork();
    if ($mojopid == 0) {
        local $ENV{MOJO_MODE} = 'test';
        my $daemon = Mojo::Server::Daemon->new(listen => ["http://127.0.0.1:$mojoport"], silent => 1);
        $daemon->build_app('OpenQA::WebAPI');
        $daemon->run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    else {
        #$SIG{__DIE__} = sub { kill('TERM', $mojopid); };
        # as this might download assets on first test, we need to wait a while
        my $wait = time + 50;
        while (time < $wait) {
            my $t      = time;
            my $socket = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => $mojoport,
                Proto    => 'tcp',
            );
            last if $socket;
            sleep 1 if time - $t < 1;
        }
    }
    return $mojopid;
}

sub create_websocket_server {
    my ($port, $bogus, $nowait, $noworkercheck) = @_;

    diag("Starting WebSocket service");
    diag("Bogus: $bogus | No wait: $nowait | No worker checks: $noworkercheck");

    OpenQA::WebSockets::Client->singleton->port($port);
    my $wspid = fork();
    if ($wspid == 0) {
        local $ENV{MOJO_LISTEN}             = "http://127.0.0.1:$port";
        local $ENV{MOJO_INACTIVITY_TIMEOUT} = 9999;

        use OpenQA::WebSockets;
        use Mojo::Util 'monkey_patch';
        use OpenQA::WebSockets;
        use OpenQA::WebSockets::Controller::Worker;
        use OpenQA::WebSockets::Plugin::Helpers;

        # TODO: Kill it with fire!
        if ($bogus) {
            monkey_patch 'OpenQA::WebSockets::Controller::Worker', _get_worker => sub { return };
            monkey_patch 'OpenQA::WebSockets::Controller::Worker', ws          => sub {
                my $c = shift;
                $c->on(json   => \&OpenQA::WebSockets::Controller::Worker::_message);
                $c->on(finish => \&OpenQA::WebSockets::Controller::Worker::_finish);
            };
        }
        monkey_patch 'OpenQA::WebSockets::Plugin::Helpers', _workers_checker => sub { 1 }
          if ($noworkercheck);
        OpenQA::WebSockets::run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    elsif (!defined $nowait) {
        # wait for websocket server
        my $wait = time + 20;
        while (time < $wait) {
            my $t      = time;
            my $socket = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => $port,
                Proto    => 'tcp'
            );
            last if $socket;
            sleep 1 if time - $t < 1;
        }
    }
    return $wspid;
}

sub create_scheduler {
    my ($port) = @_;

    diag("Starting Scheduler service");

    OpenQA::Scheduler::Client->singleton->port($port);
    my $pid = fork();
    if ($pid == 0) {
        local $ENV{MOJO_LISTEN}             = "http://127.0.0.1:$port";
        local $ENV{MOJO_INACTIVITY_TIMEOUT} = 9999;

        OpenQA::Scheduler::run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    return $pid;
}

sub create_live_view_handler {
    my ($mojoport) = @_;
    my $pid = fork();
    if ($pid == 0) {
        my $livehandlerport = $mojoport + 2;
        my $daemon          = Mojo::Server::Daemon->new(listen => ["http://127.0.0.1:$livehandlerport"], silent => 1);
        $daemon->build_app('OpenQA::LiveHandler');
        $daemon->run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    return $pid;
}

sub setup_share_dir {
    my ($sharedir) = @_;
    $sharedir = path($sharedir, 'openqa', 'share')->make_path;

    path($sharedir, 'factory', 'iso')->make_path;

    my $iso_file_path = abs_path('../os-autoinst/t/data/Core-7.2.iso') or die 'Core-7.2.iso not found';
    my $iso_link_path = path($sharedir, 'factory', 'iso')->child('Core-7.2.iso')->to_string();
    symlink($iso_file_path, $iso_link_path) || die "can't symlink $iso_link_path -> $iso_file_path";

    path($sharedir, 'tests')->make_path;

    my $tests_dir_path  = abs_path('../os-autoinst/t/data/tests/') or die 'tests dir not found';
    my $tests_link_path = path($sharedir, 'tests')->child('tinycore');
    symlink($tests_dir_path, $tests_link_path) || die "can't symlink $tests_link_path -> $tests_dir_path";

    return $sharedir;
}

sub create_worker {
    my ($apikey, $apisecret, $host, $instance, $log) = @_;
    my $connect_args = "--instance=${instance} --apikey=${apikey} --apisecret=${apisecret} --host=${host}";
    diag("Starting standard worker. Instance: $instance for host $host");

    my $workerpid = fork();
    if ($workerpid == 0) {
        exec("perl ./script/worker $connect_args --isotovideo=../os-autoinst/isotovideo --verbose"
              . (defined $log ? " 2>&1 > $log" : ""));
        die "FAILED TO START WORKER";
    }
    return defined $log ? `pgrep -P $workerpid` : $workerpid;
}

sub unstable_worker {
    # the help of the Doctor would be really appreciated here.
    my ($apikey, $apisecret, $host, $instance, $ticks, $sleep) = @_;
    diag("Starting unstable worker. Instance: $instance for host $host");
    $ticks = 1 unless $ticks;

    my $pid = fork();
    if ($pid == 0) {
        use Mojo::Util 'monkey_patch';
        use Mojo::IOLoop;
        my ($worker_settings, $host_settings)
          = read_worker_config($instance, $host);    # It will read from config file, so watch out
        $OpenQA::Worker::Common::worker_settings = $worker_settings;
        $OpenQA::Worker::Common::instance        = $instance;


        # XXX: this should be sent to the scheduler to be included in the worker's table
        local $ENV{QEMUPORT} = ($instance) * 10 + 20002;
        local $ENV{VNC}      = ($instance) + 90;
        # Mangle worker main()
        monkey_patch 'OpenQA::Worker', main => sub {
            my ($host_settings) = @_;
            my $dir;
            for my $h (@{$host_settings->{HOSTS}}) {
                my @dirs = ($host_settings->{$h}{SHARE_DIRECTORY}, path($OpenQA::Utils::prjdir, 'share'));
                ($dir) = grep { $_ && -d } @dirs;
                unless ($dir) {
                    log_error("Can not find working directory for host $h. Ignoring host");
                    next;
                }

                Mojo::IOLoop->next_tick(
                    sub { OpenQA::Worker::Common::register_worker($h, $dir, $host_settings->{$h}{TESTPOOLSERVER}) });
            }
        };

        OpenQA::Worker::init($host_settings, {apikey => $apikey, apisecret => $apisecret});
        OpenQA::Worker::main($host_settings);
        for (0 .. $ticks) {
            Mojo::IOLoop->singleton->one_tick;
        }
        Devel::Cover::report() if Devel::Cover->can('report');
        if ($sleep) {
            1 while sleep $sleep;
        }
        _exit(0);
    }
    sleep $sleep if $sleep;

    return $pid;
}

sub standard_worker     { c_worker(@_, 0) }
sub unresponsive_worker { c_worker(@_, 1) }

sub c_worker {
    # the help of the Doctor would be really appreciated here.
    my ($apikey, $apisecret, $host, $instance, $bogus) = @_;
    $bogus //= 1;

    my $pid = fork();
    if ($pid == 0) {
        use Mojo::Util 'monkey_patch';
        use Mojo::IOLoop;
        my ($worker_settings, $host_settings)
          = read_worker_config($instance, $host);    # It will read from config file, so watch out
        $worker_settings->{LOG_LEVEL}            = 'debug';
        $OpenQA::Worker::Common::worker_settings = $worker_settings;
        $OpenQA::Worker::Common::instance        = $instance;


        # XXX: this should be sent to the scheduler to be included in the worker's table
        local $ENV{QEMUPORT} = ($instance) * 10 + 20002;
        local $ENV{VNC}      = ($instance) + 90;
        # Mangle worker main()
        if ($bogus) {
            monkey_patch 'OpenQA::Worker::Commands', websocket_commands => sub {
                my ($tx, $json) = @_;
                log_debug("Received " . Dumper($json));
            };
        }

        OpenQA::Worker::init($host_settings, {apikey => $apikey, apisecret => $apisecret});
        OpenQA::Worker::main($host_settings);
        Mojo::IOLoop->start;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }

    return $pid;
}

sub read_worker_config {
    my ($instance, $host) = @_;
    my $worker_dir = $ENV{OPENQA_CONFIG} || '/etc/openqa';
    my $cfg        = Config::IniFiles->new(-file => $worker_dir . '/workers.ini');

    my $sets = {};
    for my $section ('global', $instance) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $sets->{uc $set} = $cfg->val($section, $set);
            }
        }
    }
    # use separate set as we may not want to advertise other host confiuration to the world in job settings
    my $host_settings;
    $host ||= $sets->{HOST} ||= 'localhost';
    delete $sets->{HOST};
    my @hosts = split / /, $host;
    for my $section (@hosts) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $host_settings->{$section}{uc $set} = $cfg->val($section, $set);
            }
        }
        else {
            $host_settings->{$section} = {};
        }
    }
    $host_settings->{HOSTS} = \@hosts;

    return $sets, $host_settings;
}

sub client_output {
    my ($apikey, $apisecret, $host, $args) = @_;
    my $connect_args = "--apikey=${apikey} --apisecret=${apisecret} --host=${host}";
    open(my $client, "perl ./script/client $connect_args $args|");
    my $out;
    while (<$client>) {
        $out .= $_;
    }
    close($client);
    return $out;
}

1;
