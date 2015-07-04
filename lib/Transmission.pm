package Transmission;

use Mojo::Util qw(dumper);
use Mojo::IOLoop::ForkCall;
use Mojo::JSON qw(decode_json encode_json);

use constant NO_PASS     => 0;
use constant MANUAL_PASS => 1;
use constant AUTO_PASS   => 2;

sub new {
    my ( $class, $app, $freq, $source ) = @_;

    if ( $source =~ /(.+).audio/ ) {
        my $source = $1 . '.ogg';
    }
    else {
        $app->log->error("file name is not valid: $source");
    }
    ( my $file = $source ) =~ s/.audio/.ogg/;

    my @freq_list = @{ $app->defaults('freq_list') };
    ( my $entry ) = grep { $_->{freq} == $freq } @freq_list;

    #   $state->{$file} = $entry;

    my $self = {
        'app'         => $app,
        'freq'        => $freq,
        'source_file' => $source,
        'file'        => $file,
        'type'        => 'audio',
        'url'         => $app->defaults->{audio_url},
        'start'       => time(),
        %$entry,
    };
    bless $self, $class;

    # start autopass timer;
    $self->start_xmit_timer;

    return $self;
}

sub start_xmit_timer {
    my $self = shift;

    #TODO:  There is probably a bug where this timer gets hit after rl_fm is restarted.
    #       Probably need to add a method for sub that restarts rtl_fm to kill this timer.
    $self->{timer} = Mojo::IOLoop->timer(
        15 => sub {
            my $loop = shift;

            $self->{app}
              ->log->info( sprintf( 'Long xmit (%s)', $self->{source_file} ) );

	    $self->close;
            #$self->{app}
            #  ->update_pass( $self->{freq}, $self->{bank}, AUTO_PASS );
        }
    );
}

sub close {
    my $self = shift;

    # stop autopass timer
    Mojo::IOLoop->remove( $self->{timer} );

    $self->{stop} = time();

    if ( $self->{stop} - $self->{start} <= 0 ) {
        $self->{app}->log->info( sprintf('Throwing away short transmission') );
        return;
    }

    $self->{app}->log->info( sprintf('transmission closed') );

    # convert file to sample rate chrome supports

    my $fc = Mojo::IOLoop::ForkCall->new;
    $fc->run(
        sub {
            my @args = (
                'sox',            '-r',
                '12000',          '-c',
                '1',              '-t',
                'raw',            '-b',
                '16',             '-e',
                'signed-integer', $self->{source_file},
                '-r',             '44100',
                '-c',             '2',
                $self->{file},
		'pad',           '0',  '1'
            );
            system(@args);
            return @args;
        },
        sub {
            my ( $c, @stuff ) = @_;
            $self->{app}->log->info("sox done: $self->{file}");

            # internal tracking of count (sent with audio message)
            my $count = $self->{count};
            $self->{count} = ++$count;

            # update count that is sent with /freq url
            my @freqs = @{ $self->{app}->defaults->{freq_list} };
            foreach my $entry (@freqs) {

                if (   ( $entry->{freq} == $self->{freq} )
                    && ( $entry->{bank} eq $self->{bank} ) )
                {
                    $entry->{count} = $count;
                }

            }

	    $self->{app}->pubsub->notify(msg => encode_json( $self->neuter_self ));

            $self->{app}->pg->db->query(
'INSERT INTO xmit_history (freq_key, source, start, stop) values (?, ?, to_timestamp(?), to_timestamp(?))',
                $self->{freq_key}, 'dongle1', $self->{start}, $self->{stop}
            );
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
