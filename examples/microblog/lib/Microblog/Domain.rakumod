use RedSourcing;
use Red;
use RedSourcing::Journal;
use nqp;
unit module Microblog::Domain;

role InApplication does Event is export {
    has Str $.application-id is required
}

class UserRegistered does InApplication is export {
    has Str $.user-id;
    has Str $.name
}

class TweetPublished does InApplication is export {
    has Str $.user-id;
    has Str $.tweet-id;
    has Str $.text;
    has Str $.published-at
}

class UserFollowed does InApplication is export {
    has Str $.user-id;
    has Str $.author-id
}

class UserUnfollowed does InApplication is export {
    has Str $.user-id;
    has Str $.author-id
}

model TweetRecord is table(<microblog_tweet>) {
    has Str  $.application is id;
    has Str  $.tweet       is id;
    has Str  $.author      is column;
    has Str  $.body        is column;
    has Str  $.published   is column;
    has UInt $.position    is column;
    has      $.author-page is index({
        .application, .author, .position
    });
    has      $.application-page is index({
        .application, .position
    })
}

sub tweet-page (Str $application, @authors, Int :$before = 0, Int :$limit = 50 --> Hash) {
    die "limit must be between 1 and 100" unless 1 <= $limit <= 100;
    die "before must be nonnegative" if $before < 0;
    my $*RED-FALLBACK = False; # Paging must stay in SQL, never materialize the full table.
    my @selected-authors = @authors.unique;
    my $query = TweetRecord.^all.grep(*.application eq $application);
    $query = @selected-authors.elems == 1
        ?? $query.grep(*.author eq @selected-authors[0])
        !! $query.grep(-> $tweet { [OR] @selected-authors.map({ $tweet.author eq $_ }) });
    $query = $query.grep(*.position < $before) if $before;
    my @rows = $query.sort(-*.position).head($limit + 1).Array;
    my $more = @rows.elems > $limit;
    @rows.pop if $more;
    %(tweets => @rows.map({ %(id => .tweet, author => .author, text => .body,
        published-at => .published, cursor => .position.Int) }).Array,
        next => ($more ?? @rows.tail.position.Int !! Nil))
}

aggregate User is export {
    has Str $.application-id is entity-id;
    has Str $.user-id is entity-id;
    has Bool $.registered = False;
    has Str $.name        = "";
    has %.following;

    multi method APPLY (UserRegistered $e) {
        $!registered = True;
        $!name       = $e.name
    }

    multi method APPLY (TweetPublished $e) { }

    multi method APPLY (UserFollowed $e) {
        %!following{$e.author-id} = True
    }

    multi method APPLY (UserUnfollowed $e) {
        %!following{$e.author-id}:delete
    }

    method register (Str :$name!) is command {
        die "User already exists" if $!registered;
        die "Use a user ID containing 1–40 letters, digits, underscores or hyphens" unless $!user-id ~~ /^ <+[a..z A..Z 0..9 _ \-]> ** 1..40 $ /;
        my $clean = $name.trim;
        die "Name must contain 1–80 characters" unless 1 <= $clean.chars <= 80;
        self.user-registered(:name($clean));
        %(id => $!user-id, name => $!name)
    }

    method tweet (Str :$text!) is command {
        die "User does not exist" unless $!registered;
        my $clean = $text.trim;
        die "Tweet must contain 1–280 characters" unless 1 <= $clean.chars <= 280;
        my $id = nqp::sha1($!application-id ~ $!user-id ~ now.Str ~ (2 ** 63).rand.Str);
        self.tweet-published(:tweet-id($id), :text($clean), :published-at(DateTime.now.Str));
        %(id => $id)
    }

    method follow (Str :$author-id!) is command {
        die "User does not exist" unless $!registered;
        die "Cannot follow yourself" if $author-id eq $!user-id;
        die "Author does not exist" unless User.^with-ids(:application-id($!application-id), :user-id($author-id)).^load.registered;
        self.user-followed(:author-id($author-id)) unless %!following{$author-id}:exists;
        True
    }

    method unfollow (Str :$author-id!) is command {
        die "User does not exist" unless $!registered;
        die "Cannot unfollow yourself" if $author-id eq $!user-id;
        self.user-unfollowed(:author-id($author-id)) if %!following{$author-id}:exists;
        True
    }
}

class AccountReserved does InApplication {
    has Str $.user-id
}

aggregate Accounts is export {
    has Str $.application-id is entity-id;
    has %.registered;

    method APPLY (AccountReserved $e) {
        %!registered{$e.user-id} = True
    }

    method register-user (Str :$user-id!, Str :$name!) is command {
        die "User already exists" if %!registered{$user-id}:exists;
        my $user = User.^with-ids(:application-id($!application-id), :user-id($user-id));
        $user.^create;
        my $result = $user.register(:name($name));
        self.account-reserved(:user-id($user-id));
        $result
    }
}

