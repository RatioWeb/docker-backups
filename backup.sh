#!/bin/bash
# This script is a generic solution for making backups in our infrastructure.
# It depends on duplicity and backup in a form of FTP server.
# FTP credentials can be provided as environement variables, or as script arguments.


#
# This function push backup to backup server
# 
# Arguments
# - $1 container name
# - $2 backup type
# - $3 source directory
#
function push_backup {
    date=`date +%Y-%m-%d`;
    docker run -e FTP_PASSWORD=$FTP_PASSWORD --rm  -v $3:/tmp/backup-$date  chardek/duplicity --allow-source-mismatch  --no-encryption /tmp/backup-$date ftp://$LOGIN@$HOST/$1/$2
}

#
# This function clear backups older than 1 month from backup server.
#
# - $1 container name
# - $2 backup type
#
function clear_old_backup {
    docker run -e FTP_PASSWORD=$FTP_PASSWORD --rm  chardek/duplicity remove-older-than 1M --force ftp://$LOGIN@$HOST/$1/$2
}

#
# This function created backup of selected volume in container
#
# - $1 container name
# - $2 argument line (generic|container|volume_path)
#
function generic_backup_handler {
    path=`echo $2|cut -d '|' -f 3`
    echo "Creation of backup of "$1":"$path;
    docker run -e FTP_PASSWORD=$FTP_PASSWORD --rm --volumes-from $1 chardek/duplicity --allow-source-mismatch --no-encryption $path ftp://$LOGIN@$HOST/$1/generic/$path
    clear_old_backup $1 "generic/$path"
}

#
# This function creates backup of mysql container
#
# - $1 container name
#
function postgres_backup_handler {
    echo "Creation of postgres backup for container $1";
    dump=$1"_dump_"`date +%Y-%m-%d`".sql";
    mkdir -p "postgresdumps_backups";
    docker exec $1 -u postgres sh -c 'exec pg_dumpall' > "./postgresdumps_backups/"$dump;
    bzip2 "./postgresdumps_backups/"$dump;

    # Publish backup
    push_backup $1 "postgres" "`pwd`/postgresdumps_backups";
    clear_old_backup $1 "postgres"

    # Post publication cleanup.
    rm -rf "./postgresdumps_backups";
}


function mysql_backup_handler {
    echo "Creation of mysql backup for container $1";
    dump=$1"_dump_"`date +%Y-%m-%d`".sql";
    mkdir -p "mysqldumps_backups";
    docker exec $1 sh -c 'exec mysqldump --all-databases -uroot -p"$MYSQL_ROOT_PASSWORD"' > "./mysqldumps_backups/"$dump;
    bzip2 "./mysqldumps_backups/"$dump;

    # Publish backup
    push_backup $1 "mysql" "`pwd`/mysqldumps_backups";
    clear_old_backup $1 "mysql"

    # Post publication cleanup.
    rm -rf "./mysqldumps_backups";
}

#
# This function creates backup of mongodb container
#
# - $1 container name
#
function mongodb_backup_handler {
    echo "Creation of mongodb backup for container $1";
    dump=$1"_dump_"`date +%Y-%m-%d`;
    mkdir -p "mongodbdumps_backups";

    docker exec $1 "cd /tmp && mkdir -p $dump";
    docker exec $1 "cd /tmp/$dump && mongodump";
    docker cp $1:/tmp/$dump `pwd`"/mongodbdumps_backups"

    # Publish backup
    push_backup $1 "mongodb" `pwd`"/mongodbdumps_backups";
    clear_old_backup $1 "mongodb"

    # Post publication cleanup.
    rm -rf "./mongodbdumps_backups";
}

#
# This function created backup of gitlab container
#
# - $1 container name
#
function gitlab_backup_handler {
    echo "Creation of gitlab backup for container $1";
    mkdir -p "./gitlab_backups";
    docker exec -t $1 sh -c 'gitlab-rake gitlab:backup:create';
    echo "Copying gitlab backups";
    docker cp $1:/var/opt/gitlab/backups/ "`pwd`/gitlab_backups";

    push_backup $1 "gitlab" "`pwd`/gitlab_backups";
    clear_old_backup $1 "gitlab"

    # Post publication cleanup.
    rm -rf "./gitlab_backups_backups";
}


function show_help() {
   cat << EOF
   Usage: ${0##*/} -l [FTP LOGIN] -h [FTP HOST] -p [FTP PASSWORD] -f [SPECIFICATION FILE]  

   Make backup using backups specification from [SPECIFICATION FILE]
   
       -h          display this help and exit
       -f [SPECIFICATION FILE]  load specification file. 
       -l [FTP LOGIN] FTP backup server login
       -p [FTP PASSWORD] FTP backup server backup
       -h [FTP HOST] FTP backup server host

EOF
}

# Parse options.
while getopts "h:p:l:f:" opt;do
    case "$opt" in
        h)
            HOST=$OPTARG;
        ;;
        p)
            FTP_PASSWORD=$OPTARG;
        ;;
        l)
            LOGIN=$OPTARG;
        ;;
        f)
            FILE=$OPTARG;
            ;;
        '?')
            show_help >& 2
            exit 0;
    esac
done;


current_path=$(pwd);
FILE=`realpath $FILE`
cd `dirname $0`

# Main loop - go through lines of file and 
while read -r line || [[ -n "$line" ]]; do
    type=`echo $line|cut -f 1 -d '|'`;
    container=`echo $line|cut -f 2 -d '|'`;

    if  $(declare -f $type"_backup_handler" > /dev/null); then
        $type"_backup_handler" $container $line;
    else
        echo "Function "$type"_backup_handler doesn't exist";
        exit 1;
    fi;
done < "$FILE";

cd $current_path;
