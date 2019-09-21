package Inotifier::Model::FileWatch;

use strict;
use warnings;

use Linux::Inotify2;
use EV;
use AnyEvent;
use Mojo::Pg;
use Audio::Wav;

use TransmissionIdentifier;

use Data::Dumper;

sub new {
    my ($class, $app) = @_;

    my $conf = $app->defaults->{config};

    my $pg = Mojo::Pg->new($conf->{pg})
	or $app->log->error('Could not connect to database');

    my $self = {
	app => $app,
	pg  => $pg,
	prev_name => 'first time through',
	classifier => TransmissionIdentifier->new( { load_params => 1,
                                                     params => $conf->{params},
                                                     labels => $conf->{labels}} ),
    };

    if (ref($self->{classifier})) {
        $self->{app}->log->info('Classification is enabled');
    } else {
        $self->{app}->log->error(sprintf('Classification is DISABLED: %s', $self->{classifier}));
        delete($self->{classifier});
    }

    my $notifier = new Linux::Inotify2;

    $self->{watcher} = $notifier->watch( $conf->{audio_src}, IN_CLOSE_WRITE,
        sub { $self->file_added(@_) } );

    $self->{io} = AnyEvent->io(
        fh   => $notifier->{fd},
        poll => 'r',
        cb   => sub { $notifier->poll }
    );

    $self->{app}->log->debug('Watching new files for all clients');

    bless $self, $class;

    $self->create_lockout;

    my $default_setup = $conf->{default_setup};
    my %setups = %{$conf->{setups}};
    $self->set_mode($setups{$default_setup});

    #$self->count_down;

    return $self;
}

sub file_added {
    my ( $self, $event ) = @_;

    my $file = $event->name;

    $self->{app}->log->debug(sprintf('file: %s', $file));

    unless (-e $event->fullname) {
	# there is code in ham2mon to delete wav files with header
	# only (44 bytes).
	$self->{app}->log->debug( sprintf('a header only file was removed by ham2mon: %s', $file) );
	return;
    }

    if ($file eq $self->{prev_name}) {
	# this only handles case where same name comes up multiple times in a row.
	# the general case of other file(s) in between is not covered.
	# maybe handle it on DB insert (put unique constraint on file name
	# this is probably due to first file coming in and second occuring in < 1 second
	$self->{app}->log->debug( sprintf('a file with same name just happened: %s', $file) );
	#return;
    }
    $self->{prev_name} = $file;

    my $wav = Audio::Wav->new;
    my $read = $wav->read( $event->fullname );
    my $duration = $read->length_seconds;
    $read->{handle}->close;    # http://www.perlmonks.org/bare/?node_id=946696

    if ($duration < 1.0) {
        $self->{app}->log->debug(sprintf('throwing away a short transmission: %.2f', $duration ));
        return;
    }

    my ($freq) = $file =~ /(.*)_.*\.wav/;

    my $entry = $self->{pg}->db->query(
       'select freq_key, freq, label, bank, pass from freqs where freq = ? and bank = any(?::text[]) limit 1',
       $freq, $self->{app}->defaults->{config}->{banks}
	)->hash;    #  TODO: under what situations can there be more than one across scanned banks?

    #$self->{app}->log->debug(Dumper($entry));

    if (! $entry ) {   # if no entry then create one
	my $default = $self->{app}->defaults->{config}->{banks}->[0];

	$entry->{freq_key} = $self->{pg}->db->query('insert into freqs (freq, label, bank, source) values (?, ?, ?, ?) returning freq_key', $freq, 'Unknown', $default, 'search')
	    ->hash->{freq_key};

        $entry = { label => 'Unknown',
                   bank  => $default,
	           freq_key => $entry->{freq_key},
                   pass => 0,
                 }
    }

    my $xmit = {
        'freq'     => $freq,
        'file'     => $file,
        'type'     => 'audio',
        'duration' => $duration,
	%$entry,
    };

    # try to detect voice vs. data
    my $voice_detected;
    if ($self->{classifier}->is_voice( input => $event->fullname, duration => $duration )) {
    #if ($self->detect_voice($event->fullname, $duration)) {
	$voice_detected = 1;
        $self->{app}->log->debug('detected voice');
    } else {
	$voice_detected = 0;
        $self->{app}->log->debug('detected data');
	$xmit->{label} .= '   detected DATA';
    }

    $xmit->{xmit_key} = $self->{pg}->db->query(
        'insert into xmit_history (freq_key, source, file, duration, detect_voice) values (?, ?, ?, ?, ?) returning xmit_key',
	    $xmit->{freq_key}, 'dongle1', $file, $duration, $voice_detected
    )->hash->{xmit_key};

    if (!$voice_detected) {
        $self->{app}->log->debug(sprintf('Detected as data: %s', $file ));
        return;
    }

    # This is an audio clip so attempt to remove the key on/off (start/end bit)
    my $dest = $self->{app}->defaults->{config}->{audio_dst} . "/$file";
    #my @args = ( '/usr/sbin/sox', $event->fullname, $dest, 'reverse', 'trim', '0.23', 'reverse' );
    my @args = ( '/usr/bin/sox', $event->fullname, $dest, 'trim', '0.02', '-0.23' );
    system( @args )  == 0
	or $self->{app}->log->error("system @args failed: $?");
    $xmit->{duration} -= 0.25;

    foreach my $client (keys %{$self->{cb}}) {
        $self->{cb}{$client}->($xmit);
    }

    # TODO: ugh
    # we had something worth telling client about.  This hack will
    # increment freq center.   This is needed because I am not ready to
    # deal with ham2mon which needs code to filter uninteresting stuff
    # out.   Basically, remove need for return statements above.
    $self->count_down;

}

