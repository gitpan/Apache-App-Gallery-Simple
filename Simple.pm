package Apache::App::Gallery::Simple;
use strict;

## This is a simple mod_perl gallery application inspired by Apache::Album
## by James D. Woodgate; additional inspiration courtesy _Writing Apache
## Modules with Perl and C_ by Lincoln Stein and Doug MacEachern

use Apache::Constants qw(DECLINED OK SERVER_ERROR REDIRECT);
use Image::Magick;
use Template::Trivial;
use File::Spec;

use vars qw($VERSION);
$VERSION = '1.02';

use vars qw($DEBUG);
$DEBUG   = 0;

use vars qw(%CONFIG);
%CONFIG  = ();

use vars qw(@LANG);
@LANG    = ();

use constant CAP_LINK => 0;
use constant CAP_TEXT => 1;

sub handler {
    my $r = shift;

    %CONFIG = set_defaults($r);

    ## make sure gallery root exists
    unless( $CONFIG{'gallery_root'} ) {
	$r->log_error("No GalleryRoot configured");
	return SERVER_ERROR;
    }

    $CONFIG{'gallery_path'} = path($r->document_root, $CONFIG{'gallery_root'});

    my $loc  = $r->location;
    my $uri  = $r->uri; $uri =~ s/^$loc/$CONFIG{'gallery_root'}/;
    my $subr = $r->lookup_file($uri);           ## final URI

    my %lang = ();
    @LANG = grep { ! $lang{$_}++ } 
      map { $_ eq $CONFIG{'gallery_lang'} ? '' : $_ } 
	grep { $_ } map { $_, /^([^-]+)/ } 
	  map { /^([^;]+)/ }
	    map { lc($_) }
	      split(',', ( $r->header_in('Accept-Language') 
			   ? $r->header_in('Accept-Language') 
			   : $CONFIG{'gallery_lang'} ));
    $DEBUG=0;
    $r->log_error("Accept-Language: @LANG") if $DEBUG;
    $DEBUG=0;

    if( $DEBUG ) {
	$r->log_error("r->location:        " . $r->location());
	$r->log_error("r->filename:        " . $r->filename());
	$r->log_error("r->uri:             " . $r->uri());
	$r->log_error("r->path_info:       " . $r->path_info());
	$r->log_error("\$uri:               " . $uri);
	$r->log_error("r->lookup_uri(uri): " . $subr->filename);
    }

    if( -d $subr->finfo() ) {
	$r->log_error( "found a directory at $uri" )
	  if $DEBUG;

	## show this directory
	return show_gallery($r, $subr->filename);
    }

    elsif( -f _ ) {
	$r->log_error( "found a regular file at $uri" )
	  if $DEBUG;

	## pass non-images through
	unless( $subr->content_type =~ m!^image/! ) {
	    $r->log_error("Pass through content ($uri)")
	      if $DEBUG;
	    return $subr->run;  ## FIXME: Apache book says we could do
                                ## internal redirect here for efficiency
	}

	return show_file($r, $subr->filename);
    }

    else {
	$r->log_error("File or directory not found: " . $r->uri);
	return DECLINED;
    }
}

sub set_defaults {
    my $r      = shift;
    my %config = ();

    ## set defaults
    $config{'gallery_root'}  = 
      $r->dir_config('GalleryRoot')  ||
	'';
    $config{'gallery_name'}  =
      $r->dir_config('GalleryName')  ||
	'';
    $config{'gallery_lang'}  =
      $r->dir_config('GalleryLang')  ||
	'en';
    $config{'thumb_use'}     =
      $r->dir_config('ThumbUse')     ||
	'width';
    $config{'thumb_width'}   =
      $r->dir_config('ThumbWidth')   ||
	100;
    $config{'thumb_height'}  =
      $r->dir_config('ThumbHeight')  ||
	100;
    $config{'thumb_aspect'}  = 
      $r->dir_config('ThumbAspect')  ||
	'1/5';
    $config{'thumb_dir'}     =
      $r->dir_config('ThumbDir')     ||
	'.thumbs';
    $config{'thumb_prefix'}  =
      $r->dir_config('ThumbPrefix')  ||
	'tn__';
    $config{'thumb_columns'} = 
      $r->dir_config('ThumbColumns') ||
	0;
    $config{'browser_width'} =
      $r->dir_config('BrowserWidth') ||
	640;
    $config{'breadcrumb_home'} =
      $r->dir_config('BreadcrumbHome') ||
	'no';
    $config{'caption_file'}  =
      $r->dir_config('CaptionFile')  ||
	'caption.txt';
    $config{'template_dir'}  =
      $r->dir_config('TemplateDir')  ||
	'.templates';
#    $config{'thumb_caption'} =
#      $r->dir_config('ThumbCaption') ||
#	'no';

    ## cleanup configuration directives
    $config{'thumb_use'} = lc($config{'thumb_use'});
    unless( $config{'thumb_aspect'} =~ m!^[\d/\.]+$! ) {
	$r->log_error("Illegal character in ThumbAspect: only digits, slashes, and decimal points allowed.");
	return SERVER_ERROR;
    }
    $config{'thumb_dir'} =~ s!/+$!!;
    if( $config{'thumb_dir'} =~ m!/! ) {
	$r->log_error("No paths allowed in 'ThumbDir': must be a directory name relative to the current gallery.");
	return SERVER_ERROR;
    }
#    $config{'thumb_caption'} = lc($config{'thumb_caption'});
    if( $config{'thumb_prefix'} =~ m!/! ) {
	$r->log_error("No paths allowed in ThumbPrefix: must be a string with no path separators.");
	return SERVER_ERROR;
    }
    if( $config{'caption_file'} =~ m!/! ) {
	$r->log_error("No paths allowed in 'CaptionFile': must be a file name relative to the current gallery.");
	return SERVER_ERROR;
    }
    $config{'template_dir'} =~ s!/+$!!;
    if( $config{'template_dir'} =~ m!/! ) {
	$r->log_error("No paths allowed in 'TemplateDir': must be a directory name relative to the GalleryRoot");
	return SERVER_ERROR;
    }

    return %config;
}


