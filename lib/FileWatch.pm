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

    return bless $self, $class;
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
	$entry->{freq_key} = $self->{pg}->db->query('insert into freqs (freq, label, bank, source) values (?, ?, ?, ?) returning freq_key', $freq, 'Unknown', 'TBD', 'search')
	    ->hash->{freq_key};

        $entry = { label => 'Unknown',
                   bank  => 'TBD',
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
    my $duration = $read->length_seconds;
    $xmit->{duration} = $duration;
    $read->{handle}->close;    # http://www.perlmonks.org/bare/?node_id=946696

    if ($duration < 0.5) {
        $self->{app}->log->debug(sprintf('throwing away a short transmission: %.2f', $duration ));
        return;
    }

    $xmit->{xmit_key} = $self->{pg}->db->query(
        'insert into xmit_history (freq_key, source, file, duration) values (?, ?, ?, ?) returning xmit_key',
	    $xmit->{freq_key}, 'dongle1', $file, $duration
    )->hash->{xmit_key};

    $self->{cb}->($xmit);

}

sub watch {
    my ( $self, $msg ) = @_;

    $self->{cb} = $msg;

    my $notifier = new Linux::Inotify2;

    $self->{watcher} = $notifier->watch( '/home/pub/ham2mon/apps/wav', IN_CLOSE_WRITE,
        sub { $self->file_added(@_) } );

    my $io = AnyEvent->io(
        fh   => $notifier->{fd},
        poll => 'r',
        cb   => sub { $notifier->poll }
    );

    $self->{app}->log->debug('Watching new files for client');
    return $io;
}

sub unwatch {
    my $self = shift;

    $self->{watcher}->cancel;
}

sub get_freqs {
    my ($self, $mode) = @_;

    my $result;
    if ($mode eq 'Passed Frequencies') {
	$result = $self->{pg}->db->query(
	'select freq_key, freq, label, bank, pass from freqs where pass <> 0 order by freq desc'
	)->hashes->to_array;
    } else {
        $result = $self->{pg}->db->query(
	    'select freqs.freq_key, xmit_key, freq, label, bank, pass, file, round(extract(epoch from duration)::numeric,1) as duration from xmit_history, freqs where xmit_history.freq_key = freqs.freq_key order by xmit_key desc limit 10'
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

    return \@result;
}

sub set {
    my ( $self, $fields ) = @_;

    if (exists($fields->{pass})) {
	$self->set_pass( $fields->{freq_key}, $fields->{pass} );
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

sub set_pass {
    my ( $self, $freq_key, $pass ) = @_;

    $self->{app}->log->info(
	sprintf( 'change pass for %s to %s', $freq_key, $pass ) );

    $self->{pg}->db->query( 'UPDATE freqs SET pass=? WHERE freq_key = ?',
			          $pass, $freq_key );

    # now create blocklist for scanner
    open(my $fh, '>', '/home/pub/ham2mon/apps/lockout.txt')
	or die 	$self->{app}->log->error("Can't open > lockout.txt: $!");

    my $results = $self->{pg}->db->query( 'select freq from freqs where pass = 1 order by freq asc');
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
