#!/usr/bin/perl

package PAUSE;

=comment

All the code in here is very old. Many functions are not needed
anymore or at least I am in the process of eliminating dependencies on
it. Before you *use* a function here, please ask about its status.

=cut

# nono for non-CGI: use CGI::Switch ();

use Compress::Zlib ();
use DBI ();
use Exporter;
use Fcntl qw(:flock);
use File::Spec ();
use IO::File ();
use MD5 ();
use Mail::Send ();
use YAML::Syck;

use strict;
use vars qw(@ISA @EXPORT_OK $VERSION $Config);

@ISA = qw(Exporter);
@EXPORT_OK = qw(urecord);

$VERSION = "1.005";

# for Configuration Variable we use PrivatePAUSE.pm, because these are
# really variables we cannot publish. Will separate harmless variables
# from the secret ones and put them here in the future.

my(@pauselib) = grep m!(/PAUSE|\.\.|/SVN)/lib!, @INC;
for (@pauselib) {
  s|/lib|/privatelib|;
}
push @INC, @pauselib;
$PAUSE::Config ||=
    {
     # previously also used for ftp password; still used in Error as
     # contact address and as address to send internal notifications
     # to:
     ADMIN => qq{andreas.koenig.gmwojprw+pause\@franz.ak.mind.de},
     ADMINS => [qq(modules\@perl.org)],
     ANON_FTP_PASS => qq{k\@pause.perl.org},
     AUTHEN_DATA_SOURCE_NAME => "DBI:mysql:authen_pause",
     AUTHEN_PASSWORD_FLD => "password",
     AUTHEN_USER_FLD => "user",
     AUTHEN_USER_TABLE => "usertable",
     CPAN_TESTERS => qq(cpan-testers\@perl.org,cpan-uploads\@perl.org), # deprecated
     TO_CPAN_TESTERS => qq(cpan-testers\@perl.org,cpan-uploads\@perl.org),
     REPLY_TO_CPAN_TESTERS => qq(cpan-uploads\@perl.org),
     DELETES_EXPIRE => 60*60*72,
     FTPPUB => '/home/ftp/pub/PAUSE/',
     GONERS_NOTIFY => qq{gbarr\@search.cpan.org},
     GZIP => '/bin/gzip',
     HOME => '/home/k/',
     HTTP_ERRORLOG => '/usr/local/apache/logs/error_log',
     INCOMING => 'ftp://pause.perl.org/incoming/',
     INCOMING_LOC => '/home/ftp/incoming/',
     MAXRETRIES => 16,
     MIRRORCONFIG => '/usr/local/mirror/mymirror.config',
     MLROOT => '/home/ftp/pub/PAUSE/authors/id/',
     MOD_DATA_SOURCE_NAME => "dbi:mysql:mod",
     NO_SUCCESS_BREAK => 900,
     P5P => 'perl-release-announce@perl.org',
     PAUSE_LOG => "/home/k/PAUSE/log/paused.log",
     PAUSE_LOG_DIR => "/home/k/PAUSE/log/",
     PAUSE_PUBLIC_DATA => '/home/ftp/pub/PAUSE/PAUSE-data',
     PML => 'ftp://pause.perl.org/pub/PAUSE/authors/id/',
     RUNDATA => "/usr/local/apache/rundata/pause_1999",
     RUNTIME_MLDISTWATCH => 600, # 720 was the longest of on 2003-08-10,
                                 # 2004-12-xx we frequently see >20 minutes
                                 # 2006-05-xx 7-9 minutes observed
     SLEEP => 75,
     # path to repository without "/trunk"
     SVNPATH => "/home/SVN/repos",
     # path to where we find the svn binaries
     SVNBIN => "/usr/bin",
     TIMEOUT => 60*60,
     TMP => '/home/ftp/tmp/',
     UPLOAD => 'upload@pause.perl.org',
     # sign the auto-generated CHECKSUM files with:
     CHECKSUMS_SIGNING_PROGRAM => ('gpg --homedir /home/k/PAUSE/111_sensi'.
                                   'tive/gnupg-pause-batch-signing-home  '.
                                   '--clearsign --default-key '),
     CHECKSUMS_SIGNING_KEY => '450F89EC',
     BATCH_SIG_HOME => '/home/k/PAUSE/111_sensitive/gnupg-pause-batch-signing-home',
     MIN_MTIME_CHECKSUMS => (time - 60*60*24*365.25), # max one year old
    };


eval { require PrivatePAUSE; };
if ($@) {
  # warn "Could not find or read PrivatePAUSE.pm; will try to work without";
}


