#!/usr/bin/perl -w
#
#

use strict;

use Cwd 'abs_path';
use FindBin qw($Bin);
use File::Path;
use File::Spec;
use File::Basename;
use Getopt::Long;

# Get env vars
my ($sysTmpDir, $threads) = @ENV{'TMPDIR', 'NSLOTS'};

if (!$threads) {
    $threads = 1;
}

# Variables with defaults
my $keepDeformedAtlases = 0;
my $labelInterpolationSigma = "0.25mm";
my @rigidSearchParams = (2000, 30, 40);
my $timeProcesses = 0;
my $votingMethod = "Joint[0.1,2]";


my $usage = qq{

  $0
     --input-image
     --atlas-dir
     --output-root
     [options]

  Wrapper script for performing joint label fusion with greedy

  The atlases should be organized in a single directory, with a list atlases.csv of atlases, in the format

    gray1.nii.gz,labels1.nii.gz
    gray2.nii.gz,labels2.nii.gz
    ...


  Required args:

    --input-image
      Head or brain image to be labeled.

    --atlas-dir
      Directory containing atlases and segmentations.

    --output-root
      Root for output images.


  Options:

    --input-mask
      A mask in which labeling is performed. If not provided, JLF is performed in all non-zero voxels.

    --label-interpolation-sigma
      Smoothing sigma to apply to label probabilities during resampling into subject space.
      (default = $labelInterpolationSigma).

    --keep-deformed-atlases
      Retains the deformed atlases and segmentations.

    --rigid-search-params
      Three parameters passed to the search option: number of search points, sigma for rotation (degrees), sigma for
      translation (mm) (default = @rigidSearchParams).

    --registration-mask
      A mask in the input image space for registration, for example a dilation of the brain mask.

    --threads
      Number of threads for computation. Defaults to the NSLOTS variable if defined, otherwise 1.

    --time
      Time the output of each greedy process, useful for performance profiling. Requires the GNU time command
      (default = $timeProcesses).

    --voting-method
      Either "Joint" or "Gauss", optionally with parameters, see usage for joint_fusion (default = "$votingMethod").



  Output:
   The consensus segmentation.

   Requires greedy, label_fusion (if you have ASHS, these will exist under \$ASHS_ROOT/ext/Linux/bin).

};


if ($#ARGV < 0) {
    print $usage;
    exit 1;
}

my $greedyExe = `which greedy`;
my $labelFusionExe = `which label_fusion`;

chomp($greedyExe, $labelFusionExe);

if (!( -f $greedyExe && -f $labelFusionExe )) {
    die("Cannot run without greedy and label_fusion on the PATH\n");
}

my ($inputImage, $atlasDir, $outputRoot, $inputMask, $registrationMask);

GetOptions ("input-image=s" => \$inputImage,
	    "input-mask=s" => \$inputMask,
	    "atlas-dir=s" => \$atlasDir,
	    "output-root=s" => \$outputRoot,
	    "label-interpolation-sigma=s" => \$labelInterpolationSigma,
        "keep-deformed-atlases=i" => \$keepDeformedAtlases,
        "registration-mask=s" => \$registrationMask,
        "rigid-search-params=i{3}" => \@rigidSearchParams,
        "threads=i" => \$threads,
        "time=i" => \$timeProcesses,
        "voting-method=i" => \$votingMethod
    )
    or die("Error in command line arguments\n");

my ($outputFileRoot,$outputDir) = fileparse($outputRoot);

if (! -d $outputDir ) {
    mkpath($outputDir, {verbose => 0}) or die "Cannot create output directory $outputDir\n\t";
}

# Directory for temporary files that is deleted later if $cleanup
my $tmpDir = "";

my $tmpDirBaseName = "${outputFileRoot}greedyJLF";

if ( !($sysTmpDir && -d $sysTmpDir) ) {
    $tmpDir = $outputDir . "/${tmpDirBaseName}";
}
else {
    # Have system tmp dir
    $tmpDir = $sysTmpDir . "/${tmpDirBaseName}";
}

# Gets removed later, so check we can create this and if not, exit immediately
mkpath($tmpDir, {verbose => 0, mode => 0755}) or die "Cannot create working directory $tmpDir (maybe it exists from a previous failed run)\n\t";

# Copy fixed image to tmpDir because it is read repeatedly
my $fixed="${tmpDir}/${outputFileRoot}ImageToLabel.nii.gz";

system("cp $inputImage $fixed");

if (!$inputMask) {
    $inputMask = "${tmpDir}/${outputFileRoot}ImageToLabelMask.nii.gz";
    print("Creating mask from input image\n");
    system("c3d $fixed -thresh 0.001 Inf 1 0 -o $inputMask");
}

# Base command for registration and reslicing
my $greedyBase = "greedy -d 3 -threads $threads";

my $jlfMaskArg = "";

if (-f $inputMask) {
    $jlfMaskArg = "-M $inputMask";
}
else {
    die("Cannot find mask $inputMask\n");
}

my $jlfMethodArg = "-m $votingMethod";

# Base command for joint fusion
my $jlfBase = "label_fusion 3 $jlfMaskArg $jlfMethodArg";

if ($timeProcesses) {
    # Check for time command and modify the base call if needed
    my $timeProg = `which time`;
    chomp($timeProg);

    if (-f $timeProg) {
        $greedyBase = "$timeProg -v $greedyBase";
        $jlfBase = "$timeProg -v $jlfBase";
    }
    else {
        print "  WARNING: Cannot time commands as requested, could not find time program\n";
    }
}

