#!/usr/bin/env perl

=head1 LICENSE

Copyright (c) 2014 Illumina, Inc.

This file is part of Illumina's Enhanced Artificial Genome Engine (EAGLE),
covered by the "BSD 2-Clause License" (see accompanying LICENSE file)

=head1 NAME

generateQualityTable.pl

=head1 DIAGNOSTICS

=head2 Exit status

0: successful completion
1: abnormal completion
2: fatal error

=head2 Errors

All error messages are prefixed with "ERROR: ".

=head2 Warnings

All warning messages generated by EAGLE are prefixed with "WARNING: ".

=head1 CONFIGURATION AND ENVIRONMENT

=back

=head1 BUGS AND LIMITATIONS

There are no known bugs in this module.

All documented features are fully implemented.

Please report problems to Illumina Technical Support (support@illumina.com)

Patches are welcome.

=head1 AUTHOR

Lilian Janin

=cut

use warnings FATAL => 'all';
use strict;
use Cwd qw(abs_path);
use POSIX;
use IO::File;
use Carp;

use Pod::Usage;
use Getopt::Long;


my $VERSION = '@EAGLE_VERSION_FULL@';

my $programName = (File::Spec->splitpath(abs_path($0)))[2];
my $programPath = (File::Spec->splitpath(abs_path($0)))[1];
my $Version_text =
    "$programName $VERSION\n"
  . "Copyright (c) 2014 Illumina, Inc.\n";

my $usage =
    "Usage: $programName [options]\n"
  . "\t-l, --laneDir=PATH           - lane directory in Run Folder\n"
  . "\t-t, --tile=filename          - tile BCL file\n"
  . "\t-o, --output=PATH            - output quality table file\n"
  . "\t-i, --ignore-reads-with-homopolymers-longer-than=INT - as it says\n"

  . "\t--help                       - prints usage guide\n"
  . "\t--version                    - prints version information\n"

.<<'EXAMPLES_END';

EXAMPLES:
    (none)

EXAMPLES_END

my $help             = 'nohelp';
my $isVersion        = 0;
my %PARAMS           = ();

my $argvStr = join ' ', @ARGV;

$PARAMS{verbose} = 0;

$PARAMS{laneDir} = "";
$PARAMS{tile} = "";
$PARAMS{output} = "";
my $ignoreReadsWithHomopolymersLongerThan = 0;

my $result = GetOptions(
    "laneDir|l=s"           => \$PARAMS{laneDir},
    "tile|t=s"              => \$PARAMS{tile},
    "output|o=s"            => \$PARAMS{output},
    "ignore-reads-with-homopolymers-longer-than|i=i" => \$ignoreReadsWithHomopolymersLongerThan,

    "version"               => \$isVersion,
    "help"                  => \$help
);

# display the version info
if ($isVersion) {
    print $Version_text;
    exit(0);
}

# display the help text when no output directory or other required options are given
if ( ( $result == 0 || !$PARAMS{laneDir} || !$PARAMS{tile} || !$PARAMS{output} ) && 'nohelp' eq $help) {
    die "$usage";
}

die("ERROR: Unrecognized command-line argument(s): @ARGV")  if (0 < @ARGV);


my $myInt32 = "";
my $myInt8 = "";


# Check that we won't overwrite any existing file
(! -e "$PARAMS{output}") or die "$PARAMS{output} already exist in the curent directory. Aborting.";

# Count how many cycles are available
print STDERR "Counting cycles";
my $cycleCount = 1;
while (-e "$PARAMS{laneDir}/C${cycleCount}.1/$PARAMS{tile}.bcl" || -e "$PARAMS{laneDir}/C${cycleCount}.1/$PARAMS{tile}.bcl.gz") {$cycleCount++; print STDERR "."; }
$cycleCount--;
print STDERR "\n";
print "Found ${cycleCount} cycles\n";

