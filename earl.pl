#!/usr/bin/perl
package Bot;
use base qw(Bot::BasicBot);
use warnings;
use strict;
use URI::Title qw( title );
use URI::Find::Simple qw( list_uris );
use LWP::Simple;
use HTML::HeadParser;
use POE::Kernel;
use POE::Session;
use Class::C3;
use DBI;
use Date::Format;
use DBD::SQLite;

sub ignore_nick {
  my ($self, $nick) = @_;

  # ignore the CIA announce bots from Github etc
  return 1 if $nick =~ /^CIA-\d+$/;

  $self->next::method($nick);
}

sub run {
  my ($self, $no_run) = @_;

  $self->{no_run} = $no_run;

  $self->next::method();
}

sub start_state {
  my ($self, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];

  $self->next::can->(@_);

  # And create another session to respond to irc_invite messages
  POE::Session::_register_state($session, "irc_invite", $self, "irc_invite_state");
}

sub get_response {
  my $url = shift;
  my $head = HTML::HeadParser->new;

  # BBC News article: headline and summary paragraph
  if ( $url =~ m'^http://news\.bbc\.co\.uk/.*/\d{7,}\.stm$' ) {
    $head->parse( get( $url ) );
    my $headline = $head->header( 'X-Meta-Headline' );
    my $summary = $head->header( 'X-Meta-Description' );
    return "$headline — $summary";
  }
  # Twitter status: screen name and tweet
  elsif ( $url =~ m'^http://twitter.com/\w+/status(?:es)?/\d+$' ) {
    $head->parse( get( $url ) );
    my $name = $head->header( 'X-Meta-Page-user-screen_name' );
    my $tweet = $head->header( 'X-Meta-Description');
    return "$name — $tweet";
  }
  # Everything else: the title
  elsif ( my $title = title( $url ) ) {
    return $title;
  }
}

sub said {
  my ( $self, $args ) = @_;

  return if $self->ignore_nick($args->{who});

  for ( list_uris( $args->{body} ) ) {
    next unless $_ =~ /^http/i;

    if ( my $reply = get_response( $_ ) ) {
      # Sanitise the reply to only include printable chars
      $reply =~ s/[^[:print:]]//g;

      # See if this has been posted before
      my %result = log_uri( $_, $args->{channel}, $args->{who} );
      my $olde = '';
      if (%result) {
        $olde = ' (First posted by '.$result{'nick'}.', '.time2str('%C', $result{'timestamp'}).')';
      }

      # Make sure the reply fits in one IRC message
      my $maxLen = 250 - length($olde);
      if (length($reply) > $maxLen) {
        $reply = substr($reply, 0, $maxLen) . '...';
      }

      $self->reply( $args, "[ $reply ]$olde" );
    }
  }
}

sub irc_invite_state {
    my ( $self, $who, $channel, $kernel ) = @_[ OBJECT, ARG0, ARG1, KERNEL ];
    $self->log("irc_invite_state: $who, $channel");

    $kernel->call( $self->{IRCNAME}, 'join', $self->charset_encode($channel) );
    $self->emote(
      channel => $channel,
      body => "was invited by " . $self->nick_strip($who)
    );
}

my $dbh;
sub log_uri {
    my ( $uri, $channel, $nick ) = @_;

    if (!$dbh) {
      $dbh = DBI->connect( "dbi:SQLite:earl.db") or die ("$DBI::errstr");
      
      my $info = $dbh->table_info('', '', 'uri');
      if (!$info->fetch) {
        $dbh->do(
          "CREATE TABLE uri (
            uri string, nick string, channel string, timestamp int,
            PRIMARY KEY(uri, channel)
          );"
        );
      }

    }

    my $row = $dbh->selectrow_hashref (
      "SELECT nick, timestamp FROM uri WHERE uri = ? AND channel = ?;",
      {}, $uri, $channel
    );
    return %$row if $row;

    my $result = $dbh->do (
      "INSERT INTO uri (uri, nick, timestamp, channel) VALUES (?,?,?,?);",
      {}, $uri, $nick, time(), $channel
    );

    return ();
}

package main;
use POSIX qw( setsid );

open STDIN, '/dev/null'    or die "Can't read /dev/null: $!";
open STDOUT, '>>/dev/null' or die "Can't write to /dev/null: $!";
open STDERR, '>>/dev/null' or die "Can't write to /dev/null: $!";
defined(my $pid = fork)    or die "Can't fork: $!";
exit if $pid;
setsid                     or die "Can't start a new session: $!";
umask 0;

my $freenode_bot = Bot->new(
  server => "irc.freenode.net",
  channels => [ '#juicejs', '#flusspferd', '#london-hack-space', '#hackspace', '#pubstandards' ],
  nick => 'earlbot',
  charset => 'utf-8'
);
$freenode_bot->run(1);

Bot->new(
  server => "irc.afternet.org",
  channels => [ '#randomnine' ],
  nick => 'earl',
  charset => 'utf-8'
)->run();
