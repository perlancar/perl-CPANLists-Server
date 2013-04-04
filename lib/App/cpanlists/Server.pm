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
            creator INT REFERENCES "user"(id),
            name VARCHAR(255) NOT NULL, UNIQUE(name), -- citext
            -- XXX type: module, author
            description TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            tags TEXT[]
        )],

        q[CREATE TABLE item (
            id SERIAL PRIMARY KEY,
            name VARCHAR(255) NOT NULL, UNIQUE(name),
            summary TEXT,
            author  VARCHAR(64),  -- cpan-specific
            dist    VARCHAR(255), -- cpan-specific
            version VARCHAR(64),  -- cpan-specific
            reldate DATE,         -- cpan-specific, release-time
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

        q[CREATE TABLE comment (
            id SERIAL PRIMARY KEY,
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            comment TEXT,
            creator INT REFERENCES "user"(id),
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE list_like (
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            user_id INT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            UNIQUE(list_id, user_id),
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

my $sch_items = ['array*' => of =>
                     ['hash*' => {
                         keys => {
                             name => ['str*'],
                             comment => ['str*'],
                         },
                         # req_keys => [qw/name/],
                     },
                  ],
             ];

my $sch_tag = ['str*']; # XXX match => qr/\A[A-Za-z0-9_-]+(::[A-Za-z0-9_-]+)*\z/
my $sch_tags = ['array*' => of => $sch_tag];

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
    my $res = SHARYANTO::SQL::Schema::create_or_update_db_schema(
        dbh => __dbh, spec => $spec);
    die "Can't create/update db schema: $res->[1]" unless $res->[0] == 200;
}

sub __activity_log {
    my %args = @_;

    if (__dbh()->do(q[INSERT INTO activity_log (ip,action,"user_id",note) VALUES (?,?,?,?)],
             {},
             (__env() ? __env->{REMOTE_ADDR} : $ENV{REMOTE_ADDR}),
             $args{action},
             (__env() ? __env->{"app.user_id"} : undef),
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
    if ($err) { __dbh->rollback } else { __dbh->commit }
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
        has_tags => {
            summary => "Only include lists containing these tags",
            schema => $sch_tags,
            tags => [qw/filter/],
        },
        lacks_tags => {
            summary => "Only include lists not containing these tags",
            schema => $sch_tags,
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
                  l.tags AS tags,
                  (SELECT username FROM "user" u WHERE u.id=l.creator) AS creator,
                  DATE_PART('epoch', l.ctime)::int AS ctime,
                  (SELECT COUNT(*) FROM list_item WHERE list_id=l.id) AS num_items,
                  (SELECT COUNT(*) FROM list_like WHERE list_id=l.id) AS num_likes,
                  (SELECT COUNT(*) FROM comment   WHERE list_id=l.id) AS num_comments
                FROM list l
            ];
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
    if ($args{has_tags}) {
        for (@{ $args{has_tags} }) {
            push @wheres, __dbh->quote($_)."=ANY(l.tags)";
        }
    }
    if ($args{lacks_tags}) {
        for (@{ $args{lacks_tags} }) {
            push @wheres, "NOT(".__dbh->quote($_)."=ANY(l.tags))";
        }
    }
    $sql .= " WHERE ".join(" AND ", map {"($_)"} @wheres) if @wheres;
    $sql .= " ORDER BY num_likes DESC, ctime DESC";
    $log->tracef("sql=%s", $sql);

    my $sth = __dbh->prepare($sql);
    $sth->execute;
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, $row }

    [200, "OK", \@rows,
     {result_format_options=>{table_column_orders=>[ [qw/id name creator description/] ]}}];
}

sub __get_item {
    my $mod = shift;

    my $row = __dbh->selectrow_hashref("SELECT * FROM item WHERE name=?", {}, $mod);
    return $row if $row;

    # if not already exist, fetch from MetaCPAN
    $log->debugf("Fetching module '%s' info from MetaCPAN ...", $mod);
    my $mcres;
    eval {
        $mcres = $mcpan->module($mod);
    };
    return undef if $@;
    my $reldate = $mcres->{date} =~ /^(\d\d\d\d)-(\d\d)-(\d\d)T/ ? "$1-$2-$3" : undef;
    $row = {
        name    => $mod,
        summary => $mcres->{abstract},
        author  => $mcres->{author},
        dist    => $mcres->{distribution},
        version => $mcres->{version_numified},
        reldate => $reldate,
    };
    $log->debugf("Adding item %s ...", $mod);
    __dbh->do("INSERT INTO item (name, summary,author,dist,version,reldate) VALUES (?, ?,?,?,?,?)", {}, $mod,
              $row->{summary}, $row->{author}, $row->{dist}, $row->{version}, $row->{reldate})
        or do { $log->errorf("Can't insert item %s: %s", $mod, __dbh->errstr); last WORK };
    $row->{id} = __dbh->last_insert_id(undef, undef, "item", undef);
    return $row;
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
            description => <<'_',

Will be interpreted as Markdown.

Module names in the form of `Foo::bar` or `mod://Foo::bar` or `mod://foo` will
be detected and added as items if indeed are CPAN module names.

_
        },
        scan_modules_from_description => {
            summary => 'Whether to scan module names from description '.
                'and add them as items',
            schema => [bool => default => 0],
        },
        items => {
            summary => 'Items',
            schema => $sch_items,
            description => <<'_',

Alternatively, you can leave this empty and add items one-by-one using
add_item().

_
        },
        tags => {
            summary => 'Tags',
            schema => $sch_tags,
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub create_list {
    my %args = @_; # VALIDATE_ARGS
    my $desc = $args{description};

    __dbh->begin_work;
    my $err;
    my @items;
    my $lid;

    push @items, {name=>$_->{name}, comment=>$_->{comment}} for @{ $args{items} // [] };

  WORK:
    {
        __dbh->do(q[INSERT INTO list (creator, name,description,tags) VALUES (?, ?,?,?)],
                  {},
                  (__env() ? __env->{"app.user_id"} : undef),
                  $args{name}, $desc, $args{tags},
              ) or do { $err = [500, "Can't create list: " . __dbh->errstr]; last };

        $lid=__dbh->last_insert_id(undef, undef, "list", undef);

        # try to detect module names from text, and add them as items
        if ($args{scan_modules_from_description} && $desc) {
            my @mods;
            while ($desc =~ m!(\w+(?:::\w+)+) | mod://(\w+(?:::\w+)*)!gx) {
                my $mod = $1 // $2;
                push @mods, $mod;
            }
            $log->debugf("Detected module name(s) %s", \@mods);
            for my $mod (@mods) {
                my $iteminfo = __get_item($_) for @mods;
                push @items, {name=>$mod, id=>$iteminfo->{id}} unless (grep {$_->{name} eq $mod} @items);
            }
        }

        # add the items
        for my $item (@items) {
            my $item_id = $item->{id};
            unless ($item_id) {
                my $iteminfo = __get_item($item->{name});
                if (!$iteminfo) {
                    $err = [500, "Can't find module $item->{name}"];
                    last WORK;
                }
                $item_id = $iteminfo->{id};
            }
            __dbh->do(q[INSERT INTO list_item (list_id,item_id,comment) VALUES (?,?,?)],
                      {},
                      $lid, $item_id, $item->{comment},
                  ) or do { $log->errorf("Can't add item %s: %s", $item->{name}, __dbh->errstr); last WORK };
        }
    }
    __activity_log(action => 'create list', note => {name=>$args{name}, description=>$args{description}, items=>\@items}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;

    [200, "OK", { id=>$lid }];
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
    my $uid = __env() ? __env->{"app.user_id"} : undef; return [412, "Please supply app.user_id in PSGI env"] unless $uid;
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
    if ($err) { __dbh->rollback } else { __dbh->commit }
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
    my $uid = __env() ? __env->{"app.user_id"} : undef; return [412, "Please supply app.user_id in PSGI env"] unless $uid;
    #__dbh->begin_work;
    {
        my $res = __dbh->do(q[DELETE FROM list_like WHERE list_id=? AND user_id=?], {}, $lid, $uid);
        if (!$res) { $err = [500, "Can't delete: " . __dbh->errstr]; last }
    }
    #__activity_log(action => 'unlike list', note => {id=>$lid}) unless $err;
    #if ($err) { __dbh->rollback } else { __dbh->commit }
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
           i.author AS author,
           i.dist AS dist,
           i.version AS version,
           i.reldate AS reldate,
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
        __dbh->do(q[DELETE FROM list WHERE id=?],
                  {},
                  $args{id},
              ) or do { $err = [500, "Can't delete list: " . __dbh->errstr]; last };
    }
    __activity_log(action => 'delete list', note => {list_id=>$args{list_id}, name=>$args{name}, reason=>$args{reason}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
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
        new_items => {
            summary => "List's new items",
            schema => $sch_items,
            description => "If not specified, items will not be changed",
        },
        new_tags => {
            summary => "List's new tags",
            schema => $sch_tags,
            description => "If not specified, tags will not be changed",
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub update_list {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;

  WORK:
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
        if (exists $args{new_tags}) {
            $sql .= (@params ? ", ":" ") . " tags=?";
            push @params, $args{new_tags};
        }
        if (!@params && !$args{new_items}) { $err = [304, "Nothing is changed"]; last }
        $sql .= ",mtime=CURRENT_TIMESTAMP";
        $sql .= " WHERE id=?";
        push @params, $args{id};
        my $n = __dbh->do($sql, {}, @params) or do { $err = [500, "Can't update list: " . __dbh->errstr]; last };
        $n+0 or do { $err = [404, "No such list"]; last };

        if ($args{new_items}) {
            __dbh->do("DELETE FROM list_item WHERE list_id=?", {}, $args{id})
                or do { $err = [500, "Can't delete old items: " . __dbh->errstr]; last WORK };

            for my $item (@{ $args{new_items} }) {
                my $item_id = $item->{id};
                unless ($item_id) {
                    my $iteminfo = __get_item($item->{name});
                    if (!$iteminfo) {
                        $err = [500, "Can't find module $item->{name}"];
                        last WORK;
                    }
                    $item_id = $iteminfo->{id};
                }
                __dbh->do(q[INSERT INTO list_item (list_id,item_id,comment) VALUES (?,?,?)],
                          {},
                          $args{id}, $item_id, $item->{comment},
                      ) or do { $log->errorf("Can't add item %s: %s", $item->{name}, __dbh->errstr); last WORK };
            }
        }
    }
    __activity_log(action => 'update list', note => {list_id=>$args{list_id}, new_name=>$args{new_name}, new_description=>$args{new_description}, new_items=>$args{new_items}, new_tags=>$args{new_tags}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
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
  WORK:
    {
        my $iteminfo = __get_item($args{name});
        unless ($iteminfo) {
            $err = [500, "Can't find module $args{name}"];
            last WORK;
        }
        __dbh->do(q[INSERT INTO list_item (list_id,item_id,comment) VALUES (?,?,?)],
                  {},
                  $args{list_id}, $iteminfo->{id}, $args{comment},
              ) or do { $err = [500, "Can't add item: " . __dbh->errstr]; last };
    }
    __activity_log(action => 'add item', note => {list_id=>$args{list_id}, name=>$args{name}, comment=>$args{comment}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
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
    if ($err) { __dbh->rollback } else { __dbh->commit }
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
        $sql .= ",mtime=CURRENT_TIMESTAMP";
        $sql .= " WHERE list_id=? AND item_id=(SELECT id FROM item WHERE name=?)";
        push @params, $args{list_id}, $args{name};
        my $n = __dbh->do($sql, {}, @params)
            or do { $err = [500, "Can't update item: " . __dbh->errstr]; last };
        $n+0 or do { $err = [404, "No such item"]; last }
    }
    __activity_log(action => 'update item', note => {list_id=>$args{list_id}, name=>$args{name}, comment=>$args{new_comment}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    [200, "OK"];
}

$SPEC{get_comment} = {
    v => 1.1,
    summary => "Get a single comment",
    args => {
        id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub get_comment {
    my %args = @_; # VALIDATE_ARGS
    my $row = __dbh->selectrow_hashref(
        q[SELECT
           c.id AS id,
           c.comment AS comment,
           (SELECT username FROM "user" u WHERE u.id=c.creator) AS creator,
           DATE_PART('epoch', c.ctime)::int AS ctime
         FROM comment c
         WHERE c.id=?], {}, $args{id});
    if ($row) {
        return [200, "OK", $row];
    } else {
        return [404, "No such comment"];
    }
}

$SPEC{list_comments} = {
    v => 1.1,
    summary => "List comments to a list",
    args => {
        list_id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        id => {
            schema => ['int*'],
            tags => [qw/filter/],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub list_comments {
    my %args = @_; # VALIDATE_ARGS
    my $sth = __dbh->prepare(
        q[SELECT
           c.id AS id,
           c.comment AS comment,
           (SELECT username FROM "user" u WHERE u.id=c.creator) AS creator,
           DATE_PART('epoch', c.ctime)::int AS ctime
         FROM comment c
         WHERE c.list_id=? ORDER BY c.ctime]);
    $sth->execute($args{list_id});

    my @items;
    while (my $row = $sth->fetchrow_hashref) {
        push @items, $row;
    }
    [200, "OK", \@items];
}

$SPEC{add_comment} = {
    v => 1.1,
    summary => "Add a comment to a list",
    args => {
        list_id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        comment => {
            summary => "Comment",
            schema => ['str*'],
            req => 1,
            pos => 1,
            description => 'Will be interpreted as Markdown',
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub add_comment {
    my %args = @_; # VALIDATE_ARGS
    my $desc = $args{description};

    __dbh->begin_work;
    my $err;

    {
        __dbh->do(q[INSERT INTO comment (creator,list_id,comment) VALUES (?,?,?)],
                  {},
                  (__env() ? __env->{"app.user_id"} : undef),
                  $args{list_id}, $args{comment})
            or do { $err = [500, "Can't add comment: " . __dbh->errstr]; last };

    }
    __activity_log(action => 'add comment', note => {list_id=>$args{list_id}, comment=>$args{comment}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    my $cid=__dbh->last_insert_id(undef, undef, "comment", undef);
    [200, "OK", { id=>$cid }];
}

$SPEC{update_comment} = {
    v => 1.1,
    summary => "Update a comment",
    args => {
        id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        new_comment => {
            summary => "Comment",
            schema => ['str*'],
            description => <<'_',

If not specified, comment will not be replaced.

Will be interpreted as Markdown.

_
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub update_comment {
    my %args = @_; # VALIDATE_ARGS
    my $desc = $args{description};

    __dbh->begin_work;
    my $err;

  WORK:
    {
        my $sql = "UPDATE comment SET";
        my @params;
        if (exists $args{new_comment}) {
            $sql .= (@params ? ", ":" ") . " comment=?";
            push @params, $args{new_comment};
        }
        if (!@params) { $err = [304, "Nothing is changed"]; last }
        $sql .= ",mtime=CURRENT_TIMESTAMP";
        $sql .= " WHERE id=?";
        push @params, $args{id};
        my $n = __dbh->do($sql, {}, @params) or do { $err = [500, "Can't update ccomment: " . __dbh->errstr]; last };
        $n+0 or do { $err = [404, "No such list"]; last };
    }
    __activity_log(action => 'update comment', note => {id=>$args{id}, new_comment=>$args{new_comment}}, new_tags=>$args{new_tags}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    [200, "OK"];
}

# XXX instead of delete row, option to replace comment with "(Deleted)"
$SPEC{delete_comment} = {
    v => 1.1,
    summary => "Delete a single comment",
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
sub delete_comment {
    my %args = @_; # VALIDATE_ARGS

    __dbh->begin_work;
    my $err;
    {
        __dbh->do(q[DELETE FROM comment WHERE id=?],
                  {},
                  $args{id},
              ) or do { $err = [500, "Can't delete comment: " . __dbh->errstr]; last };
    }
    __activity_log(action => 'delete comment', note => {id=>$args{id}, reason=>$args{reason}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    [200, "OK"];
}

# func: update_comment()?

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
