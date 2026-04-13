#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use Fcntl qw(:DEFAULT :flock);
use POSIX qw(strftime);
use Gtk3;
use Glib qw(TRUE FALSE);

my $APP_NAME      = 'Panther';
my $APP_ID        = 'panther';
my $APP_VERSION   = '1.0.0';
my $SYSTEM_CONF   = '/etc/panther/panther.conf';
my $FALLBACK_SIZE = [1920, 1080];
my $MAX_SCAN      = 800;
my $MAX_DEPTH     = 3;

my %MODE_META = (
    fill   => {
        title => 'Fill the screen',
        help  => 'Keeps the image shape and fills the screen. Small parts near the edges may be cropped.',
    },
    max    => {
        title => 'Fit inside the screen',
        help  => 'Keeps the image shape and shows the full picture. Empty space may appear on one side.',
    },
    center => {
        title => 'Keep it in the middle',
        help  => 'Keeps the original size and places the image in the middle of the screen.',
    },
    scale  => {
        title => 'Stretch to the screen',
        help  => 'Uses the whole screen but may stretch the picture shape.',
    },
    tile   => {
        title => 'Repeat the image',
        help  => 'Repeats the image across the screen like tiles.',
    },
);

my %STYLE_META = (
    solid   => {
        title => 'Solid color',
        help  => 'A calm single-color background.',
    },
    stripes => {
        title => 'Soft stripes',
        help  => 'Gentle vertical stripes using two colors.',
    },
    checker => {
        title => 'Checker pattern',
        help  => 'A simple square pattern using two colors.',
    },
    dots    => {
        title => 'Dots',
        help  => 'A subtle dotted background using two colors.',
    },
);

my $HOME            = $ENV{HOME} || ((getpwuid($<))[7] || '.');
my $XDG_CONFIG_HOME = $ENV{XDG_CONFIG_HOME} || File::Spec->catdir($HOME, '.config');
my $XDG_CACHE_HOME  = $ENV{XDG_CACHE_HOME}  || File::Spec->catdir($HOME, '.cache');
my $CONFIG_DIR      = File::Spec->catdir($XDG_CONFIG_HOME, $APP_ID);
my $CACHE_DIR       = File::Spec->catdir($XDG_CACHE_HOME,  $APP_ID);
my $STATE_FILE      = File::Spec->catfile($CONFIG_DIR, 'panther.conf');
my $THUMB_DIR       = File::Spec->catdir($CACHE_DIR,  'thumbs');
my $STYLE_DIR       = File::Spec->catdir($CACHE_DIR,  'styles');
my $ICON_CACHE      = File::Spec->catdir($CACHE_DIR,  'icons');
my $FEHBG           = File::Spec->catfile($HOME, '.fehbg');

my %UI;
my %RUNTIME;

sub friendly_stderr_and_exit {
    my ($text) = @_;
    print STDERR "$APP_NAME: $text\n";
    exit 1;
}

if (!$ENV{DISPLAY}) {
    friendly_stderr_and_exit('This app needs a graphical X11 session to open. Please start it from your desktop session.');
}

my $gtk_ready = eval { Gtk3->init; 1 };
if (!$gtk_ready) {
    friendly_stderr_and_exit('A graphical GTK session is not ready yet. Please open Panther from your Artix X11 desktop.');
}

sub ensure_dirs {
    for my $dir ($CONFIG_DIR, $CACHE_DIR, $THUMB_DIR, $STYLE_DIR, $ICON_CACHE) {
        next if -d $dir;
        make_path($dir, { mode => 0755 });
    }
}

sub command_path {
    my ($name) = @_;
    return undef if !$name;
    for my $dir (split /:/, ($ENV{PATH} || '')) {
        my $path = File::Spec->catfile($dir, $name);
        return $path if -x $path;
    }
    return undef;
}

sub uniq_paths {
    my %seen;
    my @out;
    for my $path (@_) {
        next if !defined $path || $path eq '';
        my $real = abs_path($path) || $path;
        next if $seen{$real}++;
        push @out, $real;
    }
    return @out;
}

sub trim {
    my ($text) = @_;
    return '' if !defined $text;
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return $text;
}

sub escape_value {
    my ($text) = @_;
    $text //= '';
    $text =~ s/\\/\\\\/g;
    $text =~ s/\n/\\n/g;
    $text =~ s/\r/\\r/g;
    return $text;
}

sub unescape_value {
    my ($text) = @_;
    $text //= '';
    $text =~ s/\\n/\n/g;
    $text =~ s/\\r/\r/g;
    $text =~ s/\\\\/\\/g;
    return $text;
}

sub read_kv_file {
    my ($path) = @_;
    my %cfg = (folder => [], disabled_folder => []);
    return \%cfg if !$path || !-f $path;

    if (open my $fh, '<', $path) {
        while (my $line = <$fh>) {
            chomp $line;
            next if $line =~ /^\s*#/;
            next if $line !~ /=/;
            my ($key, $value) = split(/=/, $line, 2);
            $key   = trim($key);
            $value = unescape_value($value);
            next if $key eq '';
            if ($key eq 'folder' || $key eq 'disabled_folder') {
                push @{ $cfg{$key} }, $value;
            } else {
                $cfg{$key} = $value;
            }
        }
        close $fh;
    }
    return \%cfg;
}

sub write_kv_file {
    my ($path, $cfg) = @_;
    my $dir = dirname($path);
    make_path($dir, { mode => 0755 }) if !-d $dir;
    my $tmp = "$path.tmp.$$";

    open my $fh, '>', $tmp or return (0, "Could not write $tmp");
    print {$fh} "# Panther state\n";
    print {$fh} "version=1\n";
    for my $key (sort keys %{$cfg}) {
        next if $key eq 'folder' || $key eq 'disabled_folder';
        next if ref $cfg->{$key};
        my $value = escape_value($cfg->{$key});
        print {$fh} "$key=$value\n";
    }
    for my $folder (@{ $cfg->{folder} || [] }) {
        print {$fh} 'folder=' . escape_value($folder) . "\n";
    }
    for my $folder (@{ $cfg->{disabled_folder} || [] }) {
        print {$fh} 'disabled_folder=' . escape_value($folder) . "\n";
    }
    close $fh or return (0, "Could not finish writing $tmp");

    rename $tmp, $path or return (0, "Could not replace $path");
    return (1, undef);
}

sub default_system_config {
    return {
        system_folder  => [
            '/usr/share/backgrounds',
            '/usr/share/wallpapers',
            '/usr/local/share/backgrounds',
            '/usr/share/pixmaps',
            '/var/lib/panther/shared',
        ],
        shared_folder  => '/var/lib/panther/shared',
        default_type   => '',
        default_path   => '',
        default_mode   => 'fill',
        default_bg_color => '#000000',
        default_pattern  => 'solid',
        default_color1   => '#1F2937',
        default_color2   => '#111827',
    };
}

sub read_system_config {
    my $base = default_system_config();
    my $cfg  = read_kv_file($SYSTEM_CONF);
    my %merged = %{$base};
    for my $key (keys %{$cfg}) {
        if ($key eq 'folder') {
            $merged{system_folder} = [ uniq_paths(@{ $cfg->{folder} || [] }) ] if @{ $cfg->{folder} || [] };
        } elsif ($key ne 'disabled_folder') {
            $merged{$key} = $cfg->{$key};
        }
    }
    $merged{system_folder} = [ uniq_paths(@{ $merged{system_folder} || [] }) ];
    return \%merged;
}

