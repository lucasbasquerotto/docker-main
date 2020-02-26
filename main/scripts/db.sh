#!/bin/bash
# shellcheck disable=SC1090,SC2154,SC1117,SC2153,SC2214
set -eou pipefail

pod_script_env_file="$POD_SCRIPT_ENV_FILE"

RED='\033[0;31m'
NC='\033[0m' # No Color

function error {
	msg="$(date '+%F %T') - ${BASH_SOURCE[0]}: line ${BASH_LINENO[0]}: ${1:-}"
	>&2 echo -e "${RED}${msg}${NC}"
	exit 2
}

command="${1:-}"

if [ -z "$command" ]; then
	error "No command entered (db)."
fi

shift;

while getopts n:s:u:p:d:-: OPT; do
  if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
    OPT="${OPTARG%%=*}"       # extract long option name
    OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
    OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
  fi
  case "$OPT" in
    n | db_name ) db_name="${OPTARG:-}" ;;
    s | db_service ) db_service="${OPTARG:-}" ;;
    u | db_user ) db_user="${OPTARG:-}" ;;
    p | db_pass ) db_pass="${OPTARG:-}";;
    d | db_backup_dir ) db_backup_dir="${OPTARG:-}" ;;
    f | db_sql_file ) db_sql_file="${OPTARG:-}" ;;
    ??* ) die "Illegal option --$OPT" ;;  # bad long option
    \? )  exit 2 ;;  # bad short option (error reported via getopts)
  esac
done
shift $((OPTIND-1))

re_number='^[0-9]+$'

case "$command" in
	"setup:verify:mysql")
		"$pod_script_env_file" up "$db_service"
		
		sql_tables="select count(*) from information_schema.tables where table_schema = '$db_name'"
		sql_output="$("$pod_script_env_file" exec-nontty "$db_service" \
			mysql -u "$db_user" -p"$db_pass" -N -e "$sql_tables")" ||:
		tables=""

		if [ ! -z "$sql_output" ]; then
			tables="$(echo "$sql_output" | tail -n 1)"
		fi

		if ! [[ $tables =~ $re_number ]] ; then
			tables=""
		fi

		if [ -z "$tables" ]; then
			>&2 echo "$(date '+%F %T') - $command - wait for db to be ready"
			sleep 60
			sql_output="$("$pod_script_env_file" exec-nontty "$db_service" \
				mysql -u "$db_user" -p"$db_pass" -N -e "$sql_tables")" ||:

			if [ ! -z "$sql_output" ]; then
				tables="$(echo "$sql_output" | tail -n 1)"
			fi
		fi

		if ! [[ $tables =~ $re_number ]] ; then
			error "$command: Could nor verify number of tables in database - output: $sql_output"
		fi

		if [ "$tables" != "0" ]; then
			echo "true"
		else
			echo "false"
		fi
		;;
  "setup:local:file:mysql")
		if [ -z "$db_sql_file" ]; then
			error "$command: db_sql_file not specified"
		fi

		"$pod_script_env_file" up "$db_service"

		"$pod_script_env_file" exec-nontty "$db_service" /bin/bash <<-SHELL
			set -eou pipefail

      extension=${db_sql_file##*.}

      if [ "\$extension" != "sql" ]; then
        error "$command: db file extension should be sql - found: \$extension ($db_sql_file)"
      fi

      if [ ! -f "$db_sql_file" ]; then
        error "$command: db file not found: $db_sql_file"
      fi
      
			mysql -u "$db_user" -p"$db_pass" -e "CREATE DATABASE IF NOT EXISTS $db_name;"
			pv "$db_sql_file" | mysql -u "$db_user" -p"$db_pass" "$db_name"
		SHELL
		;;
  "backup:local:mysql")
		"$pod_script_env_file" up "$db_service"

		"$pod_script_env_file" exec-nontty "$db_service" /bin/bash <<-SHELL
			set -eou pipefail
			mysqldump -u "$db_user" -p"$db_pass" "$db_name" > "/$db_backup_dir/$db_name.sql"
		SHELL
    ;;
  *)
		error "$command: Invalid command"
    ;;
esac