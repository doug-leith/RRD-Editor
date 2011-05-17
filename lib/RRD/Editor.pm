############################################################
#
#   RRD::Editor Standalone perl implementation of non-graph functions of RRDTOOL (plus portability and editing extras).
#
############################################################

package RRD::Editor;

use strict;
use warnings;

require Exporter;
#use Date::Format qw(time2str);
use POSIX qw/strftime/;
use Carp qw(croak carp cluck);
use Getopt::Long qw(GetOptionsFromString :config pass_through);
use Time::HiRes qw(time);
use Config;

use vars qw($VERSION @EXPORT @EXPORT_OK %EXPORT_TAGS @ISA);

$VERSION = '0.01_4';

@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(
open close create update info dump fetch 
last set_last lastupdate minstep
DS_names DS_heartbeat set_DS_heartbeat DS_min set_DS_min DS_max set_DS_max DS_type set_DS_type rename_DS add_DS delete_DS
num_RRAs RRA_numrows RRA_type RRA_step RRA_xff set_RRA_xff RRA_el set_RRA_el add_RRA delete_RRA resize_RRA
);
%EXPORT_TAGS = (all => \@EXPORT_OK);


# define sizes of long ints and floats for the various file encodings
use constant NATIVE_LONG_EL_SIZE        => $Config{longsize}; 
use constant NATIVE_DOUBLE_EL_SIZE      => $Config{doublesize}; 
use constant PORTABLE_LONG_EL_SIZE      => 4; # 32 bits
use constant PORTABLE_SINGLE_EL_SIZE    => 4; # IEEE 754 single is 32 bits
use constant PORTABLE_DOUBLE_EL_SIZE    => 8; # IEEE 754 double is 64 bits

# sort out the float cookie used by RRD files
sub _cookie {
   # Getting RRD file float cookie right is a little tricky because Perl rounds 8.642135E130 up to 8.6421500000000028e+130 on 
   # Intel 32 bit machines, and rounds to something else on 64 bit machines, and neither of these give the same bit sequence as 
   # C when Perl stores 8.642135E130.  Sigh ...  
    
    # See if we can make a call to C to get the float cookie.  Reliable, but needs Inline module to be available.
eval {
load Inline C => <<'END';
    double _cookie_C() {
    return 8.642135E130;
    }
END
return pack("d",_cookie_C());
};
    # Inline not available.
    # Try approach that avoids need for Inline module.  Ok so long as machine uses IEEE doubles (i.e. all modern machines) 
    # and either little-endian or big-endian byte order (i.e. most modern machines):
    if (substr($Config{byteorder},0,4) eq "1234") {
        if ($Config{myarchname} =~ m/^arm/i && NATIVE_LONG_EL_SIZE==4) {
            # For 32 bit ARM processors.  ARM changes the byte order of doubles
            # depending on alignment with 32 bit boundaries - this only affects the float cookie byte ordering, other .
            return chr(67). chr(43). chr(31). chr(91). chr(47). chr(37). chr(192). chr(199); 
        } else {    
            return chr(47). chr(37). chr(192). chr(199). chr(67). chr(43). chr(31). chr(91); # regular little endian
        }
    } elsif (substr($Config{byteorder},0,4) eq "4321") {
        return chr(91). chr(31). chr(43). chr(67). chr(199). chr(192). chr(37). chr(47); # big endian
    } else {
        cluck("Warning: To work with native (non-portable) RRD files, you need to install the perl Inline C module (e.g. by typing 'cpan -i Inline')\n");
        return chr(67). chr(43). chr(31). chr(91). chr(47). chr(37). chr(192). chr(199);
    } 
}
use constant  DOUBLE_FLOATCOOKIE                =>   8.642135E130;
use constant  NATIVE_BINARY_FLOATCOOKIE         =>   _cookie();
use constant  PORTABLE_BINARY_FLOATCOOKIE       =>   chr(47). chr(37). chr(192). chr(199). chr(67). chr(43). chr(31). chr(91); # portable format is always little-endian 
use constant  SINGLE_FLOATCOOKIE                =>   8.6421343830016e+13;  # cookie to use when storing floats in single precision as +130 exponent on old cookie is too large

sub _default_fileformat {
   # define the default file format
    if ($Config{myarchname} =~ m/^(mips|ppc)/i && NATIVE_LONG_EL_SIZE==4) { # TODO: does this check work ok on non-Linux/Darwin systems ?
                                                                            # Only affects behaviour when writing new files from scratch, 
                                                                            # otherwise can figure out the right format to use when read 
                                                                            # an existing file
        # For 32 bit MIPS and PowerPC machines, align long ints on 32 bit boundaries and doubles on 64 bit boundaries
        return "native-double-mips";
    } else {
        # Otherwise, align longs/doubles on 32 bit machines on 32 bit boundaries, and 64 bit machines on 64 bit boundaries.
        return "native-double";
    }
}

# check whether pack supports little-endian usage:
eval {
    my $test=pack("d<",\(DOUBLE_FLOATCOOKIE));
};
our $PACK_LITTLE_ENDIAN_SUPPORT = (length($@)>0 ? 0 : 1);

# define index into elements in CDP_PREP array
use constant VAL            => 0;
use constant UNKN_PDP_CNT   => 1;
use constant HW_INTERCEPT   => 2;
use constant HW_LAST_INTERCEPT  => 3;
use constant HW_SLOPE       => 4;
use constant HW_LAST_SLOPE  => 5;
use constant NULL_COUNT     => 6;
use constant LAST_NULL_COUNT=> 7;
use constant PRIMARY_VAL    => 8;
use constant SECONDARY_VAL  => 9;

###### private functions
### used to extract information from raw RRD file and build corresponding structured arrays
sub _get_header_size {
    # size of file header, in bytes
    my $self = $_[0]; my $rrd=$self->{rrd};   
    
    return $self->{DS_DEF_IDX} + 
        $self->{DS_EL_SIZE} * $rrd->{ds_cnt} + 
        $self->{RRA_DEF_EL_SIZE} * $rrd->{rra_cnt} + 
        $self->{LIVE_HEAD_SIZE} + 
        $self->{PDP_PREP_EL_SIZE} * $rrd->{ds_cnt} + 
        $self->{CDP_PREP_EL_SIZE} * $rrd->{ds_cnt} * $rrd->{rra_cnt} + 
        $self->{RRA_PTR_EL_SIZE} * $rrd->{rra_cnt}
        +$self->{HEADER_PAD};
}

####
sub _packd {
    # pack an array of doubles into a binary string, format determined by $self->{encoding}
    # - will do packing manually if necessary, to guarantee portability
    #my ($self,$list_ptr,$encoding) = @_; 
    my $encoding=$_[0]->{encoding};
    if (defined($_[2])) {$encoding=$_[2];}

    if ($encoding eq "native-double" || $encoding eq "native-double-mips") {
        # backwards-compatible (with RRDTOOL) RRD format
        return pack("d*", @{$_[1]});
    } elsif ($encoding eq "native-single") {
        # save some work - we can pack a portable-single using native float
        return pack("f*", @{$_[1]});
    } elsif ($PACK_LITTLE_ENDIAN_SUPPORT && $encoding eq "litteendian-single") {
        # save some work - we can pack a portable-single using native float
        return pack("f<*", @{$_[1]});
    } elsif ($PACK_LITTLE_ENDIAN_SUPPORT && $encoding eq "littleendian-double") {
        # shortcut - only difference from portable format is that native format is big-endian
            return pack("d<*", @{$_[1]});
    } 
    my $f; my $sign; my $shift; my $exp; my $mant; my $string=''; my $significand; my $significandlo; my $significandhi;
    if ($encoding eq "portable-single" || $encoding eq "ieee-32") {
        # manually pack an IEEE 754 32bit single precision number in little-endian order
        for (my $i=0; $i<@{$_[1]}; $i++) {
            $f=@{$_[1]}[$i];
            if ($f eq "nan") {
                $sign=0; $exp=255; $significand=1;
            } elsif ($f eq "-inf") {
                $sign=1; $exp=255; $significand=0;
            } elsif ($f eq "inf") {
                $sign=0; $exp=255; $significand=0;
            } elsif ($f == 0) {
                $sign=0; $exp=0; $significand=0;
            } else {
                $sign = ($f<0) ? 1 : 0;        
                $f = ($f<0) ? -$f : $f;
                # get the normalized form of f and track the exponent
                $shift = 0;
                while($f >= 2) { $f /= 2; $shift++; }
                while($f < 1 && $f>0) { $f *= 2; $shift--; }
                $f -= 1;
                # calculate the binary form (non-float) of the significand data
                $significand = int($f*(2**23));            
                # get the biased exponent
                $exp = int($shift + ((1<<7) - 1)); # shift + bias
            }
            $string.=pack("V",($sign<<31) | ($exp<<23) | $significand);
        }        
        return $string;
    } elsif ($encoding eq "portable-double" || $encoding eq "ieee-64") {
        # manuallly pack IEEE 754 64 bit double precision in little-endian order
        for (my $i=0; $i<@{$_[1]}; $i++) {
            $f=@{$_[1]}[$i];
            if ($f eq "nan") {
                $sign=0; $exp=2047; $significandhi=1;$significandlo=1;
            } elsif ($f eq "-inf") {
                $sign=1; $exp=2047; $significandhi=0;$significandlo=0;
            } elsif ($f eq "inf") {
                $sign=0; $exp=2047; $significandhi=0;$significandlo=0;
            } elsif ($f ==0) {
                $sign=0; $exp=0; $significandhi=0;$significandlo=0;
            } else {
                $sign = ($f<0) ? 1 : 0;        
                $f = ($f<0) ? -$f : $f;
                # get the normalized form of f and track the exponent
                $shift = 0;
                while($f >= 2) { $f /= 2; $shift++; }
                while($f < 1 && $f>0 ) { $f *= 2; $shift--; }
                $f -= 1;
                # calculate the binary form (non-float) of the significand data
                $significandhi = int($f*(2**20));            
                $significandlo = int( ($f-$significandhi/(2**20))*(2**52));           
                # get the biased exponent
                $exp = int($shift + ((1<<10) - 1)); # shift + bias
            }
            $string.=pack("V V",$significandlo, ($sign<<31) | ($exp<<20) | $significandhi);
        }
        return $string;
    } else {
        croak("packd:unknown encoding: ".$encoding."\n");
    }
}

#####

sub _unpackd {
    # unpack binary string into array of doubles, format determined by $self->{encoding}
    # - will do unpacking manually if necessary, to guarantee portability
    #my ($self, $string, $encoding) = @_;  
    my $encoding=$_[0]->{encoding};
    if (defined($_[2])) {$encoding=$_[2];}
  
    if ($encoding eq "native-double" || $encoding eq "native-double-mips") {
        # backwards-compatible (with RRDTOOL) RRD format
        return unpack("d*", $_[1]);
    } elsif ($encoding eq "native-single" ) {
        # save some work - we can unpack portable-single using native float
        return unpack("f*", $_[1]);
    } elsif ($PACK_LITTLE_ENDIAN_SUPPORT && $encoding eq "littleendian-single" ) {
        # save some work - we can unpack portable-single using native float
        return unpack("f<*", $_[1]);
    } elsif ($PACK_LITTLE_ENDIAN_SUPPORT && $encoding eq "littleendian-double") {
        # shortcut - only difference from portable format is that native format is big-endian
        return unpack("d<*", $_[1]);
    }
    my $word; my $sign; my $expo; my $mant; my $manthi; my $mantlo; my @list; my $num;  my $i;
    if ($encoding eq "portable-single" || $encoding eq "ieee-32") {
        # manually unpack a little-endian IEEE 754 32bit single-precision number
        for ($i=0; $i<length($_[1]); $i=$i+4) {
            $word = (unpack("C",substr($_[1],$i+3,1)) << 24) + (unpack("C",substr($_[1],$i+2,1)) << 16) + (unpack("C",substr($_[1],$i+1,1)) << 8) + unpack("C",substr($_[1],$i,1));
            $expo = (($word & 0x7F800000) >> 23) - 127;
            $mant = (($word & 0x007FFFFF) | 0x00800000);
            $sign =  ($word & 0x80000000) ? -1 : 1;    
            if ($expo == 128 && $mant == 0 ) {
                $num=$sign>0 ? 0+"inf" : 0-"inf";
            } elsif ($expo == 128) {
                $num=0+"nan";
            } elsif ($expo == -127 && $mant ==0) {
                $num=0;
            } else {
                $num = $sign * (2**($expo-23))*$mant;
            }
            push (@list, $num);
        }
        return @list;
    } elsif ($encoding eq "portable-double" || $encoding eq "ieee-64") {   
        # manually unpack IEEE 754 64 bit double-precision number.  
        for ($i=0; $i<length($_[1]); $i=$i+8) {
            $word = (unpack("C",substr($_[1],$i+7,1)) << 24) + (unpack("C",substr($_[1],$i+6,1)) << 16) + (unpack("C",substr($_[1],$i+5,1)) << 8) + unpack("C",substr($_[1],$i+4,1));
            $mantlo = (unpack("C",substr($_[1],$i+3,1)) << 24) + (unpack("C",substr($_[1],$i+2,1)) << 16) + (unpack("C",substr($_[1],$i+1,1)) << 8) + unpack("C",substr($_[1],$i,1));
            $expo = (($word & 0x7FF00000) >> 20) - 1023;
            $manthi = ($word & 0x000FFFFF) ;
            $sign =  ($word & 0x80000000) ? -1 : 1;                
            if ($expo == 1024 && $mantlo == 0 && $manthi==0 ) {
                $num=$sign*(0+"inf");
            } elsif ($expo == 1024) {
                $num=0+"nan";
            } elsif ($expo==-1023 && $manthi==0 && $mantlo==0) {
                $num=0;
            } else {
                $num = $sign * ( (2**$expo) + (2**($expo-20))*$manthi + (2**($expo-52))*$mantlo );
            }
            push (@list, $num);
        }
        return @list;
    } else {
        croak("unpackd:unknown encoding: ".$encoding."\n");
    }
}

