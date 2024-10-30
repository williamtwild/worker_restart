#!/usr/bin/bash

################################################################################
# add the following to the crontab 
# * * * * * /home/{user}/{path_to}/worker_restart.sh
################################################################################
#
# vars and config file restart_script.config loading 
#
################################################################################
global_script_array=()
#
# example of the format of the restart_script.config file
#
#  global_this_server="none"
#  global_log_to_screen=1
#  global_log_to_file=1
#  global_user_owner="root"
#  global_email_to="none@gmail.com"
#  global_email_from="none@none.com"
#  global_email_from_name="None"
#  global_email_sendgrid_key="bogus_key"
#  global_project_path="/home/$global_user_owner/project_directory"
#  global_healthcheck_token="bogus_token"

# i use the screen_name for the array to append to the global_array
# the screen name is always different for each script. you can use anything really as
# long as they are unique in the global_script_array. tried to dynamically use the screen_name
# var to declare the argument array but declare does not like arrays and eval is too risky
# if you mistype something. 
#  script_root_name="name_of_script"
#  screen_name="name_of_the_screen_to_target"
#  process_grep="python_node_etc"
#  script_command="$script_root_name.py maybe_some_arguments"
#  start_with="python2_node_etc"
#  script_path="/home/$global_user_owner/{project_directory}/{directory_of_the_script_to_check_and_start}"
#  name_of_the_screen_to_target=( "$script_root_name" "$script_command" "$screen_name" "$process_grep" "$start_with" "$script_path" )
#  global_script_array+=("name_of_the_screen_to_target")
#
#
# end sample 
#
#
#
# set the path to the config. all paths should be absolute since we are 
# running with the cron
#

