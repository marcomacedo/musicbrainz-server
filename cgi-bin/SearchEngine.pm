#____________________________________________________________________________
#
#   MusicBrainz -- the open internet music database
#
#   Copyright (C) 1998 Robert Kaye
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
#   $Id$
#____________________________________________________________________________

package SearchEngine;

use vars qw(@ISA @EXPORT);
@ISA    = @ISA    = '';
@EXPORT = @EXPORT = '';

use strict;
use DBDefs;
use DBI;
use MusicBrainz;
use Text::Unaccent;
use Sql;
use locale;
use POSIX qw(locale_h);
use utf8;

sub new
{
    my $class = shift;
    my $dbh = shift;
    my $self = shift || {};
    bless $self, $class;

    $self->{DBH}          = $dbh;
    $self->{STH}          = undef;
    $self->{ValidTables}  = ['Album','Artist','Track'];
    $self->{Table}      ||= 'Artist';
    $self->{AllWords}   ||= 0;
    $self->{Limit}      ||= 0;
    $self->{BGColor}    ||= "#ffffff";
    return $self;
}

sub Table
{
    my ($self,$table) = @_;
    $self->{Table} = $table if defined $table;
    return $self->{Table};
}

sub AllWords
{
    my ($self,$allwords) = @_;
    $self->{AllWords} = $allwords if defined $allwords;
    return $self->{AllWords};
}

sub Limit
{
    my ($self,$limit) = @_;
    $self->{Limit} = $limit if defined $limit;
    return $self->{Limit};
}

sub Tokenize
{
    my $self  = shift;
    my $str = shift;
    
    # we set the locale here to a known quantity
    # so that accented characters are considered
    # "word characters" (\w)

    my $old_locale = setlocale(LC_CTYPE);
    setlocale( LC_CTYPE, "en_US.UTF-8" )
        or die "Couldn't change locale.";

    my @words = split /\s/, $str;

    my %seen =  ();
    foreach (@words) 
    {
        $_ = unac_string('UTF-8',$_);

        s/[^a-zA-Z]//g; # strip non words
        tr/A-Z/a-z/;
        next if $_ eq '';

        $seen{$_}++;
    }

    #switch it back, just to be polite
    setlocale( LC_CTYPE, $old_locale );
    
    #uniqify the word list
    @words = keys %seen;

    return @words;
}

sub AddWord
{
    my $self = shift;
    my $word = shift;

    my $sql = Sql->new($self->{DBH});
    if ($sql->Select(qq|SELECT Id FROM WordList WHERE Word = '$word'|))
    {
        my @row;
        
        if (@row = $sql->NextRow())
        {
            $sql->Finish();
            return $row[0];
        }
        return undef;
    }
    else
    {
        eval
        {
            $sql->Do(qq|INSERT into WordList (Word) VALUES ('$word')|);
        };
        if ($@)
        {
            return undef;
        }

        return $sql->GetLastInsertId('WordList');
    }
}

sub AddWordRefs 
{
    my $self = shift;
    my ($object_id,$name) = @_;
    my @words = $self->Tokenize($name);

    foreach (@words)
    {
        my $word_id = $self->AddWord ($_);
        next if not defined $word_id;

        my $sql = Sql->new($self->{DBH});
        eval 
        { 
           $self->{DBH}->{RaiseError} = 0;
           $sql->Do(qq|INSERT into $self->{Table}Words ($self->{Table}id, Wordid) 
                       VALUES($object_id,$word_id)|);
           $self->{DBH}->{RaiseError} = 1;
        };
        if ($@ && !($@ =~ /Duplicate/) ) 
        {
            print STDERR "Attempt to insert duplicate word ref.\n";
        }
    }
}

sub RemoveObjectRefs
{
    my $self = shift;
    my ($object_id) = @_;

    my $query;

    $query = "delete from " . $self->{Table} . "Words where " .
             $self->{Table} . "id = $object_id";
    my $sql = Sql->new($self->{DBH});
    $sql->Do($query);
}