#####
sub _packlongchar {
    # pack encoding specification for integers.  no need for manual packing/unpacking of integers as agreed portable formats already available
    my $self=$_[0];
    if ($self->{encoding} eq "native-double" || $self->{encoding} eq "native-double-mips") {
        # backwards-compatible (with RRDTOOL) RRD format
        return "L!"; # native long int
    } else {
        # portable format, little-endian 32bit long int
        return "V"; 
    }         
}

####
sub _sizes {
    # define the sizes of the various elements in RRD binary file
    my ($self)=@_;
    
    $self->{OFFSET} = 12;  # byte position of start of float cookie. 
    $self->{RRA_DEL_PAD}    = 0;  # for byte alignment in RRA_DEF after char(20) string
    $self->{STAT_PAD} = 0; # for byte alignment at end of static header.  
    $self->{RRA_PAD} = 0; # for byte alignment at end of RRAD_DEF float array
    if ($self->{encoding} eq "native-double" ) {
        $self->{LONG_EL_SIZE} = NATIVE_LONG_EL_SIZE; 
        $self->{FLOAT_EL_SIZE}= NATIVE_DOUBLE_EL_SIZE; 
        $self->{COOKIE} = NATIVE_BINARY_FLOATCOOKIE;
        if ( NATIVE_LONG_EL_SIZE == 8) {
            # We assume byte alignment is carried out wrt long ints i.e 32 bits on 32 bit machines and 64 bits on 64 bit machines.  
            $self->{OFFSET}         = 16; # for byte alignment of the float cookie
            $self->{RRA_DEL_PAD}    = 4;  # for byte alignment in RRA_DEF after char(20) string
        } 
    } elsif ($self->{encoding} eq "native-double-mips") {
        # native-double-mips is to deal with MIPS which align long ints at 32 bits boundaries and
        # doubles at 64 bit boundaries.  
        $self->{LONG_EL_SIZE} = NATIVE_LONG_EL_SIZE; 
        $self->{FLOAT_EL_SIZE}= NATIVE_DOUBLE_EL_SIZE; 
        $self->{COOKIE} = NATIVE_BINARY_FLOATCOOKIE;
        $self->{OFFSET}         = 16; # for byte alignment of the float cookie
        $self->{RRA_DEL_PAD}    = 0;  # for byte alignment in RRA_DEF after char(20) string
        $self->{STAT_PAD}       = 4;
        $self->{RRA_PAD}        = 4;
    } elsif ($self->{encoding} eq "littleendian-single" || $self->{encoding} eq "native-single" || $self->{encoding} eq "portable-single" || $self->{encoding} eq "ieee-32") {
        $self->{LONG_EL_SIZE} = PORTABLE_LONG_EL_SIZE;
        $self->{FLOAT_EL_SIZE}= PORTABLE_SINGLE_EL_SIZE; # 32 bits
        my @cookie=(SINGLE_FLOATCOOKIE);
        $self->{COOKIE} = _packd($self,\@cookie,"portable-single");
    } elsif ($self->{encoding} eq "littleendian-double" ||  $self->{encoding} eq "portable-double" || $self->{encoding} eq "ieee-64") {   
        $self->{LONG_EL_SIZE} = PORTABLE_LONG_EL_SIZE;
        $self->{FLOAT_EL_SIZE}= PORTABLE_DOUBLE_EL_SIZE; # 64 bits
        $self->{COOKIE} = PORTABLE_BINARY_FLOATCOOKIE; 
    }        
    $self->{DIFF_SIZE}          = $self->{FLOAT_EL_SIZE} - $self->{LONG_EL_SIZE};     
    $self->{STAT_HEADER_SIZE}   = $self->{OFFSET} + $self->{FLOAT_EL_SIZE} + 3 * $self->{LONG_EL_SIZE};
    $self->{STAT_HEADER_SIZE0}  = $self->{STAT_HEADER_SIZE} + 10 * $self->{FLOAT_EL_SIZE} + $self->{STAT_PAD};
    $self->{RRA_PTR_EL_SIZE}    = $self->{LONG_EL_SIZE};
    $self->{CDP_PREP_EL_SIZE}   = 10 * $self->{FLOAT_EL_SIZE};    
    $self->{PDP_PREP_PAD}       = 2;  # for byte alignment of char(30) string in PDP_PREP
    $self->{PDP_PREP_EL_SIZE}   = 30 + $self->{PDP_PREP_PAD} + 10 * $self->{FLOAT_EL_SIZE};    
    $self->{RRA_DEF_EL_SIZE}    = 20 +  $self->{RRA_DEL_PAD} + 2 * $self->{LONG_EL_SIZE} + 10 * $self->{FLOAT_EL_SIZE} +$self->{RRA_PAD};
    $self->{DS_DEF_IDX}         = $self->{STAT_HEADER_SIZE0};
    $self->{DS_EL_SIZE}         = 40 + 10 * $self->{FLOAT_EL_SIZE} ;  
    $self->{LIVE_HEAD_SIZE}     = 2 * $self->{LONG_EL_SIZE};  
    $self->{HEADER_PAD}         = 0; # accounting for pad bytes at end of header (e.g. 8 pad bytes are added on Linux/Intel 64 bit platforms)
}

####
sub _extractDSdefs {
    # extract DS definitions from raw header (which must have been already read using rrd_open)
    my ($self, $header, $idx) = @_;  my $rrd=$self->{rrd};
    
    my $i; 
    my $L=$self->_packlongchar();
    @{$rrd->{ds}}=[];
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
        my $ds={}; 
        #($ds->{name}, $ds->{type}, $ds->{hb}, $ds->{min}, $ds->{max})= unpack("Z20 Z20 $L x".DIFF_SIZE." d d",substr(${$header},$idx,DS_EL_SIZE));
        ($ds->{name}, $ds->{type}, $ds->{hb})= unpack("Z20 Z20 $L",substr(${$header},$idx,40+$self->{LONG_EL_SIZE}));
        ($ds->{min}, $ds->{max})= _unpackd($self,substr(${$header},$idx+40+$self->{FLOAT_EL_SIZE},2*$self->{FLOAT_EL_SIZE}));
        $rrd->{ds}[$i] = $ds;
        $idx+=$self->{DS_EL_SIZE};
        #print $ds->{name}," ",$ds->{type}," ",$ds->{hb}," ",$ds->{min}," ",$ds->{max},"\n";
    }
}

###
sub _extractRRAdefs {
    # extract RRA definitions from raw header (which must have been already read using rrd_open)
    my ($self, $header, $idx) = @_;  my $rrd=$self->{rrd};

    my $i; 
    my $L=$self->_packlongchar();
    @{$rrd->{rra}}=[];
    for ($i=0; $i<$rrd->{rra_cnt}; $i++) {
        my $rra={}; 
        ($rra->{name}, $rra->{row_cnt}, $rra->{pdp_cnt})= unpack("Z".(20+$self->{RRA_DEL_PAD})." $L $L",substr(${$header},$idx,20+$self->{RRA_DEL_PAD}+2*$self->{LONG_EL_SIZE}));
        ($rra->{xff})= _unpackd($self,substr(${$header},$idx+20+$self->{RRA_DEL_PAD} + 2*$self->{LONG_EL_SIZE}+$self->{RRA_PAD}, $self->{FLOAT_EL_SIZE}));
        $rrd->{rra}[$i] = $rra;
        $idx+=$self->{RRA_DEF_EL_SIZE};
        #print $rra->{name}," ",$rra->{row_cnt}," ",$rra->{pdp_cnt}," ",$rra->{xff},"\n";
    }
}

####
sub _extractPDPprep {
    # extract PDP prep from raw header (which must have been already read using rrd_open)
    my ($self, $header, $idx) = @_;  my $rrd=$self->{rrd};

    my $i; 
    my $L=$self->_packlongchar();
    @{$rrd->{pdp_prep}}=[];
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
        my $pdp={}; 
        ($pdp->{last_ds}, $pdp->{unkn_sec_cnt})= unpack("Z".(30+$self->{PDP_PREP_PAD})." $L",substr(${$header},$idx,30+$self->{PDP_PREP_PAD}+$self->{LONG_EL_SIZE})); # NB Z32 instead of Z30 due to byte alignment
        ($pdp->{val})= _unpackd($self,substr(${$header},$idx+30+$self->{PDP_PREP_PAD}+$self->{FLOAT_EL_SIZE},$self->{FLOAT_EL_SIZE})); 
        $rrd->{ds}[$i]->{pdp_prep} = $pdp;
        $idx+=$self->{PDP_PREP_EL_SIZE};
        #print $pdp->{last_ds}," ",$pdp->{unkn_sec_cnt}," ",$pdp->{val},"\n";
    }
}

###
sub _extractCDPprep {
    # extract CDP prep from raw header (which must have been already read using rrd_open)
    my ($self, $header, $idx) = @_;  my $rrd=$self->{rrd};
    
    my $i; my $ii; 
    my $L=$self->_packlongchar();
    for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        #@{$rrd->{cdp_prep}[$ii]}=[];
        for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
            # do a bit of code optimisation to aggregate function calls and array allocation here, since run inside inner loop.
            if ($self->{encoding} eq "native-double") {
                @{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]} = unpack("d $L x".$self->{DIFF_SIZE}." d d d d $L x".$self->{DIFF_SIZE}." $L x".$self->{DIFF_SIZE}." d d",substr(${$header},$idx,$self->{CDP_PREP_EL_SIZE}));
                $idx+=$self->{CDP_PREP_EL_SIZE};
            } elsif ($self->{encoding} eq "native-single") {
                @{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]} = unpack("f $L x".$self->{DIFF_SIZE}." f f f f $L x".$self->{DIFF_SIZE}." $L x".$self->{DIFF_SIZE}." f f",substr(${$header},$idx,$self->{CDP_PREP_EL_SIZE}));
                $idx+=$self->{CDP_PREP_EL_SIZE};
            } else {
                @{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}=(0,0,0,0,0,0,0,0,0,0); # pre-allocate array
                (@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[0])=_unpackd($self,substr(${$header},$idx,$self->{FLOAT_EL_SIZE})); $idx+=$self->{FLOAT_EL_SIZE};
                @{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[1]=unpack("$L x".$self->{DIFF_SIZE},substr(${$header},$idx,$self->{FLOAT_EL_SIZE})); $idx+=$self->{FLOAT_EL_SIZE};
                @{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[2..5]=_unpackd($self,substr(${$header},$idx,4*$self->{FLOAT_EL_SIZE})); $idx+=4*$self->{FLOAT_EL_SIZE};
                @{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[6..7]=unpack("$L x".$self->{DIFF_SIZE}." $L x".$self->{DIFF_SIZE},substr(${$header},$idx,2*$self->{FLOAT_EL_SIZE})); $idx+=2*$self->{FLOAT_EL_SIZE};
                @{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[8..9]=_unpackd($self,substr(${$header},$idx,2*$self->{FLOAT_EL_SIZE})); $idx+=2*$self->{FLOAT_EL_SIZE};
            }
        }
    }
}

###
sub _extractRRAptr {
    # array of { cur_row } pointers into current row in rra from raw header (which must have been already read using rrd_open)
    my ($self, $header, $idx) = @_; my $rrd=$self->{rrd};

    my $L=$self->_packlongchar();
    my @ptr=unpack("$L*",substr(${$header},$idx,$self->{RRA_PTR_EL_SIZE}*$rrd->{rra_cnt}));
    my $i;
    for ($i=0; $i<$rrd->{rra_cnt}; $i++) {
        $rrd->{rra}[$i]->{ptr}=$ptr[$i];
    }
    #print @ptr;
}

###
sub _loadRRAdata {
    # read in and extract the RRA data.  assumes rrd_open has been called to read in file header and 
    # populate the RRD data structure
    my $self = $_[0]; my $rrd=$self->{rrd};   
    if (!defined($self->{fd})) {croak("loadRRDdata: must call open() first\n");}

    my $data; my $ds_cnt=$self->{FLOAT_EL_SIZE} * $rrd->{ds_cnt};
    seek $self->{fd},_get_header_size($self),0; # move to start of RRA data within file
    for (my $ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        my $idx=0; 
        read($self->{fd}, $data, $self->{FLOAT_EL_SIZE} * $rrd->{ds_cnt}* $rrd->{rra}[$ii]->{row_cnt} );
        my $row_cnt=$rrd->{rra}[$ii]->{row_cnt};
        for (my $i=0; $i<$row_cnt; $i++) {
            # rather than unpack here, do "lazy" unpacks i.e. only when needed - much faster
            #@{$rrd->{rra}[$ii]->{data}[$i]}=unpack("d*",substr($data,$idx,$ds_cnt}) );
            $rrd->{rra}[$ii]->{data}[$i]=substr($data,$idx,$ds_cnt);
            $idx+=$ds_cnt;
        }
        #print  "rra $ii:", join(", ",@{$rrd->{rra_data}[$ii][$rrd->{rra_ptr}[$ii]+1]}),"\n";
     }
    $rrd->{dataloaded}=1; # record the fact that the data is now loaded in memory
}

####
sub _findDSidx {
    # find the index of a DS given its name
    my ($self, $name) = @_;  my $rrd=$self->{rrd};
    my $i; 
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
        if ($rrd->{ds}[$i]->{name} eq $name) {
            return $i;
        }
    }
    return -1; # unknown source
}

################ public functions
sub new {
    # create new object
    my $self;
    $self->{file_name}=undef;           # name of RRD file
    $self->{fd}=undef;                  # file handle
    $self->{encoding}=undef;            # binary encoding within file.  
    $self->{rrd}->{version}=undef;
    $self->{rrd}->{rra_cnt}= undef;     # number of RRAs
    $self->{rrd}->{ds_cnt}=undef;       # number of DSs
    $self->{rrd}->{pdp_step}=undef;     # min time step size
    $self->{rrd}->{last_up} = undef;    # time when last updated
    $self->{rrd}->{ds}=undef;           # array of DS definitions
    $self->{rrd}->{rra}=undef;          # array of RRA info
    $self->{rrd}->{dataloaded}=undef;   # has body of RRD file been loaded into memory ?
    bless $self;
    return $self;
}

sub DS_names {
    # return a list containing the names of the DS's in the RRD database.   
    my $rrd=$_[0]->{rrd};
    my @names=(); my $i;
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
        push(@names, $rrd->{ds}[$i]->{name});
    }
    return @names;
}

