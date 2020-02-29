#!/bin/bash
# shellcheck disable=SC1090,SC2154,SC1117,SC2153,SC2214
set -eou pipefail

pod_script_env_file="$POD_SCRIPT_ENV_FILE"

GRAY="\033[0;90m"
RED='\033[0;31m'
NC='\033[0m' # No Color

function info {
	msg="$(date '+%F %T') - ${1:-}"
	>&2 echo -e "${GRAY}${msg}${NC}"
}

function error {
	msg="$(date '+%F %T') - ${BASH_SOURCE[0]}: line ${BASH_LINENO[0]}: ${1:-}"
	>&2 echo -e "${RED}${msg}${NC}"
	exit 2
}

command="${1:-}"

if [ -z "$command" ]; then
	error "No command entered."
fi

shift;

while getopts ':-:' OPT; do
	if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
		OPT="${OPTARG%%=*}"       # extract long option name
		OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
		OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
	fi
	case "$OPT" in
		task_short_name ) task_short_name="${OPTARG:-}";;
		task_kind ) task_kind="${OPTARG:-}";;
		toolbox_service ) toolbox_service="${OPTARG:-}";;
		s3_task_name ) s3_task_name="${OPTARG:-}";;
		s3_bucket_name ) s3_bucket_name="${OPTARG:-}" ;;
		s3_bucket_path ) s3_bucket_path="${OPTARG:-}";;

		backup_src_base_dir ) backup_src_base_dir="${OPTARG:-}";;
		backup_src_dir ) backup_src_dir="${OPTARG:-}";;
		backup_src_file ) backup_src_file="${OPTARG:-}";;
		backup_tmp_base_dir ) backup_tmp_base_dir="${OPTARG:-}";;
		backup_bucket_sync_dir ) backup_bucket_sync_dir="${OPTARG:-}";;

		restore_dest_dir ) restore_dest_dir="${OPTARG:-}";;
		restore_dest_file ) restore_dest_file="${OPTARG:-}";;
		restore_tmp_dir ) restore_tmp_dir="${OPTARG:-}";;
		restore_local_file ) restore_local_file="${OPTARG:-}" ;;
		restore_remote_file ) restore_remote_file="${OPTARG:-}" ;;
		restore_remote_bucket_path_dir ) restore_remote_bucket_path_dir="${OPTARG:-}" ;;
		restore_remote_bucket_path_file ) restore_remote_bucket_path_file="${OPTARG:-}";;
		restore_is_zip_file ) restore_is_zip_file="${OPTARG:-}";;
		restore_zip_pass ) restore_zip_pass="${OPTARG:-}";;
		restore_zip_inner_dir ) restore_zip_inner_dir="${OPTARG:-}";;
		restore_zip_inner_file ) restore_zip_inner_file="${OPTARG:-}";;

		??* ) error "Illegal option --$OPT" ;;  # bad long option
		\? )  exit 2 ;;  # bad short option (error reported via getopts)
	esac
done
shift $((OPTIND-1))

