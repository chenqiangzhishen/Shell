#!/bin/bash
#
# The downloadAugusta script downloads the specified Augusta VM image.
# 
# FEATURES:
# - download up to 2 times faster
# - only changed image blocks are downloaded
# - sparse image file is used to minimize space
# - automatic daily image download via crontab
# - keeps multiple daily images
# - automatically deletes older images
#
# DEFAULTS:
# - Default download directory 		= ~/augusta
# - Number of daily images to keep	= 7
#
# LOCAL TESTING:
# 1) Make mock test directory: 
#		mkdir -p /tmp/augusta/2013-11-12/KVM/
# 2) Copy augusta.qcow2 image and install.sh files to test directory
# 3) Run local download: 
#		downloadAugusta -h localhost -s /tmp/augusta -d 2013-11-12 kvm
#
# Author: Dave Christenson
#

# Uncomment this line to enable debug mode
#set -x

# Script name
g_script_name=downloadAugusta

# Global variables - default values
g_user=$USER
g_password=""
g_host=gsax-pro.labs.lenovo.com
g_source_dir=/ifs/rtpgsa/projects/a/augusta
g_dest_dir="$HOME/augusta"
g_build_fork=1.0
g_build_subdir="/"
g_rsync_options="-av --progress --sparse"
g_max_image_files=7 # Keep up to 7 image files
g_hidden_current_image_dir='.current_image'
g_protocol=""

# Print help
usage() {
	echo "usage: $g_script_name [options] image_type"
	echo ""
	echo "  image_type  'kvm', 'vmware' or 'vhd'"
	echo ""	
	echo "OPTIONS:"
	echo "  -f  Select the build fork 0.1 or 2.0.  Default is $g_build_fork."
    echo "  -b  Select build image sub-directory.  Default is to select most recent build."
	echo "  -t  Target (destination) directory. Default is ${g_dest_dir}."
	echo "  -s  Server's source directory.  Default is ${g_source_dir}."
	echo "  -k  Number of daily images to keep.  Default is ${g_max_image_files}."
	echo "  -u  User name.  Default is ${g_user}."	
	echo "  -h  Host name.  Default is ${g_host}." 
	echo "  -p  Protocol.  Values are lftp or rsync."
	echo ""
	echo "EXAMPLES:"
	echo "  $g_script_name kvm                              # Download kvm image to ~/download directory"
	echo "  $g_script_name -k 10 vmware                     # Download VMware image, keeping last 10 images"
	echo "  $g_script_name -b 1.0-298 vmware       			# Download VMware image for build 1.0-298"
	echo "  $g_script_name -f 2.0 vmware       				# Download latest VMware image from fork 2.0"
	echo "  echo mypassword | $g_script_name kvm            # Run without password prompt"
	echo ""
	echo "CRONTAB:"
	echo "  Download daily image at 4 AM every day:"
	echo "    $ crontab -e"
	echo "    0 4 * * *   echo password | $HOME/bin/$g_script_name vmware >> $HOME/augusta/downloadAugusta.log 2>&1"	
	exit 0
}

