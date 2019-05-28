#! /usr/bin/env perl6

use JSON::Fast;
use Cro::HTTP::Client;

class Runner {
    has $.github;
    has $.name;
    has $!container-name;

    has %.stats;

    method !output($symbol, $msg) {
        $symbol ~ $!name.fmt(" [%15s] ") ~ $msg.trim;
    }

    method !format($msg, Bool :$good = False) {
        return self!output($good ?? "✔️ " !! "❌", $msg);
    }

    method !stdout($msg) {
        return self!output("💬", $msg);
    }

    method !stderr($msg) {
        return self!output("⚠️ ", $msg);
    }

    method !tree($src) {
        for $src.dir -> $i {
            samewith(self, $i) if so $i.d;
            $i.take;
        }
    }

    method !rm-rf($folder) {
        for gather self!tree($folder) -> $i {
            $i.rmdir when so $i.d;
            $i.unlink;
        }

        $folder.rmdir;
    }

    method !slurp(Supply $sup) {
        my $buf;

        my $supplier = Supplier.new;
        my $supply = $supplier.Supply;

        $sup.tap(-> $data { $buf ~= $data }, done => { $supplier.emit($buf) });
        return $supply;
    }

    method !do-request($client, $equation) {
        my $promise-result = Promise.new;
        my $result = $promise-result.vow;

        my $promise = $client.post: '/calc',
            content-type => 'application/json',
            body => { :$equation, };

        $promise.then({
            # promise kept by timeout, just get out of here
            return if $result.promise.status ~~ Kept;

            .result.body.then({
                with .result {
                    my %h =
                        result => .<result>,
                        is-equ-returned => $equation eq .<equation>;
                    $result.keep(%h);
                }
            });
            CATCH {
                when X::Cro::HTTP::Error {
                    if .response.status == 400 {
                        .response.body.then({
                            with .result {
                                my %h =
                                    result          => 'error',
                                    msg             => .<error>,
                                    is-equ-returned => .<equation> eq $equation;
                                $result.keep(%h);
                            }
                        });
                    } else {
                        $result.keep(%{result => 'error'});
                    }
                }
                default {
                    $result.keep(%{result => 'error'});
                }
            }
        });

        Promise.in(5).then({
            $result.keep(%{result => 'timeout'}) unless $result.promise.status ~~ Kept;
        });

        return $promise-result;

    }