sub show_gallery {
    my $r    = shift;
    my ($path, $dir) = shift =~ m!^(.*)/([^/]+)$!;

    ## need to redirect?
    unless( $r->uri =~ m!/$! ) {
	$r->warn( "redirecting to " . $r->uri . '/' );
	$r->header_out( Location => $r->uri . '/' );
	return REDIRECT;
    }

    $r->content_type('text/html');
    $r->send_http_header;

    ## setup templates
    my $tmpl = new Template::Trivial;
    $tmpl->define_from_string(main => <<_EOF_,
<html>
<head>
<title>Photo Gallery: {GALLERY_NAME}</title>
<style type="text/css">
<!--
  body {
    font-family: Helvetica, sans-serif, Arial;
    font-size: large;
    color: #F4F4F4;
    background: none;
    margin: 20px;
  }
  p {
    margin: 15px;
  }
  td {
    text-align: center;
    vertical-align: top;
  }
  a {
    color: #BD9977;
    background: none;
    font-size: x-small;
    text-decoration: none;
  }
  img {
    border: 0
  }
  .breadcrumb {
    font-size: x-small;
    background: none;
    color: #000000;
  }
  .address {
    text-align: right;
    font-size: xx-small;
  }
//-->
</style>
</head>

<body>
{GALLERY_TITLE}
<p class="breadcrumb">This gallery: {BREADCRUMBS}</p>
{OTHER_GALLERIES}
<center>
<table width="400">
<tr>
<td width="25%">{DIR_FIRST}</td><td width="25%">{DIR_PREV}</td>
<td width="25%">{DIR_NEXT}</a><td width="25%">{DIR_LAST}</td>
</tr>
</table>

{GALLERY}
</center>
<hr>
<div class="address">
  <a href="http://scott.wiersdorf.org/perl/">Apache::App::Gallery::Simple</a>
</div>
</body>
</html>
_EOF_
			      gallery_title    => q!!, ## was '<h2>{GALLERY_NAME}</h2>'
			      gallery_title_empty => '',
			      other_galleries  => <<_EOF_,
<p class="breadcrumb">Other galleries within this gallery:<br>
{DIRECTORIES}</p>
_EOF_
			      other_empty      => <<_EOF_,
<p class="breadcrumb">(No other galleries within this gallery)</p>
_EOF_
			      breadcrumb       => q!&nbsp;<a href="{BREADCRUMBLINK}">{BREADCRUMB}</a>&nbsp;-&gt;!,
			      deadcrumb        => q!&nbsp;{BREADCRUMB}!,
			      homecrumb        => q!home!,

			      first            => q!<a href="{FIRST_LINK}">{FIRST_DEFAULT}</a>!,
			      first_empty      => '',
			      first_default    => q!First<br>Gallery!,
			      first_caption    => q!<br>({CAPTION})!,
			      previous         => q!<a href="{PREV_LINK}">{PREV_DEFAULT}{PREV}</a>!,
			      previous_empty   => '',
			      previous_default => q!Previous<br>Gallery!,
			      previous_caption => q!<br>({CAPTION})!,
			      next             => q!<a href="{NEXT_LINK}">{NEXT_DEFAULT}{NEXT}</a>!,
			      next_empty       => '',
			      next_default     => q!Next<br>Gallery!,
			      next_caption     => q!<br>({CAPTION})!,
			      last             => q!<a href="{LAST_LINK}">{LAST_DEFAULT}</a>!,
			      last_empty       => '',
			      last_default     => q!Last<br>Gallery!,
			      last_caption     => q!<br>({CAPTION})!,

			      dir_link         => qq!<a href="{URI_DIR}">{DIRECTORY}</a><br>\n!,
			      dir_caption      => q!&nbsp;({CAPTION})!, ## not used currently
			      gallery_table    => q!<table>{ROWS}</table>!,
			      gallery_empty    => q!<table><tr><td>(No photos in this gallery)</td></tr></table>!,
			      table_row_top    => q!<tr>!,
			      table_row_middle => q!{ROW_END}{ROW_START}!,
			      table_row_bottom => q!</tr>!,
			      table_cell       => <<_EOF_,
<td align="center"><a href="{URI_IMAGE}"><img src="{URI_THUMB}" border="0"></a></td>
_EOF_
			     );

  TEMPLATE_DIR: for my $tmpl_dir 
      ( grep { -d }
	map { path($CONFIG{'gallery_path'}, ( $_ 
					      ? $CONFIG{'template_dir'} . ".$_" 
					      : $CONFIG{'template_dir'} ) ) }
	reverse @LANG ) {

	  warn "Reading gallery templates from '$tmpl_dir'\n" if $DEBUG;

	  ## process template customizations, if any
	  $tmpl->templates($tmpl_dir);
	  $tmpl->define(main             => "gallery_main.txt")
	    if -f path($tmpl_dir, "gallery_main.txt");
	  $tmpl->define(gallery_title    => "gallery_title.txt")
	    if -f path($tmpl_dir, "gallery_title.txt");
	  $tmpl->define(gallery_title_empty => "gallery_title_empty.txt")
	    if -f path($tmpl_dir, "gallery_title_empty.txt");
	  $tmpl->define(other_galleries  => "gallery_other.txt")
	    if -f path($tmpl_dir, "gallery_other.txt");
	  $tmpl->define(other_empty      => "gallery_other_empty.txt")
	    if -f path($tmpl_dir, "gallery_other_empty.txt");
	  $tmpl->define(breadcrumb       => "gallery_breadcrumb.txt")
	    if -f path($tmpl_dir, "gallery_breadcrumb.txt");
	  $tmpl->define(deadcrumb        => "gallery_deadcrumb.txt")
	    if -f path($tmpl_dir, "gallery_deadcrumb.txt");
	  $tmpl->define(homecrumb        => "gallery_homecrumb.txt")
	    if -f path($tmpl_dir, "gallery_homecrumb.txt");

	  ## navigation links
	  $tmpl->define(first            => "gallery_first.txt")
	    if -f path($tmpl_dir, "gallery_first.txt");
	  $tmpl->define(first_empty      => "gallery_first_empty.txt")
	    if -f path($tmpl_dir, "gallery_first_empty.txt");
	  $tmpl->define(first_default    => "gallery_first_default.txt")
	    if -f path($tmpl_dir, "gallery_first_default.txt");
	  $tmpl->define(first_caption    => "gallery_first_caption.txt")
	    if -f path($tmpl_dir, "gallery_first_caption.txt");
	  $tmpl->define(previous         => "gallery_previous.txt")
	    if -f path($tmpl_dir, "gallery_previous.txt");
	  $tmpl->define(previous_empty   => "gallery_previous_empty.txt")
	    if -f path($tmpl_dir, "gallery_previous_empty.txt");
	  $tmpl->define(previous_default => "gallery_previous_default.txt")
	    if -f path($tmpl_dir, "gallery_previous_default.txt");
	  $tmpl->define(previous_caption => "gallery_previous_caption.txt")
	    if -f path($tmpl_dir, "gallery_previous_caption.txt");
	  $tmpl->define(next             => "gallery_next.txt")
	    if -f path($tmpl_dir, "gallery_next.txt");
	  $tmpl->define(next_empty       => "gallery_next_empty.txt")
	    if -f path($tmpl_dir, "gallery_next_empty.txt");
	  $tmpl->define(next_default     => "gallery_next_default.txt")
	    if -f path($tmpl_dir, "gallery_next_default.txt");
	  $tmpl->define(next_caption     => "gallery_next_caption.txt")
	    if -f path($tmpl_dir, "gallery_next_caption.txt");
	  $tmpl->define(last             => "gallery_last.txt")
	    if -f path($tmpl_dir, "gallery_last.txt");
	  $tmpl->define(last_empty       => "gallery_last_empty.txt")
	    if -f path($tmpl_dir, "gallery_last_empty.txt");
	  $tmpl->define(last_default     => "gallery_last_default.txt")
	    if -f path($tmpl_dir, "gallery_last_default.txt");
	  $tmpl->define(last_caption     => "gallery_last_caption.txt")
	    if -f path($tmpl_dir, "gallery_last_caption.txt");

	  $tmpl->define(dir_link         => "gallery_dir_link.txt")
	    if -f path($tmpl_dir, "gallery_dir_link.txt");
	  $tmpl->define(dir_caption      => "gallery_dir_caption.txt")
	    if -f path($tmpl_dir, "gallery_dir_caption.txt");
	  $tmpl->define(gallery_table    => "gallery_table")
	    if -f path($tmpl_dir, "gallery_table");
	  $tmpl->define(gallery_empty    => "gallery_empty")
	    if -f path($tmpl_dir, "gallery_empty");

	  $tmpl->define(table_row_top    => "gallery_row_top")
	    if -f path($tmpl_dir, "gallery_row_top.txt");
	  $tmpl->define(table_row_middle => "gallery_row_middle")
	    if -f path($tmpl_dir, "gallery_row_middle.txt");
	  $tmpl->define(table_row_bottom => "gallery_row_bottom")
	    if -f path($tmpl_dir, "gallery_row_bottom.txt");
	  $tmpl->define(table_cell       => "gallery_cell")
	    if -f path($tmpl_dir, "gallery_cell.txt");
      }

    my $gallery_name = get_captions($path, $dir);
    $tmpl->assign( GALLERY_NAME    => ($gallery_name ? $gallery_name : $r->uri));
    $tmpl->parse(  GALLERY_TITLE   => ( $gallery_name ? 'gallery_title' : 'gallery_title_empty' ));
    $tmpl->parse(  ROW_START       => 'table_row_top');
    $tmpl->parse(  ROW_END         => 'table_row_bottom');
    $tmpl->parse(  ROWS            => 'table_row_top');

  DO_BREADCRUMBS: {
	my $location = $r->location();
	my($alias)   = $r->uri; $alias =~ s/^$location//;
	my @breadcrumbs = ($location, grep { $_ } split('/', $alias));

	if( $DEBUG ) {
	    warn "##############################################################\n";
	    warn "URI:            " . $r->uri   . "\n";
	    warn "LOCATION:       " . $location . "\n";
	    warn "ALIAS:          " . $alias    . "\n";
	    warn "################\n";
	}

	my $lastcrumb = pop @breadcrumbs;  ## save for after the loop
	my $breadcrumblink = '';
	$DEBUG=0;
	for my $crumb ( @breadcrumbs ) {
	    warn "CRUMB:          $crumb\n" if $DEBUG;
	    $breadcrumblink .= $crumb . ($crumb =~ m!/$! ? '' : '/');
	    my ($breadpath) = $breadcrumblink =~ m!^$location(.*)!;
	    warn "BREADPATH:      $breadpath\n" if $DEBUG;

	    my $fullpath = path($CONFIG{'gallery_path'}, $breadpath);

	    my ($g_path, $g_dir) = $fullpath =~ m!^(.*/)([^/]+)$!; ## split fullpath into components
	    my $g_name = get_captions($g_path, $g_dir);  ## get comment for this directory
	    warn "BREADCRUMBLINK: $breadcrumblink\n" if $DEBUG;
	    warn "FULLPATH:       $fullpath\n" if $DEBUG;
	    if( $crumb eq '/' ) { $tmpl->parse(  BREADCRUMB => 'homecrumb') }
	    else                { $tmpl->assign( BREADCRUMB => ($g_name ? $g_name : $crumb)) }
	    $tmpl->assign(BREADCRUMBLINK => $breadcrumblink);
	    $tmpl->parse('.BREADCRUMBS' => 'breadcrumb');
	}
	$DEBUG=0;
	$tmpl->assign(BREADCRUMB => ( $gallery_name ? $gallery_name : $lastcrumb));
	$tmpl->parse('.BREADCRUMBS' => 'deadcrumb');
    }

    my $row_width = 0;
    my $columns   = 0;

    $r->log_error("Opening path '$path/$dir'")
      if $DEBUG;

    unless( opendir DIR, path($path, $dir) ) {
	$r->log_error("Could not open path '" . path($path, $dir) . "': $!");
	return SERVER_ERROR;
    }

    ## get captions for subdirectories
    my %captions = get_captions(path($path, $dir));

    my $empty_gallery = 1;
    my $empty_other   = 1;
    for my $file ( sort { lc($a) cmp lc($b) }
		    grep { ! /^(?:\.|$CONFIG{'thumb_prefix'})/ } readdir DIR ) {
	my $fullpath = path($path, $dir, $file);

	if( -d $fullpath ) {
	    $tmpl->assign( DIRECTORY => ( $captions{$file}->[CAP_TEXT]
					? $captions{$file}->[CAP_TEXT]
					: $file ) );
	    $tmpl->assign( URI_DIR   => "$file/" );
	    $tmpl->assign( CAPTION   => ( $captions{$file}->[CAP_TEXT] 
					  ? $r->uri . "$file/"
					  : '' ) );
	    $tmpl->parse( DIR_CAPTION    => 'dir_caption');			   
	    $tmpl->parse(".DIRECTORIES"  => 'dir_link' );
	    undef $empty_other;
	}

	## a file
	elsif( -f _ ) {
	    next unless $r->lookup_file($fullpath)->content_type =~ m!^image/!;

	    my $thumbpath = path($path, $dir, $CONFIG{'thumb_dir'});
	    my $fullthumb = path($thumbpath, thumb($file));
	    warn "FULLPATH:  $fullpath\n"  if $DEBUG;
	    warn "THUMBPATH: $thumbpath\n" if $DEBUG;
	    warn "FULLTHUMB: $fullthumb\n" if $DEBUG;

	    ## make sure thumbnail exists and is newer than the image
	    unless( -e $fullthumb && (stat(_))[9] > (stat($fullpath))[9] ) {
		if( -e $thumbpath && ! -d $thumbpath ) {
		    $r->log_error("Warning! '$thumbpath' already exists but is not a directory. Refusing to write to possible dangerous location\n");
		    return;
		}
		mkdir $thumbpath, 0777 unless -d $thumbpath;

		my $magick = new Image::Magick;
		unless( $magick ) {
		    $r->log_error("No Image::Magick object: $!");
		    next;
		}
		$magick->Read($fullpath);
		my($o_width, $o_height) = $magick->Get('width', 'height');
		my($new_width, $new_height);

		unless( $o_width && $o_height ) {
		    $r->log_error("Zero width/height image at '$fullpath': $!\n");
		    next;
		}

		if( $CONFIG{'thumb_use'} eq 'aspect' ) {
		    my $ratio = eval($CONFIG{'thumb_aspect'}) || (1/5);
		    $new_width  = $o_width  * $ratio;
		    $new_height = $o_height * $ratio;
		}
		elsif( $CONFIG{'thumb_use'} eq 'height' ) {
		    my $ratio = ( $o_height ? $o_width / $o_height : 1 );
		    $new_width  = $CONFIG{'thumb_height'} * $ratio;
		    $new_height = $CONFIG{'thumb_height'};
		}
		else { ## width
		    my $ratio = ( $o_height ? $o_width / $o_height : 1 );
		    $new_width  = $CONFIG{'thumb_width'};
		    $new_height = $CONFIG{'thumb_width'}/$ratio;
		}

		## rescale and write the image to file
		$magick->Scale( width => $new_width, height => $new_height );
		unlink $fullthumb if -e $fullthumb;
		$magick->Write( $fullthumb );
		undef $magick;
	    }

	    ## decide whether to make a new row
	    if( $CONFIG{'thumb_columns'} 
		? $columns   >= $CONFIG{'thumb_columns'}
		: $row_width >= $CONFIG{'browser_width'} ) {
		$tmpl->parse('.ROWS' => 'table_row_middle');
		$row_width = $columns = 0;
	    }
	    $row_width += $CONFIG{'thumb_width'};
	    $columns++;
	    undef $empty_gallery;

	    $tmpl->assign(URI_IMAGE => $file);
	    my $uri = $r->uri; my $loc = $r->location;
	    $uri =~ s/^$loc/$CONFIG{'gallery_root'}/;
	    warn "URI:         $uri\n" if $DEBUG;
	    if( my($userdir) = $r->uri =~ m!~([^/]+)! ) {
		warn "USERDIR:     $userdir\n" if $DEBUG;
		$uri = "~$userdir/$uri";
	    }
	    $tmpl->assign(URI_THUMB => File::Spec->canonpath("/$uri/$CONFIG{'thumb_dir'}/" . 
							     thumb($file)));
	    $tmpl->parse('.ROWS'    => 'table_cell');
	}

	## skip non-files/dirs
    }
    closedir DIR;
    $tmpl->parse('.ROWS' => 'table_row_bottom');  ## the last tr tag
    $tmpl->parse(GALLERY => ( $empty_gallery ? 'gallery_empty' : 'gallery_table') );

  GET_NAVIGATION: {
	my @dirs = ();
	my $idx = 0;

      READ_DIRECTORY: {
	    if( path($path, $dir) eq $CONFIG{'gallery_path'} ) {
		$r->log_error("Current directory is $CONFIG{'gallery_path'}")
		  if $DEBUG;
		last READ_DIRECTORY;
	    }

	    opendir DIR, $path
	      or do {
		  $r->log_error( "Could not open '$path': $!" );
		  last GET_NAVIGATION;
	      };
	    @dirs = grep { -d path($path, $_) }
	      sort { lc($a) cmp lc($b) } grep { ! /^(?:\.|$CONFIG{'thumb_prefix'})/ } readdir DIR;
	    closedir DIR;
	    $idx++ while $idx < $#dirs && $dirs[$idx] ne $dir;
	}

	## no peer directories? Empty navigation templates
	unless( scalar(@dirs) ) {
	    $tmpl->parse(DIR_FIRST => 'first_empty');
	    $tmpl->parse(DIR_PREV  => 'previous_empty');
	    $tmpl->parse(DIR_NEXT  => 'next_empty');
	    $tmpl->parse(DIR_LAST  => 'last_empty');
	    last GET_NAVIGATION;
	}

	## parse navigation templates
	if( $dirs[0] eq $dir ) { $tmpl->parse(DIR_FIRST => 'first_empty') }
	else { 
	    $tmpl->assign(FIRST_LINK => "../$dirs[0]/");
	    $tmpl->assign(FIRST => '' );
	    $tmpl->parse(FIRST_DEFAULT => 'first_default');
	    if( my $caption = get_captions($path, $dirs[0]) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(FIRST => 'first_caption');
	    }
	    $tmpl->parse(DIR_FIRST => 'first');
	}

	if( ($idx-1) < 0 ) { $tmpl->parse(DIR_PREV => 'previous_empty') }
	else {
	    $tmpl->assign(PREV_LINK => "../$dirs[$idx-1]/");
	    $tmpl->assign(PREV => '');
	    $tmpl->parse(PREV_DEFAULT => 'previous_default');
	    if( my $caption = get_captions($path, $dirs[$idx-1]) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(PREV => 'previous_caption');
	    }
	    $tmpl->parse(DIR_PREV => 'previous');
	}

	if( ($idx+1) > $#dirs ) { $tmpl->parse(DIR_NEXT => 'next_empty') }
	else {
	    $tmpl->assign(NEXT_LINK => "../$dirs[$idx+1]/");
	    $tmpl->assign(NEXT => '');
	    $tmpl->parse(NEXT_DEFAULT => 'next_default');
	    if( my $caption = get_captions($path, $dirs[$idx+1]) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(NEXT => 'next_caption');
	    }
	    $tmpl->parse(DIR_NEXT => 'next');
	}

	if( $dirs[$#dirs] eq $dir ) { $tmpl->parse(DIR_LAST => 'last_empty') }
	else {
	    $tmpl->assign(LAST_LINK => "../$dirs[$#dirs]/");
	    $tmpl->assign(LAST => '');
	    $tmpl->parse(LAST_DEFAULT => 'last_default');
	    if( my $caption = get_captions($path, $dirs[$#dirs]) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(LAST => 'last_caption');
	    }
	    $tmpl->parse(DIR_LAST => 'last');
	}
    }

    $tmpl->parse(OTHER_GALLERIES => ( $empty_other 
				      ? 'other_empty' 
				      : 'other_galleries' ));
    $tmpl->parse(MAIN => 'main');
    $r->print($tmpl->to_string('MAIN'));

    return OK;
}

sub show_file {
    my $r    = shift;
    my ($path, $image) = shift =~ m!^(.*)/([^/]+)$!;

    $r->content_type('text/html');
    $r->send_http_header;
    return OK if $r->header_only;

    my $first = '';
    my $prev  = '';
    my $next  = '';
    my $last  = '';
    my $up    = $r->uri; $up =~ s!^(.*/)[^/]+$!$1!;
  GET_NAVIGATION: {
	opendir DIR, $path
	  or do {
	      $r->log_error( "Could not open '$path': $!" );
	      last GET_NAVIGATION;
	  };

	my @files = ();
	for my $file ( sort { lc($a) cmp lc($b) } 
		       grep { ! /^(?:\.|$CONFIG{'thumb_prefix'})/ } 
		       readdir DIR ) {
	    my $subr = $r->lookup_file(path($path, $file));
	    push @files, $file if -f $subr->finfo() && $subr->content_type =~ m!^image/!;
	}
	closedir DIR;

	$first = ( @files && $files[0]       eq $image ? '' : $files[0] );
	$last  = ( @files && $files[$#files] eq $image ? '' : $files[$#files] );
	my $idx = 0; $idx++ while $idx < $#files && $files[$idx] ne $image;
	$prev  = ( ($idx-1) < 0       ? '' : $files[$idx-1] );
	$next  = ( ($idx+1) > $#files ? '' : $files[$idx+1] );
    }

    my($link, $comment) = get_captions($path, $image);
    my $tmpl = new Template::Trivial;
    $tmpl->define_from_string(main => <<_EOF_,
<html>
<head>
<title>{TITLE}</title>
<style type="text/css">
<!--
  body {
    font-family: Helvetica, sans-serif, Arial;
    font-size: large;
    background: none;
    color: #F4F4F4;
    margin: 20px;
  }
  p {
    margin: 15px;
  }
  td {
    text-align: center;
    vertical-align: top;
    color: #000000;
  }
  a {
    color: #BD9977;
    background: none;
    font-size: x-small;
    text-decoration: none
  }
  img {
    border: 0
  }
//-->
</style>
</head>
<body>
<center>
<table width="400">
<tr align="center" valign="top">
<td width="20%">{IMG_FIRST}</td><td width="20%">{IMG_PREV}</td>
<td width="20%">{DIR_UP}</a>
<td width="20%">{IMG_NEXT}</a><td width="20%">{IMG_LAST}</td>
</tr>
</table>

<table>
<tr><td colspan="5"><img src="{IMAGE}"></td></tr>
<tr><td colspan="5">{LINK}{COMMENT}</td></tr>
</table>
</center>
</body>
</html>
_EOF_
			      link     => q!<a href="{IMG_LINK}">More</a><br>!,
			      link_empty => '',
			      up       => q!<a href="{UP}">Back to<br>Gallery</a>!,
			      first    => q!<a href="{FIRST}">First<br>Image</a>!,
			      first_empty => '',
			      previous => q!<a href="{PREV}">Previous<br>Image</a>!,
			      previous_empty => '',
			      next     => q!<a href="{NEXT}">Next<br>Image</a>!,
			      next_empty => '',
			      last     => q!<a href="{LAST}">Last<br>Image</a>!,
			      last_empty => '',
			     );

    ## set template variables
    my $uri = $r->uri; my $loc = $r->location;
    $uri =~ s/^$loc/$CONFIG{'gallery_root'}/;
    if( my($userdir) = $r->uri =~ m!~([^/]+)! ) {
	warn "USERDIR:     $userdir\n" if $DEBUG;
	$uri = "~$userdir/$uri";
    }
    $tmpl->assign(TITLE    => $comment);
    $tmpl->assign(COMMENT  => $comment);
    $tmpl->assign(IMAGE    => "/$uri");     ## uri to actual image

  TEMPLATE_DIR: for my $tmpl_dir 
      ( grep { -d }
	map { path($CONFIG{'gallery_path'}, ( $_ 
					      ? $CONFIG{'template_dir'} . ".$_" 
					      : $CONFIG{'template_dir'} ) ) }
	reverse @LANG ) {

	  warn "Reading image templates from '$tmpl_dir'\n" if $DEBUG;

	  $tmpl->templates($tmpl_dir);
	  $tmpl->define(main     => "image_main.txt")
	    if -f path($tmpl_dir, "image_main.txt");

	  $tmpl->define(link     => 'image_link.txt')
	    if -f path($tmpl_dir, 'image_link.txt');
	  $tmpl->define(link_empty => 'image_link_empty.txt')
	    if -f path($tmpl_dir, 'image_link_empty.txt');

	  $tmpl->define(up       => "image_up.txt")
	    if -f path($tmpl_dir, "image_up.txt");

	  $tmpl->define(first    => "image_first.txt")
	    if -f path($tmpl_dir, "image_first.txt");
	  $tmpl->define(first_empty => "image_first_empty.txt")
	    if -f path($tmpl_dir, "image_first_empty.txt");

	  $tmpl->define(previous => "image_previous.txt")
	    if -f path($tmpl_dir, "image_previous.txt");
	  $tmpl->define(previous_empty => "image_previous_empty.txt")
	    if -f path($tmpl_dir, "image_previous_empty.txt");

	  $tmpl->define(next     => "image_next.txt")
	    if -f path($tmpl_dir, "image_next.txt");
	  $tmpl->define(next_empty => "image_next_empty.txt")
	    if -f path($tmpl_dir, "image_next_empty.txt");

	  $tmpl->define(last     => "image_last.txt")
	    if -f path($tmpl_dir, "image_last.txt");
	  $tmpl->define(last_empty => "image_last_empty.txt")
	    if -f path($tmpl_dir, "image_last_empty.txt");
      }

    ## parse navigation links
    $tmpl->assign(UP      => $up);
    $tmpl->parse(DIR_UP   => 'up');

    if( $link ) { $tmpl->assign(IMG_LINK => $link); $tmpl->parse(LINK => 'link'); }
    else { $tmpl->parse(LINK => 'link_empty'); }

    if( $first ) { $tmpl->assign(FIRST => $first); $tmpl->parse(IMG_FIRST => 'first'); }
    else { $tmpl->parse(IMG_FIRST => 'first_empty'); }

    if( $prev ) { $tmpl->assign(PREV => $prev); $tmpl->parse(IMG_PREV => 'previous'); }
    else { $tmpl->parse(IMG_PREV => 'previous_empty'); }

    if( $next ) { $tmpl->assign(NEXT => $next); $tmpl->parse(IMG_NEXT => 'next'); }
    else { $tmpl->parse(IMG_NEXT => 'next_empty'); }

    if( $last ) { $tmpl->assign(LAST => $last); $tmpl->parse(IMG_LAST => 'last'); }
    else { $tmpl->parse(IMG_LAST => 'last_empty'); }

    ## process main
    $tmpl->parse(MAIN => 'main');
    $r->print($tmpl->to_string('MAIN'));

    return OK;
}

sub get_captions {
    my $path   = shift;
    my $lookup = shift;
    my %captions = ();
    my $lcaption = '';
    my $llink    = '';

    ## special case for gallery root in scalar context (I used to have
    ## !wantarray in here instead of "defined $lookup")
    if( defined $lookup && path($path,$lookup) eq $CONFIG{'gallery_path'} ) {
	return ( $CONFIG{'gallery_name'} ? $CONFIG{'gallery_name'} : $lcaption );
    }

  CAPTIONS: for my $caption_file ( map { path($path, ( $_ 
						       ? $CONFIG{'caption_file'} . ".$_" 
						       : $CONFIG{'caption_file'} ) ) }
				   reverse @LANG ) {

	$DEBUG=0;
	warn "Checking for $caption_file\n" if $DEBUG;
	next CAPTIONS unless -f $caption_file;

	warn "Found $caption_file...\n" if $DEBUG;

	open FILE, $caption_file
	  or last CAPTIONS;
	local $_;
	while( my $line = <FILE> ) {
	    chomp $line;
	    my($file,$link,$caption) = split(/:/, $line, 3);
	    if( $lookup ) {
		next unless $file eq $lookup;
		last unless $caption || $link;

		warn "Setting caption to $caption\n" if $DEBUG;
		$lcaption = $caption;
		$llink    = $link;
		last;
	    }
	    warn "Setting caption(2) to $caption\n" if $DEBUG;
	    $captions{$file} = [$link, $caption];
	      
	}
	close FILE;
	$DEBUG=0;
    }

    return ( $lookup ? ($llink, $lcaption) : %captions );
}

sub path  { return File::Spec->canonpath(File::Spec->catfile(grep $_, @_)) }
sub thumb { return $CONFIG{'thumb_prefix'} . (@_ ? shift : '') }

1;
__END__

=head1 NAME

Apache::App::Gallery::Simple - Elegant and fast filesystem-based image galleries

=head1 SYNOPSIS

  <Location /photos>
    SetHandler  perl-script
    PerlHandler Apache::App::Gallery::Simple;
    PerlSetVar  GalleryRoot    /vacation/images
    PerlSetVar  GalleryName    "My Vacation Photos"
  </Location>

  <Location /~hawkeye/photos>
    SetHandler perl-script
    PerlHandler Apache::App::Gallery::Simple
    PerlSetVar  GalleryRoot /images
    PerlSetVar  GalleryName "Hawkeye's Pictures"
    PerlSetVar  ThumbWidth  250
  </Location>

=head1 DESCRIPTION

Briefly: B<Gallery::Simple> creates navigable thumbnail galleries from
directories with images on your web server. B<Gallery::Simple> is
completely configurable via a simple template system, allows for image
captions as well as multimedia support, and also allows you to specify
multiple languages for your templates and captions. The rest of this
document is just details.

B<Gallery::Simple> creates an image gallery (complete with thumbnails
and navigation links) from a directory or directory hierarchy on a web
server. Simply upload images to a directory and the work is done. You
can add captions to your images or other media (e.g., movies; see
L<"ALTERNATIVE MEDIA">) and the entire B<Gallery::Simple> application
is customizable using a simple template system (see L<"TEMPLATES">).

I wanted an image gallery that was as easy to setup and use as
Apache::Album but that offered a little more flexibility with
captions, style/layout (including CSS or other customizations).

Some effort has been made to retain some of the Apache::Album
configuration directives, if not in name, at least in spirit. You
should also be able to use existing thumbnail directories if you're
migrating from Apache::Album.

Using Gallery::Simple is, well, simple. There are no configuration
files or anything of that sort (other than the Apache directives
described in L<"OPTIONS">). All you have to do is install it, add
something like the I<Location> block shown above in B<"SYNOPSIS">
section, and the path specified in B<GalleryRoot> has suddenly become
an image gallery.

There are a few features that are I<not> implemented that
Apache::Album does implement, namely:

  - slideshow
  - browser-based uploads and gallery configuration
  - image sorting
  - variable image size viewing

Gallery::Simple does do a couple of things well, however. It allows
you to put captions to your images. It allows you to link to an
alternative media source in the image page, which means you can also
upload movies and other such stuff into your gallery. It allows
template sets and caption files for multiple languages, meaning web
visitors who prefer to see your site in Spanish may do so, while the
German readers can see German galleries.

Gallery::Simple handles virtual hosted domains and even handles
"tilde-dirs" or directories using Apache's B<UserDir> directive in the
form of F<http://www.foo.dom/~bar/baz>.

Further, Gallery::Simple also allows you to completely customize the
HTML returned for a particular gallery and an image page (you could
even customize it to return XML if you wanted). You can add style
sheets, alter (even replace) the layout so that it integrates cleanly
with your existing web site.

=head2 A quick example

Say you have a directory under your DocumentRoot (e.g.,
F</usr/home/joe/www>) called F</family/images> that contains digital
photos (full path: F</usr/home/joe/www/family/images>) and you want
people to access this location with the following url:

    http://www.joesfamily.org/gallery/

Add the following block to your Apache configuration file:

  <VirtualHost joesfamily.org>
    ServerName    joesfamily.org
    DocumentRoot  /usr/home/joe/www
    ...
  
    ## this is the gallery section you've just added
    <IfModule mod_perl.c>
      PerlWarn       On
      PerlTaintCheck On

      <Location /gallery>
	SetHandler perl-script
	PerlHandler Apache::App::Gallery::Simple
	PerlSetVar  GalleryRoot  /family/images
        PerlSetVar  GalleryName  "Joe's Photo Gallery"
      </Location>
    </IfModule>
  </VirtualHost>

Browsers accessing the url F<http://www.joesfamily.org/gallery/> will
be looking at the images in F</home/joe/www/family/images>.

=head1 OPTIONS

The following options are available in the Apache configuration file
with the B<PerlSetVar> directive.

=over 4

=item B<GalleryRoot>

Default: (empty)

Values: The physical path to the image gallery, relative to the
document root (for Apache B<UserDir> directories, this is often
F</home/username/htdocs> or something like that).

Description: this setting determines where Gallery::Simple looks for
your image gallery. All image files and directories rooted at this
location will be part of the gallery.

Paths should be specified without a leading slash; paths will be
relative to the document root (Apache's B<DocumentRoot>) for this
virtual host. Special care has been take to make this work for hosts
using Apache's B<UserDir> directive (i.e., "tilde-user" URIs such as
"~joe") as well.

=item B<GalleryName>

Default: (empty)

Values: Any string value

Description: this is the name of your "top" gallery; sub-gallery names
may be specified in the F<caption.txt> file.

=item B<GalleryLang>

Default: en

Values: Any ISO-639 language code

Description: this setting determines what language the default
F<caption.txt> file services. Browser clients send an ordered list of
preferred languages; Gallery::Simple uses this data to select which
F<caption.txt> file to read.

For example, if a browser prefers Spanish content to English, it might
send "es, en" in its request. Gallery::Simple detects this and will
look for F<caption.txt.es> and then F<caption.txt> for caption
information. If B<GalleryLang> is set to 'es', then Gallery::Simple
will assume that F<caption.txt> is in Spanish and look for
F<caption.txt> and then F<caption.txt.en> for caption information.

Gallery::Simple automatically tries major language preference if a
minor language preference fails. For example, if 'en-US' does not
exist, 'en' will be tried next (and not tried again, even if, for
example, 'en-UK' were preferred second).

=item B<ThumbUse>

Default: C<width>

Values: C<width>, C<height>, C<aspect>

Description: this setting determines how to thumbnail an image;
I<width> means that the value in B<ThumbWidth> will be used and the
height will scale accordingly; I<height> means that the value in
B<ThumbHeight> will be used and the width will scale accordingly;
I<aspect> means that the ratio in B<ThumbAspect> will be used and the
height and width will scale by that factor.

=item B<ThumbWidth>

Default: C<100>

Values: any positive integer value

Description: this setting is used when B<ThumbUse> is set to I<width>.
This determines how wide the thumbnails will be. The height will be
scaled to preserve the original image's width/height ratio.

=item B<ThumbHeight>

Default: C<100>

Values: any positive integer value

Description: this setting is used when ThumbUse is set to I<height>.
This determines how high the thumbnails will be. The width will be
scaled to preserve the original image's width/height ratio.

=item B<ThumbAspect>

Default: C<1/5>

Values: any fractional value; may be expressed as a decimal number

Description: this setting will scale all images by this amount. The
default (1/5) means that the image will be 1/5 of its original size.

=item B<ThumbDir>

Default: C<.thumbs>

Values: any valid directory name

Description: this is the name of the directory that will be created
to store thumbnails. Only filenames (no pathnames containing '/') are
allowed. A B<ThumbDir> will be created in each gallery directory where
images are found.

=item B<ThumbPrefix>

Default: C<tn__>

Values: any string of characters (no '/').

Description: this value will be prepended to each thumbnail image to
distinguish it from a regular image.

=item B<ThumbColumns>

Default: C<0>

Values: zero (0) or any positive integer value

Description: this determines the number of columns in the thumbnail
gallery. This setting overrides the calcuated setting determined by
B<BrowserWidth> and can be set to any positive integer value.

=item B<BrowserWidth>

Default: C<640>

Values: any positive integer value

Description: this setting determines the optimal browser width for
your visitors. The number of columns displayed is determined by
dividing the B<BrowserWidth> setting by B<ThumbWidth> (even if
B<ThumbHeight> is being used). For example, if B<BrowserWidth> is set
to 640 and B<ThumbWidth> is set to 100, then there will be 640/100 =
6 columns of thumbnails in each gallery.

=item B<BreadcrumbHome>

Default: off

Values: [on|off]

Description: when enabled, displays a link to the URL of '/' ("home")
in the breadcrumb navigation links in a gallery.

=item B<CaptionFile>

Default: C<caption.txt>

Values: any valid filename

Description: this is the name of the file where image caption
information will be stored. Only filenames (no pathnames containing
'/') are allowed. If a B<CaptionFile> exists, it will be read and
captions found will be displayed with the image. More information
about caption files may be found in L<"CAPTION FILES">.

=item B<TemplateDir>

Default: C<.templates>

Values: any valid directory name

Description: this is the name of the directory where you will store
your templates, if you wish to override the default look-and-feel of
Gallery::Simple. This directory is always found in the B<GalleryRoot>
directory. Only filenames (no pathnames containing '/') are allowed.
More information about templates may be found in L<"TEMPLATES">.

=back

=head1 ALTERNATIVE MEDIA

You can have non-image media (audio clips, movies, etc.) in your
gallery, too, as long as you have an image to represent it. Upload
your non-image media just as you would an image. Additionally, you'll
need to upload an image that represents your media. For example, if
your alternative media were a movie, you might take a screen capture
of it and use that as your image.

Once you've uploaded the media file and a representative image, you'll
then need to create a file called F<caption.txt> in the same directory
you uploaded the image to.  The file should contain a line like the
following:

    picnic.jpg:picnic.mov

F<picnic.jpg> is the name of your representative image; F<picnic.mov>
is your movie file. Now when people browse your gallery, they'll see
F<picnic.jpg> in the thumbnail gallery. If they click the image,
they'll be taken to a page that contains a larger version of the image
(just as a normal image would), but there will also be a link (by
default, the word "More") beneath the image which links to your
alternative media file.

For more information about the caption file see L<"CAPTION FILES">. For
more information about customizing the look of the gallery, see
L<"TEMPLATES">.

=head1 CAPTION FILES

The format of a caption file is this:

  imagename:othername:some caption text

I<imagename> is the name of the image (in this directory) that the
caption relates to. I<imagename> is case-sensitive. I<othername> is
optional.

I<othername> is a link where another media file (such as a Quicktime
movie or mpeg file) may be found (also in this directory).  Using the
default templates (see L<"TEMPLATES">), a link "More" will be placed
below the image on the image page (not in the gallery) indicating that
additional media is available.

The final field is where you can put a brief (or long--it goes until
the next newline character) description of this image. Here is a
sample directory listing:

  January
  melissa.jpg
  jared.jpg
  PB140011.JPG
  joe_burns.mov
  joe_tabasco.jpg

and the corresponding caption file:

  January::January 2003
  melissa::Melissa shakes hands with Tom
  jared.jpg::Jared turfs it
  joe_tabasco.jpg:joe_burns.mov:Joe eating Tabasco sauce

We notice the following things about these images and the
corresponding caption file:

=over 4

=item January

This is a directory within our gallery; this will be treated as a
"sub-gallery". The 'othername' space is empty ("::") and is currently
not used with sub-galleries. The directory will appear with the link
"January 2003" instead of just "January".

=item melissa.jpg

This image has no alternative media--the 'othername' space is empty
("::"). This image does have a comment (caption): "Melissa shakes
hands with Tom".

=item jared.jpg

This image is like the previous one: no alternative media, but it does
have a caption.

=item PB140011.JPG

This image is not mentioned in the caption file--no caption will be
printed for this image.

=item joe_tabasco.jpg

This image has a movie file associated with it (joe_burns.mov); a small
link will appear below this image (not in the gallery, but in the
image page itself) along with the caption "Joe eating Tabasco sauce".

=back

=head1 TEMPLATES

B<Gallery::Simple> image galleries and image pages may be customized
on a per-gallery basis (i.e., per-virtualhost or per UserDir, but not
per-subdirectory). This means that you can have one image gallery for
your brother-in-law and allow him to make his gallery appear as he
wants, and another gallery for Mom and allow her to customize her
gallery in her way.

The B<Gallery::Simple> template system is based on
B<Template::Trivial> (see L<Template::Trivial>), a fast, minimalistic
template system.  B<Gallery::Simple> has two template sets:

=over 4

=item *

thumbnail gallery ("gallery") templates (and associated template variables)

=item *

image page templates (and associated template variables)

=back

Each of these sets of templates (including template variables) are
described below.

To customize a whole or part of the look (HTML) of B<Gallery::Simple>,
all you need to do is create (or edit, if the template already exists)
a template file and upload it to a directory called F<.templates> (see
L</"TemplateDir">) in the directory you have designated as the gallery
root (see L</"GalleryRoot">).

B<Gallery::Simple> will automatically detect the new template and use
it for the next browser request. No server restart is necessary.

Associated with each template are zero or more template variables;
these variables are assigned values during the browser request (and
the value assigned depends on the current gallery, the caption file
and other environmental factors).

You may insert, rearrange, or remove template variables from the
templates to achieve a new gallery and iamge page look. Please refer
to L<Template::Trivial> for more details on how to use templates.

In the sections below we describe the available templates and
variables to customize any single Gallery::Simple gallery.

=head2 Gallery Templates

Gallery templates affect the HTML layout of the thumbnail gallery,
including navigation links, the thumbnail table layout,
"sub-galleries" (directories within the current gallery), breadcrumb
links (top level navigation), etc.

The gallery template set consists of the following templates:

=over 4

=item F<gallery_main.txt>

Default value:

    <html>
    <head>
    <title>Photo Gallery: {GALLERY_NAME}</title>
    <style type="text/css">
    <!--
      body {
	font-family: Helvetica, sans-serif, Arial;
	font-size: large;
	color: #F4F4F4;
	background: none;
	margin: 20px;
      }
      p {
	margin: 15px;
      }
      td {
	text-align: center;
	vertical-align: top;
      }
      a {
	color: #BD9977;
	background: none;
	font-size: x-small;
	text-decoration: none;
      }
      img {
	border: 0
      }
      .breadcrumb {
	font-size: x-small;
	background: none;
	color: #000000;
      }
      .address {
	text-align: right;
	font-size: xx-small;
      }
    //-->
    </style>
    </head>
    
    <body>
    {GALLERY_TITLE}
    <p class="breadcrumb">This gallery: {BREADCRUMBS}</p>
    {OTHER_GALLERIES}
    <center>
    <table width="400">
    <tr>
    <td width="25%">{DIR_FIRST}</td><td width="25%">{DIR_PREV}</td>
    <td width="25%">{DIR_NEXT}</a><td width="25%">{DIR_LAST}</td>
    </tr>
    </table>
    
    {GALLERY}
    </center>
    <hr>
    <div class="address">
      <a href="http://scott.wiersdorf.org/perl/">Apache::App::Gallery::Simple</a>
    </div>
    </body>
    </html>

Variables: GALLERY_NAME, GALLERY_TITLE, BREADCRUMBS, OTHER_GALLERIES,
DIR_FIRST, DIR_PREV, DIR_NEXT, DIR_LAST, GALLERY

=item F<gallery_title.txt>

Default value: (empty)

Variables: GALLERY_NAME

=item F<gallery_title_empty.txt>

Default value: (empty)

=item F<gallery_other.txt>

Default value:

    <p class="breadcrumb">Other galleries within this gallery:<br>
    {DIRECTORIES}</p>

Variables: DIRECTORIES

=item F<gallery_other_empty.txt>

Default value:

    <p class="breadcrumb">(No other galleries within this gallery)</p>

=item F<gallery_breadcrumb.txt>

Default value:

    &nbsp;<a href="{BREADCRUMBLINK}">{BREADCRUMB}</a>&nbsp;-&gt;

Variables: BREADCRUMBLINK, BREADCRUMB

=item F<gallery_deadcrumb.txt>

Default value:

    &nbsp;{BREADCRUMB}

Variables: BREADCRUMB

=item F<gallery_homecrumb.txt>

Default value:

    home

=item F<gallery_first.txt>

Default value:

    <a href="{FIRST_LINK}">{FIRST_DEFAULT}</a>

Variables: FIRST_LINK, FIRST_DEFAULT, FIRST

=item F<gallery_first_empty.txt>

Default value: (empty)

=item F<gallery_first_default.txt>

Default value:

    First<br>Gallery

=item F<gallery_first_caption.txt>

Default value:

    <br>({CAPTION})

Variable: CAPTION

=item F<gallery_previous.txt>

Default value:

    <a href="{PREV_LINK}">{PREV_DEFAULT}{PREV}</a>

Variables: PREV_LINK, PREV_DEFAULT, PREV

=item F<gallery_previous_empty.txt>

Default value: (empty)

=item F<gallery_previous_default.txt>

Default value:

    Previous<br>Gallery

=item F<gallery_previous_caption.txt>

Default value:

    <br>({CAPTION})

Variables: CAPTION

=item F<gallery_next.txt>

Default value:

    <a href="{NEXT_LINK}">{NEXT_DEFAULT}{NEXT}</a>

Variables: NEXT_LINK, NEXT_DEFAULT, NEXT

=item F<gallery_next_empty.txt>

Default value: (empty)

=item F<gallery_next_default.txt>

Default value:

    Next<br>Gallery

=item F<gallery_next_caption.txt>

Default value:

    <br>({CAPTION})

Variables: CAPTION

=item F<gallery_last.txt>

Default value:

    <a href="{LAST_LINK}">{LAST_DEFAULT}</a>

Variables: LAST_LINK, LAST_DEFAULT, LAST

=item F<gallery_last_empty.txt>

Default value: (empty)

=item F<gallery_last_default.txt>

Default value:

    Last<br>Gallery

=item F<gallery_last_caption.txt>

Default value:

    <br>({CAPTION})

Variables: CAPTION

=item F<gallery_dir_link.txt>

Default value:

    <a href="{URI_DIR}">{DIRECTORY}</a><br>\n

Variables: URI_DIR, DIRECTORY

=item F<gallery_dir_caption.txt>

Default value:

    &nbsp;({CAPTION})

Variables: CAPTION

=item F<gallery_gallery_table.txt>

Default value:

    <table>{ROWS}</table>

Variables: ROWS

=item F<gallery_gallery_empty.txt>

Default value:

    <table><tr><td>(No photos in this gallery)</td></tr></table>

=item F<gallery_row_top.txt>

Default value:

    <tr>

=item F<gallery_row_middle.txt>

Default value:

    {ROW_END}{ROW_START}

Variables: ROW_END, ROW_START

=item F<gallery_row_bottom.txt>

Default value:

    </tr>

=item F<gallery_cell.txt>

Default value:

    <td align="center"><a href="{URI_IMAGE}"><img src="{URI_THUMB}" border="0"></a></td>

Variables: URI_IMAGE, URI_THUMB

=back

=head2 Gallery Template Variables

We now describe the available B<template variables> for the thumbnail 
gallery template set. Some variables are assigned template parse
results ("parsed"), some variables are assigned a string ("assigned"),
while other variables may be either parsed or assigned, depending on
the context and other factors.

This is important to know which variables are parsed so that you know
which templates to alter if you want to alter the contents of a
variable. Variables whose value depends completely on environmental
factors (such as working directory names, caption files, etc.) may not
be altered via a template, but the variable may be removed or
rearranged in its respective template.

=over 4

=item BREADCRUMB

Assigned/parsed (F<gallery_homecrumb.txt>). Part of the top level
breadcrumb navigation; iteratively set to each path component (i.e.,
each directory name) up to the home directory.  If a higher level
directory has a caption in the B<caption file>, this caption will be
used instead.

=item BREADCRUMBLINK

Assigned. Part of the top level breadcrumb navigation; alternatively
set to each path component (i.e., each directory name) up to the home
directory.  This is part of the actual HTML link and should always be
a valid URI.

=item BREADCRUMBS

Parsed (F<gallery_breadcumb.txt>).

=item CAPTION

Assigned. Set to the comment or caption portion of the B<caption file>.

=item DIRECTORIES

Parsed (F<gallery_dir_link.txt>)

=item DIRECTORY

Assigned. Set to one of the directories or sub-directories within this
directory.

=item FIRST

Assigned/parsed (F<gallery_first_caption.txt>). If a caption is not
available for this directory, the variable is set to an empty string.

This variable is not used in the default templates.

=item FIRST_DEFAULT

Parsed (F<gallery_first_default.txt>).

=item FIRST_LINK

Assigned. Set to the URI of the first directory.

=item GALLERY_NAME

Assigned. Set to the caption for this directory, if any; otherwise set
to the current relative URI.

=item GALLERY_TITLE

Parsed (F<gallery_title.txt>, F<gallery_title_empty.txt>).

=item LAST

analogous to FIRST

=item LAST_DEFAULT

analogous to FIRST_DEFAULT

=item LAST_LINK

analogous to FIRST_LINK

=item NEXT

Assigned/parsed (F<gallery_next_caption.txt>). If a caption is not
available for this directory, the variable is set to an empty string.

=item NEXT_DEFAULT

Parsed (F<gallery_next_default.txt>).

=item NEXT_LINK

Assigned. Set to the URI of the next directory.

=item OTHER_GALLERIES

Parsed (F<gallery_other_empty.txt>, F<gallery_other.txt>).

=item PREV

Analogous to NEXT

=item PREV_DEFAULT

Analogous to NEXT_DEFAULT

=item PREV_LINK

Analogous to NEXT_LINK

=item ROWS

Parsed (F<gallery_row_top>, F<gallery_row_middle>, F<gallery_cell>,
F<gallery_row_bottom>).

=item ROW_END

Parsed (F<gallery_row_bottom.txt>).

=item ROW_START

Parsed (F<gallery_row_top.txt>).

=item URI_DIR

Assigned. Set to the current directory name with trailing slash.

=item URI_IMAGE

Assigned. Set to the URI of the image name.

=item URI_THUMB

Assigned. Set to the URI of the image thumbnail.

=back

=head2 Image Page Templates

Image page templates affect the image page HTML layout, including
navigation links, additional media links, and the image itself.

The image page template set consists of the following templates:

=over 4

=item F<image_main.txt>

Default value:

    <html>
    <head>
    <title>{TITLE}</title>
    <style type="text/css">
    <!--
      body {
	font-family: Helvetica, sans-serif, Arial;
	font-size: large;
	background: none;
	color: #F4F4F4;
	margin: 20px;
      }
      p {
	margin: 15px;
      }
      td {
	text-align: center;
	vertical-align: top;
	color: #000000;
      }
      a {
	color: #BD9977;
	background: none;
	font-size: x-small;
	text-decoration: none
      }
      img {
	border: 0
      }
    //-->
    </style>
    </head>
    <body>
    <center>
    <table width="400">
    <tr align="center" valign="top">
    <td width="20%">{IMG_FIRST}</td><td width="20%">{IMG_PREV}</td>
    <td width="20%">{DIR_UP}</a>
    <td width="20%">{IMG_NEXT}</a><td width="20%">{IMG_LAST}</td>
    </tr>
    </table>
    
    <table>
    <tr><td colspan="5"><img src="{IMAGE}"></td></tr>
    <tr><td colspan="5">{LINK}{COMMENT}</td></tr>
    </table>
    </center>
    </body>
    </html>

Variables: TITLE, IMG_FIRST, IMG_PREV, DIR_UP, IMG_NEXT, IMG_LAST,
IMAGE, LINK, COMMENT

=item F<image_link.txt>

Default value:

    <a href="{IMG_LINK}">More</a><br>

Variables: IMG_LINK

=item F<image_link_empty.txt>

Default value: (empty)

=item F<image_up.txt>

Default value:

    <a href="{UP}">Back to<br>Gallery</a>

Variables: UP

=item F<image_first.txt>

Default value:

    <a href="{FIRST}">First<br>Image</a>

Variables: FIRST

=item F<image_first_empty.txt>

Default value: (empty)

=item F<image_previous.txt>

Default value:

    <a href="{PREV}">Previous<br>Image</a>

Variables: PREV

=item F<image_previous_empty.txt>

Default value: (empty)

=item F<image_next.txt>

Default value:

    <a href="{NEXT}">Next<br>Image</a>

Variables: NEXT

=item F<image_next_empty.txt>

Default value: (empty)

=item F<image_last.txt>

Default value:

    <a href="{LAST}">Last<br>Image</a>

Variables: LAST

=item F<image_last_empty.txt>

Default value: (empty)

=back

=head2 Image Page Template Variables

We now describe the available B<template variables> for the image page
template set. Some variables are assigned template parse results
("parsed"), some variables are assigned a string ("assigned"), while
other variables may be either parsed or assigned, depending on the
context and other factors.

This is important to know which variables are parsed so that you know
which templates to alter if you want to alter the contents of a
variable. Variables whose value depends completely on environmental
factors (such as working directory names, caption files, etc.) may not
be altered via a template, but the variable may be removed or
rearranged in its respective template.

=over 4

=item TITLE

Assigned. Set to the image caption; if no caption is available, set
to the image filename.

IMG_FIRST

Parsed (F<image_first.txt>, F<image_first_empty.txt>).

IMG_PREV

Analogous to IMG_FIRST.

DIR_UP

Parsed (F<image_up.txt>).

IMG_NEXT

Analogous to IMG_FIRST.

IMG_LAST

Analogous to IMG_FIRST.

IMG_LINK

Assigned. Set to the link field of the caption file, if applicable.

UP

Assigned. Set to the parent URI of the current image.

FIRST

Assigned. Set to the first image URI in this gallery.

PREV

Analogous to FIRST

NEXT

Analogous to FIRST

LAST

Analogous to FIRST

=back

=head1 MULTI-LANGUAGE SUPPORT

Gallery::Simple supports multiple languages for templates and caption
files. The B<GalleryLang> setting determines what language the
F<caption.txt> file will handle (be default, English). For example,
suppose your web visitors are predominantly Spanish-speaking (or at
least, Spanish-reading). You set B<GalleryLang> in your Apache
configuration file to 'es', which is the ISO-639 language code for
Spanish.

Browsers that send the "Accept-Languages" header (most modern browsers
do) and have "es" as their preferred language will receive the
contents of the F<caption.txt> file (because we told Gallery::Simple
that 'es' was our default language for this gallery).

If you also want to service English-readers, you would create a
F<caption.txt.en> file that contained English captions. Now your
English-reading visitors will be able to view your site in English.

The default setting for B<GalleryLang> is 'en' (English). All incoming
language codes are converted to lowercase, so you don't have to
differentiate between 'en-US' and 'en-us'.

You may have as many F<caption.txt.(language code)> files as you wish.
If a caption is not available in one caption file and the browser
specified alternative languages, the next caption file (if available)
will be searched for a caption (also, if available).

You can also specify multi-language template directories in the same
manner as caption files: simply name the template directory
F<.templates.es> (taking Spanish as our example again) for Spanish
templates.

=head1 EXAMPLES

Here are a few simple examples of how to customize Gallery::Simple.

=head2 Gallery Columns

You wish to change the number of columns in the gallery. Use the
B<ThumbColumns> or B<BrowserWidth> directive in the Apache
configuration file.

=head2 Thumbnail size

You wish to change the size of the thumbnails in the gallery. Use the
B<ThumbWidth> directive in the Apache configuration file.

=head2 Alternative Gallery Navigation

You wish to use images instead of text for gallery navigation (moving
between galleries). First you'll need to create some suitable images
(e.g., arrows or something like that). Next, create (if it doesn't
already exist) a directory named F<.templates> (or whatever you may
have B<TemplateDir> set to) in the B<GalleryRoot> directory (remember,
B<GalleryRoot> is relative to B<DocumentRoot> for that virtual host
or relative to the B<UserDir> if this is a tilde-user account).

Next, create something like the following files, with the following
contents in the templates directory (you should replace the image
paths with the actual paths to your new images).

=over 4

=item F<gallery_first.txt>

    <a href="{FIRST_LINK}"><img src="/images/first.gif"></a>

=item F<gallery_previous.txt>

    <a href="{PREV_LINK}"><img src="/images/previous.gif"></a>

=item F<gallery_next.txt>

    <a href="{NEXT_LINK}"><img src="/images/next.gif"></a>

=item F<gallery_last.txt>

    <a href="{LAST_LINK}"><img src="/images/last.gif"></a>

=back

=head2 Image Captions

You wish to add a caption to an image. Create (or edit, if the file
already exists) F<caption.txt> (or the file specified by the
B<CaptionFile> directive in the Apache configuration file). Now add a
line like the following:

    image1.jpg::Our House in the Evening

=head2 Multimedia Content

You wish to add a movie to your gallery. First create an image that
will represent your movie (e.g., a video capture or something like
that would be fine); upload both the movie and image to the gallery
of your choice. Edit the F<caption.txt> file in that gallery and add
a line like the following:

    truck.jpg:truck.mov:A video clip of my truck

F<truck.jpg> will be automatically thumbnailed and used in the
thumbnail gallery; it will also be used on the image page itself with
the caption "A video clip of my truck". Below the image and above the
caption will appear the word "More" (you can override this in the
F<image_link.txt> template), indicating that there is additional
media available.

=head2 Multilanguage Captions

Some relatives in England want to see our pictures, but do not wish
to see our barbaric Americanisms in the image captions. We can create
a new caption file called F<caption.txt.en-uk> for browsers that send
'en-uk' as their primary language preference.

Our default F<caption.txt> file might look like this:

    highway.jpg::Two-way traffic
    soda.jpg::A carbonated beverage
    train.jpg::The subway
    watchout.jpg::Watch your step

While our F<caption.txt.en-uk> file would contain these UK
translations:

    highway.jpg::Dual carriageway
    soda.jpg::A fizzy drink
    train.jpg::The tube
    watchout.jpg::Mind the gap

Now web visitors whose browsers are configured to send 'en-uk' as
their primary language preference will see the correct captions to our
photos.

=head1 SAMPLES

The following sites run B<Apache::App::Gallery::Simple>; if you want
yours listed here, contact the author or current maintainer.

=over 4

=item B<Tubbing Foundation of America>

"Photo Album" link at http://www.tubbing.com/

=back

=head1 TROUBLESHOOTING

=head2 The image pages work, but the thumbnail galleries come up with
broken images

Make sure the image directory directory is writable by the UID that
Apache runs as (usually I<www> or I<nobody>). This will allow
Gallery::Simple to create a F<.thumbs> directory (or whatever you have
B<ThumbsDir> set to) to write thumbnail images into. This means you
have to 'chmod g+w photos' (or whatever directory that is) so that
Gallery::Simple can create the thumbnail directory and populate it.

=head1 SUPPORT

Additional documentation, template sets, and mailing list available
at:

    http://scott.wiersdorf.org/perl/Apache-App-Gallery-Simple/

=head1 CAVEATS

=over 4

=item *

'&' in your caption.txt files should be replaced with '&amp;' <'
should be replaced with '&lt;'

=item *

The thumbnail directory must be writable by the UID that Apache runs
under (usually I<www> or I<nobody>).

=back

=head1 SECURITY

Because Gallery::Simple writes image thumbnails with the UID that
Apache runs under (e.g., 'nobody' or 'www', etc.), it is possible to
trick Gallery::Simple to write into areas unintended by the
administrator.

Every effort is made to ensure that Gallery::Simple does not write
into unintended locations, but there are race conditions and possibly
situations the author has not foreseen.

If you are an administrator and wish to offer Gallery::Simple to users
on your system, consider restricting shell and CGI access to trusted
users only to prevent the creation of symbolic links and other such
risky actions.

If you find a flaw in the logic or other potential security issues,
please report it to the author or current maintainer as soon as
possible. Patches always welcome!

=head1 AUTHOR

Scott Wiersdorf, <scott@perlcode.org>

=head1 SEE ALSO

perl(1).

=cut
