package CPANLists::Server;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any qw($log);

use JSON;
use MetaCPAN::Client;
use Perinci::Sub::Util qw(err);
use SQL::Schema::Versioned;

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Application that runs on cpanlists.org',
};

my $json = JSON->new->allow_nonref;

my $mcpan = MetaCPAN::Client->new;

our $sqlspec = {
    latest_v => 2,

    # note, pgsql server should be 9.1+, citext must be installed to db: "CREATE
    # EXTENSION citext".

    install => [
        q[CREATE TABLE "user" (
            id SERIAL PRIMARY KEY,
            -- roles TEXT[],

            username citext NOT NULL, UNIQUE(username), -- username at our site
            first_name VARCHAR(128),
            last_name VARCHAR(128),

            email citext, UNIQUE(email),
            password VARCHAR(255) NOT NULL,
            is_suspended BOOL NOT NULL DEFAULT 'f',
            is_deleted BOOL NOT NULL DEFAULT 'f',

            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            note TEXT
        )],

        q[CREATE TABLE user_notification (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL REFERENCES "user"(id),
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            message TEXT,
            rel VARCHAR(32) NOT NULL, -- 'comment' for new comment
            rel_id INT NOT NULL, -- for comment, list id
            is_read BOOL NOT NULL DEFAULT 'f',
            is_emailed BOOL NOT NULL DEFAULT 'f'
        )],

        q[CREATE TABLE session (
            id VARCHAR(36) PRIMARY KEY,
            userid INT REFERENCES "user"(id),
            username citext NOT NULL REFERENCES "user"(username) ON DELETE CASCADE, -- cache, to avoid extra lookup
            expiry_time TIMESTAMP NOT NULL
        )],

        q[CREATE TABLE list (
            id SERIAL PRIMARY KEY,
            creator INT REFERENCES "user"(id),
            name citext NOT NULL,
            type CHAR(1) NOT NULL CHECK (type IN ('m','a')), -- list of (m)odules, or (a)uthors
            description TEXT,
            is_deleted BOOL NOT NULL DEFAULT 'f',
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            tags TEXT[]
        )],

        q[CREATE TABLE author (
            id VARCHAR(64) PRIMARY KEY, -- cpan ID
            name VARCHAR(255) NOT NULL,
            email VARCHAR(255),
            website VARCHAR(255),
            gravatar_url VARCHAR(255),
            note TEXT,            -- our internal note, if any
            is_deleted BOOL NOT NULL DEFAULT 'f',
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE module (
            name VARCHAR(255) NOT NULL, UNIQUE(name),
            summary TEXT,         -- from cpan
            author  VARCHAR(64),  -- from cpan, XXX REFERENCES author(name)
            dist    VARCHAR(255), -- from cpan, dist name
            version VARCHAR(64),  -- from cpan, latest version
            reldate DATE,         -- from cpan, latest release date
            note TEXT,            -- our internal note, if any
            is_deleted BOOL NOT NULL DEFAULT 'f',
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        # keep name|comment|rating the same among TYPE_list_item for convenience
        q[CREATE TABLE author_list_item (
            creator INT REFERENCES "user"(id),
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            name VARCHAR(64) NOT NULL REFERENCES author(id), UNIQUE(list_id, name),
            rating INT CHECK (rating BETWEEN 1 AND 5),
            comment TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        # keep name|comment|rating the same among TYPE_list_item for convenience
        q[CREATE TABLE module_list_item (
            creator INT REFERENCES "user"(id),
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL REFERENCES module(name), UNIQUE(list_id, name),
            rating INT CHECK (rating BETWEEN 1 AND 5),
            comment TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE list_comment (
            id SERIAL PRIMARY KEY,
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            ref_id INT REFERENCES list_comment(id),
            comment TEXT,
            creator INT REFERENCES "user"(id),
            is_deleted BOOL NOT NULL DEFAULT 'f',
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
            action VARCHAR(32) NOT NULL,
            param TEXT, -- additional info to, e.g. module name, etc
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ip INET,
            note TEXT
        )],

        q[CREATE INDEX activity_log_ctime ON activity_log (ctime)],
    ],
    upgrade_to_v2 => [
        q[ALTER TABLE "user" ALTER username TYPE citext],
        q[ALTER TABLE "user" ALTER email TYPE citext],
        q[ALTER TABLE list ALTER name TYPE citext],
        q[ALTER TABLE session ALTER username TYPE citext],

        q['ALTER TABLE "user" ADD COLUMN is_deleted BOOL NOT NULL DEFAULT 'f'],
        q['ALTER TABLE "author" ADD COLUMN is_deleted BOOL NOT NULL DEFAULT 'f'],
        q['ALTER TABLE "module" ADD COLUMN is_deleted BOOL NOT NULL DEFAULT 'f'],

        # we now prevent a list to be actually deleted (but just flag it as
        # such) if it has comment. the comment can now still be displayed.
        q['ALTER TABLE list ADD COLUMN is_deleted BOOL NOT NULL DEFAULT 'f'],

        # we now record to provided threaded discussion, and flag if a comment
        # is deleted (because a comment cannot be actually deleted now if it is
        # referred by a response). like in imdb.com discussion.
        q['ALTER TABLE list_comment ADD COLUMN ref_id INT REFERENCES list(id)],
        q['ALTER TABLE list_comment ADD COLUMN is_deleted BOOL NOT NULL DEFAULT 'f'],

        # mainly for notifying via email about a new comment. for watching lists,
        # authors, modules in general, we'll use RSS.
        q[CREATE TABLE user_notification (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL REFERENCES "user"(id),
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            message TEXT,
            rel VARCHAR(32) NOT NULL, -- 'comment' for new comment,
            rel_id INT NOT NULL, -- for comment, list id
            is_read BOOL NOT NULL DEFAULT 'f',
            is_emailed BOOL NOT NULL DEFAULT 'f'
        )],
    ],
};

my $sch_list_type = ['str*', in=>['m','a']];
my $sch_rating = ['int', between=>[1,5]];
my $sch_items = [
    'array*' => of =>
        ['hash*' => {
            keys => {
                name => ['str*'],
                comment => ['str*'],
                rating => $sch_rating,
            },
            req_keys => [qw/name/],
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

sub __conf {
    state $conf;
    if (@_) {
        $conf = $_[0];
    }
    $conf;
}

sub __init_db {
    my $res = SQL::Schema::Versioned::create_or_update_db_schema(
        dbh => __dbh, spec => $sqlspec);
    die "Can't create/update db schema: $res->[1]" unless $res->[0] == 200;
}

# args: action*, param
sub __activity_log {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    if (__dbh()->do(q[INSERT INTO activity_log (ip,action,param,"user_id",note) VALUES (?,?,?,?,?)],
             {},
             (__env() ? __env->{REMOTE_ADDR} : $ENV{REMOTE_ADDR}),
             $args{action},
             $args{param},
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
};
sub create_user {
    require Authen::Passphrase::BlowfishCrypt;

    local __dbh()->{RaiseError} = 0;

    my %args = @_;

    # TMP
    $args{username} =~ /\A\w+\z/ or return [400, "Invalid username syntax"];

    my $ppr = Authen::Passphrase::BlowfishCrypt->new(cost=>8, salt_random=>1, passphrase=>$args{password});

    __dbh->begin_work;
    my $err;
    {
        __dbh->do(q[INSERT INTO "user" (username,email,password, first_name,last_name, note) VALUES (?,?,?, ?,?, ?)],
                  {},
                  $args{username}, lc($args{email}), $ppr->as_crypt,
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

sub __gen_random_pass {
    join("", map {("a".."z","A".."Z",0..9)[62*rand()]} 1..10);
}

$SPEC{get_bitcard_signin_url} = {
    v => 1.1,
    summary => "Get signin URL via BitCard API (bitcard.org)",
    description => <<'_',

To signin via BitCard, first call this function. You will get login URL (to
bitcard.org). Go to the login URL and enter your credentials. Afterwards, if the
login is correct, you will get return URL like, which you need to follow:

    https://cpanlists.org/api/verify_bitcard_signin?bc_confirmed=1&...

Either follow this URL, or pass the parameters to the `verify_bitcard_signin`
function yourself. If signin is verified, a success status (200) will be
returned along with session ID to use. Session ID can be used as password in
HTTP authenticaion e.g.:

    curl -u USERNAME:SESSION_ID https://cpanlists.org/api/SOME_FUNC?PARAM1=...

By default session ID can be used for 6 (six) months. If session is expired, you
can signin again.

_
    args => {
    },
};
sub get_bitcard_signin_url {
    require Authen::Bitcard;

    my %args = @_;

    my $bc = Authen::Bitcard->new;
    $bc->token(__conf->{bitcard_token});
    $bc->info_required([qw/username email/]);
    my $p = "/api/verify_bitcard_signin";
    my $returl = "https://cpanlists.org$p";
    my $url = $bc->login_url(r => $returl);
    return [500, "Can't get login URL"] unless $url;
    [200, "OK", $url];
}

my @bc_params = qw(
                      bc_confirmed bc_email bc_fields bc_id bc_name bc_sig bc_ts
                      bc_username bc_version
              );

$SPEC{verify_bitcard_signin} = {
    v => 1.1,
    summary => "Verify URL parameters returned by BitCard",
    description => <<'_',

See `get_bitcard_signin_url` for more information on signing in via BitCard.

_
    args => {
        map {$_=>{}} @bc_params,
    },
    result => {
        summary => 'Session ID',
        schema => 'hash*',
    },
};
sub verify_bitcard_signin {
    require Authen::Bitcard;

    my %args = @_;

    my $bc = Authen::Bitcard->new;
    $bc->token(__conf->{bitcard_token});
    my $vres = $bc->verify(\%args);
    return [403, "Verification failed: " . $bc->errstr] unless $vres;

    # create user on our site, if not already exist
    my $email = lc($vres->{email});
    my $res = get_user(email => $email);
    if ($res->[0] == 200) {
        # user already exists
        my $u = $res->[2]{username};
        $res = create_or_get_session(username => $u);
        return err($res, 500, "Can't create/get session") unless $res->[0] == 200;
        return [200, "OK", {session_id => $res->[2]{id}}];
    } elsif ($res->[0] == 404) {
        # user does not exist, create

        # pick an available username
        my @u = ($vres->{username}, $vres->{id});
        my $u;
        for (@u) {
            $res = get_user(username => $_);
            do { $u = $_; last } if $res->[0] == 404;
        }
        return err(500, "Can't pick an available username for $email") if !$u;

        # use the first word as first name, the rest as last name
        my ($fn, $ln);
        if (defined $args{bc_name}) {
            if ($args{bc_name} =~ /(.+?)\s+(.+)/) {
                $fn = $1; $ln = $2;
            } else {
                $fn = $args{bc_name};
            }
        }
        $res = create_user(
            email => $email, username=>$u, password=>__gen_random_pass,
            first_name => $fn, last_name => $ln,
            note => "via bitcard, id=$vres->{id}");
        return err($res, 500, "Can't create user") unless $res->[0] == 200;
        $res = create_or_get_session(username => $u);
        return err($res, 500, "Can't create/get session") unless $res->[0] == 200;
        return [200, "OK", {session_id => $res->[2]{id}}];
    } else {
        return err($res, 500, "Can't get user");
    }
}

$SPEC{create_or_get_session} = {
    v => 1.1,
    args => {
        username => {schema=>['str*'], req=>1, pos=>0},
    },
};
sub create_or_get_session {
    require UUID::Random;

    local __dbh()->{RaiseError} = 0;

    my %args = @_;

    my $id;
    my $u;
    my $row = __dbh->selectrow_hashref("SELECT id FROM session WHERE username=? AND expiry_time >= NOW()", {}, $args{username});

    if ($row) {
        $id = $row->{id};
    } else {
        $id = UUID::Random::generate();
        __dbh->do("INSERT INTO session (id,username,expiry_time) VALUES (?,?,NOW() + INTERVAL '6 month')", {}, $id, $args{username})
            or return [500, "Can't create session: " . __dbh->errstr];

        # delete expired sessions
        __dbh->do("DELETE FROM session WHERE expiry_time < NOW()");
    }

    [200, "OK", {id=>$id}];
}

$SPEC{check_session} = {
    v => 1.1,
    summary => 'Check if session with certain ID exists and not expired',
    result => {
        summary => 'Session information',
    },
    args => {
        id => { schema => ['str*'], req => 1, pos => 0 },
    },
};
sub check_session {
    my %args = @_;
    my $row = __dbh->selectrow_hashref("SELECT id, username, userid, expiry_time, expiry_time < NOW() AS is_expired FROM session WHERE id=?", {}, $args{id});
    return [404, "No such session"] unless $row;
    return [412, "Session expired, please signin again to get a new session"]
        if $row->{is_expired};
    [200, "Session OK", $row];
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
};
sub get_user {
    my %args = @_;
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
};
sub auth_user {
    require Authen::Passphrase;

    my %args = @_;

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
        type => {
            schema => $sch_list_type,
            summary => 'Filter only certain type of lists ("a" means '.
                'lists of authors only, "m" means lists of modules only)',
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

        result_limit => {
            summary => "Limit number of results",
            schema => ['int*', default=>5000, min=>1, max=>5000],
            tags => [qw/paging/],
        },
    },
};
sub list_lists {
    my %args = @_;

    # XXX schema
    my $limit = $args{result_limit} // 5000;
    $limit = 5000 if $limit > 5000;

    my $sql = q[SELECT
                  l.id AS id,
                  l.name AS name,
                  l.type AS type,
                  l.description AS description,
                  l.tags AS tags,
                  (SELECT username FROM "user" u WHERE u.id=l.creator) AS creator,
                  DATE_PART('epoch', l.ctime)::int AS ctime,
                  (SELECT COUNT(*) FROM author_list_item WHERE list_id=l.id)+(SELECT COUNT(*) FROM module_list_item WHERE list_id=l.id) AS num_items,
                  (SELECT COUNT(*) FROM list_like WHERE list_id=l.id) AS num_likes,
                  (SELECT COUNT(*) FROM list_comment WHERE list_id=l.id) AS num_comments
                FROM list l
            ];
    my @wheres = ('NOT l.is_deleted');

    my $q = $args{query} // '';
    if (length($q)) {
        my $qq = __dbh->quote(lc $q);
        $qq =~ s/\A'//; $qq =~ s/'\z//;
        push @wheres, "LOWER(l.name) LIKE '%$qq%' OR LOWER(l.description) LIKE '%$qq%'";
    }
    if ($args{type}) {
        push @wheres, "l.type='a'" if $args{type} eq 'a';
        push @wheres, "l.type='m'" if $args{type} eq 'm';
    }
    if (defined $args{creator}) {
        push @wheres, q[l.creator=(SELECT id FROM "user" WHERE username=].__dbh->quote($args{creator}).q[)];
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
    $sql .= " LIMIT $limit";
    $log->tracef("sql=%s", $sql);

    my $sth = __dbh->prepare($sql);
    $sth->execute;
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, $row }

    [200, "OK", \@rows,
     {format_options=>{any=>{table_column_orders=>[ [qw/id name creator description/] ]}}}];
}

sub __get_author {
    my $cpanid = shift;

    local __dbh()->{RaiseError} = 0;

    my $row = __dbh->selectrow_hashref("SELECT * FROM author WHERE name=?", {}, $cpanid);
    return $row if $row;

    # if not already exist, fetch from MetaCPAN
    $log->debugf("Fetching author '%s' info from MetaCPAN ...", $cpanid);
    my $mcres;
    eval {
        $mcres = $mcpan->author($cpanid);
    };
    return undef if $@;
    $row = {
        id           => $cpanid,
        name         => $mcres->name,
        email        => $mcres->email,
        website      => $mcres->website ? $mcres->website->[0] : undef,
        gravatar_url => $mcres->gravatar_url,
    };
    $log->debugf("Adding author %s ...", $cpanid);
    __dbh->do("INSERT INTO author (id, name,email,website,gravatar_url) VALUES (?, ?,?,?,?)", {}, $cpanid,
              $row->{name}, $row->{email}, $row->{website}, $row->{gravatar_url})
        or do { $log->errorf("Can't insert author %s: %s", $cpanid, __dbh->errstr); last WORK };
    return $row;
}

sub __get_module {
    my $mod = shift;

    local __dbh()->{RaiseError} = 0;

    my $row = __dbh->selectrow_hashref("SELECT * FROM module WHERE name=?", {}, $mod);
    return $row if $row;

    # if not already exist, fetch from MetaCPAN
    $log->debugf("Fetching module '%s' info from MetaCPAN ...", $mod);
    my $mcres;
    eval {
        $mcres = $mcpan->module($mod);
    };
    return undef if $@;
    my $reldate = $mcres->date =~ /^(\d\d\d\d)-(\d\d)-(\d\d)T/ ? "$1-$2-$3" : undef;
    $row = {
        name    => $mod,
        summary => $mcres->abstract,
        author  => $mcres->author,
        dist    => $mcres->distribution,
        version => $mcres->version_numified,
        reldate => $reldate,
    };
    $log->debugf("Adding module %s ...", $mod);
    __dbh->do("INSERT INTO module (name, summary,author,dist,version,reldate) VALUES (?, ?,?,?,?,?)", {}, $mod,
              $row->{summary}, $row->{author}, $row->{dist}, $row->{version}, $row->{reldate})
        or do { $log->errorf("Can't insert module %s: %s", $mod, __dbh->errstr); last WORK };
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

Examples: "Steven's most favorite modules", "Steven's favorite authors",
"Modules to do blah", "Top ten modules you'll want for christmas 2014".

_
        },
        type => {
            summary => 'List type, either m (for modules) or a (authors)',
            schema => $sch_list_type,
            req => 1,
            pos => 1,
        },
        description => {
            summary => 'A longer (one to several paragraphs) of description',
            schema => ['str*'],
            description => <<'_',

Will be interpreted as Markdown.

For module lists, module names in the form of `Foo::bar` or `mod://Foo::bar` or
`mod://foo` will be detected and added as items if indeed are CPAN module names.

_
        },
        scan_modules_from_description => {
            summary => 'Whether to scan module names from description '.
                'and add them as items (for module lists only)',
            schema => [bool => default => 0],
        },
        items => {
            summary => 'List items',
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
};
sub create_list {
    my %args = @_;
    my $desc = $args{description};
    my $type = $args{type};
    my $itemterm = $type eq 'm' ? 'module' : 'author';

    local __dbh()->{RaiseError} = 0;

    __dbh->begin_work;
    my $err;
    my @items;
    my $lid;

    push @items, {name=>$_->{name}, comment=>$_->{comment}, rating=>$_->{rating}}
        for @{ $args{items} // [] };

  WORK:
    {
        __dbh->do(q[INSERT INTO list (creator, name,type,description,tags) VALUES (?, ?,?,?,?)],
                  {},
                  (__env() ? __env->{"app.user_id"} : undef),
                  $args{name}, $type, $desc, $args{tags},
              ) or do { $err = [500, "Can't create list: " . __dbh->errstr]; last };

        $lid=__dbh->last_insert_id(undef, undef, "list", undef);

        # try to detect module names from text, and add them as items
        if ($type eq 'm' && $args{scan_modules_from_description} && $desc) {
            my @mods;
            while ($desc =~ m!(\w+(?:::\w+)+) | mod://(\w+(?:::\w+)*)!gx) {
                my $mod = $1 // $2;
                push @mods, $mod;
            }
            $log->debugf("Detected module name(s) %s", \@mods);
            for my $mod (@mods) {
                my $iteminfo = __get_module($_) for @mods;
                push @items, {name=>$mod, id=>$iteminfo->{id}} unless (grep {$_->{name} eq $mod} @items);
            }
        }

        # add the items
        my $tbl = $type eq 'a' ? 'author_list_item' : 'module_list_item';
        for my $item (@items) {
            my $item_id = $item->{id};
            unless ($item_id) {
                my $iteminfo = $type eq 'm' ?
                    __get_module($item->{name}) : __get_author($item->{name});
                if (!$iteminfo) {
                    $err = [500, "Can't find $itemterm $item->{name}"];
                    last WORK;
                }
                $item_id = $iteminfo->{id};
            }
            __dbh->do(qq[INSERT INTO $tbl (list_id,name,comment,rating) VALUES (?,?,?,?)],
                      {},
                      $lid, $item->{name}, $item->{comment}, $item->{rating},
                  ) or do { $log->errorf("Can't add $itemterm item %s: %s", $item->{name}, __dbh->errstr); last WORK };
        }
    }
    __activity_log(action => 'create list', note => {name=>$args{name}, type=>$type, description=>$desc, items=>\@items}) unless $err;
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
};
sub like_list {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

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
};
sub unlike_list {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

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
};
sub list_items {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    my $row = __dbh->selectrow_hashref("SELECT type FROM list WHERE id=?", {}, $args{list_id});
    return [404, "No such list"] unless $row;
    my $type = $row->{type};

    my $sth;
    if ($type eq 'm') {
        $sth = __dbh->prepare(
            "SELECT
               m.name AS name,
               m.summary AS abstract,
               m.author AS author,
               m.dist AS dist,
               m.version AS version,
               m.reldate AS reldate,
               li.comment AS comment,
               li.rating AS rating,
               DATE_PART('epoch', li.ctime)::int AS ctime
             FROM module_list_item li
             LEFT JOIN module m ON li.name=m.name
             WHERE list_id=? ORDER BY li.ctime");
    } else {
        $sth = __dbh->prepare(
            "SELECT
               a.id AS id,
               a.name AS name,
               li.comment AS comment,
               li.rating AS rating,
               DATE_PART('epoch', li.ctime)::int AS ctime
             FROM author_list_item li
             LEFT JOIN author a ON li.name=a.id
             WHERE list_id=? ORDER BY li.ctime");
    }
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
};
sub get_list {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    my $res = list_lists(id => $args{id});
    return err(500, "Can't get list", $res) if $res->[0] != 200;
    return [404, "No such list"] unless @{$res->[2]};
    my $list = $res->[2][0];
    if ($args{items}) {
        $res = list_items(list_id=>$args{id});
        return err(500, "Can't get items", $res) if $res->[0] != 200;
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
};
sub delete_list {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    __dbh->begin_work;
    my $err;
    {
        if (__dbh->selectrow_hashref("SELECT id FROM list_comment WHERE list_id=? LIMIT 1", {}, $args{id})) {
            __dbh->do(q[UPDATE list SET is_deleted='t' WHERE id=?], {}, $args{id})
                or do { $err = [500, "Can't delete (set is_deleted) list: " . __dbh->errstr]; last };
        } else {
            __dbh->do(q[DELETE FROM list WHERE id=?],
                      {},
                      $args{id},
                  ) or do { $err = [500, "Can't delete list: " . __dbh->errstr]; last };
        }
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
};
sub update_list {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    __dbh->begin_work;
    my $err;

    my $row = __dbh->selectrow_hashref("SELECT * FROM list WHERE id=? AND NOT is_deleted", {}, $args{id});
    return [404, "No such list"] unless $row;
    my $type = $row->{type};
    my $itemterm = $type eq 'm' ? 'module' : 'author';
    my $tbl = $type eq 'm' ? 'module_list_item' : 'author_list_item';

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
            __dbh->do("DELETE FROM $tbl WHERE list_id=?", {}, $args{id})
                or do { $err = [500, "Can't delete old items: " . __dbh->errstr]; last WORK };

            for my $item (@{ $args{new_items} }) {
                my $item_id = $item->{id};
                unless ($item_id) {
                    my $iteminfo = $type eq 'm' ? __get_module($item->{name}) :
                        __get_author($item->{name});
                    if (!$iteminfo) {
                        $err = [500, "Can't find $itemterm $item->{name}"];
                        last WORK;
                    }
                    $item_id = $iteminfo->{id};
                }
                __dbh->do(qq[INSERT INTO $tbl (list_id, name,comment,rating) VALUES (?, ?,?,?)],
                          {},
                          $args{id}, $item->{name}, $item->{comment}, $item->{rating},
                      ) or do { $log->errorf("Can't add $itemterm item %s: %s", $item->{name}, __dbh->errstr); last WORK };
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
            summary => "Item's name (i.e. module name/CPAN ID)",
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
        rating => {
            summary => "Rating",
            schema => $sch_rating,
            pos => 3,
        },
    },
};
sub add_item {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    __dbh->begin_work;
    my $err;

    my $row = __dbh->selectrow_hashref("SELECT * FROM list WHERE id=? AND NOT is_deleted", {}, $args{list_id});
    return [404, "No such list"] unless $row;
    my $type = $row->{type};
    my $itemterm = $type eq 'm' ? 'module' : 'author';
    my $tbl = $type eq 'm' ? 'module_list_item' : 'author_list_item';

  WORK:
    {
        my $iteminfo = $type eq 'm' ? __get_module($args{name}) :
            __get_author($args{name});
        unless ($iteminfo) {
            $err = [500, "Can't find $itemterm $args{name}"];
            last WORK;
        }
        __dbh->do(qq[INSERT INTO $tbl (list_id,name,comment,rating) VALUES (?, ?,?,?)],
                  {},
                  $args{list_id}, $args{name}, $args{comment}, $args{rating},
              ) or do { $err = [500, "Can't add $itemterm item: " . __dbh->errstr]; last };
    }
    __activity_log(action => 'add item', note => {list_id=>$args{list_id}, name=>$args{name}, comment=>$args{comment}, rating=>$args{rating}}) unless $err;
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
            summary => "Item's name (i.e. module name/CPAN ID)",
            schema => ['str*'],
            req => 1,
            pos => 1,
        },
    },
};
sub delete_item {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    __dbh->begin_work;
    my $err;

    my $row = __dbh->selectrow_hashref("SELECT * FROM list WHERE id=? AND NOT is_deleted", {}, $args{list_id});
    return [404, "No such list"] unless $row;
    my $type = $row->{type};
    my $itemterm = $type eq 'm' ? 'module' : 'author';
    my $tbl = $type eq 'm' ? 'module_list_item' : 'author_list_item';

    {
        __dbh->do(qq[DELETE FROM $tbl WHERE list_id=? AND name=?],
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
        new_rating => {
            summary => "Item's new rating",
            schema => ['str'],
            description => "If not specified, rating will not be changed",
        },
    },
};
sub update_item {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    __dbh->begin_work;
    my $err;

    my $row = __dbh->selectrow_hashref("SELECT * FROM list WHERE id=? AND NOT is_deleted", {}, $args{list_id});
    return [404, "No such list"] unless $row;
    my $type = $row->{type};
    my $itemterm = $type eq 'm' ? 'module' : 'author';
    my $tbl = $type eq 'm' ? 'module_list_item' : 'author_list_item';

    {
        my $sql = "UPDATE $tbl SET";
        my @params;
        if (exists $args{new_comment}) {
            $sql .= (@params ? ", ":" ") . "comment=?";
            push @params, $args{new_comment};
        }
        if (exists $args{new_rating}) {
            $sql .= (@params ? ", ":" ") . "rating=?";
            push @params, $args{new_rating};
        }
        if (!@params) { $err = [304, "No changes"]; last }
        $sql .= ",mtime=CURRENT_TIMESTAMP";
        $sql .= " WHERE list_id=? AND name=?";
        push @params, $args{list_id}, $args{name};
        my $n = __dbh->do($sql, {}, @params)
            or do { $err = [500, "Can't update item: " . __dbh->errstr]; last };
        $n+0 or do { $err = [404, "No such item"]; last }
    }
    __activity_log(action => 'update item', note => {list_id=>$args{list_id}, name=>$args{name}, comment=>$args{new_comment}, rating=>$args{new_rating}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    [200, "OK"];
}

$SPEC{get_list_comment} = {
    v => 1.1,
    summary => "Get a single list comment",
    args => {
        id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
    },
};
sub get_list_comment {
    my %args = @_;

    my $row = __dbh->selectrow_hashref(
        q[SELECT
           c.id AS id,
           c.comment AS comment,
           (SELECT username FROM "user" u WHERE u.id=c.creator) AS creator,
           DATE_PART('epoch', c.ctime)::int AS ctime
         FROM list_comment c
         WHERE c.id=? AND NOT c.is_deleted], {}, $args{id});
    if ($row) {
        return [200, "OK", $row];
    } else {
        return [404, "No such list comment"];
    }
}

$SPEC{list_list_comments} = {
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
};
sub list_list_comments {
    my %args = @_;

    my $sth = __dbh->prepare(
        q[SELECT
           c.id AS id,
           c.comment AS comment,
           (SELECT username FROM "user" u WHERE u.id=c.creator) AS creator,
           DATE_PART('epoch', c.ctime)::int AS ctime
         FROM list_comment c
         WHERE c.list_id=? AND NOT is_deleted ORDER BY c.ctime]);
    $sth->execute($args{list_id});

    my @items;
    while (my $row = $sth->fetchrow_hashref) {
        push @items, $row;
    }
    [200, "OK", \@items];
}

$SPEC{add_list_comment} = {
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
        ref_id => {
            summary => 'Parent comment ID, if this is a reply to another comment',
            schema => ['int*'],
        },
    },
};
sub add_list_comment {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    my $desc = $args{description};

    __dbh->begin_work;
    my $err;

    {
        if (defined $args{ref_id}) {
            # check that ref_id is a comment to the same list
            __dbh->selectrow_hashref("SELECT id FROM list_comment WHERE id=? AND list_id=?", {}, $args{id}, $args{list_id})
                or do { $err = [500, "Wrong ref_id (doesn't exist or refers to another list)"]; last };
        }
        __dbh->do(q[INSERT INTO list_comment (creator,list_id,comment,ref_id) VALUES (?,?,?,?)],
                  {},
                  (__env() ? __env->{"app.user_id"} : undef),
                  $args{list_id}, $args{comment}, $args{ref_id})
            or do { $err = [500, "Can't add list_comment: " . __dbh->errstr]; last };

    }
    __activity_log(action => 'add list comment', note => {list_id=>$args{list_id}, comment=>$args{comment}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    my $cid=__dbh->last_insert_id(undef, undef, "list_comment", undef);
    [200, "OK", { id=>$cid }];
}

$SPEC{update_list_comment} = {
    v => 1.1,
    summary => "Update a list comment",
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
};
sub update_list_comment {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    my $desc = $args{description};

    __dbh->begin_work;
    my $err;

  WORK:
    {
        my $sql = "UPDATE list_comment SET";
        my @params;
        if (exists $args{new_comment}) {
            $sql .= (@params ? ", ":" ") . " comment=?";
            push @params, $args{new_comment};
        }
        if (!@params) { $err = [304, "Nothing is changed"]; last }
        $sql .= ",mtime=CURRENT_TIMESTAMP";
        $sql .= " WHERE id=?";
        push @params, $args{id};
        my $n = __dbh->do($sql, {}, @params) or do { $err = [500, "Can't update list comment: " . __dbh->errstr]; last };
        $n+0 or do { $err = [404, "No such list"]; last };
    }
    __activity_log(action => 'update list comment', note => {id=>$args{id}, new_comment=>$args{new_comment}}, new_tags=>$args{new_tags}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    [200, "OK"];
}

$SPEC{delete_list_comment} = {
    v => 1.1,
    summary => "Delete a single list comment",
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
};
sub delete_list_comment {
    my %args = @_;

    local __dbh()->{RaiseError} = 0;

    # XXX if comment has child comment, instead of delete, set flag is_deleted

    __dbh->begin_work;
    my $err;
    {
        __dbh->do(q[DELETE FROM list_comment WHERE id=?],
                  {},
                  $args{id},
              ) or do { $err = [500, "Can't delete list comment: " . __dbh->errstr]; last };
    }
    __activity_log(action => 'delete list comment', note => {id=>$args{id}, reason=>$args{reason}}) unless $err;
    if ($err) { __dbh->rollback } else { __dbh->commit }
    return $err if $err;
    [200, "OK"];
}

# func: delete_user?
# func: update_user?
# func: update_comment()?

1;
#ABSTRACT:

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
 CPANLists::Server::__dbh($dbh);

=item * Set PSGI environment for each request

Mainly so that __activity_log() can get REMOTE_ADDR etc from PSGI environment.

 CPANLists::Server::__env($env);

=back


=head1 SEE ALSO

L<App::cpanlists>

=cut
