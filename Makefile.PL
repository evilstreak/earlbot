use inc::Module::Install;

version '0.01';
name 'earlbot';

requires 'Bot::BasicBot';
requires 'URI::Find::Simple';
requires 'LWP::UserAgent';
requires 'Crypt::SSLeay';
requires 'POE::Kernel';
requires 'POE::Session';
requires 'Class::C3';
requires 'DBI';
requires 'Date::Format';
requires 'DBD::SQLite';
requires 'Config::General';
requires 'JSON';
requires 'File::Type';
requires 'Image::Size';
requires 'HTML::Entities';

WriteAll;
