=head1 NAME

EPrints::EPM

=cut

package EPrints::EPM;

use strict;
use File::Path;
use File::Copy;
use Cwd;
use Digest::MD5;

sub unpack_package 
{
	my ( $repository, $app_path, $directory ) = @_;
	
	my $mime_type = $repository->call('guess_doc_type',$repository ,$app_path );

	my $type = "zip";

	if ($mime_type eq "application/x-tar") {
		$type = "targz";
	}

	my $rc = $repository->exec(
			$type,
			DIR => $directory,
			ARC => $app_path );

	return $rc;

}

sub remove_cache_package
{
	my ( $repository, $package ) = @_;
	
	my $archive_root = $repository->get_conf("archiveroot");
	my $epm_path = $archive_root . "/var/epm/cache/";
	my $cache_package_path = $epm_path . "/" . $package;

	my $rc = rmtree($cache_package_path);
	
	if ($rc < 1) 
	{
		return (1, "Failed to remove cached package");
	}
	return (0, "Cache Package Removed");

}

sub download_package 
{
	my ($repository, $url_in) = @_;

	my $url = URI::Heuristic::uf_uri( $url_in );

	my $tmpdir = File::Temp->newdir();

# save previous dir
	my $prev_dir = getcwd();

# Change directory to destination dir., return with failure if this 
# fails.
	unless( chdir "$tmpdir" )
	{
		chdir $prev_dir;
		return( 0 );
	}

# Work out the number of directories to cut, so top-level files go in
# at the top level in the destination dir.

# Count slashes
	my $cut_dirs = substr($url->path,1) =~ tr"/""; # ignore leading /

	my $rc = $repository->get_repository->exec(
			"wget",
			CUTDIRS => $cut_dirs,
			URL => $url );

	chdir $prev_dir;

	my $epm_file;

	$rc = 1;
	File::Find::find( { 
                no_chdir => 1, 
                wanted => sub { 
                        return unless $rc and !-d $File::Find::name; 
                       	$epm_file = $File::Find::name; 
                }, 
        }, "$tmpdir" );	

	return (\$tmpdir,\$epm_file);
}

sub cache_package 
{
	my ($repository, $tmpfile) = @_;

	my $directory = File::Temp->newdir( CLEANUP => 1 );

	my $rc = unpack_package($repository, $tmpfile, $directory);
	if ($rc) {
		return (1,"failed to unpack package");
	}
	
	my $archive_root = $repository->get_repository->get_conf("archiveroot");
	my $epm_path = $archive_root . "/var/epm/cache/";
	
	if ( !-d $epm_path ) {
		mkpath($epm_path);
	}
        
	if( !-d $epm_path )
        {
                return (1,"Failed to create package management cache");
        }

	$rc = 1;

	my $spec_file_incoming = _find_spec_file($directory);
	return(1, "no_spec_file" ) if (!defined $spec_file_incoming);
	
	my $keypairs_in = read_spec_file($spec_file_incoming);
	my $package_name = $keypairs_in->{package};

	my $cache_package_path = $epm_path . "/" . $package_name;

	if ( -d $cache_package_path ) {
		rmtree($cache_package_path);
	}
	mkpath($cache_package_path);
        
	if( !-d $cache_package_path )
        {
                return (1,"Failed to create package cache");
        }
	
	$rc = unpack_package($repository, $tmpfile, $cache_package_path);
	$spec_file_incoming = _find_spec_file($cache_package_path);

	my $message = "Package copied into cache";
	if ($rc) {
		$message = "Failed to unpack package to cache";
	}
	return ($rc,$message);
	
}

sub _find_spec_file
{
	my ( $directory ) = @_;

	my $spec_file_in;

	my $rc = 1;
	File::Find::find( {
                no_chdir => 1,
                wanted => sub {
                        return unless $rc and !-d $File::Find::name;
                        my $filepath = $File::Find::name;
                        my $filename = substr($filepath, length($directory));
                        open(my $filehandle, "<", $filepath);
                        unless( defined( $filehandle ) )
                        {
                                $rc = 0;
                                return;
                        }
			if ( (substr $filename, -5) eq ".spec" ) {
				$spec_file_in = $filepath;
			}
		}
        }, "$directory" );
	
	my $keypairs = read_spec_file($spec_file_in);
	my $package_name = $keypairs->{package};
	
	my $dst_spec = $directory . "/$package_name.spec";

	unless ($dst_spec eq $spec_file_in) {
		copy($spec_file_in,$dst_spec);
		unlink($spec_file_in);
	}

	return $dst_spec;
} 