my @atlasGrayImages = ();
my @atlasSegImages = ();

open(my $fh, "<", "${atlasDir}/atlases.csv") or die ("Cannot find required file ${atlasDir}/atlases.csv");

while (my $line = <$fh>) {
    chomp($line);
    my @tokens = split(",", $line);
    push(@atlasGrayImages, $tokens[0]);
    push(@atlasSegImages, $tokens[1]);
}

close($fh);

my @atlasSubjects = map { m/(.*)\.nii\.gz$/; $1 } @atlasGrayImages;

my $searchArg = "-search " . join(" ", @rigidSearchParams);

my $regMaskArg = "";

if ($registrationMask) {
    if (-f $registrationMask) {
        $regMaskArg = "-gm $registrationMask";
    }
    else {
        die("Cannot find registration mask $registrationMask\n");
    }
}


# Array of deformed atlases and labels to be added to JLF command later
# Populated as we deform the images to subject space
my @allMovingDeformed = ();
my @allMovingSegDeformed = ();

for (my $i = 0; $i < scalar(@atlasSubjects); $i++) {
    my $atlasSubj = $atlasSubjects[$i];

    # Warp atlas brains and labels to subject space

    my $moving = "${atlasDir}/$atlasGrayImages[$i]";

    # This is just here to enable leave one out validation
    # Check equality of original input file, not $fixed which we have moved to $tmpDir
    #
    # This is an undocumented feature, user must ensure that ${atlasDir}/${atlasSubj}.nii.gz
    # is exactly equal to the input image; ie can't use relative paths for one and absolute for the
    # other
    if ($moving eq $inputImage) {
	    print " Skipping $atlasSubj because it is the same image as the input \n";
	    next;
    }

    my $movingSeg = "${atlasDir}/$atlasSegImages[$i]";

    print "Registering $atlasSubj \n";

    my $movingDeformed = "${tmpDir}/${atlasSubj}Deformed.nii.gz";
    my $movingSegDeformed = "${tmpDir}/${atlasSubj}SegDeformed.nii.gz";

    my $comTransform = "${tmpDir}/${atlasSubj}ToInputCOM.mat";

    my $regCOMCmd = "$greedyBase -moments 1 -o $comTransform -i $fixed $moving";

    print "\n--- Reg COM Call ---\n$regCOMCmd\n---\n";

    system("$regCOMCmd");

    my $rigidTransform = "${tmpDir}/${atlasSubj}ToInputRigid.mat";

    my $regRigidCmd = "$greedyBase -a -dof 6 -ia $comTransform -o $rigidTransform $searchArg " .
                      "-i $fixed $moving -m NCC 4x4x4 -n 100x50x50x10 $regMaskArg";

    print "\n--- Reg Rigid Call ---\n$regRigidCmd\n---\n";

    system("$regRigidCmd");

    my $affineTransform = "${tmpDir}/${atlasSubj}ToInputAffine.mat";

    my $regAffineCmd = "$greedyBase -a -dof 12 -ia $rigidTransform -o $affineTransform -i $fixed " .
                       "$moving -m NCC 4x4x4 -n 100x50x50x10 $regMaskArg";

    print "\n--- Reg Affine Call ---\n$regAffineCmd\n---\n";

    system("$regAffineCmd");

    my $deformableTransform = "${tmpDir}/${atlasSubj}ToInputWarp.nii.gz";

    # Could also add -sv or -svlb here to regularize more
    my $regDeformableCmd = "$greedyBase -it $affineTransform -o $deformableTransform -i $fixed $moving " .
                           "-m NCC 4x4x4 -n 100x70x50x20 -e 1.0 -wp 0 $regMaskArg";

    print "\n--- Reg Deformable Call ---\n$regDeformableCmd\n---\n";

    system("$regDeformableCmd");

    my $applyTransCmd = "$greedyBase -float -rf $fixed -ri LINEAR -rm $moving $movingDeformed -ri LABEL $labelInterpolationSigma " .
                        "-rm $movingSeg $movingSegDeformed -r $deformableTransform $affineTransform";

    print "\n--- Apply transforms Call ---\n$applyTransCmd\n---\n";

    system("$applyTransCmd");

    if (-f $movingDeformed && -f $movingSegDeformed) {
        push(@allMovingDeformed, $movingDeformed);
        push(@allMovingSegDeformed, $movingSegDeformed);

        if ($keepDeformedAtlases) {
            system("cp $movingDeformed ${outputDir}");
            system("cp $movingSegDeformed ${outputDir}");
        }

    }
}

my $numRegisteredAtlases = scalar(@allMovingDeformed);

if ( $numRegisteredAtlases < (scalar(@atlasSubjects) / 2) ) {
    die "Fewer than half of the atlases registered successfully, will not run JLF \n";
}

print "\nLabeling with " . $numRegisteredAtlases . " atlases\n";

my $jlfCmd="$jlfBase -g " . join(" ", @allMovingDeformed) . " -l " . join(" ", @allMovingSegDeformed) .
           " $fixed ${outputRoot}Labels.nii.gz";

print "\n--- JLF Call ---\n$jlfCmd\n---\n";

system("$jlfCmd");


# Clean up

system("rm -f ${tmpDir}/*");
system("rmdir $tmpDir");