sub num_RRAs {
    # returns the number of RRA's in the database.  RRAs are indexed from 0 .. num_RRAs-1.
    return $_[0]->{rrd}->{rra_cnt};
}

sub RRA_numrows {
    # return number of rows in a RRA
    my ($self, $rraidx) = @_;  my $rrd=$self->{rrd};
    if ($rraidx > $rrd->{rra_cnt} || $rraidx<0) {croak("RRA index out of range\n");}
    return $rrd->{rra}[$rraidx]->{row_cnt};
}

sub RRA_type {
    # return the type of an RRA (AVERAGE, MAX etc)
    my ($self, $rraidx) = @_; my $rrd=$self->{rrd};
    if ($rraidx > $rrd->{rra_cnt} || $rraidx<0) {croak("RRA index out of range\n");}
    return $rrd->{rra}[$rraidx]->{name};
}

sub RRA_step {
    # return the step size (in seconds) used in an RRA
    my ($self, $rraidx) = @_; my $rrd=$self->{rrd};
    if ($rraidx > $rrd->{rra_cnt} || $rraidx<0) {croak("RRA index out of range\n");}
    return $rrd->{rra}[$rraidx]->{pdp_cnt}*$rrd->{pdp_step};
}

sub RRA_xff {
    # return the xff value for an RRA
    my ($self, $idx) = @_;  my $rrd=$self->{rrd};
    if ($idx > $rrd->{rra_cnt} || $idx<0) {croak("RRA index out of range\n");}
    return $rrd->{rra}[$idx]->{xff};
}

sub RRA_el {
    # fetch a specified element from a specified RRA.
    # given the index number of the RRA, the index of the DS and the row within the RRA (oldest row is 0),
    # returns a pair (t,d) where t is the unix timestamp of the data point and d is the data value
    my ($self, $rraidx, $ds_name, $tidx) = @_;  my $rrd=$self->{rrd};
    
    if ($rraidx > $rrd->{rra_cnt} || $rraidx<0) {croak("RRA index out of range\n");}
    my $dsidx=_findDSidx($self,$ds_name);
    if ($tidx >= $rrd->{rra}[$rraidx]->{row_cnt} || $tidx<0) {croak("Row index out of range\n");}

    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}

    my  $t = $rrd->{last_up} - $rrd->{last_up}%($rrd->{rra}[$rraidx]->{pdp_cnt}*$rrd->{pdp_step}) -($rrd->{rra}[$rraidx]->{row_cnt}-1-$tidx)*$rrd->{rra}[$rraidx]->{pdp_cnt}*$rrd->{pdp_step};
    my $jj= ($rrd->{rra}[$rraidx]->{ptr}+1+ $tidx)%$rrd->{rra}[$rraidx]->{row_cnt};
    my @line=_unpackd($self,$rrd->{rra}[$rraidx]->{data}[$jj]);
    return ($t, $line[$dsidx]);
}

sub set_RRA_el {
    # change value of a specified element from a specified RRA
    # given the index number of the RRA, the index of the DS and the row within the RRA (oldest row is 0),
    # updates the data value to be $val
    my ($self, $rraidx, $ds_name, $tidx, $val) = @_;  my $rrd=$self->{rrd};
    my $dsidx=_findDSidx($self,$ds_name);
    
    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}

    my $jj= ($rrd->{rra}[$rraidx]->{ptr}+1 + $tidx)%$rrd->{rra}[$rraidx]->{row_cnt};
    my @line=_unpackd($self,$rrd->{rra}[$rraidx]->{data}[$jj]);
    $line[$dsidx] = $val;
    $rrd->{rra}[$rraidx]->{data}[$jj]=_packd($self,\@line);
}

sub last {
    # return time of last update
    return $_[0]->{rrd}->{last_up};
}

sub set_last {
    # change time of last update; use with caution !
    $_[0]->{rrd}->{last_up} = $_[1];
    return 1;
}

sub lastupdate {
    # return the most recent update values
    my $self=$_[0];  my $rrd=$self->{rrd};

    my @vals;
    for (my $i=0; $i<$rrd->{ds_cnt}; $i++) {
        push(@vals,$rrd->{ds}[$i]->{pdp_prep}->{last_ds});
    }
    return @vals;
}

sub minstep {
    # return the min step size, in seconds
    my $self=$_[0];  my $rrd=$self->{rrd};
    return $rrd->{pdp_step};
}

sub DS_heartbeat {
    # return heartbeat for DS
    my ($self, $name) = @_;  my $rrd=$self->{rrd};
    
    my $idx=_findDSidx($self,$name); if ($idx<0) {croak("Unknown source\n");}
    return $rrd->{ds}[$idx]->{hb};
}

sub set_DS_heartbeat {
    # change heartbeat for DS
    my ($self, $name, $hb) = @_;  my $rrd=$self->{rrd};
    
    if ($hb < $rrd->{pdp_step}) {croak("Heartbeat value must be at least the minimum step size ".$rrd->{pdp_step}." secs\n");}
    
    my $idx=_findDSidx($self,$name); if ($idx<0) {croak("Unknown source\n");}
    # update to new value
    $rrd->{ds}[$idx]->{hb}=$hb;
    return 1;
}

sub DS_min {
    # return min value for DS
    my ($self, $name) = @_;  my $rrd=$self->{rrd};
    
    my $idx=_findDSidx($self,$name); if ($idx<0) {croak("Unknown source\n");}
    return $rrd->{ds}[$idx]->{min};
}

sub set_DS_min {
    # change min value for DS
    my ($self, $name, $min) = @_;  my $rrd=$self->{rrd};
        
    my $idx=_findDSidx($self,$name); if ($idx<0) {croak("Unknown source\n");}
    # update to new value
    $rrd->{ds}[$idx]->{min}=$min;
    return 1;
}

sub DS_max {
    # return max value for DS
    my ($self, $name) = @_;  my $rrd=$self->{rrd};
    
    my $idx=_findDSidx($self,$name); if ($idx<0) {croak("Unknown source\n");}
    return $rrd->{ds}[$idx]->{max};
}

sub set_DS_max {
    # change max value for DS
    my ($self, $name, $max) = @_;  my $rrd=$self->{rrd};
    
    my $idx=_findDSidx($self,$name); if ($idx<0) {croak("Unknown source\n");}
    # update to new value
    $rrd->{ds}[$idx]->{max}=$max;
    return 1;
}

sub DS_type {
    # return type of DS
    my ($self, $name) = @_;  my $rrd=$self->{rrd};
    
    my $idx=$self->_findDSidx($name); if ($idx<0) {croak("Unknown source\n");}
    return $rrd->{ds}[$idx]->{type};
}

sub set_DS_type {
    # change type of DS
    my ($self, $name, $type) = @_;  my $rrd=$self->{rrd};
    
    my $idx=_findDSidx($self,$name); if ($idx<0) {croak("Unknown source\n");}
    if ($type !~ m/(GAUGE|COUNTER|DERIVE|ABSOLUTE)/) { croak("Invalid DS type\n");}
    # update to new value
    $rrd->{ds}[$idx]->{type}=$type;
    return 1;
}

sub rename_DS {
    my ($self, $old, $new) = @_;  my $rrd=$self->{rrd};

    my $idx=_findDSidx($self,$old);  if ($idx<0) {croak("Unknown source\n");}
    $rrd->{ds}[$idx]->{name}=$new;
    return 1;
}

sub add_DS {
    # add a new DS.  argument is is same format as used by create
    my ($self, $arg) = @_;  my $rrd=$self->{rrd};
    
    if ($arg !~ m/^DS:([a-zA-Z0-9_\-]+):(GAUGE|COUNTER|DERIVE|ABSOLUTE):([0-9]+):(U|[0-9\.]+):(U|[0-9\.]+)$/) { croak("Invalid DS spec\n");}

    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}

    # update DS definitions
    my $ds; 
    my $min=$4;  if ($min eq "U") {$min=0+"nan";} # set to NaN
    my $max=$5;  if ($max eq "U") {$max=0+"nan";} # set to NaN
    ($ds->{name}, $ds->{type}, $ds->{hb}, $ds->{min}, $ds->{max}, 
     $ds->{pdp_prep}->{last_ds}, $ds->{pdp_prep}->{unkn_sec_cnt}, $ds->{pdp_prep}->{val},
    )= ($1,$2,$3,$min,$max,"U", $rrd->{last_up}%$rrd->{pdp_step}, 0.0);
    $rrd->{ds}[@{$rrd->{ds}}]=$ds;
    $rrd->{ds_cnt}++;
    
    # update RRAs
    my $ii;
    for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        @{$rrd->{rra}[$ii]->{cdp_prep}[$rrd->{ds_cnt}-1]} = (0+"nan",(($rrd->{last_up}-$rrd->{last_up}%$rrd->{pdp_step})%($rrd->{pdp_step}*$rrd->{rra}[$ii]->{pdp_cnt}))/$rrd->{pdp_step},0,0,0,0,0,0,0,0);
    }
    # update data
    my @line; my $i;
    for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        for ($i=0; $i<$rrd->{rra}[$ii]->{row_cnt}; $i++) {
            @line=_unpackd($self,$rrd->{rra}[$ii]->{data}[$i]);
            $line[$rrd->{ds_cnt}-1]=0+"nan";
            $rrd->{rra}[$ii]->{data}[$i]=_packd($self,\@line);
        }
    }
    return 1;
}

sub delete_DS {
    # delete a DS
    my ($self, $name) = @_;  my $rrd=$self->{rrd};
    my $idx=_findDSidx($self,$name);  if ($idx<0) {croak("Unknown source\n");}

    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}

    # update DS definitions
    my $i;
    $rrd->{ds_cnt}--;
    for ($i=$idx; $i<$rrd->{ds_cnt}; $i++) {
        $rrd->{ds}[$i]=$rrd->{ds}[$i+1];
    }
    
    # update RRAs
    my $ii;
    for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        for ($i=$idx; $i<$rrd->{ds_cnt}; $i++) {
            $rrd->{rra}[$ii]->{cdp_prep}[$i]=$rrd->{rra}[$ii]->{cdp_prep}[$i+1];
        }
    }    

    # update data
    my $j; my @line;
    for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        for ($i=0; $i<$rrd->{rra}[$ii]->{row_cnt}; $i++) {
            @line=_unpackd($self,$rrd->{rra}[$ii]->{data}[$i]);
            for ($j=$idx; $j<$rrd->{ds_cnt}; $j++) {
                $line[$j]=$line[$j+1];
            }
            $rrd->{rra}[$ii]->{data}[$i]=_packd($self,[@line[0..$rrd->{ds_cnt}-1]]);
        }
    }
    return 1;
}

sub add_RRA {
    # add a new RRA
    my ($self, $args) = @_;  my $rrd=$self->{rrd};
    if ($args !~ m/^RRA:(AVERAGE|MAX|MIN|LAST):([0-9\.]+):([0-9]+):([0-9]+)$/) {croak("Invalid RRA spec\n");}
    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}
    # update RRA definitions
    my $rra;
    if ($4<1) { croak("Invalid row count $4\n");}
    if ($2<0.0 || $2>1.0) { croak("Invalid xff $2: must be between 0 and 1\n");}
    if ($3<1) { croak("Invalid step $3: must be >= 1\n");}
    ($rra->{name}, $rra->{xff}, $rra->{pdp_cnt}, $rra->{row_cnt}, $rra->{ptr}, $rra->{data})=($1,$2,$3,$4,int(rand($4)),undef);
    my $idx=@{$rrd->{rra}};
    $rrd->{rra}[$idx]=$rra;
    $rrd->{rra_cnt}++;
 
    my $i; 
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
       @{$rrd->{rra}[$idx]->{cdp_prep}[$i]} = (0+"nan",(($rrd->{last_up}-$rrd->{last_up}%$rrd->{pdp_step})%($rrd->{pdp_step}*$rrd->{rra}[$idx]->{pdp_cnt}))/$rrd->{pdp_step},0,0,0,0,0,0,0,0);
    }
    # update data
    my @empty=((0+"nan")x$rrd->{ds_cnt});
    for ($i=0; $i<$rrd->{rra}[$idx]->{row_cnt}; $i++) {
        $rrd->{rra}[$idx]->{data}[$i] = _packd($self,\@empty);
    }
    return 1;
}

sub delete_RRA {
    # delete an RRA
    my ($self, $idx) = @_;  my $rrd=$self->{rrd};
    if ($idx > $rrd->{rra_cnt} || $idx<0) {croak("RRA index out of range\n");}
    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}
    # update RRA 
    $rrd->{rra_cnt}--;
    for (my $i=$idx; $i<$rrd->{rra_cnt}; $i++) {
        $rrd->{rra}[$i]=$rrd->{rra}[$i+1];
    }
    return 1;
}

sub resize_RRA {
    my ($self, $idx, $size) = @_;  my $rrd=$self->{rrd};
    
    if ($idx > $rrd->{rra_cnt} || $idx<0) {croak("RRA index out of range\n");}
    if ($size < 0) {$size=0;}
    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}
    # update data
    my @empty=((0+"nan")x$rrd->{ds_cnt});
    for (my $i=$rrd->{rra}[$idx]->{row_cnt}; $i<$size; $i++) {
        $rrd->{rra}[$idx]->{data}[$i] = _packd($self,\@empty);
    }
    $rrd->{rra}[$idx]->{row_cnt} = $size;
    return 1;
}

sub set_RRA_xff {
    # schange xff value for an RRA
    my ($self, $idx, $xff) = @_;  my $rrd=$self->{rrd};
    if ($idx > $rrd->{rra_cnt} || $idx<0) {croak("RRA index out of range\n");}
    $rrd->{rra}[$idx]->{xff}=$xff;
    return 1;
}

#sub set_RRA_step {
# TODO: change RRA step size - will require resampling
#}

