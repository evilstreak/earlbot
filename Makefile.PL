use inc::Module::Install;

version '0.01';
name 'earlbot';

requires 'Bot::BasicBot';
requires 'URI::Title';
requires 'URI::Find::Simple';
requires 'LWP::Simple';
requires 'Crypt::SSLeay';
requires 'HTML::HeadParser';
requires 'POE::Kernel';
requires 'POE::Session';
requires 'Class::C3';
requires 'DBI';
requires 'Date::Format';
requires 'DBD::SQLite';
requires 'Config::General';
requires "WWW::Shorten";

install_script	'earl.pl';

WriteAll;