sub set_mode {
    my ($self, $params) = @_;

    my $base_freq = $params->{base_freq};

    #$self->set_center($self->{base_freq});
    my @centers = ();
    my $num_moves = 0;
    if ($params->{range} != 0) {
	my $range = $params->{range};

       #$self->{app}->log->debug(sprintf('range: %s', $range));

        my $start  = $base_freq - $range / 2 + 0.5 * $self->{app}->defaults->{config}->{width};
        my $finish = $base_freq + $range / 2 - 0.5 * $self->{app}->defaults->{config}->{width};
        $num_moves = ($finish - $start) / $self->{app}->defaults->{config}->{width} + 1;
        my $distance = ($finish - $start) / ($num_moves - 1);

        my $center = $start;
        for (my $i=1; $i <= $num_moves; $i++) {
            push @centers, $center;
	    $center += $distance;
        }
    } else {
        $num_moves = 0;
	@centers = ( $base_freq );

    }

    $self->{num_moves} = $num_moves;
    $self->{center_points} = \@centers;
    $self->{cur_move} = 0;

    $self->{app}->log->debug(sprintf('centers: %s', Dumper($self->{center_points})));

    $self->set_center;

    $self->count_down;

    # start at lower bound + 1/2 bandwidth:  lower_start =  base_freq - range/2 + 1/2 * width
    # go to upper bound - 1/2 bandwidth:  upper_finish = base_freq + range/2 - 1/2 * width
    # divide that range into chunks.   Overlap is OK.
    # number_of_moves = (upper_finish - lower_start) / 1e6 + 1
    # distance_between = (upper_finish - lower_start) / (number_of_moves - 1)

    # example: base_freq = 465   range = 10  width = 1
    # lower_start = 465 - 10/2 + .5 = 460.5
    # upper_finish = 465 + 10/2 - .5 = 469.5
    # number_of_moves = (469.5 - 460.5) / 1 + 1  = 10
    # distance = (469.5 - 460.5) / (10 - 1)
    # 460.5 461.5 462.5 463.5 464.5 465.5 466.5 467.5 468.5 469.5
}

sub set_center {
    my $self = shift;

    if ($self->{num_moves} == 0) { # not iterating through a range
        $self->{freq} = $self->{center_points}->[0];
    } else {
        $self->{cur_move}++;

        if ($self->{cur_move} > $self->{num_moves}) {
	    $self->{cur_move} = 1;
        }

        $self->{freq} = $self->{center_points}->[$self->{cur_move}-1];
    }

    $self->{app}->log->debug(sprintf('setting freq to: %s', $self->{freq}/1000000 ));

    #  screen -S scanner -p 0 -X stuff "/200.666\n"
    my @args = ( 'screen', '-S', 'scanner', '-p', '0', '-X', 'stuff',
	       sprintf('"/%s\\n"', $self->{freq}/1000000 )
	  );
    system(@args) == 0
	or $self->{app}->log->error("system @args failed: $?");
}

sub count_down {
    my $self = shift;

    # maybe add modes.   For example stay on certain center point.

    undef $self->{idle_timer};

    if ($self->{num_moves} == 0) { return }    # not iterating through a range

    my $rate = $self->{app}->defaults->{config}->{rate};
    $self->{idle_timer} = AnyEvent->timer (after => $rate, cb => sub {
	$self->set_center;

	#        system( 'screen', '-S', 'scanner', '-p', '0', '-X', 'stuff', '"m"' );
        $self->{app}->log->debug(sprintf('hack timer fired after %d seconds', $rate ));
        $self->count_down;
    });

}


sub watch {
    my ( $self, $client, $cb ) = @_;

    $self->{cb}{$client} = $cb;
    $self->{app}->log->debug(sprintf('watchning for %s', $client ));

    return $client;   # probably not oding right thing here
}

sub unwatch {
    my ($self, $client) = @_;

    delete $self->{cb}{$client};

    #$self->{watcher}->cancel;
}

