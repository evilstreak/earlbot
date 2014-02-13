#!/usr/bin/perl
package Bot;
use base qw(Bot::BasicBot);
use warnings;
use strict;
use URI::Find::Simple qw( list_uris );
use LWP::UserAgent;
use Crypt::SSLeay;
use POE::Kernel;
use POE::Session;
use Class::C3;
use DBI;
use Date::Format;
use DBD::SQLite;
use Getopt::Long;
use Config::General;
use JSON qw( decode_json );
use File::Type;
use Image::Size;
use HTML::Entities;

my $configFile = 'earl.conf';
my $url;

GetOptions( "url=s" => \$url,
            "config=s" => \$configFile );

my $conf = new Config::General(
    -ConfigFile => $configFile,
    -AutoTrue   => 1,
);
my %config = $conf->getall;

# Some shared things
my $ft = File::Type->new();
$Image::Size::NO_CACHE = 1;

my $ua = LWP::UserAgent->new;
$ua->timeout(20);
if (defined $config{'acceptlang'}) {
	$ua->default_header('Accept-Language' => $config{'acceptlang'});
}

# 64K ought to be enough for anybody? Apparently 32 isn't for BBC to finish HEAD.
# TODO: Configurable?
my $max_ret_size = 48*1024;
my $ua_limited = $ua->clone;
$ua_limited->max_size($max_ret_size);
$ua_limited->default_header("Range" => "bytes=0-$max_ret_size");


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

sub canonicalize {
  my ($url, $response_ref) = @_;

  # TODO: Add support for link HTTP Header?
  if ( my $link = $$response_ref->header( 'Link' ) ) {
    # Seriously, what kind of format is this?
    if ( $link =~ m'<([^>]+)>; rel="canonical"') {
	  $url = $1;
    }
  }

  return $url;

}

sub get_data {
  my $url = shift;

  my $response = $ua_limited->get($url);

  # Servers that don't like range
  $response = $ua->get($url) if $response->code >= 400 and $response->code < 500 and $response->code != 404;

  return \$response;
}

sub get_img_title {
  my $data_ref = shift;

  my ($x, $y, $type) = imgsize($data_ref);

  return "$type ($x x $y)" if $x and $y;
}

sub title {
  my $response_ref = shift;
  my $title = decode_entities($$response_ref->header('Title'));

  $title =~ s/^\s+|\s+$//g;

  return $title;
}

sub get_response {
  my $url = shift;

  # Convert ajax URLs to non-js URLs (e.g. Twitter)
  # http://googlewebmastercentral.blogspot.com/2009/10/proposal-for-making-ajax-crawlable.html
  $url =~ s/#!/\?_escaped_fragment_=/;
  $url =~ s#(//i.imgur.com/[^.]+)\.[^.]+$#$1#;

  # Twitter status: screen name and tweet
  if ( $url =~ m'^https?://twitter.com/(?:\?_escaped_fragment_=/)?\w+/status(?:es)?/(\d+)$' ) {
    return ($url, get_tweet( $1 ));
  } else {
    my $response_ref = get_data($url);
	return unless $$response_ref->is_success;

	my $data = $$response_ref->decoded_content;
    my $mime_type = $ft->checktype_contents($data);

    $url = canonicalize($url, $response_ref);

    if ( $mime_type =~ m'^image/' ) {
      return ($url, get_img_title(\$data));
    }
    # BBC News article: headline and summary paragraph
    elsif ( $url =~ m'^http://www\.bbc\.co\.uk/news/[-a-z]*-\d{7,}$' ) {
      my $headline = $$response_ref->header( 'X-Meta-Headline' );
      my $summary = $$response_ref->header( 'X-Meta-Description' );
      return ($url, "$headline \x{2014} $summary");
    }
    # Everything else: the title
    elsif ( my $title = title( $response_ref ) ) {
      return ($url, $title);
    }
  }
}

sub get_tweet {
  my ( $id ) = @_;

  my $url = "https://api.twitter.com/1.1/statuses/show/$id.json";

  my $auth = 'Bearer ' . $config{ 'twittertoken' };
  my $response = $ua->get( $url, 'Authorization' => $auth );
  return unless $response->is_success;

  my $json = decode_json( $response->decoded_content );

  return join( " \x{2014} ", $json->{user}{screen_name}, $json->{text} );
}

sub said {
  my ( $self, $args ) = @_;

  return if $self->ignore_nick($args->{who});

  for $url ( list_uris( $args->{body} ) ) {
    next unless $url =~ /^http/i;

    if ( my ($url, $reply) = get_response( $url ) ) {
      next unless $url and $reply;

      # Sanitise the reply to only include printable chars
      $reply =~ s/[^[:print:]]//g;

      # Strip unicode of death for Core Text on Macs
      $reply =~ s/\x{062e} \x{0337}\x{0334}\x{0310}\x{062e}//g;

      # See if this has been posted before, unless it's a whitelisted URL
      my $neverolde = $config{ 'neverolde' } || '^$';
      my %result = log_uri( $url, $args->{channel}, $args->{who} ) unless $url =~ m/$neverolde/i;
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

    $channel =~ s/^#//; # Because Config::General uses hash as a comment
    push @{$config{'server'}{$self->{server}}{'channel'}}, $channel;
    Config::General::SaveConfig($configFile, \%config);
}

sub irc_kick_state {
    my ( $self, $who, $channel, $kernel ) = @_[ OBJECT, ARG0, ARG1, KERNEL ];
    $self->log("irc_kick_state: $who, $channel");

    $channel =~ s/^#//; # Because Config::General uses hash as a comment

    my $channels = $config{'server'}{$self->{server}}{'channel'};
    $config{'server'}{$self->{server}}{'channel'} = [ grep { $_ ne $channel } @$channels ];

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

sub upgrade_config {
  my ( $class, $config ) = @_;

  foreach my $server_config ( values %{$config->{'server'} } ) {
    # Update config from
    #   <channel><foo></foo><bar></bar></channel>
    # to same for mas
    #   channel foo
    #   channel bar
    my $ref = ref $server_config->{channel};
    if ( $ref eq 'HASH' ) {
       $server_config->{channel} = [ keys %{$server_config->{channel}} ];
    }
    elsif ( !$ref ) {
       $server_config->{channel} = [ $server_config->{channel} ];
    }
  }
}

package main;
use POSIX qw( setsid );

Bot->upgrade_config( \%config );

if (defined $url) {
    my ($url, $response) = Bot::get_response( $url );
    die $url, " - ", $response;
}

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

    my @channelNames = map { '#'.$_ } @{ $server->{channel} };

    my $bot = Bot->new (
      server    => $host,
      nick      => $server->{nick},
      channels  => \@channelNames,
      charset   => 'utf-8',
    );
    $bot->run((@servers > 0));
}
