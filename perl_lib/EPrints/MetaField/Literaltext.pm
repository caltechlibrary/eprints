######################################################################
#
# EPrints::MetaField::Literaltext;
#
######################################################################
#
#
# Copyright 2000-2008 University of Southampton. All Rights Reserved.
#
#  This file is part of GNU EPrints 3.
#
#  Copyright (c) 2000-2008 University of Southampton, UK. SO17 1BJ.
#
#  EPrints 3 is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  EPrints 3 is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with EPrints 3; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
######################################################################

#
# NOTE: this was ported forward from BC's modifications from 3.1.x to 3.3.10 by RSD, 2020-10-08
#
=pod

=head1 NAME

B<EPrints::MetaField::Literaltext> - for creators_id field, to be treated as a literal string for searching (bc 7/22/2010)

=head1 DESCRIPTION

not done

=over 4

=cut

package EPrints::MetaField::Literaltext;

use strict;
use warnings;

BEGIN
{
	our( @ISA );

	@ISA = qw( EPrints::MetaField::Text );
}

use EPrints::MetaField::Text;

sub from_search_form
{
    my( $self, $session, $basename ) =  @_;

    # complex text types

    my $val = $session->param( $basename );
    return unless defined $val;

    my $search_type = $session->param( $basename."_merge" );
    my $search_match = $session->param( $basename."_match" );

    # Default search type if none supplied (to allow searches
    # using simple HTTP GETs)
    $search_type = "ALL" unless defined( $search_type );
# changed from "EQ" to "EX" 8/2/2013 bc
#    $search_match = "EQ" unless defined( $search_match );
    $search_match = "EX" unless defined( $search_match );

    return unless( defined $val );

    return( $val, $search_type, $search_match );
}

######################################################################
1;