=pod

The following $PAUSE::Config keys are defined in PrivatePAUSE.pm:

              AUTHEN_DATA_SOURCE_USER
              AUTHEN_DATA_SOURCE_PW
              MOD_DATA_SOURCE_USER
              MOD_DATA_SOURCE_PW

These are usernames and passwords in the two mysql databases.

=cut


=over

=item downtimeinfo

returns a hashref with keys C<downtime> and C<willlast>. C<downtime>
is an integer denoting the system time (measured in epoch seconds) of
the next downtime event. C<willlast> is an integer measuring seconds.

If the downtime is in the future, we display an announcement on all
pages. If we are now in the interval between the start of the downtime
and the expected end, we display a trivial page saying I<closed for
maintainance> while returning a 500 Server Error. This even works when
mysql is not running (server error + custom response). Interestingly,
it does not work if the user does not supply credentials at all.

If current time is after the last downtime event plus scheduled
downtime, then we're back to normal operation.

=back

=cut

sub downtimeinfo {
  return +{
           downtime => 1197317508,
           willlast => 0,
          };
}

sub filehash {
  my($file) = @_;
  my($ret,$authorfile,$size,$md5,$hexdigest);
  $ret = "";
  if (substr($file,0,length($Config->{MLROOT})) eq $Config->{MLROOT}) {
    $authorfile = "\$CPAN/authors/id/" . 
	substr($file,length($Config->{MLROOT}));
  } else {
    $authorfile = $file;
  }
  $size = -s $file;
  $md5 = MD5->new;
  local *HANDLE;
  unless ( open HANDLE, "< $file\0" ){
    $ret .= "An error occurred, couldn't open $file: $!"
  }
  $md5->addfile(*HANDLE);
  close HANDLE;
  $hexdigest = $md5->hexdigest;
  $ret .= qq{
  file: $authorfile
  size: $size bytes
   md5: $hexdigest
};
  return $ret;
}