sub install
{
	my ($repository, $app_path, $force) = @_;

	my $message;
	my $archive_root = $repository->get_conf("archiveroot");
	my $epm_path = $archive_root . "/var/epm/packages";
	#Set up variables to be used
	my $file_md5s;
	my $backup_directory;

	my $directory = $app_path;
	if ( !-d $directory ) {
		$directory = File::Temp->newdir( CLEANUP => 1 );
		my $rc = unpack_package($repository, $app_path, $directory);
		if ($rc) {
			return (1,"failed to unpack package");
		}
	}

	# Find the Package Spec File 

	my $spec_file_incoming = _find_spec_file($directory);
	return(1, "no_spec_file" ) if (!defined $spec_file_incoming);
	
	my $new_specs = read_spec_file($spec_file_incoming);
	my $package_name = $new_specs->{package};

	my $package_path = $epm_path . "/" . $package_name;
	my $installed_spec_file = $package_path . "/" . $package_name . ".spec";

	my $old_version;

	# if the package is already installed...
	if ( -e $installed_spec_file || $force ) {

		my $installed_specs = read_spec_file($installed_spec_file);

		if ($new_specs->{version} lt $installed_specs->{version}) {
			$message = "More recent version of package is already installed, use --force to override";	
			return(1,$message);
		}
		
		$old_version = $installed_specs->{version};

		$backup_directory = make_backup($repository, $package_name);

	}
	
	mkpath($package_path);

	copy($spec_file_incoming, $package_path."/".$package_name.".spec");
	copy($directory."/"."$new_specs->{icon}", $package_path."/"."$new_specs->{icon}");

	my $schema_before = get_current_schema($repository);

	my @package_files = ();
        File::Find::find( {
                no_chdir => 1,
                wanted => sub {
                        return if -d $File::Find::name;
			push @package_files, $File::Find::name;
                },
        }, "$directory" );

	foreach my $filepath (@package_files){

		my $filename = substr($filepath, length($directory));
		open(my $filehandle, "<", $filepath);
		unless( defined( $filehandle ) )
		{
			next;
		}
		close($filehandle);

		$filepath =~ m/[^\/]*$/;
		my $required_path = $archive_root . "/" . substr ($`, length($directory));

		mkpath($required_path);
		
		my $installed_path = $archive_root . $filename;

		if ( -e $installed_path and defined $backup_directory and !$force) {
			# Upgrade the installed file (if it is controlled by the previous version)
			
		# PATRICK what might this be doing?
			if( ! check_required_md5($repository,$package_name,$backup_directory,$installed_path) )
			{
				$message = "Config file has changed, not installing use --force to override";
				if ( ( substr $filename, 0, 9 ) ne "cfg/cfg.d" ) 
				{
					write_md5s($repository,$package_path,$file_md5s); 
					
					remove($repository, $package_name, 1);
					
					install($repository, $backup_directory, 1);

					$message = "Install Failed: $installed_path has been changed outside the package manager, use --force to override";
					return (1, $message);
				} 
			}
		}
			
		# Install the file, all that logic for this:
		copy($filepath, $installed_path);

		# Now some more logic to check it is installed
		# If it isn't failed and remove. 
		# It is is, write the (new) MD5 ready for upgrade/remove.

		if ( !-e $installed_path ) {
			#something went wrong time to pack up and go home...
			write_md5s($repository,$package_path,$file_md5s); 
			my ($rmrc, $rmmessage) = remove($repository, $package_name, 1);
			if ( defined $backup_directory) {
				install($repository, $backup_directory, 1);
			}
			$message = "Failed to install $filepath, installation aborted and reverted with message: " . $rmmessage;
			return(1, $message);
		} 

		my $md5 = "-";
		$md5 = md5sum($filepath);
		$file_md5s .= $installed_path . " " . $md5 . "\n"
	}


	# Write the md5s out to a file. 
	write_md5s($repository,$package_path,$file_md5s); 

	# Check the repository reloads
	my $install_failed = check_install($repository);
	if ($install_failed) {
		my ($rc2,$extra) = remove($repository,$package_name,1);
		$message = "Package Install Failed (compilation error), package was removed again with message: " . $extra;
		return ( 1, $message );
	}

	$repository->load_config();

	# Make any dataset upgrades (this is upgrade safe :) )
	my $schema_after = get_current_schema($repository);
	my $rc = install_dataset_diffs($repository,$schema_before,$schema_after);
	if ( $rc > 0 ) {
		my ($rc, $extra) = remove($repository,$package_name,1);
		return( 1, "Package Install Failed (failed to create datasets in database), package was removed again with message: " . $extra );
	}


	# Re-read spec file (ensures we have the installed one) 
	my $keypairs = read_spec_file($installed_spec_file);
	my $config_string = $keypairs->{configuration_file};
	my $new_version = $keypairs->{version};
	my $plugin_id = "Screen::".$config_string;
	my $plugin_path = $config_string;
	$plugin_path =~ s/::/\//g;
	$plugin_path = "EPrints/Plugin/Screen/" . $plugin_path . ".pm";

	my $plugin = $repository->get_repository->plugin( $plugin_id );

	if (defined $plugin) 
	{
		foreach my $inkey(keys %INC) {
			if ($inkey eq $plugin_path) {
				delete $INC{$inkey};
			}
		}

		$repository->load_config();
		
		# TODO: THIS SHOULD REALLY BE MOVED TO BEFORE THE WHOLE INSTALL IS DONE, SHOULD IT BE EXECUTABLE IS ANOTHER THING (may not ever implement)
		# if ($plugin->can( "action_preinst" )) 
		# {
		#	($return,my $preinst_msg) = $plugin->action_preinst();
		#	if ($return < 1 && $return > 0) {
		#		$message = $preinst_msg;
		#	} else {
		#		$message = "Package Install Failed (preinst failed with error: $preinst_msg), package was removed again with message: ";
		#	}
		# }

		# Call Post Install or Upgrade routine.

		if ($plugin->can( "action_postinst" ) and !$old_version) 
		{
			my ($return, $inst_msg) = $plugin->action_postinst();
			return( $return, "Package Install Failed with error ($inst_msg), package was removed again with message: " );
		} 
		
		if ($old_version && $plugin->can( "action_upgrade" )) 
		{
			my ($return, $inst_msg) = $plugin->action_upgrade($old_version, $new_version);
			return( $return, "Package Install Failed with error ($inst_msg), package was removed again with message: " );
		}

		# PATRICK im concerned we dont actually remove the package here.....
		return( 1, "Package Install Failed (postinst failed), package was removed again with message: " );

	}

	return ( 0, "Package Successfully Installed" );

}

sub get_current_schema
{
	my( $repo ) = @_;

	my $data = {};

	foreach my $datasetid ( $repo->get_sql_dataset_ids() )
	{
		my $dataset = $repo->dataset( $datasetid );
		$data->{$datasetid}->{dataset} = $dataset;
		foreach my $field ($repo->dataset( $datasetid )->fields)
		{
			next if defined $field->property( "sub_name" );
			$data->{$datasetid}->{fields}->{$field->name} = $field;
		}
	}

	return $data;
}

sub install_dataset_diffs
{
	my ($repo, $before, $after) = @_;
	
	my $db = $repo->get_db();

	my $rc = 0;

	foreach my $datasetid ( keys %$after )
	{
		my $dataset = $after->{$datasetid}->{dataset};
		my $fields = $after->{$datasetid}->{fields};

		if( !defined $before->{$datasetid} && !$db->has_dataset( $dataset ) )
		{
			$rc = $db->create_dataset_tables( $dataset );
			next;
		}

		foreach my $fieldid ( keys %$fields )
		{
			next if( defined $before->{$datasetid}->{fields}->{$fieldid} );
			$rc = $db->add_field( $dataset, $fields->{$fieldid} );
		}
	}
	
	return $rc;

}

sub remove_dataset_diffs
{
	my ($repo, $before, $after) = @_;
	
	my $db = $repo->get_db();

	my $rc = 0;

	foreach my $datasetid (keys %$before)
	{
		my $dataset = $before->{$datasetid}->{dataset};
		my $fields = $before->{$datasetid}->{fields};

		if( !defined $after->{$datasetid} && $db->has_dataset( $dataset ) )
		{
			$rc = $db->drop_dataset_tables( $dataset );
			next;
		}

		foreach my $fieldid ( keys %$fields )
		{
			next if( defined $after->{$datasetid}->{fields}->{$fieldid} );
			$rc = $db->remove_field( $dataset, $fields->{$fieldid} );
		}
	}
	
	return $rc;

}

sub check_install
{

	my ( $repository ) = @_;

	my ( $rc , $output ) = $repository->test_config();

	return $rc;

}

sub read_spec_file
{
        my ($spec_file) = @_;

        my $key_pairs;

        open (SPECFILE, $spec_file);
        while (<SPECFILE>) {
                chomp;
                my @bits = split(":",$_,2);
                my $key = $bits[0];
                my $value = trim($bits[1]);
                $key_pairs->{$key} = $value;
        }
        close (SPECFILE);

        return $key_pairs;

}

sub trim 
{
	my ($string) = @_;	
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;

}

sub check_required_md5
{
	my ( $repository, $package_name, $backup_dir, $installed_path ) = @_;

	my $md5_file = $backup_dir . "/checksums";
	
	my $archive_root = $repository->get_repository->get_conf("archiveroot");
	my $path_to_file = substr($installed_path, length($archive_root));

	open (MD5FILE, $md5_file);
	while (<MD5FILE>) {
		chomp;
		my @bits = split(/ /,$_);
		my $file = $bits[0];
		my $md5 = $bits[1];
		$file =~ s/$archive_root//;
		if ($file eq $path_to_file){
			my $installed_md5 = md5sum($installed_path);
			if ($installed_md5 eq $md5) {
				return 1;
			}
		}
	}
	close (MD5FILE);
	
	return 0;

} 

sub write_md5s 
{
	my ( $repository, $package_path, $file_md5s ) = @_;

	if ( defined $file_md5s) {
		my $md5_file = $package_path . "/checksums";
		open (MD5FILE, ">$md5_file");
		print MD5FILE $file_md5s;
		close(MD5FILE);
	}
}

sub make_backup 
{
	my ($repository, $package_name) = @_;
	
	my $backup_directory = File::Temp->newdir( CLEANUP => 1 );

	my $archive_root = $repository->get_repository->get_conf("archiveroot");
	my $epm_path = $archive_root . "/var/epm/packages/";
	my $package_path = $epm_path . "/" . $package_name;
	
	#TODO make this copy everything recusively
	my $spec_file = $package_path . "/" . $package_name . ".spec";
	my $md5_file = $package_path . "/checksums";
	my $datasets_file = $package_path . "/dataset_changes";

	copy($package_path . "/" . $package_name . ".spec", $backup_directory . "/" . $package_name . ".spec");
	copy($package_path . "/checksums", $backup_directory . "/checksums");
	if ( -e $datasets_file) {
		copy($package_path . "/dataset_changes", $backup_directory . "/dataset_changes");
	}
	#END TODO

	open (MD5FILE, $md5_file);
	while (<MD5FILE>) {
		chomp;
		my @bits = split(/ /,$_);
		my $file = $bits[0];
		my $md5 = $bits[1];
		
		my $path_separator = '/';
		$file =~ m/[^\Q$path_separator\E]*$/;
		my $required_dir = substr ($`, length($archive_root));
		my $required_path = $backup_directory . "/" . $required_dir;
		mkpath($required_path);
		my $file_sub = substr($file, length($archive_root));

		if ( -e $file ) {
			copy($file,$backup_directory . "/" . $file_sub);
		}
	}
	close (MD5FILE);
	return $backup_directory;
}


