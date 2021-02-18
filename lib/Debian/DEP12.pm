package Debian::DEP12;

use strict;
use warnings;

# ABSTRACT: interface to Debian DEP 12 format
# VERSION

use Data::Validate::URI qw( is_uri );
use Debian::DEP12::ValidationWarning;
use Encode qw( decode );
use Scalar::Util qw( blessed );
use Text::BibTeX::Validate qw( validate_BibTeX );
use YAML::XS;

# Preventing YAML::XS from doing undesired things:
$YAML::XS::DumpCode = 0;
$YAML::XS::LoadBlessed = 0;
$YAML::XS::UseCode = 0;

my @fields = qw(
    Archive
    ASCL-Id
    Bug-Database
    Bug-Submit
    Cite-As
    Changelog
    CPE
    Documentation
    Donation
    FAQ
    Funding
    Gallery
    Other-References
    Reference
    Registration
    Registry
    Repository
    Repository-Browse
    Screenshots
    Security-Contact
    Webservice
);

my @list_fields = qw(
    Funding
    Reference
    Registry
    Screenshots
);

sub new
{
    my( $class, $what ) = @_;

    my $self;
    if( !defined $what ) {
        $self = {};
    } elsif( blessed $what &&
             ( $what->isa( 'Text::BibTeX::Entry' ) ||
               $what->isa( 'Text::BibTeX::File' ) ) ) {

        my @entries;
        if( $what->isa( 'Text::BibTeX::Entry' ) ) {
            push @entries, $what;
        } else {
            require Text::BibTeX::Entry;
            while( my $entry = Text::BibTeX::Entry->new( $what ) ) {
                push @entries, $entry;
            }
        }

        my @references;
        for my $entry (@entries) {
            # FIXME: Filter only supported keys (?)
            push @references,
                 { map { _canonical_BibTeX_key( $_ ) =>
                         decode( 'UTF-8', $entry->get( $_ ) ) }
                   grep { defined $entry->get( $_ ) }
                        $entry->fieldlist };

            for ('number', 'pages', 'volume', 'year') {
                next if !exists $references[-1]->{ucfirst $_};
                next if $references[-1]->{ucfirst $_} !~ /^[1-9][0-9]*$/;
                $references[-1]->{ucfirst $_} =
                    int $references[-1]->{ucfirst $_};
            }
        }

        return $class->new( { Reference => \@references } );
    } elsif( ref $what eq '' ) {
        # Text in YAML format
        if( $YAML::XS::VERSION < 0.69 ) {
            die 'YAML::XS < 0.69 is insecure' . "\n";
        }

        $self = Load $what;
    } elsif( ref $what eq 'HASH' ) {
        $self = $what;
    } else {
        die 'cannot create Debian::DEP12 from ' . ref( $what ) . "\n";
    }

    return bless $self, $class;
}

sub _canonical_BibTeX_key
{
    my( $key ) = @_;
    return uc $key if $key =~ /^(doi|isbn|issn|pmid|url)$/;
    return ucfirst $key;
}

sub fields
{
    return keys %{$_[0]};
}

sub get
{
    my( $self, $field ) = @_;
    return $self->{$field};
}

sub set
{
    my( $self, $field, $value ) = @_;
    ( my $old_value, $self->{$field} ) = ( $self->{$field}, $value );
    return $old_value;
}

sub delete
{
    my( $self, $field ) = @_;

    my $old_value = $self->{$field};
    delete $self->{$field};

    return $old_value;
}

sub _to_BibTeX
{
    my( $self ) = @_;

    my $reference = $self->get( 'Reference' );
    if( ref $reference eq 'HASH' ) {
        $reference = [ $reference ];
    }

    my @BibTeX;
    for my $reference (@$reference) {
        push @BibTeX,
             { map { lc( $_ ) => $reference->{$_} } keys %$reference };
    }
    return @BibTeX;
}

sub to_YAML
{
    my( $self ) = @_;
    my $yaml = Dump $self;

    # HACK: no better way to serialize plain data?
    $yaml =~ s/^---[^\n]*\n//m;
    return $yaml;
}

sub validate
{
    my( $self ) = @_;

    my @warnings;

    # TODO: validate other fields

    for my $key (sort $self->fields) {
        if( !grep { $_ eq $key } @fields ) {
            push @warnings,
                 _warn_value( 'unknown field', $self, $key );
        }

        if( ref $self->get( $key ) && !grep { $_ eq $key } @list_fields ) {
            push @warnings,
                 _warn_value( 'scalar value expected', $self, $key );
        }
    }

    for my $key ('Bug-Database', 'Bug-Submit', 'Changelog',
                 'Documentation', 'Donation', 'FAQ', 'Gallery',
                 'Other-References', 'Registration', 'Repository',
                 'Repository-Browse', 'Screenshots', 'Webservice') {
        next if !defined $self->get( $key );

        my @values;
        if( ref $self->get( $key ) eq 'ARRAY' ) {
            @values = @{$self->get( $key )};
        } else {
            @values = ( $self->get( $key ) );
        }

        for (@values) {
            if( ref $_ ) {
                push @warnings,
                     _warn_value( 'non-scalar value', $self, $key );
                next;
            }

            next if defined is_uri $_;

            if( /^(.*)\n$/ && defined is_uri $1 ) {
                push @warnings,
                     _warn_value( 'URL has trailing newline character',
                                  $self,
                                  $key,
                                  { suggestion => $1 } );
                next;
            }

            push @warnings,
                 _warn_value( 'value \'%(value)s\' does not look like valid URL',
                              $self,
                              $key );
        }
    }

    my @BibTeX = $self->_to_BibTeX;
    for my $i (0..$#BibTeX) {
        my $BibTeX = $BibTeX[$i];
        my @BibTeX_warnings = validate_BibTeX( $BibTeX );
        for (@BibTeX_warnings) {
            $_->{field} = _canonical_BibTeX_key( $_->{field} );
            $_->{key} = $i;
        }
        push @warnings, @BibTeX_warnings;
    }

    return @warnings;
}

sub _warn_value
{
    my( $message, $entry, $field, $extra ) = @_;
    $extra = {} unless $extra;
    return Debian::DEP12::ValidationWarning->new(
            $message,
            { field => $field,
              value => $entry->get( $field ),
              %$extra } );
}

1;

__END__

=pod

=head1 NAME

Debian::DEP12 - interface to Debian DEP 12 format

=head1 SYNOPSIS

    use Debian::DEP12;

    my $meta = Debian::DEP12->new;
    $meta->set( 'Bug-Database',
                'https://github.com/merkys/Debian-DEP12/issues' );

    $meta->validate;

=head1 DESCRIPTION

TODO

=head1 SEE ALSO

For the description of DEP12 refer to
L<https://dep-team.pages.debian.net/deps/dep12/>.

=head1 AUTHORS

Andrius Merkys, E<lt>merkys@cpan.orgE<gt>

=cut
