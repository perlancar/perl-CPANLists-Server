package App::cpanlists::Server;

use 5.010001;
use strict;
use warnings;
use Log::Any qw($log);

# VERSION

use JSON;
use MetaCPAN::API;
#use Perinci::Sub::Util qw(wrapres);
use SHARYANTO::SQL::Schema 0.04;

# TODO: use CITEXT columns when migrating to postgres 9.1+

our %SPEC;
my $json = JSON->new->allow_nonref;

my $mcpan = MetaCPAN::API->new;

my $spec = {
    latest_v => 1,

    install => [
        q[CREATE TABLE "user" (
            id SERIAL PRIMARY KEY,
            -- roles TEXT[],
            username VARCHAR(64) NOT NULL, UNIQUE(username),
            first_name VARCHAR(128),
            last_name VARCHAR(128),
            email VARCHAR(128), UNIQUE(email),
            password VARCHAR(255) NOT NULL,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            -- XXX is_suspended BOOL,
            note TEXT
        )],

        q[CREATE TABLE list (
            id SERIAL PRIMARY KEY,
            creator INT NOT NULL REFERENCES "user"(id),
            name VARCHAR(255) NOT NULL, UNIQUE(name), -- citext
            -- XXX type: module, author
            description TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE item (
            id SERIAL PRIMARY KEY,
            name VARCHAR(255) NOT NULL, UNIQUE(name),
            summary TEXT,
            note TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE list_item (
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            item_id INT NOT NULL REFERENCES item(id), UNIQUE(list_id, item_id),
            comment TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE list_comment (
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL, UNIQUE(list_id, name),
            comment TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE list_like (
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            user_id INT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            UNIQUE(item_id, user_id),
            -- XXX UNIQUE(user_id),
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE activity_log (
            user_id INT REFERENCES "user"(id),
            action VARCHAR(32),
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ip INET,
            note TEXT
        )],
    ],
};

sub __dbh {
    state $dbh;
    if (@_) {
        $dbh = $_[0];
    }
    $dbh;
}

sub __env {
    state $env;
    if (@_) {
        $env = $_[0];
    }
    $env;
}

sub __init_db {
    SHARYANTO::SQL::Schema::create_or_update_db_schema(
        dbh => __dbh, spec => $spec,
    );
}

sub __activity_log {
    my %args = @_;

    if (__dbh()->do(q[INSERT INTO activity_log (ip,action,"user_id",note) VALUES (?,?,?,?)],
             {},
             (__env() ? __env->{REMOTE_ADDR} : $ENV{REMOTE_ADDR}),
             $args{action},
             (__env() ? __env->{"cpanlists.user_id"} : undef),
             (ref($args{note}) ? $json->encode($args{note}) : $args{note}),
            )) {
        return 1;
    } else {
        $log->error("Can't log activity: ".__dbh->errstr);
        return 0;
    }
}

my $sch_username = ['str*' => {
    # temporarily disabled because perl 5.12 stringifies regex differently and
    # unsupported by 5.10.
    # match => qr/\A\w+\z/,
    min_len => 4,
    max_len => 32,
}];
my $sch_password = ['str*' => min_len=>6, max_len=>72];
#my $sch_ip = ['str*' => {
#    # temporarily disabled because perl 5.12 stringifies regex differently and
#    # unsupported by 5.10.
#    # match => qr/\A\d{1,3}+\.\d{1,3}+\.\d{1,3}+\.\d{1,3}+\z/,
#}];

$SPEC{create_user} = {
    v => 1.1,
    args => {
        username => {
            schema => $sch_username,
            req => 1,
        },
        email => {
            schema => ['str*', {
                # match => qr/\A\S+\@\S+\z/,
            }],
            req => 1,
        },
        password => {
            schema => $sch_password,
            req => 1,
        },
        first_name => {
            schema => ['str'],
        },
        last_name => {
            schema => ['str'],
        },
        note => {
            schema => ['str'],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub create_user {
    require Authen::Passphrase::BlowfishCrypt;

    my %args = @_; # VALIDATE_ARGS

    # TMP
    $args{username} =~ /\A\w+\z/ or return [400, "Invalid username syntax"];

    my $ppr = Authen::Passphrase::BlowfishCrypt->new(cost=>8, salt_random=>1, passphrase=>$args{password});

    __dbh->begin_work;
    my $err;
    {
        __dbh->do(q[INSERT INTO "user" (username,email,password, first_name,last_name, note) VALUES (?,?,?, ?,?, ?)],
                  {},
                  $args{username}, $args{email}, $ppr->as_crypt,
                  $args{first_name}, $args{last_name},
                  $args{note},
              ) or do {
                  $err = [500, "Can't create user: " . __dbh->errstr];
                  last;
              };
    }
    __activity_log(action => 'create user', note => {username=>$args{username}}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK", { id=>__dbh->last_insert_id(undef, undef, "user", undef) }];
}

$SPEC{get_user} = {
    v => 1.1,
    summary => 'Get user information either by email or username',
    args => {
        username => {
            schema => ['str*'],
        },
        email => {
            schema => ['str*'],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub get_user {
    my %args = @_; # VALIDATE_ARGS
    # TMP, schema
    $args{username} || $args{email}
        or return [400, "Please specify either email/username"];
    my $row;
    if ($args{username}) {
        $row = __dbh->selectrow_hashref(q[SELECT * FROM "user" WHERE username=?], {}, $args{username});
    } else {
        $row = __dbh->selectrow_hashref(q[SELECT * FROM "user" WHERE email=?], {}, $args{email});
    }

    return [404, "No such user"] unless $row;

    # delete sensitive fields
    delete $row->{password};
    #delete $row->{id} unless ...;

    [200, "OK", $row];
}

$SPEC{auth_user} = {
    v => 1.1,
    summary => 'Check username and password against database',
    args => {
        username => {
            # for auth, we don't need elaborate schemas
            #schema => $sch_username,
            schema => ['str*'],
            req => 1,
        },
        password => {
            # for auth, we don't need elaborate schemas
            #schema => $sch_password,
            schema => ['str*'],
            req => 1,
        },
    },
    description => <<'_',

Upon success, will return a hash of information, currently: `id` (user numeric
ID), `email`.

_
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub auth_user {
    require Authen::Passphrase;

    my %args = @_; # VALIDATE_ARGS

    my $row = __dbh->selectrow_hashref(q[SELECT password,id,email FROM "user" WHERE username=?], {}, $args{username});
    return [403, "Authentication failed (1)"] unless $row;

    my $ppr = Authen::Passphrase->from_crypt($row->{password});
    if ($ppr->match($args{password})) {
        return [200, "Authenticated", {id=>$row->{id}, email=>$row->{email}}];
    } else {
        return [403, "Authentication failed (2)"];
    }
}

$SPEC{list_lists} = {
    v => 1.1,
    summary => 'List available lists',
    args => {
        query => {
            schema => ['str*'],
            cmdline_aliases => {q => {}},
            pos => 0,
            tags => [qw/filter/],
        },
        creator => {
            schema => ['str*'],
            tags => [qw/filter/],
        },
        id => {
            schema => ['int*'],
            tags => [qw/filter/],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub list_lists {
    my %args = @_; # VALIDATE_ARGS

    my $sql = q[SELECT
                  l.id AS id,
                  l.name AS name,
                  l.description AS description,
                  u.username AS creator,
                  DATE_PART('epoch', l.ctime)::int AS ctime,
                  (SELECT COUNT(*) FROM list_like WHERE list_id=l.id) AS likes
                FROM list l
                LEFT JOIN "user" u ON l.creator=u.id];
    my @wheres;

    my $q = $args{query} // '';
    if (length($q)) {
        my $qq = __dbh->quote(lc $q);
        $qq =~ s/\A'//; $qq =~ s/'\z//;
        push @wheres, "LOWER(l.name) LIKE '%$qq%' OR LOWER(l.description) LIKE '%$qq%'";
    }
    if (defined $args{creator}) {
        push @wheres, "l.creator=".__dbh->quote($args{creator});
    }
    if (defined $args{id}) {
        push @wheres, "l.id=".__dbh->quote($args{id});
    }
    $sql .= " WHERE ".join(" AND ", map {"($_)"} @wheres) if @wheres;
    $sql .= " ORDER BY likes DESC, ctime DESC";
    $log->tracef("sql=%s", $sql);

    my $sth = __dbh->prepare($sql);
    $sth->execute;
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, $row }

    [200, "OK", \@rows, {result_format_options=>{table_column_orders=>[ [qw/id name creator description/] ]}}];
}

$SPEC{create_list} = {
    v => 1.1,
    summary => 'Create a new list',
    args => {
        name => {
            summary => 'The list title',
            schema => ['str*', min_len=>1],
            req => 1,
            pos => 0,
            description => <<'_',

Examples: "Steven's most favorite modules", "Modules to do blah", "Top ten
modules you'll want for christmas".

_
        },
        description => {
            summary => 'A longer (one to several paragraphs) of description',
            schema => ['str*'],
            description => 'Will be interpreted as Markdown',
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub create_list {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;
    {
        __dbh->do(q[INSERT INTO list (creator,name,description) VALUES (?,?,?)],
                  {},
                  __env->{"app.user_id"}, $args{name}, $args{description},
              ) or do {
                  $err = [500, "Can't create list: " . __dbh->errstr];
                  last;
              };
    }
    __activity_log(action => 'create list', note => {name=>$args{name}, description=>$args{description}}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK", { id=>__dbh->last_insert_id(undef, undef, "list", undef) }];
}

$SPEC{like_list} = {
    v => 1.1,
    summary => 'Like a list',
    description => <<'_',

You are allowed to like your own list.

_
    args => {
        id => {
            summary => 'List ID',
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub like_list {
    my %args = @_; # VALIDATE_ARGS

    my $err;
    my $lid = $args{id};
    my $uid = __env->{"app.user_id"};
    __dbh->begin_work;
    {
        my $res = __dbh->do(q[UPDATE list_like SET list_id=list_id WHERE list_id=? AND user_id=?], {}, $lid, $uid);
        if (!$res) { $err = [500, "Can't update: " . __dbh->errstr]; last }
        $res += 0;
        if (!$res) {
            # row does not exist yet
            $res = __dbh->do(q[INSERT INTO list_like (list_id,user_id) VALUES (?,?)], {}, $lid, $uid);
            if (!$res) { $err = [500, "Can't insert: " . __dbh->errstr]; last }
        }
    }
    #__activity_log(action => 'like list', note => {id=>$lid}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK"];
}

$SPEC{unlike_list} = {
    v => 1.1,
    summary => 'Unlike a list',
    description => <<'_',
_
    args => {
        id => {
            summary => 'List ID',
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub unlike_list {
    my %args = @_; # VALIDATE_ARGS

    my $err;
    my $lid = $args{id};
    my $uid = __env->{"app.user_id"};
    #__dbh->begin_work;
    {
        my $res = __dbh->do(q[DELETE FROM list_like WHERE list_id=? AND user_id=?], {}, $lid, $uid);
        if (!$res) { $err = [500, "Can't delete: " . __dbh->errstr]; last }
    }
    #__activity_log(action => 'unlike list', note => {id=>$lid}) unless $err;
    #__dbh->commit;
    return $err if $err;
    [200, "OK"];
}

$SPEC{list_items} = {
    v => 1.1,
    summary => "List items of a list",
    args => {
        list_id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub list_items {
    my %args = @_; # VALIDATE_ARGS
    my $sth = __dbh->prepare(
        "SELECT
           li.item_id AS id,
           i.name AS name,
           i.summary AS abstract,
           li.comment AS comment,
           DATE_PART('epoch', li.ctime)::int AS ctime
         FROM list_item li
         LEFT JOIN item i ON li.item_id=i.id
         WHERE list_id=? ORDER BY li.ctime");
    $sth->execute($args{list_id});

    my @items;
    while (my $row = $sth->fetchrow_hashref) {
        push @items, $row;
    }
    [200, "OK", \@items];
}

$SPEC{get_list} = {
    v => 1.1,
    summary => "Get details about a list",
    args => {
        id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        items => {
            summary => "Whether to retrieve list's items",
            schema => ['bool*', default => 1],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub get_list {
    my %args = @_; # VALIDATE_ARGS
    my $res = list_lists(id => $args{id});
    return "Can't list items: $res->[0] - $res->[1]" if $res->[0] != 200;
    return [404, "No such list"] unless @{$res->[2]};
    my $list = $res->[2][0];
    if ($args{items}) {
        $res = list_items(list_id=>$args{id});
        return "Can't get items: $res->[0] - $res->[1]" if $res->[0] != 200;
        $list->{items} = $res->[2];
    }
    [200, "OK", $list];
}

$SPEC{delete_list} = {
    v => 1.1,
    summary => "Delete a list",
    args => {
        id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        reason => {
            summary => 'Optional reason for deletion',
            schema => ['str*'],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub delete_list {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;
    {
        __dbh->do(q[DELETE FROM list WHERE id=?)],
                  {},
                  $args{id},
              ) or do { $err = [500, "Can't delete list: " . __dbh->errstr]; last };
    }
    __activity_log(action => 'delete list', note => {list_id=>$args{list_id}, name=>$args{name}}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK"];
}

$SPEC{update_list} = {
    v => 1.1,
    summary => "Update a list",
    args => {
        id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        new_name => {
            summary => "List's new name",
            schema => ['str'],
            description => 'If not specified, name will not be changed',
        },
        new_description => {
            summary => "List's new description",
            schema => ['str*'],
            description => "If not specified, description will not be changed",
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub update_list {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;
    {
        my $sql = "UPDATE list SET";
        my @params;
        if (exists $args{new_name}) {
            $sql .= (@params ? ", ":" ") . " name=?";
            push @params, $args{new_name};
        }
        if (exists $args{new_description}) {
            $sql .= (@params ? ", ":" ") . " description=?";
            push @params, $args{new_description};
        }
        if (!@params) { $err = [304, "Nothing is changed"]; last }
        $sql .= ",mtime=CURRENT TIMESTAMP";
        $sql .= " WHERE id=?";
        push @params, $args{id};
        my $n = __dbh->do($sql, {}, @params) or do { $err = [500, "Can't update list: " . __dbh->errstr]; last };
        $n+0 or do { $err = [404, "No such list"]; last }
    }
    __activity_log(action => 'update list', note => {list_id=>$args{list_id}, new_name=>$args{new_name}, new_description=>$args{new_description}}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK"];
}

$SPEC{add_item} = {
    v => 1.1,
    summary => "Add an item to a list",
    args => {
        list_id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        name => {
            summary => "Item's name (i.e. module name)",
            schema => ['str*'],
            req => 1,
            pos => 1,
        },
        comment => {
            summary => "Comment",
            schema => ['str*'],
            pos => 2,
            description => 'Will be interpreted as Markdown',
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub add_item {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;
    {
        # first of all, find the item's name in the database
        my $row = __dbh->selectrow_hashref("SELECT * FROM item WHERE name=?", {}, $args{name});
        my $item_id;

        # if not already exist, fetch from MetaCPAN
        if ($row) {
            $item_id = $row->{id};
        } else {
            $log->debugf("Fetching module '%s' info from MetaCPAN ...", $args{name});
            my $mcres;
            eval {
                $mcres = $mcpan->module($args{name});
            };
            if ($@) { $err = [500, "Can't query MetaCPAN for module '$args{name}', probably not found: $@"]; last }
            __dbh->do("INSERT INTO item (name, summary) VALUES (?,?)", {}, $args{name}, $mcres->{abstract})
                or do { $err = [500, "Can't insert item: " . __dbh->errstr]; last };
            $item_id = __dbh->last_insert_id(undef, undef, "item", undef);
        }

        __dbh->do(q[INSERT INTO list_item (list_id,item_id,comment) VALUES (?,?,?)],
                  {},
                  $args{list_id}, $item_id, $args{comment},
              ) or do {
                  $err = [500, "Can't add item: " . __dbh->errstr];
                  last;
              };
    }
    __activity_log(action => 'add item', note => {list_id=>$args{list_id}, name=>$args{name}, comment=>$args{comment}}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK"];
}

$SPEC{delete_item} = {
    v => 1.1,
    summary => "Delete an item from a list",
    args => {
        list_id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        name => {
            summary => "Item's name",
            schema => ['str*'],
            req => 1,
            pos => 1,
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub delete_item {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;
    {
        __dbh->do(q[DELETE FROM list_item WHERE list_id=? AND item_id=(SELECT id FROM item WHERE name=?)],
                  {},
                  $args{list_id}, $args{name},
              ) or do {
                  $err = [500, "Can't delete item: " . __dbh->errstr];
                  last;
              };
    }
    __activity_log(action => 'delete item', note => {list_id=>$args{list_id}, name=>$args{name}}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK"];
}

$SPEC{update_item} = {
    v => 1.1,
    summary => "Update a list item",
    args => {
        list_id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        name => {
            summary => "Item's name",
            schema => ['str*'],
            req => 1,
            pos => 1,
        },
        new_comment => {
            summary => "Item's new comment",
            schema => ['str'],
            description => "If not specified, comment will not be changed",
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub update_item {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;
    {
        my $sql = "UPDATE list_item SET";
        my @params;
        if (exists $args{new_comment}) {
            $sql .= (@params ? ", ":" ") . "comment=?";
            push @params, $args{new_comment};
        }
        if (!@params) { $err = [304, "No changes"]; last }
        $sql .= ",mtime=CURRENT TIMESTAMP";
        $sql .= " WHERE list_id=? AND item_id=(SELECT id FROM item WHERE name=?)";
        push @params, $args{list_id}, $args{name};
        my $n = __dbh->do($sql, {}, @params)
            or do { $err = [500, "Can't update item: " . __dbh->errstr]; last };
        $n+0 or do { $err = [404, "No such item"]; last }
    }
    __activity_log(action => 'update item', note => {list_id=>$args{list_id}, name=>$args{name}, comment=>$args{new_comment}}) unless $err;
    __dbh->commit;
    return $err if $err;
    [200, "OK"];
}

1;
#ABSTRACT: Application that runs on cpanlists.org

=head1 SYNOPSIS

You probably do not want to install this. This distribution contains the code to
run on cpanlists.org.

For the client program, see L<App::cpanlists>.


=head1 DESCRIPTION

Currently to use this module, you have to do two things. This is ugly and might
change in the future.

=over

=item * Set database handle at startup

 $dbh = DBI->connect(...);
 App::cpanlists::Server::__dbh($dbh);

=item * Set PSGI environment for each request

Mainly so that __activity_log() can get REMOTE_ADDR etc from PSGI environment.

 App::cpanlists::Server::__env($env);

=back


=head1 TODO


=head1 SEE ALSO

L<App::cpanlists>

=cut
