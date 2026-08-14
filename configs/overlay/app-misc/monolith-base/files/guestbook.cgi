#!/usr/bin/perl
# guestbook.cgi — a 1996-style guestbook: perl + CGI.pm for param()/header(),
# SQLite for storage. Proves the LAMP invariant (spec §4) on a disc where DBI
# / DBD::SQLite are deferred (see configs/portage/world's monolith-perl pin
# comment): this script does NOT `use DBI` — it shells out to the on-disc
# `sqlite3` CLI (dev-db/monolith-sqlite, P1) for both the INSERT and the
# SELECT, exactly the way a pre-DBI-era CGI script would have.
#
# Invocation (see scripts/boot-test.py smoke_guestbook):
#   REQUEST_METHOD=GET QUERY_STRING='name=Ada&message=Hello' \
#       perl /usr/lib/cgi-bin/guestbook.cgi
# Prints a text/plain CGI response whose body is the just-inserted row
# ("name|message"), read back from SQLite (not just echoed from @_), so the
# smoke test's assertion is a genuine round trip through the on-disc db file.
#
# GUESTBOOK_DB overrides the db path (default /tmp/guestbook.db — tmpfs,
# always writable regardless of how the root filesystem is mounted).
use strict;
use warnings;
use CGI;

my $DB = $ENV{GUESTBOOK_DB} || '/tmp/guestbook.db';

# Run one SQL statement against $DB via the sqlite3 CLI. List-form system()
# (no shell) — the only untrusted input is inside the SQL string itself,
# which the caller is responsible for quoting (see sql_quote below).
sub sqlite3_exec {
    for my $sql (@_) {
        system('sqlite3', $DB, $sql) == 0
            or die "sqlite3 exec failed (rc=$?) for: $sql\n";
    }
}

# Run a single SELECT and return its first row as a '|'-joined string, or
# '' if there were no rows. list-form open() (no shell).
sub sqlite3_query1 {
    my ($sql) = @_;
    open(my $fh, '-|', 'sqlite3', '-separator', '|', $DB, $sql)
        or die "sqlite3 query failed: $!\n";
    my $row = <$fh>;
    close $fh;
    chomp $row if defined $row;
    return defined $row ? $row : '';
}

# Single-quote-escape a value for embedding as a SQL string literal (double
# any embedded single quotes — the standard SQL escape, and all sqlite3
# needs here since every value is quoted, never interpolated as SQL syntax).
sub sql_quote {
    my ($v) = @_;
    $v =~ s/'/''/g;
    return "'$v'";
}

my $cgi  = CGI->new;
my $name = $cgi->param('name')    // 'anonymous';
my $msg  = $cgi->param('message') // '';

sqlite3_exec(
    'CREATE TABLE IF NOT EXISTS guestbook ('
        . 'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, message TEXT);',
    'INSERT INTO guestbook (name, message) VALUES ('
        . sql_quote($name) . ', ' . sql_quote($msg) . ');',
);

my $row = sqlite3_query1(
    'SELECT name, message FROM guestbook ORDER BY id DESC LIMIT 1;');

print $cgi->header('text/plain');
print "$row\n";
