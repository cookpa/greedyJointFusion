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
my ($sysTmpDir, $threads) = $ENV{'TMPDIR', 'NSLOTS'};

if (!$threads) {
    $threads = 1;
}

# Variables with defaults
my $keepDeformedAtlases = 0;
my $labelInterpolationSigma = "0.25mm";
my $timeProcesses = 0;
my $votingMethod = "Joint";


my $usage = qq{

  $0 
     --input-image
     --input-mask
     --atlas-dir
     --output-root
     [options]

  Wrapper script for performing joint label fusion with greedy

  The atlases should be organized in a single directory containing for each atlas:
  
    atlas.nii.gz
    atlas_Seg.nii.gz


  Required args:

    --input-image
      Head or brain image to be labeled. 

    --atlas-dir
      Directory containing atlases and segmentations.

    --output-root
      Root for output images.


  Options:

    --input-mask
      A mask in which labeling is performed. If not provided, JLF is performed in all voxels where the 
      atlases are not unanimous. 

    --jlf-method
      Either "Joint" or "Gauss", optionally with parameters, see usage for joint_fusion (default = $votingMethod).

    --label-interpolation-sigma
      Smoothing sigma to apply to label probabilities during resampling into subject space. 
      (default = $labelInterpolationSigma).

    --keep-deformed-atlases
      Retains the deformed atlases and segmentations.

    --rigid-search-params 
      Three parameters passed to the search option: number of search points, sigma for rotation (degrees), sigma for 
      translation (mm).

    --registration-mask
      A mask in the input image space for registration, for example a dilation of the brain mask.

    --threads
      Number of threads for computation. Defaults to the NSLOTS variable if defined, otherwise 1 (default = $threads).

    --time 
      Time the output of each greedy process, useful for performance profiling. Requires the GNU time command
      to be on the PATH (default = $timeProcesses).

  Output:
   The consensus segmentation.
    
  Requires greedy, label_fusion

};


if ($#ARGV < 0) {
    print $usage;
    exit 1;
}

my $greedyExe = `which greedy`;
my $labelFusionExe = `which label_fusion`;

if (!( -f $greedyExe && -f $labelFusionExe )) {
    die("Cannot run without greedy and label_fusion on the PATH\n");
}

my ($inputImage, $templateToSubjectWarpString, $atlasDir, $outputRoot);

