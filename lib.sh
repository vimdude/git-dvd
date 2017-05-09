# Copyright (C) 2017  Abdel Said <tafnzart@gmail.com>
#
# This program is free software: you can redistribute it and/or modify it under the terms of version 3 of the GNU
# General Public License as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#

set -e

gitdvd_wait_msg() {
  echo "git-dvd: $1" 
  sleep 2
}

gitdvd_info_msg() {
  echo "git-dvd: $1" 
}


gitdvd_bail_out() {
  echo "git-dvd: $1" >&2   ## Send message to stderr
  exit "${2:-1}"  ## Return a code specified by $2 or 1 by default.
}

gitdvd_checkfiles() {
  tracksize=$( echo $1 | sed 's/GB/ * 1000 MB/;s/MB/ * 1000 KB/;s/KB/ * 1000/; s/$/ +\\/; $a0' | bc )
	while read file; do
    eval $file
    if [[ $filesize -lt $tracksize ]]; then
			return
		else
			gitdvd_info_msg "file $filepath larger than track size. skipped"
    fi
  done < <(git annex find --in=here --not --metadata dvd=skip --format='filesize=${bytesize} filepath=${file}\n' )
	gitdvd_bail_out "no file to burn on dvd"
  exit
}

gitdvd_create() {
	if ! [ -x "$(command -v cdrwtool)" ]; then
		gitdvd_bail_out "command cdrwtool not installed."
	fi

	if ! [ -x "$(command -v uuidgen)" ]; then
		gitdvd_bail_out "command uuidgen not installed."
	fi

	if ! [ -x "$(command -v growisofs)" ]; then
		gitdvd_bail_out "command growisofs not installed."
	fi

	while true; do
		dvdid=dvd-$(uuidgen)
		dvdtmpdir=$dvdid
		dvdudf=$dvdtmpdir/udf
		dvdpath=/mnt/cdrom
		dvdgitdir=$dvdpath/$dvdid

		gitdvd_info_msg "getting track size for next dvd"
		tracksize=`cdrwtool -i -d /dev/sr0 2>&1 | grep track_size | sed 's/.*(\([^)]\+\).*/\1/'`
		if [ -z "$tracksize" ]; then
			gitdvd_wait_msg "no blank dvd detected. please insert a blank dvd or cntl-c to stop ..."
			continue
		fi

    gitdvd_checkfiles $tracksize

		gitdvd_info_msg "creating dvd temp dir $dvdid ..."
		mkdir $dvdtmpdir || gitdvd_bail_out "failed to create dvd temp dir $dvdid ..."

		gitdvd_info_msg "creating udf volume for files not yet on dvds ..."
		truncate --size=$tracksize $dvdudf
		mkudffs --lvid="$dvdid" --utf8 $dvdudf > /dev/null 2>&1
		mount -oloop,rw $dvdudf $dvdpath
		git init --quiet $dvdgitdir
		cd $dvdgitdir
		git annex init --quiet "$dvdid"
		git annex upgrade --quiet
		cd - > /dev/null

		gitdvd_sync_files "$dvdgitdir"
		gitdvd_annex_files "$dvdgitdir" "$dvdid"

		gitdvd_info_msg "adding remote $dvdid $dvdpath/$dvdid to repo..."
		git remote add $dvdid $dvdpath/$dvdid

		gitdvd_info_msg "fetching remote $dvdid ..."
		git fetch $dvdid

		gitdvd_info_msg "making remote $dvdid read-only..."
		git config --local remote.$dvdid.annex-readonly true
		git annex sync

		# to fix location logs so that git annex whereis works
		gitdvd_info_msg "running git annex fsck ..."
		git annex fsck --quiet --fast --from $dvdid

		git annex metadata --quiet --in $dvdid --set dvd=skip --force

		gitdvd_info_msg "unmounting $dvdpath..."
		umount $dvdpath

		gitdvd_info_msg "burning iso ..."
		growisofs -dvd-compat -Z /dev/sr0=$dvdudf

		gitdvd_info_msg "cleaning up..."
		rm -rf ${dvdtmpdir}

		gitdvd_info_msg "dvd $dvdid created successfully. please mark this dvd as $dvdid for easy retrieval."
	done

	gitdvd_info_msg "done"
}

gitdvd_annex_files() {
  dvdgitdir=$1
  dvdid=$2
  (
  cd $dvdgitdir
  while true; do
    git annex add --quiet --include-dotfiles > /dev/null 2>&1 || {
      file=`git ls-files --other | tail -n 1`
      if [ ! -z "$file" ]; then
        rm -f "$file"
        continue
      fi
    }
    break
  done
  while true; do
    git commit -m "initial $dvdid" > /dev/null 2>&1 || {
      file=`git ls-files --cached | tail -n 1`
      if [ ! -z "$file" ]; then
        link=`readlink $file | sed 's/^.*.git/.git/'`
        # free space
        echo > $link
        git annex drop --force $file > /dev/null 2>&1 || true
        rm -f "$file" || true
        git rm --cached "$file" > /dev/null 2>&1 || true
        continue
      fi
    }
    break
  done
  cd - > /dev/null
  ) &
  wait
}

gitdvd_sync_files() {
  (
  dvdgitdir=$1
  nofile=true
  while read file; do
    rsync -aRL "$file" $dvdgitdir > /dev/null 2>&1
    if [ "$?" -eq "0" ]; then
      # file ok, get next
      nofile=false
      continue
    elif [ "$?" -eq "11" ]; then
      # dvd is full, ready to annex
      break
    else
      gitdvd_bail_out "sync files with rsync failed"
    fi
  done < <(git annex find --in=here --not --metadata dvd=skip)
  ) &
  wait
}

gitdvd_startover() {
	gitdvd_info_msg "removing metadata dvd on all files"
  ( git annex metadata --quiet --remove dvd --force ) & wait
	gitdvd_info_msg "done"
}

gitdvd_dead() {
  dvdid=$1
	gitdvd_info_msg "marking remote $dvdid as dead"
  ( git annex dead $dvdid ) & wait
	( git annex forget --drop-dead --force ) & wait
	( git remote remove $dvdid ) & wait
	gitdvd_info_msg "done"
}
