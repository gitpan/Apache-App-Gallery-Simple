use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'	=> 'Apache::App::Gallery::Simple',
    'VERSION_FROM' => 'Simple.pm',
    'PREREQ_PM'    => { 'Template::Trivial' => 0.06,
			'Image::Magick'     => 5.56 },
);
