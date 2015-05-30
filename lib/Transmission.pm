package Transmission;

use Mojo::Util qw(dumper);

use constant NO_PASS     => 0;
use constant MANUAL_PASS => 1;
use constant AUTO_PASS   => 2;
use Mojo::IOLoop::ForkCall;

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

    $self->{stop} = time();

    if ($self->{stop} - $self->{start} <= 0) {
	$self->{app}->log->info(sprintf('Throwing away short transmission'));
	return;
    }

    #my $count = $self->{count};
    #$self->{count} = ++$count;
    #$self->{app}->update_count( $self->{freq}, $self->{bank}, $self->{count} );

    $self->{app}->log->info(sprintf('transmission closed'));

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

	    # internal tracking of count (sent with audio message)
            my $count = $self->{count};
            $self->{count} = ++$count;

	    # update count that is sent with /freq url
	    my @freqs = @{ $self->{app}->defaults->{freq_list} };
	    foreach my $entry ( @freqs ) {

                if ( ($entry->{freq} == $self->{freq}) && ($entry->{bank} eq $self->{bank}) ) {
	            $entry->{count} = $count;
	       }

            }

            $self->{app}->publish( $self->neuter_self );

	    $self->{app}->pg->db->query('INSERT INTO xmit_history (freq_key, source, start, stop) values (?, ?, to_timestamp(?), to_timestamp(?))',
			      $self->{freq_key}, 'dongle1', $self->{start}, $self->{stop});
        }
    );

}

sub neuter_self {
    my $self = shift;

    my %msg = %$self;
    delete $msg{app};
    delete $msg{timer};
    #$self->{app}->log->debug(keys %$self);
    return \%msg;
}

1;