wdir="$PWD"; [ "$PWD" = "/" ] && wdir=""
case "$0" in
  /*) scriptdir="${0}";;
  *) scriptdir="$wdir/${0#./}";;
esac
config_script_path="${scriptdir%/*}"


if ! test -f "$config_script_path/restart_script.config"; then
    echo "no config found . exiting. "
    exit 0
fi
source "$config_script_path/restart_script.config"

global_path_for_files=$config_script_path

################################################################################
#
# functions
#
################################################################################

ping_healthcheck() {
    # i use healthchecks.io for my alerting service
    curl -m 10 --retry 5 -s https://hc-ping.com/$global_healthcheck_token >> /dev/null
}

send_email() {
    # i use sendgrid for email processing 
    subject=$1
    body=$2
    email_command=`curl -s --request POST --url https://api.sendgrid.com/v3/mail/send --header 'Authorization: Bearer '$global_email_sendgrid_key'' --header 'Content-Type: application/json' --data '{"personalizations": [{"to": [{"email": "'"$global_email_to"'"}]}],"from": {"email": "'"$global_email_from"'", "name":"'"$global_email_from_name"'" },"subject": "'"$subject $global_this_server"'","content": [{"type": "text/plain", "value": "'"$body"'"}]}'`
}

log_this() {
    text_to_log=$1
    (( $global_log_to_file > 0 )) && echo `date +%F" "%T` "$text_to_log" >> "$global_path_for_files/restart.log"
    (( $global_log_to_screen > 0 )) && echo `date +%F" "%T` "$text_to_log"
}




check_script() {
    sleep .2
    script_root_name="$1"
    script_command="$2"
    screen_name="$3"
    process_grep="$4"
    start_with="$5"
    script_path="$6"
    # i use the screen name since they are always unique. 
    script_email_count_filename="email_count.$screen_name"
    script_running_count_filename="running_count.$screen_name"
    screen_start_count_filename="screen_count.$screen_name"
    #
    #
    # first see if the screen exists and if it doees not try to create the session
    # if it cannot create the session then just bail and dont try to run the script  
    # but contine to try and create the screen for some cycles and then bail   
    if ! screen -list | grep "$screen_name" >> /dev/null; then 
        log_this "$screen_name screen not found"
        if test -f "$global_path_for_files/$screen_start_count_filename";
            then
                log_this "    $screen_start_count_filename exists."
                screen_count=$(<"$global_path_for_files/$screen_start_count_filename")
                log_this "    loaded $screen_count from $screen_start_count_filename"
                ((screen_count=screen_count+1))
            else
                echo 1 > "$global_path_for_files/$screen_start_count_filename"
                screen_count=1
        fi

        if (( $screen_count < 5 )); 
            then
                send_email "screen not found $screen_name $screen_count" "$version"
                sudo -u $global_user_owner screen -dmS $screen_name
                sleep .1
                sudo -u $global_user_owner screen -S $screen_name -p 0 -X stuff "cd $script_path ^M"
                sleep .5
                if ! screen -list | grep "$screen_name" >> /dev/null; 
                    then
                        log_this "    $screen_name creation failed."
                        send_email "creation failed $screen_name" "$version"
                        return 0
                    else
                        rm "$global_path_for_files/$screen_start_count_filename"
                        log_this "    $screen_name creation success"
                fi
            else
                if (( $screen_count == 5 )); then
                    send_email "creation bypassed $screen_name" "$version"
                fi
                return 0
        fi
    fi    


    if ! pgrep -a $process_grep | grep "$script_command" >> /dev/null;
        then
            log_this "$script_command is not running"
            echo 0 > "$global_path_for_files/$script_running_count_filename"
            if test -f "$global_path_for_files/$script_email_count_filename";
                then
                    log_this "    $script_email_count_filename exists."
                    email_count=$(<"$global_path_for_files/$script_email_count_filename")
                    log_this "    loaded $email_count from $script_email_count_filename"
                    (( $email_count > 105 )) && return 0 
                    ((email_count=email_count+1))
                    echo $email_count > "$global_path_for_files/$script_email_count_filename"
                else
                    log_this "    $script_email_count_filename does not exist. creating..."
                    echo 1 > "$global_path_for_files/$script_email_count_filename"
                    email_count=1
            fi
            log_this "    current email count = $email_count"
            log_this "    $script_command attempting to start..."
            sudo -u $global_user_owner screen -S $screen_name -p 0 -X stuff "$start_with $script_path/$script_command^M"
            # see if we should send an email
            if (( $email_count < 2 ));
                then
                    send_email "restart attempt 1 $script_command" "$version"
            elif (( $email_count == 10 ));
                then
                    send_email "retsart attempt 10 $script_command" "$version"
            elif (( $email_count == 50 ));
                then
                    send_email "restart attempt 50 $script_command" "$version"
            elif (( $email_count == 100 ));
                then
                    send_email "final attempt $script_command" "$version"
            fi

            #
            # if this is one of the first 5ish attempts then lets wait 5 seconds and check again
            # if it looks good then send an email
            if (( $email_count < 5 ));
                then
                    sleep 2
                    if pgrep -a $process_grep | grep "$script_command" >> /dev/null; then
                        send_email "restart ok $script_command count $email_count" "$version"
                        log_this "    $script_command restart ok so far"
                    fi
            fi
            
        else
            if test -f "$global_path_for_files/$script_running_count_filename";
                then
                    running_count=$(<"$global_path_for_files/$script_running_count_filename")
                    ((running_count=running_count+1))
                    echo $running_count > "$global_path_for_files/$script_running_count_filename"
                    if (( $running_count == 20 )); then
                        send_email "stable $script_command" "$version"
                        if test -f "$global_path_for_files/$script_email_count_filename"; then
                            rm "$global_path_for_files/$script_email_count_filename"
                        fi
                    fi
                else
                    echo 1 > "$global_path_for_files/$script_running_count_filename"
                    running_count=1
            fi
            log_this "$script_command ok $running_count"
    fi

}



################################################################################
#
# main
#
################################################################################
if test -f "$global_path_for_files/kill"; then 
    log_this "kill file found . check will not run"
    exit 0
fi
ping_healthcheck
version="24.10.30-002"
log_this " "
log_this "$version"
log_this " "
#
#
################################################################################
#
#
# using namerefs as an array. some people consider it hackey and fragile
# but i have never had any issues using it
#
count_of_scripts_ran=0
for argument_array in "${global_script_array[@]}"; do
    declare -n array="$argument_array"
    check_script "${array[0]}" "${array[1]}" "${array[2]}" "${array[3]}" "${array[4]}" "${array[5]}"
    ((count_of_scripts_ran=count_of_scripts_ran+1))
done
#
#
#
log_this "done. checked $count_of_scripts_ran scripts"
#
################################################################################
#
# end
#
################################################################################
exit 0