    method start(:$clone) {
        start {
            my $cwd = $*TMPDIR.add($!name);

            if ?$clone || !$cwd.add('.git').e {
                if $cwd.e {
                    self!rm-rf($cwd);
                    self!format("rm -rf $cwd", :good).say;
                }

                $cwd.mkdir;
                self!format("mkdir $cwd", :good).say;

                my $proc = Proc::Async.new: :r, 'git', 'clone', $!github, $cwd;

                $proc.stdout.tap(-> $line {
                    self!stdout($line.chomp).say;
                });

                $proc.stderr.tap(-> $line {
                    self!stderr($line.chomp).say;
                });

                self!format("git clone $!github $cwd", :good).say;
                with await $proc.start {
                    self!format(.exitcode.fmt("git clone finished with %d exitcode"), good => .exitcode == 0).say;
                }
            }

            unless $cwd.add('Dockerfile').e {
                die "$!name missing Dockerfile";
            }

            my $image-name = "atomspace/{$!name.lc}";

            my $docker-build = Proc::Async.new: :r, 'docker', 'build', '-t', $image-name, '.';
            my @output;

            $docker-build.stdout.lines(:chomp).tap(-> $line {
                @output.shift if @output.elems > 5;
                @output.push: self!stdout($line);
            });

            $docker-build.stderr.lines(:chomp).tap(-> $line {
                @output.shift if @output.elems > 5;
                @output.push: self!stderr($line);
            });

            self!format("docker build -t $image-name .", :good).say;
            with await $docker-build.start(:$cwd) {
                self!format(.exitcode.fmt("docker build finished with %d exitcode"), good => .exitcode == 0).say;

                if so .exitcode {
                    @output.join("\n").say;
                    die "$!name not able to build Docker image" if so .exitcode;
                }
            }

            my $container-name = "as-{$!name.lc}-container";

            my $docker-run = Proc::Async.new: :r, 'docker', 'run', '-d', '--rm', '--name', $container-name, $image-name;

            $docker-run.stdout.lines(:chomp).tap(-> $line {
                self!stdout($line).say;
            });

            $docker-run.stderr.lines(:chomp).tap(-> $line {
                self!stderr($line).say;
            });

            self!format("docker run --name $container-name $image-name", :good).say;
            with await $docker-run.start(:$cwd) {
                self!format(.exitcode.fmt("docker run finished with %d exitcode"), good => .exitcode == 0).say;

                if so .exitcode {
                    die "$!name not able to run Docker image" if so .exitcode;
                }
            }

            my $docker-inspect = Proc::Async.new: :r, 'docker', 'inspect', $container-name;

            my $host;
            self!slurp($docker-inspect.stdout).tap(-> $json {
                # .[0].NetworkSettings.Networks.bridge.IPAddress
                my $x = from-json $json;

                $host = $x.first.<NetworkSettings>.<Networks>.<bridge>.<IPAddress>;
            });

            self!format("docker inspect atomspace/$!name .", :good).say;
            with await $docker-inspect.start(:$cwd) {
                self!format(.exitcode.fmt("docker inspect finished with %d exitcode"), good => .exitcode == 0).say;

                # to be able to cleanup
                $!container-name = $container-name;
            }

            my $client = Cro::HTTP::Client.new(base-uri => "http://{$host}:8080");
            my $healthcheck = await start {
                my $response;
                my $cnt = 0;
                while !$response && $cnt++ < 10 {
                    my $promise = $client.get("/healthcheck");
                    $response = await $promise;

                    CATCH {
                        default {
                            self!format("reconnecting to $!name in 1 sec...").say;
                            sleep 1;
                        }
                    }
                }

                unless $response {
                    die "$!name can't connect to service";
                }

                $response;
            };
            my $json = await $healthcheck.body;

            %!stats<tests><healthcheck> = $json<status> eq 'UP';

            my @test-cases =
                %{ result => 'error',  equation => '(2 + 2) + ('},
                %{ result => '1',      equation => '1/2 + 1/2' },
                %{ result => '5/6',    equation => '1/2 + 1/3' },
                %{ result => '2',      equation => '(((4/2)))' },
                %{ result => 'error',  equation => '1 2' },
                %{ result => 'error',  equation => '(1' },
                %{ result => 'error',  equation => '(1))' },
                %{ result => 'error',  equation => '((1)' },
                %{ result => 'error',  equation => '1 + 2 3 / 4' },
                %{ result => '7/6',    equation => '1/2 + 2/3' },
                %{ result => '3/4',    equation => '(3/6) / (2/3)' },
                %{ result => '-47/42', equation => '(1/2 + 2/3) - ((2/7) / (1/8))' },
                %{ result => '3/2',    equation => '1 + 1/2' },
                %{ result => '1/9',    equation => '((2/3) * (1/6))' },
                %{ result => '3/8',    equation => '1/(2/(3/(4)))' };


            @test-cases.push(%{ result => 3000, equation => ("1/2" xx 6000).join("+"), name => "long" });

            for @test-cases -> $test {
                $test<promise> = self!do-request($client, $test<equation>);
            }

            await Promise.allof(@test-cases.map: *<promise>);

            my $equation-returned-count = 0;
            my $error-message-count = 0;
            for @test-cases -> $test {
                with $test<promise>.result {
                    my $name = $test<name> // $test<equation>;
                    %!stats<tests>{$name} = $test<result> eq .<result> ?? '+' !! '-';
                    %!stats<tests>{$name} = 'T' if .<result> eq 'timeout';

                    if .<result> eq 'error' && so .<msg> {
                        $error-message-count++;
                    }
                    $equation-returned-count++ if .<is-equ-returned>;
                }
            }

            %!stats<tests><equation-returned> = @test-cases.elems == $equation-returned-count;
            %!stats<tests><error-messages> = @test-cases.grep(*<result> eq 'error').elems == $error-message-count;

            %!stats<name> = $!name;
            %!stats;
        }
    }

    method cleanup {
        start {
            return unless $!container-name;

            my $docker-kill = Proc::Async.new: :r, 'docker', 'kill', $!container-name;

            $docker-kill.stdout.lines(:chomp).tap(-> $line {
                self!stdout($line).say;
            });

            $docker-kill.stderr.lines(:chomp).tap(-> $line {
                self!stderr($line).say;
            });

            self!format("docker kill $!container-name", :good).say;
            with await $docker-kill.start {
                self!format(.exitcode.fmt("docker kill finished with %d exitcode"), good => .exitcode == 0).say;

                if so .exitcode {
                    die "$!name not able to kill Docker container" if so .exitcode;
                }
            }
        }
    }
}

sub MAIN(Str :$repo-list!, Bool :$clone) {
    my @workers;

    for $repo-list.IO.lines -> $line {
        next if $line ~~ / ^^ '#' /;

        with $line ~~ / 'github.com/' $<name> = <-[/]>+ / {
            @workers.push: Runner.new(github => $line, name => ~$<name>);
        }
    }

    my @started = @workers».start(:$clone);
    await Promise.allof(@started);

    my %data;
    for @started -> $p {
        when $p.status eq 'Broken' {
            "Error: {$p.cause.message}".say;
        }
        with $p.result {
            %data{.<name>} = .<tests>;
        }
    }

    await Promise.allof(@workers».cleanup);

    my @names = %data.keys.sort;
    say "test-name|" ~ @names.join("|");

    for %data<cono>.keys -> $k {
        say "$k|" ~ @names.map({ %data{$_}{$k} }).map({ qw/+ - T/.first(* eq $_) ?? $_ !! $_ ?? '+' !! '-' }).join("|");
    }
}