sub remove
{
	my ($repository, $package_name, $force) = @_;
	
	my $archive_root = $repository->get_repository->get_conf("archiveroot");
	my $epm_path = $archive_root . "/var/epm/packages/";
	my $package_path = $epm_path . "/" . $package_name;
	
	my $spec_file = $package_path . "/" . $package_name . ".spec";
	my $md5_file = $package_path . "/checksums";
	my $dataset_file = $package_path . "/dataset_changes";

	if ( !-e $spec_file and $force < 1) {
                
		return (1,"Cannot locate installed package : " . $package_name);
		
	}
			
	$repository->load_config();
	
	my $keypairs = EPrints::EPM::read_spec_file($spec_file);
	my $config_string = $keypairs->{configuration_file};
	my $plugin_id = "Screen::".$config_string;

	my $plugin = $repository->get_repository->plugin( $plugin_id );

	my $return = 0;
	my $message;
	if (defined $plugin) 
	{
		if ($plugin->can( "action_prerm" )) 
		{
			($return,my $prerm_msg) = $plugin->action_prerm();
			if ($return < 1 && $return > 0) {
				$message = $prerm_msg;
			} else {
				$message = "Package cannot be removed as the packages pre-remove script failed.";
			}
		} 
		if (!$return && $plugin->can( "action_removed_status" ))
		{
			$return = $plugin->action_removed_status();
			$message = "Package cannot be removed as the packages pre-remove script failed.";
		}
	} 

	if ($return > 0) {
		return ($return,$message);
	}

	my $pass = 1;
	my @files;

	open (MD5FILE, $md5_file);
	while (<MD5FILE>) {
		chomp;
		my @bits = split(/ /,$_);
		my $file = $bits[0];
		my $md5 = $bits[1];
		my $config_file = 0;
		my $file_end = substr($file, length($archive_root)+1);
		if ( ( substr $file_end, 0, 9 ) eq "cfg/cfg.d" ) {
			$config_file = 1;
		}
		push @files, $file;
		if ( -e $file and !$config_file) {
			my $re_check = md5sum($file);
			if (!($re_check eq $md5)) {
				$pass = 0;
			}
		}
	}
	close (MD5FILE);

	if ($pass != 1 and $force != 1 ) {
	
                return (1,"Warning: Package has changed since install! Use --force to override");

	}  
	
	my $backup_directory = make_backup($repository, $package_name);
	
	my $schema_before = get_current_schema($repository);
	my $rc = 0;
	my $failed_flag = 0;

	my $remove_auto = 0;

	foreach my $file (@files) {
		if ( -e $file ) {

			if (index($file,"static/style/") > 0) {
				$remove_auto = 1;				
			}

			$rc = unlink $file;
			if ($rc != 1) {
				$failed_flag = 1;
			}
		}
	}
	
	if ($failed_flag != 0) {
		
		install($repository, $backup_directory, 1);

		return (1,"Warning: Failed to remove package! Use --force to override");
			
	}
	
	if ($remove_auto > 0) {
		remove_auto($repository);
	}

	my $installed = check_install($repository);
	
	$repository->load_config();
	my $schema_after = get_current_schema($repository);
	remove_dataset_diffs($repository,$schema_before,$schema_after);

	rmtree($package_path);

	return (0,"Package Successfully Removed");

}

