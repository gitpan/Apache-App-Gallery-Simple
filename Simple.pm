package Apache::App::Gallery::Simple;
use strict;

## This is a simple mod_perl gallery application inspired by Apache::Album
## by James D. Woodgate; additional inspiration courtesy _Writing Apache
## Modules with Perl and C_ by Lincoln Stein and Doug MacEachern

use Apache::Constants qw(DECLINED OK SERVER_ERROR REDIRECT);
use Image::Magick;
use Template::Trivial;
use File::Spec;
use File::Path qw(rmtree);

use vars qw($VERSION);
$VERSION = '1.07';

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
	grep { $_ } map { $_, ($CONFIG{'language_strict'} 
			       ? () 
			       : /^([^-]+)/) }
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
	return show_gallery($r, $subr);
    }

    elsif( -f _ ) {
	$r->log_error( "found a regular file at $uri" )
	  if $DEBUG;

	if( $subr->content_type =~ m!^image/! ) {
	    return show_image($r, $subr);
	}

	elsif( $subr->content_type =~ m!^video/quicktime! ) {
	    return show_mov($r, $subr);
	}

	elsif( $subr->content_type =~ m!^video/mp(?:e|g|eg)! ) {
	    return show_mpeg($r, $subr);
	}

	elsif( $subr->content_type =~ m!^video/x-msvideo! ) {
	    return show_avi($r, $subr);
	}

	## pass everything else through
	else {
	    $r->log_error("Pass through content ($uri)")
	      if $DEBUG;
	    return $subr->run;  ## FIXME: Apache book says we could do
		                ## internal redirect here for efficiency
	}
    }

    ## not a file or directory
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
    $config{'language_strict'} =
      $r->dir_config('LanguageStrict') ||
	'no';
    $config{'other_gallery_links'} = 
      $r->dir_config('OtherGalleryLinks') ||
	'yes';
    $config{'always_link'} = 
      $r->dir_config('AlwaysLink')   ||
	'no';
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
    $config{'language_strict'} = $config{'language_strict'} =~ /^(?:yes|on|true|1)$/i;
    $config{'other_gallery_links'} = $config{'other_gallery_links'} =~ /^(?:yes|on|true|1)$/i;
    $config{'always_link'} = $config{'always_link'} =~ /^(?:yes|on|true|1)$/i;

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
    my $subr = shift;
    my ($path, $dir) = $subr->filename =~ m!^(.*)/([^/]+)$!;

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
<title>{GALLERY_NAME}</title>
{GALLERY_STYLE}
</head>

<body>
{GALLERY_TITLE}
{BREADCRUMBS}
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
{GALLERY_FOOTER}
</body>
</html>
_EOF_
			      gallery_title    => q!!, ## was '<h2>{GALLERY_NAME}</h2>'
			      gallery_title_empty => '',
			      gallery_style    => <<_EOF_,
<style type="text/css">
<!--
  body {
    font-family: Helvetica, sans-serif, Arial;
    font-size: large;
    color: #000000;
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
  }
  .galleries {
    font-size: x-small;
    background: none;
  }
  .address {
    text-align: right;
    font-size: xx-small;
  }
//-->
</style>
_EOF_
			      gallery_footer   => <<_EOF_,
<hr>
<div class="address">
  <a href="http://scott.wiersdorf.org/perl/Apache-App-Gallery-Simple/">Apache::App::Gallery::Simple {VERSION}</a>
</div>
_EOF_
			      other_galleries  => <<_EOF_,
<p class="galleries">Other galleries within this gallery:<br>
{DIRECTORIES}</p>
_EOF_
			      other_empty      => <<_EOF_,
