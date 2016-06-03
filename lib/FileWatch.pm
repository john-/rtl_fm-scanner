package Inotifier::Model::FileWatch;

use Linux::Inotify2;
use EV;
use AnyEvent;

use strict;
use warnings;

use Data::Dumper;

sub new {
    my ($class, $app) = @_;

    my $self = {
	app => $app,
    };

    return bless $self, $class;
}

sub file_added {
    my ( $self, $event ) = @_;

    my $file = $event->name;
    my ($freq) = $file =~ /(.*)_.*\.wav/;

    my @freq_list = @{ $self->{app}->defaults('freq_list') };
    ( my $entry ) = grep { $_->{freq} == $freq } @freq_list;

    #$self->{app}->log->debug(Dumper(@freq_list));

    if (! $entry ) { $entry = { label => $freq } }
    
    my $xmit = {
        'freq' => $freq,
        'file' => $file,
        'type' => 'audio',
        'stop' => time(),
	%$entry,
    };

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

1;