sub remove_auto {
	
	my ( $repository ) = @_;

	my $archive_root = $repository->get_repository->get_conf("archiveroot");
	my $style_path = $archive_root . "/html/en/style/";

	rmtree($style_path);
	
	my $javascript_path = $archive_root . "/html/en/javascript/";

	rmtree($javascript_path);
	
}

sub md5sum
{
	my $file = shift;
	my $digest = "";
	eval{
		open(FILE, $file) or die "Can't find file $file\n";
		my $ctx = Digest::MD5->new;
		$ctx->addfile(*FILE);
		$digest = $ctx->hexdigest;
		close(FILE);
	};
	if($@){
		print $@;
		return "";
	}
	return $digest;
}

sub get_installed_epms 
{
	my ($repository) = @_;

	my $archive_root = $repository->get_repository->get_conf("archiveroot");
	my $epm_path = $archive_root . "/var/epm/packages/";

	my $installed_epms = get_local_epms($epm_path);

	return $installed_epms;

}

sub get_cached_epms 
{
	my ($repository) = @_;

	my $archive_root = $repository->get_repository->get_conf("archiveroot");
	my $epm_path = $archive_root . "/var/epm/cache/";

	my $cached_epms = get_local_epms($epm_path);

	return $cached_epms;

}

sub get_local_epms 
{
	my ($epm_path) = @_;

	if ( !-d $epm_path ) {
		return undef;
	}

	my @packages;
	my $rc;

	opendir(my $dh, $epm_path) || die "failed";
	while(defined(my $fn = readdir $dh)) {
		my $short = substr $fn, 0 , 1;
		my $package_name = $fn;

		next if ($short eq ".");

		my $spec_path = $epm_path . $fn . "/" . $package_name . ".spec";
		my $keypairs = EPrints::EPM::read_spec_file($spec_path);
		push @packages, $keypairs;
	}
	closedir ($dh);

	return \@packages;

}