sub GetQuery
{
    my $self = shift;
    my $search = shift;
    my ($query, $conditions);
    my @words = $self->Tokenize($search);

    my $where_clause = $self->GetWhereClause(@words);
    
    $conditions .= ("HAVING count(WordList.Id) = " . (scalar @words)) if $self->AllWords;

    if ($self->{Table} eq 'Album')
    {
        $query = "
        SELECT Album.id, Album.name, Artist.id, Artist.name, count(WordList.Id)
        FROM Album, AlbumWords, WordList, Artist
        WHERE $where_clause
        and AlbumWords.Wordid = WordList.Id
        and AlbumWords.Albumid = Album.Id
        and Artist.Id = Album.Artist
        GROUP BY Album.Id, Album.name, Artist.id, Artist.name 
        $conditions
        ORDER BY count(WordList.Id) desc, Album.name";
    }
    elsif ($self->{Table} eq 'Artist')
    {
        $query = "
        SELECT Artist.id, Artist.name, Artist.sortname, count(WordList.Id) 
        FROM Artist, ArtistWords, WordList
        WHERE $where_clause
        and ArtistWords.Wordid = WordList.Id
        and ArtistWords.Artistid = Artist.Id
        GROUP BY Artist.id, Artist.name, Artist.sortname
        $conditions
        ORDER BY count(WordList.Id) desc, Artist.sortname";
    }
    elsif ($self->{Table} eq 'Track')
    {
        $query = "
        SELECT Track.id, Track.name, Artist.id, Artist.name, AlbumJoin.album, count(WordList.Id)
        FROM Track, TrackWords, WordList, Artist, AlbumJoin
        WHERE $where_clause
        and TrackWords.Wordid = WordList.Id
        and TrackWords.Trackid = Track.Id
        and Track.Artist = Artist.id
        and AlbumJoin.Track = Track.Id
        GROUP BY Track.Id, Track.name, Artist.id, Artist.name, AlbumJoin.album 
        $conditions
        ORDER BY count(WordList.Id) desc, Track.name";
    }
    $query .= (" LIMIT " . $self->Limit) if  $self->Limit;
    return $query;
}
        
sub Search {
    my $self = shift;
    my $search = shift;

    $search =~ s/^\s+//;

    my $query = $self->GetQuery($search);

    $self->{STH} = Sql->new($self->{DBH});
    $self->{STH}->Select($query);
}

sub GetWhereClause
{
    my $self = shift;
    my @words = @_;
    my $where_clause = "WordList.Word ";
    if (scalar @words == 1)
    {
        $where_clause .= " = '" . $words[0] . "'";
    }
    else
    {
        $where_clause .= "IN ( '" . (join "','", @words) . "')";
    }
    return $where_clause;
}

sub RebuildIndex
{
    my $self = shift;
    my ($count, $written);
    
    my $sql = Sql->new($self->{DBH});
    $sql->Begin();
    $sql->Do("delete from " . $self->{Table} . "Words");
    $sql->Commit();

    # Make postgres analyze its foo to speed up the insertion
    $sql->AutoCommit();
    $sql->Do("vacuum analyze " . $self->{Table} . "Words");

    my $block_size = 5000;
    for($count = 0;; $count += $block_size)
    {

        $written = 0;
        # Start a transaction
        eval
        {
            print STDERR "Start transaction for $count -> " . ($count + $block_size) . "\n";
            $sql->Begin;
            $self->{DBH}->{AutoCommit} = 0;
        
            if ($sql->Select(qq|SELECT Id, Name
                              FROM $self->{Table}
                             LIMIT $block_size
                            OFFSET $count|))
            {
                while ( my $row = $sql->NextRowRef)
                {
                    print STDERR "Adding words for $self->{Table} $row->[0]: $row->[1]\n";
                    $self->AddWordRefs(@$row);
                    $written++;
                }
                $sql->Finish;
            }

            # And commit all the changes
            $sql->Commit;
            print STDERR "Commit transaction\n";
        };
        if ($@)
        {
            print STDERR "Index insert: $@\n";
        }

        # Make postgres analyze its foo to speed up the insertion
        print STDERR "Postgres: vacuum analyze WordList\n";
        $sql->AutoCommit();
        $sql->Do("vacuum analyze WordList");

        print STDERR "Postgres: analyze vacuum " . $self->{Table} . "Words\n";
        $sql->AutoCommit();
        $sql->Do("vacuum analyze " . $self->{Table} . "Words");

        if ($written < $block_size)
        {
            last;
        }
    }
}

sub RebuildAllIndices
{
    my $self = shift;
    my $orig_table = $self->{Table};
    
    my $sql = Sql->new($self->{DBH});
    $sql->Begin();
    $sql->Do("delete from WordList");
    $sql->Commit();

    # Make postgres analyze its foo to speed up the insertion
    print STDERR "Postgres: analyze vacuum\n";
    $sql->AutoCommit();
    $sql->Do("vacuum analyze");

    foreach my $table ( @{$self->{ValidTables}} )
    {
        $self->{'Table'} = $table;
        $self->RebuildIndex;
    }
    $self->{'Table'} = $orig_table;
}

sub Finish
{
    my $self = shift;
    $self->{STH}->Finish;
    $self->{STH} = undef;
}

sub Rows
{
    my $self = shift;
    $self->{STH}->Rows;
}

sub NextRow
{
    my $self = shift;
    return $self->{STH}->NextRowRef;
}

1;