# main function
main() {
        if (( $# == 0 )); then
                usage
        fi
		# Parse options.  Properly option values with spaces.
        g_xxx_ref=
        while (( $# > 1 )) || [[ $1 = -* ]]; do
               case "$1" in
		        -t) g_xxx_ref=g_dest_dir;               g_dest_dir=;;
		        -s) g_xxx_ref=g_source_dir;             g_source_dir=;;
		        -k) g_xxx_ref=g_max_image_files;        g_max_image_files=;;
		        -u) g_xxx_ref=g_user;               	g_user=;;
		        -h) g_xxx_ref=g_host;               	g_host=;;
                -b) g_xxx_ref=g_build_subdir;       	g_build_subdir=;;
                -f) g_xxx_ref=g_build_fork;     		g_build_fork=;;
                -p) g_xxx_ref=g_protocol;			    g_protocol=;;
                        -*) usage;;
                        # save argument value using indirect reference to g_xxx variable		
                        *) if [ -z "${!g_xxx_ref}" ]; then
                                declare $g_xxx_ref="$1" # save first or only argument value
                           else
                                declare $g_xxx_ref+=" $1" # save space separated argument value
                           fi;;                          
	        esac                
                shift
	done
	
	local temp_server=0
	if [ "$g_host" == 10.240.80.241 ] || [ "$g_host" == ait-move-backup.labs.lenovo.com ]; then
		temp_server=1
	fi
	
	# Append fork to source directory path
	# (the fork sub-directory is only present in the GSA path and not on the temporary build image server)
	if [ "$g_build_fork" != "" ] && [ $temp_server == 0 ]; then
		g_source_dir+=/$g_build_fork
	fi

    # Get 'image_type' positional parameter
	local image_type=$1

	local image_type_subdir=
	if [ "$image_type" == kvm ]; then
		image_type_subdir=KVM
	elif [ "$image_type" == vmware ]; then
		image_type_subdir=OVA
        elif [ "$image_type" == vhd ]; then
		image_type_subdir=VHD
	else
		echo "Invalid image type '$image_type'.  Must be 'kvm', 'vmware' or 'vhd'." > /dev/stderr
		exit 1
	fi
        	
	# Verify that destination directory exists
	if [ ! -d "$g_dest_dir" ]; then
		echo "Destination directory '$g_dest_dir' not found."
		exit 1
	fi 
	
	# No protocol specified?
	if [ "$g_protocol" == "" ]; then
		# Subsequent download of image?
		if [ -d "$g_dest_dir/$g_hidden_current_image_dir" ]; then
			g_protocol=rsync
		else
			g_protocol=lftp
		fi
	fi
	
	# Invalid protocol specified?
	if [ "$g_protocol" != rsync ] && [ "$g_protocol" != lftp ]; then
		echo "Invalid -p option value '$g_protocol'.  Valid values are 'rsync' or 'lftp'." > /dev/stderr
		exit 1
	fi
       
	# Read password from stdin 
	read -p "${g_user}@${g_host}'s password: " -s g_password
	echo ""

	# Do wildcard match on daily build directory
	local output=''
	# Testing with localhost?
	if [ "$g_host" == localhost ]; then		
		output=$(ls .)
	else
		if [ $temp_server == 1 ]; then
			output=$(run_expect "$g_password" "lftp -e 'cls -1 --sort=date -q ${g_source_dir} | grep $g_build_subdir; exit' sftp://${g_user}@${g_host}")
		else
			# host name contains dash?
			if echo $g_host | grep '-' > /dev/null; then
				local g_host=$(host $g_host)
				g_host=${g_host##* }								
			fi			
			output=$(run_expect $g_password "lftp -e 'cls -1 --sort=date -q ${g_source_dir} | grep /$g_build_fork/ | grep $g_build_subdir; exit' ftp://${g_user}@${g_host}")		
		fi
		(( $? )) && exit $? # Exit on bad return code from expect
	fi
        
    # Select most recent matching build 
    local build_dir
	while read -r line; do
		echo $line
		# This is an output line from lftp cls?
		if echo $line | grep $g_source_dir/ >/dev/null; then    	
		   build_dir=${line%\/*} # Remove slash at end of directory	
           break	
        fi
	done <<< "$output"
	    
	# Image directory with matching build found?
	if echo $build_dir | grep $g_build_subdir >/dev/null; then		
		g_source_dir="$build_dir"
		g_build_subdir=${build_dir##*\/}		
		echo "Selected image directory: $g_host:$g_source_dir"
	else
		echo "No image directory match for '$g_build_subdir' found in '${g_host}:${g_source_dir}'." > /dev/stderr		
		exit 1
	fi	
		
	# Download the most recent Augusta image
	# Use rsync if this is a subsequent download?	
	if [ "$g_protocol" == rsync ]; then
		run_expect "$g_password" "TIME='Download Time=%E' time rsync $g_rsync_options ${g_user}@${g_host}:${g_source_dir}/$image_type_subdir/ '$g_dest_dir/$g_hidden_current_image_dir/$image_type_subdir/'"
	else # use lftp on first download
		mkdir -p "$g_dest_dir/$g_hidden_current_image_dir/$image_type_subdir"		
		if [ $temp_server == 1 ]; then				
			run_expect $g_password "TIME='Download Time=%E' time lftp -e 'mirror --use-pget-n=5 ${g_source_dir}/$image_type_subdir $g_dest_dir/$g_hidden_current_image_dir/$image_type_subdir; exit' sftp://${g_user}@${g_host}"
		else
			run_expect $g_password "TIME='Download Time=%E' time lftp -e 'mirror --use-pget-n=5 ${g_source_dir}/$image_type_subdir $g_dest_dir/$g_hidden_current_image_dir/$image_type_subdir; exit' ftp://${g_user}@${g_host}"
		fi
	fi
	
	# Copy image file so it isn't overlaid on the next scheduled rsync
	mkdir -p "$g_dest_dir/$g_build_subdir/$image_type_subdir"
	echo -e "\nCopying image file to $g_dest_dir/$g_build_subdir/$image_type_subdir..."
	# cp -u will skip files that are newer than the downloaded file. 
        # We don't want to update an VM image file that is currently running.
	cp -ur --sparse=never "$g_dest_dir/$g_hidden_current_image_dir/$image_type_subdir/"* "$g_dest_dir/$g_build_subdir/$image_type_subdir/"
	# KVM needs read/write/execute permission on all directories
	# Otherwise, it will complain that it doesn't have search permission	
	find "$g_dest_dir/$g_build_subdir/$image_type_subdir" -type d -exec chmod +rwx {} \;
	find "$g_dest_dir/$g_build_subdir/$image_type_subdir" -type f -exec chmod +rw {} \;
	find "$g_dest_dir/$g_build_subdir/$image_type_subdir" -type f -name install.sh -exec chmod +x {} \;

	# Clean up old image files
	local dirs=''
	for dir in $(ls -tr "$g_dest_dir"); do
		# This is a directory and not a file?
		if [ -d "$g_dest_dir/$dir" ]; then
			dirs+=" $g_dest_dir/$dir"						
		fi
	done
	local image_dir_array=($dirs)	
	local i=0
	while (( ${#image_dir_array[@]} > $g_max_image_files )); do
		dir=${image_dir_array[$i]}
		unset image_dir_array[$i]
		((i++))
		if [ -d "$dir" ]; then
			echo "Deleting old image directory '$dir'"
			# Try to delete without root authority first...
			if ! rm -r "$dir"; then
				sudo rm -r "$dir"						
			fi
		fi
	done

	echo "Image files downloaded to $g_dest_dir/$g_build_subdir/$image_type_subdir"
}

# Expect function use to automatically enter password
# $1 password
# $2 command
run_expect() {
	# input arguments
	password=$1
	command=$2
	
	# Export environment that must be accesed by expect	
	export password
	export command

	# Use expect to automatically enter the password
	expect <<- DONE	
	  	set timeout -1
		
	  	spawn bash -c "$::env(command)"
		
		match_max 100000

	  	# Look for passwod prompt
	  	expect "*?assword:*"
	  	# Send password $::env(password)	
	  	send -- "$::env(password)\r"
	  	# send blank line (\r) before eof
	  	send -- "\r"
	  	expect eof		
		set waitval [wait]
		set exval [lindex $waitval 3]
		exit $exval
	DONE
	# Bad exit code from expect?
	rc=$?
	if [ "$rc" != 0 ]; then
		echo "Expect error exit code $rc" >/dev/stderr
		exit $rc
	fi	
}

main $@