sub get_epm_updates 
{
        my ( $installed_epms, $store_epms ) = @_;

        my @apps;

        foreach my $app (@$installed_epms) {
                foreach my $store_app (@$store_epms) {
                        next if ("$app->{package}" ne "$store_app->{package}" && !$store_app->{version} gt $app->{version}); 
                      	push @apps, $store_app;

                }
        }

        if ( scalar @apps < 1) {
                return undef;
        }

        return \@apps;
}

sub retrieve_available_epms
{
	my( $repository, $id ) = @_;

	my @apps;

	my $sources = $repository->config( "epm_sources" );
	$sources = [] if !defined $sources;

	SOURCE: foreach my $epm_source (@$sources) {

		my $url = $epm_source->{base_url} . "/cgi/search/advanced/export__XML.xml?screen=Public%3A%3AEPrintSearch&_action_export=1&output=XML&exp=0|1|-date%2Fcreators_name%2Ftitle|archive|-|type%3Atype%3AANY%3AEQ%3Aepm|-|eprint_status%3Aeprint_status%3AALL%3AEQ%3Aarchive|metadata_visibility%3Ametadata_visibility%3AALL%3AEX%3Ashow";

		my $tmp = File::Temp->new;

		$url = URI->new( $url )->canonical;
		my $ua = LWP::UserAgent->new;
		my $r = $ua->get( $url, ":content_file" => "$tmp" );

		seek($tmp,0,0);

		my $xml = eval { $repository->xml->parse_file( "$tmp" ) };
		next SOURCE if $@;

		EPRINT: foreach my $node ($xml->documentElement->getElementsByTagName( "eprint" ))
		{
			my $app = get_app_from_eprint( $repository, $node );
			next EPRINT if !defined $app;
			return $app if defined $id && $id eq $app->{id};
			push @apps, $app;
		}
	}
	return undef if defined $id;

	return \@apps;
}