sub get_freqs {
    my ($self, $mode) = @_;

    my $result;
    if ($mode eq 'Passed Frequencies') {
	$result = $self->{pg}->db->query(
	'select freq_key, freq, label, bank, pass from freqs where pass > 0 and bank = any(?::text[]) order by freq desc', $self->{app}->defaults->{config}->{banks}
	)->hashes->to_array;
    } else {
	my $type = 'True';
	if ($mode eq 'Detected as data') {
	    $type = 'False';
	}
        $self->{app}->log->debug("get_freqs type: $type");

        $result = $self->{pg}->db->query(
#	    'select freqs.freq_key, xmit_key, freq, label, bank, pass, file, round(extract(epoch from duration)::numeric,1) as duration from xmit_history, freqs where xmit_history.freq_key = freqs.freq_key order by xmit_key desc limit 20'
#	    'select freqs.freq_key, xmit_key, freq, label, bank, pass, file, round(extract(epoch from duration)::numeric,1) as duration from xmit_history, freqs where xmit_history.freq_key = freqs.freq_key and detect_voice = ? order by xmit_key desc limit 20', $type
	    'select freqs.freq_key, xmit_key, freq, label, bank, pass, file, extract(epoch from duration)::numeric as duration from xmit_history, freqs where xmit_history.freq_key = freqs.freq_key and detect_voice = ? order by xmit_key desc limit 20', $type
	    )->hashes->to_array;
    }
    return $result;
}

sub get_banks {
    my $self = shift;

    #TODO: Yes, this all is very contrived.  Need to get a better handle on better way.
    my $array = $self->{pg}->db->query(
	'select distinct(bank) from freqs order by bank asc'
	)->arrays->to_array;

    my @result;
    foreach my $element (@$array) {
	push @result, $element->[0];
    }

    # add any banks from the config
    my @banks = @{ $self->{app}->defaults->{config}->{banks} };
    foreach my $bank (@banks) {
        if (!grep( /$bank/, @result)) {
	    push @result, $bank;
        }
    }
    
#    my $default = $banks[0];
#    $self->{app}->log->debug("default bank: $banks[0]");
#    if (!grep( /$default/, @result)) {
#	push @result, $default;
#    }

    return \@result;
}

sub set_freq {
    my ( $self, $fields ) = @_;

    if (exists($fields->{pass})) {
	#$self->set_pass( $fields->{freq_key}, $fields->{pass} );

        $self->{app}->log->info(
	    sprintf( 'change pass for %s to %s', $fields->{freq_key}, $fields->{pass} ) );

        $self->{pg}->db->query( 'UPDATE freqs SET pass=? WHERE freq_key = ?',
				$fields->{pass}, $fields->{freq_key} );
	$self->create_lockout;
    }
    if (exists($fields->{label})) {
        $self->{app}->log->info(
	    sprintf( 'change label for %s to %s', $fields->{freq_key}, $fields->{label} ) );

        $self->{pg}->db->query( 'UPDATE freqs SET label=? WHERE freq_key = ?',
                                  $fields->{label}, $fields->{freq_key} );
    }
    if (exists($fields->{bank})) {
        $self->{app}->log->info(
	    sprintf( 'change bank for %s to %s', $fields->{freq_key}, $fields->{bank} ) );

        $self->{pg}->db->query( 'UPDATE freqs SET bank=? WHERE freq_key = ?',
                                  $fields->{bank}, $fields->{freq_key} );
    }

}

#sub set_pass {
#    my ( $self, $freq_key, $pass ) = @_;

#    $self->{app}->log->info(
#	sprintf( 'change pass for %s to %s', $freq_key, $pass ) );

#    $self->{pg}->db->query( 'UPDATE freqs SET pass=? WHERE freq_key = ?',
#			          $pass, $freq_key );

#}

sub create_lockout {
    my $self = shift;

    # now create blocklist for scanner
    open(my $fh, '>', '/cart/ham2mon/apps/lockout.txt')
	or die 	$self->{app}->log->error("Can't open > lockout.txt: $!");

    if ($self->{app}->defaults->{config}->{use_lockout}) {
        my $results = $self->{pg}->db->query( 'select freq from freqs where pass = 1 and bank = any(?::text[]) order by freq asc', $self->{app}->defaults->{config}->{banks});
        while (my $next = $results->array) {
    	    print $fh "$next->[0]E6\n";
        }
    }

    close($fh);

    # poke the screen session with scanner to reload the blocklist
    system( 'screen', '-S', 'scanner', '-p', '0', '-X', 'stuff', '"l"' );
}

sub set_label {
    my ( $self, $freq, $bank, $label ) = @_;

    $self->{app}->log->info(
	sprintf( 'change label for %s (%s) to %s', $freq, $bank, $label ) );

    $self->{pg}->db->query( 'UPDATE freqs SET label=? WHERE freq = ? AND bank = ?',
			          $label, $freq, $bank );
}

1;
