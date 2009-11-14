#!/usr/bin/perl
package Bot;
use base qw(Bot::BasicBot);
use warnings;
use strict;
use URI::Title qw( title );
use URI::Find::Simple qw( list_uris );
use LWP::Simple;
use HTML::HeadParser;

sub get_response {
  my $url = shift;
  my $head = HTML::HeadParser->new;

  # BBC News article: headline and summary paragraph
  if ( $url =~ m'^http://news\.bbc\.co\.uk/.*/\d{7,}\.stm$' ) {
    $head->parse( get( $url ) );
    my $headline = $head->header( 'X-Meta-Headline' );
    my $summary = $head->header( 'X-Meta-Description' );
    return "[ $headline — $summary ]";
  }
  # Twitter status: screen name and tweet
  elsif ( $url =~ m'^http://twitter.com/\w+/status/\d+$' ) {
    $head->parse( get( $url ) );
    my $name = $head->header( 'X-Meta-Page-user-screen_name' );
    my $tweet = $head->header( 'X-Meta-Description');
    return "[ $name — $tweet ]";
  }
  # Everything else: the title
  elsif ( my $title = title($url) ) {
    return "[ $title ]";
  }
}

sub said {
  my ( $self, $message ) = @_;
  for ( list_uris( $message->{body} ) ) {
    if ( my $reply = get_response( $_ ) ) {
      $self->reply( $message, $reply );
    }
  }
}

package main;
use POSIX qw( setsid );

chdir '/'                  or die "Can't chdir to /: $!";
open STDIN, '/dev/null'    or die "Can't read /dev/null: $!";
open STDOUT, '>>/dev/null' or die "Can't write to /dev/null: $!";
open STDERR, '>>/dev/null' or die "Can't write to /dev/null: $!";
defined(my $pid = fork)    or die "Can't fork: $!";
exit if $pid;
setsid                     or die "Can't start a new session: $!";
umask 0;

my $freenode_bot = Bot->new(
  server => "irc.freenode.net",
  channels => [ '#juicejs', '#london-hack-space' ],
  nick => 'earl',
);
$freenode_bot->{no_run} = 1;
$freenode_bot->run();

Bot->new(
  server => "irc.afternet.org",
  channels => [ '#randomnine' ],
  nick => 'earl',
)->run();
