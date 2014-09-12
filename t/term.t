use v5.14;
use utf8;
use Data::Dumper;
use Test::More;
use Type::Tiny::Role;
use Attean::RDF;

is(iri('http://example.org/')->ntriples_string, '<http://example.org/>', 'IRI ntriples_string');
is(iri('http://example.org/✪')->ntriples_string, '<http://example.org/\u272A>', 'unicode IRI ntriples_string');
is(literal("🐶\\\n✪")->ntriples_string, qq["🐶\\\\\\n✪"], 'unicode literal ntriples_string');
is(literal('Eve')->ntriples_string, '"Eve"', 'literal ntriples_string');
is(langliteral('Eve', 'en')->ntriples_string, '"Eve"@en', 'lang-literal ntriples_string');
is(blank('eve')->ntriples_string, '_:eve', 'blank ntriples_string');

ok(Attean::Literal->integer(1)->ebv, '1 EBV');
ok(not(Attean::Literal->integer(0)->ebv), '0 EBV');
ok(not(literal('')->ebv), '"" EBV');
ok(literal('foo')->ebv, '"foo" EBV');
ok(blank('foo')->ebv, '_:foo EBV');
ok(iri('foo')->ebv, '<foo> EBV');

{
	my $l1	= literal(7);
	my $l2	= literal(10);
	is($l1->compare($l2), 1, 'non-numeric literal sort');
}

{
	my $i1	= Attean::Literal->integer(7);
	my $i2	= Attean::Literal->integer(10);
	
	does_ok($i1, 'Attean::API::NumericLiteral');
	does_ok($i2, 'Attean::API::NumericLiteral');
	
	is($i1->compare($i2), -1, 'numeric literal sort');
}

done_testing();

sub does_ok {
    my ($class_or_obj, $does, $message) = @_;
    $message ||= "The object does $does";
    ok(eval { $class_or_obj->does($does) }, $message);
}