<p class="galleries">(No other galleries within this gallery)</p>
_EOF_
			      breadcrumbs      => q!<p class="breadcrumb">This gallery: {BREADCRUMB_PATH}</p>!,
			      breadcrumb       => q!&nbsp;<a href="{BREADCRUMB_LINK}">{BREADCRUMB}</a>&nbsp;-&gt;!,
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
	  $tmpl->define(gallery_style    => "gallery_style.txt")
	    if -f path($tmpl_dir, "gallery_style.txt");
	  $tmpl->define(gallery_footer   => "gallery_footer.txt")
	    if -f path($tmpl_dir, "gallery_footer.txt");
	  $tmpl->define(other_galleries  => "gallery_other.txt")
	    if -f path($tmpl_dir, "gallery_other.txt");
	  $tmpl->define(other_empty      => "gallery_other_empty.txt")
	    if -f path($tmpl_dir, "gallery_other_empty.txt");
	  $tmpl->define(breadcrumbs      => "gallery_breadcrumbs.txt")
	    if -f path($tmpl_dir, "gallery_breadcrumbs.txt");
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
    $tmpl->parse(  GALLERY_STYLE   => 'gallery_style');
    $tmpl->assign( VERSION         => $VERSION );
    $tmpl->parse(  GALLERY_FOOTER  => 'gallery_footer');
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
	    warn "BREADCRUMB_LINK: $breadcrumblink\n" if $DEBUG;
	    warn "FULLPATH:       $fullpath\n" if $DEBUG;
	    if( $crumb eq '/' ) { $tmpl->parse(  BREADCRUMB => 'homecrumb') }
	    else                { $tmpl->assign( BREADCRUMB => ($g_name ? $g_name : $crumb)) }
	    $tmpl->assign(BREADCRUMB_LINK => $breadcrumblink);
	    $tmpl->parse('.BREADCRUMB_PATH' => 'breadcrumb');
	}
	$DEBUG=0;
	$tmpl->assign(BREADCRUMB => ( $gallery_name ? $gallery_name : $lastcrumb));
	$tmpl->parse('.BREADCRUMB_PATH' => 'deadcrumb');
	$tmpl->parse(BREADCRUMBS        => 'breadcrumbs');
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

    my $thumbpath = path($path, $dir, $CONFIG{'thumb_dir'});
  SANITARY: { my($tmp) = $thumbpath =~ /^(.*)$/; $thumbpath = $tmp; }

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
	    ## only images are good enough do display in the thumbnail gallery
	    ## (however, images may represent other media with the 'link' field
            ## in the caption.txt file). This algorithm must match image nav
	    next unless $r->lookup_file($fullpath)->content_type =~ m!^image/!;

	    my $fullthumb = path($thumbpath, thumb($file));
	  SANITARY: { my($tmp) = $fullthumb =~ /^(.*)$/; $fullthumb = $tmp; }
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

	    ## check for a link
	    if( ! $CONFIG{'always_link'} && $captions{$file}->[CAP_LINK] ) {
		my $link_path = path($path, $dir, $captions{$file}->[CAP_LINK]);

		## a directory or a recognized media type
		if( -e $link_path && ( -d $link_path ||
				       $r->lookup_file($link_path)->content_type =~ m!^(?:image|video)/! ) ) {
		    $tmpl->assign(URI_IMAGE => $captions{$file}->[CAP_LINK]);
		}

		## link to the image itself
		else {
		    $tmpl->assign(URI_IMAGE => $file);
		}
	    }

	    ## otherwise, link to the image itself
	    else {
		$tmpl->assign(URI_IMAGE => $file);
	    }
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

    ## won't be needing the thumbnail directory...
    TIDY: {
	  local $ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin'; ## FIXME: any others?
	  rmtree($thumbpath, 0, 1) if $empty_gallery;
      }

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

    if( $CONFIG{'other_gallery_links'} ) {
	$tmpl->parse(OTHER_GALLERIES => ( $empty_other
					  ? 'other_empty'
					  : 'other_galleries' ));
    }
    else {
	$tmpl->assign(OTHER_GALLERIES => '');
    }
    $tmpl->parse(MAIN => 'main');
    $r->print($tmpl->to_string('MAIN'));

    return OK;
}

sub show_image {
    return show_file(@_, 'image', q!<img src="{MEDIA_FILE}">!);
}

sub show_mov {
    return show_file(@_, 'mov', <<'_MEDIA_');
<embed src="{MEDIA_FILE}" autostart="true" controller="true" loop="false" pluginspage="http://www.apple.com/quicktime/">
<noembed><a href="{MEDIA_FILE}">Video</a></noembed>
</embed>
_MEDIA_
}

sub show_mpeg {
    return show_file(@_, 'mpeg', <<'_MEDIA_');
<embed src="{MEDIA_FILE}" autostart="true" controller="true" loop="false">
<noembed><a href="{MEDIA_FILE}">Video</a></noembed>
</embed>
_MEDIA_
}

sub show_avi {
    return show_file(@_, 'avi', <<'_MEDIA_');
<embed src="{MEDIA_FILE}" autostart="true" controller="true" loop="false">
<noembed><a href="{MEDIA_FILE}">Video</a></noembed>
</embed>
_MEDIA_
}

