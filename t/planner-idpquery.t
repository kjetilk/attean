use strict;
use warnings;
use Test::More;
use Test::Moose;
no warnings 'redefine';
use utf8;

use RDF::Query;

use Attean;
use Attean::RDF;
use_ok('AtteanX::RDFQueryTranslator');

my $graph	= Attean::IRI->new('http://example.org/graph');
my $query	= RDF::Query->new(<<"END");
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT DISTINCT * WHERE {
	?s a foaf:Person ;
		foaf:name ?name ;
		foaf:nick "kasei" .
	FILTER(ISIRI(?s))
}
ORDER BY ?name
END

isa_ok($query, 'RDF::Query');

note "Translating query...";
my $t		= AtteanX::RDFQueryTranslator->new();
my $algebra	= $t->translate_query($query);
does_ok($algebra, 'Attean::API::Algebra');

my $store	= Attean->get_store('Memory')->new();
does_ok($store, 'Attean::API::MutableQuadStore');

my $model	= Attean::MutableQuadModel->new( store => $store );
my $planner	= Attean::IDPQueryPlanner->new();
does_ok($planner, 'Attean::API::CostPlanner');
my $plan	= $planner->plan_for_algebra($algebra, $model, $graph);
isa_ok($plan, 'Attean::Plan::Project');

my $cost	= $planner->cost_for_plan($plan, $model);
note ("Query plan (cost: $cost)");
#print $plan->as_string;

done_testing;