sub update {
    # a re-implementation of rrdupdate.  updates file in place on disk, if possible - much faster.
    
    use Getopt::Long qw(GetOptionsFromString :config pass_through);
    
    my ($self, $args_str) = @_;  my $rrd=$self->{rrd};
    
    my $ret; my $args; my $template=''; 
    ($ret, $args) = GetOptionsFromString($args_str,
    "template|t:s" => \$template,
    );    

    # update file in place ?
    my $inplace; my $fd;
    if (defined($rrd->{dataloaded})) {
        $inplace="memory"; # data is already loaded into memory so do update there.  will need to subsequently call save() to write data to disk
    } else {
        if (defined($self->{fd})) {
            $inplace="file"; # data is not loaded yet, so carry out update in place in file.  more efficient - no need to call save() to write data to disk.
            $fd=$self->{fd};
        } else {
            croak("update: must call open() or create() first\n");
        }
    }

    # Parse template, if provided
    my $i; my $j;
    my @tmp=split(/:/,$template); my @idx=(0 .. $rrd->{ds_cnt}-1);
    for ($i=0; $i<@tmp; $i++) {
        $idx[$i]=findDSidx($self,$tmp[$i]); if($idx[$i]<0) {croak("Unknown DS name ".$tmp[$i]."\n");}
    }
    # Parse update strings - updates the primary data points (PDPs)
    # and consolidated data points (CDPs), and writes changes to the RRAs.
    my @updvals; my @bits; my $rate; my $current_time; my $interval;
    for ($i=0; $i<@{$args}; $i++) {
        #parse colon-separated DS string
        if ($args->[$i] =~ m/\@/) {croak("\@ time format not supported - use either N or a unix timestamp\n");}
        @bits=split(/:/,$args->[$i]);
        if (@bits-1 < @idx) {croak("expected ".@idx." data source readings (got ".(@bits-1).") from ".$args->[$i],"\n");}
        #get_time_from_reading
        if ($bits[0] eq "N") {
            $current_time=time();
            #normalize_time
        } else {
            $current_time=$bits[0];
        }
        if ($current_time < $rrd->{last_up}) {croak("attempt to update using time $current_time when last update time is ". $rrd->{last_up}."\n");}
        $interval=$current_time - $rrd->{last_up}; 
        @updvals = "U" x $rrd->{ds_cnt};  # initialise values to NaN
        for ($j=0; $j<@idx; $j++) {
            $updvals[$idx[$j]] = $bits[$j+1];
        }
        # process the data sources and update the pdp_prep area accordingly
        my @pdp_new=();
        for ($j=0;$j<@updvals; $j++) {
            if ($rrd->{ds}[$j]->{hb} < $interval) {
                # make sure we do not build diffs with old last_ds values
                $rrd->{ds}[$j]->{pdp_prep}->{last_ds}="U";
            }
            if ($updvals[$j] ne "U" && $rrd->{ds}[$j]->{hb} >= $interval) {
                $rate=0+"nan";
                if ( $rrd->{ds}[$j]->{type} eq "COUNTER" ) {
                    if ($updvals[$j] !~ m/^\d+$/) {croak("not a simple unsigned integer ".$updvals[$j]);}
                    if ($rrd->{ds}[$j]->{pdp_prep}->{last_ds} ne "U") {
                        #use bignum; # need this for next line as might be large integers
                        $pdp_new[$j] =  $updvals[$j] - $rrd->{ds}[$j]->{pdp_prep}->{last_ds};
                        # simple overflow catcher
                        if ($pdp_new[$j] < 0) {$pdp_new[$j]+=4294967296; }  #2^32 
                        if ($pdp_new[$j] < 0) {$pdp_new[$j]+=18446744069414584320; }  #2^64-2^32
                        $rate=$pdp_new[$j]/$interval;
                    } else {
                        $pdp_new[$j]=0+"nan";
                    }
                } elsif ( $rrd->{ds}[$j]->{type} eq "DERIVE" ) {
                    if ($updvals[$j] !~ m/^[+|-]?\d+$/) {croak("not a simple signed integer ".$updvals[$j]);}
                    if ($rrd->{ds}[$j]->{pdp_prep}->{last_ds} ne "U") {
                        #use bignum; # need this for next line as might be large integers
                        $pdp_new[$j] =  $updvals[$j] - $rrd->{ds}[$j]->{pdp_prep}->{last_ds};
                        $rate=$pdp_new[$j]/$interval;
                    } else {
                        $pdp_new[$j]=0+"nan";
                    }
                } elsif ( $rrd->{ds}[$j]->{type} eq "GAUGE" ) {
                    if ($updvals[$j] !~ m/^(-)?[\d]+(\.[\d]+)?$/) {croak("not a number ".$updvals[$j]);}
                    $pdp_new[$j] = $updvals[$j]*$interval;
                    $rate=$pdp_new[$j]/$interval;
                } else { # ABSOLUTE
                    $pdp_new[$j] = $updvals[$j];
                    $rate=$pdp_new[$j]/$interval;
                }
                if ($rate ne "nan" 
                    && (
                    ($rrd->{ds}[$j]->{max} ne "nan" && $rate >$rrd->{ds}[$j]->{max})
                    || ($rrd->{ds}[$j]->{min} ne "nan" && $rate <$rrd->{ds}[$j]->{min})
                    )) {
                    $pdp_new[$j]=0+"nan";
                }
            } else {
                $pdp_new[$j]=0+"nan";
            }
            $rrd->{ds}[$j]->{pdp_prep}->{last_ds} = $updvals[$j];
        }
        # how many PDP steps have elapsed since the last update?
        my $proc_pdp_st = $rrd->{last_up} - $rrd->{last_up} % $rrd->{pdp_step};
        my $occu_pdp_age = $current_time % $rrd->{pdp_step};
        my $occu_pdp_st = $current_time - $occu_pdp_age;
        my $pre_int; my $post_int;
        if ($occu_pdp_st > $proc_pdp_st) {
            # OK we passed the pdp_st moment
            $pre_int = $occu_pdp_st - $rrd->{last_up};
            $post_int = $occu_pdp_age;
        } else {
            $pre_int = $interval;
            $post_int=0;
        }
        my $proc_pdp_cnt = $proc_pdp_st / $rrd->{pdp_step};
        my $elapsed_pdp_st = ($occu_pdp_st - $proc_pdp_st)/$rrd->{pdp_step};
        # have we moved past a pdp step size since last run ?
        if ($elapsed_pdp_st == 0) {
            # nope, simple_update
            for ($j=0; $j<$rrd->{ds_cnt}; $j++) {
                if ($pdp_new[$j] eq "nan") { 
                    $rrd->{ds}[$j]->{pdp_prep}->{unkn_sec_cnt} += int($interval); 
                } elsif ($rrd->{ds}[$j]->{pdp_prep}->{val} eq "nan" ) {
                    $rrd->{ds}[$j]->{pdp_prep}->{val} = $pdp_new[$j];
                } else {
                    $rrd->{ds}[$j]->{pdp_prep}->{val} += $pdp_new[$j];
                }
            }
        } else {
            # yep
            # process_all_pdp_st
            my $pre_unknown; my @pdp_temp; my $diff_pdp_st;
            for ($j=0; $j<$rrd->{ds_cnt}; $j++) {
                # Process an update that occurs after one of the PDP moments.
                # Increments the PDP value, sets NAN if time greater than the heartbeats have elapsed
                $pre_unknown=0; 
                if ($pdp_new[$j] eq "nan") {
                     $pre_unknown=$pre_int;
                } else {
                    #print $rrd->{ds}[$j]->{pdp_prep}->{val}," ";
                    if ($rrd->{ds}[$j]->{pdp_prep}->{val} eq "nan") {
                        $rrd->{ds}[$j]->{pdp_prep}->{val} = 0;
                    } 
                    $rrd->{ds}[$j]->{pdp_prep}->{val} += $pdp_new[$j]/$interval * $pre_int;
                }
                #print $pdp_new[$j]," ",$interval," ",$pre_int," ",$rrd->{ds}[$j]->{pdp_prep}->{val},"\n";
                if ($interval > $rrd->{ds}[$j]->{hb} || $rrd->{pdp_step}/2.0 < $rrd->{ds}[$j]->{pdp_prep}->{unkn_sec_cnt}+$pre_unknown) {
                    $pdp_temp[$j]=0+"nan";
                } else {
                    $pdp_temp[$j]=$rrd->{ds}[$j]->{pdp_prep}->{val}/($elapsed_pdp_st*$rrd->{pdp_step}-$rrd->{ds}[$j]->{pdp_prep}->{unkn_sec_cnt}-$pre_unknown);
                }
                #print $pdp_new[$j]," ",$pdp_temp[$j]," ",$rrd->{ds}[$j]->{pdp_prep}->{val}," ", $elapsed_pdp_st-$rrd->{ds}[$j]->{pdp_prep}->{unkn_sec_cnt}-$pre_unknown,"\n";
                if ($pdp_new[$j] eq "nan") {
                    $rrd->{ds}[$j]->{pdp_prep}->{unkn_sec_cnt} = int($post_int);
                    $rrd->{ds}[$j]->{pdp_prep}->{val}=0+"nan";
                } else {
                    $rrd->{ds}[$j]->{pdp_prep}->{unkn_sec_cnt} = 0;
                    $rrd->{ds}[$j]->{pdp_prep}->{val}=$pdp_new[$j]/$interval*$post_int;
                    #print $pdp_new[$j]," ", $interval, " ", $post_int, " ",$rrd->{ds}[$j]->{pdp_prep}->{val},"\n";
                }
            }
            # update_all_cdp_prep. Iterate over all the RRAs for a given DS and update the CDP
            my $current_cf; my $start_pdp_offset; my @rra_step_cnt;
            my $cum_val; my $cur_val; my $pdp_into_cdp_cnt; my $ii;
            my $idx=_get_header_size($self); # file position (used by in place updates)
            for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
                $start_pdp_offset = $rrd->{rra}[$ii]->{pdp_cnt} - $proc_pdp_cnt % $rrd->{rra}[$ii]->{pdp_cnt};
                if ($start_pdp_offset <= $elapsed_pdp_st) {
                    $rra_step_cnt[$ii] = int(($elapsed_pdp_st - $start_pdp_offset)/$rrd->{rra}[$ii]->{pdp_cnt}) + 1;
                } else {
                    $rra_step_cnt[$ii] = 0;
                }
                # update_cdp_prep.  update CDP_PREP areas, loop over data sources within each RRA
                for ($j=0; $j<$rrd->{ds_cnt}; $j++) {
                    if ($rrd->{rra}[$ii]->{pdp_cnt} > 1) {
                        # update_cdp. Given the new reading (pdp_temp_val), update or initialize the CDP value, primary value, secondary value, and # of unknowns.
                        if ($rra_step_cnt[$ii]>0) {
                            if ($pdp_temp[$j] eq "nan") {
                                $rrd->{rra}[$ii]->{cdp_prep}[$j]->[UNKN_PDP_CNT] +=$start_pdp_offset;
                                $rrd->{rra}[$ii]->{cdp_prep}[$j]->[SECONDARY_VAL] = 0+"nan";
                            } else {
                                $rrd->{rra}[$ii]->{cdp_prep}[$j]->[SECONDARY_VAL] = $pdp_temp[$j];
                            }
                            if ($rrd->{rra}[$ii]->{cdp_prep}[$j]->[UNKN_PDP_CNT] > $rrd->{rra}[$ii]->{pdp_cnt}*$rrd->{rra}[$ii]->{xff}) {
                                $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = 0+"nan";
                            } else {
                                #initialize_cdp_val
                                if ($rrd->{rra}[$ii]->{name} eq "AVERAGE") {
                                    if ($rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL] eq "nan") {
                                        $cum_val=0.0;
                                    } else {
                                        $cum_val = $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL];
                                    }
                                    if ($pdp_temp[$j] eq "nan") {
                                        $cur_val=0.0;
                                    } else {
                                        $cur_val = $pdp_temp[$j];
                                    }
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = ($cum_val+$cur_val*$start_pdp_offset)/($rrd->{rra}[$ii]->{pdp_cnt}-$rrd->{rra}[$ii]->{cdp_prep}[$j]->[UNKN_PDP_CNT]);
                                } elsif ($rrd->{rra}[$ii]->{name} eq "MAX") {
                                    if ($rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL] eq "nan") {
                                        $cum_val=0-"inf";
                                    } else {
                                        $cum_val = $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL];
                                    }
                                    if ($pdp_temp[$j] eq "nan") {
                                        $cur_val=0-"inf";
                                    } else {
                                        $cur_val = $pdp_temp[$j];
                                    }
                                    if ($cur_val > $cum_val) {
                                        $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = $cur_val;
                                    } else {
                                        $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = $cum_val;
                                    }
                                } elsif ($rrd->{rra}[$ii]->{name} eq "MIN") {
                                    if ($rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL] eq "nan") {
                                        $cum_val=0+"inf";
                                    } else {
                                        $cum_val = $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL];
                                    }
                                    if ($pdp_temp[$j] eq "nan") {
                                        $cur_val=0+"inf";
                                    } else {
                                        $cur_val = $pdp_temp[$j];
                                    }
                                    if ($cur_val < $cum_val) {
                                        $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = $cur_val;
                                    } else {
                                        $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = $cum_val;
                                    }
                                } else {
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = $pdp_temp[$j];
                                }
                            }
                            #*cdp_val = initialize_carry_over
                            $pdp_into_cdp_cnt=($elapsed_pdp_st - $start_pdp_offset) % $rrd->{rra}[$ii]->{pdp_cnt};
                            if ($pdp_into_cdp_cnt == 0 || $pdp_temp[$j] eq "nan") {
                                if ($rrd->{rra}[$ii]->{name} eq "MAX") {
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]=0-"inf";
                                } elsif ($rrd->{rra}[$ii]->{name} eq "MIN") {
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]=0+"inf";
                                } elsif ($rrd->{rra}[$ii]->{name} eq "AVERAGE") {
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]=0;
                                } else {
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]=0+"nan";
                                }
                            } else {
                                if ($rrd->{rra}[$ii]->{name} eq "AVERAGE") {
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]=$pdp_temp[$j]*$pdp_into_cdp_cnt;
                                } else {
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]=$pdp_temp[$j];
                                }
                            }
                            if ($pdp_temp[$j] eq "nan") {
                                $rrd->{rra}[$ii]->{cdp_prep}[$j]->[UNKN_PDP_CNT] = ($elapsed_pdp_st - $start_pdp_offset) % $rrd->{rra}[$ii]->{pdp_cnt};
                            } else {
                                $rrd->{rra}[$ii]->{cdp_prep}[$j]->[UNKN_PDP_CNT] = 0;
                            }
                        } else {
                            if ($pdp_temp[$j] eq "nan") {
                                $rrd->{rra}[$ii]->{cdp_prep}[$j]->[UNKN_PDP_CNT] += $elapsed_pdp_st;
                            } else {
                                #*cdp_val =calculate_cdp_val
                                if ($rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL] eq "nan") {
                                    if ($rrd->{rra}[$ii]->{name} eq "AVERAGE") {
                                        $pdp_temp[$j] *= $elapsed_pdp_st;
                                    } 
                                    $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]=$pdp_temp[$j];
                                } else {
                                    if ($rrd->{rra}[$ii]->{name} eq "AVERAGE") {
                                        $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]+=$pdp_temp[$j]*$elapsed_pdp_st;
                                    } elsif ($rrd->{rra}[$ii]->{name} eq "MIN") {
                                        if ($pdp_temp[$j] < $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]) {
                                            $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL] = $pdp_temp[$j];
                                        }
                                    } elsif ($rrd->{rra}[$ii]->{name} eq "MAX")  {
                                        if ($pdp_temp[$j] > $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL]) {
                                            $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL] = $pdp_temp[$j];
                                        } 
                                    } else {
                                        $rrd->{rra}[$ii]->{cdp_prep}[$j]->[VAL] = $pdp_temp[$j];
                                    }
                                }
                            }
                        }
                    } else {
                        # Nothing to consolidate if there's one PDP per CDP
                        $rrd->{rra}[$ii]->{cdp_prep}[$j]->[PRIMARY_VAL] = $pdp_temp[$j];
                        if ($elapsed_pdp_st > 1) {
                            $rrd->{rra}[$ii]->{cdp_prep}[$j]->[SECONDARY_VAL] = $pdp_temp[$j];
                        }
                        # consolidated with update_aberrant_cdps
                    }
                } # $j ds_cnt
                # write to RRA
                for (my $scratch_idx=PRIMARY_VAL; $rra_step_cnt[$ii] >0; $rra_step_cnt[$ii]--, $scratch_idx=SECONDARY_VAL) {
                    $rrd->{rra}[$ii]->{ptr} = ($rrd->{rra}[$ii]->{ptr}+1) %  $rrd->{rra}[$ii]->{row_cnt};
                    #write_RRA_row
                    my @line;
                    for ($j=0; $j<$rrd->{ds_cnt}; $j++) {
                        push(@line, $rrd->{rra}[$ii]->{cdp_prep}[$j]->[$scratch_idx]);
                    }
                    if ($inplace eq "memory") {
                        $rrd->{rra}[$ii]->{data}[$rrd->{rra}[$ii]->{ptr}] = _packd($self,\@line);
                    } else {
                        # update in place
                        seek $fd,$idx+$rrd->{rra}[$ii]->{ptr}*$rrd->{ds_cnt}*$self->{FLOAT_EL_SIZE},0;
                        print $fd _packd($self,\@line);
                    }
                    # rrd_notify_row
                }
                $idx+=$rrd->{rra}[$ii]->{row_cnt}*$rrd->{ds_cnt}*$self->{FLOAT_EL_SIZE}; # step file pointer to start of next RRA
            } # $ii rra_cnt
        } # complex update
        $rrd->{last_up}=$current_time;
    } # args
    if ($inplace eq "file") {
        # update header
        seek $fd,0,0;
        #print $fd $self->getheader();
        _saveheader($self,$fd);
    }
    return 1;
}

