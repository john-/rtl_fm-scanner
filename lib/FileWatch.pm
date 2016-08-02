package Inotifier::Model::FileWatch;

use Linux::Inotify2;
use EV;
use AnyEvent;
use Mojo::Pg;
use Audio::Wav;

use strict;
use warnings;

use Data::Dumper;

sub new {
    my ($class, $app) = @_;

    my $pg = Mojo::Pg->new('postgresql://script@/cart')
	or $app->log->error('Could not connect to database');

    my $self = {
	app => $app,
	pg  => $pg,
	prev_name => 'first time through',
    };

    my $notifier = new Linux::Inotify2;

    $self->{watcher} = $notifier->watch( '/home/pub/ham2mon/apps/wav', IN_CLOSE_WRITE,
        sub { $self->file_added(@_) } );

    $self->{io} = AnyEvent->io(
        fh   => $notifier->{fd},
        poll => 'r',
        cb   => sub { $notifier->poll }
    );

    $self->{app}->log->debug('Watching new files for all clients');

    bless $self, $class;

    $self->create_lockout;
    $self->set_mode( { base_freq => $self->{app}->defaults->{config}->{base_freq}, # remember starting point
	               range => $self->{app}->defaults->{config}->{range},
	               rate => $self->{app}->defaults->{config}->{rate},
		     } );
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
	$self->{app}->log->debug( sprintf('a file with same name just happened: %s', $file) );
	return;
    }
    $self->{prev_name} = $file;

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
        'freq' => $freq,
        'file' => $file,
        'type' => 'audio',
	%$entry,
    };

    my $wav = Audio::Wav->new;
    my $read = $wav->read( $event->fullname );
#    my $read = $wav->read( $dest );
    my $duration = $read->length_seconds;
    $xmit->{duration} = $duration;
    $read->{handle}->close;    # http://www.perlmonks.org/bare/?node_id=946696

    if ($duration < 1.0) {
        $self->{app}->log->debug(sprintf('throwing away a short transmission: %.2f', $duration ));
        return;
    }

    my $dest = "/home/pub/ham2mon/apps/wav_trimmed/$file";
    #my @args = ( '/usr/sbin/sox', $event->fullname, $dest, 'reverse', 'trim', '0.23', 'reverse' );
    my @args = ( '/usr/sbin/sox', $event->fullname, $dest, 'trim', '0.02', '-0.23' );
    system( @args );
    $xmit->{duration} -= 0.25;

    $xmit->{xmit_key} = $self->{pg}->db->query(
        'insert into xmit_history (freq_key, source, file, duration) values (?, ?, ?, ?) returning xmit_key',
	    $xmit->{freq_key}, 'dongle1', $file, $duration
    )->hash->{xmit_key};

    foreach my $client (keys %{$self->{cb}}) {
        $self->{cb}{$client}->($xmit);
    }

    # TODO: ugh
    # we had something worth telling client about.  This hack will
    # increment freq center point 1Mhz.   This is needed because I am not ready to
    # deal with ham2mon which needs code to filter uninteresting stuff
    # out.   Basically, remove need for return statements above.
    $self->count_down;

}

sub set_mode {
    my ($self, $params) = @_;

    # base_freq, range, rate
    foreach my $param ( ('base_freq', 'range', 'rate') ) {
        if (exists $params->{$param}) {
	    $self->{$param} = $params->{$param};
            $self->{app}->defaults->{config}->{$param} = $params->{$param};
	}
    }

    $self->set_center($self->{base_freq});

    $self->count_down;
}

sub set_center {
    my ($self, $freq) = @_;

    $self->{freq} = $freq;

    $self->{app}->log->debug(sprintf('setting freq to: %s', $freq/1000000 ));

    open(my $fh, '>', '/home/pub/ham2mon/apps/cur_freq') or $self->{app}->log->error(sprintf('could not open cur_freq' ));
;
    {
        local $/;
        print $fh sprintf('%s',$freq);
    }
    close($fh);
}

sub count_down {
    my $self = shift;

    # maybe add modes.   For example stay on certain center point.

    undef $self->{idle_timer};

    if ($self->{rate} == 0) { return }

    $self->{idle_timer} = AnyEvent->timer (after => $self->{rate}, cb => sub {
	if ($self->{freq} >= $self->{base_freq} + $self->{range}/2) {
	    $self->{freq} = $self->{base_freq} - $self->{range}/2;
	} else {
	    $self->{freq} += 1000000;
	}

	$self->set_center( $self->{freq} );

#        system( 'screen', '-S', 'scanner', '-p', '0', '-X', 'stuff', '"m"' );
        $self->{app}->log->debug(sprintf('hack timer fired after %d seconds', $self->{rate} ));
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
	'select freq_key, freq, label, bank, pass from freqs where pass <> 0 and bank = any(?::text[]) order by freq desc', $self->{app}->defaults->{config}->{banks}
	)->hashes->to_array;
    } else {
        $result = $self->{pg}->db->query(
	    'select freqs.freq_key, xmit_key, freq, label, bank, pass, file, round(extract(epoch from duration)::numeric,1) as duration from xmit_history, freqs where xmit_history.freq_key = freqs.freq_key order by xmit_key desc limit 20'
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

    my $default = $self->{app}->defaults->{config}->{banks}->[0];
    $self->{app}->log->debug("default bank: $default");
    if (!grep( /$default/, @result)) {
	push @result, $default;
    }

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
    open(my $fh, '>', '/home/pub/ham2mon/apps/lockout.txt')
	or die 	$self->{app}->log->error("Can't open > lockout.txt: $!");

    my $results = $self->{pg}->db->query( 'select freq from freqs where pass = 1 and bank = any(?::text[]) order by freq asc', $self->{app}->defaults->{config}->{banks});
    while (my $next = $results->array) {
	print $fh "$next->[0]E6\n";
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
