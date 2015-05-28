package Transmission;

use Mojo::Util qw(dumper);

use constant NO_PASS     => 0;
use constant MANUAL_PASS => 1;
use constant AUTO_PASS   => 2;
use Mojo::IOLoop::ForkCall;
#use Mojolicious::Plugins;
#use Mojolicious::Lite;
#use Mojo::Base 'Mojolicious::Plugin';

#my $plugins = Mojolicious::Plugins->new;
#my $plugin = $plugins->load_plugin('Mojolicious::Plugin::ForkCall');
#plugin 'Mojolicious::Plugin::ForkCall';

sub new {
    my ($class, $app, $freq, $source) = @_;

    if ($source =~ /(.+).audio/) {
	my $source = $1 . '.ogg';
    } else {
	$app->log->error("file name is not valid: $source");
    }
    (my $file = $source) =~ s/.audio/.ogg/;

    my @freq_list  = @{ $app->defaults('freq_list') };
    (my $entry) = grep { $_->{freq} == $freq } @freq_list;
    #   $state->{$file} = $entry;

    my $self = {
	'app' => $app,
	'freq' => $freq,
	'source_file' => $source,
	'file' => $file,
	'type' => 'audio',
        'url'  => $app->defaults->{audio_url},
	'start' => time(),
        %$entry,
    };
    bless $self, $class;

    # start autopass timer;
    $self->start_xmit_timer;

    return $self;
}

sub start_xmit_timer {
    my $self = shift;

    $self->{timer} = Mojo::IOLoop->timer(
        10 => sub {
            my $loop = shift;

            $self->{app}->log->info(sprintf('Long xmit (%s)', $self->{source_file}));

            $self->{app}->update_pass( $self->{freq}, $self->{bank}, AUTO_PASS );
            #app->publish( $state->{$file} );  # for testing let client know
            #delete $state->{$file};
            #$c->start_rtlfm;
        }
    );
}

sub close {
    my $self = shift;

    # stop autopass timer
    Mojo::IOLoop->remove($self->{timer});

    $self->{end} = time();

    if ($self->{end} - $self->{start} <= 1) {
	$self->{app}->log->info(sprintf('Throwing away short transmission (%s)',
					$self->{source_file}));
	return;
    }

    my $count = $self->{count};
    $self->{count} = ++$count;
    $self->{app}->update_count( $self->{freq}, $self->{bank}, $self->{count} );
    
    $self->{app}->log->info(sprintf('transmission closed (%s)', $self->{source_file}));

    # convert file to sample rate chrome supports

    my $fc = Mojo::IOLoop::ForkCall->new;
    $fc->run(
        sub {
            my @args = ( 'sox', '-r', '12000', '-c', '1', '-t', 'raw',
			 '-b', '16', '-e', 'signed-integer', $self->{source_file},
                         '-r', '44100', '-c', '2', $self->{file});
            system(@args);
            return @args;
        },
        sub {
            my ($c, @stuff) = @_;
            $self->{app}->log->info("sox done: $self->{file}");
	    my %smaller = %$self;
	    delete $smaller{app};
	    delete $smaller{timer};
	    #$self->{app}->log->debug(keys %$self);
            $self->{app}->publish( \%smaller );
            #delete $state->{$file};
        }
    );

}

1;