# Create array of BCL files
my @bclFiles;
my $readCount = -1;
push @bclFiles, 0; # fake value, as cycle 0 doesn't exist
for (my $cycle=1; $cycle<=$cycleCount; $cycle++) {
  my $file;
  my $filename = "$PARAMS{laneDir}/C${cycle}.1/$PARAMS{tile}.bcl";
  if (!open( $file, "<", "$filename" )) {
    open( $file, "gunzip -c $filename.gz |" )
      or die "Cannot open $filename";
  }
  binmode $file;
  push @bclFiles, $file;

  if (read ($file, $myInt32, 4)) {
    my $a = unpack('L',$myInt32);
    if ($readCount == -1) {
      $readCount = $a;
    }
    elsif ($readCount != $a) {
      die "Wrong read count in $filename: $a != $readCount";
    }
  }
}
print "Number of reads=$readCount\n";

# Open filter file
my $filterFile;
my $filterFilename = "$PARAMS{laneDir}/$PARAMS{tile}.filter";
open( $filterFile, "<", "$filterFilename" ) or die "Cannot open $filterFilename";
binmode $filterFile;
read ($filterFile, $myInt32, 4) or die "Problem reading filter file";
read ($filterFile, $myInt32, 4) or die "Problem reading filter file";
my $a = unpack('L',$myInt32);
($a == 3) or die "This tool only supports filter files version 3. This one is version $a";
read ($filterFile, $myInt32, 4) or die "Problem reading filter file";
$a = unpack('L',$myInt32);
if ($readCount != $a) {
  die "Wrong read count in filter file $filterFilename: $a != $readCount";
}


open OUTF, ">$PARAMS{output}" or die "Can't open $PARAMS{output} for writing";

my %stats;
my %statsNotPF;
my $lastPercent = 0;
my @qualitiesForRead;

loopOverReads: for (my $readNum=0; $readNum<$readCount; $readNum++) {
#  my $lastQ = 0;
  my $qSum = 0;
  read ($filterFile, $myInt8, 1) or die "Error reading filter entry for read $readNum";
  my $PFvalue = unpack('C',$myInt8);
  my $previousBase = -1;
  my $homopolymerLength = 0;
  for (my $cycle=1; $cycle<=$cycleCount; $cycle++) {
    read ($bclFiles[$cycle], $myInt8, 1) or die "Error reading cycle $cycle";
    my $bclBase = unpack('C',$myInt8);
    my $qual = $bclBase >> 2;
    $qualitiesForRead[$cycle] = $qual;
    $qSum += $qual;

    if ($ignoreReadsWithHomopolymersLongerThan) {
      my $base = $bclBase & 3;
      if ($base == $previousBase && $qual > 0) {
        $homopolymerLength++;
        if ($homopolymerLength > $ignoreReadsWithHomopolymersLongerThan) {
          next loopOverReads;
        }
      }
      else {
        $homopolymerLength = 1;
      }
      $previousBase = $base;
    }
  }
  my $averageQ = floor( $qSum/$cycleCount + 0.5 );
  if ($PFvalue == 1) {
    $stats{1}{0}{$averageQ}++;
  }
  else {
    $statsNotPF{1}{0}{$averageQ}++;
  }
  for (my $cycle=1; $cycle<=$cycleCount; $cycle++) {
    my $qual = $qualitiesForRead[$cycle];
    if ($PFvalue == 1) {
#    print "cycle=$cycle\tlastQ=$lastQ\tnewQ=$qual\tqSum=$qSum\taverageQ=$averageQ\n";
      $stats{$cycle}{$averageQ}{$qual}++;
    }
    else {
      $statsNotPF{$cycle}{$averageQ}{$qual}++;
    }
#    print OUTF "cycle=$cycle\tlastQ=$lastQ\tnewQ=$qual\n";
#    $lastQ = $qual;
  }
  if ($lastPercent < int($readNum*1000/$readCount)/10) {
    $lastPercent = int($readNum*1000/$readCount)/10;
    print "${lastPercent}%\n";
  }
}