sub dbh {
  my($db) = shift || "mod";
  my $dsn = $PAUSE::Config->{uc($db)."_DATA_SOURCE_NAME"};
  warn "DEBUG: dsn[$dsn]";
  DBI->connect(
               $dsn,
               $PAUSE::Config->{uc($db)."_DATA_SOURCE_USER"},
               $PAUSE::Config->{uc($db)."_DATA_SOURCE_PW"},
               { RaiseError => 1 }
              )
      or Carp::croak(qq{Can't DBI->connect(): $DBI::errstr});
}

sub urecord {
  my($ruser) = @_;
  return unless $ruser;
  my $db = dbh("mod");
  my $query = qq{SELECT *
                 FROM users
                 WHERE userid=?};
  my $sth = $db->prepare($query);
  $sth->execute($ruser);
  if ($sth->rows == 0) {
    $sth->execute(uc $ruser);
  }
  $sth->fetchrow_hashref;
}

sub user2dir {
  my($user) = @_;
  my(@l) = $user =~ /^(.)(.)/;
  my $result = "$l[0]/$l[0]$l[1]/$user";
  if (
      -d "$PAUSE::Config->{MLROOT}/$user"
      && !
      -d "$PAUSE::Config->{MLROOT}/$result"
     ) {
    $result = $user;
  }
  $result;
}

# available as pause_1999::main::file_to_user method
sub dir2user {
  my($uriid) = @_;
  $uriid =~ s|^/?authors/id||;
  $uriid =~ s|^/||;
  my $ret;
  if ($uriid =~ m|^\w/| ) {
    ($ret) = $uriid =~ m|\w/\w\w/([^/]+)/|;
  } else {
    ($ret) = $uriid =~ m!(.*?)/!;
  }
  $ret;
}

sub user_is {
  my($class,$user,$group) = @_;
  my $db = dbh("authen");
  my $ret;
  my $sth = $db->prepare(qq{
    SELECT ugroup FROM grouptable WHERE user='$user' AND ugroup='$group'
  });
  $ret = $sth->execute;
  return unless $ret;
  $ret = $sth->rows;
  $sth->finish;
  $db->disconnect;
  return $ret;
}

sub owner_of_module {
    my($m, $dbh) = @_;
    $dbh ||= dbh();
    my %query = (
                 mods => qq{SELECT modid,
                          userid
                   FROM mods where modid = ?},
                 primeur => qq{SELECT package,
                          userid
                   FROM primeur where package = ?},
                );
    for my $table (qw(mods primeur)) {
        my $sth = $dbh->prepare($query{$table});
        $sth->execute($m);
        if ($sth->rows >= 1) {
            return $sth->fetchrow_array; # ascii guaranteed
        }
    }
    return;
}

sub gzip {
  my($read,$write) = @_;
  my($buffer,$fhw);
  unless ($fhw = IO::File->new($read)) {
    warn("Could not open $read: $!");
    return;
  }
  my $gz;
  unless ($gz = Compress::Zlib::gzopen($write, "wb9")) {
    warn("Cannot gzopen $write: $!\n");
    return;
  }
  $gz->gzwrite($buffer)
      while read($fhw,$buffer,4096) > 0 ;
  $gz->gzclose() ;
  $fhw->close;
  return 1;
}

sub gunzip {
  my($read,$write) = @_;
  unless ($write) {
    warn "gunzip called without write argument";
    warn join ":", caller;
    warn "nothing done";
    return;
  }

  my($buffer,$fhw);
  unless ($fhw = IO::File->new(">$write\0")) {
    warn("Could not open >$write: $!");
    return;
  }
  my $gz;
  unless ($gz = Compress::Zlib::gzopen($read, "rb")) {
    warn("Cannot gzopen $read: $!\n");
    return;
  }
  $fhw->print($buffer)
      while $gz->gzread($buffer) > 0 ;
  if ($gz->gzerror != &Compress::Zlib::Z_STREAM_END) {
    warn("Error reading from $read: $!\n");
    return;
  }
  $gz->gzclose() ;
  $fhw->close;
  return 1;
}

sub gtest {
  my($class,$read) = @_;
  my($buffer);
  my $gz;
  unless (
	  $gz = Compress::Zlib::gzopen($read, "rb")
	 ) {
    warn("Cannot open $read: $!\n");
    return;
  }
  1 while $gz->gzread($buffer) > 0 ;
  if ($gz->gzerror != &Compress::Zlib::Z_STREAM_END) {
    warn("Error reading from $read: $!\n");
    return;
  }
  $gz->gzclose() ;
  return 1;
}

# log4perl!
#sub hooklog {
#  my($f) = @_;
#  open my $fh, ">>", "/tmp/hook.log";
#  use Carp;
#  printf $fh "%s: %s [%s]\n", scalar localtime, $f, Carp::longmess();
#}

our @common_args =
    (
     canonize => "naive_path_normalize",
     interval => q(6h),
     filenameroot => "RECENT",
     protocol => 1,
     comment => "These 'RECENT' files are part of a test of a new CPAN mirroring concept. Please ignore them for now.",
    );

sub newfile_hook ($) {
  my($f) = @_;
  my $rf;
  $rf = File::Rsync::Mirror::Recentfile->new
      (
       @common_args,
       localroot => "/home/ftp/pub/PAUSE/authors/",
       aggregator => [qw(1d 1W 1M 1Q 1Y Z)],
      );
  $rf->update($f,"new");
  $rf = File::Rsync::Mirror::Recentfile->new
      (
       @common_args,
       localroot => "/home/ftp/pub/PAUSE/modules/",
       aggregator => [qw(1W Z)],
      );
  $rf->update($f,"new");
}

sub delfile_hook ($) {
  my($f) = @_;
  my $rf;
  $rf = File::Rsync::Mirror::Recentfile->new
      (
       @common_args,
       localroot => "/home/ftp/pub/PAUSE/authors/",
       aggregator => [qw(1d 1W 1M 1Q 1Y Z)],
      );
  $rf->update($f,"delete");
  $rf = File::Rsync::Mirror::Recentfile->new
      (
       @common_args,
       localroot => "/home/ftp/pub/PAUSE/modules/",
       aggregator => [qw(1W Z)],
      );
  $rf->update($f,"delete");
}

{
  # File::Mirror           (JWU/File-Mirror/File-Mirror-0.10.tar.gz)      only local trees
  # Mirror::YAML           (ADAMK/Mirror-YAML-0.03.tar.gz)                some sort of inner circle
  # Net::DownloadMirror    (KNORR/Net-DownloadMirror-0.04.tar.gz)         FTP sites and stuff
  # Net::MirrorDir         (KNORR/Net-MirrorDir-0.05.tar.gz)              "
  # Net::UploadMirror      (KNORR/Net-UploadMirror-0.06.tar.gz)           "
  # Pushmi::Mirror         (CLKAO/Pushmi-v1.0.0.tar.gz)                   something SVK

  package File::Rsync::Mirror::Recentfile;

  use File::Basename qw(dirname);
  use File::Path qw(mkpath);
  use File::Rsync;
  use File::Temp;
  use Scalar::Util qw(reftype);
  use Time::HiRes qw();
  use YAML::Syck;

  use constant MAX_INT => ~0>>1; # anything better?

  # cf. interval_secs
  my %seconds = (
                 s => 1,
                 m => 60,
                 h => 60*60,
                 d => 60*60*24,
                 W => 60*60*24*7,
                 M => 60*60*30,
                 Q => 60*60*90,
                 Y => 60*60*365.25,
                );

  use accessors (
                 "_current_tempfile",
                 "_is_locked",
                 "_remotebase",
                 "_rfile",
                 "_rsync",
                 "_use_tempfile",
                 "aggregator",
                 "canonize",
                 "comment",
                 "filenameroot",
                 "ignore_link_stat_errors",
                 "interval",
                 "localroot",
                 "protocol",            # reader/writer modifier
                 "remote_dir",
                 "remote_host",
                 "remote_module",
                 "rsync_options",
                 "verbose",
                );

  sub new {
    my($class, @args) = @_;
    my $self = bless {}, $class;
    while (@args) {
      my($method,$arg) = splice @args, 0, 2;
      $self->$method($arg);
    }
    unless (defined $self->protocol) {
      $self->protocol(0); # default protocol will soon be 1
    }
    unless (defined $self->filenameroot) {
      $self->filenameroot("RECENT");
    }
    return $self;
  }

  sub rfile {
    my($self) = @_;
    if ($self->_use_tempfile) {
      return $self->_current_tempfile;
    } else {
      my $rfile = $self->_rfile;
      return $rfile if defined $rfile;
      $rfile = File::Spec->catfile
          ($self->localroot,
           sprintf ("%s-%s.yaml",
                    $self->filenameroot,
                    $self->interval,
                   )
          );
      $self->_rfile ($rfile);
      return $rfile;
    }
  }

  sub update {
    my($self,$path,$type) = @_;
    if (my $meth = $self->canonize) {
      if (ref $meth && ref $meth eq "CODE") {
        die "FIXME";
      } else {
        $path = $self->$meth($path);
      }
    }
    my $lrd = $self->localroot;
    if ($path =~ s|^\Q$lrd\E||) {
      my $interval = $self->interval;
      my $secs = $self->interval_secs();
      my $epoch = Time::HiRes::time;
      my $oldest_allowed = $epoch-$secs;

      $self->lock;
      my $recent = $self->recent_events;
      $recent ||= [];
    TRUNCATE: while (@$recent) {
        if ($recent->[-1]{epoch} < $oldest_allowed) {
          pop @$recent;
        } else {
          last TRUNCATE;
        }
      }
      # remove older duplicates of this $path, irrespective of $type:
      $recent = [ grep { $_->{path} ne $path } @$recent ];

      unshift @$recent, { epoch => $epoch, path => $path, type => $type };
      $self->write_recent($recent);
      $self->unlock;
    }
  }

  sub lock {
    my ($self) = @_;
    # not using flock because it locks on filehandles instead of
    # old school ressources.
    my $locked = $self->_is_locked and return;
    my $rfile = $self->rfile;
    # XXX need a way to allow breaking the lock
    while (not mkdir "$rfile.lock") {
      Time::HiRes::sleep 0.01;
    }
    $self->_is_locked (1);
  }

  sub unlock {
    my($self) = @_;
    return unless $self->_is_locked;
    my $rfile = $self->rfile;
    rmdir "$rfile.lock";
    $self->_is_locked (0);
  }

  sub write_recent {
    my ($self,$recent) = @_;
    my $meth = sprintf "write_%d", $self->protocol;
    $self->$meth($recent);
  }

  sub write_0 {
    my ($self,$recent) = @_;
    my $rfile = $self->rfile;
    YAML::Syck::DumpFile("$rfile.new",$recent);
    rename "$rfile.new", $rfile or die "Could not rename to '$rfile': $!";
  }

  sub write_1 {
    my ($self,$recent) = @_;
    my $rfile = $self->rfile;
    YAML::Syck::DumpFile("$rfile.new",{
                                       meta => $self->meta_data,
                                       recent => $recent,
                                      });
    rename "$rfile.new", $rfile or die "Could not rename to '$rfile': $!";
  }

  sub meta_data {
    my($self) = @_;
    my $ret = {};
    for my $m (
               "aggregator",
               "canonize",
               "comment",
               "filenameroot",
               "interval_secs",
               "protocol",
              ) {
      $ret->{$m} = $self->$m;
    }
    return $ret;
  }

  sub naive_path_normalize {
    my($self,$path) = @_;
    $path =~ s|/+|/|g;
    1 while $path =~ s|/[^/]+/\.\./|/|;
    $path =~ s|/$||;
    $path;
  }

  sub recent_events_from_tempfile {
    my ($self) = @_;
    $self->_use_tempfile(1);
    my $ret = $self->recent_events;
    $self->_use_tempfile(0);
    return $ret;
  }

  # the code relies on the resource being written atomically. We
  # cannot lock because we may have no write access.
  sub recent_events {
    my ($self) = @_;
    my $rfile = $self->rfile;
    my ($data) = eval {YAML::Syck::LoadFile($rfile);};
    my $err = $@;
    if ($err or !$data) {
      return [];
    }
    if (reftype $data eq 'ARRAY') { # protocol 0
      return $data;
    } else {
      my $meth = sprintf "read_recent_%d", $data->{meta}{protocol};
      return $self->$meth($data);
    }
  }

  sub read_recent_1 {
    my($self,$data) = @_;
    return $data->{recent};
  }

  sub local_event_path {
    my($self,$path) = @_;
    my @p = split m|/|, $path; # rsync paths are always slash-separated
    File::Spec->catfile($self->localroot,@p);
  }

  sub mirror_path {
    my($self,$path) = @_;
    my $dst = $self->local_event_path($path);
    mkpath dirname $dst;
    unless ($self->rsync->exec
            (
             src => join("/",
                         $self->remotebase,
                         $path
                        ),
             dst => $dst,
            )) {
      my($err) = $self->rsync->err;
      if ($self->ignore_link_stat_errors && $err =~ m{^ rsync: \s link_stat }x ) {
        if ($self->verbose) {
          warn "Info: ignoring link_stat error '$err'";
        }
        return 1;
      }
      die sprintf "Error: %s", $err;
    }
    return 1;
  }

  sub get_remote_recentfile_as_tempfile {
    my($self) = @_;
    my($fh) = File::Temp->new(TEMPLATE => sprintf(".%s-XXXX",
                                                  $self->filenameroot,
                                                 ),
                              DIR => $self->localroot,
                              SUFFIX => ".yaml",
                              UNLINK => 0,
                             );
    my($trecentfile) = $fh->filename;
    unless ($self->rsync->exec(
                               src => join("/",
                                           $self->remotebase,
                                           $self->recentfile_basename),
                               dst => $trecentfile,
                              )) {
      unlink $trecentfile or die "Couldn't unlink '$trecentfile': $!";
      die sprintf "Error while rsyncing: %s", $self->rsync->err;
    }
    my $mode = 0644;
    chmod $mode, $trecentfile or die "Could not chmod $mode '$trecentfile': $!";
    $self->_current_tempfile ($trecentfile);
    return $trecentfile;
  }

  sub recentfile {
    my($self) = @_;
    my $recent = File::Spec->catfile(
                                     $self->localroot,
                                     $self->recentfile_basename(),
                                    );
    return $recent;
  }

  sub recentfile_basename {
    my($self) = @_;
    my $interval = $self->interval;
    my $file = sprintf("%s-%s.yaml",
                       $self->filenameroot,
                       $interval
                      );
    return $file;
  }

  sub interval_secs {
    my ($self) = @_;
    my $interval = $self->interval;
    my ($n,$t) = $interval =~ /^(\d*)([smhdWMYZ]$)/ or
        die "Could not determine seconds from interval[$interval]";
    if ($interval eq "Z") {
      return MAX_INT;
    } elsif (exists $seconds{$t} and $n =~ /^\d+$/) {
      return $seconds{$t}*$n;
    } else {
      die "Invalid interval specification: n[$n]t[$t]";
    }
  }

  sub remotebase {
    my($self) = @_;
    my $remotebase = $self->_remotebase;
    unless (defined $remotebase) {
      $remotebase = sprintf(
                            "%s::%s%s",
                            $self->remote_host,
                            $self->remote_module,
                            ($self->remote_dir ? ("/".$self->remote_dir) : ""),
                           );
      $self->_remotebase($remotebase);
    }
    return $remotebase;
  }

  sub rsync {
    my($self) = @_;
    my $rsync = $self->_rsync;
    unless (defined $rsync) {
      my $rsync_options = $self->rsync_options || {};
      $rsync = File::Rsync->new($rsync_options);
      $self->_rsync($rsync);
    }
    return $rsync;
  }
}

1;

# Local Variables:
# mode: cperl
# cperl-indent-level: 2
# End:
