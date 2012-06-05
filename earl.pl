#!/usr/bin/perl
package Bot;
use base qw(Bot::BasicBot);
use warnings;
use strict;
use URI::Title qw( title );
use URI::Find::Simple qw( list_uris );
use LWP::Simple;
use Crypt::SSLeay;
use HTML::HeadParser;
use POE::Kernel;
use POE::Session;
use Class::C3;
use DBI;
use Date::Format;
use DBD::SQLite;
use Config::General;
use WWW::Shorten "TinyURL";

my $configFile = 'earl.conf';
my $conf = new Config::General(
    -ConfigFile => $configFile,
    -AutoTrue   => 1,
);
my %config = $conf->getall;

sub ignore_nick {
  my ($self, $nick) = @_;

  # ignore the CIA announce bots from Github etc
  return 1 if $nick =~ /^CIA-\d+$/;

  # ignore robonaut
  return 1 if $nick =~ /^robonaut$/;

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

  # Create sessions to respond to irc_invite/kick messages
  POE::Session::_register_state($session, "irc_invite", $self, "irc_invite_state");
  POE::Session::_register_state($session, "irc_kick", $self, "irc_kick_state");
}

sub get_response {
  my $url = shift;
  my $head = HTML::HeadParser->new;

  # Convert ajax URLs to non-js URLs (e.g. Twitter)
  # http://googlewebmastercentral.blogspot.com/2009/10/proposal-for-making-ajax-crawlable.html
  $url =~ s/#!/\?_escaped_fragment_=/;

  # BBC News article: headline and summary paragraph
  if ( $url =~ m'^http://www\.bbc\.co\.uk/news/[-a-z]*-\d{7,}$' ) {
    $head->parse( get( $url ) );
    my $headline = $head->header( 'X-Meta-Headline' );
    my $summary = $head->header( 'X-Meta-Description' );
    return "$headline \x{2014} $summary";
  }
  # Twitter status: screen name and tweet
  elsif ( $url =~ m'^https?://twitter.com/(\?_escaped_fragment_=/)?\w+/status(?:es)?/\d+$' ) {
    $head->parse( get( $url ) );
    my $name = $head->header( 'X-Meta-Page-user-screen_name' );
    my $tweet = $head->header( 'X-Meta-Description');
    return "$name \x{2014} $tweet";
  }
  # Everything else: the title
  elsif ( my $title = title( $url ) ) {
    return $title;
  }
}

sub said {
  my ( $self, $args ) = @_;

  return if $self->ignore_nick($args->{who});

  for my $uri ( list_uris( $args->{body} ) ) {
    next unless $uri =~ /^http/i;

    if ( my $reply = get_response( $uri ) ) {
      # Sanitise the reply to only include printable chars
      $reply =~ s/[^[:print:]]//g;

      # See if this has been posted before, unless it's a whitelisted URL
      my $neverolde = $config{ 'neverolde' } || '^$';
      my %result = log_uri( $uri, $args->{channel}, $args->{who} ) unless $uri =~ m/$neverolde/i;
      my $olde = '';
      if (%result) {
        $olde = ' (First posted by '.$result{'nick'}.', '.time2str('%C', $result{'timestamp'}).')';
      }

      if (length($uri) > 60 and $config{tinyurl}) {
	my $short = makeashorterlink($uri);
	if ($short) {
	  $reply .= " [ $short ]";
	}
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

    $channel =~ s/^#//; # Because Config::General uses hash as a comment
    $config{'server'}{$self->{server}}{'channel'}{$channel} = {};
    Config::General::SaveConfig($configFile, \%config);
}

sub irc_kick_state {
    my ( $self, $who, $channel, $kernel ) = @_[ OBJECT, ARG0, ARG1, KERNEL ];
    $self->log("irc_kick_state: $who, $channel");

    $channel =~ s/^#//; # Because Config::General uses hash as a comment
    delete $config{'server'}{$self->{server}}{'channel'}{$channel};
    Config::General::SaveConfig($configFile, \%config);
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

if (!defined $config{'detach'} || $config{'detach'}) {

    open STDIN, '/dev/null'    or die "Can't read /dev/null: $!";
    open STDOUT, '>>/dev/null' or die "Can't write to /dev/null: $!";
    open STDERR, '>>/dev/null' or die "Can't write to /dev/null: $!";
    defined(my $pid = fork)    or die "Can't fork: $!";
    exit if $pid;
    setsid                     or die "Can't start a new session: $!";
    umask 0;
}

my @servers = keys %{$config{'server'}};

while (my $host = shift @servers) {
    my $server = $config{'server'}->{$host};

    my @channelNames = keys %{$server->{channel}};
    @channelNames = map { '#'.$_ } @channelNames;

    my $bot = Bot->new (
      server    => $host,
      nick      => $server->{nick},
      channels  => \@channelNames,
      charset   => 'utf-8',
    );
    $bot->run((@servers > 0));
}