sub get_app_from_eprint
{
	my( $repo, $node ) = @_;

	my $epdata = EPrints::DataObj::EPM->xml_to_epdata( $repo, $node );

	return undef if !defined $epdata->{eprintid};

	my $app = {};
	$app->{id} = $epdata->{eprintid};
	$app->{title} = $epdata->{title};
	$app->{uri} = $epdata->{id};
	$app->{date} = $epdata->{datestamp};
	$app->{package} = $epdata->{package_name};
	$app->{description} = $epdata->{abstract};
	$app->{version} = $epdata->{package_version};

	my $match_id;
	foreach my $document (@{$epdata->{documents}})
	{
		my $content = $document->{content};
		$content = "" if !defined $content;
		my $format = $document->{format};
		$format = "" if !defined $format;
		if( $format eq "archive/zip+eprints_package" )
		{
			$app->{epm} = $document->{files}->[0]->{url};
		
			$match_id = $document->{docid};
			next;
		} 

		foreach my $relation (@{$document->{relation}})
		{
			next if $relation->{type} !~ m# ^http://eprints\.org/relation/is(\w+)ThumbnailVersionOf$ #x;
			my $type = $1;
			next if $relation->{uri} !~ m# ^/id/document/$match_id$ #x;
			my $thumb_url = $document->{files}->[0]->{url};
			if ($type eq "preview") {
				$app->{'icon_url'} = $thumb_url;
			}
			$app->{'thumbnail_'.$type} = $thumb_url;
			#substr($thumb_url, length($thumb_url) - length($document->{main}) - 1, 0) = ".has${type}ThumbnailVersion";
			#print STDERR "Thumb URL: " . $thumb_url . "\n\n";
		}
		
	}

	return $app;
}

sub verify_app
{
	my ( $app ) = @_;

	my $message;

	if (!defined $app->{package}) { $message .= " package "; }
	if (!defined $app->{version}) { $message .= " version "; }
	if (!defined $app->{title}) { $message .= " title "; }
	if (!defined $app->{icon}) { $message .= " icon "; }
	if (!defined $app->{description}) { $message .= " package description "; }
	if (!defined $app->{creator}) { $message .= " creator "; }

	if (defined $message) {
		return (0, $message);
	}

	return (1,undef);

}

1;

=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2000-2011 University of Southampton.

=for COPYRIGHT END

=for LICENSE BEGIN

This file is part of EPrints L<http://www.eprints.org/>.

EPrints is free software: you can redistribute it and/or modify it
under the terms of the GNU Lesser General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

EPrints is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
License for more details.

You should have received a copy of the GNU Lesser General Public
License along with EPrints.  If not, see L<http://www.gnu.org/licenses/>.

=for LICENSE END