sub read_user_state {
    my $cfg = read_kv_file($STATE_FILE);
    $cfg->{folder} ||= [];
    $cfg->{disabled_folder} ||= [];
    $cfg->{mode} ||= 'fill';
    $cfg->{bg_color} ||= '#000000';
    $cfg->{style_kind} ||= 'solid';
    $cfg->{style_color1} ||= '#1F2937';
    $cfg->{style_color2} ||= '#111827';
    return $cfg;
}

sub common_user_folders {
    return uniq_paths(
        File::Spec->catdir($HOME, 'Pictures'),
        File::Spec->catdir($HOME, 'Pictures', 'Wallpapers'),
        File::Spec->catdir($HOME, 'Wallpapers'),
        File::Spec->catdir($HOME, '.wallpapers'),
    );
}

sub active_folders {
    my ($system_cfg, $user_cfg) = @_;
    my %disabled = map { (abs_path($_) || $_) => 1 } @{ $user_cfg->{disabled_folder} || [] };
    my @folders = uniq_paths(
        @{ $system_cfg->{system_folder} || [] },
        common_user_folders(),
        @{ $user_cfg->{folder} || [] },
    );
    @folders = grep { !$disabled{ abs_path($_) || $_ } } @folders;
    return @folders;
}

sub image_extension_ok {
    my ($path) = @_;
    return $path =~ /\.(?:jpg|jpeg|png|bmp|gif|webp|tif|tiff|xpm|ppm|pgm|pbm)\z/i;
}

sub friendly_name {
    my ($path) = @_;
    return '' if !defined $path || $path eq '';
    my $name = basename($path);
    $name =~ s/\.[^.]+\z//;
    $name =~ s/[_-]+/ /g;
    $name =~ s/\s+/ /g;
    $name = trim($name);
    return $name || basename($path);
}

sub short_path {
    my ($path) = @_;
    return '' if !defined $path;
    my $out = $path;
    $out =~ s/^\Q$HOME\E\//~\//;
    $out =~ s/^\Q$HOME\E\b/~/;
    return $out;
}

sub fallback_icon_pixbuf {
    my ($size) = @_;
    $size ||= 96;
    my $pix;
    eval {
        $pix = Gtk3::IconTheme->get_default->load_icon('image-x-generic', $size, []);
        1;
    };
    return $pix if $pix;
    return undef;
}

sub load_scaled_pixbuf {
    my ($path, $w, $h) = @_;
    return undef if !$path || !-r $path;
    my $pix;
    eval {
        $pix = Gtk3::Gdk::Pixbuf->new_from_file_at_scale($path, $w, $h, TRUE);
        1;
    };
    return $pix;
}

sub file_dimensions {
    my ($path) = @_;
    my @info;
    eval {
        @info = Gtk3::Gdk::Pixbuf::get_file_info($path);
        1;
    };
    return (0, 0) if !@info;
    return ($info[1] || 0, $info[2] || 0);
}

sub scan_one_dir {
    my ($dir, $depth, $bucket, $seen, $folder_stats, $top) = @_;
    return if $depth > $MAX_DEPTH;
    return if !$dir || !-d $dir;

    my $dh;
    if (!opendir($dh, $dir)) {
        $folder_stats->{$top}{unreadable} = 1;
        return;
    }

    while (my $entry = readdir($dh)) {
        next if $entry eq '.' || $entry eq '..';
        my $path = File::Spec->catfile($dir, $entry);
        next if -l $path && !-e $path;

        if (-d $path) {
            scan_one_dir($path, $depth + 1, $bucket, $seen, $folder_stats, $top);
            next;
        }
        next if !-f $path;
        next if !-r $path;
        next if !image_extension_ok($path);

        my $real = abs_path($path) || $path;
        next if $seen->{$real}++;
        push @{ $bucket->{$top} }, $real;

        my $size = -s $real || 0;
        my ($w, $h) = file_dimensions($real);
        $folder_stats->{$top}{images}++;
        $folder_stats->{$top}{large}++      if $size > (8 * 1024 * 1024) || $w > 3840 || $h > 2160;
        $folder_stats->{$top}{widescreen}++ if $w && $h && ($w / $h) >= 1.60;
        my $stem = lc friendly_name($real);
        $folder_stats->{$top}{names}{$stem}++;
    }
    closedir $dh;
}

sub scan_images {
    my (@folders) = @_;
    my %bucket;
    my %seen;
    my %stats;

    for my $folder (@folders) {
        my $real = abs_path($folder) || $folder;
        $stats{$real} = {
            exists      => (-e $folder ? 1 : 0),
            readable    => (-r $folder ? 1 : 0),
            directory   => (-d $folder ? 1 : 0),
            images      => 0,
            large       => 0,
            widescreen  => 0,
            unreadable  => 0,
            names       => {},
        };
        next if !-d $folder || !-r $folder;
        scan_one_dir($folder, 0, \%bucket, \%seen, \%stats, $real);
    }

    my @all;
    for my $folder (@folders) {
        my $real = abs_path($folder) || $folder;
        push @all, @{ $bucket{$real} || [] };
    }
    @all = sort @all;

    my %dup_name;
    for my $folder (keys %stats) {
        for my $name (keys %{ $stats{$folder}{names} || {} }) {
            $dup_name{$name}++ if $stats{$folder}{names}{$name} > 0;
        }
    }

    return {
        all_images    => \@all,
        per_folder    => \%bucket,
        folder_stats  => \%stats,
        duplicate_map => \%dup_name,
    };
}

sub status_text {
    my ($level, $text) = @_;
    $level ||= 'info';
    my %prefix = (
        info    => 'Ready',
        warn    => 'Attention',
        ok      => 'Done',
        error   => 'Problem',
    );
    $UI{status_label}->set_text(($prefix{$level} || 'Panther') . ': ' . ($text || '')) if $UI{status_label};
}

sub report_folder_health {
    my ($scan) = @_;
    my @lines;
    my @folders = @{ $RUNTIME{folders} || [] };
    my $total_images = scalar @{ $scan->{all_images} || [] };

    if (!$total_images) {
        push @lines, 'We could not find any usable pictures yet.';
        push @lines, 'You can add a folder with pictures, or use the simple style tab for colors and patterns.';
    } else {
        push @lines, "We found $total_images usable picture" . ($total_images == 1 ? '' : 's') . '.';
    }

    for my $folder (@folders) {
        my $real = abs_path($folder) || $folder;
        my $st   = $scan->{folder_stats}{$real} || {};
        my $nice = short_path($real);

        if (!$st->{exists}) {
            push @lines, "$nice is listed, but it does not exist right now.";
            next;
        }
        if (!$st->{directory}) {
            push @lines, "$nice is not a folder.";
            next;
        }
        if (!$st->{readable} || $st->{unreadable}) {
            push @lines, "$nice is there, but Panther cannot read it yet.";
            next;
        }
        if (!$st->{images}) {
            push @lines, "$nice is ready, but it does not contain usable pictures yet.";
            next;
        }
        if ($st->{images} < 3) {
            push @lines, "$nice has only a few pictures so far.";
        } else {
            push @lines, "$nice looks like a good wallpaper folder.";
        }
        push @lines, "$nice includes some extra-large pictures." if $st->{large};
        push @lines, "$nice includes widescreen-friendly pictures." if $st->{widescreen};
    }

    my $dup_count = 0;
    for my $name (keys %{ $scan->{duplicate_map} || {} }) {
        $dup_count++ if $scan->{duplicate_map}{$name} > 1;
    }
    push @lines, 'Some pictures seem to have very similar names, so you may want to keep only your favorites.' if $dup_count;

    my $buffer = $UI{folder_buffer};
    $buffer->set_text(join("\n", @lines));
}

