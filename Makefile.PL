use inc::Module::Install;

version '0.01';
name 'earlbot';

requires 'Bot::BasicBot';
requires 'URI::Title';
requires 'URI::Find::Simple';
requires 'LWP::Simple';
requires 'HTML::HeadParser';
requires 'POE::Kernel';
requires 'POE::Session';
requires 'Class::C3';
requires 'DBI';
requires 'Date::Format';
requires 'DBD::SQLite';
requires 'Config::General';

WriteAll;
