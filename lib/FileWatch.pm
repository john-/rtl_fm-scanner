package Inotifier::Model::FileWatch;

use Linux::Inotify2;
use EV;
use AnyEvent;
use Mojo::Pg;

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
    };

    return bless $self, $class;
}

sub file_added {
    my ( $self, $event ) = @_;

    my $file = $event->name;

    unless (-e $event->fullname) {
	# there is code in ham2mon to delete wav files with header
	# only (44 bytes).
	$self->{app}->log->debug( sprintf('a header only file was removed by ham2mon: %s', $file) );
	return;
    }

    my ($freq) = $file =~ /(.*)_.*\.wav/;

    #  TODO:  this may be better as direct query of DB as 
    #my @freq_list = @{ $self->{app}->defaults('freq_list') };
    #( my $entry ) = grep { $_->{freq} == $freq } @freq_list;

    my $entry = $self->{pg}->db->query(
	'select freq_key, freq, label, bank, pass from freqs where freq = ? limit 1',
	$freq
	)->hash;    #  TODO: under what situations can there be more than one across scanned banks?

    $self->{app}->log->debug(Dumper($entry));

    if (! $entry ) {   # if no entry then create one
        $entry = { label => $freq }
    }
    
    my $xmit = {
        'freq' => $freq,
        'file' => $file,
        'type' => 'audio',
        'stop' => time(),
	%$entry,
    };

    $self->{cb}->($xmit);

    $self->{pg}->db->query(
        'INSERT INTO xmit_history (freq_key, source, start, stop) values (?, ?, to_timestamp(?), to_timestamp(?))',
	    $entry->{freq_key}, 'dongle1', $xmit->{stop}, $xmit->{stop}    # with approach probably no start time
    );
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

1;