sub show_file {
    my $r    = shift;
    my $subr = shift;
    my ($path, $image) = $subr->filename =~ m!^(.*)/([^/]+)$!;
    my $mime = shift || 'image';
  SANITARY: { my($tmp) = $mime =~ /^(.*)$/; $mime = $tmp; }
    my $media_tmpl = shift || q!<img src="{MEDIA_FILE}">!;

    $r->content_type('text/html');
    $r->send_http_header;
    return OK if $r->header_only;

    my $tmpl = new Template::Trivial;
    $tmpl->define_from_string(main => <<_EOF_,
<html>
<head>
<title>{TITLE}</title>
{IMAGE_STYLE}
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
<tr><td colspan="5">{MEDIA}</td></tr>
<tr><td colspan="5">{LINK}{COMMENT}</td></tr>
</table>
</center>
</body>
</html>
_EOF_
			      image_style => <<_EOF_,
<style type="text/css">
<!--
  body {
    font-family: Helvetica, sans-serif, Arial;
    font-size: large;
    background: none;
    color: #000000;
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
    text-decoration: none
  }
  img {
    border: 0
  }
//-->
</style>
_EOF_
			      media      => $media_tmpl,
			      link       => q!<a href="{IMG_LINK}">More</a><br>!,
			      link_empty => '',
			      up         => q!<a href="{UP_LINK}">{UP_DEFAULT}</a>!,
			      up_default => q!Back to<br>Gallery!,
			      first     => q!<a href="{FIRST_LINK}">{FIRST_DEFAULT}</a>!,
			      first_empty   => '',
			      first_default => q!First<br>Image!,
			      first_caption => q!<br>({CAPTION})!,
			      previous      => q!<a href="{PREVIOUS_LINK}">{PREVIOUS_DEFAULT}</a>!,
			      previous_empty => '',
			      previous_default => q!Previous<br>Image!,
			      previous_caption => q!<br>({CAPTION})!,
			      next     => q!<a href="{NEXT_LINK}">{NEXT_DEFAULT}</a>!,
			      next_empty => '',
			      next_default => q!Next<br>Image!,
			      next_caption => q!<br>({CAPTION})!,
			      last     => q!<a href="{LAST_LINK}">{LAST_DEFAULT}</a>!,
			      last_empty => '',
			      last_default => q!Last<br>Image!,
			      last_caption => q!<br>({CAPTION})!,
			     );

  TEMPLATE_DIR: for my $tmpl_dir 
      ( grep { -d }
	map { path($CONFIG{'gallery_path'}, ( $_ 
					      ? $CONFIG{'template_dir'} . ".$_" 
					      : $CONFIG{'template_dir'} ) ) }
	reverse @LANG ) {

	  warn "Reading image templates from '$tmpl_dir'\n" if $DEBUG;

	  $tmpl->templates($tmpl_dir);
	  $tmpl->define(main       => "image_main.txt")
	    if -f path($tmpl_dir, "image_main.txt");
	  $tmpl->define(image_style => "image_style.txt")
	    if -f path($tmpl_dir, "image_style.txt");

	  $tmpl->define(media      => "image_$mime.txt")
	    if -f path($tmpl_dir, "image_$mime.txt");
	  $tmpl->define(link       => 'image_link.txt')
	    if -f path($tmpl_dir, 'image_link.txt');
	  $tmpl->define(link_empty => 'image_link_empty.txt')
	    if -f path($tmpl_dir, 'image_link_empty.txt');

	  $tmpl->define(up         => "image_up.txt")
	    if -f path($tmpl_dir, "image_up.txt");
	  $tmpl->define(up_default => "image_up_default.txt")
	    if -f path($tmpl_dir, "image_up_default.txt");

	  $tmpl->define(first       => "image_first.txt")
	    if -f path($tmpl_dir, "image_first.txt");
	  $tmpl->define(first_empty => "image_first_empty.txt")
	    if -f path($tmpl_dir, "image_first_empty.txt");
	  $tmpl->define(first_default => "image_first_default.txt")
	    if -f path($tmpl_dir, "image_first_default.txt");
	  $tmpl->define(first_caption => "image_first_caption.txt")
	    if -f path($tmpl_dir, "image_first_caption.txt");

	  $tmpl->define(previous => "image_previous.txt")
	    if -f path($tmpl_dir, "image_previous.txt");
	  $tmpl->define(previous_empty => "image_previous_empty.txt")
	    if -f path($tmpl_dir, "image_previous_empty.txt");
	  $tmpl->define(previous_default => "image_previous_default.txt")
	    if -f path($tmpl_dir, "image_previous_default.txt");
	  $tmpl->define(previous_caption => "image_previous_caption.txt")
	    if -f path($tmpl_dir, "image_previous_caption.txt");

	  $tmpl->define(next     => "image_next.txt")
	    if -f path($tmpl_dir, "image_next.txt");
	  $tmpl->define(next_empty => "image_next_empty.txt")
	    if -f path($tmpl_dir, "image_next_empty.txt");
	  $tmpl->define(next_default => "image_next_default.txt")
	    if -f path($tmpl_dir, "image_next_default.txt");
	  $tmpl->define(next_caption => "image_next_caption.txt")
	    if -f path($tmpl_dir, "image_next_caption.txt");

	  $tmpl->define(last     => "image_last.txt")
	    if -f path($tmpl_dir, "image_last.txt");
	  $tmpl->define(last_empty => "image_last_empty.txt")
	    if -f path($tmpl_dir, "image_last_empty.txt");
	  $tmpl->define(last_default => "image_last_default.txt")
	    if -f path($tmpl_dir, "image_last_default.txt");
	  $tmpl->define(last_caption => "image_last_caption.txt")
	    if -f path($tmpl_dir, "image_last_caption.txt");
      }

    ## this is not an image: look it up in the caption file
    my $is_image = 1;
    unless( $subr->content_type =~ m!^image/! ) {
	$image = get_captions($path, undef, $image) || $image;
	undef $is_image;
    }

    ## set template variables
    my($link, $comment) = get_captions($path, $image);
    undef $link unless $is_image;
    if( $link ) { $tmpl->assign(IMG_LINK => $link); $tmpl->parse(LINK => 'link'); }
    else { $tmpl->parse(LINK => 'link_empty'); }

    my $uri = $r->uri; my $loc = $r->location;
    $uri =~ s/^$loc/$CONFIG{'gallery_root'}/;
    if( my($userdir) = $r->uri =~ m!~([^/]+)! ) {
	warn "USERDIR:     $userdir\n" if $DEBUG;
	$uri = "~$userdir/$uri";
    }
    $tmpl->assign(TITLE      => $comment);
    $tmpl->assign(COMMENT    => $comment);
    $tmpl->assign(MEDIA_FILE => "/$uri");     ## uri to actual media file
    $tmpl->parse(MEDIA       => 'media');

    ## parse navigation links
    my $up = $r->uri; $up =~ s!^(.*/)[^/]+$!$1!;
    $tmpl->assign(UP_LINK   => $up);
    $tmpl->parse(UP_DEFAULT => 'up_default');
    $tmpl->parse(DIR_UP     => 'up');
    $tmpl->parse(IMAGE_STYLE => 'image_style');

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

	    ## this algorithm must match thumbnail gallery display for
	    ## gallery and image navigation to stay synchronized
	    my $subreq = $r->lookup_file(path($path, $file));
	    push @files, $file
	      if -f $subreq->finfo() && $subreq->content_type =~ m!^image/!;
	}
	closedir DIR;

	if( my $first = ( @files && $files[0] eq $image ? '' : $files[0] ) ) {
	    unless( $CONFIG{'always_link'} ) {
		$first = (get_captions($path, $files[0]))[CAP_LINK] || $first;
	    }
	    $tmpl->assign(FIRST_LINK => $first);
	    $tmpl->assign(FIRST_CAPTION => '');
	    $tmpl->parse(FIRST_DEFAULT => 'first_default');
	    if( my $caption = get_captions( $path, $first ) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(FIRST_CAPTION => 'first_caption');
	    }
	    $tmpl->parse(IMG_FIRST => 'first');
	}
	else { $tmpl->parse(IMG_FIRST => 'first_empty'); }

	if( my $last = (@files && $files[$#files] eq $image ? '' : $files[$#files]) ) {
	    unless( $CONFIG{'always_link'} ) {
		$last = (get_captions($path, $files[$#files]))[CAP_LINK] || $last;
	    }
	    $tmpl->assign(LAST_LINK => $last);
	    $tmpl->assign(LAST_CAPTION => '');
	    $tmpl->parse(LAST_DEFAULT => 'last_default');
	    if( my $caption = get_captions( $path, $last ) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(LAST_CAPTION => 'last_caption');
	    }
	    $tmpl->parse(IMG_LAST => 'last');
	}
	else { $tmpl->parse(IMG_LAST => 'last_empty'); }

	## $idx is required for $prev and $next calculations
	my $idx = 0; $idx++ while $idx < $#files && $files[$idx] ne $image;

	if( my $prev = ( ($idx-1) < 0 ? '' : $files[$idx-1] ) ) {
	    unless( $CONFIG{'always_link'} ) {
		$prev = (get_captions($path, $files[$idx-1]))[CAP_LINK] || $prev;
	    }
	    $tmpl->assign(PREVIOUS_LINK => $prev);
	    $tmpl->assign(PREVIOUS_CAPTION => '');
	    $tmpl->parse(PREVIOUS_DEFAULT => 'previous_default');
	    if( my $caption = get_captions( $path, $prev ) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(PREVIOUS_CAPTION => 'previous_caption');
	    }
	    $tmpl->parse(IMG_PREV => 'previous'); 
	}
	else { $tmpl->parse(IMG_PREV => 'previous_empty'); }

	if( my $next = ( ($idx+1) > $#files ? '' : $files[$idx+1] ) ) {
	    unless( $CONFIG{'always_link'} ) {
		$next = (get_captions($path, $files[$idx+1]))[CAP_LINK] || $next;
	    }
	    $tmpl->assign(NEXT_LINK => $next);
	    $tmpl->assign(NEXT_CAPTION => '');
	    $tmpl->parse(NEXT_DEFAULT => 'next_default');
	    if( my $caption = get_captions( $path, $next ) ) {
		$tmpl->assign(CAPTION => $caption);
		$tmpl->parse(NEXT_CAPTION => 'next_caption');
	    }
	    $tmpl->parse(IMG_NEXT => 'next');
	}
	else { $tmpl->parse(IMG_NEXT => 'next_empty'); }
    }

    ## process main
    $tmpl->parse(MAIN => 'main');
    $r->print($tmpl->to_string('MAIN'));

    return OK;
}

sub get_captions {
    my $path        = shift;
    my $lookup      = shift;
    my $lookup_link = shift;

    my %captions = ();
    my $lfile    = '';
    my $llink    = '';
    my $lcaption = '';

    ## special case for gallery root in scalar context (I used to have
    ## !wantarray in here instead of "defined $lookup")
    if( defined $lookup && path($path,$lookup) eq $CONFIG{'gallery_path'} ) {
	return ( $CONFIG{'gallery_name'} ? $CONFIG{'gallery_name'} : $lcaption );
    }

  CAPTIONS: for my $caption_file ( map { path($path, ($_ 
						      ? $CONFIG{'caption_file'} . ".$_"
						      : $CONFIG{'caption_file'}) ) }
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
	    next unless $file;

	    ## looking up $file by $link
	    if( $lookup_link && $link ) {
		if( $link eq $lookup_link ) {
		    $lfile = $file;
		    last;
		}

		next;
	    }

	    ## looking up $caption or $link by $file
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

    return $lfile if $lookup_link;
    return ($llink, $lcaption) if $lookup;
    return %captions;
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

B<Gallery::Simple> creates navigable thumbnail galleries from
directories with images on your web server. B<Gallery::Simple> is
completely configurable via a simple template system, allows for image
captions as well as multimedia support, and also allows you to specify
multiple languages for your templates and captions. The rest of this
document is just the details.

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

=item B<LanguageStrict>

Default: no

Values: [yes|no]

Description: when disabled, Gallery::Simple will try (for example)
'en-us' first (assuming 'en-us' were passed in by the browser) and
then fall back to 'en' (the major language type).

If B<LanguageStrict> is set to 'yes', only languages explicitly passed
in by the browser will be attempted (e.g., in our above example, 'en'
would not be tried if 'en-us' were not found).

=item B<OtherGalleryLinks>

Default: on

Values: [on|off]

Description: when disabled, no "Other galleries" message will display
showing sub-galleries within this directory. You may still access
sub-galleries using the F<caption.txt> file (see L<"Sub-Gallery
Thumbnails"> under L<"CAPTION FILES">).

=item B<AlwaysLink>

Default: no

Values: [yes|no]

Description: when enabled, non-image media files (e.g., movies, etc.)
will simply appear as a link below the image on the representative
image page. When disabled, thumbnails and image navigation links will
load a page with the multimedia file embedded (as if it were an
image).

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
of it and use that as your representative image.

Once you've uploaded the media file and a representative image, you'll
then need to create a file called F<caption.txt> in the same directory
you uploaded the image to.  The file should contain a line like the
following:

    picnic.jpg:picnic.mov:First Summer Picnic

F<picnic.jpg> is the name of your representative image; F<picnic.mov>
is your movie file (followed by the caption). Now when people browse
your gallery, they'll see F<picnic.jpg> in the thumbnail gallery. If
they click the image, they'll be taken to a page that contains
F<picnic.mov> as an embedded movie.

[If B<AlwaysLink> is enabled, a larger version of the representative
image is shown, just as a normal image would, but there will also be
a link beneath the image which links to the alternative media file.]

For more information about the caption file see L<"CAPTION FILES">. For
more information about customizing the look of the gallery, see
L<"TEMPLATES">.

=head1 CAPTION FILES

The format of a caption file is this:

  imagename:linkname:some caption text

I<imagename> is the name of the image (in this directory) that the
caption relates to. I<imagename> is case-sensitive. I<linkname> is
optional.

I<linkname> is a link where another media file (such as a Quicktime
movie, mpeg file, or even a sub-directory) may be found (the file or
directory must be in the same directory as the caption.txt file it is
referenced in).

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
"sub-gallery". The 'linkname' space is empty ("::") and is currently
not used with sub-galleries. The directory will appear with the link
"January 2003" instead of just "January".

=item melissa.jpg

This image has no alternative media--the 'linkname' space is empty
("::"). This image does have a comment (caption): "Melissa shakes
hands with Tom".

=item jared.jpg

This image is like the previous one: no alternative media, but it does
have a caption.

=item PB140011.JPG

This image is not mentioned in the caption file--no caption will be
printed for this image.

=item joe_tabasco.jpg

A thumbnail of this image will appear in the gallery (thumbnail) page;
when the thumbnail link is followed, a page with a movie file
(F<joe_burns.mov>) will appear along with the caption "Joe eating
Tabasco sauce".

=back

=head2 Sub-Gallery Thumbnails

Another interesting use for the 'linkname' space is that you can
create picture representations of sub-galleries. For example, consider
this entry:

    vacation.png:vacation-2001/:2001 Summer Vacation Photos

When someone clicks the F<vacation.png> thumbnail, they'll be taken
not to the F<vacation.png> image (if the 'linkname' space did not
reference a directory), but to a sub-gallery named F<vacation-2001>.

You don't I<need> to do sub-galleries this way, of course. It is done
automatically for you with links on the left side of the screen under
"Other galleries", but this provides yet another (graphical) way to
do it.

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
templates to achieve a new gallery and image page look. Please refer
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
    <title>{GALLERY_NAME}</title>
    {GALLERY_STYLE}
    </head>
    
    <body>
    {GALLERY_TITLE}
    {BREADCRUMBS}
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
    {GALLERY_FOOTER}
    </body>
    </html>

Variables: GALLERY_NAME, GALLERY_TITLE, GALLERY_STYLE, BREADCRUMBS,
OTHER_GALLERIES, DIR_FIRST, DIR_PREV, DIR_NEXT, DIR_LAST, GALLERY

=item F<gallery_title.txt>

Default value: (empty)

Variables: GALLERY_NAME

=item F<gallery_title_empty.txt>

Default value: (empty)

=item F<gallery_style.txt>

Default value:

    <style type="text/css">
    <!--
      body {
	font-family: Helvetica, sans-serif, Arial;
	font-size: large;
	color: #000000;
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
      }
      .galleries {
        font-size: x-small;
        background: none;
      }
      .address {
	text-align: right;
	font-size: xx-small;
      }
    //-->
    </style>

=item F<gallery_footer.txt>

Default value:

    <hr>
    <div class="address">
      <a href="http://scott.wiersdorf.org/perl/Apache-App-Gallery-Simple/">Apache::App::Gallery::Simple {VERSION}</a>
    </div>

Variables: VERSION

=item F<gallery_other.txt>

Default value:

    <p class="galleries">Other galleries within this gallery:<br>
    {DIRECTORIES}</p>

Variables: DIRECTORIES

=item F<gallery_other_empty.txt>

Default value:

    <p class="galleries">(No other galleries within this gallery)</p>

=item F<gallery_breadcrumbs.txt>

Default value:

    <p class="breadcrumb">This gallery: {BREADCRUMB_PATH}</p>

=item F<gallery_breadcrumb.txt>

Default value:

    &nbsp;<a href="{BREADCRUMB_LINK}">{BREADCRUMB}</a>&nbsp;-&gt;

Variables: BREADCRUMB_LINK, BREADCRUMB

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

=item BREADCRUMBS

Parsed (F<gallery_breadcrumbs.txt>).

=item BREADCRUMB_PATH

Assigned. The path of directories up to the top level gallery as
links. The current gallery is not a link.

=item BREADCRUMB

Assigned/parsed (F<gallery_homecrumb.txt>). Part of the top level
breadcrumb navigation; iteratively set to each path component (i.e.,
each directory name) up to the home directory.  If a higher level
directory has a caption in the B<caption file>, this caption will be
used instead.

=item BREADCRUMB_LINK

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

=item GALLERY_NAME

Parsed (F<gallery_style.txt>).

=item GALLERY_FOOTER

Parsed (F<gallery_footer.txt>).

=item VERSION

Assigned. Set to the current version of Apache::App::Gallery::Simple.

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
    {IMAGE_STYLE}
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
    <tr><td colspan="5">{MEDIA}</td></tr>
    <tr><td colspan="5">{LINK}{COMMENT}</td></tr>
    </table>
    </center>
    </body>
    </html>

Variables: TITLE, IMG_FIRST, IMG_PREV, DIR_UP, IMG_NEXT, IMG_LAST,
MEDIA, LINK, COMMENT

=item F<image_media.txt>

FIXME

=item F<image_style.txt>

Default value:

    <style type="text/css">
    <!--
      body {
	font-family: Helvetica, sans-serif, Arial;
	font-size: large;
	background: none;
	color: #000000;
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
	text-decoration: none
      }
      img {
	border: 0
      }
    //-->
    </style>

=item F<image_image.txt>

Default value:

    <img src="{MEDIA_FILE}">

Variables: MEDIA_FILE

=item F<image_mov.txt>

Default value:

    <embed src="{MEDIA_FILE}" autostart="true" controller="true"
    loop="false" pluginspage="http://www.apple.com/quicktime/">
    <noembed><a href="{MEDIA_FILE}">Video</a></noembed>
    </embed>

Variables: MEDIA_FILE

=item F<image_mpeg.txt>

Default value:

    <embed src="{MEDIA_FILE}" autostart="true" controller="true"
    loop="false">
    <noembed><a href="{MEDIA_FILE}">Video</a></noembed>
    </embed>

Variables: MEDIA_FILE

=item F<image_avi.txt>

Default value:

    <embed src="{MEDIA_FILE}" autostart="true" controller="true"
    loop="false">
    <noembed><a href="{MEDIA_FILE}">Video</a></noembed>
    </embed>

Variables: MEDIA_FILE

=item F<image_link.txt>

Default value:

    <a href="{IMG_LINK}">More</a><br>

Variables: IMG_LINK

=item F<image_link_empty.txt>

Default value: (empty)

=item F<image_up.txt>

Default value:

    <a href="{UP_LINK}">{UP_DEFAULT}</a>

Variables: UP

=item F<image_up_default.txt>

Default value:

    Back to<br>Gallery

=item F<image_first.txt>

Default value:

    <a href="{FIRST_LINK}">{FIRST_DEFAULT}</a>

Variables: FIRST_LINK, FIRST_DEFAULT, FIRST_CAPTION

=item F<image_first_empty.txt>

Default value: (empty)

=item F<first_default>

Default value:

    First<br>Image

=item F<first_caption>

Default value:

    <br>({CAPTION})

Variables: CAPTION

=item F<image_previous.txt>

Default value:

    <a href="{PREVIOUS_LINK}">{PREVIOUS_DEFAULT}</a>

Variables: PREVIOUS_LINK, PREVIOUS_DEFAULT, PREVIOUS_CAPTION

=item F<image_previous_empty.txt>

Default value: (empty)

=item F<image_previous_default.txt>

Default value:

    Previous<br>Image

=item F<image_previous_caption.txt>

Default value:

    <br>({CAPTION})

=item F<image_next.txt>

Default value:

    <a href="{NEXT_LINK}">{NEXT_DEFAULT}</a>

Variables: NEXT_LINK, NEXT_DEFAULT, NEXT_CAPTION

=item F<image_next_empty.txt>

Default value: (empty)

=item F<image_next_default.txt>

Default value:

    Next<br>Image

=item F<image_next_caption.txt>

Default value:

    <br>({CAPTION})

Variables: CAPTION

=item F<image_last.txt>

Default value:

    <a href="{LAST_LINK}">{LAST_DEFAULT}</a>

Variables: LAST_LINK, LAST_DEFAULT, LAST_CAPTION

=item F<image_last_empty.txt>

Default value: (empty)

=item F<image_last_default.txt>

Default value:

    Last<br>Image

=item F<image_last_caption.txt>

Default value:

    <br>({CAPTION})

Variables: CAPTION

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

=item IMAGE_STYLE

Parsed (F<image_style.txt>).

MEDIA_FILE

Assigned. Set to the real URI of the media file.

IMG_FIRST

Parsed (F<image_first.txt>, F<image_first_empty.txt>).

IMG_PREV

Analogous to IMG_FIRST.

IMG_NEXT

Analogous to IMG_FIRST.

IMG_LAST

Analogous to IMG_FIRST.

IMG_LINK

Assigned. Set to the link field of the caption file, if applicable.

DIR_UP

Parsed (F<image_up.txt>).

UP_LINK

Assigned. Set to the parent URI of the current image.

UP_DEFAULT

Parsed (F<image_up_default.txt>).

FIRST_LINK

Assigned. Set to the first image URI in this gallery.

FIRST_DEFAULT

Parsed (F<image_first_default.txt>).

FIRST_CAPTION

Parsed (F<image_first_caption.txt>).

PREVIOUS_LINK

Analogous to FIRST_LINK

PREVIOUS_DEFAULT

Analogous to FIRST_DEFAULT

PREVIOUS_CAPTION

Analogous to FIRST_CAPTION

NEXT_LINK

Analogous to FIRST_LINK

NEXT_DEFAULT

Analogous to FIRST_DEFAULT

NEXT_CAPTION

Analogous to FIRST_CAPTION

LAST_LINK

Analogous to FIRST_LINK

LAST_DEFAULT

Analogous to FIRST_DEFAULT

LAST_CAPTION

Analogous to FIRST_CAPTION

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

=head2 Template Changes Required for Multi-language Support

Every effort has been made to make adding additional languages to your
gallery as painless as possible. To that end, all English text has
been placed into small sets of small files.

To add Spanish support, for example, you would create F<.templates.es>
and change the template sets listed below. The default contents of
these templates may be found elsewhere in this document.

The following B<gallery> templates must be changed for multi-language
support:

=over 4

=item F<gallery_breadcrumbs.txt>

=item F<gallery_first_default.txt>

=item F<gallery_last_default.txt>

=item F<gallery_next_default.txt>

=item F<gallery_other.txt>

=item F<gallery_other_empty.txt>

=item F<gallery_previous_default.txt>

=back

The following B<image> templates must be changed for multi-language
support:

=over 4

=item F<image_first_default.txt>

=item F<image_last_default.txt>

=item F<image_next_default.txt>

=item F<image_previous_default.txt>

=item F<image_up_default.txt>

=back

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

=head2 (Second favorite language) templates show up even though my default is set to English (and I am using the built-in Gallery::Simple templates)

This is the nature of the template system; to ensure that alternative
templates are not attempted, create English templates in
F<.templates>--the same templates you used in your second favorite
language.

Gallery::Simple will detect these templates and use them and not
attempt to find other templates.

If this seems like a lot of work, you can also simply remove your
second favorite language from your browser preferences.

If I get enough complaints about this, I'm likely to create an Apache
directive that will stop at the default templates if they match the
browser's language preference.

=head2 I don't like you you've done style sheets

I'm happy to receive criticism on my style sheets. I'm just learning
how they work, so they'll likely contain bad, uh, style. I did put
them in their own template, though, so they're easy enough to change.

=head2 I don't like the "No other galleries within this gallery" message

Create a F<.templates> directory at your gallery root and create an
empty file named F<gallery_other_empty.txt>.

=head2 I really don't like the "No other galleries ..." message

Use the B<OtherGalleryLinks> directive to disable all mention of
sub-galleries (even if they exist).

=head2 Slow!

The first time a gallery is visited, all of the images must be
"thumbnailed" (a copy of the image is reduced to a smaller size); this
operation is somewhat slow, especially if you're waiting for it to
happen in a browser.

Once this thumbnailing has taken place, however, the thumbnails will
only have to be re-created if you alter the original image in some
way, in which case Gallery::Simple will detect it and re-thumbnail the
altered image.

=head2 I get an error when I update an image and then try to view the gallery

There was a bug in versions prior to 1.06 that triggered Perl's taint
warning; update Gallery::Simple and all should be well (versions prior
to 1.03 may have template compatibility issues if you have customized
templates. If you don't have customized templates, you should not have
a problem).

=head2 I can't delete the thumbnail directory, or anything in it

This is because your UID is different than your web server's. You have
some options:

=over 4

=item *

become the UID of the web server (e.g., via 'su' or some other
mechanism)

=item *

run a CGI script under the UID of the web server that removes the
directory

=item *

create the thumbnail directory beforehand as your user (too late now,
of course); then you'll own it and can delete it whenever you want to

=item *

Upgrade to version 1.06 or later of this module. This will cause
thumbnail directories to be deleted from otherwise empty galleries
(i.e., galleries with no images)

=back

=head1 SUPPORT

Additional documentation, alternative look template sets, alternative
language template sets, and mailing list available at:

    http://scott.wiersdorf.org/perl/Apache-App-Gallery-Simple/

=head1 CAVEATS

=over 4

=item *

'&' in your caption.txt files should be replaced with '&amp;' <'
should be replaced with '&lt;'

=item *

The thumbnail directory must be writable by the UID that Apache runs
under (usually I<www> or I<nobody>) in order for thumbnails to be
written to disk. If the thumbnail directory does not exist, its parent
directory must also be writable by Apache's UID.

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

## todo
## - if the browser lang pref matches the default gallery lang, stop
##   looking for alternative languages
