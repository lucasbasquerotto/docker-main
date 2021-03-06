#!/bin/bash
# shellcheck disable=SC2154
set -eou pipefail

pod_layer_dir="$var_pod_layer_dir"
pod_script_env_file="$var_pod_script"
pod_data_dir="$var_pod_data_dir"

function info {
	"$pod_script_env_file" "util:info" --info="${*}"
}

function error {
	"$pod_script_env_file" "util:error" --error="${BASH_SOURCE[0]}: line ${BASH_LINENO[0]}: ${*}"
}

command="${1:-}"

if [ -z "$command" ]; then
	error "No command entered (env - shared)."
fi

shift;

args=("$@")

# shellcheck disable=SC2214
while getopts ':-:' OPT; do
	if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
		OPT="${OPTARG%%=*}"       # extract long option name
		OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
		OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
	fi
	case "$OPT" in
		force ) arg_force="${OPTARG:-}";;
		max_amount ) arg_max_amount="${OPTARG:-}";;
		??* ) ;; ## ignore
		\? )  ;; ## ignore
	esac
done
shift $((OPTIND-1))

pod_main_run_file="$pod_layer_dir/main/scripts/main.sh"
haproxy_run_file="$pod_layer_dir/shared/scripts/services/haproxy.sh"
nginx_run_file="$pod_layer_dir/shared/scripts/services/nginx.sh"
nextcloud_run_file="$pod_layer_dir/shared/scripts/services/nextcloud.sh"
mysql_run_file="$pod_layer_dir/shared/scripts/services/mysql.sh"
redis_run_file="$pod_layer_dir/shared/scripts/services/redis.sh"
log_run_file="$pod_layer_dir/shared/scripts/log.sh"
test_run_file="$pod_layer_dir/shared/scripts/test.sh"
ssl_local_run_file="$pod_layer_dir/shared/scripts/lib/ssl.local.sh"

title="${arg_task_name:-}"
[ -n "${arg_subtask_cmd:-}" ] && title="$title ($arg_subtask_cmd)"
[ -n "${title:-}" ] && title="$title - "
title="${title}${command}"

next_args=( --task_name"${arg_task_name:-}" --subtask_cmd="$command" )