sub parse_fehbg {
    return undef if !-f $FEHBG;
    open my $fh, '<', $FEHBG or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;

    my ($mode) = $content =~ /--bg-(fill|max|center|scale|tile)\b/;
    my ($bg1, $bg2, $bg3) = $content =~ /--image-bg\s+(?:'([^']+)'|"([^"]+)"|(#[0-9A-Fa-f]{3,8}|[A-Za-z]+))/;
    my $bg = defined $bg1 ? $bg1 : defined $bg2 ? $bg2 : defined $bg3 ? $bg3 : '#000000';

    my @quoted;
    while ($content =~ /(['"])(.*?)\1/gms) {
        push @quoted, $2;
    }
    my @images = grep { image_extension_ok($_) } @quoted;
    my $path = $images[-1] || '';

    return undef if !$path;
    return {
        source_type => 'image',
        path        => $path,
        mode        => ($mode || 'fill'),
        bg_color    => $bg,
        title       => friendly_name($path),
    };
}

sub style_output_size {
    my $screen;
    my ($w, $h) = @$FALLBACK_SIZE;
    eval {
        $screen = Gtk3::Gdk::Screen::get_default();
        1;
    };
    if ($screen) {
        eval {
            $w = $screen->get_width  if $screen->get_width;
            $h = $screen->get_height if $screen->get_height;
            1;
        };
    }
    $w = 1920 if !$w || $w < 320;
    $h = 1080 if !$h || $h < 240;
    return ($w, $h);
}

sub hex_to_rgb {
    my ($hex) = @_;
    $hex ||= '#000000';
    $hex =~ s/^#//;
    if (length($hex) == 3) {
        $hex = join('', map { $_ . $_ } split //, $hex);
    }
    return (0, 0, 0) if $hex !~ /^[0-9A-Fa-f]{6}$/;
    return map { hex($_) } ($hex =~ /(..)(..)(..)/);
}

sub write_ppm_style {
    my ($path, $kind, $c1, $c2, $w, $h) = @_;
    $kind ||= 'solid';
    $c1   ||= '#1F2937';
    $c2   ||= '#111827';
    $w    ||= 1920;
    $h    ||= 1080;

    my ($r1, $g1, $b1) = hex_to_rgb($c1);
    my ($r2, $g2, $b2) = hex_to_rgb($c2);
    my $tmp = "$path.tmp.$$";

    open my $fh, '>:raw', $tmp or return (0, "Could not create $tmp");
    print {$fh} "P6\n$w $h\n255\n";

    for my $y (0 .. $h - 1) {
        my $row = '';
        for my $x (0 .. $w - 1) {
            my ($r, $g, $b) = ($r1, $g1, $b1);
            if ($kind eq 'stripes') {
                my $band = int($x / 24) % 2;
                ($r, $g, $b) = $band ? ($r2, $g2, $b2) : ($r1, $g1, $b1);
            } elsif ($kind eq 'checker') {
                my $cell = (int($x / 48) + int($y / 48)) % 2;
                ($r, $g, $b) = $cell ? ($r2, $g2, $b2) : ($r1, $g1, $b1);
            } elsif ($kind eq 'dots') {
                my $base = (int($x / 28) + int($y / 28)) % 2;
                ($r, $g, $b) = $base ? ($r1, $g1, $b1) : ($r2, $g2, $b2);
                my $dx = $x % 28;
                my $dy = $y % 28;
                my $dist = (($dx - 14) * ($dx - 14)) + (($dy - 14) * ($dy - 14));
                ($r, $g, $b) = ($r2, $g2, $b2) if $dist < 28;
            }
            $row .= pack('C3', $r, $g, $b);
        }
        print {$fh} $row;
    }

    close $fh or return (0, "Could not finish $tmp");
    rename $tmp, $path or return (0, "Could not replace $path");
    return (1, undef);
}

sub ensure_style_file {
    my (%cfg) = @_;
    my ($w, $h) = style_output_size();
    my $kind = $cfg{style_kind} || 'solid';
    my $path = File::Spec->catfile($STYLE_DIR, 'current-style.ppm');
    my ($ok, $err) = write_ppm_style($path, $kind, $cfg{style_color1}, $cfg{style_color2}, $w, $h);
    return (undef, $err) if !$ok;
    return ($path, undef);
}

sub ensure_style_preview {
    my (%cfg) = @_;
    my $path = File::Spec->catfile($STYLE_DIR, 'preview-style.ppm');
    my ($ok, $err) = write_ppm_style($path, $cfg{style_kind}, $cfg{style_color1}, $cfg{style_color2}, 900, 500);
    return (undef, $err) if !$ok;
    return ($path, undef);
}

sub mode_key_from_combo {
    my $idx = $UI{mode_combo}->get_active;
    my @keys = qw(fill max center scale tile);
    return $keys[$idx >= 0 ? $idx : 0] || 'fill';
}

sub style_key_from_combo {
    my $idx = $UI{style_combo}->get_active;
    my @keys = qw(solid stripes checker dots);
    return $keys[$idx >= 0 ? $idx : 0] || 'solid';
}

sub rgba_from_hex {
    my ($hex) = @_;
    my $rgba;
    eval {
        $rgba = Gtk3::Gdk::RGBA::parse($hex);
        1;
    };
    return $rgba;
}

sub set_color_button_hex {
    my ($button, $hex) = @_;
    my $rgba = rgba_from_hex($hex);
    return if !$rgba;
    eval { $button->set_rgba($rgba); 1; };
}

sub color_button_hex {
    my ($button) = @_;
    my $rgba = eval { $button->get_rgba };
    return '#000000' if !$rgba;
    my $r = int(($rgba->red   || 0) * 255 + 0.5);
    my $g = int(($rgba->green || 0) * 255 + 0.5);
    my $b = int(($rgba->blue  || 0) * 255 + 0.5);
    return sprintf('#%02X%02X%02X', $r, $g, $b);
}

sub current_selection_cfg {
    my %cfg;
    my $page = $UI{source_notebook}->get_current_page;
    if ($page == 1) {
        $cfg{source_type}  = 'generated';
        $cfg{style_kind}   = style_key_from_combo();
        $cfg{style_color1} = color_button_hex($UI{style_color1});
        $cfg{style_color2} = color_button_hex($UI{style_color2});
        $cfg{mode}         = 'fill';
        $cfg{bg_color}     = $cfg{style_color1};
        $cfg{title}        = $STYLE_META{ $cfg{style_kind} }{title};
    } else {
        $cfg{source_type} = 'image';
        $cfg{path}        = $RUNTIME{selected_image} || '';
        $cfg{mode}        = mode_key_from_combo();
        $cfg{bg_color}    = color_button_hex($UI{border_color});
        $cfg{title}       = friendly_name($cfg{path});
    }
    return \%cfg;
}

sub preview_target_size {
    my ($w, $h) = (860, 480);

    if ($UI{preview_scroller}) {
        eval {
            my $aw = $UI{preview_scroller}->get_allocated_width;
            my $ah = $UI{preview_scroller}->get_allocated_height;
            $w = $aw - 24 if $aw && $aw > 80;
            $h = $ah - 24 if $ah && $ah > 80;
            1;
        };
    }

    if ((!$w || $w < 80 || !$h || $h < 80) && $UI{window}) {
        eval {
            my ($ww, $wh) = $UI{window}->get_size;
            $w = int($ww * 0.42) if $ww && $ww > 300;
            $h = int($wh * 0.36) if $wh && $wh > 250;
            1;
        };
    }

    $w = 320 if !$w || $w < 320;
    $h = 220 if !$h || $h < 220;
    $w = 1800 if $w > 1800;
    $h = 1200 if $h > 1200;
    return ($w, $h);
}

sub render_preview {
    my $path  = $RUNTIME{preview_source_path}  || '';
    my $title = $RUNTIME{preview_source_title} || 'Preview';
    my ($w, $h) = preview_target_size();

    my $pix = load_scaled_pixbuf($path, $w, $h);
    if (!$pix) {
        $pix = fallback_icon_pixbuf(128);
    }
    if ($pix) {
        $UI{preview_image}->set_from_pixbuf($pix);
    } else {
        $UI{preview_image}->clear;
    }
    $UI{preview_label}->set_text($title);
    $RUNTIME{last_preview_size} = "$w x $h";
}

sub set_preview_from_path {
    my ($path, $title) = @_;
    $RUNTIME{preview_source_path}  = $path  || '';
    $RUNTIME{preview_source_title} = $title || 'Preview';
    render_preview();
}

sub refresh_style_preview {
    my %cfg = (
        style_kind   => style_key_from_combo(),
        style_color1 => color_button_hex($UI{style_color1}),
        style_color2 => color_button_hex($UI{style_color2}),
    );
    my ($path, $err) = ensure_style_preview(%cfg);
    if ($path) {
        set_preview_from_path($path, $STYLE_META{$cfg{style_kind}}{title});
    }
    my $help = $STYLE_META{$cfg{style_kind}}{help} || '';
    $UI{style_help}->set_text($help);
    my $secondary_needed = $cfg{style_kind} eq 'solid' ? FALSE : TRUE;
    $UI{style_color2}->set_sensitive($secondary_needed);
    $UI{style_color2_label}->set_sensitive($secondary_needed);
}

sub update_mode_help {
    my $mode = mode_key_from_combo();
    $UI{mode_help}->set_text($MODE_META{$mode}{help} || '');
}

sub update_summary {
    my $current = $RUNTIME{current} || {};
    my $saved = persistence_status();

    my $source_kind = 'Not set yet';
    $source_kind = 'Picture'      if ($current->{source_type} || '') eq 'image';
    $source_kind = 'Simple style' if ($current->{source_type} || '') eq 'generated';

    my $title = $current->{title} || ($current->{path} ? friendly_name($current->{path}) : 'Nothing selected yet');
    my $mode  = $current->{mode} && $MODE_META{ $current->{mode} } ? $MODE_META{ $current->{mode} }{title} : (($current->{source_type} || '') eq 'generated' ? 'Full-screen style' : 'Not set yet');
    my $folder = $current->{path} ? short_path(dirname($current->{path})) : (($current->{source_type} || '') eq 'generated' ? 'Built by Panther' : 'Not set yet');
    my $status = 'Ready';
    $status = 'Attention needed' if !$saved->{ready};
    $status = 'Attention needed' if $current->{path} && !-r $current->{path};

    $UI{summary_source}->set_text($source_kind);
    $UI{summary_name}->set_text($title);
    $UI{summary_mode}->set_text($mode);
    $UI{summary_saved}->set_text($saved->{label});
    $UI{summary_folder}->set_text($folder);
    $UI{summary_watch}->set_text(scalar(@{ $RUNTIME{folders} || [] }) . ' folder' . ((scalar(@{ $RUNTIME{folders} || [] }) == 1) ? '' : 's'));
    $UI{summary_state}->set_text($status);
}

sub persistence_status {
    my @files = (
        File::Spec->catfile($HOME, '.xprofile'),
        File::Spec->catfile($HOME, '.xinitrc'),
        File::Spec->catfile($HOME, '.xsession'),
    );
    my $marker_count = 0;
    for my $file (@files) {
        next if !-f $file;
        if (open my $fh, '<', $file) {
            local $/;
            my $txt = <$fh>;
            close $fh;
            $marker_count++ if $txt =~ /panther background/i;
        }
    }

    if (-x $FEHBG && $marker_count) {
        return { ready => 1, label => 'Yes' };
    }
    if (-f $FEHBG && !$marker_count) {
        return { ready => 0, label => 'Not saved for future sessions yet' };
    }
    return { ready => 0, label => 'Not ready yet' };
}

sub resolve_current_state {
    my ($user_cfg, $system_cfg) = @_;
    my $current;

    if (($user_cfg->{source_type} || '') eq 'image' && $user_cfg->{path}) {
        $current = {
            source_type => 'image',
            path        => $user_cfg->{path},
            mode        => $user_cfg->{mode} || 'fill',
            bg_color    => $user_cfg->{bg_color} || '#000000',
            title       => friendly_name($user_cfg->{path}),
        };
    } elsif (($user_cfg->{source_type} || '') eq 'generated') {
        my ($path) = ensure_style_file(
            style_kind   => $user_cfg->{style_kind},
            style_color1 => $user_cfg->{style_color1},
            style_color2 => $user_cfg->{style_color2},
        );
        $current = {
            source_type => 'generated',
            path        => $path,
            title       => $STYLE_META{ $user_cfg->{style_kind} || 'solid' }{title},
            mode        => 'fill',
        } if $path;
    }

    if (!$current) {
        $current = parse_fehbg();
    }

    if (!$current && ($system_cfg->{default_type} || '') ne '') {
        if ($system_cfg->{default_type} eq 'image' && $system_cfg->{default_path}) {
            $current = {
                source_type => 'image',
                path        => $system_cfg->{default_path},
                mode        => $system_cfg->{default_mode} || 'fill',
                bg_color    => $system_cfg->{default_bg_color} || '#000000',
                title       => friendly_name($system_cfg->{default_path}),
            };
        } elsif ($system_cfg->{default_type} eq 'generated') {
            my ($path) = ensure_style_file(
                style_kind   => $system_cfg->{default_pattern} || 'solid',
                style_color1 => $system_cfg->{default_color1} || '#1F2937',
                style_color2 => $system_cfg->{default_color2} || '#111827',
            );
            $current = {
                source_type => 'generated',
                path        => $path,
                mode        => 'fill',
                title       => $STYLE_META{ $system_cfg->{default_pattern} || 'solid' }{title},
            } if $path;
        }
    }

    $RUNTIME{current} = $current || {};
}

sub populate_folder_combo {
    $UI{folder_combo}->remove_all;
    for my $folder (@{ $RUNTIME{folders} || [] }) {
        $UI{folder_combo}->append_text(short_path($folder));
    }
    $UI{folder_combo}->set_active(0) if @{ $RUNTIME{folders} || [] };
}

sub selected_folder_from_combo {
    my $idx = $UI{folder_combo}->get_active;
    return undef if $idx < 0;
    return $RUNTIME{folders}[$idx];
}

sub refresh_image_store {
    my ($keep_path) = @_;
    my $store = $UI{image_store};
    $store->clear;

    my @images = @{ $RUNTIME{scan}{all_images} || [] };
    my $shown = 0;
    for my $path (@images) {
        last if $shown >= $MAX_SCAN;
        my $thumb = load_scaled_pixbuf($path, 160, 100) || fallback_icon_pixbuf(96);
        my $iter = $store->append;
        $store->set($iter,
            0 => $thumb,
            1 => friendly_name($path),
            2 => $path,
        );
        $shown++;
    }

    my $count = scalar @images;
    my $label = $count == 1 ? '1 picture found' : "$count pictures found";
    $label .= " (showing the first $MAX_SCAN here)" if $count > $MAX_SCAN;
    $UI{browser_count}->set_text($label);

    my $target = $keep_path || $RUNTIME{selected_image} || ($RUNTIME{current}{path} || '');
    if ($target) {
        my $index = 0;
        for my $path (@images) {
            last if $index >= $MAX_SCAN;
            if ($path eq $target) {
                my $treepath = Gtk3::TreePath->new_from_indices($index);
                $UI{icon_view}->select_path($treepath);
                $RUNTIME{selected_image} = $path;
                last;
            }
            $index++;
        }
    }
}

sub refresh_all {
    $RUNTIME{folders} = [ active_folders($RUNTIME{system_cfg}, $RUNTIME{user_cfg}) ];
    populate_folder_combo();
    $RUNTIME{scan} = scan_images(@{ $RUNTIME{folders} || [] });
    report_folder_health($RUNTIME{scan});
    refresh_image_store($RUNTIME{selected_image});
    resolve_current_state($RUNTIME{user_cfg}, $RUNTIME{system_cfg});
    update_summary();
    update_mode_help();

    if ($UI{source_notebook}->get_current_page == 1) {
        refresh_style_preview();
    } elsif ($RUNTIME{selected_image}) {
        set_preview_from_path($RUNTIME{selected_image}, friendly_name($RUNTIME{selected_image}));
    } elsif ($RUNTIME{current}{path}) {
        set_preview_from_path($RUNTIME{current}{path}, $RUNTIME{current}{title});
    }
}

sub save_user_cfg_only {
    my ($cfg) = @_;
    my %persist = %{ $RUNTIME{user_cfg} || {} };
    $persist{source_type} = $cfg->{source_type} || '';
    $persist{path}        = $cfg->{path}        || '';
    $persist{mode}        = $cfg->{mode}        || 'fill';
    $persist{bg_color}    = $cfg->{bg_color}    || '#000000';
    $persist{style_kind}  = $cfg->{style_kind}  || 'solid';
    $persist{style_color1}= $cfg->{style_color1}|| '#1F2937';
    $persist{style_color2}= $cfg->{style_color2}|| '#111827';
    $persist{saved_at}    = strftime('%Y-%m-%d %H:%M:%S', localtime);
    $persist{folder}      = [ @{ $RUNTIME{user_cfg}{folder} || [] } ];
    $persist{disabled_folder} = [ @{ $RUNTIME{user_cfg}{disabled_folder} || [] } ];

    my ($ok, $err) = write_kv_file($STATE_FILE, \%persist);
    if ($ok) {
        $RUNTIME{user_cfg} = \%persist;
        return 1;
    }
    status_text('error', $err || 'Could not save your settings.');
    return 0;
}

sub run_system_cmd {
    my (@cmd) = @_;
    my $pid = fork();
    if (!defined $pid) {
        return (0, 'Could not start the background command.');
    }
    if ($pid == 0) {
        open STDIN,  '<', '/dev/null';
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec { $cmd[0] } @cmd;
        exit 127;
    }
    waitpid($pid, 0);
    my $code = $? >> 8;
    return ($code == 0 ? 1 : 0, $code == 0 ? undef : 'Could not apply the background.');
}

sub hook_block {
    return <<'HOOK';
# >>> panther background >>>
if [ -x "$HOME/.fehbg" ]; then
  "$HOME/.fehbg" >/dev/null 2>&1 &
fi
# <<< panther background <<<
HOOK
}

sub inject_block_into_file {
    my ($path, $create_if_missing) = @_;
    my $block = hook_block();
    my $content = '';
    if (-f $path) {
        open my $fh, '<', $path or return (0, "Could not open $path");
        local $/;
        $content = <$fh>;
        close $fh;
        return (1, undef) if $content =~ /panther background/i;
    } elsif (!$create_if_missing) {
        return (1, undef);
    }

    my $new = $content;
    if ($path =~ /\.xinitrc\z/ && $content =~ /^\s*exec\b/m) {
        $new =~ s/^(\s*exec\b)/$block\n$1/m;
    } elsif ($path =~ /\.xsession\z/ && $content =~ /^\s*exec\b/m) {
        $new =~ s/^(\s*exec\b)/$block\n$1/m;
    } else {
        $new .= "\n" if $new ne '' && $new !~ /\n\z/;
        $new .= $block;
    }

    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or return (0, "Could not write $tmp");
    print {$fh} $new;
    close $fh or return (0, "Could not finish writing $tmp");
    rename $tmp, $path or return (0, "Could not replace $path");
    chmod 0644, $path;
    return (1, undef);
}

sub ensure_persistence_hooks {
    my @ops = (
        [ File::Spec->catfile($HOME, '.xprofile'), 1 ],
        [ File::Spec->catfile($HOME, '.xinitrc'), 0 ],
        [ File::Spec->catfile($HOME, '.xsession'), 0 ],
    );
    for my $op (@ops) {
        my ($ok, $err) = inject_block_into_file($op->[0], $op->[1]);
        return (0, $err) if !$ok;
    }
    return (1, undef);
}

sub apply_cfg {
    my ($cfg, $save_for_future) = @_;

    if (!$RUNTIME{cmd}{feh}) {
        status_text('error', 'feh is not available right now. Please install it first.');
        return;
    }

    my $path = $cfg->{path};
    if (($cfg->{source_type} || '') eq 'generated') {
        my ($style_path, $err) = ensure_style_file(%{$cfg});
        if (!$style_path) {
            status_text('error', $err || 'Could not build the style preview.');
            return;
        }
        $path = $style_path;
        $cfg->{path} = $style_path;
    }

    if (!$path || !-r $path) {
        status_text('error', 'Please choose a picture or a style first.');
        return;
    }

    my @cmd = ($RUNTIME{cmd}{feh}, '--bg-' . ($cfg->{mode} || 'fill'));
    push @cmd, '--image-bg', ($cfg->{bg_color} || '#000000') if ($cfg->{mode} || '') ne 'tile';
    push @cmd, $path;

    my ($ok, $err) = run_system_cmd(@cmd);
    if (!$ok) {
        status_text('error', $err || 'Could not apply the background.');
        return;
    }

    chmod 0755, $FEHBG if -f $FEHBG;

    if (!save_user_cfg_only($cfg)) {
        return;
    }

    if ($save_for_future) {
        my ($persist_ok, $persist_err) = ensure_persistence_hooks();
        if (!$persist_ok) {
            status_text('warn', 'The background was applied, but Panther could not finish the future-session step. ' . ($persist_err || ''));
        } else {
            status_text('ok', 'Your changes were saved and will come back in future sessions.');
        }
    } else {
        status_text('ok', 'Background applied for this session. Use Save for future sessions when you are ready.');
    }

    resolve_current_state($RUNTIME{user_cfg}, $RUNTIME{system_cfg});
    update_summary();
}

sub on_image_selected {
    my @paths = $UI{icon_view}->get_selected_items;
    return if !@paths;
    my $treepath = $paths[0];
    my $iter = $UI{image_store}->get_iter($treepath);
    return if !$iter;
    my ($name, $path) = $UI{image_store}->get($iter, 1, 2);
    $RUNTIME{selected_image} = $path;
    set_preview_from_path($path, $name);
}

sub add_folder_dialog {
    my $dialog = Gtk3::FileChooserDialog->new(
        'Choose a picture folder',
        $UI{window},
        'select-folder',
        'gtk-cancel' => 'cancel',
        'gtk-open'   => 'ok',
    );
    $dialog->set_local_only(TRUE);
    my $response = $dialog->run;
    if ($response eq 'ok') {
        my $folder = $dialog->get_filename;
        if ($folder && -d $folder) {
            my $real = abs_path($folder) || $folder;
            my %already = map { $_ => 1 } @{ $RUNTIME{user_cfg}{folder} || [] };
            if (!$already{$real}) {
                push @{ $RUNTIME{user_cfg}{folder} }, $real;
                save_user_cfg_only($RUNTIME{user_cfg});
                refresh_all();
                status_text('ok', 'Folder added.');
            } else {
                status_text('info', 'That folder is already being checked.');
            }
        }
    }
    $dialog->destroy;
}

sub remove_selected_folder {
    my $folder = selected_folder_from_combo();
    if (!$folder) {
        status_text('warn', 'Please choose a folder first.');
        return;
    }
    my $real = abs_path($folder) || $folder;
    my @user = @{ $RUNTIME{user_cfg}{folder} || [] };
    my @kept = grep { (abs_path($_) || $_) ne $real } @user;
    if (@kept == @user) {
        status_text('info', 'That folder belongs to the shared system setup, so Panther leaves it in place.');
        return;
    }
    $RUNTIME{user_cfg}{folder} = \@kept;
    save_user_cfg_only($RUNTIME{user_cfg});
    refresh_all();
    status_text('ok', 'Folder removed from Panther.');
}

sub add_suggested_folders {
    my @suggested = grep { -d $_ && -r $_ } common_user_folders();
    my %have = map { (abs_path($_) || $_) => 1 } @{ $RUNTIME{user_cfg}{folder} || [] }, @{ $RUNTIME{folders} || [] };
    my $added = 0;
    for my $folder (@suggested) {
        my $real = abs_path($folder) || $folder;
        next if $have{$real}++;
        push @{ $RUNTIME{user_cfg}{folder} }, $real;
        $added++;
    }
    save_user_cfg_only($RUNTIME{user_cfg});
    refresh_all();
    if ($added) {
        status_text('ok', 'Panther added a few good picture folders for you.');
    } else {
        status_text('info', 'Panther could not find any new suggested folders to add right now.');
    }
}

sub load_system_default_into_ui {
    my $sys = $RUNTIME{system_cfg};
    if (($sys->{default_type} || '') eq '') {
        status_text('info', 'No shared default has been saved yet.');
        return;
    }

    if ($sys->{default_type} eq 'image' && $sys->{default_path}) {
        $UI{source_notebook}->set_current_page(0);
        $RUNTIME{selected_image} = $sys->{default_path};
        refresh_image_store($RUNTIME{selected_image});
        for my $i (0 .. 4) {
            if ((qw(fill max center scale tile))[$i] eq ($sys->{default_mode} || 'fill')) {
                $UI{mode_combo}->set_active($i);
            }
        }
        set_color_button_hex($UI{border_color}, $sys->{default_bg_color} || '#000000');
        set_preview_from_path($sys->{default_path}, friendly_name($sys->{default_path}));
        status_text('ok', 'Loaded the shared default.');
        return;
    }

    if ($sys->{default_type} eq 'generated') {
        $UI{source_notebook}->set_current_page(1);
        my @styles = qw(solid stripes checker dots);
        my $target = $sys->{default_pattern} || 'solid';
        for my $i (0 .. $#styles) {
            if ($styles[$i] eq $target) {
                $UI{style_combo}->set_active($i);
                last;
            }
        }
        set_color_button_hex($UI{style_color1}, $sys->{default_color1} || '#1F2937');
        set_color_button_hex($UI{style_color2}, $sys->{default_color2} || '#111827');
        refresh_style_preview();
        status_text('ok', 'Loaded the shared default.');
    }
}

sub save_as_shared_default {
    if ($> != 0) {
        status_text('warn', 'Saving a shared default needs root, so please open Panther as root only when you really want to manage the whole machine.');
        return;
    }

    my $cfg = current_selection_cfg();
    my $sys = read_system_config();
    my $shared = $sys->{shared_folder} || '/var/lib/panther/shared';
    make_path($shared, { mode => 0755 }) if !-d $shared;

    my %write;
    $write{folder} = [ @{ $sys->{system_folder} || [] } ];
    push @{ $write{folder} }, $shared if !grep { $_ eq $shared } @{ $write{folder} };
    $write{shared_folder} = $shared;

    if (($cfg->{source_type} || '') eq 'generated') {
        my ($src, $err) = ensure_style_file(%{$cfg});
        if (!$src) {
            status_text('error', $err || 'Could not prepare the shared style.');
            return;
        }
        my $dest = File::Spec->catfile($shared, 'panther-shared-default.ppm');
        copy($src, $dest) or do {
            status_text('error', 'Could not copy the shared style.');
            return;
        };
        chmod 0644, $dest;
        $write{default_type}    = 'generated';
        $write{default_path}    = $dest;
        $write{default_mode}    = 'fill';
        $write{default_pattern} = $cfg->{style_kind};
        $write{default_color1}  = $cfg->{style_color1};
        $write{default_color2}  = $cfg->{style_color2};
        $write{default_bg_color}= $cfg->{style_color1};
    } else {
        my $src = $cfg->{path} || '';
        if (!$src || !-r $src) {
            status_text('warn', 'Please choose a picture first.');
            return;
        }
        my $dest_name = basename($src);
        $dest_name =~ s/[^A-Za-z0-9._-]+/_/g;
        my $dest = File::Spec->catfile($shared, $dest_name);
        copy($src, $dest) or do {
            status_text('error', 'Could not copy the shared picture.');
            return;
        };
        chmod 0644, $dest;
        $write{default_type}     = 'image';
        $write{default_path}     = $dest;
        $write{default_mode}     = $cfg->{mode} || 'fill';
        $write{default_bg_color} = $cfg->{bg_color} || '#000000';
        $write{default_pattern}  = 'solid';
        $write{default_color1}   = '#1F2937';
        $write{default_color2}   = '#111827';
    }

    my ($ok, $err) = write_kv_file($SYSTEM_CONF, \%write);
    if (!$ok) {
        status_text('error', $err || 'Could not save the shared default.');
        return;
    }
    $RUNTIME{system_cfg} = read_system_config();
    status_text('ok', 'Shared default saved for this machine.');
}

sub restore_current_into_ui {
    my $cfg = $RUNTIME{user_cfg};
    if (($cfg->{source_type} || '') eq 'generated') {
        $UI{source_notebook}->set_current_page(1);
        my @styles = qw(solid stripes checker dots);
        for my $i (0 .. $#styles) {
            if ($styles[$i] eq ($cfg->{style_kind} || 'solid')) {
                $UI{style_combo}->set_active($i);
                last;
            }
        }
        set_color_button_hex($UI{style_color1}, $cfg->{style_color1} || '#1F2937');
        set_color_button_hex($UI{style_color2}, $cfg->{style_color2} || '#111827');
        refresh_style_preview();
    } else {
        $UI{source_notebook}->set_current_page(0);
        $RUNTIME{selected_image} = $cfg->{path} || $RUNTIME{current}{path} || '';
        refresh_image_store($RUNTIME{selected_image});
        my @modes = qw(fill max center scale tile);
        for my $i (0 .. $#modes) {
            if ($modes[$i] eq ($cfg->{mode} || 'fill')) {
                $UI{mode_combo}->set_active($i);
                last;
            }
        }
        set_color_button_hex($UI{border_color}, $cfg->{bg_color} || '#000000');
        if ($RUNTIME{selected_image}) {
            set_preview_from_path($RUNTIME{selected_image}, friendly_name($RUNTIME{selected_image}));
        }
    }
    update_mode_help();
    status_text('ok', 'Restored the current Panther choices.');
}

sub build_ui {
    my $window = Gtk3::Window->new('toplevel');
    $window->set_title($APP_NAME);
    $window->set_default_size(1220, 820);
    $window->set_border_width(14);
    $window->signal_connect(delete_event => sub { Gtk3->main_quit; return FALSE; });
    $UI{window} = $window;

    my $root = Gtk3::Box->new('vertical', 10);
    $window->add($root);

    my $title = Gtk3::Label->new(undef);
    $title->set_markup('<span size="x-large" weight="bold">Panther</span>');
    $title->set_xalign(0);
    my $subtitle = Gtk3::Label->new('A friendly background manager for Artix X11 sessions using feh.');
    $subtitle->set_xalign(0);
    $subtitle->set_line_wrap(TRUE);
    $root->pack_start($title, FALSE, FALSE, 0);
    $root->pack_start($subtitle, FALSE, FALSE, 0);

    my $paned = Gtk3::Paned->new('horizontal');
    $root->pack_start($paned, TRUE, TRUE, 0);

    my $left = Gtk3::Box->new('vertical', 10);
    my $right = Gtk3::Box->new('vertical', 10);
    $paned->pack1($left, TRUE, FALSE);
    $paned->pack2($right, TRUE, FALSE);

    my $notebook = Gtk3::Notebook->new;
    $UI{source_notebook} = $notebook;
    $left->pack_start($notebook, TRUE, TRUE, 0);

    my $pictures_box = Gtk3::Box->new('vertical', 8);
    my $folder_row = Gtk3::Box->new('horizontal', 6);
    $pictures_box->pack_start($folder_row, FALSE, FALSE, 0);

    my $folder_combo = Gtk3::ComboBoxText->new;
    $folder_combo->set_hexpand(TRUE);
    $UI{folder_combo} = $folder_combo;
    $folder_row->pack_start($folder_combo, TRUE, TRUE, 0);

    my $add_folder = Gtk3::Button->new_with_label('Add folder');
    my $remove_folder = Gtk3::Button->new_with_label('Remove folder');
    my $refresh_button = Gtk3::Button->new_with_label('Refresh');
    $folder_row->pack_start($add_folder, FALSE, FALSE, 0);
    $folder_row->pack_start($remove_folder, FALSE, FALSE, 0);
    $folder_row->pack_start($refresh_button, FALSE, FALSE, 0);

    my $browser_count = Gtk3::Label->new('Looking for pictures...');
    $browser_count->set_xalign(0);
    $UI{browser_count} = $browser_count;
    $pictures_box->pack_start($browser_count, FALSE, FALSE, 0);

    my $image_store = Gtk3::ListStore->new('Gtk3::Gdk::Pixbuf', 'Glib::String', 'Glib::String');
    $UI{image_store} = $image_store;

    my $icon_view = Gtk3::IconView->new_with_model($image_store);
    $icon_view->set_pixbuf_column(0);
    $icon_view->set_text_column(1);
    $icon_view->set_margin(8);
    $icon_view->set_spacing(12);
    $icon_view->set_item_width(170);
    $icon_view->set_activate_on_single_click(TRUE);
    $UI{icon_view} = $icon_view;

    my $image_scroll = Gtk3::ScrolledWindow->new;
    $image_scroll->set_policy('automatic', 'automatic');
    $image_scroll->add($icon_view);
    $pictures_box->pack_start($image_scroll, TRUE, TRUE, 0);

    my $style_box = Gtk3::Box->new('vertical', 8);
    my $style_intro = Gtk3::Label->new('Choose a simple full-screen style when you want a color or a calm pattern instead of a picture.');
    $style_intro->set_xalign(0);
    $style_intro->set_line_wrap(TRUE);
    $style_box->pack_start($style_intro, FALSE, FALSE, 0);

    my $style_grid = Gtk3::Grid->new;
    $style_grid->set_column_spacing(10);
    $style_grid->set_row_spacing(8);
    $style_box->pack_start($style_grid, FALSE, FALSE, 0);

    my $style_combo = Gtk3::ComboBoxText->new;
    $style_combo->append_text($_) for map { $STYLE_META{$_}{title} } qw(solid stripes checker dots);
    $style_combo->set_active(0);
    $UI{style_combo} = $style_combo;

    my $style_color1 = Gtk3::ColorButton->new;
    my $style_color2 = Gtk3::ColorButton->new;
    $UI{style_color1} = $style_color1;
    $UI{style_color2} = $style_color2;

    my $style_color2_label = Gtk3::Label->new('Second color');
    $style_color2_label->set_xalign(0);
    $UI{style_color2_label} = $style_color2_label;

    $style_grid->attach(Gtk3::Label->new('Style'), 0, 0, 1, 1);
    $style_grid->attach($style_combo, 1, 0, 1, 1);
    $style_grid->attach(Gtk3::Label->new('Main color'), 0, 1, 1, 1);
    $style_grid->attach($style_color1, 1, 1, 1, 1);
    $style_grid->attach($style_color2_label, 0, 2, 1, 1);
    $style_grid->attach($style_color2, 1, 2, 1, 1);

    my $style_help = Gtk3::Label->new('');
    $style_help->set_xalign(0);
    $style_help->set_line_wrap(TRUE);
    $UI{style_help} = $style_help;
    $style_box->pack_start($style_help, FALSE, FALSE, 0);

    $notebook->append_page($pictures_box, Gtk3::Label->new('Pictures'));
    $notebook->append_page($style_box, Gtk3::Label->new('Simple styles'));

    my $preview_frame = Gtk3::Frame->new('Preview');
    $right->pack_start($preview_frame, TRUE, TRUE, 0);
    my $preview_box = Gtk3::Box->new('vertical', 6);
    $preview_box->set_border_width(8);
    $preview_frame->add($preview_box);

    my $preview_scroller = Gtk3::ScrolledWindow->new;
    $preview_scroller->set_policy('automatic', 'automatic');
    $preview_scroller->set_size_request(320, 220);
    $preview_box->pack_start($preview_scroller, TRUE, TRUE, 0);

    my $preview_image = Gtk3::Image->new;
    my $preview_align = Gtk3::Alignment->new(0.5, 0.5, 0, 0);
    $preview_align->add($preview_image);
    $preview_scroller->add_with_viewport($preview_align);

    my $preview_label = Gtk3::Label->new('Preview');
    $preview_label->set_xalign(0);
    $UI{preview_scroller} = $preview_scroller;
    $UI{preview_image} = $preview_image;
    $UI{preview_label} = $preview_label;
    $preview_box->pack_start($preview_label, FALSE, FALSE, 0);

    my $summary_frame = Gtk3::Frame->new('Current background');
    $right->pack_start($summary_frame, FALSE, FALSE, 0);
    my $summary_grid = Gtk3::Grid->new;
    $summary_grid->set_column_spacing(12);
    $summary_grid->set_row_spacing(6);
    $summary_grid->set_border_width(8);
    $summary_frame->add($summary_grid);

    my %summary_label;
    my @summary_rows = (
        [ 'Current source', 'summary_source' ],
        [ 'Current image',  'summary_name'   ],
        [ 'Display style',  'summary_mode'   ],
        [ 'Saved for future sessions', 'summary_saved' ],
        [ 'Background source folder',  'summary_folder' ],
        [ 'Watched folders', 'summary_watch' ],
        [ 'Status',          'summary_state' ],
    );
    my $row = 0;
    for my $item (@summary_rows) {
        my $left_label = Gtk3::Label->new($item->[0]);
        $left_label->set_xalign(0);
        my $right_label = Gtk3::Label->new('');
        $right_label->set_xalign(0);
        $right_label->set_line_wrap(TRUE);
        $summary_grid->attach($left_label, 0, $row, 1, 1);
        $summary_grid->attach($right_label, 1, $row, 1, 1);
        $UI{ $item->[1] } = $right_label;
        $row++;
    }

    my $health_frame = Gtk3::Frame->new('Folders and suggestions');
    $right->pack_start($health_frame, TRUE, TRUE, 0);
    my $health_scroll = Gtk3::ScrolledWindow->new;
    $health_scroll->set_policy('automatic', 'automatic');
    $health_frame->add($health_scroll);
    my $folder_buffer = Gtk3::TextBuffer->new;
    my $folder_view = Gtk3::TextView->new_with_buffer($folder_buffer);
    $folder_view->set_wrap_mode('word');
    $folder_view->set_editable(FALSE);
    $folder_view->set_cursor_visible(FALSE);
    $health_scroll->add($folder_view);
    $UI{folder_buffer} = $folder_buffer;

    my $controls_frame = Gtk3::Frame->new('Apply and save');
    $right->pack_start($controls_frame, FALSE, FALSE, 0);
    my $controls = Gtk3::Box->new('vertical', 8);
    $controls->set_border_width(8);
    $controls_frame->add($controls);

    my $mode_combo = Gtk3::ComboBoxText->new;
    $mode_combo->append_text($_) for map { $MODE_META{$_}{title} } qw(fill max center scale tile);
    $mode_combo->set_active(0);
    $UI{mode_combo} = $mode_combo;

    my $mode_row = Gtk3::Box->new('horizontal', 8);
    $mode_row->pack_start(Gtk3::Label->new('How should the image fit your screen?'), FALSE, FALSE, 0);
    $mode_row->pack_start($mode_combo, TRUE, TRUE, 0);
    $controls->pack_start($mode_row, FALSE, FALSE, 0);

    my $border_color = Gtk3::ColorButton->new;
    $UI{border_color} = $border_color;
    my $bg_row = Gtk3::Box->new('horizontal', 8);
    $bg_row->pack_start(Gtk3::Label->new('Space color around the image'), FALSE, FALSE, 0);
    $bg_row->pack_start($border_color, FALSE, FALSE, 0);
    $controls->pack_start($bg_row, FALSE, FALSE, 0);

    my $mode_help = Gtk3::Label->new('');
    $mode_help->set_xalign(0);
    $mode_help->set_line_wrap(TRUE);
    $UI{mode_help} = $mode_help;
    $controls->pack_start($mode_help, FALSE, FALSE, 0);

    my $buttons_row = Gtk3::Box->new('horizontal', 6);
    my $check_folders = Gtk3::Button->new_with_label('Check folders');
    my $suggest_folders = Gtk3::Button->new_with_label('Suggest folders');
    my $restore_current = Gtk3::Button->new_with_label('Restore current');
    my $use_shared = Gtk3::Button->new_with_label('Use shared default');
    my $apply_now = Gtk3::Button->new_with_label('Apply');
    my $save_and_apply = Gtk3::Button->new_with_label('Save');
    my $save_shared = Gtk3::Button->new_with_label('Save as shared default');
    $save_shared->set_sensitive($> == 0 ? TRUE : FALSE);

    for my $btn ($check_folders, $suggest_folders, $restore_current, $use_shared, $apply_now, $save_and_apply, $save_shared) {
        $buttons_row->pack_start($btn, FALSE, FALSE, 0);
    }
    $controls->pack_start($buttons_row, FALSE, FALSE, 0);

    my $status_label = Gtk3::Label->new('Ready.');
    $status_label->set_xalign(0);
    $status_label->set_line_wrap(TRUE);
    $UI{status_label} = $status_label;
    $root->pack_start($status_label, FALSE, FALSE, 0);

    set_color_button_hex($style_color1, '#1F2937');
    set_color_button_hex($style_color2, '#111827');
    set_color_button_hex($border_color, '#000000');

    $icon_view->signal_connect(selection_changed => \&on_image_selected);
    $refresh_button->signal_connect(clicked => sub { refresh_all(); status_text('ok', 'Picture list refreshed.'); });
    $add_folder->signal_connect(clicked => \&add_folder_dialog);
    $remove_folder->signal_connect(clicked => \&remove_selected_folder);
    $mode_combo->signal_connect(changed => \&update_mode_help);
    $style_combo->signal_connect(changed => \&refresh_style_preview);
    $style_color1->signal_connect(color_set => \&refresh_style_preview);
    $style_color2->signal_connect(color_set => \&refresh_style_preview);
    $border_color->signal_connect(color_set => sub { });
    $check_folders->signal_connect(clicked => sub { report_folder_health($RUNTIME{scan}); status_text('ok', 'Folder check finished.'); });
    $suggest_folders->signal_connect(clicked => \&add_suggested_folders);
    $restore_current->signal_connect(clicked => \&restore_current_into_ui);
    $use_shared->signal_connect(clicked => \&load_system_default_into_ui);
    $apply_now->signal_connect(clicked => sub { apply_cfg(current_selection_cfg(), 0); });
    $save_and_apply->signal_connect(clicked => sub { apply_cfg(current_selection_cfg(), 1); });
    $save_shared->signal_connect(clicked => \&save_as_shared_default);
    $notebook->signal_connect(switch_page => sub {
        my ($nb, $page, $num) = @_;
        if ($num == 1) {
            $mode_combo->set_sensitive(FALSE);
            $border_color->set_sensitive(FALSE);
            $mode_help->set_text('Simple styles always cover the full screen.');
            refresh_style_preview();
        } else {
            $mode_combo->set_sensitive(TRUE);
            $border_color->set_sensitive(TRUE);
            update_mode_help();
            if ($RUNTIME{selected_image}) {
                set_preview_from_path($RUNTIME{selected_image}, friendly_name($RUNTIME{selected_image}));
            }
        }
    });

    $UI{preview_scroller}->signal_connect(size_allocate => sub {
        my ($widget, $alloc) = @_;
        my $size_key = ($alloc->{width} || 0) . 'x' . ($alloc->{height} || 0);
        return if !$RUNTIME{preview_source_path} && !$RUNTIME{preview_source_title};
        return if defined $RUNTIME{last_preview_alloc} && $RUNTIME{last_preview_alloc} eq $size_key;
        $RUNTIME{last_preview_alloc} = $size_key;
        render_preview();
    });

    $window->show_all;
}

ensure_dirs();
$RUNTIME{cmd}        = { feh => command_path('feh') };
$RUNTIME{system_cfg} = read_system_config();
$RUNTIME{user_cfg}   = read_user_state();
$RUNTIME{selected_image} = $RUNTIME{user_cfg}{path} || '';

build_ui();
refresh_all();
if (!$RUNTIME{cmd}{feh}) {
    status_text('warn', 'feh was not found yet. Panther can still browse folders, but applying backgrounds needs feh.');
}
Gtk3->main;