case "$command" in
	"backup")
		info "$command - started"

		info "$command - start needed services"
		>&2 "$pod_script_env_file" up "$toolbox_service"

		tmp_dir_name="backup-$task_short_name-$(date '+%Y%m%d_%H%M%S')-$(date '+%s')"
		tmp_dir="$backup_tmp_base_dir/$tmp_dir_name"
		bucket_prefix="$s3_bucket_name/$s3_bucket_path"
		bucket_prefix="$(echo "$bucket_prefix" | tr -s /)"
		backup_bucket_sync_dir_full="$s3_bucket_name/$s3_bucket_path/${backup_bucket_sync_dir:-}"
		backup_bucket_sync_dir_full="$(echo "$backup_bucket_sync_dir_full" | tr -s /)"

		info "$command - clean tmp directory ($tmp_dir) and create main directory ($tmp_dir)"
		>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" /bin/bash <<-SHELL
			set -eou pipefail
			rm -rf "/$tmp_dir"
			mkdir -p "/$tmp_dir"
			mkdir -p "/$tmp_dir"
		SHELL

		if [ -z "${backup_bucket_sync_dir:-}" ]; then
			if [ "$task_kind" = "dir" ]; then
				dest_file="$task_short_name.zip"
				src_full_path="/$backup_src_base_dir/$backup_src_dir"
				dest_full_path="/$tmp_dir/$dest_file"

				msg="$src_full_path to $dest_full_path (inside toolbox)"
				info "$command - zip backup directory - $msg"
				>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" /bin/bash <<-SHELL
					set -eou pipefail
					cd "/$src_full_path"
					zip -r "$dest_full_path" .
				SHELL
			elif [ "$task_kind" = "file" ]; then
				dest_file="$task_short_name.zip"
				src_full_path="/$backup_src_base_dir/$backup_src_file"
				dest_full_path="/$tmp_dir/$dest_file"
				msg="$src_full_path to $dest_full_path (inside toolbox)"

				if [ "$src_full_path" != "$dest_full_path" ]; then
					if [ "${backup_src_file##*.}" = "zip" ]; then
						info "$command - move backup file - $msg"
						>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" /bin/bash <<-SHELL
							set -eou pipefail
							mv "/$backup_src_base_dir/$backup_src_file" "/$tmp_dir/$dest_file"
						SHELL
					else
						info "$command - zip backup file - $msg"
						>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" /bin/bash <<-SHELL
							set -eou pipefail
							zip -j "/$tmp_dir/$dest_file" "/$backup_src_base_dir/$backup_src_file"
						SHELL
					fi
				fi
			else
				error "$command: $task_kind: task_kind invalid value"
			fi
		fi

		if [ ! -z "${s3_bucket_name:-}" ]; then
			empty_bucket="$("$pod_script_env_file" "$s3_task_name" --s3_cmd=is_empty_bucket)"
			s3_opts=()

			if [ "$empty_bucket" = "true" ]; then
				info "$command - $toolbox_service - $s3_task_name - create bucket $s3_bucket_name"
				>&2 "$pod_script_env_file" "$s3_task_name" --s3_cmd=create-bucket
			fi

			if [ -z "${backup_bucket_sync_dir:-}" ]; then
				src="/$tmp_dir/"
				dest="s3://$bucket_prefix/$tmp_dir_name/"

				msg="sync local tmp directory with bucket - $src to $dest"
				>&2 "$pod_script_env_file" "$s3_task_name" --s3_cmd=sync \
					"--s3_src=$src" "--s3_dest=$dest"
			else
				if [ "$task_kind" = "dir" ]; then
					src="/$backup_src_base_dir/$backup_src_dir/"
				elif [ "$task_kind" = "file" ]; then
					src="/$backup_src_base_dir/"
					s3_opts=( --exclude "*" --include "$backup_src_file" )
				else
					error "$command: $task_kind: task_kind invalid value"
				fi

				dest="s3://$backup_bucket_sync_dir_full/"

				msg="sync local src directory with bucket - $src to $dest"
				info "$command - $toolbox_service - $s3_task_name - $msg"
				>&2 "$pod_script_env_file" "$s3_task_name" --s3_cmd=sync \
					"--s3_src=$src" "--s3_dest=$dest" ${s3_opts[@]+"--s3_opts=${s3_opts[@]}"}
			fi
		fi

		info "$command - generated backup file(s) at '/$tmp_dir'"
		;;  
	"restore")
		restore_path=''
		restore_dest_dir_full="/$restore_dest_dir"

		bucket_prefix="$s3_bucket_name/$s3_bucket_path"

		if [ ! -z "${restore_remote_bucket_path_dir:-}" ]; then
			s3_bucket_path="$bucket_prefix/$restore_remote_bucket_path_dir"
			s3_bucket_path=$(echo "$s3_bucket_path" | tr -s /)			
			restore_remote_src="s3://$s3_bucket_path"
			s3_opts=()

			if [ ! -z "${restore_dest_file:-}" ]; then
				s3_opts=( --exclude "*" --include "$restore_dest_file" )
				restore_path="$restore_dest_dir_full/$restore_dest_file"
			else
				restore_path="$restore_dest_dir_full"
			fi
			
			msg="$restore_remote_src to $restore_dest_dir_full"
			info "$command - restore from remote bucket directly to local directory - $msg"
			>&2 "$pod_script_env_file" "$s3_task_name" --s3_cmd=sync \
				"--s3_src=$restore_remote_src" "--s3_dest=$restore_dest_dir_full" \
					${s3_opts[@]+"${s3_opts[@]}"}
		else
			key="$(date '+%Y%m%d_%H%M%S')-$(date '+%s')"
			restore_tmp_dir_full="/$restore_tmp_dir"
			
			backup_file=""
			restore_remote_src=""
			restore_local_dest=""

			info "$command - $toolbox_service - restore"
			>&2 "$pod_script_env_file" up "$toolbox_service"
			>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" /bin/bash <<-SHELL
				set -eou pipefail
				rm -rf "$restore_tmp_dir_full"
				mkdir -p "$restore_tmp_dir_full"
				mkdir -p "$restore_dest_dir_full"
			SHELL
			
			backup_file_default_name="$task_short_name-$key.zip"
			backup_file_default="/$restore_tmp_dir/$backup_file_default_name"

			if [ "${restore_is_zip_file:-}" != "true" ]; then
				if [ "$task_kind" = "dir" ]; then
					msg="trying to backup a directory using a non-zipped file"
					msg="$msg (instead, use a zip file or specify a bucket directory as the source)"
					error "$command - $msg"	
				fi

				backup_file_default="$restore_dest_file"
			fi

			if [ ! -z "${restore_local_file:-}" ]; then
				info "$command - restore from local file"
				backup_file="$restore_local_file"
			elif [ ! -z "${restore_remote_file:-}" ]; then
				info "$command - restore from remote file"
				backup_file="$backup_file_default"

				>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" \
					curl -L -o "$backup_file" -k "$restore_remote_file"
			elif [ ! -z "${restore_remote_bucket_path_file:-}" ]; then
				msg="$command - restore a file from remote bucket"
				info "$msg [$restore_remote_src -> $restore_local_dest]"			
				backup_file="$backup_file_default"

				s3_bucket_path="$bucket_prefix/$restore_remote_bucket_path_file"
				s3_bucket_path=$(echo "$s3_bucket_path" | tr -s /)
				
				restore_remote_src="s3://$s3_bucket_path"

				msg="$restore_remote_src to $backup_file"
				info "$command - $toolbox_service - $s3_task_name - copy bucket file to local path - $msg"
				>&2 "$pod_script_env_file" "$s3_task_name" --s3_cmd=cp \
					"--s3_src=$restore_remote_src" "--s3_dest=$backup_file"
			else
				error "$command: no source provided"
			fi
			
			info "$command - restore - main ($task_kind) - $backup_file to $restore_tmp_dir_full"
			unzip_opts=()

			if [ ! -z "${restore_zip_pass:-}" ]; then
				unzip_opts=( -P "$restore_zip_pass" )
			fi

			if [ "$task_kind" = "dir" ]; then
				if [ "${restore_is_zip_file:-}" = "true" ]; then					
					info "$command - unzip $backup_file to directory $restore_tmp_dir_full"
					>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" /bin/bash <<-SHELL
						set -eou pipefail

						unzip ${unzip_opts[@]+"${unzip_opts[@]}"} "$backup_file" -d "$restore_tmp_dir_full"
				
						if [ "$restore_tmp_dir_full/$restore_zip_inner_dir" != "$restore_dest_dir_full" ]; then
							cp -r "$restore_tmp_dir_full/$restore_zip_inner_dir"/. "$restore_dest_dir_full/"
							rm -rf "$restore_tmp_dir_full/$restore_zip_inner_dir"
						fi
					SHELL
				else
					msg="trying to backup a directory using a non-zipped file"
					msg="$msg (use a zip file instead, or specify a bucket directory as the source)"
					error "$command - $msg"	
				fi
				
				restore_path="$restore_dest_dir_full"
			elif [ "$task_kind" = "file" ]; then
				if [ "${restore_is_zip_file:-}" = "true" ]; then
					info "$command - unzip $backup_file to directory $restore_tmp_dir_full"
					intermediate="$restore_tmp_dir_full/$restore_zip_inner_file"
					dest="$restore_dest_dir_full/$restore_dest_file"

					if [ "$backup_file" != "$dest" ]; then
						>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" /bin/bash <<-SHELL
							set -eou pipefail

							unzip ${unzip_opts[@]+"${unzip_opts[@]}"} "$backup_file" -d "$restore_tmp_dir_full"

							if [ "$intermediate" != "$dest" ]; then
								mv "$intermediate" "$dest"
								rm -rf "$restore_tmp_dir_full"
							fi
						SHELL
					fi
				else
					info "$command - move $backup_file to directory $restore_dest_dir_full"
					>&2 "$pod_script_env_file" exec-nontty "$toolbox_service" \
						mv "$backup_file" "$restore_dest_dir_full/"
				fi

				restore_path="$restore_dest_dir_full/$restore_dest_file"
			else
				error "$command: $task_kind: invalid value for task_kind"
			fi
		fi

		echo "$restore_path"
		;;
	*)
		error "$command: invalid command"
		;;
esac