sub fetch {
    # dump out measurement data
    use Getopt::Long qw(GetOptionsFromString :config pass_through);
    my ($self, $args_str) = @_;  my $rrd=$self->{rrd};
    my $out='';
    
    my $step=$rrd->{pdp_step}; my $start=time()-24*60*60; my $end=time(); 
    my $ret; my $args;
    ($ret, $args) = GetOptionsFromString($args_str,
    "resolution|r:i" => \$step,
    "start|s:i" => \$start,
    "end|e:i"  => \$end
    );
    # at the moment, start/end times are unix timestamps.
    if ($start < 3600 * 24 * 365 * 10) {croak("the first entry to fetch should be after 1980");}
    if ($end < $start) {croak("start ($start) should be less than end ($end)");}
    if ($step<1) {croak("step must be >= 1 second");}
    my $cf=uc($args->[0]); my $i;
    if ($cf !~ m/AVERAGE|MIN|MAX|LAST/) {croak("unknown CF\n");}
    
    # find the RRA which best matches the requirements
    my $cal_end; my $cal_start; my $step_diff; my $firstfull=1; my $firstpart=1;
    my $full_match=$end-$start;
    my $best_full_step_diff=0; my $best_full_rra; my $best_match=0;
    my $best_part_step_diff=0; my $best_part_rra;
    my $tmp_match;
    for ($i = 0; $i < $rrd->{rra_cnt}; $i++) {
        if ($rrd->{rra}[$i]->{name} eq $cf) {
            $cal_end=$rrd->{last_up} - $rrd->{last_up}%($rrd->{rra}[$i]->{pdp_cnt}*$rrd->{pdp_step});
            $cal_start=$cal_end - $rrd->{rra}[$i]->{pdp_cnt}*$rrd->{rra}[$i]->{row_cnt}*$rrd->{pdp_step};
            $step_diff = $step-$rrd->{pdp_step}*$rrd->{rra}[$i]->{pdp_cnt};
            if ($step_diff<0) {$step_diff=-$step_diff;} # take absolute value
            if ($cal_start <= $start) {
                if ($firstfull || $step_diff < $best_full_step_diff) {
                    $firstfull=0; $best_full_step_diff = $step_diff; $best_full_rra=$i;
                }
            } else {
                $tmp_match = $full_match;
                if ($cal_start>$start) {$tmp_match-=($cal_start-$start);}
                if ($firstpart || ($best_match<$tmp_match && $step_diff < $best_part_step_diff)) {
                    $firstpart=0; $best_match=$tmp_match; $best_part_step_diff=$step_diff; $best_part_rra=$i;
                }
            }
        }
    }
    my $chosen_rra; my @line;
    if ($firstfull == 0) {$chosen_rra=$best_full_rra;}
    elsif ($firstpart==0) {$chosen_rra=$best_part_rra;}
    else {croak("the RRD does not contain an RRA matching the chosen CF");}
    $step = $rrd->{rra}[$chosen_rra]->{pdp_cnt}*$rrd->{pdp_step};
    $start -= $start % $step;
    $end += ($step - $end % $step);

    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}

    # output column headings
    $out.=sprintf "%12s"," ";
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
        $out.=sprintf "%-17s", $rrd->{ds}[$i]->{name};
    }
    $out.=sprintf "%s", "\n";
    my $t = $rrd->{last_up} - $rrd->{last_up}%($rrd->{rra}[$chosen_rra]->{pdp_cnt}*$rrd->{pdp_step}) -($rrd->{rra}[$chosen_rra]->{row_cnt}-1)*$rrd->{rra}[$chosen_rra]->{pdp_cnt}*$rrd->{pdp_step};
    my $jj; my $j;
    for ($j=0; $j<$rrd->{rra}[$chosen_rra]->{row_cnt}; $j++) {
        if ($t > $start && $t <= $end+$step) {
            $out.=sprintf "%10u: ",$t;
            $jj= ($rrd->{rra}[$chosen_rra]->{ptr}+1 + $j)%$rrd->{rra}[$chosen_rra]->{row_cnt};
            @line=_unpackd($self,$rrd->{rra}[$chosen_rra]->{data}[$jj]);
            for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
                    $out.=sprintf "%-16.10e ", $line[$i];
            }
            $out.=sprintf "%s", "\n";
        }
        $t+=$step;
    }        
    return $out;
}

sub info {
    # dump out header info
    my $self=$_[0]; my $rrd = $self->{rrd};
    my $out='';
    
    $out.=sprintf "%s", "rrd_version = ".$rrd->{version}."\n";
    if (@_==1) {
       $out.=sprintf "%s", "encoding = ";
       if ($self->{encoding} eq "native-double") {
	      $out.=$self->{encoding};
       } elsif ($self->{encoding} =~ /double/) {
	      $out.="portable-double (".$self->{encoding}.")";
       } else {
          $out.="portable-single (".$self->{encoding}.")";
       }
       $out.="\n";
    }
    $out.=sprintf "%s", "step = ".$rrd->{pdp_step}."\n";
    $out.=sprintf "%s", "last_update = ".int($rrd->{last_up})."\n";
    my $i; my $str; my $ii;
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
        $str="ds[".$rrd->{ds}[$i]->{name}."]";
        $out.=sprintf "%s", "$str.index = ".$i."\n";
        $out.=sprintf "%s", "$str.type = \"".$rrd->{ds}[$i]->{type}."\"\n";
        $out.=sprintf "%s", "$str.minimal_heartbeat = ".$rrd->{ds}[$i]->{hb}."\n";
        $out.=sprintf "%s", "$str.min = ".$rrd->{ds}[$i]->{min}."\n";
        $out.=sprintf "%s", "$str.max = ".$rrd->{ds}[$i]->{max}."\n";
        $out.=sprintf "%s", "$str.last_ds = \"".$rrd->{ds}[$i]->{pdp_prep}->{last_ds}."\"\n";
        $out.=sprintf "$str.value = %0.10e\n",$rrd->{ds}[$i]->{pdp_prep}->{val};
        $out.=sprintf "%s", "$str.unknown_sec = ".$rrd->{ds}[$i]->{pdp_prep}->{unkn_sec_cnt}."\n";
    }
    for ($i=0; $i<$rrd->{rra_cnt}; $i++) {
        $str="rra[$i]";
        $out.=sprintf "%s", "$str.cf = \"".$rrd->{rra}[$i]->{name}."\"\n";
        $out.=sprintf "%s", "$str.rows = ".$rrd->{rra}[$i]->{row_cnt}."\n";
        $out.=sprintf "%s", "$str.cur_row = ".$rrd->{rra}[$i]->{ptr}."\n";
        $out.=sprintf "%s", "$str.pdp_per_row = ".$rrd->{rra}[$i]->{pdp_cnt}."\n";
        $out.=sprintf "$str.xff = %0.10e\n",$rrd->{rra}[$i]->{xff};
        for ($ii=0; $ii<$rrd->{ds_cnt}; $ii++) {
            $out.=sprintf "$str.cdp_prep[$ii].value = %0.10e\n",$rrd->{rra}[$i]->{cdp_prep}[$ii]->[VAL];
            $out.=sprintf "%s", "$str.cdp_prep[$ii].unknown_datapoints = ".$rrd->{rra}[$i]->{cdp_prep}[$ii]->[UNKN_PDP_CNT]."\n";
        }
    }
    return $out;
}

sub dump {
    # XML dump of RRD file
    use Getopt::Long qw(GetOptionsFromString :config pass_through);
    my ($self, $args_str) = @_;  my $rrd=$self->{rrd};

    my $noheader=0;
    if (defined($args_str)) {
        my $ret; my $args;
        ($ret, $args) = GetOptionsFromString($args_str,
        "no-header|n" => \$noheader,
        );
    }
    
    # load RRA data, if not already loaded
    if (!defined($rrd->{dataloaded})) {_loadRRAdata($self);}

    my $out=''; my @line;
    
    if ($noheader<1) {
       $out.=sprintf "%s", '<?xml version="1.0" encoding="utf-8"?>'."\n";
       $out.=sprintf "%s", '<!DOCTYPE rrd SYSTEM "http://oss.oetiker.ch/rrdtool/rrdtool.dtd">'."\n";
    } 
    $out.=sprintf "%s", "<!-- Round Robin Database Dump -->\n<rrd>\n\t<version>".$rrd->{version}."</version>\n";
    $out.=sprintf "%s", "\t<step>".$rrd->{pdp_step}."</step> <!-- Seconds -->\n\t<lastupdate>".$rrd->{last_up}."</lastupdate> <!-- ".strftime("%Y-%m-%d %T %Z",localtime($rrd->{last_up})). "-->\n\t";
    my $i; my $ii; my $j; my $jj; my $t;
    for ($i=0; $i<$rrd->{ds_cnt}; $i++) { 
        $out.=sprintf "%s", "\n\t<ds>\n\t\t<name>".$rrd->{ds}[$i]->{name}."</name>\n\t\t";
        $out.=sprintf "%s", "<type>".$rrd->{ds}[$i]->{type}."</type>\n\t\t";
        $out.=sprintf "%s", "<minimal_heartbeat>".$rrd->{ds}[$i]->{hb}."</minimal_heartbeat>\n\t\t",;
        $out.=sprintf "%s", "<min>".$rrd->{ds}[$i]->{min}."</min>\n\t\t<max>".$rrd->{ds}[$i]->{max}."</max>\n\t\t";
        $out.=sprintf "%s", "\n\t\t<!-- PDP Status -->\n\t\t<last_ds>".$rrd->{ds}[$i]->{pdp_prep}->{last_ds}."</last_ds>\n\t\t";
        $out.=sprintf "<value>%0.10e</value>\n\t\t", $rrd->{ds}[$i]->{pdp_prep}->{val}+0;
        $out.=sprintf "%s", "<unknown_sec>".$rrd->{ds}[$i]->{pdp_prep}->{unkn_sec_cnt}."</unknown_sec>\n\t";
        $out.=sprintf "%s", "</ds>\n";
    }
    $out.=sprintf "%s", "\n\t<!-- Round Robin Archives -->\n";
    for ($i=0; $i<$rrd->{rra_cnt}; $i++) {
        $out.=sprintf "%s", "\t<rra>\n\t\t";
        $out.=sprintf "%s", "<cf>".$rrd->{rra}[$i]->{name}."</cf>\n\t\t";
        $out.=sprintf "%s", "<pdp_per_row>".$rrd->{rra}[$i]->{pdp_cnt}."</pdp_per_row> <!-- ".$rrd->{rra}[$i]->{pdp_cnt}*$rrd->{pdp_step}." seconds -->\n\n\t\t";
        $out.=sprintf "<params>\n\t\t<xff>%0.10e</xff>\n\t\t</params>\n\t\t",$rrd->{rra}[$i]->{xff};
        $out.=sprintf "%s", "<cdp_prep>\n\t\t";
        for ($ii=0; $ii<$rrd->{ds_cnt}; $ii++) {
            $out.=sprintf "\t<ds>\n\t\t\t<primary_value>%0.10e</primary_value>\n\t\t\t", $rrd->{rra}[$i]->{cdp_prep}[$ii]->[PRIMARY_VAL];
            $out.=sprintf "<secondary_value>%0.10e</secondary_value>\n\t\t\t", $rrd->{rra}[$i]->{cdp_prep}[$ii]->[SECONDARY_VAL];
			$out.=sprintf "<value>%0.10e</value>\n\t\t\t", $rrd->{rra}[$i]->{cdp_prep}[$ii]->[VAL];
			$out.=sprintf "%s", "<unknown_datapoints>". $rrd->{rra}[$i]->{cdp_prep}[$ii]->[UNKN_PDP_CNT]."</unknown_datapoints>\n\t\t\t";            
            $out.=sprintf "%s", "</ds>\n\t\t";        
        }
        $out.=sprintf "%s", "</cdp_prep>\n\t\t";
        $out.=sprintf "%s", "<database>\n\t\t";
        $t = $rrd->{last_up} - $rrd->{last_up}%($rrd->{rra}[$i]->{pdp_cnt}*$rrd->{pdp_step}) -($rrd->{rra}[$i]->{row_cnt}-1)*$rrd->{rra}[$i]->{pdp_cnt}*$rrd->{pdp_step};
            for ($j=0; $j<$rrd->{rra}[$i]->{row_cnt}; $j++) {
                $jj= ($rrd->{rra}[$i]->{ptr}+1 + $j)%$rrd->{rra}[$i]->{row_cnt};
                $out.=sprintf "\t%s", "<!-- ".strftime("%Y-%m-%d %T %Z",localtime($t)). " / $t --> <row>";
                @line=_unpackd($self,$rrd->{rra}[$i]->{data}[$jj]);
                for ($ii=0; $ii<$rrd->{ds_cnt}; $ii++) {
                       $out.=sprintf "<v>%0.10e</v>", $line[$ii];
                }
                $out.=sprintf "%s", "</row>\n\t\t";
                $t+=$rrd->{rra}[$i]->{pdp_cnt}*$rrd->{pdp_step};
            }
            $out.=sprintf "%s", "</database>\n\t";
        $out.=sprintf "%s", "</rra>\n";
    }
    $out.=sprintf "%s", "</rrd>\n";
    return $out;
}