# Print results
print OUTF "# cycle\tlastQ\tnewQ\tcount\n";
for (my $cycle=1; $cycle<=$cycleCount; $cycle++) {
  if (defined $stats{$cycle}) {
    for (my $i=0; $i<=40; $i++) {
      if (defined $stats{$cycle}{$i}) {
        for (my $j=0; $j<=40; $j++) {
          if (defined $stats{$cycle}{$i}{$j}) {
            print OUTF "$cycle\t$i\t$j\t" . $stats{$cycle}{$i}{$j} . "\n"
          }
        }
      }
    }
  }
}

close OUTF;


# Print results using format 2 (table)
open OUTF2, ">$PARAMS{output}.format2" or die "Can't open $PARAMS{output}.format2 for writing";
print OUTF2 "# cycle\tlastQ\tcount of newQ=0\tcount of newQ=1\t...\tcount of newQ=40\n";
for (my $cycle=1; $cycle<=$cycleCount; $cycle++) {
  for (my $i=0; $i<=40; $i++) {
    print OUTF2 "$cycle\t$i";
    my $sum = 0;
    if (defined $stats{$cycle} && defined $stats{$cycle}{$i}) {
      for (my $j=0; $j<=40; $j++) {
        if (defined $stats{$cycle}{$i}{$j}) {
          $sum += $stats{$cycle}{$i}{$j};
        }
      }
    }
    if ($sum != 0) {
      for (my $j=0; $j<=40; $j++) {
        if (defined $stats{$cycle}{$i}{$j}) {
          print OUTF2 "\t" . $stats{$cycle}{$i}{$j};
        }
        else {
          print OUTF2 "\t0";
        }
      }
    }
    print OUTF2 "\n";
  }
}
close OUTF2;

# Print results using format 3 (normalised table)
open OUTF3, ">$PARAMS{output}.format3" or die "Can't open $PARAMS{output}.format3 for writing";
print OUTF3 "# cycle\tlastQ\tcount of newQ=0\tcount of newQ=1\t...\tcount of newQ=40\n";
for (my $cycle=1; $cycle<=$cycleCount; $cycle++) {
  for (my $i=0; $i<=40; $i++) {
    print OUTF3 "$cycle\t$i";
    my $sum = 0;
    for (my $j=0; $j<=40; $j++) {
      if (defined $stats{$cycle} && defined $stats{$cycle}{$i} && defined $stats{$cycle}{$i}{$j}) {
        $sum += $stats{$cycle}{$i}{$j};
      }
    }
    for (my $j=0; $j<=40; $j++) {
      if (defined $stats{$cycle} && defined $stats{$cycle}{$i} && defined $stats{$cycle}{$i}{$j}) {
        print OUTF3 "\t" . ($stats{$cycle}{$i}{$j} / $sum);
      }
      else {
        print OUTF3 "\t0";
      }
    }
    print OUTF3 "\n";
  }
}
close OUTF3;

# Print results using format 2 (table) for not-PF reads
open OUTF2, ">$PARAMS{output}.notPF.format2" or die "Can't open $PARAMS{output}.notPF.format2 for writing";
print OUTF2 "# cycle\tlastQ\tcount of newQ=0\tcount of newQ=1\t...\tcount of newQ=40\n";
for (my $cycle=1; $cycle<=$cycleCount; $cycle++) {
  for (my $i=0; $i<=40; $i++) {
    print OUTF2 "$cycle\t$i";
    for (my $j=0; $j<=40; $j++) {
      if (defined $statsNotPF{$cycle} && defined $statsNotPF{$cycle}{$i} && defined $statsNotPF{$cycle}{$i}{$j}) {
        print OUTF2 "\t" . $statsNotPF{$cycle}{$i}{$j};
      }
      else {
        print OUTF2 "\t0";
      }
    }
    print OUTF2 "\n";
  }
}
close OUTF2;

print "Done. If you wish to split a format2 table, use an awk script such as awk 'BEGIN { OFS=\"\\t\" } { if (\$1 > 101) { \$1-=101; print \$0 } }'\n";
