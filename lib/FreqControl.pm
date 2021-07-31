package FreqControl;

use strict;
use warnings;

use Mojo::Pg;
use Mojo::Pg::PubSub;
use Mojo::JSON qw(decode_json);

use Data::Dumper;

sub new {
    my ($class, $app) = @_;

    my $conf = $app->defaults->{config};

    my $pg = Mojo::Pg->new($conf->{pg})
	or $app->log->error('Could not connect to database');

    my $self = {
	app => $app,
	pg  => $pg,
    };

    bless $self, $class;

    $self->create_lockout;

    my $default_setup = $conf->{default_setup};
    my %setups = %{$conf->{setups}};
    $self->set_mode($setups{$default_setup});

    my $listener = $pg->pubsub->listen(audio => sub {
	my ($pubsub, $payload) = @_;

	my $msg = decode_json($payload);
        if ($msg->{detected_as} ne 'D') {   # This considers skip items as activity
	    $self->count_down();  # there is activity so reset the timer
        }
    });

    return $self;
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

    # tmux send-keys -t cart:ham2mon "/200.666" Enter
    my @args = ( 'tmux', 'send-keys', '-t', 'cart:ham2mon',
	       sprintf('"/%s"', $self->{freq}/1000000 ), 'Enter'
	  );
    system(@args) == 0
	or $self->{app}->log->error("system @args failed: $?");
}

sub count_down {
    my $self = shift;

    # maybe add modes.   For example stay on certain center point.

    if ($self->{idle_timer}) { Mojo::IOLoop->remove($self->{idle_timer}) }

    if ($self->{num_moves} == 0) { return }    # not iterating through a range

    my $rate = $self->{app}->defaults->{config}->{rate};

    $self->{idle_timer} = Mojo::IOLoop->recurring($rate => sub {
	$self->set_center;
        $self->{app}->log->debug(sprintf('hack timer fired after %d seconds', $rate ));
        $self->count_down;
    });

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
    if (exists($fields->{class})) {
        $self->{app}->log->info(
	    sprintf( 'change type for %s to %s', $fields->{xmit_key}, $fields->{class} ) );
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

    if ($self->{app}->defaults->{config}->{use_lockout}) {  # lockout if not using ML to filter
        my $results = $self->{pg}->db->query( 'select freq from freqs where pass = 1 and bank = any(?::text[]) order by freq asc', $self->{app}->defaults->{config}->{banks});
        while (my $next = $results->array) {
    	    print $fh "$next->[0]E6\n";
        }
    }

    close($fh);

    # poke the screen session with scanner to reload the blocklist
    system( 'tmux', 'send-keys', '-t', 'cart:ham2mon', '"l"' );
}

sub set_label {
    my ( $self, $freq, $bank, $label ) = @_;

    $self->{app}->log->info(
	sprintf( 'change label for %s (%s) to %s', $freq, $bank, $label ) );

    $self->{pg}->db->query( 'UPDATE freqs SET label=? WHERE freq = ? AND bank = ?',
			          $label, $freq, $bank );
}

1;