####
sub _saveheader {
    # construct binary header for RRD file
    my $self=$_[0];
    my $fd=$_[1];

    my $L=$self->_packlongchar();
    my $header="\0"x _get_header_size($self); # preallocate header
    substr($header,0,9,"RRD\0".$self->{rrd}->{version});
    substr($header,$self->{OFFSET},$self->{FLOAT_EL_SIZE}+3*$self->{LONG_EL_SIZE}, $self->{COOKIE}.pack("$L $L $L",$self->{rrd}->{ds_cnt}, $self->{rrd}->{rra_cnt}, $self->{rrd}->{pdp_step}));
    # DS defs
    my $idx=$self->{STAT_HEADER_SIZE0};
    for (my $i=0; $i<$self->{rrd}->{ds_cnt}; $i++) {
        substr($header,$idx,40+$self->{FLOAT_EL_SIZE},pack("Z20 Z20 $L x".$self->{DIFF_SIZE},
		$self->{rrd}->{ds}[$i]->{name}, $self->{rrd}->{ds}[$i]->{type}, $self->{rrd}->{ds}[$i]->{hb}));
        $idx+=40+$self->{FLOAT_EL_SIZE};
        my @minmax=($self->{rrd}->{ds}[$i]->{min}, $self->{rrd}->{ds}[$i]->{max});
        substr($header,$idx,2*$self->{FLOAT_EL_SIZE},_packd($self,\@minmax));
        $idx+=9*$self->{FLOAT_EL_SIZE};
    }
    # RRA defs
    my $i;
    for ($i=0; $i<$self->{rrd}->{rra_cnt}; $i++) {
        substr($header,$idx,20+$self->{RRA_DEL_PAD}+2*$self->{LONG_EL_SIZE},pack("Z".(20+$self->{RRA_DEL_PAD})." $L $L",$self->{rrd}->{rra}[$i]->{name}, $self->{rrd}->{rra}[$i]->{row_cnt}, $self->{rrd}->{rra}[$i]->{pdp_cnt}));
        $idx+=20+$self->{RRA_DEL_PAD}+2*$self->{LONG_EL_SIZE};
        my @xff=($self->{rrd}->{rra}[$i]->{xff});
        substr($header,$idx+$self->{RRA_PAD},$self->{FLOAT_EL_SIZE},_packd($self,\@xff));
        $idx += $self->{FLOAT_EL_SIZE}*10+$self->{RRA_PAD};
    }
    # live header
    substr($header,$idx,2*$self->{LONG_EL_SIZE},pack("$L $L", $self->{rrd}->{last_up},0));
    $idx+= 2*$self->{LONG_EL_SIZE};
    # PDP_PREP
    for ($i=0; $i<$self->{rrd}->{ds_cnt}; $i++) {
        substr($header,$idx,30+$self->{PDP_PREP_PAD}+$self->{FLOAT_EL_SIZE},
          pack("Z".(30+$self->{PDP_PREP_PAD})." $L x".$self->{DIFF_SIZE},$self->{rrd}->{ds}[$i]->{pdp_prep}->{last_ds}, $self->{rrd}->{ds}[$i]->{pdp_prep}->{unkn_sec_cnt}));
        $idx+=30+$self->{PDP_PREP_PAD}+$self->{FLOAT_EL_SIZE};
        my @val=($self->{rrd}->{ds}[$i]->{pdp_prep}->{val});
        substr($header,$idx,$self->{FLOAT_EL_SIZE},_packd($self,\@val));
        $idx+= $self->{FLOAT_EL_SIZE}*9;
    }
    # CDP_PREP
    my @val; my $ii;
    for (my $ii=0; $ii<$self->{rrd}->{rra_cnt}; $ii++) {
        for ($i=0; $i<$self->{rrd}->{ds_cnt}; $i++) {
            # do a bit of code optimisation here
            if ($self->{encoding} eq "native-double") {
                substr($header,$idx,$self->{CDP_PREP_EL_SIZE}, pack("d $L x".$self->{DIFF_SIZE}." d d d d $L x".$self->{DIFF_SIZE}." $L x".$self->{DIFF_SIZE}." d d",@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}));
                $idx+=$self->{CDP_PREP_EL_SIZE};
            } elsif ($self->{encoding} eq "native-single") {
                substr($header,$idx,$self->{CDP_PREP_EL_SIZE}, pack("f $L x".$self->{DIFF_SIZE}." f f f f $L x".$self->{DIFF_SIZE}." $L x".$self->{DIFF_SIZE}." f f",@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}));
                $idx+=$self->{CDP_PREP_EL_SIZE};
            } else {
                substr($header,$idx,$self->{FLOAT_EL_SIZE},_packd($self,[@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[0]]));
                $idx+=$self->{FLOAT_EL_SIZE};
                substr($header,$idx,$self->{FLOAT_EL_SIZE},pack("$L x".$self->{DIFF_SIZE},@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[1]));
                $idx+=$self->{FLOAT_EL_SIZE};
                substr($header,$idx,4*$self->{FLOAT_EL_SIZE},_packd($self,[@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[2..5]]));
                $idx+=4*$self->{FLOAT_EL_SIZE};
                substr($header,$idx,2*$self->{FLOAT_EL_SIZE},pack("$L x".$self->{DIFF_SIZE}." $L x".$self->{DIFF_SIZE},@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[6..7]));
                $idx+=2*$self->{FLOAT_EL_SIZE};
                substr($header,$idx,2*$self->{FLOAT_EL_SIZE},_packd($self,[@val=@{$self->{rrd}->{rra}[$ii]->{cdp_prep}[$i]}[8..9]]));
                $idx+=2*$self->{FLOAT_EL_SIZE};
            }
        }
    }
    # RRA PTR
    for ($i=0; $i<$self->{rrd}->{rra_cnt}; $i++) {
        substr($header,$idx,$self->{LONG_EL_SIZE},pack("$L",$self->{rrd}->{rra}[$i]->{ptr}));
        $idx+=$self->{LONG_EL_SIZE};
    }    
    #return $header;
    print $fd $header;
}

sub save {
    # save RRD data to a file
    my $self=$_[0]; 
    
    # load RRA data, if not already loaded
    if (!defined($self->{rrd}->{dataloaded})) {_loadRRAdata($self);}
    
    if (@_>1) {  
        # open file
        $self->{file_name}=$_[1];
    } elsif (!defined($self->{file_name})) {
        croak("Must either supply a filename to use or have a file already opened e.g. via calling open()\n");
    }
    open $self->{fd}, ">", $self->{file_name};
    binmode($self->{fd});
    my $fd=$self->{fd};

    if (!defined($self->{encoding})) { croak("Current encoding must be defined\n.");}
    my $current_encoding=$self->{encoding};
    if (@_>2) {$self->{encoding}=$_[2];}
    _sizes($self);

    # output headers
    #print $fd $self->getheader();
    _saveheader($self,$fd);

    # output data
    my @line; my $i; my $ii;
    for ($ii=0; $ii<$self->{rrd}->{rra_cnt}; $ii++) {
        for ($i=0; $i<$self->{rrd}->{rra}[$ii]->{row_cnt}; $i++) {
            if ($self->{encoding} ne $current_encoding) {
                # need to convert binary data encoding
                @line=_unpackd($self,$self->{rrd}->{rra}[$ii]->{data}[$i],$current_encoding);
                $self->{rrd}->{rra}[$ii]->{data}[$i] = _packd($self,\@line);
            }
            print $fd $self->{rrd}->{rra}[$ii]->{data}[$i];
        }
    }    
    # done
    #close($fd);   
    return 1;
}

####
sub close {
    # close an open RRD file
    my $self=$_[0];
    if (defined($self->{fd})) { close($self->{fd}); }
}

####

sub create {
    # create a new RRD
    my ($self, $args_str) = @_;  my $rrd=$self->{rrd};

    my $last_up=time(); my $pdp_step=300; 
    my $encoding=_default_fileformat(); # default to RRDTOOL compatible encoding.
    my $ret; my $args;
    ($ret, $args) = GetOptionsFromString($args_str,
    "start|b:i" => \$last_up,
    "step|s:i"  => \$pdp_step,
    "format|f:s"  => \$encoding
    );
    if ($last_up < 3600 * 24 * 365 * 10) { croak("the first entry to the RRD should be after 1980\n"); }
    if ($pdp_step <1) {croak("step size should be no less than one second\n");}
    if ($encoding !~ m/(native-double|portable-double|portable-single)/) {croak("unknown format ".$encoding."\n");} 
    $self->{encoding}=$encoding;
    _sizes($self);
        
    $rrd->{version}="0003";
    $rrd->{ds_cnt}=0; $rrd->{rra_cnt}=0; $rrd->{pdp_step}=$pdp_step;    
    $rrd->{last_up}=$last_up;
    
    # now parse the DS and RRA info
    my $i;
    my $min; my $max;
    for ($i=0; $i<@{$args}; $i++) {
        if (${$args}[$i] =~ m/^DS:([a-zA-Z0-9]+):(GAUGE|COUNTER|DERIVE|ABSOLUTE):([0-9]+):(U|[0-9\.]+):(U|[0-9\.]+)$/) {
            my $ds; 
            $min=$4;  if ($min eq "U") {$min=0+"nan";} # set to NaN
            $max=$5;  if ($max eq "U") {$max=0+"nan";} # set to NaN
            ($ds->{name}, $ds->{type}, $ds->{hb}, $ds->{min}, $ds->{max}, 
            $ds->{pdp_prep}->{last_ds}, $ds->{pdp_prep}->{unkn_sec_cnt}, $ds->{pdp_prep}->{val}
            )= ($1,$2,$3,$min,$max,"U", $last_up%$pdp_step, 0.0);
            $rrd->{ds}[@{$rrd->{ds}}]=$ds;
            $rrd->{ds_cnt}++;
        } elsif (${$args}[$i] =~ m/^RRA:(AVERAGE|MAX|MIN|LAST):([0-9\.]+):([0-9]+):([0-9]+)$/) {
            my $rra;
            if ($4<1) { croak("Invalid row count $4\n");}
            if ($2<0.0 || $2>1.0) { croak("Invalid xff $2: must be between 0 and 1\n");}
            if ($3<1) { croak("Invalid step $3: must be >= 1\n");}
            ($rra->{name}, $rra->{xff}, $rra->{pdp_cnt}, $rra->{row_cnt}, $rra->{ptr}, $rra->{data})=($1,$2,$3,$4,int(rand($4)),undef);
            $rrd->{rra}[@{$rrd->{rra}}]=$rra;
            $rrd->{rra_cnt}++;
        }
    }
    if ($rrd->{ds_cnt}<1) {croak("You must define at least one Data Source\n");}
    if ($rrd->{rra_cnt}<1) {croak("You must define at least one Round Robin Archive\n");}
    
    my $ii;
    for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        for ($i=0; $i<$rrd->{ds_cnt}; $i++) {
            @{$rrd->{rra}[$ii]->{cdp_prep}[$i]} = (0+"nan",(($last_up-$last_up%$pdp_step)%($pdp_step*$rrd->{rra}[$ii]->{pdp_cnt}))/$pdp_step,0,0,0,0,0,0,0,0);
        }
    }
 
    # initialise the data
    my $j;
    my @empty=((0+"nan")x$rrd->{ds_cnt});
    for ($ii=0; $ii<$rrd->{rra_cnt}; $ii++) {
        for ($i=0; $i<$rrd->{rra}[$ii]->{row_cnt}; $i++) {
            $rrd->{rra}[$ii]->{data}[$i]=_packd($self,\@empty);
        }
    }
    $rrd->{dataloaded}=1; # record the fact that the data is now loaded in memory
}