case "$command" in
	"upgrade")
		if [ "${var_custom__use_main_network:-}" = "true" ]; then
			"$pod_main_run_file" "setup:main:network" ${next_args[@]+"${next_args[@]}"}
		fi

		"$pod_main_run_file" "$command" ${args[@]+"${args[@]}"}
		;;
	"local:ssl")
		host="${1:-}"
		"$ssl_local_run_file" "$pod_layer_dir/tmp/ssl" "$host"
		;;
	"local:clear")
		mapfile -t list < <(sudo docker ps -aq)
		[[ ${#list[@]} -gt 0 ]] && sudo docker container rm -f "${list[@]}"
		sudo docker container prune -f
		sudo docker network prune -f
		sudo rm -rf "$pod_data_dir"
		;;
	"local:clear-all")
		mapfile -t list < <(sudo docker ps -aq)
		[[ ${#list[@]} -gt 0 ]] && sudo docker container rm -f "${list[@]}"
		sudo docker container prune -f
		sudo docker network prune -f
		sudo docker volume prune -f

		data_dir_aux="$pod_data_dir/../../../../data"

		if [ -d "$data_dir_aux" ]; then
			data_dir="$(cd "$data_dir_aux" && pwd)"
			sudo rm -rf "$data_dir/"*
		fi
		;;
	"backup"|"local.backup")
		"$pod_script_env_file" "shared:bg:$command" ${next_args[@]+"${next_args[@]}"}
		;;
	"action:exec:backup"|"action:exec:local.backup")
		task_name="${command#action:exec:}"

		if [ "${var_custom__use_logrotator:-}" = "true" ]; then
			"$pod_script_env_file" "shared:unique:rotate" ${next_args[@]+"${next_args[@]}"} ||:
		fi

		"$pod_main_run_file" "$task_name" ${next_args[@]+"${next_args[@]}"}
		;;
	"action:exec:rotate")
		"$pod_script_env_file" run logrotator
		;;
	"build")
		if [ "${var_custom__use_nginx:-}" = "true" ]; then
			if [ "$var_custom__pod_type" = "app" ] || [ "$var_custom__pod_type" = "web" ]; then
				env_dir_nginx="$pod_layer_dir/env/nginx"

				dir="${env_dir_nginx}/auth"

				if [ ! -d "$dir" ]; then
					mkdir -p "$dir"
				fi

				dir="${env_dir_nginx}/www"

				if [ ! -d "$dir" ]; then
					mkdir -p "$dir"
				fi
			fi
		fi

		if [ -n "${var_run__general__main_base_dir:-}" ] \
				&& [ -n "${var_run__general__main_base_dir_container:-}" ] \
				&& [ "${var_run__general__main_base_dir:-}" != "${var_run__general__main_base_dir_container:-}" ]; then

			src_dir="$(readlink -f "$pod_layer_dir/$var_run__general__main_base_dir")"
			dest_dir="$pod_layer_dir/$var_run__general__main_base_dir_container"

			mkdir -p "$dest_dir"
			rsync --recursive --delete --exclude "/" "$src_dir/" "$dest_dir/"
		fi

		"$pod_main_run_file" "$command" ${args[@]+"${args[@]}"}
		;;
	"prepare")
		data_dir="/var/main/data"

		"$pod_script_env_file" up "toolbox"

		"$pod_script_env_file" exec-nontty "toolbox" /bin/bash <<-SHELL || error "$title"
			set -eou pipefail

			dir="$data_dir/log/bg"

			if [ ! -d "\$dir" ]; then
				mkdir -p "\$dir"
				chmod 777 "\$dir"
			fi

			if [ "${var_custom__use_nginx:-}" = "true" ]; then
				if [ "$var_custom__pod_type" = "app" ] || [ "$var_custom__pod_type" = "web" ]; then
					dir_nginx="$data_dir/sync/nginx"

					dir="\${dir_nginx}/auto"
					file="\${dir}/ips-blacklist-auto.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# 127.0.0.1 1;
							# 1.2.3.4/16 1;
						EOF
					fi

					dir="\${dir_nginx}/manual"
					file="\${dir}/ips-blacklist.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# 127.0.0.1 1;
							# 0.0.0.0/0 1;
						EOF
					fi

					dir="\${dir_nginx}/manual"
					file="\${dir}/ua-blacklist.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# ~(Mozilla|Chrome) 1;
							# "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Safari/537.36" 1;
							# "python-requests/2.18.4" 1;
						EOF
					fi

					dir="\${dir_nginx}/manual"
					file="\${dir}/allowed-hosts.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# *.googlebot.com
							# *.google.com
						EOF
					fi

					dir="\${dir_nginx}/manual"
					file="\${dir}/log-exclude-paths.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# theia.localhost
							# /app/uploads/
						EOF
					fi

					dir="\${dir_nginx}/manual"
					file="\${dir}/log-exclude-paths-full.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# theia.localhost
							# /app/uploads/
						EOF
					fi
				fi
			fi

			if [ "${var_custom__use_haproxy:-}" = "true" ]; then
				if [ "$var_custom__pod_type" = "app" ] || [ "$var_custom__pod_type" = "web" ]; then
					dir_haproxy="$data_dir/sync/haproxy"

					dir="\${dir_haproxy}/auto"
					file="\${dir}/ips-blacklist-auto.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# 127.0.0.1
							# 1.2.3.4/16
						EOF
					fi

					dir="\${dir_haproxy}/manual"
					file="\${dir}/ips-blacklist.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# 127.0.0.1
							# 0.0.0.0/0
						EOF
					fi

					dir="\${dir_haproxy}/manual"
					file="\${dir}/ua-blacklist.lst"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Safari/537.36
							# python-requests/2.18.4
						EOF
					fi

					dir="\${dir_haproxy}/manual"
					file="\${dir}/allowed-hosts.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# *.googlebot.com
							# *.google.com
						EOF
					fi

					dir="\${dir_haproxy}/manual"
					file="\${dir}/log-exclude-paths.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# theia.localhost
							# /app/uploads/
						EOF
					fi

					dir="\${dir_haproxy}/manual"
					file="\${dir}/log-exclude-paths-full.conf"

					if [ ! -f "\$file" ]; then
						mkdir -p "\$dir"
						cat <<-EOF > "\$file"
							# theia.localhost
							# /app/uploads/
						EOF
					fi
				fi
			fi

			if [ "${var_custom__use_mysql:-}" = "true" ]; then
				if [ "$var_custom__pod_type" = "app" ] || [ "$var_custom__pod_type" = "db" ]; then
					dir="$data_dir/mysql"

					if [ ! -d "\$dir" ]; then
						mkdir -p "\$dir"
						chmod 755 "\$dir"
					fi

					dir="$data_dir/tmp/mysql"

					if [ ! -d "\$dir" ]; then
						mkdir -p "\$dir"
						chmod 777 "\$dir"
					fi

					dir="$data_dir/tmp/log/mysql"

					if [ ! -d "\$dir" ]; then
						mkdir -p "\$dir"
						chmod 777 "\$dir"
					fi
				fi
			fi

			if [ "${var_custom__use_mongo:-}" = "true" ]; then
				if [ "$var_custom__pod_type" = "app" ] || [ "$var_custom__pod_type" = "db" ]; then
					dir="$data_dir/mongo/db"

					if [ ! -d "\$dir" ]; then
						mkdir -p "\$dir"
						chmod 755 "\$dir"
					fi

					dir="$data_dir/mongo/dump"

					if [ ! -d "\$dir" ]; then
						mkdir -p "\$dir"
						chmod 755 "\$dir"
					fi
				fi
			fi
		SHELL
		;;
	"setup")
		if [ "${var_custom__local:-}" = "true" ]; then
			"$pod_script_env_file" "action:exec:setup" ${next_args[@]+"${next_args[@]}"}
		else
			"$pod_script_env_file" "shared:bg:setup" ${next_args[@]+"${next_args[@]}"}
		fi
		;;
	"action:exec:setup")
		if [ "${var_custom__use_theia:-}" = "true" ]; then
			"$pod_script_env_file" up theia
		fi

		if [ "${var_custom__use_certbot:-}" = "true" ]; then
			info "$command - run certbot if needed..."
			"$pod_script_env_file" "main:task:certbot" ${next_args[@]+"${next_args[@]}"}
		fi

		if [ "${var_custom__use_nginx:-}" = "true" ]; then
			"$pod_script_env_file" up nginx
		fi

		if [ "${var_custom__use_mongo:-}" = "true" ]; then
			if [ "$var_custom__pod_type" = "app" ] || [ "$var_custom__pod_type" = "db" ]; then
				"$pod_script_env_file" up mongo

				info "$command - init the mongo database if needed"
				"$pod_script_env_file" run mongo_init /bin/bash <<-SHELL || error "$title"
					set -eou pipefail

					for i in \$(seq 1 30); do
						mongo mongo/"$var_run__migrate__db_name" \
							--authenticationDatabase admin \
							--username "$var_run__migrate__db_root_user" \
							--password "${var_run__migrate__db_root_pass:-}" \
							--eval "
								rs.initiate({
									_id: 'rs0',
									members: [ { _id: 0, host: 'localhost:27017' } ]
								})
							" && s=\$? && break || s=\$?;
						echo "Tried \$i times. Waiting 5 secs...";
						sleep 5;
					done;

					if [ "\$s" != "0" ]; then
						exit "\$s"
					fi

					for i in \$(seq 1 30); do
						mongo mongo/admin \
							--authenticationDatabase admin \
							--username "$var_run__migrate__db_root_user" \
							--password "${var_run__migrate__db_root_pass:-}" \
							/tmp/main/init.js && s=\$? && break || s=\$?;
						echo "Tried \$i times. Waiting 5 secs...";
						sleep 5;
					done;

					if [ "\$s" != "0" ]; then
						exit "\$s"
					fi
				SHELL
			fi
		fi

		"$pod_main_run_file" setup ${next_args[@]+"${next_args[@]}"}
		;;
	"migrate")
		if [ "${var_custom__use_varnish:-}" = "true" ]; then
			"$pod_script_env_file" up varnish

			info "$command - clear varnish cache..."
			"$pod_script_env_file" "service:varnish:clear" ${next_args[@]+"${next_args[@]}"}
		fi

		if [ "${var_custom__use_nextcloud:-}" = "true" ]; then
			info "$command - prepare nextcloud..."
			"$pod_script_env_file" "shared:service:nextcloud:setup" \
				${next_args[@]+"${next_args[@]}"}
		fi
		;;
	"shared:service:nextcloud:setup")
		"$pod_script_env_file" "service:nextcloud:setup" \
			--task_name="nextcloud" \
			--subtask_cmd="$command" \
			--admin_user="$var_shared__nextcloud__setup__admin_user" \
			--admin_pass="$var_shared__nextcloud__setup__admin_pass" \
			--nextcloud_url="$var_shared__nextcloud__setup__url" \
			--nextcloud_domain="$var_shared__nextcloud__setup__domain" \
			--nextcloud_host="$var_shared__nextcloud__setup__host" \
			--nextcloud_protocol="$var_shared__nextcloud__setup__protocol"

		"$pod_script_env_file" "service:nextcloud:fs" \
			--task_name="nextcloud_action" \
			--subtask_cmd="$command" \
			--mount_point="/action" \
			--datadir="/var/main/data/action"

		"$pod_script_env_file" "service:nextcloud:fs" \
			--task_name="nextcloud_data" \
			--subtask_cmd="$command" \
			--mount_point="/data" \
			--datadir="/var/main/data"

		"$pod_script_env_file" "service:nextcloud:fs" \
			--task_name="nextcloud_sync" \
			--subtask_cmd="$command" \
			--mount_point="/sync" \
			--datadir="/var/main/data/sync"

		if [ "${var_shared__nextcloud__s3_backup__enable:-}" = "true" ]; then
			"$pod_script_env_file" "service:nextcloud:s3" \
				--task_name="nextcloud_backup" \
				--subtask_cmd="$command" \
				--mount_point="/backup" \
				--bucket="$var_shared__nextcloud__s3_backup__bucket" \
				--hostname="$var_shared__nextcloud__s3_backup__hostname" \
				--port="$var_shared__nextcloud__s3_backup__port" \
				--region="$var_shared__nextcloud__s3_backup__region" \
				--use_ssl="$var_shared__nextcloud__s3_backup__use_ssl" \
				--use_path_style="$var_shared__nextcloud__s3_backup__use_path_style" \
				--legacy_auth="$var_shared__nextcloud__s3_backup__legacy_auth"  \
				--key="$var_shared__nextcloud__s3_backup__access_key" \
				--secret="$var_shared__nextcloud__s3_backup__secret_key"
		fi

		if [ "${var_shared__nextcloud__s3_uploads__enable:-}" = "true" ]; then
			"$pod_script_env_file" "service:nextcloud:s3" \
				--task_name="nextcloud_uploads" \
				--subtask_cmd="$command" \
				--mount_point="/uploads" \
				--bucket="$var_shared__nextcloud__s3_uploads__bucket" \
				--hostname="$var_shared__nextcloud__s3_uploads__hostname" \
				--port="$var_shared__nextcloud__s3_uploads__port" \
				--region="$var_shared__nextcloud__s3_uploads__region" \
				--use_ssl="$var_shared__nextcloud__s3_uploads__use_ssl" \
				--use_path_style="$var_shared__nextcloud__s3_uploads__use_path_style" \
				--legacy_auth="$var_shared__nextcloud__s3_uploads__legacy_auth"  \
				--key="$var_shared__nextcloud__s3_uploads__access_key" \
				--secret="$var_shared__nextcloud__s3_uploads__secret_key"
		fi
		;;
	"action:exec:block_ips")
		service="${var_shared__block_ips__action_exec__service:-}"

		if [ "${var_shared__block_ips__action_exec__enabled:-}" != 'true' ]; then
			error "$title: action is not enabled"
		elif [ -z "$service" ]; then
			error "$title: no service specified"
		fi

		"$pod_script_env_file" "shared:log:$service:verify"

		dest_last_day_file="$("$pod_script_env_file" "shared:log:$service:day" \
			--force="${arg_force:-}" \
			--days_ago="1" \
			--max_amount="${arg_max_amount:-}")"

		dest_day_file=""

		if [ "${var_shared__block_ips__action_exec__current_day:-}" = "true" ]; then
			dest_day_file="$("$pod_script_env_file" "shared:log:$service:day" \
				--force="${arg_force:-}" \
				--max_amount="${arg_max_amount:-}")"
		fi

		service_sync_base_dir="/var/main/data/sync/$service"
		log_hour_path_prefix="$("$pod_script_env_file" "shared:log:$service:hour_path_prefix")"

		"$pod_script_env_file" "service:$service:block_ips" \
			--task_info="$title" \
			--max_amount="${var_shared__block_ips__action_exec__max_amount:-$arg_max_amount}" \
			--output_file="$service_sync_base_dir/auto/ips-blacklist-auto.conf" \
			--manual_file="$service_sync_base_dir/manual/ips-blacklist.conf" \
			--allowed_hosts_file="$service_sync_base_dir/manual/allowed-hosts.conf" \
			--log_file_last_day="$dest_last_day_file" \
			--log_file_day="$dest_day_file" \
			--amount_day="$var_shared__block_ips__action_exec__amount_day" \
			--log_file_hour="$log_hour_path_prefix.$(date -u '+%Y-%m-%d.%H').log" \
			--log_file_last_hour="$log_hour_path_prefix.$(date -u -d '1 hour ago' '+%Y-%m-%d.%H').log" \
			--amount_hour="$var_shared__block_ips__action_exec__amount_hour"
		;;
	"action:exec:nginx_reload")
		"$pod_script_env_file" "service:nginx:reload" ${args[@]+"${args[@]}"}
		;;
	"action:exec:haproxy_reload")
		"$pod_script_env_file" "service:haproxy:reload" ${args[@]+"${args[@]}"}
		;;
	"shared:bg:"*)
		task_name="${command#shared:bg:}"

		"$pod_script_env_file" "bg:subtask" \
			--task_name="$task_name" \
			--subtask_cmd="$command" \
			--bg_file="$pod_data_dir/log/bg/$task_name.$(date -u '+%Y%m%d.%H%M%S').$$.log" \
			--action_dir="/var/main/data/action"
		;;
	"shared:unique:"*)
		task_name="${command#shared:unique:}"

		opts=()

		opts+=( "--task_name=$task_name" )
		opts+=( "--subtask_cmd=$command" )

		opts+=( "--toolbox_service=toolbox" )
		opts+=( "--action_dir=/var/main/data/action" )

		"$pod_main_run_file" "unique:subtask" "${opts[@]}"
		;;
	"action:exec:watch")
		inotifywait -m "$pod_data_dir/action" -e create -e moved_to |
			while read -r _ _ file; do
				"$pod_script_env_file" "shared:action:$file"
			done
		;;
	"shared:action:"*)
		task_name="${command#shared:action:}"

		opts=()

		opts+=( "--task_name=$task_name" )
		opts+=( "--subtask_cmd=$command" )

		opts+=( "--toolbox_service=toolbox" )
		opts+=( "--action_dir=/var/main/data/action" )

		"$pod_main_run_file" "action:subtask" "${opts[@]}"
		;;
	"action:exec:log_register."*)
		task_name="${command#action:exec:log_register.}"
		"$pod_script_env_file" "shared:log:register:$task_name" \
			${next_args[@]+"${next_args[@]}"}
		;;
	"shared:s3:replicate:backup")
		opts=()

		opts+=( "--task_name=s3_backup_replica" )
		opts+=( "--subtask_cmd=$command" )
		opts+=( "--s3_cmd=sync" )

		opts+=( "--s3_src_alias=backup" )
		opts+=( "--s3_remote_src=true" )
		opts+=( "--s3_bucket_src_name=$var_task__s3_backup__s3_subtask__bucket_name" )
		opts+=( "--s3_bucket_src_path=${var_task__s3_backup__s3_subtask__bucket_path:-}" )

		opts+=( "--s3_dest_alias=backup_replica" )
		opts+=( "--s3_remote_dest=true" )
		opts+=( "--s3_bucket_dest_name=$var_shared__s3_replicate_backup__bucket_dest_name" )
		opts+=( "--s3_bucket_dest_path=${var_shared__s3_replicate_backup__bucket_dest_path:-}" )

		"$pod_script_env_file" "s3:subtask" "${opts[@]}"
		;;
	"shared:s3:replicate:uploads")
		opts=()

		opts+=( "--task_name=s3_uploads_replica" )
		opts+=( "--subtask_cmd=$command" )
		opts+=( "--s3_cmd=sync" )

		opts+=( "--s3_src_alias=uploads" )
		opts+=( "--s3_remote_src=true" )
		opts+=( "--s3_bucket_src_name=$var_task__s3_uploads__s3_subtask__bucket_name" )
		opts+=( "--s3_bucket_src_path=${var_task__s3_uploads__s3_subtask__bucket_path:-}" )

		opts+=( "--s3_dest_alias=uploads_replica" )
		opts+=( "--s3_remote_dest=true" )
		opts+=( "--s3_bucket_dest_name=$var_shared__s3_replicate_s3_uploads__bucket_dest_name" )
		opts+=( "--s3_bucket_dest_path=${var_shared__s3_replicate_s3_uploads__bucket_dest_path:-}" )

		"$pod_script_env_file" "s3:subtask" "${opts[@]}"
		;;
	"service:nginx:"*)
		"$nginx_run_file" "$command" \
			--toolbox_service="toolbox" \
			--nginx_service="nginx" \
			${args[@]+"${args[@]}"}
		;;
	"service:haproxy:"*)
		"$haproxy_run_file" "$command" \
			--toolbox_service="toolbox" \
			--haproxy_service="haproxy" \
			${args[@]+"${args[@]}"}
		;;
	"service:nextcloud:"*)
		"$nextcloud_run_file" "$command" \
			--toolbox_service="toolbox" \
			--nextcloud_service="nextcloud" \
			${args[@]+"${args[@]}"}
		;;
	"service:mysql:"*)
		"$mysql_run_file" "$command" \
			--toolbox_service="toolbox" \
			${args[@]+"${args[@]}"}
		;;
	"service:redis:"*)
		"$redis_run_file" "$command" \
			--toolbox_service="toolbox" \
			--redis_service="redis" \
			${args[@]+"${args[@]}"}
		;;
	"service:varnish:clear")
		cmd=( "$pod_script_env_file" exec-nontty varnish varnishadm ban req.url '~' '.' )
		error="$({ "${cmd[@]}"; } 2>&1)" && status=0 || status=1

		# Sometimes varnish returns an autentication error when the container was just created
		if [ "$status" = 1 ] && [[ "$error" == *'Authentication required'* ]]; then
			echo "waiting for the varnish service to be ready..."
			sleep 30
			"${cmd[@]}"
		fi
		;;
	"delete:old")
		info "$command - clear old files"
		>&2 "$pod_script_env_file" up toolbox

		dirs=( "/var/log/main/" "/tmp/main/tmp/" )

		re_number='^[0-9]+$'
		delete_old_days="${var_shared__delete_old__days:-7}"

		if ! [[ $delete_old_days =~ $re_number ]] ; then
			msg="The variable 'var_shared__delete_old__days' should be a number"
			error "$title: $msg (value=$delete_old_days)"
		fi

		info "$command - create the backup base directory and clear old files"
		"$pod_script_env_file" exec-nontty toolbox /bin/bash <<-SHELL || error "$title"
			set -eou pipefail

			for dir in "${dirs[@]}"; do
				if [ -d "\$dir" ]; then
					# remove old files and directories
					find "\$dir" -mindepth 1 -ctime +$delete_old_days -delete -print;

					# remove old and empty directories
					find "\$dir" -mindepth 1 -type d -ctime +$delete_old_days -empty -delete -print;
				fi
			done
		SHELL
		;;
	"shared:log:"*)
		"$log_run_file" "$command" ${args[@]+"${args[@]}"}
		;;
	"shared:test:"*)
		"$test_run_file" "$command" ${args[@]+"${args[@]}"}
		;;
	*)
		"$pod_main_run_file" "$command" ${args[@]+"${args[@]}"}
		;;
esac
