use v5.14;
use warnings;

=head1 NAME

Attean::IDPQueryPlanner - Iterative dynamic programming query planner

=head1 VERSION

This document describes Attean::IDPQueryPlanner version 0.004

=head1 SYNOPSIS

  use v5.14;
  use Attean;
  my $planner = Attean::IDPQueryPlanner->new();
  my $default_graphs = [ Attean::IRI->new('http://example.org/') ];
  my $plan = $planner->plan_for_algebra( $algebra, $model, $default_graphs );
  my $iter = $plan->evaluate($model);
  my $iter = $e->evaluate( $model );

=head1 DESCRIPTION

The Attean::IDPQueryPlanner class implements a query planner using the
iterative dynamic programming approach.

=head1 ATTRIBUTES

=over 4

=cut

use Attean::Algebra;
use Attean::Plan;
use Attean::Expression;

package Attean::IDPQueryPlanner 0.004 {
	use Moo;
	use Encode qw(encode);
	use Attean::RDF qw(iri);
	use LWP::UserAgent;
	use Scalar::Util qw(blessed reftype refaddr);
	use List::Util qw(all any reduce);
	use Types::Standard qw(Int ConsumerOf InstanceOf);
	use URI::Escape;
	use Algorithm::Combinatorics qw(subsets);
	use List::Util qw(min);
	use Math::Cartesian::Product;
	use namespace::clean;

	with 'Attean::API::CostPlanner';
	has 'counter' => (is => 'rw', isa => Int, default => 0);
=back

=head1 METHODS

=over 4

=cut

	sub new_temporary {
		my $self	= shift;
		my $type	= shift;
		my $c		= $self->counter;
		$self->counter($c+1);
		return sprintf('.%s-%d', $type, $c);
	}
	
=item C<< plans_for_algebra( $algebra, $model, \@active_graphs, \@default_graphs ) >>

Returns L<Attean::API::Plan> objects representing alternate query plans for
evaluating the query C<< $algebra >> against the C<< $model >>, using
the supplied C<< $active_graph >>.

=cut

	sub plans_for_algebra {
		my $self			= shift;
		my $algebra			= shift;
		my $model			= shift;
		my $active_graphs	= shift;
		my $default_graphs	= shift;
		my %args			= @_;
		
		if ($model->does('Attean::API::CostPlanner')) {
			my @plans	= $model->plans_for_algebra($algebra, $model, $active_graphs, $default_graphs, @_);
			if (@plans) {
				return @plans; # trust that the model knows better than us what plans are best
			}
		}
		
		Carp::confess "No algebra passed for evaluation" unless ($algebra);
		
		# TODO: propagate interesting orders
		my $interesting	= [];
		
		my @children	= @{ $algebra->children };
		my ($child)		= $children[0];
		if ($algebra->isa('Attean::Algebra::BGP')) {
			my @plans	= $self->bgp_join_plans($algebra, $model, $active_graphs, $default_graphs, $interesting, map {
				[$self->access_plans($model, $active_graphs, $_)]
			} @{ $algebra->triples });
			return @plans;
		} elsif ($algebra->isa('Attean::Algebra::Join')) {
			return $self->group_join_plans($model, $active_graphs, $default_graphs, $interesting, map {
				[$self->plans_for_algebra($_, $model, $active_graphs, $default_graphs, @_)]
			} @children);
		} elsif ($algebra->isa('Attean::Algebra::Distinct') or $algebra->isa('Attean::Algebra::Reduced')) {
			my @plans	= $self->plans_for_algebra($child, $model, $active_graphs, $default_graphs, @_);
			my @dist;
			foreach my $p (@plans) {
				if ($p->distinct) {
					push(@dist, $p);
				} else {
					my @vars	= @{ $p->in_scope_variables };
					my $cmps	= $p->ordered;
					if ($self->_comparators_are_stable_and_cover_vars($cmps, @vars)) {
						# the plan has a stable ordering which covers all the variables, so we can just uniq the iterator
						push(@dist, Attean::Plan::Unique->new(children => [$p], distinct => 1, in_scope_variables => $p->in_scope_variables, ordered => $p->ordered));
					} else {
						# TODO: if the plan isn't distinct, but is ordered, we can use a batched implementation
						push(@dist, Attean::Plan::HashDistinct->new(children => [$p], distinct => 1, in_scope_variables => $p->in_scope_variables, ordered => $p->ordered));
					}
				}
			}
			return @dist;
		} elsif ($algebra->isa('Attean::Algebra::Filter')) {
			# TODO: simple range relation filters can be handled differently if that filter operates on a variable that is part of the ordering
			my $expr	= $algebra->expression;
			my $var		= $self->new_temporary('filter');
			my %exprs	= ($var => $expr);
			
			my @plans;
			foreach my $plan ($self->plans_for_algebra($child, $model, $active_graphs, $default_graphs, @_)) {
				my $distinct	= $plan->distinct;
				my $ordered		= $plan->ordered;
				my @vars		= ($var);
				my @pvars		= map { Attean::Variable->new($_) } @{ $plan->in_scope_variables };
				my $extend		= Attean::Plan::Extend->new(children => [$plan], expressions => \%exprs, distinct => 0, in_scope_variables => [@vars, $var], ordered => $ordered);
				my $filtered	= Attean::Plan::EBVFilter->new(children => [$extend], variable => $var, distinct => 0, in_scope_variables => \@vars, ordered => $ordered);
				my $proj		= $self->new_projection($filtered, $distinct, @{ $plan->in_scope_variables });
				push(@plans, $proj);
			}
			return @plans;
		} elsif ($algebra->isa('Attean::Algebra::OrderBy')) {
			# TODO: no-op if already ordered
			my @cmps	= @{ $algebra->comparators };
			my %ascending;
			my %exprs;
			my @svars;
			foreach my $i (0 .. $#cmps) {
				my $var	= $self->new_temporary('order');
				my $cmp	= $cmps[$i];
				push(@svars, $var);
				$ascending{$var}	= $cmp->ascending;
				$exprs{$var}		= $cmp->expression;
			}
			
			my @plans;
			foreach my $plan ($self->plans_for_algebra($child, $model, $active_graphs, $default_graphs, interesting_order => $algebra->comparators, @_)) {
				my $distinct	= $plan->distinct;
				my @vars	= (@{ $plan->in_scope_variables }, keys %exprs);
				my @pvars	= map { Attean::Variable->new($_) } @{ $plan->in_scope_variables };
				my $extend	= Attean::Plan::Extend->new(children => [$plan], expressions => \%exprs, distinct => 0, in_scope_variables => \@vars, ordered => $plan->ordered);
				my $ordered	= Attean::Plan::OrderBy->new(children => [$extend], variables => \@svars, ascending => \%ascending, distinct => 0, in_scope_variables => \@vars, ordered => \@cmps);
				my $proj	= $self->new_projection($ordered, $distinct, @{ $plan->in_scope_variables });
				push(@plans, $proj);
			}
			
			return @plans;
		} elsif ($algebra->isa('Attean::Algebra::LeftJoin')) {
			my $l	= [$self->plans_for_algebra($children[0], $model, $active_graphs, $default_graphs, @_)];
			my $r	= [$self->plans_for_algebra($children[1], $model, $active_graphs, $default_graphs, @_)];
			return $self->join_plans($model, $active_graphs, $default_graphs, $l, $r, 1, 0, $algebra->expression);
		} elsif ($algebra->isa('Attean::Algebra::Minus')) {
			return $self->join_plans($model, $active_graphs, $default_graphs, @children[0,1], 0, 1);
		} elsif ($algebra->isa('Attean::Algebra::Project')) {
			my $vars	= $algebra->variables;
			my @vars	= map { $_->value } @{ $vars };
			my $vars_key	= join(' ', sort @vars);
			my $distinct	= 0;
			my @plans	= map {
				($vars_key eq join(' ', sort @{ $_->in_scope_variables }))
					? $_ # no-op if plan is already properly-projected
					: $self->new_projection($_, $distinct, @vars)
			} $self->plans_for_algebra($child, $model, $active_graphs, $default_graphs, @_);
			return @plans;
		} elsif ($algebra->isa('Attean::Algebra::Graph')) {
			my $graph	= $algebra->graph;
			if ($graph->does('Attean::API::Term')) {
				return $self->plans_for_algebra($child, $model, $graph, @_);
			} else {
				my $gvar	= $graph->value;
				my $graphs	= $model->get_graphs;
				my @plans;
				my %vars		= map { $_ => 1 } $child->in_scope_variables;
				$vars{ $gvar }++;
				my @vars	= keys %vars;
				
				my @branches;
				my %ignore	= map { $_->value => 1 } @$default_graphs;
				while (my $graph = $graphs->next) {
					next if $ignore{ $graph->value };
					my %exprs	= ($gvar => Attean::ValueExpression->new(value => $graph));
					# TODO: rewrite $child pattern here to replace any occurrences of the variable $gvar to $graph
					my @plans	= map {
						Attean::Plan::Extend->new(children => [$_], expressions => \%exprs, distinct => 0, in_scope_variables => \@vars, ordered => $_->ordered);
					} $self->plans_for_algebra($child, $model, [$graph], $default_graphs, @_);
					push(@branches, \@plans);
				}
				
				if (scalar(@branches) == 1) {
					@plans	= @{ shift(@branches) };
				} else {
					cartesian { push(@plans, Attean::Plan::Union->new(children => [@_], distinct => 0, in_scope_variables => \@vars, ordered => [])) } @branches;
				}
				return @plans;
			}
		} elsif ($algebra->isa('Attean::Algebra::Table')) {
			my $rows	= $algebra->rows;
			my $vars	= $algebra->variables;
			my @vars	= map { $_->value } @{ $vars };
			my $plan	= Attean::Plan::Table->new( variables => $vars, rows => $rows, distinct => 0, in_scope_variables => \@vars, ordered => [] );
			return $plan;
		} elsif ($algebra->isa('Attean::Algebra::Service')) {
			my $endpoint	= $algebra->endpoint;
			my $silent		= $algebra->silent;
			my $sparql		= sprintf('SELECT * WHERE { %s }', $child->as_sparql);
			my @vars		= $child->in_scope_variables;
			my $plan		= Attean::Plan::Service->new( endpoint => $endpoint, silent => $silent, sparql => $sparql, distinct => 0, in_scope_variables => \@vars, ordered => [] );
			return $plan;
		} elsif ($algebra->isa('Attean::Algebra::Slice')) {
			my $limit	= $algebra->limit;
			my $offset	= $algebra->offset;
			my @plans;
			foreach my $plan ($self->plans_for_algebra($child, $model, $active_graphs, $default_graphs, @_)) {
				my $vars	= $plan->in_scope_variables;
				push(@plans, Attean::Plan::Slice->new(children => [$plan], limit => $limit, offset => $offset, distinct => $plan->distinct, in_scope_variables => $vars, ordered => $plan->ordered));
			}
			return @plans;
		} elsif ($algebra->isa('Attean::Algebra::Union')) {
			# TODO: if both branches are similarly ordered, we can merge the branches and keep the ordering
			my @vars		= keys %{ { map { map { $_ => 1 } $_->in_scope_variables } @children } };
			my @plansets	= map { [$self->plans_for_algebra($_, $model, $active_graphs, $default_graphs, @_)] } @children;

			my @plans;
			cartesian { push(@plans, Attean::Plan::Union->new(children => \@_, distinct => 0, in_scope_variables => \@vars, ordered => [])) } @plansets;
			return @plans;
		} elsif ($algebra->isa('Attean::Algebra::Extend')) {
		} elsif ($algebra->isa('Attean::Algebra::Group')) {
		} elsif ($algebra->isa('Attean::Algebra::Path')) {
		} elsif ($algebra->isa('Attean::Algebra::Ask')) {
		} elsif ($algebra->isa('Attean::Algebra::Construct')) {
		}
		die "Unimplemented algebra evaluation for: $algebra";
	}
	
	sub new_projection {
		my $self		= shift;
		my $plan		= shift;
		my $distinct	= shift;
		my @vars		= @_;
		my $order		= $plan->ordered;
		my @pvars		= map { Attean::Variable->new($_) } @vars;
		
		my %pvars		= map { $_ => 1 } @vars;
		my @porder;
		CMP: foreach my $cmp (@{ $order }) {
			my @cmpvars	= $self->_comparator_referenced_variables($cmp);
			foreach my $v (@cmpvars) {
				unless ($pvars{ $v }) {
					# projection is dropping a variable used in this comparator
					# so we lose any remaining ordering that the sub-plan had.
					last CMP;
				}
			}
			
			# all the variables used by this comparator are available after
			# projection, so the resulting plan will continue to be ordered
			# by this comparator
			push(@porder, $cmp);
		}
		
		return Attean::Plan::Project->new(children => [$plan], variables => \@pvars, distinct => $distinct, in_scope_variables => \@vars, ordered => \@porder);
	}
	
=item C<< bgp_join_plans( $bgp, $model, \@active_graphs, \@default_graphs, \@interesting_order, \@plansA, \@plansB, ... ) >>

Returns a list of alternative plans for the join of a set of triples.
The arguments C<@plansA>, C<@plansB>, etc. represent alternative plans for each
triple participating in the join.

=cut

	sub bgp_join_plans {
		my $self			= shift;
		my $bgp				= shift;
		my @plans			= $self->_IDPJoin(@_);
		my @triples			= @{ $bgp->triples };
		
		# If the BGP does not contain any blanks, then the results are
		# guaranteed to be distinct. Otherwise, we have to assume they're
		# not distinct.
		my $distinct		= 1;
		LOOP: foreach my $t (@triples) {
			foreach my $b ($t->values_consuming_role('Attean::API::Blank')) {
				$distinct	= 0;
				last LOOP;
			}
		}
		
		# Set the distinct flag on each of the top-level join plans that
		# represents the entire BGP. (Sub-plans won't ever be marked as
		# distinct, but that shouldn't matter to the rest of the planning
		# process.)
		if ($distinct) {
			foreach my $p (@plans) {
				$p->distinct(1);
			}
		}
		return @plans;
	}
	
=item C<< group_join_plans( $model, \@active_graphs, \@default_graphs, \@interesting_order, \@plansA, \@plansB, ... ) >>

Returns a list of alternative plans for the join of a set of sub-plans.
The arguments C<@plansA>, C<@plansB>, etc. represent alternative plans for each
sub-plan participating in the join.

=cut

	sub group_join_plans {
		my $self			= shift;
		return $self->_IDPJoin(@_);
	}
	
	sub _IDPJoin {
		my $self			= shift;
		my $model			= shift;
		my $active_graphs	= shift;
		my $default_graphs	= shift;
		my $interesting		= shift;
		my @args			= @_; # each $args[$i] here is an array reference containing alternate plans for element $i

		my $k				= 3; # this is the batch size over which to do full dynamic programming
		
		# initialize $optPlan{$i} to be a set of alternate plans for evaluating element $i
		my %optPlan;
		foreach my $i (0 .. $#args) {
			$optPlan{$i}	= [$self->prune_plans($model, $interesting, $args[$i])];
		}
		
		my @todo	= (0 .. $#args); # initialize the todo list to all elements
		my $next_symbol	= 'a'; # when we start batching together sub-plans, we'll rename them with letters (e.g. elements 1, 2, and 4 might become 'a', and then 3, 5, and 'a' become 'b')
		
		# until we've joined all the elements in todo and are left with a set of plans for the join of all elements
		while (scalar(@todo) > 1) {
			$k	= ($k < scalar(@todo)) ? $k : scalar(@todo); # in case we're joining fewer than the batch size
			foreach my $i (2 .. $k) { # we've already initialized plans for evaluating single elements; now consider plans for groups of elements (with group sizes 2, 3, ..., $k)
				foreach my $s (subsets(\@todo, $i)) { # pick a subset of size $i of the elements that need to be planned
					my $s_key	= join('.', sort @$s);
					$optPlan{$s_key}	= [];
					foreach my $o (subsets($s)) { # partition the subset s into two (o and not_o)
						next if (scalar(@$o) == 0); # only consider proper, non-empty subsets
						next if (scalar(@$o) == scalar(@$s)); # only consider proper, non-empty subsets
						my $o_key	= join('.', sort @$o);
						my %o		= map { $_ => 1 } @$o;
						my $not_o_key	= join('.', sort grep { not exists $o{$_} } @$s);
						
						my $lhs		= $optPlan{$o_key}; # get the plans for evaluating o
						my $rhs		= $optPlan{$not_o_key}; # get the plans for evaluating not_o
						
						# compute and store all the possible ways to evaluate s (o ⋈ not_o)
						push(@{ $optPlan{$s_key} }, $self->join_plans($model, $active_graphs, $default_graphs, $lhs, $rhs, 0, 0));
						$optPlan{$s_key}	= [$self->prune_plans($model, $interesting, $optPlan{$s_key})];
					}
				}
			}
			
			# find the minimum cost plan $p that computes the join over $k elements (the elements end up in @v)
			my %min_plans;
			foreach my $w (subsets(\@todo, $k)) {
				my $w_key	= join('.', sort @$w);
				my $plans	= $optPlan{$w_key};
				my %costs	= map { $self->cost_for_plan($_, $model) => [$_, $w] } @$plans;
				my $min		= min keys %costs;
				my $min_plan	= $costs{ $min };
				$min_plans{ $min }	= $min_plan;
			}
			my $min_cost	= min keys %min_plans;
			my $min_plan	= $min_plans{$min_cost};
			my ($p, $v)		= @$min_plan;
			my $v_key		= join('.', sort @$v);
# 			warn "Choosing join for $v_key\n";
			
			# generate a new symbol $t to stand in for $p, the join over the elements in @v
			my $t	= $next_symbol++;
			
			# remove elements in @v from the todo list, and replace them by the new composite element $t
			$optPlan{$t}	= [$p];
			my %v	= map { $_ => 1 } @$v;
			push(@todo, $t);
			@todo	= grep { not exists $v{$_} } @todo;
			
			# also remove subsets of @v from the optPlan hash as they are now covered by $optPlan{$t}
			foreach my $o (subsets($v)) {
				my $o_key	= join('.', sort @$o);
# 				warn "deleting $o_key\n";
				delete $optPlan{$o_key};
			}
		}
		
		my $final_key	= join('.', sort @todo);
		return $self->prune_plans($model, $interesting, $optPlan{$final_key});
	}
	
	sub prune_plans {
		my $self		= shift;
		my $model		= shift;
		my $interesting	= shift;
		my @plans		= @{ shift || [] };
		
		my @sorted	= map { $_->[1] } sort { $a->[0] <=> $b->[0] } map { [$self->cost_for_plan($_, $model), $_] } @plans;
		return splice(@sorted, 0, 5);
	}
	
	# $pattern is a Attean::API::TripleOrQuadPattern object
	# Return a Attean::API::Plan object that represents the evaluation of $pattern.
	# e.g. different plans might represent different ways of producing the matches (table scan, index match, etc.)
	sub access_plans {
		my $self			= shift;
		my $model			= shift;
		my $active_graphs	= shift;
		my $pattern			= shift;
		my @vars			= map { $_->value } grep { $_->does('Attean::API::Variable') } $pattern->values;
		my %vars;
		my $dup				= 0;
		foreach my $v (@vars) {
			$dup++ if ($vars{$v}++);
		}
		
		my $distinct		= 0; # TODO: is this pattern distinct? does it have blank nodes?
		
		my @nodes			= $pattern->values;
		unless ($nodes[3]) {
			$nodes[3]	= $active_graphs;
		}
		my $plan		= Attean::Plan::Quad->new( values => \@nodes, distinct => $distinct, in_scope_variables => \@vars, ordered => [] );
		return $plan;
	}
	
	# $lhs and $rhs are both Attean::API::Plan objects
	# Return a Attean::API::Plan object that represents the evaluation of $lhs ⋈ $rhs.
	# The $left and $minus flags indicate the type of the join to be performed (⟕ and ▷, respectively).
	# e.g. different plans might represent different join algorithms (nested loop join, hash join, etc.) or different orderings ($lhs ⋈ $rhs or $rhs ⋈ $lhs)
	sub join_plans {
		my $self			= shift;
		my $model			= shift;
		my $active_graphs	= shift;
		my $default_graphs	= shift;
		my $lplans			= shift;
		my $rplans			= shift;
		my $left			= shift;
		my $minus			= shift;
		my $expr			= shift;
		
		my @plans;
		Carp::confess unless (reftype($lplans) eq 'ARRAY');
		foreach my $lhs (@{ $lplans }) {
			foreach my $rhs (@{ $rplans }) {
				my @vars	= (@{ $lhs->in_scope_variables }, @{ $rhs->in_scope_variables });
				my %vars;
				foreach my $v (@vars) {
					$vars{$v}++;
				}
				my %join_vars;
				foreach my $l (@{ $lhs->in_scope_variables }) {
					foreach my $r (@{ $rhs->in_scope_variables }) {
						if ($l eq $r) {
							$join_vars{$l}++;
						}
					}
				}
				my @join_vars	= keys %join_vars;
		
				if ($left) {
					push(@plans, Attean::Plan::NestedLoopJoin->new(children => [$lhs, $rhs], left => 1, expression => $expr, join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => $lhs->ordered));
					if (scalar(@join_vars) > 0) {
						push(@plans, Attean::Plan::HashJoin->new(children => [$lhs, $rhs], left => 1, expression => $expr, join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => []));
					}
				} elsif ($minus) {
					push(@plans, Attean::Plan::NestedLoopJoin->new(children => [$lhs, $rhs], anti => 1, join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => $lhs->ordered));
					if (scalar(@join_vars) > 0) {
						push(@plans, Attean::Plan::HashJoin->new(children => [$lhs, $rhs], anti => 1, join_variables => \@join_vars, join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => []));
					}
				} else {
					# nested loop joins work in all cases
					push(@plans, Attean::Plan::NestedLoopJoin->new(children => [$lhs, $rhs], join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => $lhs->ordered));
					push(@plans, Attean::Plan::NestedLoopJoin->new(children => [$rhs, $lhs], join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => $rhs->ordered));
			
					if (scalar(@join_vars) > 0) {
						# if there's shared variables (hopefully), we can also use a hash join
						push(@plans, Attean::Plan::HashJoin->new(children => [$lhs, $rhs], join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => []));
						push(@plans, Attean::Plan::HashJoin->new(children => [$rhs, $lhs], join_variables => \@join_vars, distinct => 0, in_scope_variables => [keys %vars], ordered => []));
					}
				}
			}
		}
		return @plans;
	}
	
	# Return a cost value for $plan. This value is basically opaque, except
	# that it will be used to sort plans by cost when determining which is the
	# cheapest plan to evaluate.
	sub cost_for_plan {
		my $self	= shift;
		my $plan	= shift;
		my $model	= shift;
		Carp::confess "No valid model given" unless ref($model);
		use Data::Dumper;
		my $i =0;
		if ($plan->has_cost) {
			return $plan->cost;
		} else {
			if ($model->does('Attean::API::CostPlanner')) {
				if (defined(my $cost = $model->cost_for_plan($plan, $model))) {
					$plan->cost($cost);
					return $cost;
				}
			}

			my %hsp_join_candidates;
			# Implement Heuristic 2 from HSP
			$plan->walk(prefix => sub {
								my $p = shift;
								if ($p->isa('Attean::Plan::Quad')) {
									warn "Sum for " . $p->as_string . "\t" . $self->_hsp_heuristic_triple_sum($p);
									$hsp_join_candidates{refaddr($p)} = { thisquad => $p };
								}
							});
#			warn Dumper(\%hsp_join_candidates);
			foreach my $myref (keys(%hsp_join_candidates)) {
				my @mynodes = $hsp_join_candidates{$myref}{thisquad}->values;
				foreach my $otherref (keys(%hsp_join_candidates)) {
					next if ($myref == $otherref);
					my @othernodes = $hsp_join_candidates{$otherref}{thisquad}->values;
					for (my $myp = 0; $myp <= 2; $myp++) {
						for (my $otherp = 0; $otherp <= 2; $otherp++) {
							my $mynode = $mynodes[0][$myp];
							my $othernode = $othernodes[0][$otherp];
							if (blessed($mynode) && $mynode->does('Attean::API::Variable') 
								 && blessed($othernode) && $othernode->does('Attean::API::Variable') 
								 && $mynode->equals($othernode)) {
								# We have found a shared variable, now find the position
								$hsp_join_candidates{$myref}{other}{'m' . $myp . 'o' . $otherp} = $otherref;
							}
						}
					}
				}
			}

			# TODO: A quad in the hash that doesn't have 'other' but has in_scope_variables are cartesian

			#warn Dumper(\%hsp_join_candidates);
			my $cost	= 1;
			my @children	= @{ $plan->children };
			if ($plan->isa('Attean::Plan::Quad')) {
				my @vars	= map { $_->value } grep { blessed($_) and $_->does('Attean::API::Variable') } @{ $plan->values };
				return 3 * scalar(@vars);
			} elsif ($plan->isa('Attean::Plan::NestedLoopJoin')) {
				my $jv			= $plan->join_variables;
				my $mult		= scalar(@$jv) ? 1 : 5;	# penalize cartesian joins
				my $lcost		= $self->cost_for_plan($children[0], $model);
				my $rcost		= $self->cost_for_plan($children[1], $model);
				if ($lcost == 0) {
					$cost	= $rcost;
				} elsif ($rcost == 0) {
					$cost	= $lcost;
				} else {
					$cost	= $mult * $lcost * $rcost;
				}
			} elsif ($plan->isa('Attean::Plan::HashJoin')) {
				my $jv			= $plan->join_variables;
				my $mult		= scalar(@$jv) ? 1 : 5;	# penalize cartesian joins
				my $lcost		= $self->cost_for_plan($children[0], $model);
				my $rcost		= $self->cost_for_plan($children[1], $model);
				if ($lcost == 0) {
					$cost	= $rcost;
				} elsif ($rcost == 0) {
					$cost	= $lcost;
				} else {
					$cost	= $mult * ($lcost + $rcost);
				}
			} elsif ($plan->isa('Attean::Plan::Unique')) {
				$cost	= 0; # consider a filter on the iterator to be essentially free
				foreach my $c (@{ $plan->children }) {
					$cost	+= $self->cost_for_plan($c, $model);
				}
			} else {
				foreach my $c (@{ $plan->children }) {
					$cost	+= $self->cost_for_plan($c, $model);
				}
			}
			
			$plan->cost($cost);
			return $cost;
		}
	}

# The below function finds a number to aid sorting
# It takes into account Heuristic 1 and 4 of the HSP paper, see REFERENCES
# as well as that it was noted in the text that rdf:type is usually less selective.

# By assigning the integers to nodes, depending on whether they are in
# triple (subject, predicate, object), variables, rdf:type and
# literals, and sum them, they may be sorted. See code for the actual
# values used.

# Denoting s for bound subject, p for bound predicate, a for rdf:type
# as predicate, o for bound object and l for literal object and ? for
# variable, we get the following order, most of which are identical to
# the HSP:

# spl: 6
# spo: 8
# sao: 10
# s?l: 14
# s?p: 16
# ?pl: 25
# ?po: 27
# ?ao: 29
# sp?: 30
# sa?: 32
# ??l: 33
# ??o: 35
# s??: 38
# ?p?: 49
# ?a?: 51
# ???: 57

# Note that this number is not intended as an estimate of selectivity,
# merely a sorting key, but further research may possibly create such
# numbers.

	sub _hsp_heuristic_triple_sum {
		my ($self, $t) = @_;
		my @nodes = $t->values;
		my $sum = 0;
		if ($nodes[0][0]->does('Attean::API::Variable')) {
			$sum = 20;
		} else {
			$sum = 1;
		}
		if ($nodes[0][1]->does('Attean::API::Variable')) {
			$sum += 10;
		} else {
			if ($nodes[0][1]->equals(iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'))) {
				$sum += 4;
			} else {
				$sum += 2;
			}
		}
		if ($nodes[0][2]->does('Attean::API::Variable')) {
			$sum += 27;
		} elsif ($nodes[0][2]->does('Attean::API::Literal')) {
			$sum += 3;
		} else {
			$sum += 5;
		}
		return $sum;
	}

	
	sub _comparator_referenced_variables {
		my $self	= shift;
		my %vars;
		while (my $c = shift) {
			my $expr	= $c->expression;
			foreach my $v ($expr->in_scope_variables) {
				$vars{$v}++;
			}
		}
		return keys %vars;
	}
	
	sub _comparators_are_stable_and_cover_vars {
		my $self	= shift;
		my $cmps	= shift;
		my @vars	= @_;
		my %unseen	= map { $_ => 1 } @vars;
		foreach my $c (@$cmps) {
			return 0 unless ($c->expression->is_stable);
			foreach my $v ($self->_comparator_referenced_variables($c)) {
				delete $unseen{$v};
			}
		}
		my @keys	= keys %unseen;
		return (scalar(@keys) == 0);
	}
}

1;

__END__

=back

=head1 BUGS

Please report any bugs or feature requests to through the GitHub web interface
at L<https://github.com/kasei/attean/issues>.

=head1 REFERENCES

The seminal reference for Iterative Dynamic Programming is "Iterative
dynamic programming: a new class of query optimization algorithms" by
D. Kossmann and K. Stocker, ACM Transactions on Database Systems
(2000).

The heuristics to order triple patterns in this module is strongly
influenced by L<The ICS-FORTH Heuristics-based SPARQL Planner
(HSP)|http://www.ics.forth.gr/isl/index_main.php?l=e&c=645>.


=head1 SEE ALSO

L<http://www.perlrdf.org/>

=head1 AUTHOR

Gregory Todd Williams  C<< <gwilliams@cpan.org> >>

=head1 COPYRIGHT

Copyright (c) 2014 Gregory Todd Williams.
This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