####
sub open {
    # open an RRD file and read the header; reading of the body of the RRD file (containing the RRA data) is left until actually needed
    my $self = $_[0];  my $rrd=$self->{rrd}; 
    $self->{file_name}=$_[1]; 
    
    open($self->{fd}, "+<", $self->{file_name}) or croak "Couldn't open file ".$self->{file_name}.": $!\n";
    binmode($self->{fd});
    my $file_len = -s $self->{file_name};

    # check static part of the header (with fixed size)
    # header format: {cookie[4], version[5], double float_cookie, ds_cnt, rra_cnt, pdp_step, par[10] (unused array) }
    read($self->{fd},my $staticheader,16+8*NATIVE_DOUBLE_EL_SIZE); 
    my $file_cookie = unpack("Z4",substr($staticheader,0,4));
    if ($file_cookie ne "RRD") { croak("Wrong magic id $file_cookie\n"); }
    $rrd->{version}=unpack("Z5",substr($staticheader,4,5));
    if ($rrd->{version} ne "0003" && $rrd->{version} ne "0004") { croak("Unsupported RRD version ".$rrd->{version}."\n");}

    # use float cookie to try to figure out the encoding used, taking account of variable byte alignment (e.g. float cookie starts at byte 12 on 32 bits Intel/Linux machines and at byte 16 on 64 bit Intel/Linux machines)
    #my ($x, $y, $byte1, $byte2, $byte3, $byte4, $byte5, $byte6, $byte7, $byte8) =unpack("Z4 Z5 x![L!] C C C C C C C C",substr($staticheader,0,length($staticheader)));
    #print $byte1, " ", $byte2, " ",$byte3," ", $byte4," ", $byte5," ", $byte6," ", $byte7," ", $byte8,"\n";
    $self->{encoding}=undef;
    (my $x, my $y, my $file_floatcookie_native_double) =unpack("Z4 Z5 x![L!] d",substr($staticheader,0,length($staticheader)));
    ($x, $y, my $file_floatcookie_native_double_mips) =unpack("Z4 Z5 x![d] d",substr($staticheader,0,length($staticheader)));
    $file_floatcookie_native_double = sprintf("%0.6e", $file_floatcookie_native_double);
    my ($t)=_unpackd($self,substr($staticheader,12,PORTABLE_SINGLE_EL_SIZE),"native-single");
    my $file_floatcookie_native_single=sprintf("%0.6e",$t); 
    ($t)=_unpackd($self,substr($staticheader,12,PORTABLE_SINGLE_EL_SIZE),"portable-single");
    my $file_floatcookie_portable_single=sprintf("%0.6e",$t); 
    ($t)=_unpackd($self,substr($staticheader,12,PORTABLE_DOUBLE_EL_SIZE),"portable-double");
    my $file_floatcookie_portable_double=sprintf("%0.6e",$t); 
    my $file_floatcookie_littleendian_single; 
    my $file_floatcookie_littleendian_double; 
    if ($PACK_LITTLE_ENDIAN_SUPPORT>0) {
        ($t)=_unpackd($self,substr($staticheader,12,PORTABLE_SINGLE_EL_SIZE),"littleendian-single");
        $file_floatcookie_littleendian_single=sprintf("%0.6e",$t); 
        ($t)=_unpackd($self,substr($staticheader,12,PORTABLE_DOUBLE_EL_SIZE),"littleendian-double");
        $file_floatcookie_littleendian_double=sprintf("%0.6e",$t); 
    }
    my $cookie=sprintf("%0.6e",DOUBLE_FLOATCOOKIE);
    my $singlecookie=sprintf("%0.6e",SINGLE_FLOATCOOKIE);
    if ($file_floatcookie_native_double eq $cookie) {
        $self->{encoding} = "native-double";  
    } elsif ($file_floatcookie_native_double_mips eq  $cookie ) {
        $self->{encoding} = "native-double-mips"; 
    } elsif ($file_floatcookie_native_single eq  $singlecookie ) {
        $self->{encoding} = "native-single"; 
    } elsif ($PACK_LITTLE_ENDIAN_SUPPORT>0 && $file_floatcookie_littleendian_double eq $cookie) {
            $self->{encoding} = "littleendian-double";        
    } elsif ($PACK_LITTLE_ENDIAN_SUPPORT>0 && $file_floatcookie_littleendian_single eq $singlecookie) {
            $self->{encoding} = "littleendian-single";        
    } elsif ($file_floatcookie_portable_single eq $singlecookie) {
        $self->{encoding} = "portable-single";  
    } elsif ($file_floatcookie_portable_double eq $cookie) {
        $self->{encoding} = "portable-double";  
    } else {
        croak("This RRD was created on incompatible architecture\n");
    }
    #print  $self->{encoding},"\n";
    #$self->{encoding} = "portable-double";
    _sizes($self); # now that we know the encoding, calc the sizes of the various elements in the file
    my $L=_packlongchar($self);

    # extract info on number of DS's and RRS's, plus the pdp step size
    ($rrd->{ds_cnt}, $rrd->{rra_cnt}, $rrd->{pdp_step}) =unpack("$L $L $L",substr($staticheader,$self->{OFFSET} +$self->{FLOAT_EL_SIZE},3*$self->{LONG_EL_SIZE}));  
    #print $self->{encoding}," ",$offset," ",$L," ",$self->{FLOAT_EL_SIZE}," ", $self->{LONG_EL_SIZE}," ",$rrd->{ds_cnt}," ",$rrd->{rra_cnt}," ",$rrd->{pdp_step},"\n";

    # read in the full header now;
    seek $self->{fd},0,0; # go back to start of the file
    read($self->{fd},my $header,_get_header_size($self));   
    # extract header info into structured arrays
    my $pos=$self->{DS_DEF_IDX};   
    _extractDSdefs($self,\$header,$pos);
    
    $pos+=$self->{DS_EL_SIZE}*$rrd->{ds_cnt};  
    _extractRRAdefs($self,\$header,$pos);
    
    $pos+=$self->{RRA_DEF_EL_SIZE}*$rrd->{rra_cnt};
    $rrd->{last_up} = unpack("$L",substr($header,$pos,$self->{LONG_EL_SIZE})); 
    
    $pos+=$self->{LIVE_HEAD_SIZE};
    _extractPDPprep($self,\$header,$pos);
    
    $pos+=$self->{PDP_PREP_EL_SIZE}*$rrd->{ds_cnt};
    _extractCDPprep($self,\$header,$pos);
    
    $pos+=$self->{CDP_PREP_EL_SIZE}*$rrd->{ds_cnt}*$rrd->{rra_cnt};   
    _extractRRAptr($self,\$header,$pos);
    
    $pos+=$self->{RRA_PTR_EL_SIZE}*$rrd->{rra_cnt}; 
    
    # validate file size
    my $i; my $row_cnt=0;
    for ($i=0; $i<$rrd->{rra_cnt}; $i++) {
        $row_cnt+=$rrd->{rra}[$i]->{row_cnt};
    }
    my $correct_len=_get_header_size($self) +$self->{FLOAT_EL_SIZE} * $row_cnt*$rrd->{ds_cnt};
    if ($file_len < $correct_len  || $file_len > $correct_len+8) { # extra 8 bytes here is to allow for padding on Linux/Intel 64 bit platforms
        croak($self->{file_name}." size is incorrect (is $file_len bytes but should be $correct_len bytes)");
    }
    $rrd->{dataloaded}=undef; # keep note that data is not loaded yet
    return $self->{encoding};
}

1;


=pod
 
=head1 NAME
 
RRD::Editor - Standalone tool (no need for RRDs.pm) to create and edit RRD files.
 
=head1 SYNOPSIS

 use strict;
 use RRD::Editor ();
 
 # Create a new object
 my $rrd = RRD::Editor->new();
  
 # Create a new RRD with 3 data sources called bytesIn, bytesOut and 
 # faultsPerSec and one RRA which stores 1 day worth of data at 5 minute 
 # intervals (288 data points). The argument format is the same as that used 
 # by 'rrdtool create', see L<http://oss.oetiker.ch/rrdtool/doc/rrdcreate.en.html>
 $rrd->create("DS:bytesIn:GAUGE:600:U:U DS:bytesOut:GAUGE:600:U:U DS:faultsPerSec:COUNTER:600:U:U RRA:AVERAGE:0.5:1:288")

 # Save RRD to a file
 $rrd->save("myfile.rrd");
 # The file format to use can also be optionally specified:
 # $rrd->save("myfile.rrd","native-double");   # default; non-portable format used by RRDTOOL
 # $rrd->save("myfile.rrd","portable-double"); # portable, data stored in double-precision
 # $rrd->save("myfile.rrd","portable-single"); # portable, data stored in single-precision

 # Load RRD from a file.  Automagically figures out the file format 
 # (native-double, portable-double etc) 
 $rrd->open("myfile.rrd");
 
 # Add new data to the RRD for the same 3 data sources bytesIn, 
 # bytesOut and faultsPerSec.  The argument format is the same as that used by 
 # 'rrdtool update', see L<http://oss.oetiker.ch/rrdtool/doc/rrdupdate.en.html>
 $rrd->update("N:10039:389:0.4");
  
 # Show information about an RRD.  Output generated is similar to 
 # "rrdtool info".
 print $rrd->info();
 
 # XML dump of RRD contents.  Output generated is similar to "rrdtool dump".
 print $rrd->dump();
 
 # Extract data measurements stored in RRAs of type "AVERAGE"
 # The argument format is the same as that used by 'rrdtool fetch' and 
 # the output generated is also similar, see
 # L<http://oss.oetiker.ch/rrdtool/doc/rrdfetch.en.html>
 print $rrd->fetch("AVERAGE");
 
 # Get the time when the RRD was last updated (as a unix timestamp)
 printf "RRD last updated at %d\n", $rrd->last();

 # Get the measurements added when the RRD was last updated
 print $rrd->lastupdate();
 
 # Get the min step size (or resolution) of the RRD.  This defaults to 300s unless specified
 otherwise when creating an RRD.
 print $rrd->minstep()
 
=head2 Edit DSs
 
 # Add a new data-source called bytes.  Argument format is the same as $rrd->create().
 $rrd->add_DS("DS:bytes:GAUGE:600:U:U");
 
 # Delete the data-source bytesIn
 $rrd->delete_DS("bytesIn");
 
 # Get a list of the data-sources names
 print $rrd->DS_names();
 
 # Change the name of data-source bytes to be bytes_new
 $rrd->rename_DS("bytes", "bytes_new")
 
 # Get the heartbeat value for data-source bytesOut (the max number of seconds that
 # may elapse between data measurements)
 printf "Heartbeat for DS bytesOut = %d\n", $rrd->DS_heartbeat("bytesOut");

 # Set the heartbeat value for data-source bytesOut to be 1200 secs
 $rrd->set_DS_heartbeat("bytesOut",1200);
 
 # Get the type of data-source bytesOut
 printf "Type of DS bytesOut = %s\n", $rrd->DS_type("bytesOut");
 
 # Set the type of data-source bytesOut to be COUNTER
 $rrd->set_DS_type("bytesOut", "COUNTER");
 
 # Get the minimum value allowed for measurements from data-source bytesOut
 printf "Min value of DS bytesOut = %s\n", $rrd->DS_min("bytesOut");

 # Set the minimum value allowed for measurements from data-source bytesOut to be 0
 $rrd->set_DS_min("bytesOut",0);
 
 # Get the maximum value allowed for measurements from data-source bytesOut
 printf "Max value of DS bytesOut = %s\n", $rrd->DS_max("bytesOut");
 
 # Set the maximum value allowed for measurements from data-source bytesOut to be 100
 $rrd->set_DS_max("bytesOut",100);
 
=head2 Edit RRAs 
 
 # Add a new RRA which stores 1 weeks worth of data at 30 minute intervals 
 # (336 data points)
 $rrd->add_RRA("RRA:AVERAGE:0.5:6:336");

 # RRAs are identified by an index in range 0 .. $rrd->num_RRAs().  The index 
 # of an RRD can also be 
 # found using $rrd->info() or $rrd->dump()
 
 # Delete an existing RRA with index $rra_idx.  
 my $rra_idx=1; 
 $rrd->delete_RRA($rra_idx);
 
 # Get the number of rows/data points stored in an RRD
 my $rra_idx=0; 
 printf "number of rows of RRA %d = %d\n", $rra_idx, $rrd->RRA_numrows($rra_idx);
 
 # Change the number of rows/data points stored in the RRA with index 
 # $rra_idx to 600.
 $rra->resize_RRA($rra_idx, 600);
 
  # Get the value of bytesIn stored at the 10th row/data-point in the 
 # RRA with index $rra_idx.
 printf "Value of data-source bytesIn at row 10 in RRA %d = %d", $rra_idx, $rra->RRA_el($rra_idx, "bytesIn", 10);
 
  # Set the value of bytesIn at the 10th row/data-point to be 100
 $rra->set_RRA_el($rra_idx, "bytesIn", 10, 100);  
 
 # Get the xff value for the RRA with index $rra_idx
 printf "Xff value of RRA %d = %d\n", $rra_idx, $rra->RRA_xff($rra_idx);

 # Set the xff value to 0.75 for the RRA with index $rra_idx
 $rra->RRA_xff($rra_idx,0.75);
 
 # Get the type (AVERAGE, LAST etc) of the RRA with index $rra_idx
 print $rrd->RRA_type($rra_idx);
 
 # Get the step (in seconds) of the RRA with index $rra_idx
 print $rrd->RRA_step($rra_idx);


=head1 DESCRIPTION

RRD:Editor implements most of the functionality of RRDTOOL, apart from graphing, plus adds some new editing and portability features.  It aims to be portable and self-contained (no need for RRDs.pm).
 
RRD::Editor provides the ability to add/delete DSs and RRAs and to get/set most of the parameters in DSs and RRAs (renaming, resizing etc). It also allows the data values stored in each RRA to be inspected and changed individually.  That is, it provides almost complete control over the contents of an RRD.
 
