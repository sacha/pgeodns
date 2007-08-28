use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile
  (
   NAME                => 'pgeodns',
   AUTHOR              => 'Ask Bjoern Hansen <ask@develooper.com>',
   VERSION_FROM        => 'lib/GeoDNS.pm',
   ABSTRACT            => "Perl Geographic DNS Server",
   PL_FILES            => { },
   EXE_FILES           => [ 'pgeodns.pl' ],
   #    PM => {
   #        'GeoDNS.pm' => '$(INST_LIBDIR)/App/HWD.pm',
   #    },
   PREREQ_PM => 
   {
    'Net::DNS' => 0,
    'Net::DNS::Nameserver' => 0,
    'Geo::IP' => 0,
    'List::Util' => 0,
    'JSON' => 0,
   },
   MAN3PODS            => { }, # no need for docs on these
   dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
   clean               => { FILES => 'cover_db pm_to_blib' },
);

sub MY::postamble {
    return <<'MAKE_FRAG';

.PHONY: testcover

testcover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover make test
	cover

MAKE_FRAG
}