projection TweetIndex is export {
    has Str $.application-id is entity-id;

    method APPLY (TweetPublished $e where {
        .application-id eq $!application-id
    }) is transactional {
        my $*RED-FALLBACK = False;
        my $record = TweetRecord.^find(:application($!application-id), :tweet($e.tweet-id));
        unless $record.defined {
            $record = TweetRecord.^create(:application($!application-id), :tweet($e.tweet-id),
                :author($e.user-id), :body($e.text), :published($e.published-at), :position($e.StoredEvent.id));
        }
        die "Conflicting tweet identity" unless $record.author eq $e.user-id
            && $record.body eq $e.text && $record.published eq $e.published-at
            && $record.position == $e.StoredEvent.id
    }
}

projection UserTweets is export {
    has Str $.application-id is entity-id;
    has Str $.user-id is entity-id;

    method APPLY (UserRegistered $e where {
        .application-id eq $!application-id && .user-id eq $!user-id
    }) { }

    method page (Int :$before = 0, Int :$limit = 50) {
        tweet-page($!application-id, [$!user-id], :before($before), :limit($limit))
    }
}

projection UserTimeline is export {
    has Str $.application-id is entity-id;
    has Str $.user-id is entity-id;
    has %.following;

    multi method APPLY (UserFollowed $e where {
        .application-id eq $!application-id && .user-id eq $!user-id
    }) {
        %!following{$e.author-id} = True
    }

    multi method APPLY (UserUnfollowed $e where {
        .application-id eq $!application-id && .user-id eq $!user-id
    }) {
        %!following{$e.author-id}:delete
    }

    method page (Int :$before = 0, Int :$limit = 50) {
        tweet-page($!application-id, [$!user-id, |%!following.keys.sort], :before($before), :limit($limit))
    }

    method follows {
        %!following.keys.sort.Array
    }
}

projection Directory is export {
    has Str $.application-id is entity-id;
    has %.users;

    method APPLY (UserRegistered $e where {
        .application-id eq $!application-id
    }) {
        %!users{$e.user-id} = $e.name
    }

    method list {
        %!users.keys.sort.map({ %(id => $_, name => %!users{$_}) }).Array
    }
}

sub seed (Str $application) is export {
    my $accounts     = Accounts.^with-ids(:application-id($application));
    my $known        = $accounts.^load;
    my Bool $new-ana = False;
    for <ana bruno clara> Z ["Ana Costa", "Bruno Lima", "Clara Alves"] -> ($id, $name) {
        my $user = User.^with-ids(:application-id($application), :user-id($id));
        unless $known.registered{$id}:exists {
            $new-ana = True if $id eq "ana";
            $accounts.register-user(:user-id($id), :name($name));
            $user.tweet(:text(do given $id {
                when "ana" {
                    "Uma ideia pequena também pode começar uma boa conversa."
                }
                when "bruno" {
                    "Café pronto. O que vocês estão construindo hoje?"
                }
                default {
                    "Um lugar para compartilhar o que está acontecendo, uma mensagem de cada vez."
                }
            }))
        }
    }
    User.^with-ids(:application-id($application), :user-id<ana>).follow(:author-id<bruno>) if $new-ana
}

sub rebuild-tweets (Str $application) is export {
    journal-do {
        my $*RED-FALLBACK = False;
        TweetRecord.^all.grep(*.application eq $application).delete;
        my $index       = TweetIndex.bless(:application-id($application));
        my UInt $cursor = 0;
        loop {
            my @ids = StoredEvent.^all.grep(*.id > $cursor)
                .sort(*.id).map(*.id).head(500).Array;
            last unless @ids;
            for @ids -> $id {
                my $record = StoredEvent.^all.grep(*.id == $id).head;
                if $record.class eq TweetPublished.^name && $record.data<application-id> eq $application {
                    $index.APPLY($record.COERCE(TweetPublished))
                }
                $cursor = $id.UInt
            }
        }
        True # Red 0.2.7 commits automatic transactions only on a defined result.
    }
}

sub initialize-tweets is export {
    TweetRecord.^create-table(:unless-exists);
    TweetRecord.^create-indexes;
    TweetIndex.^subscribe
}

sub initialize-application (Str $application) is export {
    my $accounts = Accounts.^with-ids(:application-id($application));
    journal-do { $accounts.^create unless StoredEvent.^all.grep(*.stream eq $accounts.^stream-name).head.defined }
}