The RRD files created by RRDTOOL use a binary format (let's call it C<native-double>) that is not portable across platforms.  In addition to this file format, RRD:Editor provides two new portable file formats (C<portable-double> and C<portable-single>) that allow the exchange of files.  RRD::Editor can freely convert RRD files between these three formats (C<native-double>,C<portable-double> and C<portable-single>).  
  
Notes:

=over

=item * times must all be specified as unix timestamps (i.e. -1d, -1w etc don't work, and there is no @ option in rrdupdate).

=item * there is full support for COUNTER, GAUGE, DERIVE and ABSOLUTE data-source types but the COMPUTE type is only partially supported.

=item * there is full support for AVERAGE, MIN, MAX, LAST RRA types but the HWPREDCT, MHWPREDICT, SEASONAL etc types are only partially supported).

=back
 
=head1 METHODS
 
=head2 new
 
 my $rrd=new RRD:Editor->new();
 
Creates a new RRD::Editor object
 
=head2 create
 
 $rrd->create($args);
 
The method will create a new RRD with the data-sources and RRAs specified by C<$args>.   C<$args> is a string that contains the same sort of command line arguments that would be passed to C<rrdtool create>.   The format for  C<$args> is:
 
[--start|-b start time] [--step|-s step] [--format|-f encoding] [DS:ds-name:DST:heartbeat:min:max] [RRA:CF:xff:steps:rows]
 
where DST may be one of GAUGE, COUNTER, DERIVE, ABSOLUTE and CF may be one of AVERAGE, MIN, MAX, LAST.  Possible values for encoding are C<native-double>, C<portable-double>, C<portable-single>.  If omitted, defaults to C<native-double> (the non-portable file format used by RRDTOOL). See L<http://oss.oetiker.ch/rrdtool/doc/rrdcreate.en.html> for further information.
 
=head2 open
 
 $rrd->open($file_name);
 
Load the RRD in the file called C<$file_name>.  Only the file header is loaded initially, to improve efficiency, with the body of the file subsequently loaded if needed.  The file format (C<native-double>, C<portable-double> etc) is detected automagically.

=head2 save
 
 $rrd->save();
 $rrd->save($file_name);
 $rrd->save($file_name, $encoding);
 
Save RRD to a file called $file_name with format specified by C<$encoding>.  Possible values for C<$encoding> are C<"native-double">, C<"portable-double">, C<"portable-single">.  
 
If omitted, C<$encoding> defaults to the format of the file specified when calling C<open()>, or to C<native-double> if the RRD has just been created using C<create()>.  C<native-double> is the non-portable binary format used by RRDTOOL.  C<portable-double> is portable across platforms and stores data as double-precision values. C<portable-single> is portable across platforms and stores data as single-precision values (reducing the RRD file size by approximately half).  If interested in the gory details, C<portable-double> is just the native-double format used by Intel 32-bit platforms (i.e. little-endian byte ordering, 32 bit integers, 64 bit IEEE 754 doubles, storage aligned to 32 bit boundaries) - an arbitrary choice, but not unreasonable since Intel platforms are probably the most widespread at the moment, and compatible with web tools such as javascriptRRD L<http://javascriptrrd.sourceforge.net/>.
 
If the RRD was opened using C<open()>, then C<$file_name> is optional and if omitted C<$rrd->save()> will save the RRD to the same file as it was read from.

=head2 close
 
 $rrd->close();
 
Close an RRD file accessed using C<open()> or C<save()>.  Calling C<close()> flushes any cached data to disk.

=head2 info
 
 my $info = $rrd->info();
 
Returns a string containing information on the DSs and RRAs in the RRD (but not showing the data values stored in the RRAs).  Also shows details of the file format (C<native-double>, C<portable-double> etc) if the RRD was read from a file.
 
=head2 dump
 
 my $dump = $rrd->dump();
 my $dump = $rrd->dump($arg);
 
Returns a string containing the complete contents of the RRD (including data) in XML format.  C<$arg> is optional. Possible values are "--no-header" or "-n", which remove the XML header from the output string.
 
=head2 fetch
 
 my $vals = $rrd->fetch($args);
 
Returns a string containing a table of measurement data from the RRD.  C<$arg>s is a string that contains the same sort of command line arguments that would be passed to C<rrdtool fetch>.   The format for C<$args> is:
 
 CF [--resolution|-r resolution] [--start|-s start] [--end|-e end] 
 
where C<CF> may be one of AVERAGE, MIN, MAX, LAST.  See L<http://oss.oetiker.ch/rrdtool/doc/rrdfetch.en.html> for further details.

=head2 update
 
 $rrd->update($args);
 
Feeds new data values into the RRD.   C<$args> is a string that contains the same sort of command line arguments that would be passed to C<rrdtool update>.   The format for C<$args> is:

 [--template:-t ds-name[:ds-name]...] N|timestamp:value[:value...] [timestamp:value[:value...] ...]
 
See L<http://oss.oetiker.ch/rrdtool/doc/rrdupdate.en.html> for further details.
 
SinceC<update()> is often called repeatedly, for greater efficiency in-place updating of RRD files is used where possible.  To understand this, a little knowledge of the RRD file format is needed.  RRD files consist of a small header containing details of the DSs and RRA, and a large body containing the data values stored in the RRAs.  Reading the body into memory is relatively costly since it is much larger than the header, and so is only done by RRD::Editor on an "as-needed" basis.  So long as the body has not yet been read into memory when C<update()> is called, C<update()> will update the file on disk i.e. without reading in the body.  In this case there is no need to call C<save()>.   If the body has been loaded into memory when C<update()> is  called, then the copy of the data stored in memory will be updated and the file on disk left untouched - a call to C<save()> is then needed to freshen the file stored on disk.  Seems complicated, but its actually ok in practice.  If all you want to do is efficiently update a file, just use the following formula:
 
 $rrd->open($file_name);
 $rrd->update($args);
 $rrd->close();
 
and that's it.  If you want to do more, then be sure to call C<save()> when you're done.
 
=head2 last
 
 my $unixtime = $rrd->last();
 
Returns the time when the data stored in the RRD was last updated.  The time is returned as a unix timestamp.  This value should not be confused with the last modified time of the RRD file.

=head2 set_last
 
 $rrd->set_last($unixtime);
 
Set the last update time to equal C<$unixtime>.  WARNING: Rarely needed, use with caution !

=head2 lastupdate
 
 my @vals=$rrd->lastupdate();
 
Return a list containing the data-source values inserted at the most recent update to the RRD
 
=head2 minstep
 
 my $minstep = $rrd->minstep();
 
Returns the minimum step size (in seconds) used to store data values in the RRD.  RRA data intervals must be integer multiples of this step size.  The min step size defaults to 300s when creating an RRD (where it is referred to as the "resolution").   NB: Changing the min step size is hard as it would require resampling all of the stored data, so we leave this "to do".

=head2 add_DS
 
 $rrd->add_DS($arg);

Add a new data-source to the RRD.  Only one data-source can be added at a time. Details of the data-source to be added are specified by the string $arg. The format of $arg is:
 
 [DS:ds-name:DST:heartbeat:min:max] 
 
where DST may be one of GAUGE, COUNTER, DERIVE, ABSOLUTE i.e. the same format as used for $rrd->create().

=head2 delete_DS
 
 $rrd->delete_DS($ds-name);

Delete the data-source with name $ds-name from the RRD.   WARNING: This will irreversibly delete all of the data stored for the data-source.
 
=head2 DS_names
 
 my @ds-names = $rrd->DS_names();

Returns a list containing the names of the data-sources in the RRD.

=head2 rename_DS

 $rrd->rename_DS($ds-name, $ds-newname);
 
Change the name of data-source C<$ds-name> to be C<$ds-newname>

=head2 DS_heartbeat
 
 my $hb= $rrd->DS_heartbeat($ds-name);
 
Returns the current heartbeat (in secodns) of a data-source.  The heartbeat is the max number of seconds that may elapse between data measurements before declaring that data is missing.

=head2 set_DS_heartbeat
 
 $rrd->set_DS_heartbeat($ds-name,$hb);

Sets the heartbeat value (in seconds) of data-source C<$ds-name> to be C<$hb>.
 
=head2 DS_type
 
 my $type = $rrd->DS_type($ds-name);
 
Returns the type (GAUGE, COUNTER etc) of a data-source.
 
=head2 set_DS_type

 $rrd->set_DS_type($ds-name, $type);
 
Sets the type of data-source C<$ds-name> to be C<$type>.

=head2 DS_min

 my $min = $rrd->DS_min($ds-name);
 
Returns the minimum allowed for measurements from data-source C<$ds-name>.  Measurements below this value are set equal to $min when stored in the RRD.
 
=head2 set_DS_min
 
 $rrd->set_DS_min($ds-name, $min);
 
Set the minimum value for data-source $ds-name to be $min.
 
=head2 DS_max
 
 my $max = $rrd->DS_max($ds-name);
 
Returns the maximum allowed for measurements from data-source $ds-name.  Measurements above this value are set equal to $max when stored in the RRD.
 
=head2 set_DS_max
 
 $rrd->set_DS_max($ds-name, $max);
 
Set the maximum value for data-source $ds-name to be $max.
 
=head2 add_RRA 
 
 $rrd->add_RRA($arg);

Add a new RRA to the RRD.   Only one RRA can be added at a time. Details of the RRA to be added are specified by the string $arg. The format of $arg is:
 
 [RRA:CF:xff:steps:rows]
 
where CF may be one of AVERAGE, MIN, MAX, LAST i.e. the same format as used for $rrd->create().

=head2 num_RRAs
 
 my $num_RRAs = $rrd->num_RRAs();
 
Returns the number of RRAs stored in the RRD.   Unfortunaely, unlike data-sources, RRAs are not named and so are only identified by an index in the range 0 .. C<num_RRAs()>.  The index of an RRD can be found using C<info()> or C<dump()>.
 
=head2 delete_RRA
 
 $rrd->delete_RRA($rra_idx);
 
Delete the RRA with index C<$rra_idx> (see above discussion for how to determine the index of an RRA). WARNING: This will irreversibly delete all of the data stored in the RRA.

=head2 RRA_numrows

 my $numrows = $rrd->RRA_numrows($rra_idx);
 
Returns the number of rows in the RRA with index C<$rra_idx>.

=head2 resize_RRA

 $rra->resize_RRA($rra_idx, $numrows);
 
Change the number of rows to be C<$numrows> in the RRA with index C<$rra_idx>.   WARNING: If C<$numrows> is smaller than the current row size, excess data points will be discarded.  

=head2 RRA_el

 my ($t,$val) = $rra->RRA_el($rra_idx, $ds-name, $row);
 
Returns the timestamp and the value of data-source $ds-name stored at row C<$row> in the RRA with index C<$rra_idx>.  C<$row> must be in the range [0..C<RRA_numrows($rra_idx)>-1].  Row 0 corresponds to the oldest data point stored and row C<RRA_numrows($rra_idx)>-1 to the most recent data point.

=head2 set_RRA_el

 $rra->set_RRA_el($rra_idx, $ds-name, $row, $val);  
 
Set the stored value equal to C<$val> for data-source $ds-name stored at row C<$row> in the RRA with index C<$rra_idx>.

=head2 RRA_xff

 my $xff = $rra->RRA_xff($rra_idx); 
 
Returns the xff value for the RRA with index C<$rra_idx>.  The xff value defines the proportion of an RRA data interval that may contain UNKNOWN data (i.e. missing data) and still be treated as known.  For example, an xff value 0.5 in an RRA with data interval 300 seconds (5 minutes) means that if less than 150s of valid data is available since the last measurement, UNKNOWN will be stored in the RRA for the next data point.   

=head2 set_RRA_xff

 $rra->RRA_xff($rra_idx,$xff);
 
Sets the xff value to C<$xff> for the RRA with index C<$rra_idx>.
 
=head2 RRA_step
 
 my $step = $rrd->RRA_step($rra_idx);
 
Returns the data interval (in seconds) of the RRA with index C<$rra_idx>.    NB: Changing the step size is hard as it would require resampling the data stored in the RRA, so we leave this "to do".
 
=head2 RRA_type
 
 my $type = $rrd->RRA_type($rra_idx);
 
Returns the type of the RRA with index C<$rra_idx> i.e. AVERAGE, MAX, MIN, LAST etc.  NB: Changing the type of an RRA is hard (impossible ?) as the stored data doesn't contain enough information to allow its type to be changed.  To change type, its recommended instead to delete the RRA and add a new RRA with the desired type.

=head1 EXPORTS
 
You can export the following functions if you do not want to use the object orientated interface:
 
 create
 open
 save
 close
 update
 info
 dump
 fetch
 last 
 set_last
 lastupdate
 minstep
 add_RRA
 delete_RRA
 num_RRAs
 RRA_numrows
 resize_RRA
 RRA_type
 RRA_step
 RRA_xff
 set_RRA_xff
 add_DS
 delete_DS
 DS_names
 rename_DS
 DS_heartbeat
 set_DS_heartbeat
 DS_min
 set_DS_min
 DS_max
 set_DS_max
 DS_type
 set_DS_type

The tag C<all> is available to easily export everything:
 
 use RRD::Editor qw(:all);
 
=head1 Portability/Compatibility with RRDTOOL
 
The RRD::Editor code is portable, and so long as you stick to using the portable-double and portable-single file formats the RRD files generated will also be portable.  Portability issues arise when the C<native-double> file format of RRD::Editor is used to store RRDs.  This format tries to be compatible with the non-portable binary format used by RRDTOOL, which requires RRD::Editor to figure out nasty low-level details of the platform it is running on (byte ordering, byte alignment, representation used for doubles etc).   To date, RRD::Editor and RRDTOOL have been confirmed compatible (i.e. they can read each others RRD files) on the following platforms:

Intel 686 32bit, AMD64/Intel x86 64bit, ARM 32bit (Versatile/PB, little-endian), MIPS 32bit (Malta), PowerPC 32bit
 
If your platform is not listed, there is a good chance things will "just work" but double checking that RRDTOOL can read the C<native-double> format RRD files generated by RRD::Editor, and vice-versa, would be a good idea if that's important to you.
 
=head1 SEE ALSO

L<RRD::Simple>, L<RRDTool::OO>, L<RRDs>,
L<http://www.rrdtool.org>, examples/*.pl,
 
=head1 VERSION
 
Ver 0.01_4
 
=head1 AUTHOR
 
Doug Leith 
 
L<http://www.leith.ie>
   
=head1 BUGS
 
Please report any bugs or feature requests to C<bug-rrd-db at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=RRD-Editor>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.
 
=head1 COPYRIGHT
 
Copyright 2011 D.J.Leith.
 
This program is free software; you can redistribute it and/or modify it under the terms of either: the GNU General Public License as published by the Free Software Foundation; or the Artistic License.
 
See http://dev.perl.org/licenses/ for more information.
 
=cut


__END__
