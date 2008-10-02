package MusicBrainz::Server::Controller::Search;

use strict;
use warnings;

use base 'Catalyst::Controller';

=head1 NAME

MusicBrainz::Server::Controller::Search - Handles searching the database

=head1 DESCRIPTION

This control handles searching the database for various data, such as
artists and releases, but also MusicBrainz specific data, such as editors
and tags.

=head1 METHODS

=head2 simple

Handle a "simple" search which has a type and a query. This then redirects
to whichever specific search action the search type maps to.

=cut

sub simple : Local
{
    my ($self, $c) = @_;

    use MusicBrainz::Server::Form::Search::Simple;

    my $form = $c->form(undef, "Search::Simple");

    if(!$form->validate($c->req->query_params))
    {
        $c->response->redirect($c->request->referer);
        $c->detach;
    }

    my ($type, $query) = (  $form->value('type'),
                            $form->value('query')   );

    $c->session->{last_simple_search} = $type;

    # Use the 'editor' action for searching for moderators,
    # otherwise search using the external search engine
    if ($type eq 'editor')
    {
        $c->detach("editor", [ $query ]);
    }
    else
    {
        $c->detach("external");
    }
}

=head2 editor

Serach for a MusicBrainz database.

This search is performed right in this action, and is not dispatched to
one of the MusicBrainz search servers. It searches for a moderator with
the exact name given, and if found, redirects to their profile page. If
no moderator could be found, the user is informed.

=cut

sub editor : Private
{
    my ($self, $c, $query) = @_;

    my $user = $c->model('User')->load({ username => $query });

    if(defined $user)
    {
        $c->response->redirect($c->uri_for('/user/profile', $user->name));
        $c->detach;
    }
    else
    {
        $c->stash->{could_not_find_user} = 1;
        $c->stash->{query} = $query;
        $c->stash->{template} = 'search/editor.tt';
    }
}

=head2 external

Search using an external search engine (currently Lucene, but moving
towards Xapian).

=cut

sub external : Local
{
    my ($self, $c) = @_;

    my $form = $c->form(undef, 'Search::External');

    return unless $form->validate($c->req->query_params);

    use URI::Escape qw( uri_escape );
    use POSIX qw(ceil floor);

    my $type   = $form->value('type');
    my $query  = $form->value('query');
    my $offset = $c->request->query_params->{offset} || 0;
    my $limit  = $form->value('limit') || 25;

    if ($query eq '!!!' and $type eq 'artist')
    {
        $query = 'chkchkchk';
    }

    unless ($form->value('enable_advanced'))
    {
        use MusicBrainz::Server::LuceneSearch;
        
        $query = MusicBrainz::Server::LuceneSearch::EscapeQuery($query);

        if ($type eq 'artist')
        {
            $query = "artist:($query)(sortname:($query) alias:($query) !artist:($query))";
        }
    }

    $query = uri_escape($query);
    
    my $search_url = sprintf("http://%s/ws/1/%s/?query=%s&offset=%s&max=%s",
                                 DBDefs::LUCENE_SERVER,
                                 $type,
                                 $query,
                                 $offset,
                                 $limit,);
    use LWP::UserAgent;
    
    my $ua = LWP::UserAgent->new;
    $ua->timeout (2);
    
    if (DBDefs::PROXY_ENABLE)
    {
        $ua->proxy([ 'http' ], sprintf('http://%s:%i', DBDefs::PROXY_HOST, DBDefs::PROXY_PORT));
    }

    # Dispatch the search request.
    my $response = $ua->get($search_url);
    unless ($response->is_success)
    {
        # Something went wrong with the search
        my $template = 'search/error/';

        # Switch on the response code to decide which template to provide
        use Switch;
        switch ($response->code)
        {
            case 404 { $template .= 'no-results.tt'; }
            case 403 { $template .= 'no-info.tt'; };
            case 500 { $template .= 'internal-error.tt'; }
            case 400 { $template .= 'invalid.tt'; }

            else { $template .= 'general.tt'; }
        }

        $c->stash->{content}  = $response->content;
        $c->stash->{query}    = $query;
        $c->stash->{type}     = $type;
        $c->stash->{template} = $template;

        $c->detach;
    }
    else
    {
        my $results = $response->content;

        # Because this branch has a different url scheme, we need to
        # update the URLs.
        # TODO Update when this branch is live in Xapian's code base.
        $results =~ s/\.html//g;

        # Parse information about total results
        my ($redirect, $total_hits);
        if ($results =~ /<!--\s+(.*?)\s+-->/s)
        {
            my $comments = $1;
            
            use Switch;
            foreach my $comment (split(/\n/, $comments))
            {
                my ($key, $value) = split(/=/, $comment, 2);

                switch ($key)
                {
                    case ('hits')     { $total_hits = $value; }
                    case ('redirect') { $redirect   = $value; }
                }
            }
        }

        # If the user searches for annotations, they will get the results in wikiformat - we need to
        # convert this to HTML.
        while ($results =~ /%WIKIBEGIN%(.*?)%WIKIEND%/s) 
        {
            use Text::WikiFormat;
            use DBDefs;

            my $temp = Text::WikiFormat::format($1, {}, { prefix => "http://".DBDefs::WIKITRANS_SERVER, extended => 1, absolute_links => 1, implicit_links => 0 });
            $results =~ s/%WIKIBEGIN%(.*?)%WIKIEND%/$temp/s;
        } 

        if ($redirect && $total_hits == 1 &&
            ($type eq 'artist' || $type eq 'release' || $type eq 'label'))
        {
            my $type_controller = $c->controller($type);
            my $action = $type_controller->action_for('show');

            $c->res->redirect($c->uri_for($action, [ $redirect ]));
            $c->detach;
        }

        my $total_pages = ceil($total_hits / $limit);

        $c->stash->{current_page} = floor($offset / $limit) + 1;
        $c->stash->{total_pages}  = $total_pages;
        $c->stash->{offset}       = $offset;
        $c->stash->{total_hits}   = $total_hits;
        $c->stash->{results}      = $results;

        $c->stash->{url_for_page} = sub {
            my $page_number = shift;
            $page_number    = $page_number - 1;

            my $new_offset  = $page_number * $limit;

            my $min_offset  = 0;
            my $max_offset  = ($c->stash->{total_pages} - 1) * $limit;

            $new_offset = $new_offset < $min_offset ? $min_offset
                        : $new_offset > $max_offset ? $max_offset
                        :                             $new_offset;

            my $query = $c->req->query_params;
            $query->{offset} = $page_number * $limit;

            $c->uri_for('/search/external', $query);
        };
    }
}

=head1 LICENSE

This software is provided "as is", without warranty of any kind, express or
implied, including  but not limited  to the warranties of  merchantability,
fitness for a particular purpose and noninfringement. In no event shall the
authors or  copyright  holders be  liable for any claim,  damages or  other
liability, whether  in an  action of  contract, tort  or otherwise, arising
from,  out of  or in  connection with  the software or  the  use  or  other
dealings in the software.

GPL - The GNU General Public License    http://www.gnu.org/licenses/gpl.txt
Permits anyone the right to use and modify the software without limitations
as long as proper  credits are given  and the original  and modified source
code are included. Requires  that the final product, software derivate from
the original  source or any  software  utilizing a GPL  component, such  as
this, is also licensed under the GPL license.

=cut

1;