GetOptions ("input-image=s" => \$inputImage,
	    "input-mask=s" => \$inputMask,  
	    "atlas-dir=s" => \$atlasDir,
	    "output-root=s" => \$outputRoot,
	    "label-interpolation-sigma=s" => \$labelInterpolationSigma,
	    "jlf-method=i" => \$jlfMethod,
            "keep-deformed-atlases=i" => \$keepDeformedAtlases,
            "rigid-search-params=i{3}" => \@rigidSearchParams,
            "threads=i" => $threads,
            "time=i" => $timeProcesses

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

# These exist in the tmp dir because they are read several times
my $fixed="${tmpDir}/${outputFileRoot}ImageToLabel.nii.gz";
my $fixedMask = "${tmpDir}/${outputFileRoot}Mask.nii.gz";

my $inputMask = "";

system("cp $inputImage $fixed");

if (-f $inputMask) {
    system("cp $inputMask $fixedMask");
}

# Assume atlases of the form ${id}.nii.gz ${id}_seg.nii.gz

my @atlasSegImages = glob("${atlasDir}/*_Seg.nii.gz");

my @atlasSubjects = map { m/${atlasDir}\/?(.*)_Seg\.nii\.gz$/; $1 } @atlasSegImages;


# Array of deformed atlases and labels to be added to JLF command later
# Populated as we deform the images to subject space
my @allMovingDeformed = ();
my @allMovingSegDeformed = ();

my $greedyBase = "$time greedy -d 3 -threads $threads";

foreach my $atlasSubj (@atlasSubjects) {

    # Warp atlas brains and labels to subject space

    my $moving = "${atlasDir}/${atlasSubj}.nii.gz";

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

    my $movingSeg = "${atlasDir}/${atlasSubj}_Seg.nii.gz";
    
    print " Registering $atlasSubj \n";

    my $movingDeformed = "${tmpDir}/${atlasSubj}ToInputDeformed.nii.gz";
    my $movingSegDeformed = "${tmpDir}/${atlasSubj}ToInputSegDeformed.nii.gz";
    
  	    my $comTransform = "${tmpDir}/${subject}To${subjToLabel}COM.mat";
	    
	    my $regCOMCmd = "$greedyBase -moments 1 -o $comTransform -i $fixed $moving";
	    
	    print "\n--- Reg COM Call ---\n$regCOMCmd\n---\n";
	    
	    system("$regCOMCmd");
	    
	    my $rigidTransform = "${tmpDir}/${subject}To${subjToLabel}Rigid.mat";
	    
	    my $regRigidCmd = "$greedyBase -a -dof 6 -ia $comTransform -o $rigidTransform -i $fixed $moving -m NCC 4x4x4 -n 100x50x50x10 -gm $regMask";
	    
	    print "\n--- Reg Rigid Call ---\n$regRigidCmd\n---\n";
	    
	    system("$regRigidCmd");
	    
	    my $affineTransform = "${tmpDir}/${subject}To${subjToLabel}Affine.mat";
	    
	    my $regAffineCmd = "$greedyBase -a -dof 12 -ia $rigidTransform -o $affineTransform -i $fixed $moving -m NCC 4x4x4 -n 100x50x50x10 -gm $regMask";
	    
	    print "\n--- Reg Affine Call ---\n$regAffineCmd\n---\n";
	    
	    system("$regAffineCmd");
	    
	    my $deformableTransform = "${tmpDir}/${subject}To${subjToLabel}Warp.nii.gz";
	    
	    my $regDeformableCmd = "$greedyBase -it $affineTransform -o $deformableTransform -i $fixed $moving -m NCC 4x4x4 -n 100x70x50x20 -e 1.0 -wp 0 -gm $regMask";

	    print "\n--- Reg Deformable Call ---\n$regDeformableCmd\n---\n";
	    
	    system("$regDeformableCmd");
	    
	    my $applyTransCmd = "$greedyBase -float -rf $fixed -ri LINEAR -rm $moving $movingDeformed -ri LABEL 0.2vox -rm $movingSeg $movingSegDeformed -r $deformableTransform $affineTransform";
	    
	    print "\n--- Apply transforms Call ---\n$applyTransCmd\n---\n";
	    
	    system("$applyTransCmd");

	
	push(@allMovingDeformed, $movingDeformed);
	push(@allMovingSegDeformed, $movingSegDeformed);
    }	


}

print "\n  Labeling with " . scalar(@grayImagesSubjSpace) . " atlases \n";

if ($outputJLF) {
    
    my $majorityLabels = "${tmpDir}/${outputFileRoot}MajorityLabels.nii.gz";
    my $jlfMask = "${tmpDir}/${outputFileRoot}MajorityLabels_Mask.nii.gz";

    # ImageMath call creates ${outputFileRoot}MajorityLabels.nii.gz and ${outputFileRoot}MajorityLabels_Mask.nii.gz, where 
    # the mask is voxels where we need to do JLF - but these may include voxels outside of the user supplied brain mask.
    #
    system("${antsPath}ImageMath 3 $majorityLabels MajorityVoting $jlfMajorityThresh " . join(" ", @segImagesSubjSpace));
    
    # Mask these in turn by user supplied input mask
    system("${antsPath}ImageMath 3 $majorityLabels m $refMask $majorityLabels");
    system("${antsPath}ImageMath 3 $jlfMask m $refMask $jlfMask");
    
    print "Running antsJointFusion \n";
    
    my $jlfResult = "${tmpDir}/${outputFileRoot}PGJLF.nii.gz";

    my $cmd = "${antsPath}antsJointFusion -d 3 -v 1 -t $refImage -x $jlfMask -g " . join(" -g ",  @grayImagesSubjSpace) . " -l " . join(" -l ",  @segImagesSubjSpace) . " -o $jlfResult ";
    
    print "\n$cmd\n";
    
    system($cmd);
    
    # Now integrate JLF result with majority labels
    system("${antsPath}ImageMath 3 ${outputDir}/${outputFileRoot}PGJLF.nii.gz max $jlfResult $majorityLabels");
}

# Copy input to output for easy evaluation
system("cp $refImage ${outputDir}/${outputFileRoot}Brain.nii.gz");


# Clean up

system("rm -f ${tmpDir}/*");
system("rmdir $tmpDir");
